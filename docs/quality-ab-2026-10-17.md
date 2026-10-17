# Quality A/B, 2026-10-17: YaRN ×4 at 500k vs native 262k, and client-side fixes

Issue #30. The question was whether serving changes and OpenCode settings improve the
**quality** of agentic-coding output. The kept changes are listed first. Everything here
was measured on this box on 2026-10-17 unless it says otherwise.

| Change | Kept? | Evidence |
|---|---|---|
| Server: YaRN off, native 262,144 (`bin/run-qwen38.sh`) | **yes** | NLL −2.16% (34/42 docs better, p = 6.9e-5); run-to-run noise 0.00%; no regression on HumanEval, tool calls or a 167k needle |
| Client: `limit.context` 262144 + `compaction.reserved` 122144 | **yes** | Required by the server change; the compaction ceiling stays at 140,000 tokens |
| Client: `limit.output` 32,768 → 65,536 | **yes** | On the wire: `max_completion_tokens: 65536`. Low impact: in the 10 days before, 6 requests generated 20k-50k tokens and none more (`vllm:request_generation_tokens_bucket`) |
| Client: `compatibility.reasoningField: "reasoning"` | **yes** | Direct route: already worked, now pinned. **Gateway route: fixed** (earlier reasoning now reaches the model) |
| Client: reviewer subagent with thinking on (`reasoning_effort: low`) | **no** | 59/60 vs 58/60 seeded bugs found, at 2.1× the time and tokens |

## Conditions

- **Box:** the shared DGX Spark, Qwen3.8-Flash-Next `-fp8hybrid`, blazux recipe at `5be66376e8` on the preview vLLM image (`0.1.dev20073`), MTP 2, bf16 KV, prefix caching, priority scheduling, `--long-prefill-token-threshold 1024`.
- **Two states:**
  - **Before:** `YARN=1 CTX=500000`. YaRN factor 4 is applied through `--hf-overrides` and does reach the target model's text config (checked by building vLLM's `ModelConfig` with the same override inside the container). The MTP draft model never gets the override.
  - **After:** `YARN=0 CTX=262144`.
  - One reload between them: 15:35:41-15:49:22 UTC.
- **Traffic:**
  - All requests went to the `qwen3.8-flash-next-batch` alias (priority 10), over loopback on the box through an SSH tunnel.
  - Other consumers kept running throughout: 0-1 of their requests were in flight when checked.
  - Each phase ran in this order:
    1. NLL alone.
    2. Tool suite and HumanEval generation in parallel, 3 requests in flight each.
    3. Needle alone.
    4. Speed alone.
- **Scripts:** `scripts/quality/`. Raw results are in `data/quality/2026-10-17/`. The corpus itself is not committed; `corpus-manifest.json` has every source and its sha256.

## Results

### G2: teacher-forced NLL (the primary gate)
`nll.py` sends each document once to `/v1/completions` with `prompt_logprobs: 0` and scores the mean NLL of the document's own tokens. Every document is over 512 tokens because of vllm#53488. `compare.py nll` runs a paired sign test per document.

```
group    docs   tokens  NLL before  NLL after     delta     rel  better  sign p
all        42   430602     0.21969    0.21495  -0.00474  -2.16%  34/42  6.88e-05
long        6   260673     0.07328    0.06834  -0.00494  -6.74%   6/6    0.0312
medium     16   131930     0.47186    0.46784  -0.00402  -0.85%  14/16  0.00418
short      20    37999     0.34860    0.34270  -0.00590  -1.69%  14/20    0.115
```
Buckets by measured prompt length: short is 988-3,937 tokens, medium 3,624-12,591, long 26,322-60,757. The corpus is CPython 3.14.6 stdlib source plus this repo's own docs and scripts.

**Noise control:** scoring the corpus a second time on the *same* (after) server reproduced 38/42 documents exactly. The overall change was +0.00%, and the largest bucket change was 0.19% (`nll-after2.jsonl`). The 2.16% improvement is therefore the configuration, not run-to-run variation.

### G3: HumanEval pass@1
164 problems, thinking on at `reasoning_effort: low`, T 1.0 / top_p 0.95 / top_k 20, `max_tokens` 8192. Tests ran in `python:3.12-slim` under podman with `--network none`.

| | before | after |
|---|---|---|
| pass@1 | 161/164 | 161/164 |
| discordant | 2 pass only before (97, 145) | 2 pass only after (50, 163) |
| McNemar exact | | p = 1 |

HumanEval/145 after the change hit the 8,192 cap: one runaway thought. HumanEval/38 and /50 fail in this harness whenever the model returns only the decode function, because the encode helper from the prompt is not kept. That affects both states equally.

