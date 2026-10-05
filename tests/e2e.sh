#!/usr/bin/env bash
# End-to-end test of the Chalk workflow using fake docker, claude, gh and glab.
# Exercises the real loop, git plumbing and lifecycle without Docker or API
# spend. Run with: make test
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export PATH="$here/fakes:$here/../bin:$PATH"
export FAKE_STATE="$tmp/fake" XDG_STATE_HOME="$tmp/state" HOME="$tmp/home"
export ANTHROPIC_API_KEY="test-key"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$FAKE_STATE" "$HOME"

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; exit 1; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }

# Against a real Postgres (make test-db), everything this test writes goes
# to a schema of its own, made afresh on every run, so a database used
# before gives the same results and its other data is never touched. The
# extensions stay in public, where dropping the schema cannot take them.
if [ -n "${FAKE_PG_URL:-}" ]; then
  PGOPTIONS='-c client_min_messages=warning' psql "$FAKE_PG_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector') THEN
        CREATE EXTENSION IF NOT EXISTS vector SCHEMA public;
    END IF;
END
$$;
DROP SCHEMA IF EXISTS chalk_e2e_run CASCADE;
CREATE SCHEMA chalk_e2e_run;
SQL
  e2e_pgoptions='-c search_path=chalk_e2e_run,public'
  export PGOPTIONS="$e2e_pgoptions"
fi

# A repository with a remote and a rubric that rejects a file named BROKEN.
git init -q --bare "$tmp/origin.git"
# Like GitHub, the remote answers a push with a hint to open a pull request,
# and it refuses branches of PROJ-23, as a branch protection rule might.
cat > "$tmp/origin.git/hooks/post-receive" <<'HOOK'
#!/bin/sh
echo
echo "Create a pull request by visiting:"
echo "     https://example.com/pull/new"
HOOK
cat > "$tmp/origin.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
if grep -q 'refs/heads/chalk/PROJ-23$'; then echo "error: pushes to chalk/PROJ-23 are not allowed"; exit 1; fi
HOOK
chmod +x "$tmp/origin.git/hooks/post-receive" "$tmp/origin.git/hooks/pre-receive"
git init -q -b main "$tmp/demo"
cd "$tmp/demo"
git remote add origin "$tmp/origin.git"
chalk init > "$tmp/init1.log"
sed -i.bak 's/^CHALK_TEST_CMD=.*/CHALK_TEST_CMD=test ! -e BROKEN/' .chalk/config && rm .chalk/config.bak
git add -A && git commit -q -m "init"

check "init scaffolds config, textbook, CI and CLAUDE.md" \
  test -f .chalk/textbook.md -a -f .gitlab/chalk.gitlab-ci.yml -a -f .gitlab-ci.yml -a -f CLAUDE.md
check "init says where to set the CI rubric's image for a stack other than Node" \
  grep -q 'not Node 22?.*CHALK_CI_IMAGE in .gitlab/chalk.gitlab-ci.yml.*/guide/configuring/your-stack/' "$tmp/init1.log"

