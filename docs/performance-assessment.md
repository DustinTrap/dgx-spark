# Qwen3.8-Flash-Next on `10.0.1.227:9292` — performance assessment

Measured 2026-09-19 from a LAN client (macOS) with [llama-benchy](https://github.com/eugr/llama-benchy) 0.4.0.
Raw data: [`data/endpoint/`](../data/endpoint) (config and metrics snapshots), [`data/benchy/`](../data/benchy) (benchmark output).

## Summary

- Single stream: **~1,740 tok/s prefill, ~30–32 tok/s decode**, 1.4 s to first token on a cold 2k prompt.
- Aggregate decode scales **3.5x, to ~104 tok/s at 8 concurrent**, while per-request speed falls to ~14 tok/s.
- **Concurrency 16 and 32 could not be measured.** llama-swap rejects everything past 10 in-flight requests with HTTP 429, so those two sweep rows are really concurrency 10.
- **Two limits disagree.** llama-swap admits 10; vLLM runs only 8 at once (inferred from queueing, see below). Requests 9 and 10 are accepted and then wait silently — up to 39 s to first token.
- **Prefill is the bottleneck for this box.** Time to first token grows linearly with the total prompt tokens in flight: 8 cold 2k prompts means ~10.5 s each. The prefix cache (85% lifetime hit rate) is what makes agent workloads usable.
- No preemptions and no errors other than the 429s.

## Endpoint configuration (as observed)

| Item | Value |
|---|---|
| Front end | llama-swap, API key required, `/health` open. One model, TTL 0 (never unloaded) |
| Host | DGX Spark, 121 GB unified memory. ~75 GiB of weights resident; the 48 GiB n-gram table is mmapped from NVMe (see [`bin/run-qwen38.sh`](../bin/run-qwen38.sh)) |
| llama-swap concurrency limit | 10. Not set in [`llama-swap.yaml`](../llama-swap.yaml), so this is llama-swap's default. Observed: exactly `N − 10` requests rejected at N = 16 and 32 |
| Backend | vLLM `0.1.dev20073+g8e685d198`, launched by `~/ai-stack/bin/run-qwen38.sh`, port 10001 |
| Model | `nvidia/Qwen3.8-Flash-Next-NVFP4`, `fp8hybrid` snapshot; hybrid attention/Mamba MoE. llama-swap description: 125B main + 51B n-gram, 6B active |
| `max_model_len` | 500,000 (`CTX_LEN` default in the launch script, with `YARN=1`) |
| KV cache | 721,212 tokens → 1.44 full-length requests. `cache_dtype=auto`, block size 8, Mamba block size 16 |
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

**Prefill.** ~1,740 tok/s alone, 1,250–1,500 tok/s aggregate with 2–8 requests, ~940 tok/s with 10 in flight. Prefill does not get faster with concurrency, so requests queue behind each other's prompts. Cold-prompt cost at the single-stream rate, extrapolated (long-context prefill was **not** measured and usually slows with depth):

| Cold prompt | Estimated TTFT |
|---:|---:|
| 8k | ~5 s |
| 32k | ~18 s |
| 128k | ~75 s or more |
| 500k | ~5 min or more |

**Memory.** No KV pressure at these sizes (0 preemptions). The 721k-token KV pool against a 500k `max_model_len` means two long-context requests cannot coexist; with 8 slots the average budget is ~90k tokens per request.

## Recommendations

### Fix first

1. **Make the two concurrency limits agree.** Add `concurrencyLimit: 8` under the `qwen3.8-flash-next` model in `llama-swap.yaml` so the 9th request gets an immediate 429 it can retry. (The alternative, raising vLLM's `--max-num-seqs` to 10+, means changing the recipe's launcher, which `run-qwen38.sh` deliberately does not reimplement.) Today requests 9–10 are accepted and then stall for 20–40 s, which looks like a hang to an agent client.
2. **To get real 16/32 numbers**, raise both limits (for example `--max-num-seqs 32`, llama-swap limit 32) and re-run sweep 1. On this evidence expect little aggregate gain past 8 in prefill-heavy use, and per-request decode under 10 tok/s.

### Use

3. **Pick concurrency by workload.** Interactive coding agent: 1–2 streams (26–32 tok/s each). Several agents sharing the box: up to 4 (18–20 tok/s each, 70 tok/s total). Batch or offline jobs: 8 (104 tok/s total). Do not run more than 8 clients.
4. **Protect the prefix cache.** It is doing most of the work for agent traffic (85% hits). Keep system prompt and tool definitions byte-stable and first, put volatile content (timestamps, per-turn state) at the end, and avoid rotating many distinct long contexts through the 721k-token pool.
5. **Budget reasoning tokens.** Reasoning is on by default and costs ~30 ms per token. For short, latency-sensitive calls, turn it off per request if the chat template supports it (Qwen convention: `chat_template_kwargs: {"enable_thinking": false}` — not verified against this model), and set `max_tokens` with reasoning in mind.
6. **Set client timeouts for prefill, not decode.** A cold 32k prompt behind other traffic can take well over 20 s to produce a first token.

### Tune (each needs an A/B run; none was tested here)

7. **`CTX_LEN` 500k → what you actually use** (for example `CTX_LEN=262144`). This does not enlarge the KV pool, but it stops one request from being allowed to take 70% of it, and it raises vLLM's guaranteed concurrency figure. The 500k window relies on `YARN=1`; static YaRN scaling can cost some short-context quality on Qwen models, so if nothing needs more than the native window it is worth checking whether the recipe can run without it. Not measured here.
8. **KV capacity.** If long contexts start causing preemptions (`vllm:num_preemptions_total` > 0), the lever to test is `--kv-cache-dtype fp8` (roughly doubles KV tokens; check output quality and hybrid-model support). Do **not** raise `gpu_memory_utilization`: 0.85 and 0.875 have already failed on this box.
9. **`--max-num-batched-tokens`.** Aggregate prefill drops from 1,740 to ~940 tok/s as concurrency rises. A larger per-step token budget may recover prefill throughput at the cost of decode latency for running requests; a smaller one does the reverse. Check the current value in the recipe's `serve.sh` and test one step either side.
10. **Speculative decoding: leave at 2 draft tokens.** Position-1 acceptance is already only 46–56%; a third position would likely land under 40% and would cost throughput at higher concurrency. Only worth testing if single-stream latency is the sole goal.

### Not yet measured

- Decode and prefill speed at context depth (`--depth 8192 32768 131072`). This matters most for coding agents and is the natural next run.
- True concurrency above 10 (blocked by the limit).
- Warm-cache TTFT (benchy `--enable-prefix-caching`), which reflects real agent turns better than the cold numbers here.
- Whether page-cache pressure on the mmapped n-gram table affects decode speed over long uptimes or after other I/O-heavy work.
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
```

vLLM internals are reachable through llama-swap at `/upstream/qwen3.8-flash-next/{metrics,version,v1/models}`.
