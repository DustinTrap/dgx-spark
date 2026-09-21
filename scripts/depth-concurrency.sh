#!/usr/bin/env bash
# Stepped long-context x concurrency test against the llama-swap endpoint.
#
# Several long prompts at once is where the KV pool first comes under pressure,
# and this box has been OOM-killed on a long prefill before (see
# bin/run-qwen38.sh), so the load goes up in steps. Between steps the script
# checks /health and stops rather than pushing on if the endpoint is unhappy
# or a step had failures.
#
# While each step runs, vLLM's KV usage, running/waiting counts and preemption
# counter are sampled every 5s to data/benchy/depthconc-kv-samples.csv - idle
# snapshots show 0% KV usage, so the peak is only visible during the run.
#
# THIS IS A LOAD TEST AGAINST A SHARED BOX. Every other consumer of the endpoint
# slows to 1-6 tok/s while it runs. Announce a window on an issue first and pass
# that issue number as ANNOUNCED_ISSUE (see AGENTS.md).
#
# Usage: LLM_HOST=http://<spark-ip>:9292 OPENAI_API_KEY=... ANNOUNCED_ISSUE=<n> \
#          scripts/depth-concurrency.sh ["<conc>:<depth>" ...]
#        DRY_RUN=1 scripts/depth-concurrency.sh [...]   # print the plan, contact nothing
#
# The output logs are piped through scripts/scrub-paths.sh, so absolute home
# paths and the endpoint's address never reach a tracked file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRUB="$ROOT/scripts/scrub-paths.sh"
MODEL=qwen3.8-flash-next
OUT="$ROOT/data/benchy"
STEPS=("$@")
[ ${#STEPS[@]} -gt 0 ] || STEPS=(2:32768 4:32768 2:131072)

benchy_cmd() {  # benchy_cmd <conc> <depth> <tag> <api-key> -> the llama-benchy argv, one word per line
  printf '%s\n' uvx llama-benchy --base-url "$HOST/v1" --api-key "$4" \
    --model "$MODEL" --tokenizer Qwen/Qwen3.8-Flash-Next \
    --pp 2048 --tg 128 --depth "$2" --runs 3 --no-cache \
    --latency-mode generation --concurrency "$1" --exit-on-first-fail \
    --format json --save-result "$OUT/$3.json"
}

if [ -n "${DRY_RUN:-}" ]; then
  HOST="${LLM_HOST:-http://<spark-ip>:9292}"
  echo "DRY RUN - nothing is contacted, nothing is written."
  for step in "${STEPS[@]}"; do
    conc="${step%%:*}"; depth="${step##*:}"; tag="depthconc-c${conc}-d${depth}"
    echo "== $tag"
    benchy_cmd "$conc" "$depth" "$tag" '<redacted>' | tr '\n' ' ' | "$SCRUB"; echo
    echo "   log -> $OUT/$tag.output.txt (scrubbed)" | "$SCRUB"
  done
  exit 0
fi

: "${OPENAI_API_KEY:?set OPENAI_API_KEY to the llama-swap bearer token}"
: "${LLM_HOST:?set LLM_HOST to the endpoint, e.g. http://<spark-ip>:9292 (no default: this repo is public)}"
: "${ANNOUNCED_ISSUE:?this is a load test on a shared box - set ANNOUNCED_ISSUE to the issue number where the window was announced}"
HOST="$LLM_HOST"

metric() {  # metric <name> -> value, from vLLM via llama-swap's upstream passthrough
  curl -sS -m 10 -H "Authorization: Bearer $OPENAI_API_KEY" "$HOST/upstream/$MODEL/metrics" \
    | awk -v n="vllm:$1{" 'index($0, n) == 1 && !seen++ { print $NF }'   # no early exit: that would SIGPIPE curl and trip pipefail
}

SAMPLES="$OUT/depthconc-kv-samples.csv"
echo "ts,step,kv_cache_usage,running,waiting,preemptions_total" > "$SAMPLES"

for step in "${STEPS[@]}"; do
  conc="${step%%:*}"; depth="${step##*:}"
  tag="depthconc-c${conc}-d${depth}"

  curl -fsS -m 10 "$HOST/health" >/dev/null || { echo "health check failed before $tag - stopping" >&2; exit 1; }
  pre_before="$(metric num_preemptions_total)"
  echo "== $tag (preemptions so far: $pre_before)"

  ( while :; do
      echo "$(date +%s),$tag,$(metric kv_cache_usage_perc),$(metric num_requests_running),$(metric num_requests_waiting),$(metric num_preemptions_total)" >> "$SAMPLES" || true
      sleep 5
    done ) &
  sampler=$!
  trap 'kill $sampler 2>/dev/null || true' EXIT

  rc=0
  cmd=()
  while IFS= read -r word; do cmd+=("$word"); done < <(benchy_cmd "$conc" "$depth" "$tag" "$OPENAI_API_KEY")
  # pipefail: a benchy failure still surfaces as rc even though the scrubber exits 0.
  "${cmd[@]}" 2>&1 | "$SCRUB" > "$OUT/$tag.output.txt" || rc=$?

  kill $sampler 2>/dev/null || true
  wait $sampler 2>/dev/null || true   # reap quietly; otherwise bash prints a 'Terminated' job notice
  echo "   exit=$rc preemptions during step: $(( $(metric num_preemptions_total | cut -d. -f1) - ${pre_before%.*} ))"
  [ $rc -eq 0 ] || { echo "$tag failed - stopping before the next step" >&2; exit $rc; }
done