# ci_rubric FILE REPO TEST_CMD: runs the rubric job's script from a CI file
# that init wrote, with sh as a runner might, in a copy of REPO whose
# CHALK_TEST_CMD is TEST_CMD.
ci_rubric() {
  local file="$1" repo="$2" test_cmd="$3" dir script
  dir="$(mktemp -d "$tmp/ci.XXXXXX")"
  mkdir -p "$dir/.chalk"
  printf 'CHALK_SETUP_CMD=\nCHALK_TEST_CMD=%s\n' "$test_cmd" > "$dir/.chalk/config"
  case "$file" in
    *.github/workflows/*)
      script="$(awk '/- name: Run the rubric/ { found = 1; next }
        found && /run: [|]/ { body = 1; next }
        body && /^          / { print substr($0, 11); next }
        body { exit }' "$repo/$file")" ;;
    *)
      script="$(awk '/^chalk:rubric:/ { job = 1 }
        job && /^    - / { line = substr($0, 7)
          if (line ~ /^\047.*\047$/) line = substr(line, 2, length(line) - 2)
          print line }
        job && /^$/ { exit }' "$repo/$file")" ;;
  esac
  [ -n "$script" ] || return 2
  (cd "$dir" && sh -ec "$script")
}

# ci_rubric_fails FILE REPO TEST_CMD: the job ran and failed with TEST_CMD's
# status (3), not because its script could not be found (2).
ci_rubric_fails() {
  local status=0
  ci_rubric "$@" || status=$?
  [ "$status" -eq 3 ]
}

# The sandbox runs the rubric with bash -c (run_rubric), so CI does too: a
# rubric that needs bash must not pass in one place and fail in the other.
ci_runs_rubric_with_bash() {
  grep -qF 'bash -c "$TEST_CMD"' "$1" && grep -qF 'bash -c "$SETUP_CMD"' "$1" &&
    ! grep -qE '(^|[^a-z])sh -c' "$1"
}
check "GitLab CI runs the setup and the rubric with bash -c, never sh -c" \
  ci_runs_rubric_with_bash .gitlab/chalk.gitlab-ci.yml
check "GitLab CI rubric job passes a rubric that needs bash" \
  ci_rubric .gitlab/chalk.gitlab-ci.yml "$PWD" 'set -o pipefail; [[ -n $BASH_VERSION ]]'
check "GitLab CI rubric job fails when the rubric fails" \
  ci_rubric_fails .gitlab/chalk.gitlab-ci.yml "$PWD" 'exit 3'

# 0. chalk doctor asks the CLI in the sandbox image which permission mode a
# loop on CHALK_MODEL starts in. It sends the SDK's initialize request and
# no message, so it costs nothing.
chalk doctor > "$tmp/doctor1.log" 2>&1 || { cat "$tmp/doctor1.log"; fail "doctor"; }
check "doctor: auto mode is available for the default model" \
  grep -qx '  ok    auto mode for the default model' "$tmp/doctor1.log"
check "doctor: the CLI is asked for auto mode, with no prompt and no budget to spend" \
  sh -c "grep -e '--input-format stream-json' '$FAKE_STATE/claude.log' | grep -q -e '--permission-mode auto' &&
    ! grep -e '--input-format stream-json' '$FAKE_STATE/claude.log' | grep -q -e '--max-budget-usd'"
if CHALK_MODEL=sonnet FAKE_AUTO_MODE=off chalk doctor > "$tmp/doctor2.log" 2>&1; then
  fail "doctor must fail when auto mode is unavailable"
fi
check "doctor: auto mode unavailable for CHALK_MODEL is a FAIL that says what follows" \
  grep -q '^  FAIL  auto mode for sonnet: unavailable: loops would start in manual mode' "$tmp/doctor2.log"
FAKE_AUTO_MODE=unknown chalk doctor > "$tmp/doctor3.log" 2>&1 ||
  { cat "$tmp/doctor3.log"; fail "doctor must pass when auto mode cannot be verified"; }
check "doctor: auto mode that cannot be asked about is reported as not verified" \
  grep -q '^  --    auto mode for the default model: could not verify' "$tmp/doctor3.log"
CHALK_PERMISSION_MODE=bypass FAKE_AUTO_MODE=off chalk doctor > "$tmp/doctor4.log" 2>&1 ||
  { cat "$tmp/doctor4.log"; fail "doctor with CHALK_PERMISSION_MODE=bypass"; }
check "doctor: auto mode is not checked when CHALK_PERMISSION_MODE=bypass" \
  grep -q 'auto mode not used (CHALK_PERMISSION_MODE=bypass)' "$tmp/doctor4.log"
if CHALK_MODEL=haiku chalk doctor > "$tmp/doctor5.log" 2>&1; then fail "doctor must refuse Haiku in auto mode"; fi
check "doctor: Haiku is refused for auto mode without asking the CLI" \
  grep -q 'auto mode does not support Haiku' "$tmp/doctor5.log"

# next_step LOG TEXT: LOG has exactly one "what to do next" line, and it
# starts with TEXT.
next_step() {
  test "$(grep -c '^\[[A-Z0-9-]*\] next: ' "$1")" -eq 1 && grep -q "^\[[A-Z0-9-]*\] next: $2" "$1"
}

# 1. Happy path: two checkpoints, two loops, merge request opened.
chalk new PROJ-1 Demo feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-1"
git add -A && git commit -q -m "spec"
# The agent's summary runs to several paragraphs, as real ones do.
FAKE_SUMMARY=$'Ticked the checkpoint.\n\nTests (test/demo.test.js): wrote them first.' \
  CHALK_SETUP_CMD='echo setting up' chalk run > "$tmp/run1.log" 2>&1 || { cat "$tmp/run1.log"; fail "happy path run"; }
check "all checkpoints ticked on host branch" test "$(grep -c -e '- \[x\]' specs/PROJ-1.md)" -eq 2
check "one commit per loop" test "$(git rev-list --count main..HEAD)" -eq 3
check "branch pushed to origin" git -C "$tmp/origin.git" rev-parse chalk/PROJ-1
check "merge request opened" grep -q "mr create.*chalk/PROJ-1" "$FAKE_STATE/glab.log"
check "sandbox removed" test ! -e "$FAKE_STATE/chalk-sandbox-demo-PROJ-1"
check "run telemetry recorded" grep -q "INSERT INTO runs" "$FAKE_STATE/db.log"
check "the database and sandbox image start side by side, each with a log" \
  test -f "$XDG_STATE_HOME/chalk/demo/runs/PROJ-1/io/startup/database.log" \
    -a -f "$XDG_STATE_HOME/chalk/demo/runs/PROJ-1/io/startup/image.log"
io="$XDG_STATE_HOME/chalk/demo/runs/PROJ-1/io"
check "system prompt carries harness rules and the textbook" \
  sh -c "grep -q 'harness commits for you' '$io/system.md' && grep -q '<engineering_rules>' '$io/system.md'"
check "system prompt passed to the CLI" grep -q -e "--append-system-prompt-file .*/chalk/system.md" "$FAKE_STATE/claude.log"
check "loops run in auto mode, never with permissions skipped" \
  sh -c "grep -q -e '--permission-mode auto' '$FAKE_STATE/claude.log' && ! grep -q -e '--dangerously-skip-permissions' '$FAKE_STATE/claude.log'"
check "read-only calls are limited to read tools" \
  grep -q -e "--model haiku --permission-mode dontAsk --allowedTools Read Grep Glob" "$FAKE_STATE/claude.log"
check "structured output requested" grep -q -e "--json-schema" "$FAKE_STATE/claude.log"
check "loop prompt tags its context" \
  sh -c "grep -q '<notes_file>specs/PROJ-1.notes.md</notes_file>' '$io/prompt.md' && grep -q '<rubric_command>' '$io/prompt.md'"
check "spec check ran on the cheap model and passed" \
  sh -c "grep -q -e '--model haiku' '$FAKE_STATE/claude.log' && test -s '$XDG_STATE_HOME/chalk/demo/runs/PROJ-1/spec-check.ok'"
check "final review ran before the merge request" grep -q "final review: pass" "$tmp/run1.log"
check "the run summary counts loops, not the spec check or review" \
  grep -q "all checkpoints complete (2 loops" "$tmp/run1.log"
check "review summary lands in the merge request" grep -q "Agent review before submission: Looks complete" "$FAKE_STATE/glab.log"
check "the run says what it is doing from the start, in order" \
  test "$(grep -o -e 'starting the database and the sandbox image' -e 'starting sandbox ' -e 'cloning chalk/PROJ-1 into the sandbox' \
             -e 'running the setup command: echo setting up' -e 'checking the spec with haiku' \
             -e 'spec check passed (\$0.25, [0-9]*s)' -e 'loop 1 (continue) started' -e 'final review started' \
             "$tmp/run1.log" | sed 's/, [0-9]*s)/, Ns)/' | paste -sd '|' -)" \
    = 'starting the database and the sandbox image|starting sandbox |cloning chalk/PROJ-1 into the sandbox|running the setup command: echo setting up|checking the spec with haiku|spec check passed ($0.25, Ns)|loop 1 (continue) started|final review started'
check "every line of a summary of several paragraphs carries the ticket" \
  sh -c "test \"\$(grep -c '^\[PROJ-1\] Tests (test/demo.test.js): wrote them first.\$' '$tmp/run1.log')\" -eq 2 &&
    test \"\$(grep -cx '\[PROJ-1\]' '$tmp/run1.log')\" -eq 2 && ! grep -q '^Tests ' '$tmp/run1.log'"
git init -q --bare "$tmp/hint.git"
cp "$tmp/origin.git/hooks/post-receive" "$tmp/hint.git/hooks/"
check "the remote's hint would show in a plain push" \
  sh -c "git push -q '$tmp/hint.git' HEAD:refs/heads/hint 2>&1 | grep -q '^remote: Create a pull request'"
check "the remote's hint after the push is not shown" sh -c "! grep -q -e '^remote:' -e 'Create a pull request' '$tmp/run1.log'"
# The harness commits a checkpoint only when the rubric passes, so a
# checkpoint must leave it passing on its own. The prompts are the contract.
check "spec check fails a checkpoint that cannot leave the rubric passing on its own" \
  sh -c "grep -q '^- Green on its own: once it is done, the rubric passes, without any later' '$io/spec-check.prompt.md' &&
    grep -q 'merge the test and the code that makes it pass into one checkpoint' '$io/spec-check.prompt.md'"
check "loops are told to end every session with the rubric passing" \
  sh -c "grep -q 'Every session must end with the whole rubric passing' '$io/system.md' &&
    grep -q 'do the next one too, tick both' '$io/prompt.md'"
check "the spec template asks for a test and its code in one checkpoint" \
  grep -q 'put a test and the code that makes it pass in one checkpoint' specs/PROJ-1.md

# 2. Failure path: rubric keeps failing, work goes to detention, human fixes.
cd "$tmp/demo"
chalk new PROJ-2 Broken feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-2"
git add -A && git commit -q -m "spec"
db_lines="$(wc -l < "$FAKE_STATE/db.log")"
if FAKE_CLAUDE_MODE="break" chalk run > "$tmp/run2.log" 2>&1; then fail "failing run should exit non-zero"; fi
tail -n +"$((db_lines + 1))" "$FAKE_STATE/db.log" > "$tmp/db2.log"
# CHALK_FP_RULES defaults to shadow: verdicts are recorded and nothing else
# changes. The agent leaves the same tree each loop and the rubric names no
# tests, so the loops after the first are no_change.
check "shadow mode: the same three loops, then the usual detention" \
  sh -c "grep -q 'loop 3 (retry)' '$tmp/run2.log' && ! grep -q 'loop 4' '$tmp/run2.log' &&
    grep -q 'DETENTION: rubric failed (exit 1)$' '$tmp/run2.log'"
check "next step when retries run out on a failing rubric: fix the failure" \
  next_step "$tmp/run2.log" "the rubric still fails after 2 retries; fix the failure in .*/rubric.log"
check "shadow mode: the retry prompt's failure feedback is unchanged" \
  sh -c "grep -A 1 '^<failure>' '$XDG_STATE_HOME/chalk/demo/runs/PROJ-2/io/prompt.md' | grep -qx 'rubric failed (exit 1)'"
check "shadow mode: one verdict per loop with no progress" \
  test "$(grep -c -e '-v verdict=first$' "$tmp/db2.log"):$(grep -c -e '-v verdict=no_change$' "$tmp/db2.log")" = 1:2
check "shadow mode: every call records CHALK_FP_RULES=shadow" \
  test "$(grep -c 'INSERT INTO runs' "$tmp/db2.log")" = "$(grep -c -e '-v fp_rules=shadow ' "$tmp/db2.log")"
check "every call in the run records its run_id" \
  test "$(grep -c 'INSERT INTO runs' "$tmp/db2.log")" = "$(grep -Ec -e '-v run_id=PROJ-2-[0-9]+ -v tests_hash=' "$tmp/db2.log")"
check "the lesson is linked to its run" grep -Eq -e '-v run_id=PROJ-2-[0-9]+ -v fingerprint=' "$tmp/db2.log"
detention="$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/PROJ-2-*')"
check "detention branch created" test -n "$detention"
check "detention branch holds the broken work" git cat-file -e "$detention:BROKEN"
check "working branch left untouched" test "$(git rev-list --count main..chalk/PROJ-2)" -eq 1
check "nothing pushed for the failed run" test -z "$(git -C "$tmp/origin.git" for-each-ref 'refs/heads/detention')"
check "failure recorded as a lesson" grep -q "INSERT INTO lessons" "$FAKE_STATE/db.log"
check "failed attempts were retried with the retry prompt" grep -q "(retry)" "$tmp/run2.log"
check "a detention is not reported as an unexpected failure" sh -c "! grep -q 'unexpected failure' '$tmp/run2.log'"

git switch -q "$detention"
git rm -q BROKEN && git commit -q -m "remove the blocker"
chalk office-hours -m "BROKEN marker must not be committed" > "$tmp/run3.log" 2>&1 ||
  { cat "$tmp/run3.log"; fail "office hours"; }
check "resumed on a tutoring branch" test "$(git rev-parse --abbrev-ref HEAD | cut -d/ -f1)" = tutoring
check "spec finished after office hours" test "$(grep -c -e '- \[ \]' specs/PROJ-2.md)" -eq 0
check "lesson resolved with the engineer's note" grep -q "resolution=BROKEN marker" "$FAKE_STATE/db.log"
check "note distilled into a general lesson" \
  grep -q -e "-v lesson=Distilled: never commit a BROKEN marker -v scope=general$" "$FAKE_STATE/db.log"
distill="$XDG_STATE_HOME/chalk/demo/runs/PROJ-2/distill/distill.prompt.md"
check "distillation gets the engineer's note and the diff of the fix commit" \
  sh -c "grep -A 1 '^<engineer_note>$' '$distill' | grep -qx 'BROKEN marker must not be committed' &&
    sed -n '/^<fix_diff>$/,/^<\/fix_diff>$/p' '$distill' > '$tmp/fix_diff' &&
    grep -q '^1 commit(s) since the detention' '$tmp/fix_diff' && grep -q '^diff --git a/BROKEN b/BROKEN' '$tmp/fix_diff'"
check "distillation sandbox removed" test ! -e "$FAKE_STATE/chalk-sandbox-demo-PROJ-2-distill"
check "tutoring merge request opened" grep -q "mr create.*tutoring/PROJ-2" "$FAKE_STATE/glab.log"

# 2b. With CHALK_FP_RULES=on, a loop that repeats the last one's failure on
# the same tree is detained at once. The rubric writes a JUnit report.
cd "$tmp/demo"
chalk new PROJ-9 Repeating feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-9"
git add -A && git commit -q -m "spec"
junit='<testsuite><testcase classname="demo" name="no_marker"><failure message="BROKEN"/></testcase></testsuite>'
db_lines="$(wc -l < "$FAKE_STATE/db.log")"
if FAKE_CLAUDE_MODE=break CHALK_FP_RULES=on CHALK_TEST_REPORT=out/report.xml \
   CHALK_TEST_CMD="if [ -e BROKEN ]; then mkdir -p out; echo '$junit' > out/report.xml; echo 'AssertionError: BROKEN exists'; exit 1; fi" \
   chalk run > "$tmp/run12.log" 2>&1; then
  fail "a repeating run with rules on should exit non-zero"
fi
tail -n +"$((db_lines + 1))" "$FAKE_STATE/db.log" > "$tmp/db12.log"
check "rules on: a repeating loop is detained at loop 2 with the verdict as the reason" \
  sh -c "grep -q 'DETENTION: repeat: rubric failed (exit 1)' '$tmp/run12.log' && ! grep -q 'loop 3' '$tmp/run12.log'"
check "next step on repeat: fix the failure, since a retry would repeat it" \
  next_step "$tmp/run12.log" "the agent made the same failing change twice"
check "rules on: the loops record first, then repeat, with the failing test count" \
  sh -c "grep -q -e '-v failing=1 .*-v verdict=first$' '$tmp/db12.log' && grep -q -e '-v failing=1 .*-v verdict=repeat$' '$tmp/db12.log'"
check "rules on: every call records CHALK_FP_RULES=on" \
  test "$(grep -c 'INSERT INTO runs' "$tmp/db12.log")" = "$(grep -c -e '-v fp_rules=on ' "$tmp/db12.log")"
check "rules on: the lesson carries the failing loop's fingerprint and first error" \
  grep -Eq -e "-v fingerprint=[0-9a-f]{64} -v first_error=AssertionError: BROKEN exists" "$tmp/db12.log"
check "rules on: the failing loops record their failing test IDs" \
  test "$(grep -c -e '-v failing_tests=demo::no_marker ' "$tmp/db12.log")" -eq 2
cd "$tmp/demo"

# 2b'. A go test -json report is read like a JUnit one: the format is told
# by content, so the same failing test is named whatever the file is called.
chalk new PROJ-19 Go report feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-19"
git add -A && git commit -q -m "spec"
gojson='{"Action":"run","Package":"demo","Test":"TestNoMarker"}
{"Action":"fail","Package":"demo","Test":"TestNoMarker","Elapsed":0}
{"Action":"fail","Package":"demo","Elapsed":0.1}'
db_lines="$(wc -l < "$FAKE_STATE/db.log")"
if FAKE_CLAUDE_MODE=break CHALK_MAX_RETRIES=1 CHALK_TEST_REPORT=out/report.json \
   CHALK_TEST_CMD="if [ -e BROKEN ]; then mkdir -p out; echo '$gojson' > out/report.json; echo 'FAIL demo'; exit 1; fi" \
   chalk run > "$tmp/run19.log" 2>&1; then
  fail "a failing run with a go -json report should exit non-zero"
fi
tail -n +"$((db_lines + 1))" "$FAKE_STATE/db.log" > "$tmp/db19.log"
check "go -json report: the failing test is named as package::test, with its count" \
  sh -c "grep -q -e '-v tests_hash=[0-9a-f]\{64\} -v failing_tests=demo::TestNoMarker -v failing=1 ' '$tmp/db19.log'"
check "go -json report: the second loop repeats the first" grep -q -e '-v failing=1 .*-v verdict=repeat$' "$tmp/db19.log"
cd "$tmp/demo"

# 2b'. Every detention says what to do next, in one line. These runs share
# one ticket: a detention leaves its working branch as it was.
chalk new PROJ-31 Detained feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-31"
git add -A && git commit -q -m "spec"
# detain NAME [ENV=VALUE...]: a run of PROJ-31 that must end in detention,
# logged to $tmp/detain-NAME.log.
detain() {
  local name="$1"
  shift
  if env "$@" chalk run > "$tmp/detain-$name.log" 2>&1; then fail "the $name run should end in detention"; fi
}
# detained NAME REASON TEXT: the NAME run was detained for REASON, and its
# one next-step line starts with TEXT.
detained() { grep -q "DETENTION: $2" "$tmp/detain-$1.log" && next_step "$tmp/detain-$1.log" "$3"; }

# The failure of PROJ-9, whose detention is still open. The fake database
# is told so; a real one (make test-db) holds PROJ-9's open lesson.
detain deja_vu FAKE_OPEN_MATCH=PROJ-9 FAKE_CLAUDE_MODE=break CHALK_FP_RULES=on CHALK_TEST_REPORT=out/report.xml \
  CHALK_TEST_CMD="if [ -e BROKEN ]; then mkdir -p out; echo '$junit' > out/report.xml; echo 'AssertionError: BROKEN exists'; exit 1; fi"
check "next step on deja_vu: fix the matching open detention first" \
  detained deja_vu "deja_vu: " "this fails like the open detention of PROJ-9; fix that one first"
detain no_change FAKE_CLAUDE_MODE=break CHALK_FP_RULES=on
check "next step on no_change: make the checkpoint clearer or do it yourself" \
  detained no_change "no_change: " "the agent changed nothing"
detain agent_error FAKE_CLAUDE_MODE=error CHALK_MAX_RETRIES=0
check "next step when the agent stopped early: see why, or raise the budget" \
  detained agent_error "agent stopped early (error_max_turns)" "see why the agent stopped in .*/loop.json"
detain passed FAKE_CLAUDE_MODE=idle CHALK_MAX_RETRIES=0
check "next step when nothing was ticked: tick it or make it testable" \
  detained passed "rubric passed but no checkpoint was ticked" "the rubric passes but no checkpoint was ticked"
detain refused FAKE_CLAUDE_MODE=refused CHALK_MAX_RETRIES=0
check "next step after many permission refusals: check auto mode with chalk doctor" \
  detained refused "rubric passed but no checkpoint was ticked" \
    "4 actions were refused in the last loop, as when auto mode is unavailable for the model; run: chalk doctor"
# Last, as its first loop's progress lands on the working branch.
detain loop_limit CHALK_MAX_LOOPS=1
check "next step at the loop limit: split the checkpoints or raise the limit" \
  detained loop_limit "loop limit of 1 reached" \
    "split the open checkpoints into smaller ones, or raise CHALK_MAX_LOOPS (now 1)"
cd "$tmp/demo"

# 2c. With CHALK_FP_FEEDBACK=true, a retry is told the failing tests and the
# first error, normalized, and only the last 20 lines of output. The rubric
# prints 40 lines before its error, so a 20-line tail starts at line-22.
chalk new PROJ-17 Feedback feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-17"
git add -A && git commit -q -m "spec"
if FAKE_CLAUDE_MODE=break CHALK_FP_FEEDBACK=true CHALK_MAX_RETRIES=1 CHALK_TEST_REPORT=out/report.xml \
   CHALK_TEST_CMD="if [ -e BROKEN ]; then mkdir -p out; echo '$junit' > out/report.xml; seq -f 'line-%g' 1 40; echo 'AssertionError: BROKEN exists at 0x7f3a2b'; exit 1; fi" \
   chalk run > "$tmp/run13.log" 2>&1; then
  fail "a failing run with fp feedback should exit non-zero"
fi
sed -n '/^<failure>$/,/^<\/failure>$/p' "$XDG_STATE_HOME/chalk/demo/runs/PROJ-17/io/prompt.md" > "$tmp/failure13.txt"
check "fp feedback: the retry is told which test still fails" \
  test "$(grep -A1 -x 'this test still fails:' "$tmp/failure13.txt")" = $'this test still fails:\n- demo::no_marker'
check "fp feedback: the retry is told the normalized first error" \
  grep -qx 'first error: AssertionError: BROKEN exists at 0x?' "$tmp/failure13.txt"
check "fp feedback: the output is cut to its last 20 lines" \
  sh -c "grep -qx line-22 '$tmp/failure13.txt' && ! grep -qx line-21 '$tmp/failure13.txt'"
# PROJ-19 ran with the default CHALK_FP_FEEDBACK=false and a report that
# named its failing test: its retry still gets only the reason and output.
prompt19="$XDG_STATE_HOME/chalk/demo/runs/PROJ-19/io/prompt.md"
check "fp feedback: a run without it is told the reason and 60 lines, as before" \
  test "$(sed -n '/^<failure>$/,/^<\/failure>$/p' "$prompt19")" = $'<failure>\nrubric failed (exit 1)\nFAIL demo\n</failure>'
check "fp feedback: the retry instructions are the retry prompt, unchanged" \
  sh -c "tail -n \"\$(wc -l < '$here/../share/prompts/retry.md')\" '$prompt19' | cmp -s - '$here/../share/prompts/retry.md'"
cd "$tmp/demo"

# 2c'. A rubric that prints nothing, as `go test -json ./... > report.json`
# does, leaves a retry nothing to read in its output. Even with the default
# CHALK_FP_FEEDBACK=false, the retry is then told the failing tests from
# the report, and that the rubric printed no output.
chalk new PROJ-22 Silent rubric feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-22"
git add -A && git commit -q -m "spec"
if FAKE_CLAUDE_MODE=break CHALK_MAX_RETRIES=1 CHALK_TEST_REPORT=out/report.json \
   CHALK_TEST_CMD="if [ -e BROKEN ]; then mkdir -p out; echo '$gojson' > out/report.json; exit 1; fi" \
   chalk run > "$tmp/run20.log" 2>&1; then
  fail "a failing run with a silent rubric should exit non-zero"
fi
sed -n '/^<failure>$/,/^<\/failure>$/p' "$XDG_STATE_HOME/chalk/demo/runs/PROJ-22/io/prompt.md" > "$tmp/failure20.txt"
check "silent rubric: the retry is told the failing test from the report" \
  test "$(grep -A1 -x 'this test still fails:' "$tmp/failure20.txt")" = $'this test still fails:\n- demo::TestNoMarker'
check "silent rubric: the retry is told the rubric printed nothing" \
  grep -qx 'the rubric printed no output' "$tmp/failure20.txt"
cd "$tmp/demo"

# 3. Fleet: a plan with two workstreams runs in parallel in the background.
cd "$tmp/demo"
cat > "$tmp/plan.json" <<'PLAN'
{"workstreams":[
  {"ticket":"PROJ-11","title":"First","context":"c","checkpoints":["one","two"]},
  {"ticket":"PROJ-12","title":"Second","context":"c","checkpoints":["one"]}
]}
PLAN
chalk fleet PROJ-10 --plan "$tmp/plan.json" --yes >/dev/null
for _ in $(seq 1 100); do
  grep -q "chalk/PROJ-11" "$FAKE_STATE/glab.log" && grep -q "chalk/PROJ-12" "$FAKE_STATE/glab.log" && break
  sleep 0.2
done
check "fleet workstream 1 completed" git -C "$tmp/origin.git" rev-parse chalk/PROJ-11
check "fleet workstream 2 completed" git -C "$tmp/origin.git" rev-parse chalk/PROJ-12
check "status lists the runs" sh -c 'chalk status | grep -q PROJ-11'
touch -t 209901010000 "$XDG_STATE_HOME/chalk/demo/runs/PROJ-1"
check "status lists the most recently active run first" \
  test "$(chalk status | sed -n 2p | cut -d' ' -f1)" = PROJ-1

# 3b. Prompts in the loop: blockers, spec check, review, overrides.
chalk new PROJ-4 Blocked feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-4"
git add -A && git commit -q -m "spec"
if FAKE_SPEC=fail chalk check > "$tmp/check.log" 2>&1; then fail "bad spec must fail the check"; fi
check "spec check reports the problem and a suggestion" \
  sh -c "grep -q 'not testable' '$tmp/check.log' && grep -q 'state the behaviour' '$tmp/check.log'"
if FAKE_SPEC=fail chalk run > "$tmp/run5.log" 2>&1; then fail "bad spec must stop the run"; fi
check "bad spec stops the run before any loop" sh -c "! grep -q 'loop 1' '$tmp/run5.log'"
check "bad spec does not create a detention" test -z "$(git for-each-ref 'refs/heads/detention/PROJ-4-*')"

if FAKE_CLAUDE_MODE=blocked chalk run > "$tmp/run6.log" 2>&1; then fail "blocked run should exit non-zero"; fi
check "blocker goes to detention without retries" \
  sh -c "grep -q 'needs the staging API key' '$tmp/run6.log' && ! grep -q 'loop 2' '$tmp/run6.log'"
check "blocker text recorded as the lesson signature" grep -q "signature=agent reported a blocker" "$FAKE_STATE/db.log"
check "next step on a blocker: provide what the agent asked for" \
  next_step "$tmp/run6.log" "provide what the agent asked for above"

# The key is provided outside the repository, so nothing is committed, and
# the distillation finds no rule in the evidence.
git switch -q "$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/PROJ-4-*')"
FAKE_DISTILL=none chalk office-hours -m "added the staging API key to the sandbox environment" > "$tmp/run6b.log" 2>&1 ||
  { cat "$tmp/run6b.log"; fail "office hours with the fix outside the repository"; }
distill="$XDG_STATE_HOME/chalk/demo/runs/PROJ-4/distill/distill.prompt.md"
check "with nothing committed, distillation is told the fix was made outside the repository" \
  sh -c "sed -n '/^<fix_diff>$/,/^<\/fix_diff>$/p' '$distill' | grep -q '^No commits since the detention: the engineer changed nothing in this repository' &&
    ! grep -q '^diff --git' '$distill'"
check "distillation is told the note is the source of truth and asked for a scope" \
  sh -c "grep -q 'The note is the source of truth about what was wrong' '$distill' && grep -q 'Set \"scope\"' '$distill'"
check "a distillation that finds no lesson stores none, and keeps the note for this repository only" \
  grep -q -e "-v resolution=added the staging API key to the sandbox environment .*-v lesson= -v scope=repo$" "$FAKE_STATE/db.log"
check "office hours says no lesson was distilled" grep -q "no lesson distilled" "$tmp/run6b.log"
check "the run resumes after an office hours with nothing committed" grep -q "mr create.*tutoring/PROJ-4" "$FAKE_STATE/glab.log"

cd "$tmp/demo"
chalk new PROJ-5 Reviewed feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-5"
git add -A && git commit -q -m "spec"
FAKE_REVIEW=fail-once chalk run > "$tmp/run7.log" 2>&1 || { cat "$tmp/run7.log"; fail "review fix round"; }
check "failed review triggers a fix loop" grep -q "(fix-review)" "$tmp/run7.log"
check "review findings reach the fix prompt" grep -q "feature is a stub" "$XDG_STATE_HOME/chalk/demo/runs/PROJ-5/io/prompt.md"
check "fix is committed and re-reviewed before submission" \
  sh -c "git log --format=%s | grep -q 'fix-review' && grep -q 'mr create.*chalk/PROJ-5' '$FAKE_STATE/glab.log'"

cd "$tmp/demo"
chalk new PROJ-6 Rejected feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-6"
git add -A && git commit -q -m "spec"
if FAKE_REVIEW=fail chalk run > "$tmp/run8.log" 2>&1; then fail "persistently failing review should exit non-zero"; fi
check "unresolved review goes to detention, not a merge request" \
  sh -c "test -n \"\$(git for-each-ref 'refs/heads/detention/PROJ-6-*')\" && ! grep -q 'chalk/PROJ-6' '$FAKE_STATE/glab.log'"
check "next step when the review still fails: fix the findings" \
  next_step "$tmp/run8.log" "fix the review findings above, or raise CHALK_REVIEW_ROUNDS (now 1)"

cd "$tmp/demo"
chalk prompts eject continue >/dev/null
check "ejected prompt is listed as overridden" sh -c "chalk prompts | grep -q 'continue *overridden'"
rm -rf .chalk/prompts

# 3c. Report card and OpenTelemetry export.
# Stored text containing "</script>" must not close the page's script tag.
# The fake database's canned answer carries such text; a real one gets it
# through a run row.
if [ -n "${FAKE_PG_URL:-}" ]; then
  psql "$FAKE_PG_URL" -q -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons, failing_tests)
