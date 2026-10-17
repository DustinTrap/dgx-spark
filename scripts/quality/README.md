# Quality A/B scripts

Paired before/after checks for a serving or client change. First used for issue #30
([docs/quality-ab-2026-10-17.md](../../docs/quality-ab-2026-10-17.md)). Every script takes
`--base` (the endpoint, e.g. `http://127.0.0.1:9292`) and `--key-file` (a file that holds one
consumer key). By default they send to the `qwen3.8-flash-next-batch` alias, so other consumers
keep their place in the queue. They still load the box, so run them only in an announced window
(AGENTS.md §2).

| Script | What it measures | Cost on this box |
|---|---|---|
| `build_corpus.py` | Builds the fixed NLL corpus (CPython stdlib + this repo) and a sha256 manifest | none |
| `nll.py` | Teacher-forced per-token NLL via `prompt_logprobs` | ~7 min for ~430k tokens |
| `toolcalls.py` | Tool-call correctness, OpenAI (stream and not) + `/v1/messages` | ~5 min at 3 in flight |
| `humaneval.py` | HumanEval pass@1; generated code runs in a network-less container | ~25 min at 3 in flight |
| `needle.py` | Retrieval at depth in a long prompt; `--over N` expects a clean 400 | ~2 min per 167k prefill |
| `speed.py` | Cold prefill and decode, single stream (a sanity check, not a benchmark) | ~2 min |
| `review_ab.py` | Reviewer-variant A/B on seeded-bug diffs (`--set hard` for subtler ones) | ~15 min |
| `compare.py` | Paired comparison: sign test for NLL, exact McNemar for pass/fail | none |

Run every script once before the change and once after, with the same corpus and order.
Then re-run `nll.py` on the *same* server to measure the noise floor before attributing a
difference to the change.
