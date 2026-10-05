#!/usr/bin/env bash
# test-wait-for-slot.sh - run scripts/wait-for-slot.sh against tests/mock_metrics.py
# (issue #25).
#
# Everything stays on 127.0.0.1: it never calls the real endpoint and needs no
# real key. Needs bash, curl and python3. Takes about 15 s, because the waiting
# cases really wait.
#
#   tests/test-wait-for-slot.sh      exit 0 when every case passes
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
S=$HERE/../scripts/wait-for-slot.sh
KEY=test-key-Zq9          # fake; the mock accepts only this
TMP=$(mktemp -d)
MOCK=
cleanup() {
  if [ -n "$MOCK" ]; then
    kill "$MOCK" 2>/dev/null
    wait "$MOCK" 2>/dev/null
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

KF=$TMP/good.key;    printf '%s\n' "$KEY" >"$KF"
CRLFKF=$TMP/crlf.key; printf '%s\r\n' "$KEY" >"$CRLFKF"
BADKF=$TMP/bad.key;  printf 'wrong-key\n' >"$BADKF"
EMPTYKF=$TMP/empty.key; : >"$EMPTYKF"
ALL=$TMP/all-output; : >"$ALL"
PASS=0; FAIL=0

MOCK_KEY=$KEY python3 "$HERE/mock_metrics.py" >"$TMP/port" 2>"$TMP/mock.log" & MOCK=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT=$(head -n 1 "$TMP/port")
[[ $PORT =~ ^[0-9]+$ ]] || { echo "mock server did not start"; exit 1; }
B=http://127.0.0.1:$PORT

ok()  { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# t NAME EXPECTED_EXIT EXPECTED_STDERR_SUBSTRING -- ARGS...
# Runs the script with OPENAI_API_KEY and LLM_HOST cleared. Also checks the
# script's promise that nothing goes to stdout.
t() {
  local name=$1 want=$2 grepfor=$3 got pass=1
  shift 4
  env -u OPENAI_API_KEY -u LLM_HOST "$S" "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  got=$?
  cat "$TMP/stdout" "$TMP/stderr" >>"$ALL"
  [ "$got" = "$want" ] || pass=0
  [ -z "$grepfor" ] || grep -qF -- "$grepfor" "$TMP/stderr" || pass=0
  [ ! -s "$TMP/stdout" ] || pass=0
  if [ $pass = 1 ]; then
    ok "$name"
  else
    bad "$name: exit $got (want $want), stderr: $(tr '\n' ' ' <"$TMP/stderr")"
  fi
}

echo "== decisions"
t "room"                                   0 "room: running=1 waiting=0 need=1 limit=6" -- --check --key-file "$KF" --model room "$B"
t "busy (5+2+1 > 6)"                       1 "busy: running=5 waiting=2" -- --check --key-file "$KF" --model busy "$B"
t "boundary 5+2+1 = 8 <= limit 8"          0 "room: running=5 waiting=2 need=1 limit=8" -- --check --limit 8 --key-file "$KF" --model busy "$B"
t "boundary 5+2+2 = 9 > limit 8"           1 "busy:" -- --check --limit 8 --need 2 --key-file "$KF" --model busy "$B"
t "two engines summed, _by_reason ignored" 0 "room: running=3 waiting=1 need=1" -- --check --key-file "$KF" --model multi "$B"
t "two engines, need 3 (3+1+3 > 6)"        1 "busy: running=3 waiting=1 need=3" -- --check --need 3 --key-file "$KF" --model multi "$B"

echo "== server answers"
t "wrong key: 401, exit 2"                 2 "HTTP 401 - the key from the key file was rejected" -- --check --key-file "$BADKF" --model room "$B"
t "wrong key while waiting: still exit 2"  2 "HTTP 401" -- --interval 1 --max-wait 5 --key-file "$BADKF" --model room "$B"
t "unknown model: 404, exit 2"             2 "HTTP 404 - no metrics for model 'nosuch'" -- --check --key-file "$KF" --model nosuch "$B"
t "200 without the gauges: exit 2"         2 "carried no vllm:num_requests_* gauges" -- --check --key-file "$KF" --model nogauge "$B"
t "HTTP 500 counts as busy"                1 "busy: HTTP 500" -- --check --key-file "$KF" --model err500 "$B"
t "answer slower than --timeout is busy"   1 "no answer within 1s" -- --check --timeout 1 --key-file "$KF" --model slow "$B"
t "nothing listening is busy"              1 "no answer within 2s" -- --check --timeout 2 --key-file "$KF" --model room http://127.0.0.1:1

echo "== waiting"
t "busy twice, then room"                  0 "room: running=1" -- --interval 1 --max-wait 30 --key-file "$KF" --model frees "$B"
n=$(grep -c '^busy:' "$TMP/stderr")
[ "$n" = 2 ] && ok "  ...after exactly 2 busy samples" || bad "  ...after $n busy samples, want 2"
t "stays busy: gives up at --max-wait"     1 "gave up after" -- --interval 1 --max-wait 3 --key-file "$KF" --model busy "$B"

echo "== inputs"
if OPENAI_API_KEY=$KEY "$S" --check --model room "$B" 2>>"$ALL"; then
  ok "key from OPENAI_API_KEY"
else
  bad "key from OPENAI_API_KEY"
fi
if MYKEY=$KEY LLM_HOST=$B/v1/ "$S" --check --key-env MYKEY --model room 2>>"$ALL"; then
  ok "LLM_HOST with a /v1/ suffix, key via --key-env NAME"
else
  bad "LLM_HOST with a /v1/ suffix, key via --key-env NAME"
fi
t "key file with CRLF line ending"         0 "room:" -- --check --key-file "$CRLFKF" --model room "$B"
t "--quiet"                                0 "" -- --check -q --key-file "$KF" --model room "$B"
[ ! -s "$TMP/stderr" ] && ok "  ...prints nothing" || bad "  ...wrote to stderr"
t "need > limit is a usage error"          2 "can never fit" -- --check --need 7 --key-file "$KF" --model room "$B"
t "need = limit is allowed (1+0+6 > 6)"    1 "busy: running=1 waiting=0 need=6 limit=6" -- --check --need 6 --key-file "$KF" --model room "$B"
t "no BASE_URL"                            2 "BASE_URL is required" -- --check --key-file "$KF"
t "BASE_URL without a scheme"              2 "must start with http" -- --check --key-file "$KF" "127.0.0.1:$PORT"
t "empty key file"                         2 "no key" -- --check --key-file "$EMPTYKF" "$B"
t "missing key file"                       2 "missing or not readable" -- --check --key-file "$TMP/nope.key" "$B"
t "--need 0"                               2 "--need must be an integer >= 1" -- --check --need 0 --key-file "$KF" "$B"

echo "== the key is never shown"
t "key pasted into --key-env is not echoed" 2 "value not shown" -- --check --key-env "pasted-$KEY" "$B"
t "key pasted as an option is not echoed"   2 "not echoed" -- --check "--$KEY" "$B"
# Look at the process list while a request is in flight (the slow scenario
# answers after 4 s).
env -u OPENAI_API_KEY "$S" --check --key-file "$KF" --model slow "$B" 2>>"$ALL" & BG=$!
sleep 1.5
PS=$(ps -A -ww -o pid=,args= | grep -E 'curl|wait-for-slot' | grep -v grep || true)
wait "$BG"
if printf '%s' "$PS" | grep -qF -- "$KEY"; then
  bad "key visible in the process list"
elif printf '%s' "$PS" | grep -q curl; then
  ok "curl in the process list mid-request, key not on its command line"
else
  bad "did not catch curl mid-request (inconclusive)"
fi
if grep -qF -- "$KEY" "$ALL"; then
  bad "key appears in captured output"
else
  ok "key absent from all captured stdout and stderr"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