VALUES ('</script>', 'PROJ-99', 'chalk/PROJ-99', 1, 'continue', 'ok', 0, true, 'm',
        'p', 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 'x::</script><b>');
SQL
fi
chalk dashboard --no-open --days 7 --output "$tmp/report.html" >/dev/null
check "dashboard page is built with its data embedded" \
  sh -c "grep -q 'Chalk report card' '$tmp/report.html' && grep -q '\"generated_at\"' '$tmp/report.html' && ! grep -q 'CHALK_DATA' '$tmp/report.html'"
check "stored text cannot close the dashboard's script tag" \
  sh -c "grep -qF '\"<\\/script>\"' '$tmp/report.html' && ! grep -qF '\"</script>\"' '$tmp/report.html'"
if [ -n "${FAKE_PG_URL:-}" ]; then
  check "a stored failing test name cannot close the dashboard's script tag" \
    sh -c "grep -qF '\"x::<\\/script><b>\"' '$tmp/report.html' && ! grep -qF 'x::</script>' '$tmp/report.html'"
fi

# 3c'. Against a real Postgres: the schema upgrades a populated database in
# place, and the verdict ledger adds up. Both run in a schema of their own,
# so the numbers do not depend on the rest of this test.
if [ -n "${FAKE_PG_URL:-}" ]; then
  pg() { PGOPTIONS='-c search_path=chalk_e2e,public -c client_min_messages=warning' psql "$FAKE_PG_URL" -X -q -A -t -v ON_ERROR_STOP=1 "$@"; }
  pg -c 'DROP SCHEMA IF EXISTS chalk_e2e CASCADE' -c 'CREATE SCHEMA chalk_e2e'
  pg -f "$here/../share/schema.sql"
  # A database from before fingerprints, with a row in it.
  pg <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons)
