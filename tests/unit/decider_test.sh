#!/usr/bin/env bash
# lib/decider.sh: the protocol client and its shared per-loop budget, the
# mode, the calibration gate and the slow-machine cap, the rerank's size, the auto-start headroom
# gate, starting the local service exactly once, idle shutdown and restart,
# concurrent loops taking turns at the local decider, the device it serves
# on, the benchmark, and the chalk-embed contract.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime core/jobs core/system db decider dashboard

export XDG_STATE_HOME="$tmp/state" FAKE_STATE="$tmp/fake"
mkdir -p "$FAKE_STATE" "$tmp/bin"
PATH="$CHALK_HOME/tests/fakes:$tmp/bin:$PATH"

CHALK_DECIDER=shadow CHALK_DECIDER_URL="http://decider.test" CHALK_DECIDER_TOKEN=""
CHALK_EMBED_URL="http://embed.test" CHALK_DECIDER_THRESHOLD=0.9 CHALK_DECIDER_MIN_LESSONS=30
CHALK_DECIDER_IDLE_MINUTES=30 CHALK_DECIDER_TIMEOUT=auto
RUN_ID="" RUN_IO=""

fails() { ! "$@"; }
noul='{"stuck":{"type":"noul","instructions":"Is the agent stuck?"}}'
declare -A got=()

# ask [ENV=VALUE...]: decider_ask about a fixed text, with the fake decider
# scripted by the given variables.
ask() {
  local -a vars=("$@")
  local var
  for var in "${vars[@]}"; do export "${var?}"; done
  decider_ask "FAILED tests/test_app.py::test_marker" "$noul" got
  local status=$?
  for var in "${vars[@]}"; do unset "${var%%=*}"; done
  return "$status"
}

# --- another machine: nothing is sent before `chalk decider trust` --------

for url in http://127.0.0.1:8471 http://localhost:9000/v1 "http://[::1]:8471" http://127.1.2.3 HTTP://LOCALHOST \
           http://user@127.0.0.1:8471; do
  check "$url is this machine" decider_loopback "$url"
done
for url in http://decider.test https://127.0.0.1.example.com http://localhost@decider.test:80 \
           http://10.0.0.1:8471 "http://[::2]:8471" http://localhost.example.com http://0.0.0.0:8471; do
  check "$url is another machine" fails decider_loopback "$url"
done

: > "$FAKE_STATE/curl.log"
decider_budget_reset
ask 2> "$tmp/untrusted.err" || true
check "a decider on another machine that was not acknowledged is not asked" test ! -s "$FAKE_STATE/curl.log"
check "... named untrusted" test "$DECIDER_ERROR" = untrusted
check "... and the warning says what to run" \
  grep -q 'http://decider.test is on another machine, and nothing is sent there .* run: chalk decider trust http://decider.test$' \
    "$tmp/untrusted.err"
check "... nor checked for health" fails decider_healthy http://decider.test
check "... and chalk-embed on another machine is sent nothing either" test -z "${| decider_embed one; }"
check "... named untrusted" test "$DECIDER_ERROR" = untrusted
check "... and still nothing reached either" test ! -s "$FAKE_STATE/curl.log"

# decider_gate, as a run starts: the decider off, said once, with what it
# would have received.
DECIDER_WARNED=()
decider_gate 2> "$tmp/gate.err"
check "a run with an unacknowledged decider goes on with the decider off" test "$CHALK_DECIDER" = off
check "... saying where it would have sent, and how to allow it" \
  grep -q '^warning: continuing with the decider off: http://decider.test and http://embed.test are on another machine' "$tmp/gate.err"
check "... and exactly what it would send: the stuck question's facts and caps" \
  grep -q "the failing test IDs (up to 20) and the first error line" "$tmp/gate.err"
check "... the rerank's failure and lesson texts, and their caps" \
  grep -q "failure and fix note of up to $DECIDER_SHORTLIST past lessons; at most $DECIDER_RERANK_CHARS characters" "$tmp/gate.err"
check "... and what chalk-embed would get" grep -q '^  The embedding service (http://embed.test) gets' "$tmp/gate.err"
CHALK_DECIDER=shadow
decider_gate 2> "$tmp/gate.err"
check "... said once a process" test ! -s "$tmp/gate.err"
CHALK_DECIDER=shadow

# chalk decider trust: shows what is sent, then records the URL.
decider_trust http://decider.test/ > "$tmp/trust.out"
check "chalk decider trust shows what the decider gets" grep -q '^The decider (http://decider.test) gets' "$tmp/trust.out"
check "... records the URL, without its trailing slash" grep -qx 'http://decider.test' "${| decider_trust_file; }"
check "... and then the decider is asked" ask
check "... though not a URL that only starts the same" fails decider_acknowledged http://decider.test.example.com/v1/systemone
check "chalk-embed's URL is still not acknowledged" test -z "${| decider_embed one; }"
check "trusting a URL twice records it once" \
  test "$(decider_trust http://decider.test | tail -n 1; grep -c . "${| decider_trust_file; }")" = $'already acknowledged: http://decider.test\n1'
check "trusting this machine records nothing" \
  test "$(decider_trust http://localhost:8471; grep -c localhost "${| decider_trust_file; }" || true)" = $'http://localhost:8471 is on this machine: nothing to acknowledge\n0'
decider_untrust http://decider.test >/dev/null
check "chalk decider untrust takes it back" fails decider_acknowledged http://decider.test
DECIDER_WARNED=()
decider_gate 2>/dev/null
check "... and the next run goes on with the decider off" test "$CHALK_DECIDER" = off
CHALK_DECIDER=shadow
decider_trust http://decider.test >/dev/null
decider_trust http://embed.test >/dev/null
DECIDER_WARNED=()
check "once both are acknowledged, a run keeps the decider" \
  test "$(decider_gate 2>&1; printf '%s' "$CHALK_DECIDER")" = \
    "decider: questions go to http://decider.test (acknowledged; what it gets: chalk decider status)
shadow"

# --- answers ----------------------------------------------------------------

decider_budget_reset
ask FAKE_DECIDER_ANSWERS="stuck=0.97" || true
check "a noul answer at 0.97 is yes at 970 thousandths" test "${got[stuck]-}" = "yes 970"
check "... and records which model answered" test "$DECIDER_ANSWERED_BY" = fake-decider
check "the request follows the protocol: version, state and questions" \
  jq -e '.protocol == 1 and .state == "FAILED tests/test_app.py::test_marker" and .questions.stuck.type == "noul"' \
    <<<"$(tail -n 1 "$FAKE_STATE/decider.log")"
