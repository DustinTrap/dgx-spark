#!/usr/bin/env bash
# check-keys.sh - read-only check that per-consumer llama-swap keys behave.
#
# For every NAME=ENVVAR pair it reads the key from the CALLER'S environment
# variable ENVVAR and sends one GET /v1/models. It also sends one request with a
# deliberately wrong key and one with no key at all; both must get 401, or the
# endpoint is not enforcing authentication.
#
# It never prints, logs or echoes a key, and never puts one on a command line:
# the Authorization header reaches curl on stdin. It changes nothing on the
# server - GET /v1/models lists models and does not load or unload anything.
#
# No `set -x` here, ever: xtrace would write the keys to the terminal.
set -euo pipefail

PROG=${0##*/}

usage() {
  cat <<EOF
Usage: $PROG [options] BASE_URL NAME=ENVVAR [NAME=ENVVAR ...]

Read-only check of llama-swap bearer keys, one per consumer.

  BASE_URL      e.g. http://<spark-ip>:9292   (no trailing /v1)
  NAME=ENVVAR   NAME is the consumer name you want in the report
                (agent-<host>, dashboard-<host>, webui, standby).
                ENVVAR is the NAME of an environment variable, set in the
                shell that runs this script, that holds that consumer's key.
                The key itself is never an argument.

Expectations:
  NAME=ENVVAR             key must be ACCEPTED  -> HTTP 200 on /v1/models
  --revoked NAME=ENVVAR   key must be REJECTED  -> HTTP 401 (use after removing
                          an old key, to prove the revocation took effect)
  always                  a random wrong key    -> HTTP 401
  always                  no key at all         -> HTTP 401

Options:
  --revoked NAME=ENVVAR   expect 401 for this key (repeatable)
  --timeout SECONDS       per-request limit, default 30. /v1/models can take
                          over 10 s while a long prefill is running.
  -h, --help              show this help

Exit status: 0 everything as expected, 1 at least one check failed, 2 usage.

Example - load the keys into this shell only, then check them by name:
  set -a; . ~/ai-stack/secrets/api-key.env; set +a
  $PROG http://<spark-ip>:9292 \\
      agent-host1=LLM_KEY_AGENT_HOST1 \\
      dashboard-host1=LLM_KEY_DASHBOARD_HOST1 \\
      webui=LLM_KEY_WEBUI standby=LLM_KEY_STANDBY

Example - after retiring a key, prove it is dead and the rest still work:
  read -rs OLD_KEY; export OLD_KEY      # paste the retired key, not echoed
  $PROG http://<spark-ip>:9292 --revoked agent-host1-old=OLD_KEY \\
      agent-host1=LLM_KEY_AGENT_HOST1

Output is one line per check: consumer name, expected and observed HTTP status.
Keys are never printed. Over plain http:// every key checked crosses the
network in cleartext, exactly as it does in normal use - run this from a host
and network you would use the keys on anyway.
EOF
}

die_usage() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  printf 'Try: %s --help\n' "$PROG" >&2
  exit 2
}

TIMEOUT=30
BASE_URL=
PAIRS=()      # "expected_code<TAB>name<TAB>envvar"

add_pair() {
  local expect=$1 pair=$2 name envvar
  case $pair in
    ?*=?*) ;;
    *) die_usage "expected NAME=ENVVAR, got an argument without that shape" ;;
  esac
  name=${pair%%=*}
  envvar=${pair#*=}
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] ||
    die_usage "consumer name may only contain letters, digits, '.', '_' and '-'"
  # ENVVAR must be a variable NAME. If it is not, the caller has most likely
  # pasted a key here by mistake - so do not echo it back.
  [[ $envvar =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
    die_usage "for consumer '$name': the right-hand side must be the NAME of an environment variable, not a key (value not shown)"
  PAIRS+=("$expect"$'\t'"$name"$'\t'"$envvar")
}

while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --timeout)
      [ $# -ge 2 ] || die_usage "--timeout needs a value"
      if ! [[ $2 =~ ^[1-9][0-9]*$ ]]; then die_usage "--timeout must be a positive integer"; fi
      TIMEOUT=$2; shift 2 ;;
    --revoked)
      [ $# -ge 2 ] || die_usage "--revoked needs NAME=ENVVAR"
      add_pair 401 "$2"; shift 2 ;;
    --) shift; break ;;
    -*) die_usage "unknown option (not echoed, in case it was a pasted key)" ;;
    *)
      if [ -z "$BASE_URL" ]; then BASE_URL=$1; else add_pair 200 "$1"; fi
      shift ;;
  esac
