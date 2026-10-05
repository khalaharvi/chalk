#!/usr/bin/env bash
# lib/fingerprint.sh: the failing test set (T), first error (E) and tree ID
# (D) of a loop, and the verdict rules that compare two loops.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log fingerprint run

esc=$'\e'

# --- fp_verdict: one row per rule, then the precedence rows ---------------

# fp_set VAR SPEC: fills the associative array VAR from "key=value|..." pairs;
# an empty SPEC leaves it empty (no baseline).
fp_set() {
  local -n __set=$1
  local pair
  local -a pairs
  __set=()
  [[ -n $2 ]] || return 0
  mapfile -d '|' -t pairs < <(printf '%s' "$2")
  for pair in "${pairs[@]}"; do __set["${pair%%=*}"]="${pair#*=}"; done
}

# verdict REASON PREV CUR: prints fp_verdict's answer.
verdict() {
  local -A prev cur
  fp_set prev "$2"
  fp_set cur "$3"
  fp_verdict "$1" prev cur
  printf '%s\n' "$REPLY"
}

# row LABEL EXPECTED REASON PREV CUR
row() {
  local got
  got="$(verdict "$3" "$4" "$5")"
  if [[ $got == "$2" ]]; then pass "verdict: $1"; else fail "verdict: $1 (expected $2, got $got)"; fi
}

ab=$'a\nb'
A="tree_id=t1|tests=$ab|failing=2|first_error=AssertionError: x|generic=0"

row "a blocker is blocked"                   blocked     blocked     "$A" ""
row "an agent error is agent_error"          agent_error agent_error "$A" ""
row "passed, no baseline: first"             first       passed      ""                  "tree_id=t1"
row "passed, same tree: no_change"           no_change   passed      "tree_id=t1"        "tree_id=t1"
row "passed, new tree: other"                other       passed      "tree_id=t1"        "tree_id=t2"
row "1 deja_vu"                              deja_vu     failed      "$A"                "tree_id=t2|tests=x|failing=1|open_match=1"
row "2 first"                                first       failed      ""                  "$A"
row "3 repeat, same tree and tests"          repeat      failed      "$A"                "$A"
row "3 repeat, unknown tests and same error" repeat      failed \
  "tree_id=t1|tests=UNKNOWN|first_error=boom: x|generic=0" "tree_id=t1|tests=UNKNOWN|first_error=boom: x|generic=0"
row "4 no_change, same tree, other tests"    no_change   failed      "$A"                "tree_id=t1|tests=c|failing=1"
row "5 improving"                            improving   failed      "$A"                "tree_id=t2|tests=a|failing=1"
row "6 spinning, same tests"                 spinning    failed      "$A"                "tree_id=t2|tests=$ab|failing=2"
row "6 spinning, unknown tests, same error"  spinning    failed \
  "tree_id=t1|tests=UNKNOWN|first_error=boom: x|generic=0" "tree_id=t2|tests=UNKNOWN|first_error=boom: x|generic=0"
row "7 other"                                other       failed      "$A"                "tree_id=t2|tests=c|failing=2"

row "deja_vu wins over first"                deja_vu     failed      ""                  "tree_id=t1|tests=x|failing=1|open_match=1"
row "deja_vu needs known tests"              first       failed      ""                  "tree_id=t1|tests=UNKNOWN|first_error=boom: x|open_match=1"
row "repeat wins over no_change"             repeat      failed      "$A"                "$A|first_error=other"
row "no_change wins over improving"          no_change   failed      "$A"                "tree_id=t1|tests=a|failing=1"
row "unknown tests are never improving"      other       failed      "$A"                "tree_id=t2|tests=UNKNOWN"
row "unknown tests, known before: not repeat" no_change  failed      "$A"                "tree_id=t1|tests=UNKNOWN|first_error=AssertionError: x|generic=0"
row "a generic error is never a repeat"      no_change   failed \
  "tree_id=t1|tests=UNKNOWN|first_error=FAIL pkg|generic=1" "tree_id=t1|tests=UNKNOWN|first_error=FAIL pkg|generic=1"
row "a generic error is never spinning"      other       failed \
  "tree_id=t1|tests=UNKNOWN|first_error=FAIL pkg|generic=1" "tree_id=t2|tests=UNKNOWN|first_error=FAIL pkg|generic=1"
