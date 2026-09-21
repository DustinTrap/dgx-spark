#!/usr/bin/env bash
# Mixed-workload test: one steady "victim" decode stream while N cold
# long-context "aggressor" prefills arrive. Sibling of depth-concurrency.sh.
#
# It answers one question: how much of its single-stream decode speed does a
# request that is already generating keep while somebody else's long cold
# prompt is being prefilled - and what does protecting it cost the long prompt
# in time to first token? See docs/mixed-workload-plan.md for the test matrix
# and the operator runbook this script is one step of.
#
# THIS SCRIPT IS THE HARM IT MEASURES. The endpoint is shared; a cold 131k
# prefill stalls every other stream on the box for a minute or more. So:
#   - --dry-run prints the exact request plan and the estimated load and
#     contacts nothing.
#   - Without --i-have-announced-this-window it refuses to send any request.
#   - --max-duration is a hard cap; when it expires every connection is closed
#     (vLLM aborts a request whose client went away) and the run exits 3.
#   - It refuses to start if other requests are already running on the server
#     (they would be harmed, and they would contaminate the numbers).
#   - It never restarts, reconfigures or otherwise touches the server.
#
# While the run is in flight, vLLM's KV usage, running/waiting counts and
# preemption counter are sampled to data/benchy/mixed-<tag>-kv-samples.csv,
# exactly as depth-concurrency.sh does.
#
# The bearer token is read from OPENAI_API_KEY. It is never printed, never
# written to a file, and never put on a command line (curl gets it on stdin,
# python reads it from the environment). Do not run this under `set -x`.
#
# Usage:
#   scripts/mixed-workload.sh --base-url http://<spark-ip>:9292 --dry-run
#   OPENAI_API_KEY=... scripts/mixed-workload.sh --base-url http://<spark-ip>:9292 \
#       --label baseline --server-config 'mnbt=8192 policy=fcfs' \
#       --i-have-announced-this-window
set -euo pipefail

MODEL=qwen3.8-flash-next
BASE_URL=""
LABEL=run
SERVER_CONFIG="not recorded"
VICTIM_TOKENS=8192
AGGRESSORS=1
DEPTH=131072
SPACING=0
WARMUP=20
AGG_TOKENS=16
PROBE_EVERY=0
PRIORITY=""
MAX_DURATION=1500
SAMPLE_EVERY=5
TOKENS_PER_WORD=""
ASSUMED_DECODE_TPS=30
ASSUMED_PREFILL_TPS=1850
KV_BUDGET=380000
SLOTS=8
DRY_RUN=0
ANNOUNCED=0
ALLOW_BUSY=0
ALLOW_KV_PRESSURE=0

usage() {
  cat <<'EOF'
mixed-workload.sh - one victim decode stream vs N cold long-context prefills

Required:
  --base-url URL          llama-swap endpoint, e.g. http://<spark-ip>:9292
                          (no default on purpose; never written to any output file)
  OPENAI_API_KEY          environment variable holding the bearer token
                          (not needed for --dry-run)

Safety:
  --dry-run               print the request plan + estimated load; contact NOTHING
  --i-have-announced-this-window
                          required to send any request. The box is shared and
                          this test stalls every other client while it runs.
  --max-duration SEC      hard cap on the whole run (default 1500). On expiry all
                          connections are closed and the script exits 3.
  --allow-busy            start even if the server already has running/waiting
                          requests (default: refuse - those are other people)
  --allow-kv-pressure     skip the KV-budget and slot-count refusals

Workload:
  --victim-tokens N       victim output tokens, ignore_eos (default 8192)
  --aggressors N          number of cold long prompts (default 1)
  --depth TOKENS          target prompt size of each aggressor (default 131072)
  --spacing SEC           gap between aggressor arrivals (default 0 = all at once)
  --warmup SEC            victim decodes alone this long first; this window is
                          the run's own single-stream baseline (default 20)
  --aggressor-tokens N    output tokens per aggressor (default 16)
  --probe-every SEC       also send a short latency probe (small prompt, 16
                          tokens out) every SEC while aggressors prefill; 0 = off
  --priority N            add "priority": N to the victim's and the probes'
                          request bodies (lower = served sooner). Aggressors are
                          always sent without the field. Needs a server started
                          with --scheduling-policy priority; see the plan.

Bookkeeping:
  --label NAME            tag for output files (default "run")
  --server-config TEXT    free text stored in the JSON: what the server was
                          started with for this run (the script cannot see it)
  --model NAME            default qwen3.8-flash-next
  --sample-every SEC      server metrics sampling period (default 5)
  --tokens-per-word X     skip the 1-request calibration and assume X
  --assumed-decode-tps X  for estimates only (default 30)
  --assumed-prefill-tps X for estimates only (default 1850)
  --kv-budget TOKENS      refuse if estimated concurrent context exceeds this
                          (default 380000 - the measured usable figure)
  --slots N               refuse if more requests than this would be in flight
                          (default 8 - keep equal to llama-swap concurrencyLimit)
  -h, --help

Output (relative to the repo): data/benchy/mixed-<label>-n<N>-d<depth>.json,
.summary.txt and -kv-samples.csv.

Exit codes: 0 ok, 1 usage/refusal/pre-flight failure, 2 request failures,
3 --max-duration reached.
EOF
}