VALUES ('old', 'OLD-1', 'chalk/OLD-1', 1, 'continue', 'ok', 0, true, 'm', 'p', 0.5, 1, 0, 0, 0, 0, 0, 0, 0, 0);
INSERT INTO lessons (repo, ticket, signature) VALUES ('old', 'OLD-1', 'rubric failed');
ALTER TABLE runs DROP COLUMN run_id, DROP COLUMN tests_hash, DROP COLUMN failing,
                 DROP COLUMN first_error, DROP COLUMN tree_id, DROP COLUMN verdict,
                 DROP COLUMN fp_rules;
DROP INDEX lessons_fingerprint_idx;
ALTER TABLE lessons DROP COLUMN run_id, DROP COLUMN fingerprint, DROP COLUMN first_error;
ALTER TABLE runs DROP COLUMN failing_tests;
ALTER TABLE lessons DROP COLUMN scope;
SQL
  pg -f "$here/../share/schema.sql"
  pg -f "$here/../share/schema.sql"
  check "schema: applied twice to a populated database, every row is kept" \
    test "$(pg -c 'SELECT count(*) FROM runs'):$(pg -c 'SELECT count(*) FROM lessons')" = 1:1
  check "schema: the fingerprint columns are added, and old rows read as NULL" \
    test "$(pg -c "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'chalk_e2e'
                     AND column_name IN ('run_id', 'tests_hash', 'failing', 'first_error', 'tree_id',
                                         'verdict', 'fingerprint', 'fp_rules')"):$(pg -c 'SELECT count(*) FROM runs WHERE verdict IS NULL AND fp_rules IS NULL')" = 10:1
  check "schema: lessons are indexed by fingerprint" \
    test "$(pg -c "SELECT count(*) FROM pg_indexes WHERE schemaname = 'chalk_e2e' AND indexname = 'lessons_fingerprint_idx'")" = 1
  check "schema: the failing test IDs column is added, and old rows read as NULL" \
    test "$(pg -c 'SELECT count(*) FROM runs WHERE failing_tests IS NULL')" = 1
  check "schema: the lesson scope column is added, and old lessons read as NULL, recalled anywhere" \
    test "$(pg -c 'SELECT count(*) FROM lessons WHERE scope IS NULL')" = 1

  # Four runs, ten cents a loop unless noted:
  #   L-1 detained:  first, no_change, no_change (30c)   saves 30c by no_change
  #   L-2 detained:  first, repeat, repeat (40c)         saves 40c by repeat
  #   L-3 submitted: first, no_change, progressed (50c)  a false stop, 50c after it
  #   L-4 detained:  first, improving, improving         converging but detained
  #   L-5 detained:  first, repeat, under CHALK_FP_RULES=on: stopped at its
  #                  first stop, so it is counted apart and changes nothing
  #   L-6 detained:  blocked (15c)                       blocker only: apart
  #   L-7 detained:  agent_error, blocked (5c, 5c)       no rule judged it: apart
  #   L-8 detained:  no verdicts, under CHALK_FP_RULES=off (20c): apart
  #   L-9 detained:  first, blocked (10c, 10c)           a judged loop: counted
  # L-1 records CHALK_FP_RULES=shadow; the others, from before it was
  # recorded, record nothing and count as shadow.
  pg -c 'TRUNCATE runs, lessons'
  pg <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons,
                  run_id, failing, verdict)
