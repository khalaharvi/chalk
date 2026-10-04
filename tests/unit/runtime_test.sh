#!/usr/bin/env bash
# lib/core/runtime.sh: error reports, signal exit codes and version checks.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"

# script NAME BODY: a script that loads the runtime and then runs BODY.
script() {
  printf '. "$CHALK_HOME/lib/core/log.sh"\n. "$CHALK_HOME/lib/core/runtime.sh"\n%s\n' "$2" > "$tmp/$1"
}

script unexpected 'inner() { false; }
outer() { inner; }
outer'
status=0
"$BASH" "$tmp/unexpected" 2> "$tmp/unexpected.err" || status=$?
check "an unexpected failure ends Chalk with its status" test "$status" -eq 1
check "an unexpected failure names the command" grep -q 'unexpected failure (exit 1): false' "$tmp/unexpected.err"
check "an unexpected failure shows where it was called from" \
  grep -qF "in outer ($tmp/unexpected:4)" "$tmp/unexpected.err"

script deliberate 'stop() { return 3; }
stop'
status=0
"$BASH" "$tmp/deliberate" 2> "$tmp/deliberate.err" || status=$?
check "a function returning non-zero keeps its status" test "$status" -eq 3
check "a function returning non-zero is not reported" test ! -s "$tmp/deliberate.err"

script substitution 'value="$(false)"'
"$BASH" "$tmp/substitution" 2> "$tmp/substitution.err" || true
check "a failed command substitution is reported once" \
  test "$(grep -c 'unexpected failure' "$tmp/substitution.err")" -eq 1

script signal 'trap "echo cleaned" EXIT
kill -TERM $$
sleep 5'
status=0
output="$("$BASH" "$tmp/signal")" || status=$?
check "SIGTERM exits with 143" test "$status" -eq 143
check "SIGTERM still runs EXIT traps" test "$output" = "cleaned"

load core/log core/runtime
check "bash_at_least accepts an equal version" bash_at_least 5 2 5 2
check "bash_at_least accepts a newer major" bash_at_least 5 2 6 0
check "bash_at_least rejects an older minor" eval '! bash_at_least 5 2 5 1'
check "bash_at_least rejects an older major" eval '! bash_at_least 5 2 4 4'
check "bash_at_least defaults to this bash" bash_at_least 5 3