row "an empty error is never a repeat"       no_change   failed      "tree_id=t1|tests=UNKNOWN" "tree_id=t1|tests=UNKNOWN"
row "an empty tree ID is never unchanged"    other       failed      "tests=UNKNOWN"     "tests=UNKNOWN"
check "deja_vu, repeat and no_change stop a run; the rest do not" \
  sh -c '"$0" -c ". $1/lib/fingerprint.sh; for v in deja_vu repeat no_change; do fp_stops \$v || exit 1; done
    for v in first improving spinning other blocked agent_error \"\"; do ! fp_stops \"\$v\" || exit 1; done"' "$BASH" "$CHALK_HOME"

# --- Streaks: run_verdict keeps the baseline across loops -----------------

CHALK_FP_RULES=shadow
declare -A fp
# loop WHY SPEC: one loop through run_verdict; prints nothing, sets $got.
loop() { fp_set fp "$2"; run_verdict fp "$1"; got="${fp[verdict]-}"; }

RUN_FP_BASE=()
loop agent_error ""
loop failed "$A"
check "after an agent_error with no baseline, a failing loop is first" test "$got" = first
loop failed "$A"
check "the sequence agent_error, fail, fail ends in a repeat" test "$got" = repeat

RUN_FP_BASE=()
loop failed "$A"
loop agent_error ""
check "an agent_error is recorded as such" test "$got" = agent_error
loop failed "$A"
check "an agent_error never becomes the baseline" test "$got" = repeat

RUN_FP_BASE=()
loop passed "tree_id=t9"
check "the first passed-no-tick loop is first" test "$got" = first
loop passed "tree_id=t9"
check "two passed-no-tick loops in a row with the same tree: no_change" test "$got" = no_change
loop progressed "tree_id=t10"
check "a loop that progresses gets no verdict" test -z "$got"
loop failed "$A"
check "progress ends the streak, so the next failure is first" test "$got" = first

CHALK_FP_RULES=off
RUN_FP_BASE=()
loop failed "$A"
check "with CHALK_FP_RULES=off no verdict is recorded" test -z "$got"
CHALK_FP_RULES=shadow

# --- T and E from real runner output ---------------------------------------

# The sandbox is a directory here: sandbox_sh runs in $tmp/repo.
mkdir -p "$tmp/repo"
sandbox_sh() { local command="$2"; shift 2; (cd "$tmp/repo" && bash -c "$command" chalk "$@"); }
CHALK_TEST_REPORT=""

# compute NAME [REPORT]: fp_compute over the fixture $tmp/NAME.log into fp.
compute() { fp=(); fp_compute fp sandbox "$tmp/$1.log" "${2:-}"; }

cat > "$tmp/pytest.log" <<LOG
============================= test session starts ==============================
collected 3 items