die() { echo "mixed-workload: $*" >&2; exit 1; }
need_val() { [ $# -ge 2 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) need_val "$@"; BASE_URL="$2"; shift 2 ;;
    --label) need_val "$@"; LABEL="$2"; shift 2 ;;
    --server-config) need_val "$@"; SERVER_CONFIG="$2"; shift 2 ;;
    --model) need_val "$@"; MODEL="$2"; shift 2 ;;
    --victim-tokens) need_val "$@"; VICTIM_TOKENS="$2"; shift 2 ;;
    --aggressors) need_val "$@"; AGGRESSORS="$2"; shift 2 ;;
    --depth) need_val "$@"; DEPTH="$2"; shift 2 ;;
    --spacing) need_val "$@"; SPACING="$2"; shift 2 ;;
    --warmup) need_val "$@"; WARMUP="$2"; shift 2 ;;
    --aggressor-tokens) need_val "$@"; AGG_TOKENS="$2"; shift 2 ;;
    --probe-every) need_val "$@"; PROBE_EVERY="$2"; shift 2 ;;
    --priority) need_val "$@"; PRIORITY="$2"; shift 2 ;;
    --max-duration) need_val "$@"; MAX_DURATION="$2"; shift 2 ;;
    --sample-every) need_val "$@"; SAMPLE_EVERY="$2"; shift 2 ;;
    --tokens-per-word) need_val "$@"; TOKENS_PER_WORD="$2"; shift 2 ;;
    --assumed-decode-tps) need_val "$@"; ASSUMED_DECODE_TPS="$2"; shift 2 ;;
    --assumed-prefill-tps) need_val "$@"; ASSUMED_PREFILL_TPS="$2"; shift 2 ;;
    --kv-budget) need_val "$@"; KV_BUDGET="$2"; shift 2 ;;
    --slots) need_val "$@"; SLOTS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --i-have-announced-this-window) ANNOUNCED=1; shift ;;
    --allow-busy) ALLOW_BUSY=1; shift ;;
    --allow-kv-pressure) ALLOW_KV_PRESSURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
for pair in "victim-tokens:$VICTIM_TOKENS" "aggressors:$AGGRESSORS" "depth:$DEPTH" \
            "spacing:$SPACING" "warmup:$WARMUP" "aggressor-tokens:$AGG_TOKENS" \
            "probe-every:$PROBE_EVERY" "max-duration:$MAX_DURATION" \
            "sample-every:$SAMPLE_EVERY" "kv-budget:$KV_BUDGET" "slots:$SLOTS"; do
  is_uint "${pair#*:}" || die "--${pair%%:*} must be a non-negative integer"
done
[ "$MAX_DURATION" -gt 0 ] || die "--max-duration must be > 0"
[ "$SAMPLE_EVERY" -gt 0 ] || die "--sample-every must be > 0"
case "$PRIORITY" in ''|-[0-9]*|[0-9]*) ;; *) die "--priority must be an integer" ;; esac
case "$LABEL" in *[!A-Za-z0-9._-]*|'') die "--label may contain only A-Z a-z 0-9 . _ -" ;; esac
[ -n "$BASE_URL" ] || die "--base-url is required (e.g. http://<spark-ip>:9292)"
case "$BASE_URL" in http://*|https://*) ;; *) die "--base-url must start with http:// or https://" ;; esac
BASE_URL="${BASE_URL%/}"