### G4: tool-call suite
12 coding-agent cases, each run 3 times in 3 modes (OpenAI non-streaming, OpenAI streaming, Anthropic `/v1/messages`), 108 requests per state. The cases cover required and nested arguments, three parallel calls, byte-exact multi-line code, markup and quotes in arguments, a fenced fake `<tool_call>`, and an answer after a tool result.

- Before: 107/108. After: 106/108. McNemar p = 1.
- Every miss in both states was the model choosing a different tool (`grep`/`bash`) at T = 1.0.
- **Zero malformed calls, missing required arguments or parse failures** in either state.

### G5: long context
| | before | after |
|---|---|---|
| needle at depth 0.1 / 0.5 / 0.9 of a 167,251-token prompt | 3/3 found | 3/3 found |
| needle at 297,040 tokens | **found** | not servable |
| 340k-character prompt (over 262,144 tokens) | (served) | HTTP 400 in 1.8 s: "maximum context length is 262144 tokens" |

**What the change gives up:** the old window really did retrieve at about 297k. In the 10 days before, 9 of 12,351 prompts were over 200k tokens (`vllm:request_prompt_tokens_bucket`). The histogram cannot say how many were over 262k. Those now get a 400. OpenCode treats that as an overflow and compacts; other clients see an error.

### G6: speed (sanity check, not a benchmark)
`speed.py`: a unique cold prompt, 256 tokens out, thinking off, T = 0, three runs per size.

| | decode tok/s, ~1.6k prompt | decode tok/s, ~25k prompt | prefill tok/s |
|---|---|---|---|
| before | 28.8 / 30.4 / 31.6 | 31.6 / 31.9 / 32.0 | 957-1,363 |
| after | 39.3 / 38.6 / 38.6 | 40.1 / 42.9 / 23.2 | 1,213-1,466 |

Decode was faster after the change, but **this is not attributed to it**:
- MTP acceptance on the phase traffic was the same: 83.07% vs 83.11% (`vllm:spec_decode_num_accepted_tokens_total` over the phase).
- On this preview build, decode varies by up to 1.83× between restarts (jschmied notes, issue #30).
- It needs several boots to tell apart.

The cause of the single 23.2 reading was not checked.

### Client-side: OpenCode 2.0.32 on the wire
Captured with a logging proxy in front of `opencode run --standalone` (a three-file read task) against copies of the live profile. The proxy never logs the Authorization header.

| Route | Before | After |
|---|---|---|
| direct, earlier reasoning sent back as | `reasoning` (already worked) | `reasoning`, pinned |
| gateway (#27), sent back as | `reasoning_content`, **dropped by the gateway**: +77 prompt tokens per turn | `reasoning`, passes: +174 to +197 per turn |
| `max_completion_tokens` | 32768 | 65536 (OpenCode clips it to the room left in the window) |

- **Probe:** the same three-turn request is 44 prompt tokens with no reasoning field and 124 with `reasoning` or `reasoning_content`, sent directly. Through the gateway it is 124 with `reasoning` but only 44 with `reasoning_content`.
- **Why it matters:** the chat template renders every earlier assistant turn as `<think>{reasoning}</think>`. With nothing replayed, the model sees an empty thought in every past turn.
- **What was not measured:** the task-level effect of the gateway fix. It restores the model card's default behaviour (preserved thinking) rather than adding something new.

### Reviewer variant A/B (rejected)
`review_ab.py`: 20 diffs with one seeded defect each, sent with the OpenCode reviewer's description as the system prompt. Each diff ran once per variant per repeat, 3 repeats.

- The easy set covers off-by-one, SQL injection and unset-variable `rm`, among others.
- The `--set hard` diffs add harmless edits around subtler defects: a binary search that never terminates, an unanchored regex, path traversal, late-binding lambdas, numeric sort in JS, lock-order deadlock, OFFSET without ORDER BY, a cache key missing the locale, float money equality, and `is` on ints.

| | nothink | thinking, `reasoning_effort: low` |
|---|---|---|
| easy set found | 30/30 | 30/30 |
| hard set found | 28/30 | 29/30 |
| median time per review (hard) | 24.4 s | 50.8 s |
| mean completion tokens (hard) | 571 | 1,201 |

One discordant pair in 60. Every miss was read by hand: one regex false-negative was fixed and re-scored, and the remaining misses are real (OFFSET without ORDER BY). On a box where the 8 slots are shared, doubling reviewer time for no measurable detection gain is not worth it, so the reviewer stays non-thinking.

## Not verified
- Task-level agentic success (multi-step SWE-style tasks) under the new settings. HumanEval and the tool suite are proxies.
- Whether the decode speed-up holds across boots.
- Which consumers, if any, sent prompts over 262k in the past. Watch llama-swap logs for 400s during the canary week.
- The FP4-Local checkpoint and the vLLM v0.31 upgrade were out of scope. Both remain open in issue #30.
