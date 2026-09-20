# Qwen3.8-Flash-Next on `10.0.1.227:9292` — performance assessment

Measured 2026-09-19 from a LAN client (macOS) with [llama-benchy](https://github.com/eugr/llama-benchy) 0.4.0.
Raw data: [`data/endpoint/`](../data/endpoint) (config and metrics snapshots), [`data/benchy/`](../data/benchy) (benchmark output).

## Summary

- Single stream: **~1,740 tok/s prefill, ~30–32 tok/s decode**, 1.4 s to first token on a cold 2k prompt.
- Aggregate decode scales **3.5x, to ~104 tok/s at 8 concurrent**, while per-request speed falls to ~14 tok/s.
- **Concurrency 16 and 32 could not be measured.** llama-swap rejects everything past 10 in-flight requests with HTTP 429, so those two sweep rows are really concurrency 10.
- **Two limits disagreed.** As measured, llama-swap admitted 10 while vLLM ran only 8 at once (inferred from queueing, see below), so requests 9 and 10 were accepted and then waited silently — up to 39 s to first token. `llama-swap.yaml` in this repo now sets `concurrencyLimit: 8`; every number here was taken before that change.
- **Prefill is the bottleneck for this box.** Time to first token grows linearly with the total prompt tokens in flight: 8 cold 2k prompts means ~10.5 s each. The prefix cache (85% lifetime hit rate) is what makes agent workloads usable.
- **Speed holds at depth.** Out to 133k tokens of context, single-stream prefill stays at ~1,850–2,000 tok/s and decode at ~27–32 tok/s. A cold 133k prompt takes 72 s to first token — long, but linear, with no cliff.
- **But a long prefill starves everyone else's decode.** While one request prefills a long prompt, a request that is already generating drops from ~30 tok/s to **1–6 tok/s** until that prefill ends — over a minute for a 131k prompt. For several agents sharing the box this matters more than any throughput figure above.
- **Real KV capacity is about half the headline.** Two 133k requests filled 69.5% of the KV cache; usage ran ~2x the simple token count at every step. Plan for roughly 380k tokens of context in flight, not 721k.
- No preemptions and no errors other than the 429s.

## Endpoint configuration (as observed)

| Item | Value |
|---|---|
| Front end | llama-swap, API key required, `/health` open. One model, TTL 0 (never unloaded) |
| Host | DGX Spark, 121 GB unified memory. ~75 GiB of weights resident; the 48 GiB n-gram table is mmapped from NVMe (see [`bin/run-qwen38.sh`](../bin/run-qwen38.sh)) |
| llama-swap concurrency limit | 10. Not set in [`llama-swap.yaml`](../llama-swap.yaml), so this is llama-swap's default. Observed: exactly `N − 10` requests rejected at N = 16 and 32 |
| Backend | vLLM `0.1.dev20073+g8e685d198`, launched by `~/ai-stack/bin/run-qwen38.sh`, port 10001 |
| Model | `nvidia/Qwen3.8-Flash-Next-NVFP4`, `fp8hybrid` snapshot; hybrid MoE, 3:1 Gated DeltaNet (linear attention) to sparse attention, 512 experts. 125B backbone + 51B n-gram table, 6B active |
| `max_model_len` | 500,000 (`CTX_LEN` default in the launch script). Native window is 262,144; 500k comes from YaRN factor 4 |
| KV cache | 19.5 GiB, 721,212 tokens → 1.44 full-length requests nominal (about half that in practice, see sweep 4). `cache_dtype=auto`, block size 8; vLLM reports the DeltaNet state under its `mamba_*` cache settings (block size 16, mode `align`) |
| `gpu_memory_utilization` | 0.8 — deliberately: the launch script records that 0.85 drifted into swap and 0.875 was OOM-killed |
| KV offload | backend `native`, no size set, 0 CPU blocks |
| Prefix caching | on (sha256). Lifetime: 3.10M hits / 3.62M queried = 85% |
| Speculative decoding | MTP, 2 draft tokens per step, reduced draft vocabulary |
| vLLM running-sequence cap | **8 — inferred, not read from config** (see "The 8-slot queue") |
| Reasoning | on by default; a trivial coding prompt spent 79 of 144 output tokens on reasoning |

Deployment config lives in this repo (`llama-swap.yaml`, `bin/run-qwen38.sh`). The vLLM flag set itself — including `--max-num-seqs` and `--max-num-batched-tokens` — is in the upstream recipe's `scripts/serve.sh` (`~/ai-stack/qwen38-flash` on the host), which is not in this repo and was not read for this assessment.

## Results

All runs: 3 repetitions, `--no-cache` (unique prompts, prefix cache bypassed — confirmed by 0 cache hits on 287,300 prompt tokens), text from benchy's default book corpus. Throughput in tokens/s; ± is the standard deviation across runs.

### Sweep 1 — prefill-heavy: 2048 prompt / 128 output

| Requested | Actually ran | Rejected (429) | Prefill tok/s | Decode total | Decode per request | Peak total | TTFT mean | TTFT max |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 0 | 1,739 | 32.2 ± 0.6 | 32.2 | 46 | 1.36 s | 1.38 s |
| 2 | 2 | 0 | 1,513 | 45.0 ± 4.9 | 23.8 | 109 | 2.57 s | 3.02 s |
| 4 | 4 | 0 | 1,253 | 71.4 ± 7.4 | 20.5 | 151 | 6.54 s | 8.05 s |
| 8 | 8 | 0 | 1,444 | 70.8 ± 4.0 | 13.4 | 188 | 10.50 s | 12.07 s |
| 16 | **10** | 6 of 16 | 960 | 61.1 ± 2.7 | 13.7 | 195 | 12.06 s | 22.25 s |
| 32 | **10** | 22 of 32 | 916 | 59.7 ± 1.0 | 14.3 | 208 | 12.75 s | 22.79 s |

The last two rows are the same experiment twice (10 in flight) and agree with each other. They are not 16- or 32-way results. benchy computes its statistics over successful requests only and exited 0, so the JSON alone does not show the rejections — [`sweep-pp2048-tg128.output.txt`](../data/benchy/sweep-pp2048-tg128.output.txt) does.

"Decode total" in this sweep is depressed by prefill contention: with 128 output tokens against 2048 input, most of each request's decode overlaps its neighbours' prefills. Use sweep 2 for decode capacity.

### Sweep 2 — decode-heavy: 128 prompt / 512 output

Run to separate decode scaling from prefill contention. Stays within the 10-request limit; no errors.

| Concurrency | Decode total | Decode per request | Peak total | TTFT mean | TTFT max |
|---:|---:|---:|---:|---:|---:|
| 1 | 30.0 ± 0.5 | 30.0 | 67 | 0.48 s | 0.83 s |
| 2 | 50.5 ± 1.6 | 26.1 | 115 | 0.63 s | 1.01 s |
| 4 | 70.4 ± 2.6 | 18.5 | 155 | 0.72 s | 0.82 s |
| 8 | 103.8 ± 2.5 | 13.7 | 222 | 0.98 s | 1.03 s |
| 10 | 87.9 ± 2.8 | 15.6 | 288 | 8.09 s | 38.99 s |

### Sweep 3 — context depth, single stream: 2048 prompt / 128 output on top of N tokens of prior context

Cold cache (0 prefix-cache hits on 721,283 prompt tokens), concurrency 1, no errors, 0 preemptions.

| Depth | Total prompt | Prefill tok/s | Decode tok/s (3 runs) | Cold TTFT |
|---:|---:|---:|---:|---:|
| 0 | 2,048 | 1,670 | 28.9 (21.9, 32.9, 31.8) | 1.5 s |
| 8,192 | 10,240 | 1,949 | 29.6 (29.5, 28.4, 30.9) | 5.5 s |
| 32,768 | 34,816 | 1,987 | 31.7 (35.5, 30.4, 29.1) | 17.9 s |
| 131,072 | 133,120 | 1,844 | 27.4 (27.5, 24.3, 30.3) | 72.4 s |

Decode at 131k averages ~10% below the shallower depths, but with three runs and a run-to-run spread of ±3 tok/s that difference is within noise; treat decode as flat to ~130k, not as a measured 10% loss. Speculative-decoding acceptance over this run was 56.3%, the same as at depth 0, so long context does not hurt drafting either.

### Sweep 4 — context depth x concurrency

Run with [`scripts/depth-concurrency.sh`](../scripts/depth-concurrency.sh), in steps, cold cache, 3 runs each. No errors, 0 preemptions. KV usage was sampled every 5 s during each step ([`depthconc-kv-samples.csv`](../data/benchy/depthconc-kv-samples.csv)).

| Step | Tokens in flight | Prefill tok/s (aggregate) | TTFT by finishing order | Decode tok/s, by same order | Peak KV usage |
|---|---:|---:|---|---|---:|
| 1 x 32k (sweep 3) | 35k | 1,987 | 17.9 s | 31.7 | — |
| 2 x 32k | 70k | 1,658 | 26 s, 42 s | **6.0**, 25 | 20.6% |
| 4 x 32k | 139k | 1,512 | 26 s, 53 s, 77 s, 92 s | **1.8, 2.8, 5.9**, 19 | 42.7% |
| 1 x 131k (sweep 3) | 133k | 1,844 | 72 s | 27.4 | — |
| 2 x 131k | 266k | 1,463 | 85 s, 181 s | **1.3**, 23 | 69.5% |

Per-request values were consistent across all three runs of every step (for example 2 x 131k decode: 1.3, 1.2, 1.3 tok/s for the first finisher; 22.1, 23.7, 23.8 for the second).

**Decode starvation.** Prefills are largely serialised, so the first request reaches its first token well before the others — and then has to generate while the others are still prefilling. During that window it gets 1.3–6 tok/s. Only the last request to finish prefill decodes at normal speed. In the 2 x 131k case, the first request's 128 output tokens took ~100 s. benchy's own "total decode throughput" for these steps (2.4–11.9 tok/s) averages over that stall and is not a useful capacity number; the per-request figures above are.

The same effect is present, less visibly, in sweep 1: it is why "decode total" there plateaus at ~70 tok/s while sweep 2 reaches 104.

**KV usage.** Peak usage was 1.9–2.2x what tokens-in-flight / 721,212 predicts (70k → 20.6%, 139k → 42.7%, 266k → 69.5%). The cause was not determined — candidates are per-request state for the DeltaNet layers, block alignment (`mamba_cache_mode=align`), or blocks held by the previous run — but the ratio was stable, so the practical budget is ~380k tokens of concurrent context. A third 131k request would not have fit alongside the two here.

**Monitoring under load.** Two of the script's `/metrics` reads timed out at 10 s during heavy prefill (those samples are blank in the CSV). The API server itself becomes slow to answer while a long prefill is running; health checks with short timeouts could misfire.

### The 8-slot queue

At concurrency 10, per-request TTFT in every run splits 8 / 2:

```
run 1: 0.8 1.1 1.1 1.1 1.1 1.1 1.1 1.1 | 37.0 39.0
run 2: 0.8 0.8 0.8 0.8 0.8 0.8 0.8 0.8 | 37.4 38.3
run 3: 0.8 0.8 0.8 0.8 0.9 0.9 0.9 0.9 | 33.8 35.3
```

37 s is how long 512 tokens take at ~14 tok/s: the last two requests start only when one of the first eight finishes. Sweep 1 shows the same shape (eight at 6–12 s, two at 19–22 s). At concurrency 8 there is no tail at all. This is the signature of vLLM `--max-num-seqs 8`; the value itself was not readable from the endpoint, so confirm it in the recipe's `scripts/serve.sh`.

### Counters during sweep 1

| Counter | Change |
|---|---|
| Preemptions | 0 |
| Prefix-cache hits | 0 of 287,300 (bypass working) |
| Speculative decoding | 8,488 steps, 16,976 drafted, 9,627 accepted = **56.7%** (position 0: 67.6%, position 1: 45.8%) → 2.13 tokens per step |

Lifetime acceptance on real traffic before the benchmark was higher: 64.6% (position 0: 73.6%, position 1: 55.6%), 2.29 tokens per step. The benchmark text is English prose; the production traffic is presumably code, which drafts better. Expect real coding decode speed to be slightly above the figures here.

## Assessment

**Decode.** 30–32 tok/s single-stream, scaling to ~104 tok/s across 8 streams. Scaling efficiency is 84% at 2, 59% at 4, 43% at 8. Peak one-second windows reached 222–288 tok/s, so the engine has some headroom beyond the averages, but 8 slots is where the measured curve ends.

**Prefill.** ~1,740 tok/s alone, 1,250–1,500 tok/s aggregate with 2–8 requests, ~940 tok/s with 10 in flight. Prefill does not get faster with concurrency, so requests queue behind each other's prompts.

**Context depth.** Neither phase degrades meaningfully with depth (see sweep 3), which is what a hybrid that is three-quarters linear attention (Gated DeltaNet) should do and what a pure-attention model would not. Cold time to first token is therefore simply `prompt tokens / ~1,900`. An earlier version of this document extrapolated these figures and warned they would probably be worse; measured, they are not.

**Memory.** No KV pressure at these sizes (0 preemptions). The 721k-token KV pool against a 500k `max_model_len` means two long-context requests cannot coexist; with 8 slots the average budget is ~90k tokens per request. Sweep 4 shows measured usage runs ~2x the token count, so halve those figures in practice: ~380k tokens in flight, ~47k per request across 8 slots.

## Recommendations

### Fix first

1. **Make the two concurrency limits agree.** Done in this repo: `llama-swap.yaml` now sets `concurrencyLimit: 8`, so the 9th request gets an immediate 429 it can retry instead of stalling 20–40 s. It takes effect once that file is copied to the host. Confirm `--max-num-seqs` in the recipe's `serve.sh` and keep the two equal.
2. **To get real 16/32 numbers**, raise both limits (for example `--max-num-seqs 32`, llama-swap limit 32) and re-run sweep 1. On this evidence expect little aggregate gain past 8 in prefill-heavy use, and per-request decode under 10 tok/s.

### Use

3. **Treat big cold prompts as disruptive.** One agent sending a 100k+ uncached prompt stalls every other stream to 1–6 tok/s for a minute or more. Until the scheduler is tuned (item 10), avoid mixing long-context cold starts with interactive sessions, and keep long sessions cache-warm so they rarely pay a full prefill.
4. **Pick concurrency by workload.** Interactive coding agent: 1–2 streams (26–32 tok/s each). Several agents sharing the box: up to 4 (18–20 tok/s each, 70 tok/s total). Batch or offline jobs: 8 (104 tok/s total). Do not run more than 8 clients.
5. **Protect the prefix cache.** It is doing most of the work for agent traffic (85% hits). Keep system prompt and tool definitions byte-stable and first, put volatile content (timestamps, per-turn state) at the end, and avoid rotating many distinct long contexts through the KV pool (~380k tokens usable).
6. **Budget reasoning tokens.** Reasoning is on by default and costs ~30 ms per token; a trivial prompt spent 79 of 144 output tokens on it. For short, latency-sensitive calls send `reasoning_effort: "low"` (the template accepts `low`/`medium`/`xhigh`, with `high`/`max`/`minimal` aliased — see the README), and set `max_tokens` with reasoning in mind.
7. **Set client timeouts for prefill, not decode.** Budget ~0.55 s per 1,000 uncached prompt tokens for a lone request (18 s at 35k, 72 s at 133k), and multiply by the number of requests prefilling at once.

### Tune (each needs an A/B run; none was tested here)

8. **`CTX_LEN` 500k → 262,144, the native window.** Nothing measured here needs more, and sweep 4 shows a single 500k request could not fit in the KV pool anyway (~380k usable). Dropping to native also removes YaRN (factor 4), whose static scaling can cost some short-context quality on Qwen models — not measured here. The README's related idea of also lowering `GPU_MEM` to ~0.72 for page cache needs care: it would roughly halve the KV pool, and at the measured ~2x usage the remainder may not hold one full 262k request. Resolve the 2x question first.
9. **KV capacity.** If long contexts start causing preemptions (`vllm:num_preemptions_total` > 0), the lever to test is `--kv-cache-dtype fp8` (roughly doubles KV tokens; check output quality and hybrid-model support). Do **not** raise `gpu_memory_utilization`: 0.85 and 0.875 have already failed on this box.
10. **`--max-num-batched-tokens` — the most valuable knob to test, given sweep 4.** Running requests decode at 1–6 tok/s while another request prefills a long prompt, which suggests each scheduler step is dominated by a large prefill chunk. A *smaller* per-step token budget should give running requests more decode steps per second, at some cost in prefill throughput and TTFT. For a box shared by several interactive agents that is probably the right trade; for a single user or batch work it is not. Check the current value in the recipe's `serve.sh` and test one step either side.
11. **Speculative decoding: leave at 2 draft tokens.** Position-1 acceptance is already only 46–56%; a third position would likely land under 40% and would cost throughput at higher concurrency. Only worth testing if single-stream latency is the sole goal.

### Not yet measured

- Depth beyond 131k (the window is 500k), and what happens when the KV pool actually fills (3 x 131k would do it): whether vLLM queues, preempts, or the host runs out of memory. Not attempted — it is a production endpoint with a recorded OOM kill on a long prefill at a higher memory setting.
- Why KV usage is ~2x the token count.
- True concurrency above 10 (blocked by the limit).
- Warm-cache TTFT (benchy `--enable-prefix-caching`), which reflects real agent turns better than the cold numbers here.
- The effect of page-cache pressure on the mmapped n-gram table. The README records only ~3 GiB of page cache for a 47.7 GiB table and 4.7–9.3 ms per lookup op; how much decode speed that costs, and whether it varies with uptime, was not measured.
- Code-like text, to see the production speculative-decoding acceptance rate under benchmark conditions.

## Reproduce

```bash
export OPENAI_API_KEY=...   # llama-swap key; never commit it

uvx llama-benchy --base-url http://10.0.1.227:9292/v1 --api-key "$OPENAI_API_KEY" \
  --model qwen3.8-flash-next --tokenizer Qwen/Qwen3.8-Flash-Next \
  --pp 2048 --tg 128 --runs 3 --no-cache --latency-mode generation \
  --concurrency 1 2 4 8 16 32 --format json --save-result sweep-pp2048-tg128.json

uvx llama-benchy ... --pp 128 --tg 512 --concurrency 1 2 4 8 10 \
  --format json --save-result decode-pp128-tg512.json

uvx llama-benchy ... --pp 2048 --tg 128 --depth 0 8192 32768 131072 --concurrency 1 \
  --format json --save-result depth-c1-pp2048-tg128.json
```

vLLM internals are reachable through llama-swap at `/upstream/qwen3.8-flash-next/{metrics,version,v1/models}`.