cd "$(dirname "$0")/.."            # repo root: every path below is relative
OUT=data/benchy
TAG="mixed-${LABEL}-n${AGGRESSORS}-d${DEPTH}"

# Everything the runner needs, none of it secret. The token is NOT in here.
export MW_MODEL="$MODEL" MW_LABEL="$LABEL" MW_SERVER_CONFIG="$SERVER_CONFIG" \
  MW_VICTIM_TOKENS="$VICTIM_TOKENS" MW_AGGRESSORS="$AGGRESSORS" MW_DEPTH="$DEPTH" \
  MW_SPACING="$SPACING" MW_WARMUP="$WARMUP" MW_AGG_TOKENS="$AGG_TOKENS" \
  MW_PROBE_EVERY="$PROBE_EVERY" MW_PRIORITY="$PRIORITY" MW_MAX_DURATION="$MAX_DURATION" \
  MW_TOKENS_PER_WORD="$TOKENS_PER_WORD" MW_DECODE_TPS="$ASSUMED_DECODE_TPS" \
  MW_PREFILL_TPS="$ASSUMED_PREFILL_TPS" MW_KV_BUDGET="$KV_BUDGET" MW_SLOTS="$SLOTS" \
  MW_ALLOW_KV_PRESSURE="$ALLOW_KV_PRESSURE" MW_OUT="$OUT" MW_TAG="$TAG"

runner() {  # runner plan|run  - the python half; see the heredoc at the bottom
  MW_MODE="$1" python3 -c "$RUNNER_PY"
}

# read -d '' rather than "$(cat <<'PY')": bash 3.2 (macOS) mis-parses quotes and parentheses
# inside a heredoc that sits inside a command substitution.
IFS= read -r -d '' RUNNER_PY <<'PY' || true
import json, os, random, sys, threading, time

E = os.environ
MODE = E["MW_MODE"]
def I(k): return int(E[k])
def F(k): return float(E[k])
MODEL, LABEL = E["MW_MODEL"], E["MW_LABEL"]
V_TOK, N_AGG, DEPTH = I("MW_VICTIM_TOKENS"), I("MW_AGGRESSORS"), I("MW_DEPTH")
SPACING, WARMUP, A_TOK = I("MW_SPACING"), I("MW_WARMUP"), I("MW_AGG_TOKENS")
PROBE_EVERY, MAX_DUR = I("MW_PROBE_EVERY"), I("MW_MAX_DURATION")
PRIORITY = int(E["MW_PRIORITY"]) if E["MW_PRIORITY"] else None
DEC_TPS, PRE_TPS = F("MW_DECODE_TPS"), F("MW_PREFILL_TPS")
KV_BUDGET, SLOTS = I("MW_KV_BUDGET"), I("MW_SLOTS")
ALLOW_KV = E["MW_ALLOW_KV_PRESSURE"] == "1"
TPW_GIVEN = float(E["MW_TOKENS_PER_WORD"]) if E["MW_TOKENS_PER_WORD"] else None
ASSUMED_TPW = 1.3            # planning figure only; a real run calibrates
CAL_WORDS, PROBE_WORDS, PROBE_TOKENS, MTP_TOKENS_PER_STEP = 2000, 40, 16, 2.2

WORDS = ("time year people way day man thing woman life child world school state family student "
         "group country problem hand part place case week company system program question work "
         "government number night point home water room mother area money story fact month lot "
         "right study book eye job word business issue side kind head house service friend father "
         "power hour game line end member law car city community name president team minute idea "
         "kid body information back parent face others level office door health person art war "
         "history party result change morning reason research girl guy moment air teacher force").split()

VICTIM_PROMPT = ("Write a very long, carefully reasoned design document for a distributed job "
                 "scheduler: requirements, data model, failure handling, fairness, observability, "
                 "rollout plan, and a worked example for each section. Do not stop early.")

def cold_prompt(n_words, seed):
    # A unique nonce FIRST, so not even the first KV block can come from the prefix cache.
    rng = random.Random(seed)
    nonce = "%016x" % rng.getrandbits(64)
    body = " ".join(rng.choice(WORDS) for _ in range(max(n_words, 1)))
    return "[run %s]\n%s\n\nIn one short sentence, which word above appeared most often?" % (nonce, body)

