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
# Usage: OPENAI_API_KEY=... scripts/depth-concurrency.sh ["<conc>:<depth>" ...]
set -euo pipefail

: "${OPENAI_API_KEY:?set OPENAI_API_KEY to the llama-swap bearer token}"
HOST="${LLM_HOST:-http://10.0.1.227:9292}"
MODEL=qwen3.8-flash-next
OUT="$(cd "$(dirname "$0")/.." && pwd)/data/benchy"
STEPS=("$@")
[ ${#STEPS[@]} -gt 0 ] || STEPS=(2:32768 4:32768 2:131072)

metric() {  # metric <name> -> value, from vLLM via llama-swap's upstream passthrough
  curl -sS -m 10 -H "Authorization: Bearer $OPENAI_API_KEY" "$HOST/upstream/$MODEL/metrics" \
    | awk -v n="vllm:$1{" 'index($0, n) == 1 { print $NF; exit }'
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
  uvx llama-benchy --base-url "$HOST/v1" --api-key "$OPENAI_API_KEY" \
    --model "$MODEL" --tokenizer Qwen/Qwen3.8-Flash-Next \
    --pp 2048 --tg 128 --depth "$depth" --runs 3 --no-cache \
    --latency-mode generation --concurrency "$conc" --exit-on-first-fail \
    --format json --save-result "$OUT/$tag.json" > "$OUT/$tag.output.txt" 2>&1 || rc=$?

  kill $sampler 2>/dev/null || true
  echo "   exit=$rc preemptions during step: $(( $(metric num_preemptions_total | cut -d. -f1) - ${pre_before%.*} ))"
  [ $rc -eq 0 ] || { echo "$tag failed - stopping before the next step" >&2; exit $rc; }
done