SELECT 'ledger', t, 'chalk/' || t, n, CASE n WHEN 1 THEN 'continue' ELSE 'retry' END, 'ok',
       CASE WHEN p THEN 0 ELSE 1 END, p, 'm', 'p', cost, 1, 1, 0, 0, 0, 0, 0, 0, 0,
       t || '-100', failing, verdict
  FROM (VALUES
    ('L-1', 1, false, 0.10, NULL, 'first'), ('L-1', 2, false, 0.20, NULL, 'no_change'),
    ('L-1', 3, false, 0.30, NULL, 'no_change'),
    ('L-2', 1, false, 0.10, 1, 'first'), ('L-2', 2, false, 0.20, 1, 'repeat'),
    ('L-2', 3, false, 0.40, 1, 'repeat'),
    ('L-3', 1, false, 0.10, NULL, 'first'), ('L-3', 2, false, 0.10, NULL, 'no_change'),
    ('L-3', 3, true, 0.50, NULL, NULL),
    ('L-4', 1, false, 0.10, 3, 'first'), ('L-4', 2, false, 0.20, 2, 'improving'),
    ('L-4', 3, false, 0.30, 1, 'improving')
  ) v(t, n, p, cost, failing, verdict);
UPDATE runs SET fp_rules = 'shadow' WHERE run_id = 'L-1-100';
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons,
                  run_id, failing, verdict, fp_rules)
VALUES ('ledger-on', 'L-5', 'chalk/L-5', 1, 'continue', 'ok', 1, false, 'm', 'p', 0.10, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 'L-5-100', 1, 'first', 'on'),
       ('ledger-on', 'L-5', 'chalk/L-5', 2, 'retry', 'ok', 1, false, 'm', 'p', 0.20, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 'L-5-100', 1, 'repeat', 'on');
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons,
                  run_id, verdict, fp_rules)
SELECT 'ledger', t, 'chalk/' || t, n, CASE n WHEN 1 THEN 'continue' ELSE 'retry' END, status,
       CASE status WHEN 'ok' THEN 1 ELSE 0 END, false, 'm', 'p', cost, 1, 1, 0, 0, 0, 0, 0, 0, 0,
       t || '-100', verdict, rules
  FROM (VALUES
    ('L-6', 1, 'blocked', 0.15, 'blocked', 'shadow'),
    ('L-7', 1, 'error_max_turns', 0.05, 'agent_error', 'shadow'),
    ('L-7', 2, 'blocked', 0.05, 'blocked', 'shadow'),
    ('L-8', 1, 'ok', 0.10, NULL, 'off'), ('L-8', 2, 'ok', 0.10, NULL, 'off'),
    ('L-9', 1, 'ok', 0.10, 'first', 'shadow'), ('L-9', 2, 'blocked', 0.10, 'blocked', 'shadow')
  ) v(t, n, status, cost, verdict, rules);
INSERT INTO lessons (repo, ticket, signature, run_id)
VALUES ('ledger', 'L-1', 's', 'L-1-100'), ('ledger', 'L-2', 's', 'L-2-100'), ('ledger', 'L-4', 's', 'L-4-100'),
       ('ledger-on', 'L-5', 's', 'L-5-100'), ('ledger', 'L-6', 's', 'L-6-100'),
       ('ledger', 'L-7', 's', 'L-7-100'), ('ledger', 'L-8', 's', 'L-8-100'), ('ledger', 'L-9', 's', 'L-9-100');
SQL
  pg -v days=30 -f "$here/../share/dashboard.sql" | jq -c .ledger > "$tmp/ledger.json"
  # Amounts are compared in cents: jq may keep "0.7000" as Postgres wrote it.
  ledger() { jq -r "def c: . * 100 | round; $1" "$tmp/ledger.json"; }
  check "ledger: no-progress spend and savings on detained runs with a judged verdict" \
    test "$(ledger '[.detained_runs, (.no_progress_cost | c), (.saved | c)] | join(" ")')" = "4 210 70"
  check "ledger: detentions with only blockers or agent errors, or no verdicts, are counted apart" \
    test "$(ledger '[.blocked_only, (.blocked_only_cost | c), .no_verdicts] | join(" ")')" = "2 25 1"
  check "ledger: savings split by the first stopping verdict" \
    test "$(ledger '[.by_verdict[] | "\(.verdict)=\(.runs)/\(.saved | c)"] | join(" ")')" = "repeat=1/40 no_change=1/30"
  check "ledger: a stop followed by progress is a false stop, with the spend after it" \
    test "$(ledger '[.false_stops, (.false_stop_cost | c)] | join(" ")')" = "1 50"
  check "ledger: runs detained while improving are counted" test "$(ledger .converging)" = 1
  check "ledger: a run stopped by CHALK_FP_RULES=on is counted apart" test "$(ledger .stopped_on)" = 1
  check "ledger: one row per run" \
    test "$(ledger '[.runs[] | "\(.run_id):\(.could_stop):\(.stop_verdict):\(.stop_loop):\(.after_cost | c):\(.false_stop):\(.converging)"] | sort | join(" ")')" \
      = "L-1-100:true:no_change:2:30:false:false L-2-100:true:repeat:2:40:false:false L-3-100:true:no_change:2:50:true:false L-4-100:true:null:null:0:false:true L-6-100:false:null:null:0:false:false L-7-100:false:null:null:0:false:false L-8-100:false:null:null:0:false:false L-9-100:true:null:null:0:false:false"
  check "ledger: failed loops that named no tests, per repository" \
    test "$(ledger '[.unknown_tests[] | "\(.repo) \(.loops) \(.unknown)"] | join(" ")')" = "ledger 12 6 ledger-on 2 0"

  # Tests that keep failing: in ft, test a fails in four loops on two
  # tickets, b in two and c in one; a review naming z is not a loop. In
  # ft2 one loop names twelve tests, of which ten are shown.
  pg <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons, failing_tests)
SELECT repo, t, 'chalk/' || t, n, kind, 'ok', 1, false, 'm', 'p', 0.1, 1, 1, 0, 0, 0, 0, 0, 0, 0, tests
  FROM (VALUES
    ('ft', 'F-1', 1, 'continue', E'a\nb'), ('ft', 'F-1', 2, 'retry', E'a\nb'),
    ('ft', 'F-1', 3, 'retry', 'a'), ('ft', 'F-2', 1, 'continue', E'a\nc'),
    ('ft', 'F-2', 2, 'review', 'z'),
    ('ft2', 'G-1', 1, 'continue', (SELECT string_agg(format('t%s', lpad(i::text, 2, '0')), E'\n')
                                     FROM generate_series(1, 12) i))
  ) v(repo, t, n, kind, tests);