def plan(tpw):
    agg_prefill_s = DEPTH / PRE_TPS
    # Prefills run one after another, so when the last aggressor arrives the ones that
    # have already finished are those whose serialised prefill fitted in the elapsed time.
    done_by_last_arrival = int((N_AGG - 1) * SPACING // agg_prefill_s) if N_AGG else 0
    overlap = max(1, N_AGG - done_by_last_arrival) if N_AGG else 0
    last_arrival = WARMUP + SPACING * max(N_AGG - 1, 0)
    # Prefills are serialised in practice, and the victim is close to stalled while they run.
    stall = N_AGG * agg_prefill_s
    victim_s = V_TOK / DEC_TPS + stall
    agg_done = last_arrival + stall + A_TOK / DEC_TPS
    n_probes = int(stall // PROBE_EVERY) if PROBE_EVERY else 0
    prompt_tokens = N_AGG * DEPTH + 200 + n_probes * 60 + (0 if TPW_GIVEN else int(CAL_WORDS * tpw))
    in_flight_tokens = overlap * DEPTH + V_TOK + 200
    return dict(aggressor_prefill_s=agg_prefill_s, overlap=overlap, stall_s=stall,
                est_duration_s=max(victim_s, agg_done) + 5, n_probes=n_probes,
                total_prompt_tokens=prompt_tokens, in_flight_tokens=in_flight_tokens,
                peak_requests=1 + overlap + (1 if PROBE_EVERY else 0),
                words_per_aggressor=int(DEPTH / tpw),
                est_kv_usage_pct=100.0 * 2 * in_flight_tokens / 721212)

def refusals(p):
    out = []
    if p["in_flight_tokens"] > KV_BUDGET and not ALLOW_KV:
        out.append("estimated %d tokens of context in flight exceeds --kv-budget %d "
                   "(usable KV is about half the nominal pool); space the aggressors out, "
                   "lower --depth, or pass --allow-kv-pressure" % (p["in_flight_tokens"], KV_BUDGET))
    if p["peak_requests"] > SLOTS and not ALLOW_KV:
        out.append("%d requests would be in flight but only %d slots exist; the extras would "
                   "get 429s or queue silently" % (p["peak_requests"], SLOTS))
    if p["est_duration_s"] > MAX_DUR:
        out.append("estimated duration %.0f s exceeds --max-duration %d s; the run would be cut "
                   "off before it measured anything" % (p["est_duration_s"], MAX_DUR))
    return out

def print_plan(p, tpw, calibrated):
    pr = "absent" if PRIORITY is None else str(PRIORITY)
    print("== request plan: %s-n%d-d%d" % ("mixed-" + LABEL, N_AGG, DEPTH))
    print("   base URL              : set by caller (not shown, never written to output files)")
    print("   model                 : %s" % MODEL)
    print("   server config (label) : %s" % E["MW_SERVER_CONFIG"])
    if not TPW_GIVEN and not calibrated:
        print("   t=-    calibration    : 1 request, %d words in, 1 token out (real runs only; "
              "fixes tokens/word)" % CAL_WORDS)
    print("   t=0s   victim         : ~200 tokens in, %d out (ignore_eos, streamed), priority=%s"
          % (V_TOK, pr))
    for i in range(N_AGG):
        print("   t=%-4s aggressor %-2d   : ~%d tokens in (%d words, unique nonce first = cold), "
              "%d out, priority=absent" % ("%ds" % (WARMUP + i * SPACING), i + 1, DEPTH,
                                           p["words_per_aggressor"], A_TOK))
    if PROBE_EVERY:
        print("   every %ds probe        : ~60 tokens in, %d out, reasoning_effort=low, priority=%s, "
              "while any aggressor is prefilling (~%d probes)" % (PROBE_EVERY, PROBE_TOKENS, pr, p["n_probes"]))
    print("== estimated load (%s tokens/word = %.2f; decode %.0f tok/s, prefill %.0f tok/s assumed)"
          % ("calibrated" if calibrated else "assumed", tpw, DEC_TPS, PRE_TPS))
    print("   total prompt tokens   : ~%d" % p["total_prompt_tokens"])
    print("   total output tokens   : ~%d" % (V_TOK + N_AGG * A_TOK + p["n_probes"] * PROBE_TOKENS))
    print("   peak requests in flight: %d of %d slots" % (p["peak_requests"], SLOTS))
    print("   peak context in flight: ~%d tokens (~%.0f%% KV at the measured 2x usage; budget %d)"
          % (p["in_flight_tokens"], p["est_kv_usage_pct"], KV_BUDGET))
    print("   one aggressor prefill : ~%.0f s; other clients on the box are stalled for ~%.0f s in total"
          % (p["aggressor_prefill_s"], p["stall_s"]))
    print("   expected duration     : ~%.0f s (hard cap --max-duration %d s)" % (p["est_duration_s"], MAX_DUR))
    print("   (smaller prefill chunks make prefill slower: expect longer than this on tuned configs)")

if MODE == "plan":
    tpw = TPW_GIVEN or ASSUMED_TPW
    p = plan(tpw)
    print_plan(p, tpw, False)
    bad = refusals(p)
    for b in bad:
        print("   REFUSE: " + b)
    print("== dry run: nothing was contacted." if not bad else "== dry run: a real run would refuse.")
    sys.exit(1 if bad else 0)

# ---------------------------------------------------------------- real run
if E.get("MW_NET_OK") != "1":
    sys.exit("runner: network gate not opened by the wrapper - refusing")
import urllib.request, urllib.error                     # only imported past the gate
KEY = E["OPENAI_API_KEY"]
BASE = E["MW_BASE_URL"]
T0 = time.time()
STOP = threading.Event()
LOCK = threading.Lock()
OPEN = []                                                # live responses, closed on abort

def now(): return time.time() - T0

def chat(body, rec):
    # Streams one chat completion. rec gets: start, ttft, end, samples[(t, completion_tokens)],
    # prompt_tokens, completion_tokens, error. Token counts come from vLLM's
    # continuous_usage_stats; if the server does not send them, chunks are counted instead.
    body = dict(body, model=MODEL, stream=True,
                stream_options={"include_usage": True, "continuous_usage_stats": True})
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + KEY,
                                          "Content-Type": "application/json"})
    rec.update(start=now(), ttft=None, end=None, samples=[], prompt_tokens=None,
               completion_tokens=0, error=None, token_count_source="usage")
    chunks = 0
    try:
        resp = urllib.request.urlopen(req, timeout=max(MAX_DUR, 60))
        with LOCK: OPEN.append(resp)
        for raw in resp:
            if STOP.is_set(): break
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"): continue
            data = line[5:].strip()
            if data == "[DONE]": break
            ev = json.loads(data)
            if "error" in ev:
                rec["error"] = str(ev["error"])[:300]; break
            delta = (ev.get("choices") or [{}])[0].get("delta") or {}
            produced = any(delta.get(k) for k in ("content", "reasoning_content", "reasoning", "tool_calls"))
            usage = ev.get("usage") or {}
            if usage.get("prompt_tokens") is not None: rec["prompt_tokens"] = usage["prompt_tokens"]
            if produced: chunks += 1
            if usage.get("completion_tokens") is not None:
                n = usage["completion_tokens"]
            else:
                n = chunks; rec["token_count_source"] = "chunks (approximate: one chunk can carry >1 token)"
            if n > 0 and rec["ttft"] is None: rec["ttft"] = now() - rec["start"]
            if n != rec["completion_tokens"]:
                rec["completion_tokens"] = n; rec["samples"].append((round(now(), 3), n))
    except urllib.error.HTTPError as e:
        rec["error"] = "HTTP %d %s" % (e.code, e.read(300).decode("utf-8", "replace"))
    except Exception as e:                                # noqa: BLE001 - record, never crash the run
        if not STOP.is_set(): rec["error"] = "%s: %s" % (type(e).__name__, e)
    rec["end"] = now()

