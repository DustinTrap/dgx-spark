#!/usr/bin/env bash
# Strip machine-specific strings from benchmark output before it is committed.
# This repository is public (see AGENTS.md), and tools like llama-benchy print
# the absolute cache path, the result path and the endpoint URL into their logs.
#
# Rewrites, and nothing else - measured values are never touched:
#   /Users/<name>/...  and  /home/<name>/...   ->  ~/...
#   any private-network (RFC 1918) IPv4 host   ->  <spark-ip>
#
# As a filter:   some-benchmark 2>&1 | scripts/scrub-paths.sh > out.txt
# In place:      scripts/scrub-paths.sh data/benchy/*.output.txt
# Idempotent: running it over already-scrubbed text changes nothing.
set -euo pipefail

scrub() {
  sed -E \
    -e 's#(/Users|/home)/[A-Za-z0-9._-]+#~#g' \
    -e 's#(^|[^0-9.])(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}#\1<spark-ip>#g'
}

if [ $# -eq 0 ]; then
  scrub
  exit 0
fi

for f in "$@"; do
  [ -f "$f" ] || { echo "not a file: $f" >&2; exit 1; }
  tmp="$(mktemp "${f}.scrub.XXXXXX")"
  scrub < "$f" > "$tmp"
  if cmp -s "$f" "$tmp"; then
    rm -f "$tmp"
  else
    cat "$tmp" > "$f"   # keep the original file's mode
    rm -f "$tmp"
    echo "scrubbed: $f" >&2
  fi
done