tests/test_math.py ${esc}[31mF${esc}[0m.${esc}[31mF${esc}[0m
=================================== FAILURES ===================================
__________________________________ test_add ___________________________________
>       assert add(1, 2) == 4
E       assert 3 == 4
${esc}[31mFAILED${esc}[0m tests/test_math.py::test_sub - assert -1 == 1
FAILED tests/test_math.py::test_add - assert 3 == 4
${esc}[31m========================= 2 failed, 1 passed in 0.12s =========================${esc}[0m
LOG
compute pytest
check "pytest: failing tests are read and sorted" \
  test "${fp[tests]}" = $'tests/test_math.py::test_add\ntests/test_math.py::test_sub'
check "pytest: the failing count" test "${fp[failing]}" = 2
check "pytest: the FAILURES banner is a generic first error" \
  test "${fp[first_error]}:${fp[generic]}" = "=================================== FAILURES ===================================:1"
check "pytest: known tests give a tests hash and a lesson fingerprint" \
  test "${#fp[tests_hash]}:${#fp[fingerprint]}" = 64:64

cat > "$tmp/go.log" <<'LOG'
=== RUN   TestParse
    parse_test.go:12: got 3, want 4
--- FAIL: TestParse (0.00s)
=== RUN   TestServe
=== RUN   TestServe/empty
    --- FAIL: TestServe/empty (0.01s)
--- FAIL: TestServe (0.01s)
FAIL
FAIL	example.com/app	0.214s
LOG
compute go
check "go: failing tests and subtests are read" \
  test "${fp[tests]}" = $'TestParse\nTestServe\nTestServe/empty'
check "go: the first error has its duration stripped" test "${fp[first_error]}" = "--- FAIL: TestParse (<d>)"

cat > "$tmp/jest.log" <<'LOG'
 FAIL  src/sum.test.js
  ● Math › adds numbers

    expect(received).toBe(expected) // Object.is equality

  ● Math › nested › subtracts

Tests:       2 failed, 3 passed, 5 total
LOG
compute jest
check "jest: failing tests are read" test "${fp[tests]}" = $'Math › adds numbers\nMath › nested › subtracts'
check "jest: FAIL <file> is a generic first error" test "${fp[generic]}" = 1

cat > "$tmp/cargo.log" <<'LOG'
running 2 tests
test tests::adds ... ok
test tests::subtracts ... FAILED

failures:

---- tests::subtracts stdout ----
thread 'tests::subtracts' panicked at src/lib.rs:12:5:
assertion `left == right` failed
test result: FAILED. 1 passed; 1 failed; 0 ignored; finished in 0.00s
error: test failed, to rerun pass `--lib`
LOG
compute cargo
check "cargo: failing tests are read" test "${fp[tests]}" = tests::subtracts
check "cargo: the first error is the failing test's line" test "${fp[first_error]}" = "test tests::subtracts ... FAILED"

cat > "$tmp/build.log" <<'LOG'
# example.com/app
./main.go:3:5: undefined: x
FAIL	example.com/app [build failed]
LOG
compute build
check "a build error with no tests gives UNKNOWN, not zero failures" \
  test "${fp[tests]}:${fp[failing]}:${fp[tests_hash]}" = "UNKNOWN::"
check "a build error that is only a banner gives no lesson fingerprint" \
  test "${fp[generic]}:${fp[fingerprint]}" = "1:"

cat > "$tmp/tsc.log" <<'LOG'
src/app.ts(3,5): error TS2304: Cannot find name 'x'.
LOG
compute tsc
check "unknown tests with a specific error still give a lesson fingerprint" \
  test "${fp[tests]}:${fp[generic]}:${#fp[fingerprint]}" = UNKNOWN:0:64

printf 'checking things\nsomething went wrong\n' > "$tmp/unknown.log"
compute unknown
check "an unknown runner gives UNKNOWN tests and no first error" \
  test "${fp[tests]}:${fp[first_error]}:${fp[fingerprint]}" = "UNKNOWN::"
compute missing
check "a missing log gives UNKNOWN tests" test "${fp[tests]}:${fp[first_error]}" = "UNKNOWN:"

# Two tickets whose failures share only a runner's banner.
printf 'ok  \texample.com/a\t0.1s\nFAIL\texample.com/b\t0.31s\n' > "$tmp/banner1.log"
printf 'FAIL\texample.com/b\t1.02s\n' > "$tmp/banner2.log"
compute banner1
one="${fp[fingerprint]}:${fp[generic]}"
compute banner2
check "two failures sharing only a generic error give no lesson fingerprint" \
  test "$one:${fp[fingerprint]}:${fp[generic]}" = ":1::1"
fp["open_match"]=1
declare -A none=()
fp_verdict failed none fp
check "two failures sharing only a generic error are never deja_vu" test "$REPLY" = first

# --- E: normalization and the generic denylist ----------------------------

printf '%s\n' "${esc}[1mpanic: runtime error at 0x7ffd5a1c in /tmp/go-build123/main.go:42:7 at 2026-10-04T17:52:02Z after 12ms${esc}[0m" > "$tmp/e1.log"
printf '%s\n' "panic: runtime error at 0xc000123 in /var/folders/x1/T/go-build9/main.go:57:3 at 2026-10-05 09:01:13 after 3.5s" > "$tmp/e2.log"
e1="${| fp_first_error "$tmp/e1.log"; }"
e2="${| fp_first_error "$tmp/e2.log"; }"
check "E strips ANSI codes, addresses, :line:col, temp paths, timestamps and durations" test "$e1" = "$e2"
check "E keeps the error's words" test "$e1" = "panic: runtime error at 0x? in <tmp> at <time> after <d>"

# generic_entry LABEL LINE: LINE, as the first error of a log, is generic.
generic_entry() {
  printf '%s\n' "$2" > "$tmp/generic.log"
  check "generic: $1" fp_generic "${| fp_first_error "$tmp/generic.log"; }"
}
generic_entry "go FAIL <pkg>"           $'FAIL\texample.com/app\t0.214s'
generic_entry "npm ERR! Test failed"    "npm ERR! Test failed.  See above for more details."
generic_entry "a bare error:"           "error:"
generic_entry "N failed"                "========= 2 failed, 3 passed, 1 error in 0.52s ========="
generic_entry "cargo test failed"       "error: test failed, to rerun pass \`--lib\`"
generic_entry "pytest section banner"   "=================== FAILURES ==================="
generic_entry "python traceback banner" "Traceback (most recent call last):"
check "a specific error is not generic" sh -c '! "$0" -c ". $1/lib/fingerprint.sh; fp_generic \"AssertionError: expected 3, got 4\""' "$BASH" "$CHALK_HOME"

# --- JUnit XML reports -----------------------------------------------------

cat > "$tmp/report.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<testsuites><testsuite name="pytest" errors="1" failures="1" tests="4">
  <testcase classname="tests.test_math" name="test_ok" time="0.001" />
  <testcase classname="tests.test_math" name="test_add" time="0.002">
    <failure message="assert 3 == 4">def test_add(): assert add(1, 2) == 4</failure>
  </testcase>
  <testcase classname="tests.test_io" name="test_read[a&amp;b]" time="0.010"><error message="OSError">boom</error></testcase>
  <testcase classname="tests.test_io" name="test_skip"><skipped message="later"/></testcase>
  <testcase name="bare"><system-out>no failure here</system-out></testcase>
</testsuite></testsuites>
XML
compute unknown "$tmp/report.xml"
check "JUnit: testcases with a failure or error child, as classname::name" \
  test "${fp[tests]}" = $'tests.test_io::test_read[a&b]\ntests.test_math::test_add'
check "JUnit: the report wins over the log" test "${fp[failing]}" = 2

# --- The report in the sandbox: a stale one is never read -----------------

CHALK_TEST_REPORT=report.xml
cp "$tmp/report.xml" "$tmp/repo/report.xml"
fp_report_clear sandbox
check "the report is deleted before the rubric runs" test ! -e "$tmp/repo/report.xml"
# The rubric then fails without writing a report (say, a build error).
fp_report_fetch sandbox "$tmp/fetched.xml"
check "no report this run means none is fetched" test ! -e "$tmp/fetched.xml"
compute go "$tmp/fetched.xml"
check "a stale report is never read: tests come from this run's log" \
  test "${fp[tests]}" = $'TestParse\nTestServe\nTestServe/empty'
cp "$tmp/report.xml" "$tmp/repo/report.xml"
fp_report_fetch sandbox "$tmp/fetched.xml"
check "this run's report is fetched from the sandbox" cmp -s "$tmp/report.xml" "$tmp/fetched.xml"
rm -f "$tmp/repo/report.xml"
CHALK_TEST_REPORT=""

# --- D: the tree ID --------------------------------------------------------

git -C "$tmp/repo" init -q
mkdir -p "$tmp/repo/specs"
printf 'spec\n' > "$tmp/repo/specs/PROJ-1.md"
printf 'notes\n' > "$tmp/repo/specs/PROJ-1.notes.md"
printf 'code\n' > "$tmp/repo/main.txt"
git -C "$tmp/repo" add -A
git -C "$tmp/repo" commit -q -m init

d0="${| fp_tree_id sandbox; }"
check "the tree ID is a git tree" test "$(git -C "$tmp/repo" cat-file -t "$d0")" = tree
check "an unchanged tree keeps its ID" test "${| fp_tree_id sandbox; }" = "$d0"
printf 'more notes\n' >> "$tmp/repo/specs/PROJ-1.notes.md"
check "a change to the notes file only keeps the same tree ID" test "${| fp_tree_id sandbox; }" = "$d0"
printf 'notes\n' > "$tmp/repo/specs/PROJ-2.notes.md"
check "a new notes file keeps the same tree ID" test "${| fp_tree_id sandbox; }" = "$d0"
CHALK_TEST_REPORT=out/report.xml
mkdir -p "$tmp/repo/out"
printf '<testsuite/>\n' > "$tmp/repo/out/report.xml"
check "the test report is not part of the tree ID" test "${| fp_tree_id sandbox; }" = "$d0"
rm -rf "$tmp/repo/out"
check "a tree ID is taken when the rubric wrote no report" test "${| fp_tree_id sandbox; }" = "$d0"
CHALK_TEST_REPORT=""
printf 'new\n' > "$tmp/repo/new.txt"
d1="${| fp_tree_id sandbox; }"
check "a new untracked file changes the tree ID" test -n "$d1" -a "$d1" != "$d0"
check "the index copy lives under .git" test -f "$tmp/repo/.git/chalk-fp-index"
check "the index copy is not in the tree" sh -c '! git -C "$0" ls-tree -r --name-only "$1" | grep -q chalk-fp-index' "$tmp/repo" "$d1"
check "the real index is left alone" \
  test "$(git -C "$tmp/repo" status --porcelain -- new.txt)" = "?? new.txt"
compute go
check "fp_compute records the tree ID" test "${fp[tree_id]}" = "$d1"
rm -rf "$tmp/repo/.git"
check "outside a git repository the tree ID is empty" test -z "${| fp_tree_id sandbox; }"