def with_priority(body):
    return dict(body, priority=PRIORITY) if PRIORITY is not None else body

def msg(text): return [{"role": "user", "content": text}]

# 1. calibration: one small request so aggressors land on the requested token depth
tpw, calibrated = TPW_GIVEN or ASSUMED_TPW, False
cal = {}
if not TPW_GIVEN:
    chat({"messages": msg(cold_prompt(CAL_WORDS, random.getrandbits(64))), "max_tokens": 1,
          "reasoning_effort": "low"}, cal)
    if cal.get("error") or not cal.get("prompt_tokens"):
        sys.exit("calibration request failed (%s) - stopping before any load is sent"
                 % (cal.get("error") or "no usage returned; pass --tokens-per-word"))
    tpw, calibrated = cal["prompt_tokens"] / float(CAL_WORDS), True
p = plan(tpw)
print_plan(p, tpw, calibrated)
bad = refusals(p)
if bad:
    sys.stdout.flush()
    sys.stderr.write("\n".join("REFUSE: " + b for b in bad) + "\n" + ("Only the calibration request was sent.\n" if calibrated else "Nothing was sent.\n"))
    sys.exit(1)
T0 = time.time()                                         # the clock the CSV sampler lines up with

victim, aggs, probes = {"role": "victim"}, [], []
threads = [threading.Thread(target=chat, args=(with_priority(
    {"messages": msg(VICTIM_PROMPT), "max_tokens": V_TOK, "ignore_eos": True}), victim))]
