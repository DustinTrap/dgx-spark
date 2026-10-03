#!/usr/bin/env bash
# wait-for-slot.sh - read-only admission gate: wait until the endpoint has room.
#
# The endpoint runs 8 sequences at once and is shared. A client that fans out can
# only count its own requests; this script reads the total from vLLM instead. It
# samples two gauges through llama-swap,
#     vllm:num_requests_running   vllm:num_requests_waiting
# and returns 0 as soon as  running + waiting + NEED <= LIMIT.
#
# Each sample is one GET of /upstream/<model>/metrics. It sends no inference
# request and changes nothing on the server.
#
# It is ADVISORY. Two clients can sample at the same moment and both take the
# same free slot. The hard limit is still concurrencyLimit in llama-swap.yaml,
# which answers request 9 with a 429.
#
# It never prints, logs or echoes the key, and never puts it on a command line:
# the Authorization header reaches curl on stdin.
#
# No `set -x` here, ever: xtrace would write the key to the terminal.
set -euo pipefail

PROG=${0##*/}

usage() {
  cat <<EOF
Usage: $PROG [options] [BASE_URL]

Wait until the endpoint has room for NEED more requests, then exit 0.

  BASE_URL      e.g. http://<spark-ip>:9292   (no trailing /v1)
                Default: the LLM_HOST environment variable.

Options:
  --need N            requests you are about to start, default 1
  --limit N           proceed when running + waiting + NEED <= N, default 6.
                      The endpoint has 8 slots; the default leaves 2 for
                      latency-sensitive consumers. The 6 is a policy choice,
                      not a measurement.
  --check             take one sample and exit: 0 room, 1 no room. Do not wait.
  --interval SECONDS  pause between samples, default 5
  --max-wait SECONDS  give up after this long, default 600. 0 = wait forever.
  --timeout SECONDS   per-request limit, default 15. /metrics can take over
                      10 s while a long prefill is running.
  --model NAME        model id in the metrics path, default qwen3.8-flash-next
  --key-env ENVVAR    NAME of the environment variable that holds the key,
                      default OPENAI_API_KEY. The key itself is never an argument.
  --key-file PATH     read the key from the first line of this file instead
  -q, --quiet         print nothing; use the exit status
  -h, --help          show this help

Exit status: 0 room, 1 no room (--check) or gave up after --max-wait,
2 usage error or an answer that waiting cannot fix (401, 403, 404).

A sample that gets no answer, a 5xx, or a 429 counts as "no room": an endpoint
too busy to report its load is busy.

Example - is there room for three sub-agents right now?
  $PROG --check --need 3 --key-file ~/.config/opencode/llama-swap.key \\
      http://<spark-ip>:9292

Example - gate each job of a batch, waiting up to 10 minutes for a slot:
  export LLM_HOST=http://<spark-ip>:9292     # key already in OPENAI_API_KEY
  for task in tasks/*.md; do
    $PROG || break
    run-one-task "\$task"
  done

One line per sample goes to stderr; nothing is written to stdout. The key is
never printed. Over plain http:// the key crosses the network in cleartext,
exactly as it does in normal use.
EOF
}

die_usage() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  printf 'Try: %s --help\n' "$PROG" >&2
  exit 2
}

NEED=1
LIMIT=6
CHECK=0
INTERVAL=5
MAX_WAIT=600
TIMEOUT=15
MODEL=qwen3.8-flash-next
KEY_ENV=OPENAI_API_KEY
KEY_FILE=
QUIET=0
BASE_URL=

# int_opt NAME VALUE MIN -> prints VALUE if it is an integer >= MIN
int_opt() {
  if ! [[ $2 =~ ^[0-9]+$ ]] || [ "$2" -lt "$3" ]; then
    die_usage "$1 must be an integer >= $3"
  fi
  printf '%s' "$2"
}

while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --check) CHECK=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    --need|--limit|--interval|--max-wait|--timeout|--model|--key-env|--key-file)
      [ $# -ge 2 ] || die_usage "$1 needs a value"
      case $1 in
        --need)     NEED=$(int_opt --need "$2" 1) ;;
        --limit)    LIMIT=$(int_opt --limit "$2" 1) ;;
        --interval) INTERVAL=$(int_opt --interval "$2" 1) ;;
        --max-wait) MAX_WAIT=$(int_opt --max-wait "$2" 0) ;;
        --timeout)  TIMEOUT=$(int_opt --timeout "$2" 1) ;;
        --model)
          [[ $2 =~ ^[A-Za-z0-9._-]+$ ]] ||
            die_usage "--model may only contain letters, digits, '.', '_' and '-'"
          MODEL=$2 ;;
        --key-env)
          # Must be a variable NAME. If it is not, the caller has most likely
          # pasted a key here by mistake - so do not echo it back.
          [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            die_usage "--key-env takes the NAME of an environment variable, not a key (value not shown)"
          KEY_ENV=$2 ;;
        --key-file) KEY_FILE=$2 ;;
      esac
      shift 2 ;;
    --) shift; break ;;
    -*) die_usage "unknown option (not echoed, in case it was a pasted key)" ;;
    *)
      [ -z "$BASE_URL" ] || die_usage "only one BASE_URL, please"
      BASE_URL=$1; shift ;;
  esac
done
while [ $# -gt 0 ]; do
  [ -z "$BASE_URL" ] || die_usage "only one BASE_URL, please"
  BASE_URL=$1; shift
done

[ -n "$BASE_URL" ] || BASE_URL=${LLM_HOST-}
[ -n "$BASE_URL" ] || die_usage "BASE_URL is required (argument, or LLM_HOST in the environment)"
[[ $BASE_URL =~ ^https?://[^/[:space:]]+ ]] || die_usage "BASE_URL must start with http:// or https://"
[ "$NEED" -le "$LIMIT" ] || die_usage "--need $NEED can never fit under --limit $LIMIT"
command -v curl >/dev/null 2>&1 || { printf '%s: curl not found\n' "$PROG" >&2; exit 2; }

if [ -n "$KEY_FILE" ]; then
  [ -r "$KEY_FILE" ] || die_usage "--key-file is missing or not readable"
  IFS= read -r KEY <"$KEY_FILE" || true
  KEY_SOURCE="the key file"
else
  KEY=${!KEY_ENV-}
  KEY_SOURCE="variable $KEY_ENV"
fi
KEY=${KEY%$'\r'}
[ -n "$KEY" ] || die_usage "no key: $KEY_SOURCE is unset or empty"
case $KEY in
  *[[:space:]]*) die_usage "the key from $KEY_SOURCE contains whitespace (value not shown)" ;;
esac

BASE_URL=${BASE_URL%/}
BASE_URL=${BASE_URL%/v1}
URL="$BASE_URL/upstream/$MODEL/metrics"

say() {
  [ "$QUIET" -eq 1 ] || printf '%s\n' "$1" >&2
}

# sample -> sets CODE (HTTP status, 000 if the request itself failed) and, on a
# 200 that carries both gauges, RUNNING and WAITING. Returns 0 only then.
# The key travels to curl as a config file on stdin, never in argv. printf is a
# shell builtin, so it does not show up in the process list either.
sample() {
  local esc out body counts
  esc=${KEY//\\/\\\\}
  esc=${esc//\"/\\\"}
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$esc" |
    curl --silent --write-out '\n%{http_code}' \
         --max-time "$TIMEOUT" --config - -- "$URL" 2>/dev/null) || true
  CODE=${out##*$'\n'}
  [[ $CODE =~ ^[0-9]{3}$ ]] || CODE=000
  [ "$CODE" = 200 ] || return 1
  body=${out%$'\n'*}
  # Sum over engines. The [{ ] keeps ..._waiting_by_reason out of the total.
  counts=$(printf '%s\n' "$body" | awk '
    /^vllm:num_requests_running[{ ]/ { r += $NF; fr = 1 }
    /^vllm:num_requests_waiting[{ ]/ { w += $NF; fw = 1 }
    END { if (fr && fw) printf "%d %d", r, w; else exit 1 }') || return 1
  RUNNING=${counts% *}
  WAITING=${counts#* }
  return 0
}

START=$SECONDS
while :; do
  if sample; then
    if [ $((RUNNING + WAITING + NEED)) -le "$LIMIT" ]; then
      say "room: running=$RUNNING waiting=$WAITING need=$NEED limit=$LIMIT"
      exit 0
    fi
    say "busy: running=$RUNNING waiting=$WAITING need=$NEED limit=$LIMIT"
  else
    case $CODE in
      401|403)
        say "$PROG: HTTP $CODE - the key from $KEY_SOURCE was rejected"
        exit 2 ;;
      404)
        say "$PROG: HTTP 404 - no metrics for model '$MODEL' at this BASE_URL"
        exit 2 ;;
      200)
        say "$PROG: the answer carried no vllm:num_requests_* gauges - is '$MODEL' served by vLLM?"
        exit 2 ;;
      000) say "busy: no answer within ${TIMEOUT}s (unreachable, or too busy to report)" ;;
      *)   say "busy: HTTP $CODE from the metrics endpoint" ;;
    esac
  fi
  [ "$CHECK" -eq 0 ] || exit 1
  if [ "$MAX_WAIT" -gt 0 ] && [ $((SECONDS - START + INTERVAL)) -gt "$MAX_WAIT" ]; then
    say "$PROG: gave up after $((SECONDS - START))s without room for $NEED"
    exit 1
  fi
  sleep "$INTERVAL"
done