SQL
  pg -v days=30 -f "$here/../share/dashboard.sql" | jq -c .failing_tests > "$tmp/failing.json"
  check "failing tests: counted per repository by failed loops and tickets, most first" \
    test "$(jq -r '[.[] | select(.repo == "ft") | "\(.test) \(.loops) \(.tickets)"] | join(", ")' "$tmp/failing.json")" \
      = "a 4 2, b 2 1, c 1 1"
  check "failing tests: at most ten per repository" \
    test "$(jq -r '[.[] | select(.repo == "ft2") | .test] | "\(length) \(first) \(last)"' "$tmp/failing.json")" = "10 t01 t10"
  check "failing tests: each row says when the test last failed" \
    test "$(jq '[.[] | .last | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")] | all' "$tmp/failing.json")" = true
  pg -c 'DROP SCHEMA chalk_e2e CASCADE'
fi

check "telemetry is off unless an endpoint is set" sh -c "! grep -q OTEL_ '$FAKE_STATE/docker.log'"
chalk new PROJ-7 Traced feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-7"
git add -A && git commit -q -m "spec"
CHALK_OTEL_ENDPOINT=http://localhost:4317 chalk run >/dev/null 2>&1 || fail "run with telemetry"
check "telemetry endpoint is rewritten to reach the host collector" \
  grep -q "OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4317" "$FAKE_STATE/docker.log"
check "traces are tagged with repository and ticket" \
  sh -c "grep -q 'OTEL_TRACES_EXPORTER=otlp' '$FAKE_STATE/docker.log' && grep -q 'chalk.repo=demo,chalk.ticket=PROJ-7' '$FAKE_STATE/docker.log'"
cd "$tmp/demo"

# 3d. A stopped run exits with the conventional code and still cleans up.
chalk new PROJ-8 Stopped feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-8"
git add -A && git commit -q -m "spec"
FAKE_CLAUDE_MODE=slow chalk run > "$tmp/run9.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do [ -e "$FAKE_STATE/slow-started" ] && break; sleep 0.2; done
kill -TERM "$pid"
status=0
wait "$pid" || status=$?
check "a run stopped by SIGTERM exits 143" test "$status" -eq 143
check "a stopped run removes its sandbox" test ! -e "$FAKE_STATE/chalk-sandbox-demo-PROJ-8"
cd "$tmp/demo"

# 3d'. A detached run shows as running as soon as the command returns.
chalk new PROJ-30 Detached feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-30"
git add -A && git commit -q -m "spec"
rm -f "$FAKE_STATE/slow-started"
FAKE_CLAUDE_MODE=slow chalk run --detach >/dev/null
check "a detached run is listed as running straight away" \
  sh -c 'chalk status | grep -q "^PROJ-30 *running"'
for _ in $(seq 1 50); do [ -e "$FAKE_STATE/slow-started" ] && break; sleep 0.2; done
check "the detached run gets past its own recorded pid to the agent" \
  sh -c "test -e '$FAKE_STATE/slow-started' && ! grep -q 'already active' '$XDG_STATE_HOME/chalk/demo/runs/PROJ-30/run.log'"
read -r pid < "$XDG_STATE_HOME/chalk/demo/runs/PROJ-30/pid"
kill -TERM "$pid"
for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
cd "$tmp/demo"

# 3e. A sandbox image whose bash is too old is refused before any agent runs.
chalk new PROJ-13 Old image >/dev/null
cd "$tmp/demo.worktrees/PROJ-13"
git add -A && git commit -q -m "spec"
if FAKE_SANDBOX_BASH="5 1" chalk run > "$tmp/run10.log" 2>&1; then fail "an image with bash 5.1 must be refused"; fi
check "an image with bash 5.1 is refused with the reason" \
  grep -q "has bash 5.1; Chalk needs bash >= 5.2 in the sandbox" "$tmp/run10.log"
check "the refused sandbox is removed" test ! -e "$FAKE_STATE/chalk-sandbox-demo-PROJ-13"
check "no agent ran in the refused sandbox" sh -c "! grep -q 'loop 1' '$tmp/run10.log'"
cd "$tmp/demo"

# 3f. A service that cannot start stops the run and is named.
chalk new PROJ-14 No database >/dev/null
cd "$tmp/demo.worktrees/PROJ-14"
git add -A && git commit -q -m "spec"
if FAKE_DB_BROKEN=1 chalk run > "$tmp/run11.log" 2>&1; then fail "a run without its database must stop"; fi
check "a service that fails to start is named" grep -q "could not start: database" "$tmp/run11.log"
check "no sandbox is started when a service fails" test ! -e "$FAKE_STATE/chalk-sandbox-demo-PROJ-14"
cd "$tmp/demo"

# 3f'. A push the remote refuses shows the remote's reason, and stops the
# run before any request is opened.
chalk new PROJ-23 Refused push >/dev/null
cd "$tmp/demo.worktrees/PROJ-23"
git add -A && git commit -q -m "spec"
if chalk run > "$tmp/run23.log" 2>&1; then fail "a refused push must fail the run"; fi
check "a refused push shows what the remote said, and why the run stopped" \
  sh -c "grep -q '^remote: error: pushes to chalk/PROJ-23 are not allowed' '$tmp/run23.log' &&
    grep -q '^error: could not push chalk/PROJ-23 to origin' '$tmp/run23.log' &&
    ! grep -q 'chalk/PROJ-23' '$FAKE_STATE/glab.log'"
cd "$tmp/demo"

# 3f''. chalk status gives every ticket that is not running the state it
# was left in: submitted (PROJ-1, and PROJ-2 and PROJ-4 after office
# hours), detained (PROJ-6 by its review), spec-blocked (PROJ-24),
# done when the work passed review but was not submitted (PROJ-23, whose
# push was refused), stopped when the run ended with no outcome (PROJ-8,
# stopped by SIGTERM) and new when no call was made (PROJ-14, whose
# database did not start).
chalk new PROJ-24 Spec not ready >/dev/null
cd "$tmp/demo.worktrees/PROJ-24"
git add -A && git commit -q -m "spec"
if FAKE_SPEC=fail chalk run > /dev/null 2>&1; then fail "a spec that is not ready must stop the run"; fi
cd "$tmp/demo"
chalk status > "$tmp/status.log"
state_of() { awk -v t="$1" '$1 == t { print $2 }' "$tmp/status.log"; }
check "status: states of tickets that are not running" \
  test "$(for t in PROJ-1 PROJ-2 PROJ-6 PROJ-4 PROJ-24 PROJ-23 PROJ-8 PROJ-14; do printf '%s=%s ' "$t" "$(state_of "$t")"; done)" \
    = "PROJ-1=submitted PROJ-2=submitted PROJ-6=detained PROJ-4=submitted PROJ-24=spec-blocked PROJ-23=done PROJ-8=stopped PROJ-14=new "
check "status: no ticket is idle" sh -c "! grep -q ' idle ' '$tmp/status.log'"

# 3g. Database versions and `chalk db upgrade`. With FAKE_DB_MODEL set, the
# fake keeps chalk-db containers and volumes as state, here in a fake state
# of their own.
db_state="$tmp/db-model"
db_reset() { rm -rf "$db_state"; mkdir -p "$db_state"; }
in_db_model() { FAKE_STATE="$db_state" FAKE_DB_MODEL=1 "$@"; }
db_field() { cat "$db_state/dbs/$1/$2" 2>/dev/null || true; }

# Two first runs on a fresh machine both reach the database; one creates it.
db_reset
for ticket in PROJ-15 PROJ-16; do
  chalk new "$ticket" Fresh machine >/dev/null
  (cd "$tmp/demo.worktrees/$ticket" && git add -A && git commit -q -m "spec")
done
pids=()
for ticket in PROJ-15 PROJ-16; do
  (cd "$tmp/demo.worktrees/$ticket" && in_db_model chalk run > "$tmp/$ticket.log" 2>&1) &
  pids+=("$!")
done
reached=0
for pid in "${pids[@]}"; do
  if wait "$pid"; then reached=$((reached + 1)); fi
done
[ "$reached" -eq 2 ] || cat "$tmp/PROJ-15.log" "$tmp/PROJ-16.log"
check "two first runs on a fresh machine both reach the database" test "$reached" -eq 2
check "exactly one of them creates chalk-db" test "$(grep -c -e '--name chalk-db ' "$db_state/docker.log")" -eq 1
check "a fresh machine gets Postgres 17 with pgvector, on the new volume" \
  test "$(db_field chalk-db image) $(db_field chalk-db volume)" = "pgvector/pgvector:pg17 chalk-db-data-17"

# A missing container on the legacy volume comes back on Postgres 16.
db_reset
mkdir -p "$db_state/volumes/chalk-db-data"
in_db_model chalk db up > "$tmp/db1.log" 2>&1 || { cat "$tmp/db1.log"; fail "db up on the legacy volume"; }
check "a missing container on the legacy volume is recreated on Postgres 16" \
  test "$(db_field chalk-db image) $(db_field chalk-db volume)" = "postgres:16-alpine chalk-db-data"
check "Postgres 17 is never started next to Postgres 16 data" test ! -e "$db_state/volumes/chalk-db-data-17"
check "a Postgres 16 database warns to upgrade, and carries on" \
  grep -q 'run `chalk db upgrade`; semantic recall is off until then' "$tmp/db1.log"