def aggressor(i):
    rec = {"role": "aggressor", "index": i + 1, "planned_start": WARMUP + i * SPACING}
    aggs.append(rec)
    while now() < rec["planned_start"] and not STOP.is_set(): time.sleep(0.05)
    if victim.get("error") or victim.get("end") is not None or STOP.is_set():
        rec["error"] = "skipped: victim was not decoding at this aggressor's start time"; return
    chat({"messages": msg(cold_prompt(p["words_per_aggressor"], random.getrandbits(64))),
          "max_tokens": A_TOK, "ignore_eos": True, "reasoning_effort": "low"}, rec)
def prober():
    while not STOP.is_set():
        time.sleep(PROBE_EVERY)
        busy = [a for a in aggs if a.get("start") is not None and a.get("ttft") is None and a.get("end") is None]
        if all(a.get("end") is not None or a.get("error") for a in aggs) and len(aggs) == N_AGG: return
        if not busy: continue
        rec = {"role": "probe"}; probes.append(rec)
        chat(with_priority({"messages": msg(cold_prompt(PROBE_WORDS, random.getrandbits(64))),
                            "max_tokens": PROBE_TOKENS, "reasoning_effort": "low"}), rec)
threads += [threading.Thread(target=aggressor, args=(i,)) for i in range(N_AGG)]
if PROBE_EVERY: threads.append(threading.Thread(target=prober))
for t in threads: t.daemon = True; t.start()

timed_out = False
while any(t.is_alive() for t in threads):
    if now() > MAX_DUR:
        timed_out = True; STOP.set()
        with LOCK:
            for r in OPEN:
                try: r.close()                           # client gone -> vLLM aborts the request
                except Exception: pass                   # noqa: BLE001
        break
    time.sleep(0.2)
for t in threads: t.join(timeout=5)

# ---------------------------------------------------------------- analysis
def rate(samples, a, b):
    # completion tokens per second between wall times a and b, from cumulative samples
    pts = [(t, n) for t, n in samples if a <= t <= b]
    if len(pts) < 2 or pts[-1][0] - pts[0][0] < 0.5: return None
    return (pts[-1][1] - pts[0][1]) / (pts[-1][0] - pts[0][0])

vs = victim.get("samples") or []
first_tok = (victim["start"] + victim["ttft"]) if victim.get("ttft") is not None else None
windows = [(a["start"], a["start"] + a["ttft"]) for a in aggs if a.get("ttft") is not None]
first_agg = min([a["start"] for a in aggs if a.get("start") is not None] or [victim.get("end") or 0])
baseline = rate(vs, first_tok or 0, first_agg)
during_tok = during_s = 0.0
for a, b in windows:
    pts = [(t, n) for t, n in vs if a <= t <= b]
    if len(pts) >= 2: during_tok += pts[-1][1] - pts[0][1]; during_s += pts[-1][0] - pts[0][0]
during = during_tok / during_s if during_s > 0.5 else None
last_prefill_end = max([b for _, b in windows] or [0])
after = rate(vs, last_prefill_end, victim.get("end") or 0) if windows else None
INTERVAL = 5
series, t = [], 0
while vs and t < (victim.get("end") or 0):
    r = rate(vs, t, t + INTERVAL)
    series.append({"t": t, "tok_per_s": round(r, 2) if r is not None else 0.0,
                   "aggressor_prefilling": any(a < t + INTERVAL and b > t for a, b in windows)})
    t += INTERVAL
def r2(x): return None if x is None else round(x, 2)
for a in aggs:
    a["prefill_tok_per_s_effective"] = r2(a["prompt_tokens"] / a["ttft"]) if a.get("ttft") and a.get("prompt_tokens") else None
    a.pop("samples", None)
