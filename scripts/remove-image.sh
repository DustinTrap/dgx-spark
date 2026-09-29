#!/usr/bin/env bash
# remove-image.sh - remove ONE unused Docker image from the shared box, by name,
# only while the endpoint is quiet, and record what the removal did to serving.
#
# Run on the box, detached, with the output kept as the record:
#   setsid nohup scripts/remove-image.sh IMAGE \
#     > ~/ai-stack/changes/image-removal-$(date -u +%Y%m%d-%H%MZ).log 2>&1 < /dev/null &
#
# Why this much care (#21):
# - `docker images` hides untagged images, and other solutions on this box
#   still use some of them. `docker image prune -a` or `docker system prune`
#   would delete those. This script removes exactly the one name it is given,
#   never with -f, and refuses if any container (running or stopped) uses it.
# - The weights, the model's mmap'd table and /var/lib/docker share one NVMe
#   partition. The deletion runs inside dockerd (root), so `ionice` on this
#   client changes nothing. Timing is the only lever.
#
# Gate: waits (up to MAX_WAIT seconds) until llama-swap /health is OK and the
# vLLM stats lines of the last ~65 s show at most 1 running request and no
# prompt throughput, or there are no stats lines at all (idle). Then it takes
# one snapshot, runs `docker image rm`, and takes a snapshot every 30 s for
# 5 minutes. Each snapshot records I/O and memory pressure, page cache, slab,
# MemAvailable, llama-swap /health and vLLM prompt/generation throughput.
#
# Remove the smallest image first, as a canary, and read its log before
# removing the next one.
#
# DRY_RUN=1 checks the image and the gate once and removes nothing.
set -uo pipefail

MODEL_CONTAINER=${MODEL_CONTAINER:-qwen38-flash}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:9292/health}
MAX_WAIT=${MAX_WAIT:-43200}   # seconds; 12 h
DRY_RUN=${DRY_RUN:-0}
[ $# -eq 1 ] || { echo "usage: ${0##*/} IMAGE   (one image per run)" >&2; exit 2; }
IMAGE=$1

# "prompt_tok_s running" for each vLLM stats line of the last ~65 s
stats() {
  docker logs --since 65s "$MODEL_CONTAINER" 2>&1 | grep 'Running:' |
    sed -E 's/.*Avg prompt throughput: ([0-9.]+).*Running: ([0-9]+) reqs.*/\1 \2/'
}

quiet() {
  local s n busy
  [ "$(curl -s -m 3 "$HEALTH_URL")" = OK ] || return 1
  s=$(stats)
  n=$(printf '%s\n' "$s" | grep -c .)
  busy=$(printf '%s\n' "$s" | awk 'NF==2 && ($1+0>0 || $2+0>1)' | wc -l)
  [ "$n" -eq 0 ] || { [ "$n" -ge 6 ] && [ "$busy" -eq 0 ]; }
}

snap() {
  local io iofull mem cached slab avail st hc
  io=$(awk '/^some/{split($2,a,"=");print a[2]}' /proc/pressure/io)
  iofull=$(awk '/^full/{split($2,a,"=");print a[2]}' /proc/pressure/io)
  mem=$(awk '/^some/{split($2,a,"=");print a[2]}' /proc/pressure/memory)
  cached=$(awk '/^Cached:/{print int($2/1024)}' /proc/meminfo)
  slab=$(awk '/^SReclaimable:/{print int($2/1024)}' /proc/meminfo)
  avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
  st=$(docker logs --since 15s "$MODEL_CONTAINER" 2>&1 | grep 'Running:' | tail -1 |
    sed -E 's/.*Avg prompt throughput: ([0-9.]+).*Avg generation throughput: ([0-9.]+).*Running: ([0-9]+).*/prompt=\1 gen=\2 running=\3/')
  hc=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$HEALTH_URL")
  echo "$(date -u +%TZ) $1 io_some10=$io io_full10=$iofull mem_some10=$mem cachedMiB=$cached sreclaimMiB=$slab availMiB=$avail health=$hc ${st:-vllm=no-stats}"
}

ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null) || { echo "ABORT: $IMAGE not found"; exit 1; }
if docker ps -aq --no-trunc | xargs -r docker inspect -f '{{.Image}}' | grep -qx "$ID"; then
  echo "ABORT: a container (running or stopped) uses $IMAGE ($ID)"; exit 1
fi
# Enough to re-pull it later.
echo "$IMAGE id=$ID digests=$(docker image inspect -f '{{.RepoDigests}}' "$IMAGE")"

if [ "$DRY_RUN" = 1 ]; then
  if quiet; then echo "DRY_RUN: gate is open now; nothing removed"; else echo "DRY_RUN: gate is closed now (busy); nothing removed"; fi
  exit 0
fi

waited=0
until quiet; do
  [ "$waited" -ge "$MAX_WAIT" ] && { echo "ABORT: endpoint not quiet within ${MAX_WAIT}s"; exit 1; }
  sleep 30; waited=$((waited + 30))
done

snap before
t0=$(date +%s.%N)
out=$(docker image rm "$IMAGE" 2>&1) || { echo "ABORT: docker image rm failed: $out"; exit 1; }
printf '%s\n' "$out" | tail -3
awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "rm took %.1f s\n", b - a }'
for i in $(seq 1 10); do
  sleep 30
  snap "after+$((i * 30))s"
done