# Every run starts the database, so the warning is given once a day.
in_db_model chalk db up > "$tmp/db1b.log" 2>&1 || { cat "$tmp/db1b.log"; fail "db up again on Postgres 16"; }
check "the Postgres 16 warning is not repeated the same day" sh -c "! grep -q 'chalk db upgrade' '$tmp/db1b.log'"
echo 2000-01-01 > "$XDG_STATE_HOME/chalk/db-upgrade-warned"
in_db_model chalk db up > "$tmp/db1c.log" 2>&1 || { cat "$tmp/db1c.log"; fail "db up on Postgres 16 another day"; }
check "the Postgres 16 warning is given again on another day" grep -q 'run `chalk db upgrade`' "$tmp/db1c.log"
in_db_model chalk doctor > "$tmp/doctor16.log" 2>&1 || true
check "chalk doctor reports Postgres 16 every time, whatever the day" \
  grep -q 'database on Postgres 16 (chalk-db-data): run: chalk db upgrade' "$tmp/doctor16.log"

mkdir -p "$XDG_STATE_HOME/chalk/other/runs/PROJ-77"
echo "$$" > "$XDG_STATE_HOME/chalk/other/runs/PROJ-77/pid"
if in_db_model chalk db upgrade > "$tmp/db2.log" 2>&1; then fail "upgrade must refuse while a run is active"; fi
check "upgrade refuses while any run is active, and changes nothing" \
  sh -c "grep -q 'still active' '$tmp/db2.log' && test ! -e '$db_state/dbs/chalk-db-16'"
rm -rf "$XDG_STATE_HOME/chalk/other"

if in_db_model chalk db upgrade --cleanup > "$tmp/db3.log" 2>&1; then fail "cleanup must refuse before an upgrade"; fi
check "cleanup before an upgrade removes nothing" test -d "$db_state/volumes/chalk-db-data"

# A restore that fails puts the original container back, running.
if FAKE_DB_RESTORE_FAIL=1 in_db_model chalk db upgrade > "$tmp/db4.log" 2>&1; then
  fail "a failed restore must fail the upgrade"
fi
check "a failed restore leaves the original chalk-db running on its volume" \
  test "$(db_field chalk-db image) $(db_field chalk-db volume) $(db_field chalk-db running)" = \
    "postgres:16-alpine chalk-db-data true"
check "rollback removes the new container's volume and frees the old name" \
  test ! -e "$db_state/volumes/chalk-db-data-17" -a ! -e "$db_state/dbs/chalk-db-16"
check "a failed upgrade says what failed and that it rolled back" \
  sh -c "grep -q 'upgrade failed: the restore failed' '$tmp/db4.log' && grep -q 'rolled back' '$tmp/db4.log'"

# A successful upgrade, then cleanup.
in_db_model chalk db upgrade > "$tmp/db5.log" 2>&1 || { cat "$tmp/db5.log"; fail "db upgrade"; }
check "upgrade moves chalk-db to Postgres 17 on its own volume" \
  test "$(db_field chalk-db image) $(db_field chalk-db volume) $(db_field chalk-db running)" = \
    "pgvector/pgvector:pg17 chalk-db-data-17 true"
check "the dump of the old database is restored into the new one" grep -q "database cluster dump" "$db_state/db.log"
check "row counts are verified after the restore" grep -Eq "runs events lessons: [0-9]+ [0-9]+ [0-9]+ rows" "$tmp/db5.log"
check "the old container is kept, stopped, as chalk-db-16" \
  test "$(db_field chalk-db-16 image) $(db_field chalk-db-16 running)" = "postgres:16-alpine false"
in_db_model chalk db up > "$tmp/db6.log" 2>&1 || { cat "$tmp/db6.log"; fail "db up after upgrade"; }
check "Postgres 17 does not warn" sh -c "! grep -q 'chalk db upgrade' '$tmp/db6.log'"
in_db_model chalk db upgrade --cleanup > "$tmp/db7.log" 2>&1 || { cat "$tmp/db7.log"; fail "cleanup"; }
check "cleanup removes chalk-db-16 and the legacy volume" \
  test ! -e "$db_state/dbs/chalk-db-16" -a ! -e "$db_state/volumes/chalk-db-data"
check "cleanup keeps the upgraded database" test "$(db_field chalk-db image)" = "pgvector/pgvector:pg17"
cd "$tmp/demo"

# 4. Lesson memory. Hindsight was removed: its old settings still load, with
# one warning, and nothing but the database is started for lessons.
chalk new PROJ-3 Memory feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-3"
git add -A && git commit -q -m "spec"
rm -f "$FAKE_STATE/curl.log"
if FAKE_CLAUDE_MODE=break CHALK_MEMORY=hindsight CHALK_MEMORY_URL=http://127.0.0.1:18888 \
   chalk run > "$tmp/run4.log" 2>&1; then
  fail "failing run should exit non-zero"
fi
check "old Hindsight settings: the run goes ahead, with one warning naming them" \
  sh -c "grep -q 'DETENTION: rubric failed' '$tmp/run4.log' &&
    test \"\$(grep -c '^warning: ignoring CHALK_MEMORY=hindsight CHALK_MEMORY_URL: Hindsight lesson memory was removed' '$tmp/run4.log')\" -eq 1"
check "no lesson memory service is started" \
  sh -c "test ! -e '$XDG_STATE_HOME/chalk/demo/runs/PROJ-3/io/startup/memory.log' &&
    ! grep -q chalk-memory '$FAKE_STATE/docker.log' && test ! -e '$FAKE_STATE/curl.log'"
git switch -q "$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/PROJ-3-*')"
git rm -q BROKEN && git commit -q -m "remove the blocker"
CHALK_MEMORY=hindsight FAKE_DISTILL=repo chalk office-hours -m "note" > "$tmp/run4b.log" 2>&1 ||
  { cat "$tmp/run4b.log"; fail "office hours with old Hindsight settings"; }
check "a lesson about this repository is stored and reported as recalled here only" \
  sh -c "grep -q -e '-v resolution=note .*-v scope=repo$' '$FAKE_STATE/db.log' &&
    grep -q 'lesson, recalled in this repository only: Distilled' '$tmp/run4b.log'"
check "office hours resolves the lesson without syncing it anywhere" \
  sh -c "grep -q 'resolution=note' '$FAKE_STATE/db.log' && ! grep -q 'SET memory_synced_at' '$FAKE_STATE/db.log' &&
    ! grep -q 'chalk memory sync' '$tmp/run4b.log'"
chalk memory sync > "$tmp/memory.log" 2>&1 || fail "chalk memory must exit 0"
check "chalk memory says Hindsight was removed and how to clean it up" \
  sh -c "grep -q 'Hindsight lesson memory was removed' '$tmp/memory.log' &&
    grep -qF 'docker rm -f chalk-memory && docker volume rm chalk-memory-data' '$tmp/memory.log'"
cd "$tmp/demo"