for q in probes: q.pop("samples", None)
for x in aggs + probes:
    for k in ("start", "ttft", "end"):
        if isinstance(x.get(k), float): x[k] = round(x[k], 3)
errors = [x.get("error") for x in [victim] + aggs + probes if x.get("error")]
ratio = during / baseline if during is not None and baseline else None
result = {
    "tool": "scripts/mixed-workload.sh", "schema": 1,
    "timestamp_utc": time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime(T0)),
    "label": LABEL, "server_config_as_stated_by_operator": E["MW_SERVER_CONFIG"],
    "vllm_version": E.get("MW_VLLM_VERSION", "not read"), "model": MODEL,
    "params": {"victim_tokens": V_TOK, "aggressors": N_AGG, "depth_target_tokens": DEPTH,
               "spacing_s": SPACING, "warmup_s": WARMUP, "aggressor_tokens": A_TOK,
               "probe_every_s": PROBE_EVERY, "victim_priority": PRIORITY,
               "max_duration_s": MAX_DUR, "tokens_per_word": round(tpw, 4), "calibrated": calibrated},
    "victim": {"ttft_s": r2(victim.get("ttft")), "wall_s": r2((victim.get("end") or 0) - victim.get("start", 0)),
               "prompt_tokens": victim.get("prompt_tokens"), "completion_tokens": victim.get("completion_tokens"),
               "token_count_source": victim.get("token_count_source"),
               "baseline_tok_per_s_before_aggressors": r2(baseline),
               "tok_per_s_while_aggressors_prefill": r2(during),
               "seconds_spent_under_prefill": r2(during_s),
               "fraction_of_baseline_kept": r2(ratio),
               "tok_per_s_after_last_prefill": r2(after),
               "tok_per_s_by_5s_interval": series, "error": victim.get("error")},
    "aggressors": sorted(aggs, key=lambda a: a["index"]), "probes": probes,
    "server": {"preemptions_before": E.get("MW_PREEMPT_BEFORE", ""), "kv_samples_csv": E["MW_TAG"] + "-kv-samples.csv"},
    "timed_out": timed_out, "errors": errors,
    "acceptance_issue_3": {"target_fraction": 0.5,
                           "met": (ratio is not None and ratio >= 0.5) if N_AGG == 1 and DEPTH >= 131072 else None,
                           "note": "defined for one cold 131k aggressor; null for any other shape"},
}
path = os.path.join(E["MW_OUT"], E["MW_TAG"])
with open(path + ".json", "w") as f: json.dump(result, f, indent=2)
L = ["mixed-workload %s   %s   server config: %s" % (E["MW_TAG"], result["timestamp_utc"], E["MW_SERVER_CONFIG"]),
     "victim    : TTFT %s s, wall %s s, %s tokens (%s)" % (r2(victim.get("ttft")), result["victim"]["wall_s"],
                                                           victim.get("completion_tokens"), victim.get("token_count_source")),
     "            alone %s tok/s -> during prefill %s tok/s (%s of baseline, %s s under prefill) -> after %s tok/s"
     % (r2(baseline), r2(during), "n/a" if ratio is None else "%.0f%%" % (100 * ratio), r2(during_s), r2(after))]
for a in result["aggressors"]:
    L.append("aggressor %d: start %s s, %s prompt tokens, TTFT %s s, effective prefill %s tok/s%s"
             % (a["index"], r2(a.get("start")), a.get("prompt_tokens"), r2(a.get("ttft")),
                a.get("prefill_tok_per_s_effective"), "  ERROR " + a["error"] if a.get("error") else ""))
