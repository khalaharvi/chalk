#!/usr/bin/env bash
# End-to-end test of the Chalk workflow using fake docker, claude and glab.
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

# A repository with a remote and a rubric that rejects a file named BROKEN.
git init -q --bare "$tmp/origin.git"
git init -q -b main "$tmp/demo"
cd "$tmp/demo"
git remote add origin "$tmp/origin.git"
chalk init >/dev/null
sed -i.bak 's/^CHALK_TEST_CMD=.*/CHALK_TEST_CMD=test ! -e BROKEN/' .chalk/config && rm .chalk/config.bak
git add -A && git commit -q -m "init"

check "init scaffolds config, textbook, CI and CLAUDE.md" \
  test -f .chalk/textbook.md -a -f .gitlab/chalk.gitlab-ci.yml -a -f .gitlab-ci.yml -a -f CLAUDE.md

# 1. Happy path: two checkpoints, two loops, merge request opened.
chalk new PROJ-1 Demo feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-1"
git add -A && git commit -q -m "spec"
chalk run > "$tmp/run1.log" 2>&1 || { cat "$tmp/run1.log"; fail "happy path run"; }
check "all checkpoints ticked on host branch" test "$(grep -c -e '- \[x\]' specs/PROJ-1.md)" -eq 2
check "one commit per loop" test "$(git rev-list --count main..HEAD)" -eq 3
check "branch pushed to origin" git -C "$tmp/origin.git" rev-parse chalk/PROJ-1
check "merge request opened" grep -q "mr create.*chalk/PROJ-1" "$FAKE_STATE/glab.log"
check "sandbox removed" test ! -e "$FAKE_STATE/chalk-sandbox-demo-PROJ-1"
check "run telemetry recorded" grep -q "INSERT INTO runs" "$FAKE_STATE/db.log"
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
check "review summary lands in the merge request" grep -q "Agent review before submission: Looks complete" "$FAKE_STATE/glab.log"

# 2. Failure path: rubric keeps failing, work goes to detention, human fixes.
cd "$tmp/demo"
chalk new PROJ-2 Broken feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-2"
git add -A && git commit -q -m "spec"
if FAKE_CLAUDE_MODE="break" chalk run > "$tmp/run2.log" 2>&1; then fail "failing run should exit non-zero"; fi
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
check "note distilled into a general lesson" grep -q "lesson=Distilled: never commit" "$FAKE_STATE/db.log"
check "distillation sandbox removed" test ! -e "$FAKE_STATE/chalk-sandbox-demo-PROJ-2-distill"
check "tutoring merge request opened" grep -q "mr create.*tutoring/PROJ-2" "$FAKE_STATE/glab.log"

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

cd "$tmp/demo"
chalk prompts eject continue >/dev/null
check "ejected prompt is listed as overridden" sh -c "chalk prompts | grep -q 'continue *overridden'"
rm -rf .chalk/prompts

# 3c. Report card and OpenTelemetry export.
chalk dashboard --no-open --days 7 --output "$tmp/report.html" >/dev/null
check "dashboard page is built with its data embedded" \
  sh -c "grep -q 'Chalk report card' '$tmp/report.html' && grep -q '\"generated_at\"' '$tmp/report.html' && ! grep -q 'CHALK_DATA' '$tmp/report.html'"
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

# 4. Hindsight memory: lessons are stored at office hours and recalled into prompts.
export CHALK_MEMORY=hindsight
chalk new PROJ-3 Memory feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-3"
git add -A && git commit -q -m "spec"
if FAKE_CLAUDE_MODE="break" chalk run >/dev/null 2>&1; then fail "failing run should exit non-zero"; fi
git switch -q "$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/PROJ-3-*')"
git rm -q BROKEN && git commit -q -m "remove the blocker"
chalk office-hours -m "note" > "$tmp/run4.log" 2>&1 || { cat "$tmp/run4.log"; fail "office hours with memory"; }
check "lesson sent to Hindsight" grep -Eq '"document_id": *"chalk-lesson-[0-9]+"' "$FAKE_STATE/curl.log"
check "lesson marked as synced" grep -q "UPDATE lessons SET memory_synced_at" "$FAKE_STATE/db.log"
check "recalled lessons reach the agent prompt" \
  grep -q "Use the sandbox base URL in tests" "$XDG_STATE_HOME/chalk/demo/runs/PROJ-3/io/prompt.md"
unset CHALK_MEMORY
cd "$tmp/demo"

# 5. Guards and cleanup.
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
