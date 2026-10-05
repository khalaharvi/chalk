#!/usr/bin/env bash
# lib/decider.sh: the protocol client and its shared per-loop budget, the
# mode and the slow-machine cap, the auto-start headroom gate, starting the
# local service exactly once, idle shutdown and restart, the benchmark, and
# the chalk-embed contract.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime core/jobs core/system db decider

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
installed() { printf 'decider_model=%s@0123456789abcdef\nbench_ms=%s\n' "$DECIDER_MODEL" "$1" > "$dir/installed"; }
CHALK_DECIDER=on CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"
installed 153
check "on stays on where the local decider is fast enough" test "${| decider_mode; }" = on
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
echo "decider \$\$" >> "$tmp/started"
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

# --- the benchmark and the cap ----------------------------------------------

CHALK_DECIDER_URL="$DECIDER_LOCAL_URL"
export FAKE_DECIDER_DELAY=0.05
median="${| decider_bench; }"
unset FAKE_DECIDER_DELAY
check "the benchmark gives a median in milliseconds ($median)" test "${median:-0}" -ge 50 -a "${median:-0}" -lt 1000
check "the benchmark asks one warm-up and five timed questions" \
  test "$(grep -c '^max-time=60.000' "$FAKE_STATE/decider.log")" -ge 6
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