decider_budget_reset
ask FAKE_DECIDER_ANSWERS="stuck=0.02" || true
check "a noul answer at 0.02 is no at 980 thousandths" test "${got[stuck]-}" = "no 980"
decider_budget_reset
ask FAKE_DECIDER_ANSWERS="stuck=-" || true
check "a key the decider leaves out is no answer for it" test -z "${got[stuck]-}"
decider_budget_reset
check "a newer protocol is not understood" fails ask FAKE_DECIDER_PROTOCOL=2
check "... and is named as a version error" test "$DECIDER_ERROR" = version
decider_budget_reset
check "a protocol of 1 in the answer is understood" ask FAKE_DECIDER_PROTOCOL=1
decider_budget_reset
check "nothing listening is no answer" fails ask FAKE_DECIDER_DOWN=1
check "... named unreachable" test "$DECIDER_ERROR" = unreachable
decider_budget_reset
check "a server error is no answer" fails ask FAKE_DECIDER_STATUS=500
check "... named server" test "$DECIDER_ERROR" = server
decider_budget_reset
check "a request the decider rejects is no answer" fails decider_ask "" "$noul" got
check "... named rejected (the fake checks the protocol)" test "$DECIDER_ERROR" = rejected

# --- the token --------------------------------------------------------------

: > "$FAKE_STATE/decider.log"
: > "$FAKE_STATE/curl.log"
CHALK_DECIDER_TOKEN="s3cret-token"
decider_budget_reset
check "with CHALK_DECIDER_TOKEN, the decider gets the bearer token" ask FAKE_DECIDER_TOKEN=s3cret-token
check "... sent as a header" grep -q 'auth=yes' "$FAKE_STATE/decider.log"
decider_budget_reset
check "a token the decider refuses is no answer" fails ask FAKE_DECIDER_TOKEN=other
check "... named auth" test "$DECIDER_ERROR" = auth
check "the token never appears in what curl was given or logged" \
  fails grep -rq 's3cret-token' "$FAKE_STATE"
CHALK_DECIDER_TOKEN=""

# --- one budget per loop ----------------------------------------------------

# Each call waits 0.8 s. Over a 2 s budget, two calls answer, the third
# gets what is left and times out, and the rest are not made.
: > "$FAKE_STATE/decider.log"
decider_budget_reset
started="${| decider_now_ms; }"
results=()
for i in 1 2 3 4 5; do
  if ask FAKE_DECIDER_DELAY=0.8; then results+=(ok); else results+=("$DECIDER_ERROR"); fi
done
elapsed=$(( ${| decider_now_ms; } - started ))
# How many calls fit depends on how long this machine takes between calls
# (process start, jq), so check the shape rather than exact counts: answers
# first, then at most one call cut off by what was left, then only skipped
# calls, and never an answer after one failed.
check "calls share one 2 s budget: answers, then at most one timeout, then skipped" \
  sh -c 'printf "%s\n" "$1" | grep -Eqx "(ok )+(timeout )?budget( budget)*"' _ "${results[*]}"
# Waiting on the services is held to the budget; reading their answers
# (jq, a few milliseconds a call) comes on top.
check "... and wait no more than the budget (${DECIDER_SPENT_MS} ms)" test "$DECIDER_SPENT_MS" -le 2150
# Generous on purpose: it only catches waiting that is not capped at all.
check "... in about that time in all (${elapsed} ms)" test "$elapsed" -le 4000
mapfile -t limits < <(sed -n 's/^max-time=\([0-9.]*\) .*/\1/p' "$FAKE_STATE/decider.log")
check "each call's --max-time is what is left of the budget" \
  test "${limits[0]}" = "2.000" -a "${#limits[@]}" -ge 2
check "... and gets smaller" awk -v a="${limits[0]}" -v b="${limits[-1]}" 'BEGIN { exit !(b < a && b > 0) }'
decider_budget_reset
check "a new loop gets a new budget" ask

decider_budget_reset
started="${| decider_now_ms; }"
check "a decider slower than the budget is no answer" fails ask FAKE_DECIDER_DELAY=5
elapsed=$(( ${| decider_now_ms; } - started ))
check "... named timeout, after no more than the budget (${elapsed} ms)" \
  test "$DECIDER_ERROR" = timeout -a "$elapsed" -le 2500

# --- thresholds and modes ---------------------------------------------------

for pair in 0.9:900 1:1000 0.95:950 0.875:875 0.5:500; do
  CHALK_DECIDER_THRESHOLD="${pair%%:*}"
  check "threshold ${pair%%:*} is ${pair#*:} thousandths" test "${| decider_threshold_milli; }" = "${pair#*:}"
done
CHALK_DECIDER_THRESHOLD=0.9

dir="${| decider_dir; }"
mkdir -p "$dir"
installed() { printf 'decider_model=%s@%s\nbench_ms=%s\n' "$DECIDER_MODEL" "${2:-0123456789abcdef}" "$1" > "$dir/installed"; }

# --- the calibration gate ---------------------------------------------------