# 4b. Against a real Postgres: a resolved lesson that matches the failure
# reaches the prompt's <lessons> and is counted in runs.lessons. The runs
# use a schema of their own, so the seeded lessons are the only ones. Their
# rubric fails with a known first error (E) and, through a JUnit report, a
# known failing test (T); the agent leaves BROKEN behind on every loop. With
# one retry allowed, loop 1 recalls by the spec and loop 2 by the failure.
if [ -n "${FAKE_PG_URL:-}" ]; then
  export PGOPTIONS='-c search_path=chalk_recall,public -c client_min_messages=warning'
  rpg() { psql "$FAKE_PG_URL" -X -q -A -t -v ON_ERROR_STOP=1 "$@"; }
  rpg -c 'DROP SCHEMA IF EXISTS chalk_recall CASCADE' -c 'CREATE SCHEMA chalk_recall'
  rpg -f "$here/../share/schema.sql"
  error='AssertionError: BROKEN exists'
  recall_cmd="if [ -e BROKEN ]; then mkdir -p out; echo '$junit' > out/report.xml; echo '$error'; exit 1; fi"
  # The lesson fingerprint of that failure: sha256 of T and E (fp_compute).
  if command -v sha256sum >/dev/null; then sha=(sha256sum); else sha=(shasum -a 256); fi
  fingerprint="$(printf '%s\n\n%s\n' demo::no_marker "$error" | "${sha[@]}" | cut -d' ' -f1)"

  # seed REPO FINGERPRINT FIRST_ERROR SIGNATURE FIX [SCOPE]: a resolved
  # lesson. An empty FINGERPRINT, FIRST_ERROR or SCOPE is stored as NULL, as
  # for old lessons.
  seed() {
    rpg -v repo="$1" -v fingerprint="$2" -v first_error="$3" -v signature="$4" -v fix="$5" \
      -v scope="${6:-}" <<'SQL'
INSERT INTO lessons (repo, ticket, signature, resolution, lesson, resolved_by, resolved_at,
                     fingerprint, first_error, scope)
VALUES (:'repo', 'SEED-1', :'signature', 'note', :'fix', 'e2e', now(),
        nullif(:'fingerprint', ''), nullif(:'first_error', ''), nullif(:'scope', ''));
SQL
  }
  # recall_run TICKET [ENV=VALUE...]: a run of TICKET whose rubric always
  # fails, after the given extra line is added to its spec (RECALL_CONTEXT).
  recall_run() {
    local ticket="$1"
    shift
    cd "$tmp/demo"
    chalk new "$ticket" Recall feature >/dev/null
    cd "$tmp/demo.worktrees/$ticket"
    if [ -n "${RECALL_CONTEXT:-}" ]; then
      sed -i.bak "s|^What is being built.*|$RECALL_CONTEXT|" "specs/$ticket.md" && rm "specs/$ticket.md.bak"
    fi
    git add -A && git commit -q -m "spec"
    if env FAKE_CLAUDE_MODE=break CHALK_MAX_RETRIES=1 CHALK_TEST_REPORT=out/report.xml \
         CHALK_TEST_CMD="$recall_cmd" "$@" chalk run > "$tmp/$ticket.log" 2>&1; then
      fail "the recall run for $ticket should end in detention"
    fi
    cd "$tmp/demo"
  }
  # recalled TICKET: the fixes in the last prompt's <lessons> block, in order.
  recalled() {
    sed -n '/^<lessons>$/,/^<\/lessons>$/s/^  Fix: //p' "$XDG_STATE_HOME/chalk/demo/runs/$1/io/prompt.md" | paste -sd ' ' -
  }
  # counted TICKET: runs.lessons for each agent loop of TICKET, in order.
  counted() {
    rpg -v ticket="$1" <<'SQL'
SELECT string_agg(lessons::text, ' ' ORDER BY loop) FROM runs
 WHERE ticket = :'ticket' AND kind IN ('continue', 'retry');
SQL
  }

  # 1. Exact: the same fingerprint in the same repository comes first, and
  # three lexical matches cannot push it out. The same fingerprint in
  # another repository is not an exact match.
  rpg -c 'TRUNCATE lessons, runs'
  seed demo "$fingerprint" "" "disk quota exceeded" EXACT-FIX
  seed other "$fingerprint" "" "disk quota exceeded" OTHER-REPO-FIX
  for fix in LEX-A LEX-B LEX-C; do seed other "fp-$fix" "$error" "rubric failed" "$fix"; done
  recall_run PROJ-40
  check "recall: the failure's own detention lesson carries the fingerprint seeded here" \
    test "$(rpg -c "SELECT fingerprint FROM lessons WHERE ticket = 'PROJ-40'")" = "$fingerprint"
  check "recall: an exact fingerprint match comes first and is never displaced" \
    test "$(recalled PROJ-40)" = "EXACT-FIX LEX-C LEX-B"
  check "recall: the lessons given are counted in runs.lessons" test "$(counted PROJ-40)" = "0 3"

  # 2. Lexical: a similar first error from another repository matches; a
  # different error does not.
  rpg -c 'TRUNCATE lessons, runs'
  seed other fp-1 "$error in the working tree" "rubric failed" LEXICAL-FIX
  seed other fp-2 "TypeError: Cannot read properties of undefined (reading 'map')" "rubric failed" WRONG-FIX
  recall_run PROJ-41
  check "recall: a lesson with a similar first error is recalled after a failure" \
    test "$(recalled PROJ-41):$(counted PROJ-41)" = "LEXICAL-FIX:0 1"

  # 3. Legacy: a lesson from before fingerprints has no first_error, and is
  # matched on its signature. An unresolved one is never recalled.
  rpg -c 'TRUNCATE lessons, runs'
  seed other "" "" "rubric failed (exit 1)
$error
FAILED demo::no_marker" LEGACY-FIX
  seed other "" "" "rubric failed (exit 2)
panic: runtime error: index out of range [3] with length 3" OTHER-LEGACY-FIX
  rpg -c "INSERT INTO lessons (repo, ticket, signature) VALUES ('demo', 'OPEN-1', 'rubric failed (exit 1)
$error')"
  recall_run PROJ-42
  check "recall: a lesson with no first_error is matched on its signature" \
    test "$(recalled PROJ-42):$(counted PROJ-42)" = "LEGACY-FIX:0 1"

  # 4. First loop: before any failure, a lesson whose error the spec mentions.
  rpg -c 'TRUNCATE lessons, runs'
  seed other fp-1 "$error" "rubric failed" SPEC-FIX
  seed other fp-2 "panic: runtime error: index out of range [3] with length 3" "rubric failed" NOT-IN-SPEC-FIX
  RECALL_CONTEXT="CI fails with $error after the last refactor; make the marker check pass." \
    recall_run PROJ-43 FAKE_CLAUDE_MODE=blocked
  check "recall: the first loop gets the lessons whose error the spec mentions" \
    test "$(recalled PROJ-43):$(counted PROJ-43)" = "SPEC-FIX:1"

  # 5. No match: no <lessons> block at all, and nothing counted.
  rpg -c 'TRUNCATE lessons, runs'
  seed other fp-1 "TypeError: Cannot read properties of undefined (reading 'map')" "rubric failed (exit 2)" NOPE-FIX
  recall_run PROJ-44
  check "recall: with no matching lesson the prompt has no <lessons> block" \
    sh -c "! grep -q '<lessons>' '$XDG_STATE_HOME/chalk/demo/runs/PROJ-44/io/prompt.md'"
  check "recall: with no matching lesson none are counted" test "$(counted PROJ-44)" = "0 0"

  # 6. Without fingerprints, recall matches the failure text, as it always did.
  rpg -c 'TRUNCATE lessons, runs'
  seed other "" "" "rubric failed (exit 1)
$error" TEXT-FIX
  recall_run PROJ-45 CHALK_FP_RULES=off
  check "recall: with CHALK_FP_RULES=off, lessons are matched on the failure text" \
    test "$(recalled PROJ-45):$(counted PROJ-45)" = "TEXT-FIX:0 1"

  # 7. Scope: a lesson scoped to its repository is recalled only there; a
  # general one, like one from before scopes, anywhere.
  rpg -c 'TRUNCATE lessons, runs'
  seed other fp-1 "$error" "rubric failed" OTHER-REPO-ONLY-FIX repo
  seed demo fp-2 "$error" "rubric failed" OWN-REPO-FIX repo
  seed other fp-3 "$error" "rubric failed" GENERAL-FIX general
  recall_run PROJ-46
  check "recall: a lesson scoped to another repository is not recalled; one scoped to this one is" \
    test "$(recalled PROJ-46):$(counted PROJ-46)" = "GENERAL-FIX OWN-REPO-FIX:0 2"

  rpg -c 'DROP SCHEMA chalk_recall CASCADE'
  export PGOPTIONS="$e2e_pgoptions"
fi

# 5. GitHub: a repository with CHALK_FORGE=github gets Actions gates and a
# pull request through gh.
git init -q --bare "$tmp/hub-origin.git"
git init -q -b main "$tmp/hub"
cd "$tmp/hub"
git remote add origin "$tmp/hub-origin.git"
export CHALK_FORGE=github
chalk init > "$tmp/init5.log"
check "init on GitHub adds the Actions workflow, not GitLab CI" \
  test -f .github/workflows/chalk.yml -a ! -e .gitlab-ci.yml -a ! -e .gitlab
check "init on GitHub names the repository variable CHALK_CI_IMAGE" \
  grep -q 'not Node 22?.*the repository variable CHALK_CI_IMAGE' "$tmp/init5.log"
CHALK_IMAGE=chalk-sandbox-go:local chalk init > "$tmp/init5b.log"
check "init with a custom CHALK_IMAGE asks for CHALK_CI_IMAGE as an action" \
  grep -q 'action   CHALK_IMAGE is chalk-sandbox-go:local: set the repository variable CHALK_CI_IMAGE' "$tmp/init5b.log"
check "the Actions workflow runs the setup and the rubric with bash -c, never sh -c" \
  ci_runs_rubric_with_bash .github/workflows/chalk.yml
check "the Actions rubric job passes a rubric that needs bash" \
  ci_rubric .github/workflows/chalk.yml "$PWD" 'set -o pipefail; [[ -n $BASH_VERSION ]]'
check "the Actions rubric job fails when the rubric fails" \
  ci_rubric_fails .github/workflows/chalk.yml "$PWD" 'exit 3'
sed -i.bak 's/^CHALK_TEST_CMD=.*/CHALK_TEST_CMD=test ! -e BROKEN/' .chalk/config && rm .chalk/config.bak
git add -A && git commit -q -m "init"
chalk new PROJ-20 Hub feature >/dev/null
cd "$tmp/hub.worktrees/PROJ-20"
git add -A && git commit -q -m "spec"
chalk run > "$tmp/run5.log" 2>&1 || { cat "$tmp/run5.log"; fail "GitHub run"; }
check "branch pushed to the GitHub origin" git -C "$tmp/hub-origin.git" rev-parse chalk/PROJ-20
check "pull request opened with gh" grep -q "pr create --head chalk/PROJ-20 --base main" "$FAKE_STATE/gh.log"
check "the pull request carries the execution summary" grep -q "Chalk execution summary" "$FAKE_STATE/gh.log"
check "glab is not used for a GitHub repository" sh -c "! grep -q PROJ-20 '$FAKE_STATE/glab.log'"
unset CHALK_FORGE
cd "$tmp/demo"

# 6. Guards and cleanup.
if chalk fleet PROJ-10 --plan /dev/null --yes >/dev/null 2>&1; then fail "empty plan must be rejected"; fi
pass "invalid plan rejected"
sleep 0.5
chalk cleanup >/dev/null 2>&1
check "cleanup removes worktrees" test ! -e "$tmp/demo.worktrees/PROJ-11"
check "cleanup keeps unpushed detention work" test -n "$(git for-each-ref refs/heads/detention)"
check "cleanup drops branches already pushed" test -z "$(git for-each-ref refs/heads/chalk/PROJ-1)"
chalk cleanup --all >/dev/null 2>&1
check "cleanup --all removes branches" test -z "$(git for-each-ref refs/heads/chalk refs/heads/detention refs/heads/tutoring)"

echo "all tests passed"
