# Mixed workload: keeping short clients alive while a long prompt prefills

Plan, research and operator runbook for
[issue #3](https://github.com/DustinTrap/dgx-spark/issues/3). The measurement
harness is [`scripts/mixed-workload.sh`](../scripts/mixed-workload.sh).

**Status: prepared, not measured.** Nothing in this document was run against
the server. Every number below is either quoted from
[performance-assessment.md](performance-assessment.md) (measured 2026-09-19) or
is labelled as a prediction. The harness was exercised only against a local
loopback mock.

## (a) The problem

The box serves several independent consumers at once. While one request
prefills a long cold prompt, requests that are already generating drop from
~30 tok/s to **1-6 tok/s** until that prefill ends - 72 s for a lone cold 133k
prompt, 96 s for the second of two. **That was measured with chunked prefill
already on and `--max-num-batched-tokens 8192`**, which is what the recipe's
`serve.sh` sets; the question is not "enable chunking" but "how much smaller
must a chunk be, and what does that cost". The field effect (issue #3): over a
19-hour window a latency-sensitive client's short requests succeeded 119 of 119
(1-9 s each), but its long reasoning requests - 8-14k output tokens, 230-370 s
when they complete, against a 600 s client timeout - **timed out 25 of 98
times (25.5 %)**, clustered around heavy long-context activity. A ~5-minute
decode has ~5 minutes of slack; three or four cold 100k+ prefills by anyone else
use it all.

### Why 8192 still starves: one decode step per chunk

vLLM's V1 scheduler gives every step one token budget. Running requests are
scheduled first (a decode needs 1 token, 3 with MTP=2), and whatever is left
goes to prefill. So a step during a long prefill is *"every decode, plus one
~8,189-token chunk"* - the decoders are never skipped, but they advance **once
per chunk**, and a chunk takes as long as 8k tokens of prefill take.

That model reproduces the committed data. In the 2 x 131k run the second
prefill ran ~96 s at 1,463 tok/s, i.e. ~17 chunks of 8,192 and therefore ~17
decode steps for the first request. At ~2.2 tokens per step (MTP acceptance)
that is ~38 tokens in 96 s; its remaining ~90 tokens at ~25 tok/s take ~4 s.
Predicted ~100 s for 128 tokens; **measured ~100 s** (1.3 tok/s).

First-order prediction, with a decode-only step at ~73 ms (2.2 tokens / 30
tok/s) and prefill cost linear at 1,850 tok/s:

| Prefill tokens per step | Step time | Victim decode | of 30 tok/s | Prefill rate | Cold 131k TTFT |
|---:|---:|---:|---:|---:|---:|
| 8,192 (today) | 4.5 s | 0.5 tok/s | 2 % | 1,820 tok/s | ~72 s |
| 4,096 | 2.3 s | 1.0 | 3 % | 1,790 | ~73 s |
| 2,048 | 1.2 s | 1.9 | 6 % | 1,740 | ~75 s |
| 1,024 | 0.63 s | 3.5 | 12 % | 1,630 | ~80 s |
| 512 | 0.35 s | 6.3 | 21 % | 1,460 | ~90 s |
| 256 | 0.21 s | 10.4 | 35 % | 1,210 | ~108 s |
| 128 | 0.14 s | 15.5 | 52 % | 900 | ~145 s |

This is a **model, not a measurement**. It ignores fixed per-step overhead
(which makes small chunks cost *more* prefill than shown), the MTP draft passes
inside a mixed step, and whether a mixed prefill+decode step can use CUDA
graphs on this build. What it does say with some confidence: **4096 and 2048 -
the values the issue proposes - cannot get near the 50 % target**; the
interesting region is 128-1,024, and the acceptance target may only be
reachable at roughly double the long-prompt TTFT. The matrix in (d) is built
around that.

## (b) Who shares the box, and what each needs

Generic consumer classes for a multi-tenant inference box. Priority tiers use
vLLM's convention: **lower number = served sooner**, default 0.

| Class | Traffic shape | Needs from the scheduler | Tolerates | Suggested tier |
|---|---|---|---|---:|
| Latency-sensitive periodic client | Small prompt; either a short answer (seconds) or a long steady decode (minutes); **hard client timeout**; low volume | Steady decode rate; bounded TTFT for the short calls | Nothing - a stall is a failed request | **-10** |
| Human chat UI | Short-to-medium prompts, a person watching tokens appear | TTFT of a few seconds; decode that does not visibly freeze | Slower-than-peak decode | **-5** |
| Interactive coding agent | Long prompts (100k+), bursty; mostly prefix-cache hits, occasionally fully cold | Prefill throughput; tolerable cold TTFT (it already waits ~70 s) | +50-100 % on a *cold* TTFT; warm turns are unaffected by chunk size | **0** |
| Batch / background agent | Long or many prompts, nobody waiting | Aggregate throughput only | Queueing, preemption, slow decode | **+10** |

The small clients are many, cheap to serve and brittle; the long-context agents
are few, expensive and patient. A setting is good if it protects the first two
rows without making the third unusable - see (f).

## (c) Research

Installed build: **vLLM `0.1.dev20073+g8e685d198`** (V1 engine; from the base
image `vllm/vllm-openai:qwen38-flash-next` plus the upstream recipe's 13
patches). Commit `8e685d198` is **not present in the public vLLM repository**,
so its scheduler source could not be read. Source-level statements below are
from public vLLM `main` at `e34685df` (2026-09-21) and are marked
*version-dependent* where the installed build could differ. Flag existence on
the installed build was confirmed by the operator from `vllm serve --help=all`.
llama-swap is **v256 (`6701d0d`)**; its statements below are from that tag.

### 1. Chunked prefill and `--max-num-batched-tokens`

- **What it is.** "Maximum number of tokens that can be processed in a single
  iteration" (`vllm/config/scheduler.py`). With `enable_chunked_prefill`, "prefill
  requests can be chunked based on the remaining `max_num_batched_tokens`". In
  V1 chunked prefill is on by default whenever possible
  ([optimization guide](https://docs.vllm.ai/en/latest/configuration/optimization.html)).
- **Current value here: 8192**, set explicitly by the recipe's `serve.sh`
  (`--enable-chunked-prefill --max-num-batched-tokens 8192`), confirmed from the
  live launch flags. `--max-num-seqs` is 8, confirming the assessment's inference.
- **Scheduling order.** The optimization guide: the policy "prioritizes decode
  requests. It batches all pending decode requests before scheduling any prefill
  operations." In source (`vllm/v1/core/sched/scheduler.py`, `schedule()`):
  RUNNING requests are walked in list order while `token_budget > 0`, then
  WAITING requests get what is left. Two consequences, both *version-dependent*:
  1. a decoder admitted **before** a long prefill keeps its slot in every step
     (the mechanism in (a));
  2. a long prefill takes `min(remaining prompt, budget)` - the **whole** budget -
     so a request that arrives **after** it finds `token_budget == 0` and is not
     admitted until that prefill ends. That is the second harm: short requests
     that arrive mid-prefill wait out the whole thing. Consistent with the
     assessment's "prefills are largely serialised" - but **not confirmed for
     short requests**: the field data in (a) shows 119 of 119 short calls
     answered within 9 s, so either they rarely coincided with a cold prefill,
     or block alignment leaves a few tokens of budget that let a short prompt
     trickle in. The harness's `--probe-every` exists to settle this.
- **The trade**, from the same guide: "Smaller values (e.g., 2048) achieve better
  ITL because there are fewer prefills slowing down decodes. Higher values
  achieve better TTFT as you can process more prefill tokens in a batch"; for
  throughput it recommends "> 8192". The guide's 2048 is sized for datacentre
  GPUs where 2,048 tokens prefill in tens of milliseconds; here they take ~1.1 s.
- **`--long-prefill-token-threshold N`** (exists on the installed build). Source:
  in both the running and waiting loops, `if 0 < threshold < num_new_tokens:
  num_new_tokens = threshold`. It is a **per-request, per-step cap**: one long
  prompt contributes at most N tokens to a step, and the rest of the budget
  stays available - to decoders listed after it, and to **new arrivals**. So it
  fixes consequence 2 as well as 1, which lowering `--max-num-batched-tokens`
  alone does not (a prefill still takes the whole, smaller, budget). With k long
  prompts prefilling at once a step carries ~`min(k x N, max-num-batched-tokens)`
  prefill tokens, so the batch budget becomes the multi-aggressor ceiling.
- **`--max-num-partial-prefills`, `--max-long-partial-prefills`: not available**
  in the installed build (operator-confirmed), and absent from public `main`'s
  scheduler config. They belonged to the retired V0 scheduler. Not in the matrix.
- **Speculative decoding (MTP=2).** Each decoding request consumes `1 + 2`
  tokens of the budget per step, so 8 decoders take 24; the scheduler keeps a
  separate `max_num_scheduled_tokens` that "can be smaller [than
  max_num_batched_tokens] in cases when the model might append tokens into the
  batch (such as speculative decoding)". No incompatibility between chunked
  prefill and MTP was found. Whether the draft passes make a mixed step
  materially slower than the model in (a) assumes: **not determined**.
- **Hybrid / Gated DeltaNet layers.** This deployment reports
  `mamba_cache_mode="align"`, `mamba_block_size=16`, `block_size=8`. In that mode
  (`_mamba_block_aligned_split`) "chunk ends must be block aligned", and a
  request is **skipped for the step** when there is "insufficient budget for a
  block-aligned chunk" (or, with MTP, to keep a chunk "out of the
  prefill-lookahead window"). Practical rule: use chunk sizes that are multiples
  of 64 and no smaller than 128. Whether tiny chunks hurt the DeltaNet
  chunked-scan kernels disproportionately: **not determined** - the harness
  measures it as "prefill tok/s lost".
- **Side effects of changing `--max-num-batched-tokens` itself** (not the
  threshold): it is part of vLLM's compile-cache key ("max_num_batched_tokens
  need to be included in the hash"), so the first boot at each new value
  recompiles (upstream quotes ~80 s extra); and the memory-profiling run is
  sized by it, so a smaller value leaves slightly more of the fixed
  `GPU_MEM=0.80` share for KV. `--long-prefill-token-threshold` has neither side
  effect, which is one more reason to sweep it first.
- **A metrics trap.** `vllm:iteration_tokens_total` looks like it should reveal
  the chunk size. It does not: V1 adds a request's whole prompt length to the
  step in which its **first token** appears (`IterationStats.update_from_output`,
  `if is_prefilling`). The committed snapshots show eight steps over 16,384
  tokens for exactly that reason, with chunking at 8,192.

### 2. Priority scheduling

- **Exists on the installed build**: `--scheduling-policy {fcfs,priority}`,
  default `fcfs`. Semantics (`vllm/config/scheduler.py`): "requests are handled
  based on given priority (lower value means earlier handling) and time of
  arrival deciding any ties". V1 support is documented in the
  [V1 guide](https://docs.vllm.ai/en/latest/usage/v1_guide.html).
- **Per-request field**: integer `priority` in the JSON body of
  `/v1/chat/completions` and `/v1/completions`, default 0. Public `main` also
  accepts an `X-Vllm-Priority` header that overrides the body; whether the
  installed build has the header: **not determined**. The
  [server docs](https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html)
  state "Non-zero priorities require the server to use priority scheduling" -
  so **a client must not send a non-zero `priority` while the server runs
  `fcfs`**. The exact failure (expected: HTTP 400) on this build: **not determined**.
- **What it changes** (source, *version-dependent*): (1) the waiting queue
  becomes a heap ordered by `(priority, arrival_time)`; (2) when KV blocks run
  out, the request preempted is `max(running, key=(priority, arrival_time))` -
  the least important, newest one - instead of simply the last in the list.
  Preemption happens **only on KV shortage**; a high-priority arrival does not
  evict or pause a running prefill. A preempted request is recomputed from
  scratch, so for a 131k agent that is another full cold prefill.
- **What it does not change**: the composition of a step. It does not make
  chunks smaller and does not reorder already-running requests. **Prediction:
  priority alone does not help a decoding victim at all**, and helps a
  late-arriving short request only when two or more long prompts are queued (it
  jumps ahead of the *waiting* ones, but still waits out the one already
  prefilling). Combined with `--long-prefill-token-threshold`, the leftover
  budget in every step is handed out in priority order, so the two are
  complementary. With all priorities equal the policy degenerates to FCFS, so
  it is free to switch on in every candidate restart.
- **No aging.** A steady stream of high-priority work can starve tier +10
  indefinitely. Acceptable here because the high tiers are low-volume.
- **llama-swap forwards it.** v256 `internal/server/filters.go` treats the body
  as raw bytes and edits only named keys (`model`, plus whatever
  `filters.stripParams` / `setParams` / `setParamsByID` name) with `sjson`; this
  repo's `llama-swap.yaml` configures no filters, so unknown fields such as
  `priority` reach vLLM unchanged. Two useful corollaries: `setParamsByID` with
  a `"priority?"` key can assign a default tier per model alias for clients that
  cannot send the field; and `stripParams: "priority"` is the safety net if the
  server is ever rolled back to `fcfs` while a client still sends it.
- **`--async-scheduling`** exists on the installed build. It overlaps CPU
  scheduling with GPU work; it does not change chunk sizes. Interaction with
  MTP on this build: **not determined**. Out of scope for this matrix.

### 3. What can change without a reload

| Change | Reload? |
|---|---|
| Any vLLM flag above (`--max-num-batched-tokens`, `--long-prefill-token-threshold`, `--scheduling-policy`) | **Yes.** They are `SchedulerConfig` fields fixed at engine start; no runtime endpoint changes them. ~13 min each. |
| Per-request `priority` values | No - per request, once the policy is `priority` |
| llama-swap `filters` (tier by alias, strip) | No model reload in principle, **but see the trap below** |
| `concurrencyLimit` in `llama-swap.yaml` | Same trap |

**Trap: editing the live `llama-swap.yaml` is a restart.** The service runs with
`-watch-config`; v256's reload handler builds a new server and calls
`old.Shutdown(30s)` on the old one, which stops its processes - i.e. the model -
and the `preload` hook then starts a fresh 13-minute load. Whether the new
preload can race the old container's `docker stop`: **not determined**, which is
why the runbook stops the service first instead of relying on the watcher.

### 4. Version notes

- vLLM: `0.1.dev20073+g8e685d198`, a preview build; recorded in
  `data/endpoint/vllm-version.json`. Record it again in every result file (the
  harness does).
- Everything marked *version-dependent* can be settled read-only on the host:

  ```bash
  docker exec qwen38-flash sh -c 'grep -n "long_prefill_token_threshold\|PRIORITY" \
    "$(python3 -c "import vllm,os;print(os.path.dirname(vllm.__file__))")"/v1/core/sched/scheduler.py | head -20'
  ```

  (Importing `vllm` for the path costs a few hundred MB of host RAM for a moment;
  on a box with ~2 GB free, prefer `find / -name scheduler.py -path "*v1/core*"`.)

## (d) Test matrix

**Workloads** (harness arguments), run at every configuration:

| ID | What | Arguments | Est. time at baseline |
|---|---|---|---|
| W1 | **Acceptance shape**: victim + one cold 131k | `--aggressors 1 --depth 131072 --probe-every 10` | ~6 min |
| W2 | **Field shape**: victim + three cold 100k, 45 s apart | `--aggressors 3 --depth 100000 --spacing 45 --probe-every 10` | ~8 min |
| W1p / W2p | Same, victim and probes at tier -10 | add `--priority -10` | same |

W2 keeps at most ~2-3 x 100k in flight, inside the ~380k usable KV; the harness
refuses shapes that are not. Do **not** add a 3 x 131k-at-once case: it would
fill the pool, and this box has been OOM-killed on a long prefill.

**Configurations**, grouped so that one restart answers as many questions as
possible. `EXTRA` is appended after the recipe's own flags.

| Step | Restart? | `EXTRA` | Runs | Answers |
|---|---|---|---|---|
| **C0** baseline | **no** | *(none: 8192, fcfs)* | W1, W2 | Reproduces the problem with this harness; the reference for every ratio |
| **C1** | yes | `--scheduling-policy priority --long-prefill-token-threshold 1024` | W1, W1p, W2, W2p | First point on the chunk curve; does the threshold admit late short requests (probe TTFT); does priority add anything on top (W1 vs W1p) |
| **C2** | yes | `--scheduling-policy priority --long-prefill-token-threshold 256` | W1, W2 (+W2p if C1 showed a priority effect) | Second point. C0+C1+C2 fit `step time = a + b x chunk`, which replaces the model in (a) with this box's real curve |
| **C3** | yes | `--scheduling-policy priority --long-prefill-token-threshold T*` with `T*` read off the fitted curve (multiple of 64, >= 128) | W1, W2, W2p | The candidate. Apply the decision rule (f) |
| **C4** *(only if W2 at C3 is much worse than W1)* | yes | C3 plus `--max-num-batched-tokens` = 2 x T* to 4 x T* | W2, W2p | Caps the several-agents-prefilling-at-once case, where steps grow to k x T* |

Three restarts expected, four at most: ~40 min of loading plus ~25 min of runs
per step, **about 3-3.5 hours of announced window**, during which the endpoint
is either reloading or deliberately congested.

Deliberately **not** in the matrix: `--max-num-batched-tokens` 4096 / 2048 on
their own (the issue's original sweep) - the model in (a) puts them at 3-6 % and
a lowered batch budget alone does not fix late-arrival starvation. If C1's
measured point contradicts the model, put them back. `--max-num-partial-prefills`
/ `--max-long-partial-prefills`: not in this build.

**Expected direction and explicit cost**

| Metric (harness field) | C0 -> smaller chunks | Priority on top |
|---|---|---|
| Victim tok/s while an aggressor prefills (`tok_per_s_while_aggressors_prefill`) | **up**, roughly 1/chunk until the ~73 ms decode step dominates | no change predicted |
| Victim wall time (`victim.wall_s`) | **down** toward tokens/30 | no change predicted |
| Probe TTFT (`probes[].ttft`) | **down sharply** with a threshold (from "until the prefill ends" to about one step) | **down** further when several long prompts are queued |
| Aggressor TTFT, cold (`aggressors[].ttft`) | **up - this is the price**: predicted +10 % at 1024, +50 % at 256, +100 % at 128; real figures likely worse at the small end | up slightly for tier 0 when tier -10 work is queued |
| Effective prefill tok/s (`prefill_tok_per_s_effective`) | **down** by the same factor | - |
| Warm (prefix-cached) agent turns | unaffected: a cached turn prefills only its new tokens, usually under any threshold here | - |
| Preemptions / KV usage (`-kv-samples.csv`) | unchanged; slower prefills hold KV longer, so peak concurrent context can rise | preemption victim becomes the lowest tier |
| Aggregate decode, single-stream decode | unchanged (no prefill in the step) | unchanged |

## (e) Operator runbook

Commands run **on the host** unless marked *client*. `<spark-ip>` stays a
placeholder here; pass the real address on the command line only.

**0. Announce.** Tell every user of the box: start time, ~3.5 h, "the endpoint
will be down for ~13 min several times and slow in between; long-running
requests will fail". Wait for in-flight work to drain. The harness refuses to
start while other requests are running.

**1. Dry-run the harness** (*client*, contacts nothing):

```bash
scripts/mixed-workload.sh --base-url http://<spark-ip>:9292 --dry-run
scripts/mixed-workload.sh --base-url http://<spark-ip>:9292 --dry-run \
  --aggressors 3 --depth 100000 --spacing 45 --probe-every 10
```

**2. Snapshot the current state.**

```bash
SNAP=~/ai-stack/snapshots/$(date +%Y%m%d-%H%M); mkdir -p "$SNAP"
cp ~/ai-stack/llama-swap.yaml "$SNAP/llama-swap.yaml"
docker inspect qwen38-flash --format '{{json .Args}}' > "$SNAP/vllm-args.json"
docker logs qwen38-flash 2>&1 | grep -m3 -E 'Chunked prefill is enabled|scheduling|non-default args' > "$SNAP/vllm-startup.txt"
free -g > "$SNAP/mem.txt"; swapon --show >> "$SNAP/mem.txt"
grep -n 'max-num-batched-tokens\|EXTRA' ~/ai-stack/qwen38-flash/scripts/serve.sh
```

Expect `--max-num-batched-tokens 8192` and an `EXTRA` that is appended after it.
Note the swap figure: it is the baseline for the stop-list.

**3. C0 - baseline, no restart** (*client*):

```bash
export OPENAI_API_KEY=...            # never commit it; do not use `set -x`
CFG='mnbt=8192 threshold=0 policy=fcfs'
scripts/mixed-workload.sh --base-url http://<spark-ip>:9292 --label c0 --server-config "$CFG" \
  --aggressors 1 --depth 131072 --probe-every 10 --i-have-announced-this-window
scripts/mixed-workload.sh --base-url http://<spark-ip>:9292 --label c0 --server-config "$CFG" \
  --aggressors 3 --depth 100000 --spacing 45 --probe-every 10 --i-have-announced-this-window
```

Check between runs: exit code 0, `preemptions during run: 0`, memory as in step 5.

**4. Apply a configuration (C1, C2, ...).** The flags travel as the recipe's
`EXTRA` variable through a llama-swap `env:` entry; `bin/run-qwen38.sh` passes
its environment to `serve.sh` untouched, and llama-swap appends `env` to the
inherited environment. Stop the service **before** editing, so the file watcher
cannot trigger a second, racing restart:

```bash
systemctl --user stop llama-swap.service      # ExecStopPost removes the container
docker ps -a --filter name=qwen38-flash       # expect: nothing
```

Edit `~/ai-stack/llama-swap.yaml`, under `models: "qwen3.8-flash-next":`

```yaml
    env:
      - "EXTRA=--scheduling-policy priority --long-prefill-token-threshold 1024"
```

```bash
~/.local/bin/llama-swap -config ~/ai-stack/llama-swap.yaml -validate   # parse check only
systemctl --user start llama-swap.service
docker logs -f qwen38-flash                   # ~13 min; ready at "Application startup complete"
```

**5. Verify before measuring.**

```bash
docker inspect qwen38-flash --format '{{json .Args}}' | tr ',' '\n' | grep -A1 -E 'threshold|scheduling|batched'
docker logs qwen38-flash 2>&1 | grep -E 'Chunked prefill is enabled|long_prefill|priority'
curl -s -H "Authorization: Bearer $LLM_API_KEY" http://127.0.0.1:9292/v1/models | head -c 200
free -g; swapon --show
```

The new flags must appear in the container args. If `--max-num-batched-tokens`
was passed twice (C4), confirm in the startup log that the **second** value won.
Then one tiny request with a priority, to prove the field survives llama-swap
and is accepted (*client*, negligible load):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<spark-ip>:9292/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next","priority":-10,"reasoning_effort":"low",
       "messages":[{"role":"user","content":"Say OK"}],"max_tokens":8}'
# expect 200 under --scheduling-policy priority
```

**6. Measure** (*client*): the four runs of the matrix row, e.g. for C1

```bash
CFG='mnbt=8192 threshold=1024 policy=priority'
for P in "" "--priority -10"; do
  # $P is deliberately unquoted: it is either nothing or two words
  scripts/mixed-workload.sh --base-url http://<spark-ip>:9292 --label "c1${P:+p}" --server-config "$CFG" \
    --aggressors 1 --depth 131072 --probe-every 10 $P --i-have-announced-this-window
  scripts/mixed-workload.sh --base-url http://<spark-ip>:9292 --label "c1${P:+p}" --server-config "$CFG" \
    --aggressors 3 --depth 100000 --spacing 45 --probe-every 10 $P --i-have-announced-this-window
done
```

Small-chunk configurations prefill more slowly; if the harness refuses because
the estimate exceeds `--max-duration`, pass a realistic `--assumed-prefill-tps`
rather than simply raising the cap.

**7. Record.** After each configuration, copy the one-line summaries into the
results table of issue #3. Commit `data/benchy/mixed-*` by name. Before
committing, `git grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' data/benchy/mixed-*`
must print nothing - the harness never writes the base URL, keep it that way.

**8. Stop immediately if** (any one):

- **Swap climbing.** It sits at ~5-6 GiB and flat. Growth of more than ~1 GiB
  during a configuration, or steady growth across two samples a minute apart, is
  the runaway pattern that preceded the 0.85 failure.
- **Free memory collapsing.** The box idles at ~114 of 121 GiB used with ~2 GiB
  free and ~6 GiB of page cache. `available` under ~1 GiB, or page cache pushed
  well below its idle level (the mmap'd n-gram table lives there), means stop.
- **OOM kill**: `docker inspect qwen38-flash --format '{{.State.OOMKilled}}'` is
  `true`, or the container exited.
- **KV preemptions**: `preemptions during run` non-zero, or `kv_cache_usage`
  above ~0.85 in the samples CSV. A preempted 100k request recomputes from zero
  and the run stops meaning anything.
- `/health` fails, or the harness exits 3 (hit `--max-duration`).
- Startup does not reach "Application startup complete" in 20 min (bad flag:
  `serve.sh` prints the last log lines and exits).
- Anyone reports they were not told.

**9. Roll back** (also the answer to every stop condition):

```bash
systemctl --user stop llama-swap.service
cp "$SNAP/llama-swap.yaml" ~/ai-stack/llama-swap.yaml
systemctl --user start llama-swap.service     # ~13 min
docker inspect qwen38-flash --format '{{json .Args}}' | diff - "$SNAP/vllm-args.json" && echo "args identical to snapshot"
```

If any client was taught to send `priority` during the window, either it stops
before the rollback or the rolled-back `llama-swap.yaml` gains
`filters: { stripParams: "priority" }` - under `fcfs` a non-zero priority is
rejected.

**10. Keep or restore, then write it down.** If a configuration passes (f):
leave it running, commit the `env:` block to this repo's `llama-swap.yaml`,
record the setting with its numbers under README "Configuration decisions", move
the starvation item out of "Known issues", and add the tier table from (b) to
"Connecting agents". If none passes: roll back, and record the measured curve in
the README so the next attempt starts from data. Announce the end of the window
either way.

## (f) Decision rule

**Acceptance (issue #3):** with one cold 131k prefill running (W1), the victim
keeps **>= ~50 %** of its own same-run single-stream rate -
`victim.fraction_of_baseline_kept >= 0.5`. Today: 3-20 %.

Because the model in (a) says 50 % may cost a doubling of cold TTFT, decide in
this order:

1. **Disqualify** any configuration that produced preemptions, swap growth, an
   error, or a 429.
2. **Operational floor - what actually stops the timeouts.** In W2 (three cold
   100k prompts during one long decode) the victim's wall time must stay under
   **450 s** for 8,192 tokens - 75 % of the 600 s client timeout, leaving room
   for a 14k-token answer at the same ratio - and probe TTFT must stay under
   **10 s** at the median and 30 s at the maximum.
3. **Ceiling for the long-context agents.** Cold 131k TTFT no worse than
   **2x baseline (~145 s)**, and no worse than 2.5x in W2. Past that a coding
   agent's own client timeouts start to fire and the fix has only moved the
   failure. Warm turns are unaffected by chunk size, and warm turns are 85 % of
   agent traffic - which is why a 2x cost on the cold path is a fair price.
4. Among configurations passing 2 and 3, **take the one with the largest chunk**
   (least prefill throughput lost). If it also meets the 50 % acceptance figure,
   close the issue. If 2 and 3 pass but 50 % does not, keep the setting, record
   the measured fraction, and put the choice between "accept N %" and "pay more
   TTFT" to the issue with the curve attached - do not quietly trade the
   long-context agents away for a round number.
5. **Priority**: switch clients to the tiers in (b) only if W1p/W2p measurably
   beat W1/W2. If they do not, leave the policy at `priority` (it is inert with
   equal priorities) but do not ask clients to send the field.

**Fairness note.** The many small clients cannot protect themselves: they cannot
make their requests cheaper, and a stall is a hard failure for them. The
long-context agents can - by staying cache-warm - and for them a slower cold
prefill is a delay, not a failure. So the setting should lean toward the small
clients, up to the point in rule 3 where a delay becomes a failure for the
agents too. That point, not the 50 % figure, is the real constraint.

## Not determined

- Whether the installed build's scheduler matches public `main` on the two
  behaviours the predictions rest on (running-first budget order; threshold
  applied per request per step).
- The real fixed cost of a small mixed step on this hardware (MTP drafts, MoE
  with 512 experts, DeltaNet chunked scan, CUDA-graph eligibility) - i.e.
  whether 50 % is reachable at all within a 2x TTFT.
- Whether the installed build accepts the `X-Vllm-Priority` header, and its
  exact response to a non-zero `priority` under `fcfs`.
- Whether llama-swap's watcher-triggered reload can race the old container's
  shutdown (avoided by stopping the service first).
- Whether a duplicated `--max-num-batched-tokens` on the command line resolves
  to the last value on this build (expected; verify in the startup log, C4 only).
- Interaction of `--async-scheduling` with MTP on this build.
- Why KV usage runs ~2x the token count (inherited open question; it sets the
  `--kv-budget` default).
