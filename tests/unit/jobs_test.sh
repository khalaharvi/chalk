#!/usr/bin/env bash
# lib/core/jobs.sh: background jobs collected by name, with their output.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime core/jobs

quick()  { echo "quick done"; }
slow()   { sleep 0.3; echo "slow done"; }
broken() { echo "about to fail"; die "broken on purpose"; }

jobs_init "$tmp/all-good"
jobs_spawn slow slow
jobs_spawn quick quick
declare -A results
jobs_wait results > "$tmp/out" 2> "$tmp/err"
check "every job's status is recorded by name" test "${results[quick]}:${results[slow]}" = "0:0"
check "output of finished jobs is replayed in the order they finish" \
  test "$(cat "$tmp/out")" = "$(printf 'quick done\nslow done')"
check "successful jobs write nothing to stderr" test ! -s "$tmp/err"

jobs_init "$tmp/one-broken"
jobs_spawn quick quick
jobs_spawn broken broken
status=0
jobs_wait results > "$tmp/out" 2> "$tmp/err" || status=$?
check "a failed job makes jobs_wait fail" test "$status" -ne 0
check "the failed job is named with its status" test "${results[broken]}:${results[quick]}" = "1:0"
check "a failed job's output goes to stderr" \
  sh -c 'grep -q "about to fail" "$1" && grep -q "broken on purpose" "$1"' _ "$tmp/err"
check "die inside a job ends only that job" test "$(cat "$tmp/out")" = "quick done"
check "each job keeps its own log" test -s "$tmp/one-broken/broken.log"

jobs_init "$tmp/none"
jobs_wait results
check "waiting with no jobs succeeds with no results" test "${#results[@]}" -eq 0