done
while [ $# -gt 0 ]; do
  if [ -z "$BASE_URL" ]; then BASE_URL=$1; else add_pair 200 "$1"; fi
  shift
done

[ -n "$BASE_URL" ] || die_usage "BASE_URL is required"
[[ $BASE_URL =~ ^https?://[^/[:space:]]+ ]] || die_usage "BASE_URL must start with http:// or https://"
[ ${#PAIRS[@]} -gt 0 ] || die_usage "give at least one NAME=ENVVAR pair"
command -v curl >/dev/null 2>&1 || { printf '%s: curl not found\n' "$PROG" >&2; exit 2; }

BASE_URL=${BASE_URL%/}
BASE_URL=${BASE_URL%/v1}
URL="$BASE_URL/v1/models"

# probe KEY -> prints the HTTP status (000 if the request itself failed).
# The key travels to curl as a config file on stdin, never in argv. printf is a
# shell builtin, so it does not show up in the process list either.
probe() {
  local key=$1 code esc
  if [ -n "$key" ]; then
    esc=${key//\\/\\\\}
    esc=${esc//\"/\\\"}
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$esc" |
      curl --silent --output /dev/null --write-out '%{http_code}' \
           --max-time "$TIMEOUT" --config - -- "$URL" 2>/dev/null) || true
  else
    code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
           --max-time "$TIMEOUT" -- "$URL" </dev/null 2>/dev/null) || true
  fi
  [[ $code =~ ^[0-9]{3}$ ]] || code=000
  printf '%s' "$code"
}

FAILED=0
report() {   # name expected observed [note]
  local verdict=ok
  if [ "$2" != "$3" ]; then verdict=FAIL; FAILED=1; fi
  printf '%-6s %-28s expected %s  got %s%s\n' "$verdict" "$1" "$2" "$3" "${4:+  ($4)}"
}

note_for() {
  case $1 in
    000) printf 'no HTTP answer: unreachable, timed out, or TLS failure' ;;
    429) printf 'concurrency limit hit, retry' ;;
    *)   printf '' ;;
  esac
}

printf 'Checking %s  (timeout %ss, keys are never shown)\n' "$URL" "$TIMEOUT"

# Indexed arrays of the values seen so far, to flag a key shared by two names.
SEEN_NAMES=()
SEEN_VALUES=()

for entry in "${PAIRS[@]}"; do
  IFS=$'\t' read -r expect name envvar <<<"$entry"
  value=${!envvar-}
  if [ -z "$value" ]; then
    printf '%-6s %-28s variable %s is unset or empty in this shell\n' FAIL "$name" "$envvar"
    FAILED=1
    continue
  fi
  case $value in
    *[[:space:]]*)
      printf '%-6s %-28s value of %s contains whitespace (llama-swap rejects such keys)\n' FAIL "$name" "$envvar"
      FAILED=1
      continue ;;
  esac
  if [ "$expect" = 200 ]; then
    i=0
    while [ "$i" -lt "${#SEEN_VALUES[@]}" ]; do
      if [ "${SEEN_VALUES[$i]}" = "$value" ]; then
        printf '%-6s %-28s same key as %s - one key per consumer, or revoking one revokes both\n' \
          FAIL "$name" "${SEEN_NAMES[$i]}"
        FAILED=1
      fi
      i=$((i + 1))
    done
    SEEN_NAMES+=("$name")
    SEEN_VALUES+=("$value")
  fi
  got=$(probe "$value")
  report "$name" "$expect" "$got" "$(note_for "$got")"
done

# A key that cannot be valid: fresh random bytes every run.
WRONG="invalid-$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
got=$(probe "$WRONG")
note=$(note_for "$got")
[ "$got" = 200 ] && note='a random key was ACCEPTED: authentication is not being enforced'
report '(deliberately wrong key)' 401 "$got" "$note"

got=$(probe '')
note=$(note_for "$got")
[ "$got" = 200 ] && note='a request with NO key was accepted: authentication is not being enforced'
report '(no key)' 401 "$got" "$note"

unset value WRONG SEEN_VALUES

if [ "$FAILED" -eq 0 ]; then
  printf 'All checks passed.\n'
else
  printf 'At least one check FAILED.\n' >&2
fi
exit "$FAILED"