if probes:
    tt = sorted(q["ttft"] for q in probes if q.get("ttft") is not None)
    L.append("probes    : %d sent, %d answered, TTFT median %s s, max %s s"
             % (len(probes), len(tt), r2(tt[len(tt) // 2]) if tt else None, r2(tt[-1]) if tt else None))
if timed_out: L.append("STOPPED   : --max-duration reached; connections closed, numbers above are partial")
for e in errors: L.append("error     : " + e)
with open(path + ".summary.txt", "w") as f: f.write("\n".join(L) + "\n")
print("\n".join(L))
sys.exit(3 if timed_out else 2 if errors else 0)
PY

# ---- dry run: print the plan and stop. Nothing above or below this block that
# ---- touches the network is reachable from here.
if [ "$DRY_RUN" -eq 1 ]; then
  runner plan
  exit $?
fi

if [ "$ANNOUNCED" -ne 1 ]; then
  cat >&2 <<'EOF'
mixed-workload: REFUSING to send any request.

This endpoint is shared. One cold long prefill stalls every other client on the
box for a minute or more, and this test sends several on purpose. Announce the
window to the other users first, then re-run with
  --i-have-announced-this-window
Use --dry-run to see exactly what would be sent. Nothing was contacted.
EOF
  exit 1
fi

: "${OPENAI_API_KEY:?set OPENAI_API_KEY to the llama-swap bearer token (it is never printed)}"
command -v curl >/dev/null || die "curl not found"
command -v python3 >/dev/null || die "python3 not found"
export OPENAI_API_KEY

# The token reaches curl on stdin (-K -), so it never appears in a process list.
authed_get() {  # authed_get <url> [max-seconds]
  printf 'header = "Authorization: Bearer %s"\n' "$OPENAI_API_KEY" \
    | curl -sS -m "${2:-10}" -K - "$1"
}

METRICS_CACHE=""
metrics_fetch() { METRICS_CACHE="$(authed_get "$BASE_URL/upstream/$MODEL/metrics" 10 2>/dev/null || true)"; }
metric() {  # metric <name> -> value, from the last metrics_fetch (one HTTP GET per sample, not four)
  printf '%s\n' "$METRICS_CACHE" | awk -v n="vllm:$1{" 'index($0, n) == 1 && !seen++ { print $NF }'
}

curl -fsS -m 10 "$BASE_URL/health" >/dev/null || die "health check failed - not starting"
metrics_fetch
running="$(metric num_requests_running)"; waiting="$(metric num_requests_waiting)"
pre_before="$(metric num_preemptions_total)"
[ -n "$running" ] || die "could not read vLLM metrics through /upstream/$MODEL/metrics - not starting"
if [ "${running%.*}" -gt 0 ] || [ "${waiting%.*}" -gt 0 ]; then
  if [ "$ALLOW_BUSY" -eq 1 ]; then
    echo "WARNING: server has ${running%.*} running / ${waiting%.*} waiting requests that are not ours - results will be contaminated" >&2
  else
    die "server has ${running%.*} running / ${waiting%.*} waiting requests that are not ours - somebody is using the box. Not starting (--allow-busy overrides)."
  fi
fi
MW_VLLM_VERSION="$(authed_get "$BASE_URL/upstream/$MODEL/version" 10 2>/dev/null | tr -d '\n' | cut -c1-120 || true)"
export MW_VLLM_VERSION MW_PREEMPT_BEFORE="$pre_before" MW_BASE_URL="$BASE_URL" MW_NET_OK=1

SAMPLES="$OUT/$TAG-kv-samples.csv"
echo "ts,step,kv_cache_usage,running,waiting,preemptions_total" > "$SAMPLES"
( while :; do
    metrics_fetch
    echo "$(date +%s),$TAG,$(metric kv_cache_usage_perc),$(metric num_requests_running),$(metric num_requests_waiting),$(metric num_preemptions_total)" >> "$SAMPLES" || true
    sleep "$SAMPLE_EVERY"
  done ) &
sampler=$!
trap 'kill $sampler 2>/dev/null || true' EXIT

echo "== $TAG (preemptions so far: ${pre_before:-?})"
rc=0
runner run || rc=$?

kill $sampler 2>/dev/null || true
wait $sampler 2>/dev/null || true   # reap quietly; otherwise bash prints a 'Terminated' job notice
metrics_fetch
pre_after="$(metric num_preemptions_total)"
if [ -n "$pre_after" ] && [ -n "$pre_before" ] && [ "$rc" -ne 1 ]; then
  echo "   exit=$rc preemptions during run: $(( ${pre_after%.*} - ${pre_before%.*} ))" | tee -a "$OUT/$TAG.summary.txt"
fi
curl -fsS -m 30 "$BASE_URL/health" >/dev/null || echo "WARNING: /health did not answer within 30 s after the run - check the server" >&2
if [ -f "$OUT/$TAG.json" ] && [ "$rc" -ne 1 ]; then
  echo "   wrote $OUT/$TAG.json, .summary.txt, -kv-samples.csv"
else
  rm -f "$SAMPLES"                  # a refused run measured nothing; leave no stray CSV behind
fi
exit $rc