# A stand-in for the database: db_decider_calibration prints $calibration,
# one provider per line of "URL MODEL T:JUDGED:CORRECT:WAITING...", most
# recent first; with calibration unset, the database does not answer.
db_decider_calibration() {
  [[ -v calibration ]] || return 1
  local url model levels_line
  local -a levels
  while read -r url model levels_line; do
    [[ -n $url ]] || continue
    read -ra levels <<<"$levels_line"
    jq -cn --arg url "$url" --arg model "$model" '
      {url: $url, model: $model, last: "2026-10-01T00:00:00Z",
       levels: [$ARGS.positional[] | split(":") | map(tonumber)
                | {t: .[0], judged: .[1], correct: .[2], waiting: .[3]}]}' --args "${levels[@]}"
  done <<<"$calibration" | jq -cs .
}
# gate [LINES]: the database holds LINES (none: it does not answer), read
# afresh, with no answer yet in this process and no warning given.
gate() {
  if (( $# )); then calibration="$1"; else unset calibration; fi
  DECIDER_CALIBRATION_READ=0 DECIDER_ANSWERED_BY="" DECIDER_ERROR="" DECIDER_WARNED=()
}
# judged FIELD...: the current provider's judgement, its fields joined by spaces.
judged() {
  local -A cal
  local field out=()
  decider_calibration cal
  for field in "$@"; do out+=("${cal[$field]}"); done
  printf '%s\n' "${out[*]}"
}
# note: the current provider's judgement in words.
note() {
  local -A cal
  decider_calibration cal
  printf '%s\n' "${| decider_calibration_note cal; }"
}
hosted="http://decider.test"
CHALK_DECIDER=on CHALK_DECIDER_URL="$hosted"

gate
check "with no database, the gate is unknown" test "$(judged status)" = unknown
check "... and on is held to shadow" test "${| decider_mode 2>/dev/null; }" = shadow
gate
check "... saying why, once per run" \
  test "$(decider_mode 2>&1; decider_mode 2>&1)" = "warning: CHALK_DECIDER=on records in shadow mode only: the decider at $hosted: its calibration could not be read from the telemetry database (see: chalk doctor)"
gate ""
check "a decider never recorded is not calibrated, with nothing judged" test "$(judged status judged)" = "uncalibrated 0"
gate "$hosted fake-decider 0.95:19:19:3"
check "19 runs right of 19 is too few" test "$(judged status judged correct waiting)" = "uncalibrated 19 19 3"
check "... and on is held to shadow" test "${| decider_mode 2>/dev/null; }" = shadow
gate "$hosted fake-decider 0.95:19:19:3"
check "... saying how far it is, once" \
  test "$(decider_mode 2>&1; decider_mode 2>&1)" = "warning: CHALK_DECIDER=on records in shadow mode only: fake-decider at $hosted is not calibrated yet: 19 shadow run(s) judged at CHALK_DECIDER_THRESHOLD=0.9, 19 right (100%), 3 not settled yet; it needs 90% right over at least 20 (see: chalk doctor)"
gate "$hosted fake-decider 0.95:20:17:0"
check "17 right of 20 (85%) is not right often enough" test "$(judged status)" = uncalibrated
gate "$hosted fake-decider 0.95:20:18:0"
check "18 right of 20 (90%) is calibrated" test "$(judged status)" = calibrated
check "... and on acts, saying nothing" test "$(decider_mode 2>&1):${| decider_mode; }" = ":on"
check "... in words" test "$(note)" = \
  "fake-decider at $hosted is calibrated: 20 shadow run(s) judged at CHALK_DECIDER_THRESHOLD=0.9, 18 right (90%)"

# The levels are the confidences it said "stuck" at; a threshold takes the
# lowest one at or above it. Here it was right at 0.75 and above, wrong below.
gate "$hosted fake-decider 0.6:26:20:0 0.75:20:20:0 0.8:12:12:0"
check "at 0.9 nothing it said counts, and the lowest threshold that would pass is suggested" \
  test "$(judged status judged suggested)" = "uncalibrated 0 0.75"
check "... in words" test "${| decider_hold; }" = \
  "CHALK_DECIDER=on records in shadow mode only: fake-decider at $hosted is not calibrated yet: 0 shadow run(s) judged at CHALK_DECIDER_THRESHOLD=0.9; it needs 90% right over at least 20; it would be at CHALK_DECIDER_THRESHOLD=0.75 (see: chalk doctor)"
CHALK_DECIDER_THRESHOLD=0.7
gate "$hosted fake-decider 0.6:26:20:0 0.75:20:20:0 0.8:12:12:0"
check "at 0.7 the answers at 0.75 and above count, and it is calibrated" test "$(judged status judged)" = "calibrated 20"
CHALK_DECIDER_THRESHOLD=0.6
gate "$hosted fake-decider 0.6:26:20:0 0.75:20:20:0 0.8:12:12:0"
check "at 0.6 the false stops below 0.75 count too (77%), and it is not" test "$(judged status judged correct)" = "uncalibrated 26 20"
CHALK_DECIDER_THRESHOLD=0.9

# A provider is its URL and its model's revision.
gate "http://other.test fake-decider 0.95:30:30:0
$hosted other-model 0.95:30:30:0
$hosted fake-decider 0.95:3:3:0"
check "before any answer, a hosted decider is judged by the latest model recorded at its URL" \
  test "$(judged status model)" = "calibrated other-model"
DECIDER_ANSWERED_BY="fake-decider"
check "... once one answers, by that model: another URL's or model's calibration does not count" \
  test "$(judged status model judged)" = "uncalibrated fake-decider 3"
gate "http://other.test fake-decider 0.95:30:30:0
$hosted fake-decider 0.95:3:3:0"
CHALK_DECIDER_URL="http://user:pw@decider.test/"
check "the URL is judged without its credentials or a trailing slash" test "$(judged url judged)" = "$hosted 3"
CHALK_DECIDER_URL="$hosted"

CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"
installed 153
gate "$DECIDER_LOCAL_URL fake-decider@0123456 0.95:25:25:0"
check "before any answer, the local decider is judged by the revision installed" \
  test "$(judged status model)" = "calibrated fake-decider@0123456"
check "on stays on where the local decider is fast enough and calibrated" test "${| decider_mode; }" = on
installed 153 abcdef0123456789
gate "$DECIDER_LOCAL_URL fake-decider@0123456 0.95:25:25:0"
check "a new revision starts again, in shadow" \
  test "$(judged status model judged)" = "uncalibrated ${DECIDER_MODEL#*/}@abcdef0 0"
DECIDER_ANSWERED_BY="fake-decider@abcdef0"
check "... and so do its answers" test "$(judged status model)" = "uncalibrated fake-decider@abcdef0"
gate "$DECIDER_LOCAL_URL fake-decider@abcdef0 0.9:2:2:0
$DECIDER_LOCAL_URL fake-decider@0123456 0.95:25:25:0"
check "... however the old one did" test "$(judged status judged)" = "uncalibrated 2"
installed 153
gate "$DECIDER_LOCAL_URL fake-decider@0123456 0.95:25:25:0
$hosted fake-decider 0.95:25:25:0 0.97:25:25:0"
installed 1400
check "on is held to shadow where the local decider took over 1 s" test "${| decider_mode; }" = shadow 2>/dev/null
check "... and that is said once" test "$(decider_mode 2>&1; decider_mode 2>&1)" = ""
CHALK_DECIDER_URL="http://decider.test"
check "the cap applies only to the local decider" test "${| decider_mode; }" = on
CHALK_DECIDER=shadow
check "shadow is shadow" test "${| decider_mode; }" = shadow
CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"
installed 153
CHALK_DECIDER=on
decider_budget_reset
check "answers from the local decider name its revision" ask
check "... the first seven characters of it" test "$DECIDER_ANSWERED_BY" = fake-decider@0123456

# --- the stuck question -----------------------------------------------------

RUN_ID="T-1" RUN_IO="$tmp/io"
mkdir -p "$RUN_IO"
CHALK_DECIDER_URL="http://decider.test"
export FAKE_DECIDER_ANSWERS="stuck=0.95"
decider_budget_reset
check "on: a confident yes may act" test "${| decider_stuck "state"; }" = "yes 950"
CHALK_DECIDER_THRESHOLD=0.96
decider_budget_reset
check "on: a yes below the threshold does not" test -z "${| decider_stuck "state"; }"
CHALK_DECIDER_THRESHOLD=0.9 CHALK_DECIDER=shadow
decider_budget_reset
check "shadow: a confident yes never acts" test -z "${| decider_stuck "state"; }"
unset FAKE_DECIDER_ANSWERS
CHALK_DECIDER=on
decider_budget_reset
FAKE_DECIDER_DOWN=1 decider_stuck "state"
check "no answer never acts" test -z "$REPLY"
check "every decision is kept for the loop's call, acted or not" \
  test "$(jq -sc '[.[] | [.kind, .answer, (.confidence | if . then . * 1 else . end), .acted, .mode, .error]]' \
            "$RUN_IO/decisions.jsonl")" = \
    '[["stuck","yes",0.95,true,"on",null],["stuck","yes",0.95,false,"on",null],["stuck","yes",0.95,false,"shadow",null],["stuck",null,null,false,"on","unreachable"]]'
check "... with the threshold and how long it took" \
  jq -se 'all(.[]; .threshold == 0.9 or .threshold == 0.96) and all(.[]; .latency_ms >= 0)' "$RUN_IO/decisions.jsonl"
check "... and the URL asked, which with the model names the provider" \
  jq -se --arg url "$hosted" 'all(.[]; .url == $url)' "$RUN_IO/decisions.jsonl"
rm -f "$RUN_IO/decisions.jsonl"
gate "$hosted fake-decider 0.95:5:5:0"
export FAKE_DECIDER_ANSWERS="stuck=0.97"
decider_budget_reset
decider_stuck "state" 2>"$tmp/held.err"
check "on, not calibrated: a confident yes does not act" test -z "$REPLY"
check "... it is recorded as a shadow answer, which the gate counts" \
  test "$(jq -c '[.answer, .mode, .acted, .model]' "$RUN_IO/decisions.jsonl")" = '["yes","shadow",false,"fake-decider"]'
check "... and the run is told why, with the numbers" \
  grep -q '^warning: CHALK_DECIDER=on records in shadow mode only: fake-decider at http://decider.test is not calibrated yet: 5 shadow run(s) judged' "$tmp/held.err"
gate "$hosted fake-decider 0.95:5:5:0"
decider_budget_reset
check "... but not after a call that got no answer: a decider that is down stays quiet" \
  test -z "$(FAKE_DECIDER_DOWN=1 decider_stuck "state" 2>&1)"
gate "$hosted fake-decider 0.95:5:5:0"
CHALK_DECIDER=shadow
decider_budget_reset
check "shadow says nothing about the gate" test -z "$(decider_stuck "state" 2>&1)"
CHALK_DECIDER=on
unset FAKE_DECIDER_ANSWERS
gate "$hosted fake-decider 0.95:25:25:0"
long="$(printf 'x%.0s' {1..9000})"
decider_budget_reset
decider_stuck "$long" >/dev/null
check "the stuck question's text is capped near 1,500 tokens" \
  test "$(tail -n 1 "$FAKE_STATE/decider.log" | jq -r '.state | length')" -eq "$DECIDER_STATE_CHARS"
rm -f "$RUN_IO/decisions.jsonl"
RUN_ID=""

# --- embeddings -------------------------------------------------------------

decider_budget_reset
vectors="${| decider_embed "one" "two"; }"
check "one embedding per text, in pgvector's text form" \
  test "$(wc -l <<<"$vectors" | tr -d ' '):$(head -n 1 <<<"$vectors" | jq length)" = 2:384
decider_budget_reset
check "no embeddings when chalk-embed is down" test -z "${| FAKE_DECIDER_DOWN=1 decider_embed one; }"

# --- the rerank's size ------------------------------------------------------

# Stand-ins for the database: enough resolved lessons, no embeddings, and a
# shortlist of two exact matches and N other lessons. With gate=none, the
# database does not answer.
gate="40 0"
db_decider_gate() { [[ $gate != none ]] || return 1; echo "$gate"; }
db_recall_shortlist() { printf '%s\n' "$recall_shortlist"; }
# lessons N FAILURE FIX: that shortlist, every lesson with FAILURE and FIX.
lessons() {
  jq -cn --argjson n "$1" --arg f "$2" --arg x "$3" '
    [range(1; 3) | {id: ., exact: true, line: "- exact \(.)", failure: $f, fix: $x}]
    + [range(10; 10 + $n) | {id: ., exact: false, line: "- other \(.)", failure: $f, fix: $x}]'
}
# rerank QUERY: decider_recall's request to the fake decider, as JSON.
rerank() {
  decider_budget_reset
  decider_recall picked demo failure "$1" >/dev/null 2>&1 || true
  sent="$(tail -n 1 "$FAKE_STATE/decider.log")"
}
size='(.state | length) + ([.questions[].instructions | length] | add)'
fix_part='.questions.lesson_10.instructions | split("\nIts fix: ")[1] | length'
RUN_ID="T-2" RUN_IO="$tmp/io" CHALK_DECIDER=shadow CHALK_DECIDER_URL="http://decider.test"
# The worst case: a long failure, and every lesson at the 400 characters
# db_recall_shortlist allows its failure and its fix, non-ASCII included.
long="$(printf 'AssertionError: Größe überschritten in tests/test_orders.py %.0s' {1..20})"
recall_shortlist="$(lessons "$DECIDER_SHORTLIST" "${long:0:400}" "${long:0:400}")"
rerank "$(printf 'FAILED tests/test_api.py::test_create - KeyError %.0s' {1..300})"
check "the largest rerank fits DECIDER_RERANK_CHARS ($(jq "$size" <<<"$sent") of $DECIDER_RERANK_CHARS)" \
  jq -e --argjson max "$DECIDER_RERANK_CHARS" "$size <= \$max" <<<"$sent"
check "... the failure cut to DECIDER_RERANK_STATE_CHARS" \
  jq -e --argjson n "$DECIDER_RERANK_STATE_CHARS" '.state == "Current failure:\n" + .state[17:] and (.state[17:] | length) == $n' <<<"$sent"
check "... asking about every lesson that is not an exact match, and no exact match" \
  jq -e --argjson n "$DECIDER_SHORTLIST" '(.questions | keys) == ([range(10; 10 + $n) | "lesson_\(.)"] | sort)' <<<"$sent"
check "... each with part of its failure and part of its fix, each cut with …" \
  jq -e 'all(.questions[].instructions; test("\nPast failure: AssertionError: Größe[^\n]*…\nIts fix: AssertionError[^\n]*…$"))' <<<"$sent"
check "at 3 characters a token, it is within the 3,072-token window the decider was evaluated at" \
  test $((DECIDER_RERANK_CHARS / 3)) -le 3072
half="$(jq "$fix_part" <<<"$sent")"
recall_shortlist="$(lessons "$DECIDER_SHORTLIST" "KeyError: 'id'" "${long:0:400}")"
rerank "KeyError: 'id'"
check "a short failure leaves the rest of its share to the fix ($(jq "$fix_part" <<<"$sent") > $half characters)" \
  test "$(jq "$fix_part" <<<"$sent")" -gt "$half"
recall_shortlist="$(lessons 2 "KeyError: 'id'" "Seed the fixture first.")"
rerank "KeyError: 'id'"
check "a rerank that fits is sent whole" \
  jq -e --arg ask "$DECIDER_LESSON_QUESTION" \
    '.state == "Current failure:\nKeyError: '"'id'"'" and all(.questions[].instructions;
       . == $ask + "\nPast failure: KeyError: '"'id'"'\nIts fix: Seed the fixture first.")' <<<"$sent"
rm -f "$RUN_IO/decisions.jsonl"
RUN_ID="" CHALK_DECIDER=on

# --- the auto-start headroom gate -------------------------------------------

CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"
SYS=() SYS_PROBED=1
SYS["ram_mb"]=16384 SYS["docker_mem_mb"]=12288
CHALK_DECIDER=shadow
check "shadow: no auto-start with under 6 GiB beside Docker" fails decider_autostart_ok
check "... said in a warning" test -n "${DECIDER_WARNED[headroom]-}"
CHALK_DECIDER=on
check "on: auto-start whatever the headroom" decider_autostart_ok
CHALK_DECIDER=shadow SYS["docker_mem_mb"]=8192
check "shadow: auto-start with 8 GiB beside Docker" decider_autostart_ok
SYS=() SYS_PROBED=1
check "auto-start when the host profile is unknown" decider_autostart_ok
rm -f "$dir/installed"
check "no auto-start before chalk decider up" fails decider_autostart_ok
installed 153
CHALK_DECIDER_URL="http://decider.test"
check "no auto-start of a decider someone else runs" fails decider_autostart_ok
CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"

# --- starting once, idle shutdown, restart ----------------------------------

# Stand-ins for what uv installs: strands-decider, and chalk-embed run by
# `uv run --script`. Each records that it started and waits to be stopped.
mkdir -p "$tmp/uvbin"
cat > "$tmp/uvbin/strands-decider" <<STUB
#!/usr/bin/env bash
echo "decider \$\$ \$*" >> "$tmp/started"
exec sleep 60
STUB
cat > "$tmp/bin/uv" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "tool dir") echo "$tmp/uvbin" ;;
  "run --script")
    while [ \$# -gt 0 ]; do [ "\$1" = --pidfile ] && echo "\$\$" > "\$2"; shift; done
    echo "embed \$\$" >> "$tmp/started"
    exec sleep 60 ;;
esac
STUB
chmod +x "$tmp/uvbin/strands-decider" "$tmp/bin/uv"

# Without a real flock (stock macOS), a stand-in on the same flock(2) call.
if ! command -v flock >/dev/null 2>&1; then
  cat > "$tmp/bin/flock" <<'PERL'
#!/usr/bin/perl
use strict; use warnings; use Fcntl qw(:flock); use Time::HiRes qw(sleep time);
my ($nonblock, $wait) = (0, 0);
while (@ARGV > 1) {
  my $arg = shift @ARGV;
  if ($arg eq '-n') { $nonblock = 1 } elsif ($arg eq '-w') { $wait = shift @ARGV }
}
open(my $fh, '>>&=', $ARGV[0]) or die "flock: fd $ARGV[0]: $!\n";
my $deadline = time + $wait;
while (1) {
  exit 0 if flock($fh, LOCK_EX | LOCK_NB);
  exit 1 if $nonblock || time >= $deadline;
  sleep 0.05;
}
PERL
  chmod +x "$tmp/bin/flock"
fi

for has_flock in 1 0; do
  SYS=() SYS_PROBED=1 SYS[has_flock]="$has_flock"
  rm -f "$tmp/started"
  touch "$tmp/started"
  decider_start_once > "$tmp/a.log" 2>&1 &
  a=$!
  decider_start_once > "$tmp/b.log" 2>&1 &
  b=$!
  wait "$a" "$b"
  for _ in $(seq 1 50); do [[ $(grep -c . "$tmp/started" 2>/dev/null) -ge 2 ]] && break; sleep 0.1; done
  sleep 0.3
  check "two runs starting the decider at once start one of each (has_flock=$has_flock)" \
    test "$(grep -c '^decider' "$tmp/started"):$(grep -c '^embed' "$tmp/started")" = 1:1
  check "... and it is alive" decider_alive
  check "... and the lock is free again" chalk_lock decider 0
  chalk_unlock decider
  decider_start_once >/dev/null 2>&1
  check "a run finding it alive starts nothing" test "$(grep -c . "$tmp/started")" -eq 2
  decider_stop
  check "chalk decider down stops both" fails decider_alive
done

# Idle shutdown: with a 2 s idle time checked every 0.2 s, an untouched
# decider stops by itself, and the next run starts it again. (File times
# are whole seconds, so the idle time is too.)
export DECIDER_WATCH_SECONDS=0.2 DECIDER_IDLE_SECONDS=2
DECIDER_WATCH_SECONDS=0.2
rm -f "$tmp/started"
decider_start_once >/dev/null 2>&1
for _ in $(seq 1 30); do [[ -n ${| decider_pid embed; } ]] && break; sleep 0.1; done
check "the started decider has a watcher" test -n "${| decider_pid watch; }"
for _ in $(seq 1 50); do decider_alive || break; sleep 0.1; done
check "an idle decider stops itself" fails decider_alive
for _ in $(seq 1 20); do [[ -e $dir/decider.pid || -e $dir/embed.pid ]] || break; sleep 0.1; done
check "... and removes its pidfiles" test ! -e "$dir/decider.pid" -a ! -e "$dir/embed.pid"
for _ in $(seq 1 20); do [[ -z ${| decider_pid watch; } ]] && break; sleep 0.1; done
check "... and its watcher ends" test -z "${| decider_pid watch; }"
decider_start_once >/dev/null 2>&1
check "the next run starts it again" test "$(grep -c '^decider' "$tmp/started")" -eq 2
# Used, it keeps running past the idle time.
for _ in $(seq 1 16); do decider_touch; sleep 0.2; done
check "a decider in use is not stopped" decider_alive
decider_stop
unset DECIDER_IDLE_SECONDS

# strands-decider dying alone, as it does on MPS when asked two things at
# once, leaves chalk-embed up: the next start stops that and starts both.
rm -f "$tmp/started"
decider_start_once >/dev/null 2>&1
for _ in $(seq 1 30); do [[ -n ${| decider_pid embed; } ]] && break; sleep 0.1; done
old_embed="${| decider_pid embed; }"
kill "${| decider_pid decider; }"
for _ in $(seq 1 20); do [[ -z ${| decider_pid decider; } ]] && break; sleep 0.1; done
decider_start_once >/dev/null 2>&1
for _ in $(seq 1 30); do [[ $(grep -c '^embed' "$tmp/started") -ge 2 ]] && break; sleep 0.1; done
check "a decider that died alone is started again, with chalk-embed" \
  test "$(grep -c '^decider' "$tmp/started"):$(grep -c '^embed' "$tmp/started")" = 2:2
check "... and the chalk-embed it left is stopped" fails kill -0 "$old_embed"
decider_stop

# --- starting only once a question can be asked (#85) -----------------------

# Below CHALK_DECIDER_MIN_LESSONS resolved lessons, lesson rerank cannot be
# asked, so a run waits for a failed loop to start the service.
gate="4 1"
check "the resolved lessons lesson rerank waits for are counted" test "${| decider_lessons; }" = 4
gate=none
check "... and not guessed without the database" test -z "${| decider_lessons; }"
gate="40 0"

SYS=() SYS_PROBED=1
rm -f "$tmp/started"
touch "$tmp/started"
CHALK_DECIDER=off
check "decider off: a run starts nothing" fails decider_start_bg "$tmp/bg/start.log"
CHALK_DECIDER=shadow
check "shadow, installed and stopped: a run starts it in the background" decider_start_bg "$tmp/bg/start.log"
for _ in $(seq 1 50); do [[ -n ${| decider_pid decider; } ]] && break; sleep 0.1; done
check "... with its output in the run's log" test -e "$tmp/bg/start.log"
check "... and once: running, it is not started again" fails decider_start_bg "$tmp/bg/start.log"

# A question while strands-decider loads its model (its process is up, but
# nothing listens yet) gets no answer, recorded as starting; once it has
# been up for longer than its start may take, as unreachable.
decider_budget_reset
ask FAKE_DECIDER_DOWN=1 || true
check "a question while the decider is starting is recorded as starting, not unreachable" \
  test "$DECIDER_ERROR" = starting
touch -t 202001010000 "$dir/decider.pid"
decider_budget_reset
ask FAKE_DECIDER_DOWN=1 || true
check "... and one to a decider up for long that does not answer, as unreachable" test "$DECIDER_ERROR" = unreachable
decider_stop
CHALK_DECIDER=on

# --- why nothing was asked (#85) --------------------------------------------

# reach LOOPS FAILED GRAY BLOCKED_RUNS QUESTIONS LESSONS: db_decider_reach's record.
reach() {
  jq -cn --argjson l "$1" --argjson f "$2" --argjson g "$3" --argjson b "$4" --argjson q "$5" --argjson n "$6" \
    '{days: 30, loops: $l, failed: $f, gray: $g, unticked: 0, blocked_runs: $b, questions: $q, lessons: $n}'
}
quiet() { printf '%s\n' "${| decider_quiet_note "$(reach "$@")"; }"; }
check "no failed loop: the stuck question waits for one, and lesson rerank for lessons" \
  test "$(quiet 85 0 0 4 0 4)" = "the stuck question is asked only after a loop fails its rubric, and 0 of 85 loops did (4 run(s) ended in a blocker instead); lesson rerank needs 30 resolved lessons, this machine has 4"
check "failed loops, none spinning or other" \
  test "$(quiet 20 3 0 0 0 4)" = "the stuck question is asked only after a failed loop the verdicts call spinning or other, and none of 3 failed loop(s) was; lesson rerank needs 30 resolved lessons, this machine has 4"
check "loops that could have been asked: the decider was off for them" \
  test "$(quiet 20 3 2 0 0 31)" = "2 failed loop(s) the verdicts call spinning or other could have been asked, but the decider was off for them; lesson rerank had 31 resolved lessons, but no candidate lesson for any loop's failure"
check "no loops at all" test "$(quiet 0 0 0 0 0 0)" = "no loop ran; lesson rerank needs 30 resolved lessons, this machine has 0"
check "with CHALK_FP_RULES=off, the stuck question needs verdicts" \
  sh -c 'case "$1" in "the stuck question needs verdicts, which CHALK_FP_RULES=off turns off; "*) ;; *) exit 1 ;; esac' _ \
    "$(CHALK_FP_RULES=off; quiet 20 0 0 0 0 4)"
check "nothing to explain once a question was asked" test -z "$(quiet 85 1 1 0 1 4)"
check "nor without the database" test -z "${| decider_quiet_note ""; }"
check "nor from a record it cannot read" test -z "${| decider_quiet_note '{"questions": 0}'; }"
ledger_note() { printf '%s\n' "${| dashboard_ledger_note "$1"; }"; }
check "the ledger: no loop the rules judge, and the runs that reported a blocker instead" \
  test "$(ledger_note "$(reach 85 0 0 4 0 4)")" = "No loop failed its rubric or passed without ticking a checkpoint in the last 30 days (85 loop(s)), so no verdict could stop a run; agents that could not progress reported a blocker instead (4 run(s))."
check "the ledger: loops the rules judge, in runs that were not detained" \
  test "$(ledger_note "$(reach 20 3 0 0 0 4)")" = "Of 20 loop(s) in the last 30 days, 3 failed their rubric and 0 passed without ticking a checkpoint, but none of their runs was detained in shadow mode."
check "the ledger: nothing to say with no loops" test -z "$(ledger_note "$(reach 0 0 0 0 0 4)")"

# --- taking turns at the local decider --------------------------------------

# asker NAME DELAY: one loop's question, in the background like a fleet
# loop's, with a budget of its own; writes "ERROR MS" to $tmp/turn.NAME.
asker() {
  ( decider_budget_reset
    outcome=ok
    ask FAKE_DECIDER_DELAY="$2" || outcome="$DECIDER_ERROR"
    printf '%s %s\n' "$outcome" "$DECIDER_MS" > "$tmp/turn.$1" ) &
  askers+=("$!")
}
# hold SECONDS: another loop's turn, held for SECONDS; waits until it is.
hold() {
  rm -f "$tmp/held"
  ( chalk_lock decider-ask 0 && : > "$tmp/held" && sleep "$1" && chalk_unlock decider-ask ) &
  holder=$!
  until [[ -e $tmp/held ]]; do sleep 0.02; done
}
outcomes() { cut -d' ' -f1 "$tmp"/turn.* | sort | uniq -c | tr -s ' ' | sed 's/^ //' | paste -sd, -; }

CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"
for has_flock in 1 0; do
  SYS=() SYS_PROBED=1 SYS[has_flock]="$has_flock"
  # Four fleet loops ask at once. With the wait long enough for all four,
  # all are answered, one at a time.
  rm -f "$FAKE_STATE/overlaps" "$tmp"/turn.*
  askers=()
  DECIDER_QUEUE_MS=1900
  for i in 1 2 3 4; do asker "$i" 0.1; done
  wait "${askers[@]}"
  DECIDER_QUEUE_MS=1000
  check "four loops asking the local decider at once take turns (has_flock=$has_flock)" \
    test ! -e "$FAKE_STATE/overlaps"
  check "... and each is answered: $(outcomes)" test "$(outcomes)" = "4 ok"
done
# The fake does notice overlapping requests: a hosted decider is not
# waited for, and four at once overlap.
rm -f "$FAKE_STATE/overlaps"
CHALK_DECIDER_URL="http://decider.test"
askers=()
for i in 1 2 3 4; do asker "$i" 0.3; done
wait "${askers[@]}"
check "a hosted decider is asked at once, without turns" test -s "$FAKE_STATE/overlaps"
CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"

# Each turn takes 0.8 s and the wait is at most DECIDER_QUEUE_MS, inside
# each loop's own 2 s budget: some loops are answered, and the rest give up
# waiting, as `busy`, rather than wait past their budget.
rm -f "$FAKE_STATE/overlaps" "$tmp"/turn.*
askers=()
for i in 1 2 3 4; do asker "$i" 0.8; done
wait "${askers[@]}"
check "four slow turns at once: answers, and busy for the rest ($(outcomes))" \
  sh -c 'printf "%s\n" "$1" | grep -Eqx "[1-3] busy,[1-3] ok"' _ "$(outcomes)"
check "... still one at a time" test ! -e "$FAKE_STATE/overlaps"
check "... and no loop waits past its budget" \
  awk '{ if ($2 > 2150) exit 1 }' "$tmp"/turn.*
check "... nor gives up before DECIDER_QUEUE_MS" \
  awk -v q="$DECIDER_QUEUE_MS" '$1 == "busy" && $2 < q { exit 1 }' "$tmp"/turn.*

# Waiting is part of the loop's budget.
hold 2.5
: > "$FAKE_STATE/decider.log"
decider_budget_reset
check "a loop whose turn does not come is not answered" fails ask
check "... named busy, after DECIDER_QUEUE_MS ($DECIDER_MS ms)" \
  test "$DECIDER_ERROR" = busy -a "$DECIDER_MS" -ge "$DECIDER_QUEUE_MS" -a "$DECIDER_MS" -le $((DECIDER_QUEUE_MS + 300))
check "... spent from its budget" test "$DECIDER_SPENT_MS" -eq "$DECIDER_MS"
check "... having sent nothing" test ! -s "$FAKE_STATE/decider.log"
decider_budget_reset
DECIDER_SPENT_MS=1700
fails ask
check "with 300 ms of its budget left, a loop waits no more than that leaves for the call ($DECIDER_MS ms)" \
  test "$DECIDER_ERROR" = busy -a "$DECIDER_MS" -le 400
CHALK_DECIDER_URL="http://decider.test"
decider_budget_reset
check "a hosted decider does not wait for the local decider's turn" ask
CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"
wait "$holder"
hold 0.5
: > "$FAKE_STATE/decider.log"
decider_budget_reset
check "a loop whose turn comes after a wait is answered" ask
check "... in a time that includes the wait ($DECIDER_MS ms)" test "$DECIDER_MS" -ge 400
wait "$holder"
max="$(sed -n 's/^max-time=\([0-9.]*\) .*/\1/p' "$FAKE_STATE/decider.log")"
check "... and its call may take only what the wait left of the budget (--max-time $max)" \
  awk -v m="$max" 'BEGIN { exit !(m > 0 && m <= 1.6) }'

# --- health, with /health optional ------------------------------------------

# probes: how many probe questions the fake decider got.
probes() { grep -c '"health":{"type":"noul"' "$FAKE_STATE/decider.log" || true; }
: > "$FAKE_STATE/decider.log"
: > "$FAKE_STATE/curl.log"
check "a decider answering /health is healthy" decider_healthy http://decider.test
check "... without a question asked" test "$(probes)" -eq 0
export FAKE_DECIDER_HEALTH=404
CHALK_DECIDER_TOKEN="s3cret-token"
check "a decider whose /health is 404 is healthy when it answers one question" \
  decider_healthy http://decider.test CHALK_DECIDER_TOKEN
check "... a noul question, as the protocol has it, with the token" \
  test "$(probes):$(grep -c 'auth=yes' "$FAKE_STATE/decider.log")" = 1:1
CHALK_DECIDER_TOKEN=""
FAKE_DECIDER_HEALTH=405
check "... and when it is 405" decider_healthy http://decider.test
decider_budget_reset
DECIDER_SPENT_MS=1900 DECIDER_ERROR=budget
decider_healthy http://decider.test
check "the probe is outside the loop's budget, which it leaves as it was" \
  test "$DECIDER_SPENT_MS:$DECIDER_LIMIT_MS:$DECIDER_ERROR" = "1900:$DECIDER_LOOP_BUDGET_MS:budget"
decider_budget_reset
FAKE_DECIDER_HEALTH=404
FAKE_DECIDER_TOKEN=other-token \
  check "a decider whose /health is 404 and that refuses the question is not healthy" \
    fails decider_healthy http://decider.test
: > "$FAKE_STATE/decider.log"
FAKE_DECIDER_HEALTH=503
check "a /health that says it is not ready is not healthy" fails decider_healthy http://decider.test
check "... and is not probed" test "$(probes)" -eq 0
FAKE_DECIDER_HEALTH=404
FAKE_DECIDER_DOWN=1 check "nothing listening is not healthy" fails decider_healthy http://decider.test
check "... and is not probed" test "$(probes)" -eq 0
# chalk-embed's probe is one embedding.
: > "$FAKE_STATE/curl.log"
check "chalk-embed whose /health is 404 is healthy when it embeds one word" decider_embed_healthy http://embed.test
check "... asked at /v1/embeddings" grep -q '^http://embed.test/v1/embeddings$' "$FAKE_STATE/curl.log"
# At the local decider, the probe waits its turn like any question.
CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"
SYS=() SYS_PROBED=1 SYS[has_flock]=1
export FAKE_DECIDER_HEALTH=404
rm -f "$FAKE_STATE/overlaps"
: > "$FAKE_STATE/decider.log"
hold 2.5
started="${| decider_now_ms; }"
check "the local decider busy with a loop's question is not probed over it" fails decider_healthy "$DECIDER_LOCAL_URL"
elapsed=$(( ${| decider_now_ms; } - started ))
check "... the probe gave up after its turn did not come (${elapsed} ms)" \
  test "$elapsed" -ge "$DECIDER_QUEUE_MS" -a "$elapsed" -le $((DECIDER_HEALTH_MS + 300))
check "... having sent nothing" test "$(probes)" -eq 0
wait "$holder"
hold 0.3
check "once its turn comes, the probe is answered" decider_healthy "$DECIDER_LOCAL_URL"
wait "$holder"
check "... one at a time" test ! -e "$FAKE_STATE/overlaps"
unset FAKE_DECIDER_HEALTH

# --- the device -------------------------------------------------------------

# A strands-decider whose `serve --help` lists the devices in $tmp/devices,
# and fails when there are none.
cat > "$tmp/help-decider" <<STUB
#!/usr/bin/env bash
echo "\$COLUMNS" > "$tmp/help-columns"
[ "\$1 \$2" = "serve --help" ] && [ -s "$tmp/devices" ] || exit 1
echo "| --device  <str>  Torch device (\$(cat "$tmp/devices")). Auto-detected when omitted. |"
STUB
chmod +x "$tmp/help-decider"
# device OS ARCH DEVICES: the device chosen on that host for that help.
device() {
  SYS=() SYS_PROBED=1 SYS["os"]="$1" SYS["arch"]="$2"
  printf '%s' "$3" > "$tmp/devices"
  decider_serve_device "$tmp/help-decider"
  printf '%s' "$REPLY"
}
check "Apple silicon: mps while strands-decider has no mlx" test "$(device darwin arm64 'cuda|mps|cpu')" = mps
check "... its help read unwrapped" test "$(<"$tmp/help-columns")" = 200
check "Apple silicon: mlx once strands-decider offers it" test "$(device darwin arm64 'cuda|mlx|mps|cpu')" = mlx
check "Apple silicon: mps when its help does not answer" test "$(device darwin arm64 '')" = mps
check "Intel Mac: strands-decider chooses" test -z "$(device darwin x86_64 'cuda|mlx|mps|cpu')"
check "Linux: strands-decider chooses" test -z "$(device linux x86_64 'cuda|mlx|mps|cpu')"
check "Linux on Arm: strands-decider chooses" test -z "$(device linux aarch64 'cuda|mlx|mps|cpu')"

# A run starts the decider on the device `chalk decider up` recorded.
SYS=() SYS_PROBED=1 SYS[has_flock]=0
for pair in mlx:"--device mlx" mps:"--device mps" auto:""; do
  { printf 'decider_model=%s@0123456789abcdef\nbench_ms=153\n' "$DECIDER_MODEL"
    printf 'serve_device=%s\n' "${pair%%:*}"; } > "$dir/installed"
  rm -f "$tmp/started"
  decider_start_once >/dev/null 2>&1
  for _ in $(seq 1 30); do [[ -s $tmp/started ]] && break; sleep 0.1; done
  args="$(sed -n 's/^decider [0-9]* //p' "$tmp/started")"
  flag="${pair#*:}"
  check "serve_device=${pair%%:*}: strands-decider is served with '$flag'" \
    test "$args" = "serve $DECIDER_MODEL --host 127.0.0.1 --port $DECIDER_PORT${flag:+ $flag}"
  decider_stop
done
# What status and doctor say about it.
note() {
  printf 'package=strands-decider 0.1.0\nserve_device=%s\nmlx_failed=%s\n' "$1" "${2:-0}" > "$dir/installed"
  decider_device_note
  printf '%s' "$REPLY"
}
check "the device note says mlx was chosen" test "$(note mlx)" = "mlx (Apple silicon)"
check "... that mps was, while strands-decider has no mlx" \
  sh -c 'case "$1" in "mps (Apple silicon): strands-decider 0.1.0 has no --device mlx"*) ;; *) exit 1 ;; esac' _ "$(note mps)"
check "... or because mlx did not start" test "$(note mps 1)" = "mps (Apple silicon): --device mlx did not start"
check "... and nothing for an install that recorded no device" \
  test -z "$(printf 'bench_ms=1\n' > "$dir/installed"; decider_device_note; printf '%s' "$REPLY")"
installed 153

# --- the benchmark and the cap ----------------------------------------------

CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"
export FAKE_DECIDER_DELAY=0.05
median="${| decider_bench; }"
unset FAKE_DECIDER_DELAY
check "the benchmark gives a median in milliseconds ($median)" test "${median:-0}" -ge 50 -a "${median:-0}" -lt 1000
check "the benchmark asks one warm-up and five timed questions" \
  test "$(grep -Ec '^max-time=(59\.9|60\.0)' "$FAKE_STATE/decider.log")" -ge 6
check "... about a text the size of a real stuck question" \
  test "$(tail -n 1 "$FAKE_STATE/decider.log" | jq -r '.state | length')" -gt 1000
median="${| FAKE_DECIDER_DOWN=1 decider_bench; }"
check "no median when the decider does not answer" test -z "$median"

# --- the chalk-embed contract -----------------------------------------------

# The real chalk-embed.py, with its stand-in model, against the real curl;
# then the fake one the e2e test uses. Both answer the same shape.
if command -v python3 >/dev/null 2>&1 && [ -x /usr/bin/curl ]; then
  port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  CHALK_EMBED_FAKE=1 python3 "$CHALK_HOME/share/decider/chalk-embed.py" --port "$port" --pidfile "$tmp/embed.pid" \
    > "$tmp/embed.log" 2>&1 &
  for _ in $(seq 1 50); do /usr/bin/curl -s "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break; sleep 0.1; done
  real() { /usr/bin/curl -s "http://127.0.0.1:$port$1" "${@:2}"; }
  shape='[paths(type != "array" and type != "object")] | map(map(if type == "number" then 0 else . end)) | unique'
  answer="$(real /v1/embeddings -H 'Content-Type: application/json' -d '{"input": ["a", "b"], "model": "BAAI/bge-small-en-v1.5"}')"
  check "chalk-embed: one 384-dimension vector per input, in order" \
    jq -e '.object == "list" and (.data | length) == 2 and .data[1].index == 1
           and all(.data[]; .object == "embedding" and (.embedding | length) == 384)' <<<"$answer"
  check "chalk-embed: the vectors have unit length" \
    jq -e 'all(.data[]; ([.embedding[] | . * .] | add | sqrt) as $n | $n > 0.999 and $n < 1.001)' <<<"$answer"
  check "chalk-embed: a single string is one input" \
    jq -e '(.data | length) == 1' <<<"$(real /v1/embeddings -d '{"input": "a"}')"
  check "chalk-embed: input that is not text is refused with 422" \
    test "$(real /v1/embeddings -o /dev/null -w '%{http_code}' -d '{"input": [1]}')" = 422
  check "chalk-embed: another model is refused with 422" \
    test "$(real /v1/embeddings -o /dev/null -w '%{http_code}' -d '{"input": ["a"], "model": "other"}')" = 422
  check "chalk-embed: health names the model, revision and dimensions" \
    jq -e '.status == "ok" and .model == "BAAI/bge-small-en-v1.5" and .dimensions == 384 and (.revision | type) == "string"' \
      <<<"$(real /health)"
  check "chalk-embed: it writes its pid" test "$(<"$tmp/embed.pid")" -gt 0
  fake="$(curl -s "http://embed.test/v1/embeddings" --data-binary @- <<<'{"input": ["a", "b"], "model": "BAAI/bge-small-en-v1.5"}')"
  check "the fake chalk-embed answers in the same shape as the real one" \
    test "$(jq -c "$shape" <<<"$answer" | jq -c 'map(select(.[0] != "usage"))')" = "$(jq -c "$shape" <<<"$fake")"
  kill "$(<"$tmp/embed.pid")" 2>/dev/null || true
  wait 2>/dev/null || true
else
  pass "chalk-embed contract skipped: no python3 or /usr/bin/curl"
fi
