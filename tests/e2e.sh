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
# No run is a holdout (certify.sh) unless a test says so: a certified stop
# acts every time, so a test of it cannot pass or fail by chance.
export CHALK_HOLDOUT=0
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

# calibrate URL MODEL CONFIDENCE RIGHT WRONG [MODE]: seeds the database
# (the schema PGOPTIONS names) with RIGHT + WRONG runs in which MODEL at URL
# said "stuck" at CONFIDENCE on loop 1, in MODE (shadow): the first RIGHT
# runs made no progress after it and were detained, the others progressed
# at loop 2 (false stops). Each call seeds runs of its own.
calibrate() {
  psql "$FAKE_PG_URL" -X -q -v ON_ERROR_STOP=1 -v url="$1" -v model="$2" -v confidence="$3" \
    -v right="$4" -v wrong="$5" -v mode="${6:-shadow}" <<'SQL'
SELECT 'cal-' || left(md5(clock_timestamp()::text || random()::text), 10) AS tag \gset
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons, run_id)
SELECT 'cal', 'CAL-' || i, 'chalk/CAL-' || i, v.n, CASE v.n WHEN 1 THEN 'continue' ELSE 'retry' END,
       'ok', CASE WHEN v.p THEN 0 ELSE 1 END, v.p, 'm', 'p', 0.10, 1, 1, 0, 0, 0, 0, 0, 0, 0,
       :'tag' || '-' || i
  FROM generate_series(1, :'right'::int + :'wrong'::int) i,
       LATERAL (VALUES (1, false), (2, i > :'right'::int)) v(n, p);
INSERT INTO lessons (repo, ticket, signature, run_id)
SELECT 'cal', 'CAL-' || i, 'seeded', :'tag' || '-' || i FROM generate_series(1, :'right'::int) i;
INSERT INTO decisions (call_id, run_id, kind, question, answer, confidence, threshold, mode,
                       latency_ms, model, url)
SELECT c.id, c.run_id, 'stuck', 'q', 'yes', :'confidence'::numeric, 0.9, :'mode', 100, :'model', :'url'
  FROM runs c WHERE c.run_id LIKE :'tag' || '-%' AND c.loop = 1;
SQL
}

# certified VERDICT...: the stopping verdicts named are certified for the
# fake agent's model (certify.sh): in the fake database's answer, and, with
# a real one (make test-db), by a block of shadow runs each judged right
# (detained with no progress after the verdict), in a repository of their own.
certified() {
  FAKE_CERTIFY="$(jq -cn --argjson block 46 '[$ARGS.positional[] | {verdict: ., model: "claude-fake-1",
    judged: $block, correct: $block, wrong: 0, waiting: 0, blocks: 1, block_wrong: 0, saved: 0, saved_max: 0}]' --args "$@")"
  export FAKE_CERTIFY
  [ -n "${FAKE_PG_URL:-}" ] || return 0
  psql "$FAKE_PG_URL" -X -q -v ON_ERROR_STOP=1 -v verdicts="$*" <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons, run_id, verdict, fp_rules)
SELECT 'cert', 'CERT-' || i, 'chalk/CERT-' || i, n, 'continue', 'ok', 1, false, 'claude-fake-1', 'p', 0.25, 1,
       1, 0, 0, 0, 0, 0, 0, 0, 'cert-' || v || '-' || i, CASE n WHEN 1 THEN v END, 'shadow'
  FROM unnest(string_to_array(:'verdicts', ' ')) v, generate_series(1, 46) i, generate_series(1, 2) n;
INSERT INTO lessons (repo, ticket, signature, run_id)
SELECT 'cert', 'CERT-' || i, 'seeded', 'cert-' || v || '-' || i
  FROM unnest(string_to_array(:'verdicts', ' ')) v, generate_series(1, 46) i;
SQL
}

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

# chalk doctor makes one HTTPS request from the sandbox image, as the agent
# would, so a proxy that re-signs HTTPS is found before the first run.
check "doctor: a sandbox that reaches the API over TLS is ok" \
  grep -q '^  ok    sandbox reaches api.anthropic.com over TLS$' "$tmp/doctor1.log"
if FAKE_TLS="tls: SELF_SIGNED_CERT_IN_CHAIN" chalk doctor > "$tmp/doctor6.log" 2>&1; then fail "doctor must fail on an untrusted certificate"; fi
check "doctor: an untrusted certificate in the sandbox fails and names CHALK_EXTRA_CA_CERTS" \
  grep -q '^  FAIL  sandbox reaches api.anthropic.com over TLS: SELF_SIGNED_CERT_IN_CHAIN; this network intercepts TLS .*set CHALK_EXTRA_CA_CERTS' "$tmp/doctor6.log"
if FAKE_TLS="network: ENOTFOUND" chalk doctor > "$tmp/doctor7.log" 2>&1; then fail "doctor must fail when the API cannot be reached"; fi
check "doctor: an API the sandbox cannot reach fails, saying what to check" \
  grep -q '^  FAIL  sandbox reaches api.anthropic.com: ENOTFOUND; check the network' "$tmp/doctor7.log"
printf -- '-----BEGIN CERTIFICATE-----\nshell\n-----END CERTIFICATE-----\n' > "$tmp/shell-ca.pem"
NODE_EXTRA_CA_CERTS="$tmp/shell-ca.pem" chalk doctor > "$tmp/doctor8.log" 2>&1 || true
check "doctor: a CA the shell trusts is suggested for CHALK_EXTRA_CA_CERTS" \
  grep -q "extra CA certificates: not set, but your shell sets NODE_EXTRA_CA_CERTS=$tmp/shell-ca.pem" "$tmp/doctor8.log"
CHALK_EXTRA_CA_CERTS="$tmp/shell-ca.pem" chalk doctor > /dev/null 2>&1 || true
check "doctor: the TLS probe mounts CHALK_EXTRA_CA_CERTS as a run does" \
  sh -c "grep -F ' node -e ' '$FAKE_STATE/docker.log' | grep -F -- '-v $tmp/shell-ca.pem:/chalk-ca.pem:ro' | grep -qF 'NODE_EXTRA_CA_CERTS=/chalk-ca.pem'"

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

# 2a'. CHALK_FP_RULES=on acts only once shadow runs certify a verdict
# (certify.sh). With no evidence yet, a repeating run goes as in shadow
# mode, and says why once per verdict.
cd "$tmp/demo"
junit='<testsuite><testcase classname="demo" name="no_marker"><failure message="BROKEN"/></testcase></testsuite>'
# A test of its own, so that its open detention matches no later run (deja_vu).
held='<testsuite><testcase classname="demo" name="held"><failure message="BROKEN"/></testcase></testsuite>'
chalk new PROJ-91 Held feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-91"
git add -A && git commit -q -m "spec"
db_lines="$(wc -l < "$FAKE_STATE/db.log")"
if FAKE_CLAUDE_MODE=break CHALK_FP_RULES=on CHALK_TEST_REPORT=out/report.xml \
   CHALK_TEST_CMD="if [ -e BROKEN ]; then mkdir -p out; echo '$held' > out/report.xml; echo 'AssertionError: BROKEN exists'; exit 1; fi" \
   chalk run > "$tmp/run91.log" 2>&1; then
  fail "a repeating run should still end in detention"
fi
tail -n +"$((db_lines + 1))" "$FAKE_STATE/db.log" > "$tmp/db91.log"
check "rules on, not certified: the same three loops, then the usual detention" \
  sh -c "grep -q 'loop 3 (retry)' '$tmp/run91.log' && grep -q 'DETENTION: rubric failed (exit 1)$' '$tmp/run91.log'"
check "rules on, not certified: the run says why, once" \
  test "$(grep -c '^warning: CHALK_FP_RULES=on records repeat in shadow mode only: repeat for claude-fake-1' "$tmp/run91.log")" -eq 1
check "rules on, not certified: every call records shadow" \
  test "$(grep -c 'INSERT INTO runs' "$tmp/db91.log")" = "$(grep -c -e '-v fp_rules=shadow ' "$tmp/db91.log")"
cd "$tmp/demo"
certified repeat deja_vu no_change

# 2b. With CHALK_FP_RULES=on, once certified, a loop that repeats the last
# one's failure on the same tree is detained at once. The rubric writes a
# JUnit report.
cd "$tmp/demo"
chalk new PROJ-9 Repeating feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-9"
git add -A && git commit -q -m "spec"
db_lines="$(wc -l < "$FAKE_STATE/db.log")"
if FAKE_CLAUDE_MODE=break CHALK_FP_RULES=on CHALK_HOLDOUT=0 CHALK_TEST_REPORT=out/report.xml \
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
check "rules on: only the call whose verdict detained the run records on" \
  sh -c "test \"\$(grep -c -e '-v fp_rules=on ' '$tmp/db12.log')\" -eq 1 &&
    grep -e '-v fp_rules=on ' '$tmp/db12.log' | grep -q -e '-v verdict=repeat$' &&
    test \"\$(grep -c 'INSERT INTO runs' '$tmp/db12.log')\" -eq \"\$((\$(grep -c -e '-v fp_rules=shadow ' '$tmp/db12.log') + 1))\""
check "rules on: no warning for a certified verdict" sh -c "! grep -q 'records repeat in shadow mode only' '$tmp/run12.log'"
cd "$tmp/demo"

# 2b''. A holdout run (CHALK_HOLDOUT) keeps certified verdicts in shadow
# mode, so that they go on being judged after they act.
chalk new PROJ-92 Holdout feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-92"
git add -A && git commit -q -m "spec"
db_lines="$(wc -l < "$FAKE_STATE/db.log")"
if FAKE_CLAUDE_MODE=break CHALK_FP_RULES=on CHALK_HOLDOUT=1 CHALK_TEST_REPORT=out/report.xml \
   CHALK_TEST_CMD="if [ -e BROKEN ]; then mkdir -p out; echo '${held/held/holdout}' > out/report.xml; echo 'AssertionError: BROKEN exists'; exit 1; fi" \
   chalk run > "$tmp/run92.log" 2>&1; then
  fail "a holdout run should still end in detention"
fi
tail -n +"$((db_lines + 1))" "$FAKE_STATE/db.log" > "$tmp/db92.log"
check "holdout: a certified verdict is recorded, not acted on, and the run says so once" \
  sh -c "grep -q 'loop 3 (retry)' '$tmp/run92.log' && grep -q 'DETENTION: rubric failed (exit 1)$' '$tmp/run92.log' &&
    test \"\$(grep -c 'this run is a holdout (CHALK_HOLDOUT=1)' '$tmp/run92.log')\" -eq 1"
check "holdout: every call records shadow" \
  test "$(grep -c 'INSERT INTO runs' "$tmp/db92.log")" = "$(grep -c -e '-v fp_rules=shadow ' "$tmp/db92.log")"
# chalk certify and doctor show the evidence, against the bar.
chalk certify > "$tmp/certify.log" 2>&1 || { cat "$tmp/certify.log"; fail "chalk certify"; }
check "chalk certify: each verdict, per agent model, against the bar" \
  sh -c "grep -q '^An early stop may act once its latest block of 46 judged shadow runs had at most 1 wrongful stop' '$tmp/certify.log' &&
    grep -Eq '^  repeat +claude-fake-1 +certified +[0-9]+ +0 ' '$tmp/certify.log'"
check "chalk certify --json: the rules it judged by" \
  test "$(chalk certify --json | jq -c .rules)" = '{"block":46,"max_wrong":1,"percent":90,"false_stop_usd":5,"decider_threshold":0.9}'
check "chalk certify: a price for a wrongful stop must be a number" \
  sh -c "! chalk certify --false-stop-usd lots > '$tmp/certify-usd.log' 2>&1 && grep -q 'takes a number of dollars' '$tmp/certify-usd.log'"
CHALK_FP_RULES=on chalk doctor > "$tmp/doctor-certify.log" 2>&1 || true
check "doctor under CHALK_FP_RULES=on: each certified verdict, by model" \
  grep -q '^  ok    verdict repeat for claude-fake-1 is certified' "$tmp/doctor-certify.log"
if [ -n "${FAKE_PG_URL:-}" ]; then
  # A verdict on a run's last loop saves nothing and cannot be wrong: the
  # run ended there anyway. 46 such runs judge nothing.
  psql "$FAKE_PG_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons, run_id, verdict, fp_rules)
SELECT 'cert', 'LAST-' || i, 'chalk/LAST-' || i, 1, 'continue', 'ok', 1, false, 'claude-last', 'p', 0.25, 1,
       1, 0, 0, 0, 0, 0, 0, 0, 'last-' || i, 'repeat', 'shadow'
  FROM generate_series(1, 46) i;
INSERT INTO lessons (repo, ticket, signature, run_id)
SELECT 'cert', 'LAST-' || i, 'seeded', 'last-' || i FROM generate_series(1, 46) i;
SQL
  check "chalk certify: a verdict on a run's last loop is not judged" \
    test "$(chalk certify --json | jq '[.verdicts[] | select(.model == "claude-last") | .judged] | add // 0')" -eq 0
fi
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
detain deja_vu FAKE_OPEN_MATCH=PROJ-9 FAKE_CLAUDE_MODE=break CHALK_FP_RULES=on CHALK_HOLDOUT=0 CHALK_TEST_REPORT=out/report.xml \
  CHALK_TEST_CMD="if [ -e BROKEN ]; then mkdir -p out; echo '$junit' > out/report.xml; echo 'AssertionError: BROKEN exists'; exit 1; fi"
check "next step on deja_vu: fix the matching open detention first" \
  detained deja_vu "deja_vu: " "this fails like the open detention of PROJ-9; fix that one first"
detain no_change FAKE_CLAUDE_MODE=break CHALK_FP_RULES=on CHALK_HOLDOUT=0
check "next step on no_change: make the checkpoint clearer or do it yourself" \
  detained no_change "no_change: " "the agent changed nothing"
unset FAKE_CERTIFY
detain agent_error FAKE_CLAUDE_MODE=error CHALK_MAX_RETRIES=0
check "next step when the agent ran out of turns: make the checkpoint smaller" \
  detained agent_error "agent stopped early (max_turns: error_max_turns)" "the agent ran out of turns: make the checkpoint smaller"
# Refused credentials fail the same way every time: no retries.
detain auth FAKE_API_ERROR=401 CHALK_SPEC_CHECK=false
check "a refused key detains after one loop, naming the CLI's message" \
  sh -c "grep -qF 'DETENTION: agent stopped early (auth: Invalid API key · Fix external API key (HTTP 401))' '$tmp/detain-auth.log' &&
    test \"\$(grep -c 'loop [0-9]* (.*) started' '$tmp/detain-auth.log')\" -eq 1"
check "next step for a refused key: check the credentials" \
  next_step "$tmp/detain-auth.log" "the agent's credentials were refused: check ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"
detain agent_timeout FAKE_AGENT_TIMEOUT=1 CHALK_SPEC_CHECK=false CHALK_MAX_RETRIES=0
check "an agent call that takes too long is stopped, naming CHALK_AGENT_TIMEOUT" \
  detained agent_timeout "agent stopped early (timeout: no answer within 1800s" "the agent gave no answer within CHALK_AGENT_TIMEOUT"
detain rubric_timeout CHALK_TEST_CMD="exit 124" CHALK_MAX_RETRIES=0
check "a rubric that timed out says so, naming CHALK_RUBRIC_TIMEOUT" \
  grep -q "DETENTION: rubric timed out after 900s (CHALK_RUBRIC_TIMEOUT)" "$tmp/detain-rubric_timeout.log"
detain passed FAKE_CLAUDE_MODE=idle CHALK_MAX_RETRIES=0
check "next step when nothing was ticked: tick it or make it testable" \
  detained passed "rubric passed but no checkpoint was ticked" "the rubric passes but no checkpoint was ticked"
detain refused FAKE_CLAUDE_MODE=refused CHALK_MAX_RETRIES=0
check "next step after many permission refusals: check auto mode with chalk doctor" \
  detained refused "rubric passed but no checkpoint was ticked" \
    "4 actions were refused in the last loop, as when auto mode is unavailable for the model; run: chalk doctor"
# A blocker about the environment comes with a fix and a probe
# (evidence.sh): the probe runs at detention, as proof. The fake sandbox
# shows its image as FAKE_CONTAINER_IMAGE, so the probe below passes only
# on an image named repo-image.
needs_probe='test "$FAKE_CONTAINER_IMAGE" = repo-image'
image_fix="$(jq -cn --arg p "$needs_probe" '{kind: "image", why: "gcc not found", probe: $p, image: "apt-get install -y gcc"}')"
detain fix_fails FAKE_CLAUDE_MODE=blocked FAKE_BLOCKER="cgo: C compiler gcc not found" FAKE_BLOCKER_FIX="$image_fix"
check "a blocker's fix is shown, and its failing probe proves the blocker real" \
  sh -c "grep -q '\] the agent proposes a fix:' '$tmp/detain-fix_fails.log' && grep -q '\]   kind: image' '$tmp/detain-fix_fails.log' &&
    grep -q '\]   image needs: apt-get install -y gcc' '$tmp/detain-fix_fails.log' &&
    grep -q '\] proof: the probe fails (exit 1), so the blocker is real' '$tmp/detain-fix_fails.log'"
check "next step for an image fix on the default image: build a repository image on it" \
  detained fix_fails "agent reported a blocker" "build a repository image FROM chalk-sandbox:local that adds: apt-get install -y gcc"
detain fix_passes FAKE_CLAUDE_MODE=blocked FAKE_BLOCKER_FIX='{"kind":"config","why":"w","probe":"true","config":{"CHALK_SETUP_CMD":"make deps"}}'
check "a probe that passes says the blocker may not be real" \
  grep -q 'the probe passes, so this blocker may not be real' "$tmp/detain-fix_passes.log"
check "next step for a config fix: the settings to commit" \
  detained fix_passes "agent reported a blocker" "set in .chalk/config and commit: CHALK_SETUP_CMD=make deps"
detain fix_hangs FAKE_CLAUDE_MODE=blocked FAKE_PROBE_TIMEOUT=sleep FAKE_BLOCKER_FIX='{"kind":"image","why":"w","probe":"sleep 99"}'
check "a probe that times out is inconclusive" grep -q 'the probe was inconclusive (timed out after 30s' "$tmp/detain-fix_hangs.log"
detain fix_bad FAKE_CLAUDE_MODE=blocked FAKE_BLOCKER_FIX='{"kind":"image","why":"no probe"}'
check "a fix that breaks the rules is dropped, saying why, and the detention is as before" \
  sh -c "grep -q 'the agent.s proposed fix was not kept: an image fix needs a probe' '$tmp/detain-fix_bad.log' &&
    grep -q 'next: provide what the agent asked for above' '$tmp/detain-fix_bad.log'"
check "the lesson records the fix and the probe's outcome at detention" \
  grep -q -e '-v evidence={"fix":{"kind":"image","why":"gcc not found".*"outcome":"failed","exit":"1"' "$FAKE_STATE/db.log"

# Last, as its first loop's progress lands on the working branch.
detain loop_limit CHALK_MAX_LOOPS=1
check "next step at the loop limit: split the checkpoints or raise the limit" \
  detained loop_limit "loop limit of 1 reached" \
    "split the open checkpoints into smaller ones, or raise CHALK_MAX_LOOPS (now 1)"
cd "$tmp/demo"

# 2c. Office hours checks a probe-carrying fix in a fresh sandbox before it
# keeps the lesson: still failing, it stops and records nothing; passing,
# after failing at detention, the lesson is proved and its probe is saved
# as a need, committed on the branch, which the resumed run checks before
# its first loop. The fake database is told what the lesson carries; a
# real one (make test-db) holds what the detention recorded.
chalk new PROJ-93 Needs gcc >/dev/null
cd "$tmp/demo.worktrees/PROJ-93"
git add -A && git commit -q -m "spec"
if FAKE_CLAUDE_MODE=blocked FAKE_BLOCKER_FIX="$image_fix" chalk run > "$tmp/run93.log" 2>&1; then
  fail "a blocked run must end in detention"
fi
detention93="$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/PROJ-93-*')"
git switch -q "$detention93"
FAKE_PENDING_EVIDENCE="$(jq -cn --argjson fix "$image_fix" --arg p "$needs_probe" \
  '{id: 93, fix: $fix, fix_kind: "image", probe: $p, before_outcome: "failed"}')"
export FAKE_PENDING_EVIDENCE
db_lines="$(wc -l < "$FAKE_STATE/db.log")"
if chalk office-hours -m "the image lacks gcc" > "$tmp/oh93a.log" 2>&1; then
  fail "office hours must stop while the probe still fails"
fi
check "office hours: a probe that still fails stops it, recording nothing, with what to do" \
  sh -c "grep -q 'the probe still fails after your fix (exit 1)' '$tmp/oh93a.log' &&
    grep -q 'or add --unproved to resume anyway' '$tmp/oh93a.log' &&
    ! tail -n +$((db_lines + 1)) '$FAKE_STATE/db.log' | grep -q 'SET resolution' &&
    test \"\$(git rev-parse --abbrev-ref HEAD)\" = '$detention93'"
# The fix: a repository image, set in the repository's config.
sed -i.bak 's/^CHALK_IMAGE=.*/CHALK_IMAGE=repo-image/' .chalk/config && rm .chalk/config.bak
git commit -q -am "use the repository image, which has gcc"
db_lines="$(wc -l < "$FAKE_STATE/db.log")"
chalk office-hours -m "the default image has no gcc; added a repository image" > "$tmp/oh93b.log" 2>&1 ||
  { cat "$tmp/oh93b.log"; fail "office hours after the fix"; }
tail -n +"$((db_lines + 1))" "$FAKE_STATE/db.log" > "$tmp/db93.log"
check "office hours: the probe passes in a fresh sandbox, after failing at detention: proved" \
  sh -c "grep -q 'the probe passes now, and failed at detention: the fix is proved' '$tmp/oh93b.log' &&
    grep -Eq -e '-v id=[0-9]+ -v after=passed .*-v evidence=proved' '$tmp/db93.log'"
check "office hours: the proved probe is saved as a need and committed" \
  sh -c "git log --format=%s | grep -qx 'chalk: save the need PROJ-93 proved' &&
    grep -Eqx -e '$(printf '%s' "$needs_probe" | sed 's/[]$.*[\^]/\\&/g')  # image PROJ-93 lesson=[0-9]+' .chalk/needs &&
    test -z \"\$(git status --porcelain)\""
check "office hours: distillation is given the proposed fix and what the probe showed" \
  sh -c "sed -n '/^<proposed_fix>$/,/^<\/proposed_fix>$/p' '$XDG_STATE_HOME/chalk/demo/runs/PROJ-93/distill/distill.prompt.md' |
    grep -q 'probe at detention: failed; after your fix: passed'"
check "the resumed run checks the saved need before its first loop" grep -q 'pre-flight: 1 saved need(s) hold' "$tmp/oh93b.log"
unset FAKE_PENDING_EVIDENCE
cd "$tmp/demo"

# 2c'. A saved need that fails detains the run in pre-flight, before any
# loop; chalk needs checks every need with and without its fix, retires
# one the environment no longer needs, and fails when one fails.
chalk new PROJ-94 Pre-flight >/dev/null
cd "$tmp/demo.worktrees/PROJ-94"
mkdir -p .chalk
printf '# Needs of earlier tickets.\n%s  # image PROJ-93 lesson=93\ntrue  # config PROJ-1 lesson=\n' "$needs_probe" > .chalk/needs
git add -A && git commit -q -m "spec, and the needs of earlier tickets"
if chalk run > "$tmp/run94.log" 2>&1; then fail "a run whose saved need fails must be detained"; fi
check "pre-flight: a saved need that fails detains the run before any loop" \
  sh -c "grep -qF 'DETENTION: pre-flight: a saved need fails: $needs_probe' '$tmp/run94.log' && ! grep -q 'loop 1' '$tmp/run94.log'"
check "next step in pre-flight: restore what the earlier ticket needed" \
  next_step "$tmp/run94.log" "the environment lacks what an earlier ticket needed (.$needs_probe., saved by PROJ-93)"
if chalk needs > "$tmp/needs1.log" 2>&1; then fail "chalk needs must fail while a need fails"; fi
check "chalk needs: a need that fails, and one the environment no longer needs" \
  sh -c "grep -qF 'FAILS (exit 1)  $needs_probe  (image, from PROJ-93)' '$tmp/needs1.log' &&
    grep -qF 'retired: passes without the fix too  true  (config, from PROJ-1)' '$tmp/needs1.log'"
CHALK_IMAGE=repo-image chalk needs > "$tmp/needs2.log" 2>&1 || { cat "$tmp/needs2.log"; fail "chalk needs with the fix"; }
check "chalk needs: on the repository image the need holds, since the default image still lacks it" \
  grep -qF "holds  $needs_probe  (image, from PROJ-93)" "$tmp/needs2.log"
CHALK_IMAGE=repo-image chalk needs --prune > "$tmp/needs3.log" 2>&1 || { cat "$tmp/needs3.log"; fail "chalk needs --prune"; }
check "chalk needs --prune: drops the retired need, keeps the others and the comments" \
  test "$(cat .chalk/needs)" = "$(printf '# Needs of earlier tickets.\n%s  # image PROJ-93 lesson=93' "$needs_probe")"
git checkout -q -- .chalk/needs
# Office hours with --unproved resumes past a need that still fails: the
# resumed run's pre-flight skips it, rather than detaining the run again.
git switch -q "$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/PROJ-94-*')"
FAKE_PENDING_EVIDENCE="$(jq -cn --arg p "$needs_probe" '{id: 94, fix_kind: "image", probe: $p, before_outcome: "failed"}')" \
  chalk office-hours --unproved -m "no gcc yet; going on without it" > "$tmp/oh94.log" 2>&1 || true
check "office hours --unproved: the resumed run's pre-flight skips the need that still fails" \
  sh -c "grep -qF 'pre-flight: skipping the saved need' '$tmp/oh94.log' && ! grep -q 'DETENTION: pre-flight' '$tmp/oh94.log' &&
    grep -q 'loop 1' '$tmp/oh94.log'"
cd "$tmp/demo"

# 2c''. Tuning experiments (tune.sh). An exploring run gets more loops,
# once, where it would be detained, and records them as explored; a run in
# arm b of a prompt A/B test reads .chalk/prompts-b/; chalk tune reads the
# runs and recommends, and --apply writes a stop-only change to the config.
chalk new PROJ-96 Explore feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-96"
mkdir -p .chalk/prompts-b
printf 'PROMPT-B-MARKER\n' > .chalk/prompts-b/continue.md
printf 'PROMPT-B-MARKER\n' > .chalk/prompts-b/retry.md
git add -A && git commit -q -m "spec, and prompts b"
db_lines="$(wc -l < "$FAKE_STATE/db.log")"
if FAKE_CLAUDE_MODE=break CHALK_MAX_RETRIES=0 CHALK_EXPLORE=true CHALK_EXPLORE_SHARE=1 CHALK_PROMPT_AB=b \
   chalk run > "$tmp/run96.log" 2>&1; then
  fail "an exploring run that keeps failing must still end in detention"
fi
tail -n +"$((db_lines + 1))" "$FAKE_STATE/db.log" > "$tmp/db96.log"
check "explore: the run says it may explore, then runs two more loops past CHALK_MAX_RETRIES=0" \
  sh -c "grep -q 'exploring (CHALK_EXPLORE): if it would be detained for failing, this run gets up to 2 more loop' '$tmp/run96.log' &&
    grep -q 'exploring: one more loop past CHALK_MAX_RETRIES=0 (1 left)' '$tmp/run96.log' &&
    grep -q 'loop 3 (retry) started' '$tmp/run96.log' && ! grep -q 'loop 4' '$tmp/run96.log' &&
    grep -q 'DETENTION: rubric failed' '$tmp/run96.log'"
check "explore: the extra loops are recorded as explored, every call as in the exploring arm" \
  sh -c "test \"\$(grep -c -e '-v explored=1 ' '$tmp/db96.log')\" -eq 2 &&
    test \"\$(grep -c 'INSERT INTO runs' '$tmp/db96.log')\" = \"\$(grep -c -e '-v arm_explore=true ' '$tmp/db96.log')\""
check "A/B: arm b reads .chalk/prompts-b and says so; pinned to it, not drawn, it records no arm" \
  sh -c "grep -q 'this run uses prompts b, from .chalk/prompts-b/' '$tmp/run96.log' &&
    grep -q PROMPT-B-MARKER '$XDG_STATE_HOME/chalk/demo/runs/PROJ-96/io/prompt.md' &&
    test \"\$(grep -c 'INSERT INTO runs' '$tmp/db96.log')\" = \"\$(grep -c -e '-v arm_prompts= ' '$tmp/db96.log')\""
# The run above explored two loops at $0.25 each: a ceiling of $0.50 is
# spent, in the fake database's answer and in a real one alike.
check "explore: no exploring once the 30-day ceiling is spent" \
  sh -c "! FAKE_CLAUDE_MODE=break CHALK_MAX_RETRIES=0 CHALK_EXPLORE=true CHALK_EXPLORE_SHARE=1 FAKE_EXPLORE_SPENT=0.50 \
      CHALK_EXPLORE_BUDGET_USD=0.50 chalk run > '$tmp/run96b.log' 2>&1 &&
    grep -q 'would pass its ceiling (CHALK_EXPLORE_BUDGET_USD=0.50)' '$tmp/run96b.log' && ! grep -q 'loop 2' '$tmp/run96b.log'"
chalk tune > "$tmp/tune1.log" 2>&1 || { cat "$tmp/tune1.log"; fail "chalk tune"; }
check "chalk tune: the three kinds of change, each with what it would take" \
  sh -c "grep -q '^Fewer retries (stop-only' '$tmp/tune1.log' && grep -q '^More retries (spend-extending' '$tmp/tune1.log' &&
    grep -q '^Prompts a against b (randomized' '$tmp/tune1.log'"
if [ -z "${FAKE_PG_URL:-}" ]; then
  # 46 runs that failed three loops in a row and were detained.
  FAKE_TUNE_DATA="$(jq -cn '[range(46) | {run_id: "t-\(.)", arm_prompts: null, explore: false, detained: true,
      success: false, cost: 3, loops: [range(3) | {kind: "retry", progressed: false, cost_usd: 1, explored: false}]}]')"
  export FAKE_TUNE_DATA
  # A config whose last line has no newline: the setting goes on a line of
  # its own.
  printf '%s' "$(grep -v '^CHALK_MAX_RETRIES=' .chalk/config)" > .chalk/config.new
  mv .chalk/config.new .chalk/config
  chalk tune --apply > "$tmp/tune2.log" 2>&1 || { cat "$tmp/tune2.log"; fail "chalk tune --apply"; }
  check "chalk tune: fewer retries recommended from runs that never recovered, and applied" \
    sh -c "grep -q 'recommend CHALK_MAX_RETRIES=0' '$tmp/tune2.log' && grep -qx 'CHALK_MAX_RETRIES=0' .chalk/config &&
      test \"\$(grep -c '' .chalk/config)\" -ge 2 &&
      grep -q 'applied: CHALK_MAX_RETRIES=0 in .chalk/config; commit it' '$tmp/tune2.log'"
  git checkout -q -- .chalk/config
  unset FAKE_TUNE_DATA
fi
cd "$tmp/demo"

# 2d. With CHALK_ATTEST=true a finished branch carries a signed evidence
# record, committed under .chalk/evidence, which chalk attest verify checks
# against the branch, re-running the rubric with --rerun; a commit after it
# makes it fail. CI trusts the key through the line chalk attest key prints.
chalk new PROJ-95 Attested feature >/dev/null
cd "$tmp/demo.worktrees/PROJ-95"
git add -A && git commit -q -m "spec"
CHALK_ATTEST=true chalk run > "$tmp/run95.log" 2>&1 || { cat "$tmp/run95.log"; fail "an attested run"; }
check "attest: the record is committed on the branch, and the request names it" \
  sh -c "grep -q 'evidence record committed: .chalk/evidence/PROJ-95.json' '$tmp/run95.log' &&
    test \"\$(git log -1 --format=%s)\" = 'chalk: evidence for PROJ-95' &&
    grep -q 'Evidence: .\.chalk/evidence/PROJ-95\.json., signed by the harness' '$FAKE_STATE/glab.log'"
check "attest: the record is an in-toto statement about this branch's tree, from the harness's ledger" \
  test "$(jq -r .payload .chalk/evidence/PROJ-95.json | openssl base64 -d -A |
          jq -r '"\(.subject[0].name) \(.predicate.rubric.command) \(.predicate.ledger.loops | length > 0)"')" = \
    "chalk/PROJ-95 test ! -e BROKEN true"
chalk attest key > "$tmp/attest-key.log" 2>&1 || { cat "$tmp/attest-key.log"; fail "chalk attest key"; }
tail -n 1 "$tmp/attest-key.log" > "$tmp/allowed_signers"
CHALK_ATTEST_SIGNERS="$tmp/allowed_signers" chalk attest verify --rerun PROJ-95 > "$tmp/verify95.log" 2>&1 ||
  { cat "$tmp/verify95.log"; fail "chalk attest verify"; }
check "attest verify: signature, subject, tests, cost, and a fresh rubric run all hold" \
  test "$(grep -c '^  [a-z]*: ok: ' "$tmp/verify95.log")" -eq 6
echo late > late.txt && git add late.txt && git commit -q -m "a change after the record"
if CHALK_ATTEST_SIGNERS="$tmp/allowed_signers" chalk attest verify PROJ-95 > "$tmp/verify95b.log" 2>&1; then
  fail "a record must not verify after the branch changed"
fi
check "attest verify: a commit after the record fails it, saying so" \
  grep -q '  subject: FAIL: .*the branch changed after it was recorded' "$tmp/verify95b.log"
if chalk attest verify PROJ-95 > "$tmp/verify95c.log" 2>&1; then fail "a record must not verify without trusted signers"; fi
check "attest verify: with no trusted signers, it says how to add one" \
  grep -q "signature: FAIL: no trusted signers: commit 'chalk attest key' output to .chalk/allowed_signers on the base branch" "$tmp/verify95c.log"
cd "$tmp/demo"

# 2b'''. An agent call that cannot run is reported with the CLI's own words.
# A refused key stops the run at the spec check, before any loop.
chalk new PROJ-75 Refused key >/dev/null
cd "$tmp/demo.worktrees/PROJ-75"
git add -A && git commit -q -m "spec"
if FAKE_API_ERROR=401 chalk run > "$tmp/run75.log" 2>&1; then fail "a run with a refused key must fail"; fi
check "a refused key stops the run at the spec check, with what to do" \
  sh -c "grep -qF 'the spec check could not run (auth: Invalid API key · Fix external API key (HTTP 401)); the agent' '$tmp/run75.log' &&
    grep -q 'then run chalk run again$' '$tmp/run75.log' &&
    ! grep -q 'loop 1' '$tmp/run75.log' && ! grep -q 'unexpected failure' '$tmp/run75.log'"
check "the failure is recorded with the call" grep -q -e "-v failure=auth: Invalid API key" "$FAKE_STATE/db.log"
cd "$tmp/demo"

# A final review that cannot run detains, unless CHALK_REVIEW_REQUIRED=false.
chalk new PROJ-76 Review did not run >/dev/null
cd "$tmp/demo.worktrees/PROJ-76"
git add -A && git commit -q -m "spec"
if FAKE_REVIEW=error chalk run > "$tmp/run76.log" 2>&1; then fail "a review that cannot run must detain"; fi
check "a review that cannot run detains instead of opening the request" \
  sh -c "grep -qF 'DETENTION: the final review did not run (budget: error_max_budget_usd)' '$tmp/run76.log' && ! grep -q 'chalk/PROJ-76' '$FAKE_STATE/glab.log'"
check "next step for a review that cannot run names CHALK_REVIEW_REQUIRED" \
  next_step "$tmp/run76.log" "the final review could not run: the call reached its spend cap.*CHALK_REVIEW_REQUIRED=false"
cd "$tmp/demo"
chalk new PROJ-78 Review not required >/dev/null
cd "$tmp/demo.worktrees/PROJ-78"
git add -A && git commit -q -m "spec"
FAKE_REVIEW=error CHALK_REVIEW_REQUIRED=false chalk run > "$tmp/run78.log" 2>&1 || { cat "$tmp/run78.log"; fail "a run whose review is not required"; }
check "with CHALK_REVIEW_REQUIRED=false, the request says the review did not run" \
  grep -qF "Agent review before submission: did not run (budget: error_max_budget_usd)" "$FAKE_STATE/glab.log"
cd "$tmp/demo"

# 2b''. No way a run can end loses the sandbox's work or shows a stack trace.
# no_trace LOG: the run said how it ended, without an unexpected failure.
no_trace() { ! grep -q 'unexpected failure' "$1"; }

# A database that goes away mid-run is reported once; the run still graduates.
chalk new PROJ-70 Database gone >/dev/null
cd "$tmp/demo.worktrees/PROJ-70"
git add -A && git commit -q -m "spec"
FAKE_DB_FAIL_ON="INSERT INTO" chalk run > "$tmp/run70.log" 2>&1 || { cat "$tmp/run70.log"; fail "a run whose database goes away"; }
check "a run whose database goes away still opens its merge request" grep -q "mr create.*chalk/PROJ-70" "$FAKE_STATE/glab.log"
check "a database that goes away is reported once, and not as a crash" \
  sh -c "test \"\$(grep -c 'telemetry database could not be written' '$tmp/run70.log')\" -eq 1 && ! grep -q 'unexpected failure' '$tmp/run70.log'"
cd "$tmp/demo"

# A database that goes away before a detention: the work is still parked.
chalk new PROJ-71 Database gone, detained >/dev/null
cd "$tmp/demo.worktrees/PROJ-71"
git add -A && git commit -q -m "spec"
if FAKE_DB_FAIL_ON="INSERT INTO" FAKE_CLAUDE_MODE=break CHALK_MAX_RETRIES=0 chalk run > "$tmp/run71.log" 2>&1; then
  fail "a failing run without a database should exit non-zero"
fi
detention="$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/PROJ-71-*')"
check "without a database, a detention still parks the work" git cat-file -e "$detention:BROKEN"
check "without a database, a detention still says what to do next" \
  sh -c "grep -q 'next: ' '$tmp/run71.log' && grep -q 'work parked on local branch' '$tmp/run71.log'"
check "without a database, a detention is not reported as a crash" no_trace "$tmp/run71.log"
cd "$tmp/demo"

# The branch moves on the host during a run: the loop's commit is parked
# on a detention branch, with a next step, instead of a crash.
chalk new PROJ-72 Branch moved >/dev/null
cd "$tmp/demo.worktrees/PROJ-72"
git add -A && git commit -q -m "spec"
if FAKE_HOST_COMMIT="$PWD" chalk run > "$tmp/run72.log" 2>&1; then fail "a run whose branch moved should exit non-zero"; fi
detention="$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/PROJ-72-*')"
check "a branch that moved during the run parks the loop's commit" \
  sh -c "test -n '$detention' && git log --format=%s '$detention' | grep -q 'chalk(PROJ-72): continue, loop 1'"
check "a branch that moved during the run says what to do next" \
  next_step "$tmp/run72.log" "chalk/PROJ-72 changed in .* during the run"
check "a branch that moved during the run is not reported as a crash" no_trace "$tmp/run72.log"
cd "$tmp/demo"

# The sandbox disappears mid-run: the run says the work is lost, plainly.
chalk new PROJ-73 Sandbox gone >/dev/null
cd "$tmp/demo.worktrees/PROJ-73"
git add -A && git commit -q -m "spec"
if FAKE_CLAUDE_MODE=vanish CHALK_MAX_RETRIES=0 chalk run > "$tmp/run73.log" 2>&1; then fail "a run whose sandbox vanished should exit non-zero"; fi
check "a vanished sandbox is reported as gone, with what the branch still holds" \
  grep -q "the sandbox is gone, so work since the last checkpoint is lost; chalk/PROJ-73 holds every checkpoint" "$tmp/run73.log"
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
                     AND table_name IN ('runs', 'lessons') AND column_name IN ('run_id', 'tests_hash', 'failing', 'first_error', 'tree_id',
                                         'verdict', 'fingerprint', 'fp_rules')"):$(pg -c 'SELECT count(*) FROM runs WHERE verdict IS NULL AND fp_rules IS NULL')" = 10:1
  check "schema: lessons are indexed by fingerprint" \
    test "$(pg -c "SELECT count(*) FROM pg_indexes WHERE schemaname = 'chalk_e2e' AND indexname = 'lessons_fingerprint_idx'")" = 1
  check "schema: the decider's answers have a table, linked to the loop's call" \
    test "$(pg -c "SELECT confrelid::regclass FROM pg_constraint WHERE conrelid = 'chalk_e2e.decisions'::regclass AND contype = 'f'")" = runs
  embedding="$(pg -c "SELECT format_type(atttypid, atttypmod) FROM pg_attribute
                       WHERE attrelid = 'chalk_e2e.lessons'::regclass AND attname = 'embedding'")"
  if [ "$(pg -c "SELECT count(*) FROM pg_extension WHERE extname = 'vector'")" = 1 ]; then
    check "schema: with pgvector, lessons get a 384-dimension embedding" test "$embedding" = "vector(384)"
    check "schema: ... with an HNSW index for cosine distance" \
      pg -c "SELECT 1/count(*) FROM pg_indexes WHERE schemaname = 'chalk_e2e' AND indexname = 'lessons_embedding_hnsw'
               AND indexdef LIKE '%USING hnsw (embedding vector_cosine_ops)%'"
  else
    check "schema: without pgvector (Postgres 16), lessons have no embedding" test -z "$embedding"
  fi
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
  pg -c 'TRUNCATE runs, lessons, decisions'
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

  # The decider, in shadow mode, ten cents a loop:
  #   D-1 detained:  "stuck" at 0.95 on loop 2, nothing progressed after: right,
  #                  and stopping there would have saved loop 3
  #   D-2 submitted: "stuck" at 0.92 on loop 1, then loop 2 progressed: wrong,
  #                  a false stop
  #   D-3 submitted: "not stuck" at 0.80 on loop 1, then progress: right
  # plus a question on D-3 that got no answer (timeout), and one rerank.
  pg -c 'TRUNCATE runs, lessons, decisions'
  pg <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons, run_id, verdict)
SELECT 'dec', t, 'chalk/' || t, n, CASE n WHEN 1 THEN 'continue' ELSE 'retry' END, 'ok',
       CASE WHEN p THEN 0 ELSE 1 END, p, 'm', 'p', 0.10, 1, 1, 0, 0, 0, 0, 0, 0, 0, t || '-1', v
  FROM (VALUES ('D-1', 1, false, 'first'), ('D-1', 2, false, 'spinning'), ('D-1', 3, false, 'spinning'),
               ('D-2', 1, false, 'other'), ('D-2', 2, true, NULL),
               ('D-3', 1, false, 'spinning'), ('D-3', 2, true, NULL)) v(t, n, p, v);
INSERT INTO lessons (repo, ticket, signature, run_id) VALUES ('dec', 'D-1', 's', 'D-1-1');
INSERT INTO decisions (call_id, run_id, kind, question, answer, confidence, threshold, mode,
                       latency_ms, acted, model, error)
SELECT (SELECT id FROM runs WHERE run_id = v.r AND loop = v.n), v.r, v.kind, 'q', v.a, v.c, 0.9,
       'shadow', v.ms, false, 'fake-decider@0123456', v.e
  FROM (VALUES ('D-1-1', 2, 'stuck', 'yes', 0.95, 100, NULL), ('D-2-1', 1, 'stuck', 'yes', 0.92, 200, NULL),
               ('D-3-1', 1, 'stuck', 'no', 0.80, 300, NULL), ('D-3-1', 1, 'stuck', NULL, NULL, 2000, 'timeout'),
               ('D-1-1', 3, 'rerank', 'yes', 0.97, 120, NULL)) v(r, n, kind, a, c, ms, e);
SQL
  pg -v days=30 -f "$here/../share/dashboard.sql" | jq -c . > "$tmp/decider.json"
  dec() { jq -r "def c: . * 100 | round; .decider | $1" "$tmp/decider.json"; }
  check "decider: questions asked, answered, and the median time of an answer" \
    test "$(dec '[.questions, .answered, .median_ms] | join(" ")')" = "5 4 160"
  check "decider: questions by kind, and calls with no answer by why" \
    test "$(dec '[(.by_kind[] | "\(.kind)=\(.questions)/\(.answered)"), (.errors[] | "\(.error)=\(.calls)")] | join(" ")')" \
      = "rerank=1/1 stuck=4/3 timeout=1"
  check "decider: confident answers are checked against what the run did next" \
    test "$(dec '[.calibration[] | "\(.low):\(.answers)/\(.agreed)"] | join(" ")')" = "0.7:1/1 0.9:2/1"
  check "decider: what stopping at a confident stuck would have saved, and its false stops" \
    test "$(dec '[.would_stop, (.would_save | c), .false_stops] | join(" ")')" = "2 10 1"
  check "decider: the model and revision that answered" test "$(dec '.models | join(" ")')" = "fake-decider@0123456"
  check "ledger: each run says where the decider would have stopped it" \
    test "$(jq -r '[.ledger.runs[] | "\(.run_id):\(.decider_loop)"] | sort | join(" ")' "$tmp/decider.json")" \
      = "D-1-1:2 D-2-1:1"

  # The calibration gate, per provider (URL and model revision), as the
  # report card shows it and runs judge it (CHALK_DECIDER_THRESHOLD=0.9):
  #   a.test m@1111111  46 runs right at 0.95, each also "stuck" at loop 2,
  #                     which a run under on never reaches: calibrated
  #   a.test m@2222222  a new revision: 2 right in shadow, 50 under on that
  #                     prove nothing: not yet
  #   b.test m@1111111  the same model elsewhere: 43 right of 46: not yet
  #   c.test c-model    right at 0.75, wrong at 0.6: nothing at 0.9, and
  #                     0.75 suggested
  #   d.test d-model    3 runs not settled: no progress, no detention yet
  # plus D-1 and D-2 above (fake-decider@0123456, recorded before url was:
  # the schema names the local service), one right and one wrong.
  export PGOPTIONS='-c search_path=chalk_e2e,public -c client_min_messages=warning'
  calibrate http://a.test m@1111111 0.95 46 0
  pg -c "INSERT INTO decisions (call_id, run_id, kind, question, answer, confidence, threshold, mode, model, url)
         SELECT c.id, c.run_id, 'stuck', 'q', 'yes', 0.99, 0.9, 'shadow', d.model, d.url
           FROM decisions d JOIN runs c ON c.run_id = d.run_id AND c.loop = 2 WHERE d.url = 'http://a.test'"
  calibrate http://a.test m@2222222 0.95 2 0
  calibrate http://a.test m@2222222 0.95 50 0 on
  calibrate http://b.test m@1111111 0.95 43 3
  calibrate http://c.test c-model 0.75 46 0
  calibrate http://c.test c-model 0.6 0 5
  calibrate http://d.test d-model 0.95 3 0
  pg -c "DELETE FROM lessons WHERE run_id IN (SELECT run_id FROM decisions WHERE url = 'http://d.test')"
  chalk dashboard --no-open --days 30 --output "$tmp/gate.html" >/dev/null
  export PGOPTIONS="${e2e_pgoptions:-}"
  sed -n '/^const DATA =$/{n;p;}' "$tmp/gate.html" > "$tmp/gate.json"
  check "the schema names the local service as the URL of answers recorded before url was" \
    test "$(pg -c "SELECT DISTINCT url FROM decisions WHERE model = 'fake-decider@0123456'")" = http://127.0.0.1:8471
  check "calibration gate: each provider judged at the threshold, with the lowest threshold that would pass" \
    test "$(jq -r '[.decider.gate[] | "\(.url) \(.model) \(.judged)/\(.correct)/\(.waiting) \(.calibrated) \(.suggested)"]
                   | sort | join(", ")' "$tmp/gate.json")" = "$(printf '%s, ' \
      "http://127.0.0.1:8471 fake-decider@0123456 2/1/0 false null" \
      "http://a.test m@1111111 46/46/0 true 0.95" \
      "http://a.test m@2222222 2/2/0 false null" \
      "http://b.test m@1111111 46/43/0 false null" \
      "http://c.test c-model 0/0/0 false 0.75" \
      "http://d.test d-model 0/0/3 false null" | sed 's/, $//')"
  check "calibration gate: the report card says what it was judged by" \
    test "$(jq -c .decider.gate_rules "$tmp/gate.json")" = '{"threshold":0.9,"block":46,"max_wrong":1,"percent":90}'
  pg -c 'DROP SCHEMA chalk_e2e CASCADE'
fi

# 3c''. chalk share: an anonymised report card that never holds anything
# identifying (#21). The database and the state directory are seeded with
# sentinels: repository and branch names, ticket IDs, paths, test names,
# errors, notes, lessons, an email, a host, model revisions, a cloud
# account ID and labels Chalk never writes. None may reach the summary.
# Against a real Postgres the sentinels go through share/dashboard.sql and
# share/share.sql; with the fakes, the database answers with them directly,
# as if a query had let them through, and share/share.jq must drop them.
decider_name="$(sed -n 's/^DECIDER_MODEL=//p' "$here/../lib/decider.sh")"
decider_name="${decider_name##*/}"
mkdir -p "$XDG_STATE_HOME/chalk/SENTINEL_REPO/runs/SENT-123"
printf 'loop 1 failed at /SENTINEL/path/app.py: SENTINEL_TEXT\n' \
  > "$XDG_STATE_HOME/chalk/SENTINEL_REPO/runs/SENT-123/run.log"
if [ -n "${FAKE_PG_URL:-}" ]; then
  spg() { PGOPTIONS='-c search_path=chalk_e2e_share,public -c client_min_messages=warning' psql "$FAKE_PG_URL" -X -q -A -t -v ON_ERROR_STOP=1 "$@"; }
  spg -c 'DROP SCHEMA IF EXISTS chalk_e2e_share CASCADE' -c 'CREATE SCHEMA chalk_e2e_share'
  spg -f "$here/../share/schema.sql"
  spg -v decider="$decider_name" <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons,
                  run_id, tests_hash, failing, first_error, tree_id, verdict, fp_rules, failing_tests)
VALUES
  ('SENTINEL_REPO', 'SENT-123', 'chalk/SENT-123-sentinel-branch', 1, 'continue', 'ok', 1, false,
   'claude-opus-4-5-20251101', 'SENTINELHASH', 0.4567, 1, 30, 1234567, 2345, 3456789, 4567, 12, 1, 0,
   'SENT-123-1700000000', 'SENTINELTESTHASH', 2, 'Error at /SENTINEL/path/app.py: SENTINEL_TEXT',
   'SENTINELTREE', 'first', 'shadow', E'tests/SENTINEL_TEST.py::test_sentinel_login\n/SENTINEL/path/spec.js'),
  ('SENTINEL_REPO', 'SENT-123', 'chalk/SENT-123-sentinel-branch', 2, 'retry', 'SENTINEL_STATUS', 1, false,
   'arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/sentinelarn', 'SENTINELHASH',
   0.3333, 1, 20, 1000, 200, 0, 0, 3, 0, 1,
   'SENT-123-1700000000', 'SENTINELTESTHASH', 2, 'Error at /SENTINEL/path/app.py: SENTINEL_TEXT',
   'SENTINELTREE', 'SENTINEL_VERDICT', 'SENTINEL_RULES', 'tests/SENTINEL_TEST.py::test_sentinel_login'),
  ('SENTINEL_REPO', 'SENT-123', 'chalk/SENT-123-sentinel-branch', 3, 'retry', 'ok', 0, true,
   'claude-opus-4-5-20251101', 'SENTINELHASH', 0.2, 1, 10, 1000, 100, 0, 0, 2, 0, 1,
   'SENT-123-1700000000', NULL, NULL, NULL, 'SENTINELTREE2', NULL, 'shadow', NULL),
  ('SENTINEL_REPO', 'SENT-123', 'chalk/SENT-123-sentinel-branch', 0, 'review', 'pass', 0, false,
   'claude-sonnet-4-5@20250929', 'SENTINELHASH', 0.1, 1, 5, 100, 10, 0, 0, 1, 0, 0,
   'SENT-123-1700000000', NULL, NULL, NULL, NULL, NULL, 'shadow', NULL),
  ('SENTINEL_REPO', 'SENT-123', 'chalk/SENT-123-sentinel-branch', 0, 'SENTINEL_KIND', 'ok', 0, false,
   'claude-haiku-4-5-20251001', 'SENTINELHASH', 0.01, 1, 1, 10, 1, 0, 0, 1, 0, 0,
   'SENT-123-1700000000', NULL, NULL, NULL, NULL, NULL, NULL, NULL),
  ('sentinel-other-repo', 'SENT-456', 'chalk/SENT-456', 1, 'continue', 'ok', 0, true,
   'us.anthropic.claude-sonnet-4-5-20250929-v1:0', 'SENTINELHASH', 0.25, 1, 40, 500, 50, 0, 0, 4, 0, 0,
   'SENT-456-1700000001', NULL, NULL, NULL, 'SENTINELTREE3', NULL, 'on', NULL);
INSERT INTO events (repo, ticket, kind)
VALUES ('SENTINEL_REPO', 'SENT-123', 'detention'), ('SENTINEL_REPO', 'SENT-123', 'SENTINEL_EVENT'),
       ('sentinel-other-repo', 'SENT-456', 'submitted');
INSERT INTO lessons (repo, ticket, signature, resolution, lesson, resolved_by, resolved_at,
                     run_id, fingerprint, first_error, scope)
VALUES ('SENTINEL_REPO', 'SENT-123', E'deja_vu: rubric failed (exit 1)\n/SENTINEL/path/app.py SENTINEL_TEXT',
        'SENTINEL_TEXT: the fix was in /SENTINEL/path', 'SENTINEL_LESSON: never touch /SENTINEL/path',
        'sentinel.user@example.com', now(), 'SENT-123-1700000000', 'SENTINELFP', '/SENTINEL/path', 'repo'),
       ('SENTINEL_REPO', 'SENT-789', 'SENTINEL_TEXT, a reason Chalk never writes', NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL);
INSERT INTO decisions (call_id, run_id, kind, question, answer, confidence, threshold, mode,
                       latency_ms, acted, model, error, url)
SELECT (SELECT id FROM runs WHERE run_id = 'SENT-123-1700000000' AND loop = v.n AND kind <> 'review'
          ORDER BY id LIMIT 1),
       'SENT-123-1700000000', v.kind, 'SENTINEL_QUESTION about /SENTINEL/path', v.a, v.c, 0.9, v.mode,
       v.ms, false, v.model, v.e, v.u
  FROM (VALUES (1, 'stuck', 'yes', 0.95, 'shadow', 123, 'SENTINEL-HOST.example.com/decider@deadbee', NULL,
                'https://SENTINEL-URL.example.net:8443/decider'),
               (2, 'stuck', 'no', 0.75, 'shadow', 457, :'decider' || '@abcdef1', NULL, 'http://127.0.0.1:8471'),
               (2, 'SENTINEL_DKIND', NULL, NULL, 'SENTINEL_MODE', 2000, NULL, 'SENTINEL_ERROR', NULL)
       ) v(n, kind, a, c, mode, ms, model, e, u);
SQL
  PGOPTIONS='-c search_path=chalk_e2e_share,public' chalk share --json --days 30 > "$tmp/share.json" 2> "$tmp/share.err" ||
    { cat "$tmp/share.err"; fail "chalk share against a seeded database"; }
else
  # The report card's data and share.sql's counts, with a sentinel in
  # every string a query could let through.
  cat > "$tmp/share-dashboard.json" <<'JSON'
{"generated_at": "2026-10-05T10:00:00Z", "days": 30, "submitted": 1, "detentions": 1,
 "totals": {"cost": 1.3500, "calls": 6, "loops": 4, "checkpoints": 2, "loop_cost": 1.2400,
            "wasted": 0.7900, "tickets": 2, "input_tokens": 1237177, "output_tokens": 2706,
            "cache_read_tokens": 3456789, "cache_write_tokens": 4567, "denials": 1, "loop_denials": 1},
 "by_hour": [{"hour": "2026-10-05T09:00:00Z", "cost": 1.35, "wasted": 0.79}],
 "by_kind": [{"kind": "continue", "calls": 2, "cost": 0.7067, "avg_cost": 0.3534, "avg_seconds": 35},
             {"kind": "SENTINEL_KIND", "calls": 1, "cost": 0.01, "avg_cost": 0.01, "avg_seconds": 1}],
 "by_model": [{"model": "claude-opus-4-5-20251101", "loops": 2, "cost": 0.6567, "checkpoints": 1},
              {"model": "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/sentinelarn", "loops": 1, "cost": 0.3333, "checkpoints": 0},
              {"model": "us.anthropic.claude-sonnet-4-5-20250929-v1:0", "loops": 1, "cost": 0.25, "checkpoints": 1}],
 "by_prompts": [{"prompts": "SENTINELHASH", "first_seen": "2026-10-05T09:00:00Z", "loops": 4, "cost": 1.24}],
 "budget": {"loops": 4, "cap": 1.0000, "cap_min": 1.0000, "p50": 0.29, "p90": 0.42, "max": 0.4567, "near_cap": 0},
 "review": {"reviews": 1, "failed": 0, "cost": 0.1, "fix_cost": 0},
 "spec": {"checks": 0, "failed": 0, "cost": 0},
 "lessons": {"with": 2, "with_passed": 1, "without": 0, "without_passed": 0},
 "failing_tests": [{"repo": "SENTINEL_REPO", "test": "tests/SENTINEL_TEST.py::test_sentinel_login", "loops": 2, "tickets": 1, "last": "2026-10-05T09:00:00Z", "n": 1}],
 "ledger": {"detained_runs": 1, "no_progress_cost": 0.79, "saved": 0.53, "blocked_only": 0, "blocked_only_cost": 0,
            "no_verdicts": 0, "false_stops": 0, "false_stop_cost": 0, "converging": 0, "stopped_on": 0,
            "by_verdict": [{"verdict": "SENTINEL_VERDICT", "runs": 1, "saved": 0.53}],
            "runs": [{"run_id": "SENT-123-1700000000", "repo": "SENTINEL_REPO", "ticket": "SENT-123"}],
            "unknown_tests": [{"repo": "SENTINEL_REPO", "loops": 2, "unknown": 0}]},
 "decider": {"questions": 3, "answered": 2, "acted": 0, "median_ms": 290,
             "models": ["SENTINEL-HOST.example.com/decider@deadbee", "DECIDER@abcdef1"],
             "by_kind": [{"kind": "SENTINEL_DKIND", "questions": 1, "answered": 0, "acted": 0},
                         {"kind": "stuck", "questions": 2, "answered": 2, "acted": 0}],
             "errors": [{"error": "SENTINEL_ERROR", "calls": 1}],
             "calibration": [{"low": 0.7, "answers": 1, "agreed": 1}, {"low": "SENTINEL", "answers": 1, "agreed": 0}],
             "would_stop": 1, "would_save": 0.53, "false_stops": 0},
 "tickets": [{"repo": "SENTINEL_REPO", "ticket": "SENT-123", "state": "detention", "last": "2026-10-05T09:00:00Z"}]}
JSON
  sed -i.bak "s/DECIDER@/$decider_name@/" "$tmp/share-dashboard.json" && rm "$tmp/share-dashboard.json.bak"
  cat > "$tmp/share-extra.json" <<'JSON'
{"runs": 2, "repositories": 2, "agent": {"ok": 3, "blocked": 0, "error": 1, "turns": 21},
 "verdicts": {"first": 1, "SENTINEL_VERDICT": 1, "none": 2},
 "fp_rules": {"shadow": 2, "SENTINEL_RULES": 1, "on": 1},
 "events": {"detention": 1, "submitted": 1, "SENTINEL_EVENT": 1},
 "detentions_by_reason": {"deja_vu": 1, "SENT-123 at /SENTINEL/path": 1},
 "lessons": {"opened": 2, "resolved": 1, "distilled": 1, "scope_repo": 1, "scope_general": 0, "fingerprinted": 1},
 "decider_modes": {"shadow": 2, "SENTINEL_MODE": 1},
 "note": "SENTINEL_TEXT from sentinel.user@example.com"}
JSON
  FAKE_DASHBOARD="$tmp/share-dashboard.json" FAKE_SHARE_COUNTS="$tmp/share-extra.json" \
    chalk share --json --days 30 > "$tmp/share.json" 2> "$tmp/share.err" ||
    { cat "$tmp/share.err"; fail "chalk share"; }
fi
# share_has FILTER VALUE: the summary's FILTER is VALUE.
share_has() { test "$(jq -c "$1" "$tmp/share.json")" = "$2"; }
check "share: prints one JSON summary and nothing else on stdout" jq -e 'type == "object" and .schema == 1' "$tmp/share.json"
check "share: --json prints no guidance" test ! -s "$tmp/share.err"
leaks=""
for sentinel in SENTINEL SENT-123 SENT-456 SENT-789 /SENTINEL/path 123456789012 example.com \
                example.net deadbee abcdef1 20251101 20250929 1700000000 us.anthropic arn:aws 0.4567 0.3333 \
                1237177 3456789 test_sentinel_login "$tmp" "$XDG_STATE_HOME" "$HOME"; do
  if grep -qiF -- "$sentinel" "$tmp/share.json"; then leaks="$leaks $sentinel"; fi
done
user="$(id -un)"
if (( ${#user} >= 5 )) && grep -qiF -- "$user" "$tmp/share.json"; then leaks="$leaks $user"; fi
[ -z "$leaks" ] || { jq . "$tmp/share.json"; echo "leaked:$leaks"; }
check "share: no repository, ticket, path, test, note, email, host, revision or account ID leaks" test -z "$leaks"
check "share: models are named by family, and anything else is other" \
  share_has '[.by_model[] | "\(.model)=\(.loops)"] | sort' '["claude-opus-4-5=2","claude-sonnet-4-5=1","other=1"]'
check "share: costs and token counts are rounded to two significant figures" \
  share_has '[.totals.cost_usd, .totals.input_tokens, .budget.max_usd]' '[1.4,1200000,0.46]'
check "share: counts are kept as they are" \
  share_has '[.totals.loops, .totals.runs, .totals.repositories, .totals.submitted, .totals.detentions]' '[4,2,2,1,1]'
check "share: labels Chalk does not write read as other" \
  share_has '[.verdicts.other, .fp_rules.other, .detentions_by_reason.other, .decider.modes.other, .decider.errors.other]' '[1,1,1,1,1]'
check "share: the local decider is named, any other only as hosted" \
  share_has '.decider.models' "[\"hosted\",\"$decider_name\"]"
check "share: the summary says what kind of machine, not which" \
  jq -e '.host | (.os | IN("darwin", "linux", "other")) and (.cpus == null or (.cpus | test("^[0-9]+(-[0-9]+|\\+)?$")))' "$tmp/share.json"
# network_calls: how many bytes the network fakes have logged so far.
network_calls() {
  local log bytes=0
  for log in "$FAKE_STATE"/{curl,gh,glab,claude}.log; do
    if [ -e "$log" ]; then bytes=$((bytes + $(wc -c < "$log"))); fi
  done
  echo "$bytes"
}
before="$(network_calls)"
chalk share --days 30 --output "$tmp/share-saved.json" > "$tmp/share2.out" 2> "$tmp/share2.err" ||
  { cat "$tmp/share2.err"; fail "chalk share --output"; }
check "share: --output saves the same JSON it prints" cmp -s "$tmp/share-saved.json" "$tmp/share2.out"
check "share: says nothing was sent, and where it could be posted" \
  sh -c "grep -q 'Nothing has been sent' '$tmp/share2.err' && grep -qF 'discussions/new?category=report-cards' '$tmp/share2.err'"
check "share: calls no network tool (curl, gh, glab, claude)" \
  test "$(network_calls)" = "$before"
if chalk share --days 0 >/dev/null 2>&1; then fail "share must reject --days 0"; fi
pass "share: --days takes a positive whole number"
if [ -n "${FAKE_PG_URL:-}" ]; then spg -c 'DROP SCHEMA chalk_e2e_share CASCADE'; fi

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
detention="$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/PROJ-8-*')"
check "a stopped run parks the loop's unfinished work on a detention branch" \
  sh -c "test -n '$detention' && git cat-file -e '$detention:slow.txt' && grep -q 'run stopped by a signal (exit 143)' '$tmp/run9.log'"
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
if chalk db down > "$tmp/db-down.log" 2>&1; then fail "chalk db down must refuse while a run is alive"; fi
check "chalk db down refuses while a run is alive, and says how to force it" \
  grep -q "1 run(s) on this machine are using the database.*chalk db down --force" "$tmp/db-down.log"
read -r pid < "$XDG_STATE_HOME/chalk/demo/runs/PROJ-30/pid"
kill -TERM "$pid"
for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
cd "$tmp/demo"

# 3e'. Behind a proxy that re-signs HTTPS, CHALK_EXTRA_CA_CERTS is trusted
# by the image build and by every sandbox. Failures say what to do.
if FAKE_BUILD_FAIL=tls chalk sandbox build > "$tmp/build-tls.log" 2>&1; then fail "a build that fails on TLS must fail"; fi
check "a build that fails on TLS says to set CHALK_EXTRA_CA_CERTS, with no stack trace" \
  sh -c "grep -q 'this network intercepts TLS .*set CHALK_EXTRA_CA_CERTS' '$tmp/build-tls.log' && ! grep -q 'unexpected failure' '$tmp/build-tls.log'"
if FAKE_BUILD_FAIL=rate chalk sandbox build > "$tmp/build-rate.log" 2>&1; then fail "a rate-limited build must fail"; fi
check "a rate-limited build says to wait or sign in" grep -q 'wait a few minutes and try again, or sign in with docker login' "$tmp/build-rate.log"
printf -- '-----BEGIN CERTIFICATE-----\nproxy\n-----END CERTIFICATE-----\n' > "$tmp/proxy-ca.pem"
CHALK_EXTRA_CA_CERTS="$tmp/proxy-ca.pem" chalk sandbox build > /dev/null 2>&1 || fail "a build with CHALK_EXTRA_CA_CERTS"
check "the image build gets CHALK_EXTRA_CA_CERTS as a build secret" \
  grep -qF "build --secret id=extra_ca,src=$tmp/proxy-ca.pem" "$FAKE_STATE/docker.log"
chalk new PROJ-74 Behind a proxy >/dev/null
cd "$tmp/demo.worktrees/PROJ-74"
git add -A && git commit -q -m "spec"
if CHALK_EXTRA_CA_CERTS=proxy-ca.pem chalk run > "$tmp/run74a.log" 2>&1; then fail "a relative CHALK_EXTRA_CA_CERTS must be refused"; fi
check "a relative CHALK_EXTRA_CA_CERTS is refused before any sandbox starts" \
  grep -q 'CHALK_EXTRA_CA_CERTS must be an absolute path' "$tmp/run74a.log"
CHALK_EXTRA_CA_CERTS="$tmp/proxy-ca.pem" chalk run > "$tmp/run74.log" 2>&1 || { cat "$tmp/run74.log"; fail "a run with CHALK_EXTRA_CA_CERTS"; }
check "a sandbox mounts CHALK_EXTRA_CA_CERTS read-only and points the agent and tools at it" \
  sh -c "grep -F -- '-v $tmp/proxy-ca.pem:/chalk-ca.pem:ro' '$FAKE_STATE/docker.log' |
    grep -F 'NODE_EXTRA_CA_CERTS=/chalk-ca.pem' | grep -qF 'SSL_CERT_FILE=/home/chalk/.ca-bundle.pem'"
check "a run with CHALK_EXTRA_CA_CERTS still opens its merge request" grep -q "mr create.*chalk/PROJ-74" "$FAKE_STATE/glab.log"
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
# push was refused), detained when a stopped run parked its work (PROJ-8,
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
    = "PROJ-1=submitted PROJ-2=submitted PROJ-6=detained PROJ-4=submitted PROJ-24=spec-blocked PROJ-23=done PROJ-8=detained PROJ-14=new "
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

# 4c. The decider (docs/decider-protocol.md), played by the fake in
# tests/fakes/curl at a hosted URL, so nothing is started. The agent
# changes a file every loop but the same test keeps failing, so the rules
# call loops 2 and 3 spinning: the gray zone the decider is asked about.
# decider_run TICKET [ENV=VALUE...]: a churning run of TICKET, its log in
# $tmp/TICKET.log, the requests the decider got in $tmp/TICKET.decider and
# what went to the database in $tmp/TICKET.db. Each ticket fails its own
# test, so that no run fails like another's open detention (deja_vu).
decider_run() {
  local ticket="$1" db_lines decider_cmd
  shift
  decider_cmd="if [ -e BROKEN ]; then mkdir -p out
    echo '<testsuite><testcase classname=\"demo\" name=\"no_marker_$ticket\"><failure message=\"BROKEN\"/></testcase></testsuite>' > out/report.xml
    echo 'AssertionError: BROKEN exists in $ticket'; exit 1; fi"
  cd "$tmp/demo"
  chalk new "$ticket" Decider feature >/dev/null
  cd "$tmp/demo.worktrees/$ticket"
  git add -A && git commit -q -m "spec"
  : > "$FAKE_STATE/decider.log"
  db_lines="$(wc -l < "$FAKE_STATE/db.log")"
  env FAKE_CLAUDE_MODE=churn CHALK_TEST_REPORT=out/report.xml CHALK_TEST_CMD="$decider_cmd" \
      CHALK_DECIDER_URL=http://decider.test CHALK_EMBED_URL=http://embed.test "$@" \
      chalk run > "$tmp/$ticket.log" 2>&1 || true
  tail -n +"$((db_lines + 1))" "$FAKE_STATE/db.log" > "$tmp/$ticket.db"
  cp "$FAKE_STATE/decider.log" "$tmp/$ticket.decider"
  cd "$tmp/demo"
}
# asked TICKET: how many stuck questions the decider got.
asked() { grep -c '"stuck":{"type":"noul"' "$tmp/$1.decider" || true; }
# detained_as_usual TICKET: three loops, then detention for the failing rubric.
detained_as_usual() {
  grep -q 'loop 3 (retry)' "$tmp/$1.log" && ! grep -q 'loop 4' "$tmp/$1.log" &&
    grep -q 'DETENTION: rubric failed (exit 1)$' "$tmp/$1.log" &&
    next_step "$tmp/$1.log" "the rubric still fails after 2 retries"
}

# A decider on another machine gets nothing until `chalk decider trust`
# acknowledges it: the run goes on with the decider off and says so once,
# with exactly what it would have sent, and where.
touch "$FAKE_STATE/curl.log"
curl_lines="$(wc -l < "$FAKE_STATE/curl.log")"
decider_run PROJ-49 CHALK_DECIDER=on FAKE_DECIDER_ANSWERS="stuck=0.97"
check "hosted, not acknowledged: the run goes as with the decider off" detained_as_usual PROJ-49
check "hosted, not acknowledged: nothing reaches the decider or chalk-embed" \
  sh -c "test ! -s '$tmp/PROJ-49.decider' &&
    ! tail -n +$((curl_lines + 1)) '$FAKE_STATE/curl.log' | grep -qE '^http://(decider|embed)\.test'"
check "... and no answer is recorded" sh -c "! grep -q 'INSERT INTO decisions' '$tmp/PROJ-49.db'"
check "hosted, not acknowledged: the run says so once, with what to run" \
  test "$(grep -c '^warning: continuing with the decider off: http://decider.test and http://embed.test are on another machine, .* run: chalk decider trust http://decider.test; chalk decider trust http://embed.test$' "$tmp/PROJ-49.log")" -eq 1
check "... and the disclosure: what each would receive, and where" \
  sh -c "grep -q '^  The decider (http://decider.test) gets, in POST /v1/systemone:' '$tmp/PROJ-49.log' &&
    grep -q 'the failing test IDs (up to 20) and the first error line' '$tmp/PROJ-49.log' &&
    grep -q '^  The embedding service (http://embed.test) gets' '$tmp/PROJ-49.log'"
curl_lines="$(wc -l < "$FAKE_STATE/curl.log")"
CHALK_DECIDER=shadow CHALK_DECIDER_URL=http://decider.test CHALK_EMBED_URL=http://embed.test \
  chalk doctor > "$tmp/doctor-untrusted.log" 2>&1 || true
CHALK_DECIDER=shadow CHALK_DECIDER_URL=http://decider.test CHALK_EMBED_URL=http://embed.test \
  chalk decider status > "$tmp/status-untrusted.log" 2>&1 || { cat "$tmp/status-untrusted.log"; fail "chalk decider status"; }
check "doctor: a hosted decider not acknowledged is reported, with what to run" \
  grep -q '^  --    decider (CHALK_DECIDER=shadow): runs go on with it off: http://decider.test and http://embed.test are on another machine' \
    "$tmp/doctor-untrusted.log"
check "doctor: ... and what it would receive" \
  grep -q '^        The decider (http://decider.test) gets, in POST /v1/systemone:' "$tmp/doctor-untrusted.log"
check "chalk decider status: the same, for each" \
  sh -c "grep -q '^http://decider.test: on another machine and not acknowledged' '$tmp/status-untrusted.log' &&
    grep -q '^http://embed.test: on another machine and not acknowledged' '$tmp/status-untrusted.log' &&
    grep -q '^  The decider (http://decider.test) gets' '$tmp/status-untrusted.log'"
check "doctor and status contact neither, not even for health" \
  sh -c "! tail -n +$((curl_lines + 1)) '$FAKE_STATE/curl.log' | grep -qE '^http://(decider|embed)\.test'"
chalk decider trust http://decider.test > "$tmp/trust.log" 2>&1 || { cat "$tmp/trust.log"; fail "chalk decider trust"; }
check "chalk decider trust shows what is sent, then records the URL" \
  sh -c "grep -q '^The decider (http://decider.test) gets' '$tmp/trust.log' &&
    grep -q '^acknowledged: ' '$tmp/trust.log' && grep -qx 'http://decider.test' '$XDG_STATE_HOME/chalk/decider/trusted'"
chalk decider trust http://embed.test >/dev/null 2>&1 || fail "chalk decider trust (embed)"

decider_run PROJ-50 CHALK_DECIDER=off
check "decider off: the churning run takes three loops, then the usual detention" detained_as_usual PROJ-50
check "decider off: the loops after the first are spinning" \
  test "$(grep -c -e '-v verdict=spinning$' "$tmp/PROJ-50.db")" -eq 2
check "decider off: nothing is asked" test "$(asked PROJ-50)" -eq 0

decider_run PROJ-51 CHALK_DECIDER=shadow FAKE_DECIDER_ANSWERS="stuck=0.97"
check "decider shadow: the run is unchanged" detained_as_usual PROJ-51
check "hosted, acknowledged: the run says where questions go, and asks" \
  sh -c "grep -q '^decider: questions go to http://decider.test (acknowledged' '$tmp/PROJ-51.log' &&
    ! grep -q 'continuing with the decider off' '$tmp/PROJ-51.log' && test -s '$tmp/PROJ-51.decider'"
check "decider shadow: each spinning loop is put to the decider" test "$(asked PROJ-51)" -eq 2
state="$(grep '"stuck"' "$tmp/PROJ-51.decider" | tail -n 1 | jq -r .state)"
check "the decider gets the failing tests and first errors of both loops" \
  sh -c 'printf "%s\n" "$1" | grep -q "^previous loop:" && printf "%s\n" "$1" | grep -q "^current loop:" &&
    test "$(printf "%s\n" "$1" | grep -c "failing tests (1): demo::no_marker")" -eq 2 &&
    test "$(printf "%s\n" "$1" | grep -c "first error: AssertionError: BROKEN exists")" -eq 2' _ "$state"
check "... and a diffstat between their trees, never the diff itself" \
  sh -c 'printf "%s\n" "$1" | grep -q " churn.txt | 1 +" && ! printf "%s\n" "$1" | grep -qE "^(@@|\+attempt|diff --git)"' _ "$state"
check "decider shadow: the answers are recorded with their loops, none acted on" \
  sh -c "test \"\$(grep -c 'INSERT INTO decisions' '$tmp/PROJ-51.db')\" -eq 2 &&
    grep -q '\"answer\":\"yes\",\"confidence\":0.970,\"threshold\":0.9,\"mode\":\"shadow\"' '$tmp/PROJ-51.db' &&
    ! grep -q '\"acted\":true' '$tmp/PROJ-51.db'"

# Every provider starts uncalibrated (decider_calibration): until enough
# shadow runs show its confident answers right, on records as shadow.
# Without a database (make test) its calibration cannot be read; with one
# (make test-db) it has only PROJ-51's run. Either way it does not act.
decider_run PROJ-52 CHALK_DECIDER=on FAKE_DECIDER_ANSWERS="stuck=0.97"
check "decider on, not calibrated: the run is unchanged, nothing detained early" detained_as_usual PROJ-52
check "decider on, not calibrated: the answers are recorded in shadow mode, none acted on" \
  sh -c "test \"\$(grep -c 'INSERT INTO decisions' '$tmp/PROJ-52.db')\" -eq 2 &&
    grep -q '\"answer\":\"yes\",\"confidence\":0.970,\"threshold\":0.9,\"mode\":\"shadow\"' '$tmp/PROJ-52.db' &&
    ! grep -q '\"acted\":true' '$tmp/PROJ-52.db'"
check "decider on, not calibrated: the run says why, once" \
  test "$(grep -c '^warning: CHALK_DECIDER=on records in shadow mode only: fake-decider at http://decider.test' "$tmp/PROJ-52.log")" -eq 1

decider_run PROJ-53 CHALK_DECIDER=on FAKE_DECIDER_ANSWERS="stuck=0.6"
check "decider on: an answer below the threshold changes nothing" detained_as_usual PROJ-53

decider_run PROJ-54 CHALK_DECIDER=on FAKE_DECIDER_ANSWERS="stuck=0.97" FAKE_DECIDER_DOWN=1
check "decider unreachable: the run goes as with the decider off" detained_as_usual PROJ-54
check "decider unreachable: no warning, and no answer recorded as unreachable" \
  sh -c "! grep -q '^warning' '$tmp/PROJ-54.log' && grep -q '\"error\":\"unreachable\"' '$tmp/PROJ-54.db'"

decider_run PROJ-55 CHALK_DECIDER=on FAKE_DECIDER_ANSWERS="stuck=0.97" FAKE_DECIDER_DELAY=5
check "decider too slow: the run goes as with the decider off" detained_as_usual PROJ-55
check "decider too slow: no call waits past the loop's 2 s, recorded as a timeout" \
  sh -c "sed -n 's/^max-time=//p' '$tmp/PROJ-55.decider' | awk '{ if (\$1 > 2) bad = 1 } END { exit bad || NR == 0 }' &&
    grep -q '\"error\":\"timeout\"' '$tmp/PROJ-55.db'"

decider_run PROJ-56 CHALK_DECIDER=on CHALK_FP_RULES=off FAKE_DECIDER_ANSWERS="stuck=0.97"
check "CHALK_FP_RULES=off: the decider is not asked whether a loop is stuck" test "$(asked PROJ-56)" -eq 0
check "CHALK_FP_RULES=off: the run goes as with the decider off" detained_as_usual PROJ-56

decider_run PROJ-57 CHALK_DECIDER=on FAKE_DECIDER_ANSWERS="stuck=0.97" \
  CHALK_DECIDER_TOKEN=tok-e2e-secret FAKE_DECIDER_TOKEN=tok-e2e-secret
check "a hosted decider gets CHALK_DECIDER_TOKEN, and answers" grep -q '"answer":"yes","confidence":0.970' "$tmp/PROJ-57.db"
check "the token is never logged or stored" \
  sh -c "! grep -rq 'tok-e2e-secret' '$FAKE_STATE' '$XDG_STATE_HOME' '$tmp/PROJ-57.log' '$tmp/PROJ-57.db'"
decider_run PROJ-58 CHALK_DECIDER=on FAKE_DECIDER_ANSWERS="stuck=0.97" \
  CHALK_DECIDER_TOKEN=wrong FAKE_DECIDER_TOKEN=tok-e2e-secret
check "a refused token: the run goes as with the decider off, with one warning" \
  sh -c "grep -q 'DETENTION: rubric failed (exit 1)$' '$tmp/PROJ-58.log' &&
    test \"\$(grep -c '^warning: the decider at http://decider.test refused the request' '$tmp/PROJ-58.log')\" -eq 1"

# Once a block of 46 shadow runs shows its confident "stuck" right with at
# most one false stop, the same decider acts. Only with a database to show it (make test-db).
if [ -n "${FAKE_PG_URL:-}" ]; then
  calibrate http://decider.test fake-decider 0.95 46 0
  decider_run PROJ-63 CHALK_DECIDER=on FAKE_DECIDER_ANSWERS="stuck=0.97"
  check "decider on, calibrated: a confident stuck detains the run at loop 2, quietly" \
    sh -c "grep -q 'DETENTION: stuck: rubric failed (exit 1)' '$tmp/PROJ-63.log' && ! grep -q 'loop 3' '$tmp/PROJ-63.log' &&
      ! grep -q 'records in shadow mode only' '$tmp/PROJ-63.log'"
  check "next step when the decider stopped the run: fix the cause yourself" \
    next_step "$tmp/PROJ-63.log" "the decider judged the agent stuck on the same root cause as the loop before (confidence 0.97)"
  check "decider on, calibrated: the answer that acted is recorded as such" \
    grep -q '"mode":"on","latency_ms":[0-9]*,"acted":true' "$tmp/PROJ-63.db"
  check "decider on, calibrated: the lesson carries the failing loop's fingerprint" \
    grep -Eq -e "-v fingerprint=[0-9a-f]{64} -v first_error=AssertionError: BROKEN exists" "$tmp/PROJ-63.db"
  CHALK_DECIDER=on CHALK_DECIDER_URL=http://decider.test chalk decider status > "$tmp/decider-status-cal.log" 2>&1 ||
    { cat "$tmp/decider-status-cal.log"; fail "chalk decider status"; }
  check "chalk decider status: on acts, and the numbers it was judged by" \
    sh -c "grep -q '(acting as on)' '$tmp/decider-status-cal.log' &&
      grep -q '^calibration: fake-decider at http://decider.test is calibrated: [0-9]* shadow run(s) judged at CHALK_DECIDER_THRESHOLD=0.9' '$tmp/decider-status-cal.log'"
  CHALK_DECIDER=on CHALK_DECIDER_URL=http://decider.test CHALK_DECIDER_THRESHOLD=0.99 chalk doctor > "$tmp/doctor-cal.log" 2>&1 || true
  # Its answers at 0.6 (PROJ-53) were right too, so 0.6 would pass.
  check "doctor: at a threshold it said nothing at, it is not calibrated, and the lowest that would pass is named" \
    grep -q '^  --    decider calibration: fake-decider at http://decider.test is not calibrated yet: 0 shadow run(s) judged at CHALK_DECIDER_THRESHOLD=0.99; it needs a block of 46 judged runs with at most 1 wrongful stop(s), which shows it right at least 90% of the time, 95% sure; it would be at CHALK_DECIDER_THRESHOLD=0.6; until it is, CHALK_DECIDER=on records in shadow mode only' \
      "$tmp/doctor-cal.log"
  check "doctor: how many questions the decider was asked lately" \
    grep -Eq '^  ok    decider asked [1-9][0-9]* question\(s\) in the last 30 days$' "$tmp/doctor-cal.log"

  # Asked nothing (#85): every loop kept its rubric green, and the agent
  # that could not progress reported a blocker. doctor, chalk decider
  # status and the report card say why, rather than show zeros. In a schema
  # of its own: four loops, one of them blocked, and four resolved lessons.
  quiet_pg() { PGOPTIONS='-c search_path=chalk_quiet,public -c client_min_messages=warning' psql "$FAKE_PG_URL" -X -q -A -t -v ON_ERROR_STOP=1 "$@"; }
  quiet_pg -c 'DROP SCHEMA IF EXISTS chalk_quiet CASCADE' -c 'CREATE SCHEMA chalk_quiet'
  quiet_pg -f "$here/../share/schema.sql"
  quiet_pg <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons, run_id, verdict, fp_rules)
SELECT 'quiet', t, 'chalk/' || t, n, 'continue', s, 0, s = 'ok', 'm', 'p', 0.1, 1, 1, 0, 0, 0, 0, 0, 0, 0,
       t || '-1', CASE WHEN s = 'ok' THEN NULL ELSE 'blocked' END, 'shadow'
  FROM (VALUES ('Q-1', 1, 'ok'), ('Q-1', 2, 'ok'), ('Q-2', 1, 'ok'), ('Q-3', 1, 'blocked')) v(t, n, s);
INSERT INTO lessons (repo, ticket, signature, run_id) VALUES ('quiet', 'Q-3', 'agent reported a blocker', 'Q-3-1');
INSERT INTO lessons (repo, ticket, signature, resolution, lesson, resolved_by, resolved_at)
SELECT 'quiet', 'OLD-' || i, 's', 'note', 'fix', 'e2e', now() FROM generate_series(1, 4) i;
SQL
  why="the stuck question is asked only after a loop fails its rubric, and 0 of 4 loops did (1 run(s) ended in a blocker instead); lesson rerank needs 30 resolved lessons, this machine has 4"
  export PGOPTIONS='-c search_path=chalk_quiet,public -c client_min_messages=warning'
  CHALK_DECIDER=shadow CHALK_DECIDER_URL=http://decider.test chalk doctor > "$tmp/doctor-quiet.log" 2>&1 || true
  CHALK_DECIDER=shadow CHALK_DECIDER_URL=http://decider.test chalk decider status > "$tmp/status-quiet.log" 2>&1 ||
    { cat "$tmp/status-quiet.log"; fail "chalk decider status"; }
  CHALK_DECIDER=shadow chalk dashboard --no-open --days 30 --output "$tmp/quiet.html" >/dev/null
  CHALK_DECIDER=off chalk dashboard --no-open --days 30 --output "$tmp/quiet-off.html" >/dev/null
  export PGOPTIONS="${e2e_pgoptions:-}"
  sed -n '/^const DATA =$/{n;p;}' "$tmp/quiet.html" > "$tmp/quiet.json"
  sed -n '/^const DATA =$/{n;p;}' "$tmp/quiet-off.html" > "$tmp/quiet-off.json"
  check "doctor: a decider asked nothing says why, with the numbers" \
    grep -qxF "  --    decider asked 0 questions in the last 30 days: $why" "$tmp/doctor-quiet.log"
  check "chalk decider status: the same" grep -qxF "questions: 0 in the last 30 days: $why" "$tmp/status-quiet.log"
  check "report card: the decider panel says why it is empty" \
    test "$(jq -r .empty.decider "$tmp/quiet.json")" = "0 questions in the last 30 days: $why."
  check "report card: ... only when the decider is wanted" test "$(jq -r .empty.decider "$tmp/quiet-off.json")" = ""
  check "report card: the verdict ledger says why it counts no run" \
    test "$(jq -r .empty.ledger "$tmp/quiet.json")" = "No loop failed its rubric or passed without ticking a checkpoint in the last 30 days (4 loop(s)), so no verdict could stop a run; agents that could not progress reported a blocker instead (1 run(s))."
  check "report card: ... next to the blocked run it counts apart" test "$(jq -r .ledger.blocked_only "$tmp/quiet.json")" = 1
  quiet_pg -c 'DROP SCHEMA chalk_quiet CASCADE'
fi

# The local service: a run does not start one that `chalk decider up` never
# installed, and doctor says so.
decider_run PROJ-59 CHALK_DECIDER=shadow CHALK_DECIDER_URL=http://127.0.0.1:8471
check "a run does not start a local decider that was never installed" \
  test ! -e "$XDG_STATE_HOME/chalk/demo/runs/PROJ-59/io/startup/decider.log"
CHALK_DECIDER=shadow chalk doctor > "$tmp/doctor-decider1.log" 2>&1 || true
check "doctor: a local decider that was never installed is reported" \
  grep -q '^  --    local decider (CHALK_DECIDER=shadow): not installed, so nothing is asked; run: chalk decider up' \
    "$tmp/doctor-decider1.log"
CHALK_DECIDER=shadow CHALK_DECIDER_URL=http://decider.test chalk doctor > "$tmp/doctor-decider2.log" 2>&1 || true
check "doctor: a hosted decider is checked through its health endpoint" \
  grep -q '^  ok    decider at http://decider.test (CHALK_DECIDER=shadow)' "$tmp/doctor-decider2.log"
: > "$FAKE_STATE/decider.log"
CHALK_DECIDER=shadow CHALK_DECIDER_URL=http://decider.test FAKE_DECIDER_HEALTH=404 \
  chalk doctor > "$tmp/doctor-decider3.log" 2>&1 || true
check "doctor: a hosted decider without /health is checked with one question" \
  sh -c "grep -q '^  ok    decider at http://decider.test (CHALK_DECIDER=shadow)' '$tmp/doctor-decider3.log' &&
    test \"\$(grep -c '\"health\":{\"type\":\"noul\"' '$FAKE_STATE/decider.log')\" -eq 1"
check "doctor: off says so" grep -q '^  ok    decider off (CHALK_DECIDER=off)' "$tmp/doctor1.log"
CHALK_DECIDER_URL=http://decider.test chalk decider status > "$tmp/decider-status.log" 2>&1 ||
  { cat "$tmp/decider-status.log"; fail "chalk decider status"; }
check "chalk decider status reports a hosted decider's health" grep -q '^decider: healthy' "$tmp/decider-status.log"
CHALK_DECIDER_URL=http://decider.test FAKE_DECIDER_HEALTH=404 chalk decider status > "$tmp/decider-status2.log" 2>&1 ||
  { cat "$tmp/decider-status2.log"; fail "chalk decider status"; }
check "... and, without /health, through one question" grep -q '^decider: healthy' "$tmp/decider-status2.log"
if CHALK_DECIDER_URL=http://decider.test chalk decider up > "$tmp/decider-up.log" 2>&1; then
  fail "chalk decider up must refuse a decider it does not manage"
fi
check "chalk decider up manages only the local service, and installs nothing for another" \
  sh -c "grep -q \"manages only the local service\" '$tmp/decider-up.log' && ! grep -q installing '$tmp/decider-up.log'"

# Installed, a run starts the local service only once it can be asked
# something (#85): it holds several GB. Stand-ins for what `chalk decider
# up` leaves: strands-decider and chalk-embed, each recording that it
# started in $tmp/local-started; the fake curl answers for them.
mkdir -p "$tmp/uvbin" "$tmp/uvfake"
cat > "$tmp/uvbin/strands-decider" <<STUB
#!/usr/bin/env bash
echo decider >> "$tmp/local-started"
exec sleep 60
STUB
cat > "$tmp/uvfake/uv" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "tool dir") echo "$tmp/uvbin" ;;
  "run --script")
    while [ \$# -gt 0 ]; do [ "\$1" = --pidfile ] && echo "\$\$" > "\$2"; shift; done
    echo embed >> "$tmp/local-started"
    exec sleep 60 ;;
esac
STUB
chmod +x "$tmp/uvbin/strands-decider" "$tmp/uvfake/uv"
printf 'decider_model=StrandsAgents/strands-decider-2B-hobson-v19@0123456789abcdef\nbench_ms=100\n' \
  > "$XDG_STATE_HOME/chalk/decider/installed"
local_started() { grep -c '^decider' "$tmp/local-started" 2>/dev/null || true; }
local_run() {
  : > "$tmp/local-started"
  PATH="$tmp/uvfake:$PATH" decider_run "$@" CHALK_DECIDER=shadow CHALK_DECIDER_URL=http://127.0.0.1:8471 \
    FAKE_DECIDER_ANSWERS="stuck=0.97"
  for _ in $(seq 1 50); do [ "$(local_started)" -ge 1 ] && break; sleep 0.1; done
}

# Fewer resolved lessons than CHALK_DECIDER_MIN_LESSONS, so no lesson
# rerank; every loop passes, so no stuck question: nothing starts it.
local_run PROJ-64 FAKE_CLAUDE_MODE= CHALK_DECIDER_MIN_LESSONS=1000
check "too few lessons and no failed loop: a run never starts the local decider" \
  sh -c "grep -q 'final review: pass' '$tmp/PROJ-64.log' && test \"\$(grep -c . '$tmp/local-started')\" -eq 0"
check "... and says when it will" \
  grep -q '\[PROJ-64\] the local decider starts once a loop fails its rubric: until then it cannot be asked anything (lesson rerank needs 1000 resolved lessons, this machine has [0-9]*)' \
    "$tmp/PROJ-64.log"

# A loop fails: that starts it, once, in time for the next loop's question.
local_run PROJ-65 CHALK_DECIDER_MIN_LESSONS=1000
check "a run whose loop fails its rubric starts the local decider then" \
  sh -c "test $(local_started) -eq 1 &&
    awk '/loop 1 failed its rubric: starting the local decider for the stuck question/ { s = NR }
         /loop 2 \(retry\) started/ { l = NR } END { exit !(s && l && s < l) }' '$tmp/PROJ-65.log'"
check "... once, however many loops fail" \
  test "$(grep -c 'starting the local decider' "$tmp/PROJ-65.log")" -eq 1
check "... and the next loops' stuck questions are answered" \
  test "$(grep -o '"kind":"stuck","question":"[^"]*","answer":"yes"' "$tmp/PROJ-65.db" | wc -l)" -eq 2
chalk decider down >/dev/null 2>&1

# Enough lessons for rerank, which the first loop's prompt asks: a run
# starts it at run start, as before, though no loop fails.
local_run PROJ-66 FAKE_CLAUDE_MODE= CHALK_DECIDER_MIN_LESSONS=0
check "enough lessons for lesson rerank: a run starts the local decider at run start" \
  sh -c "test $(local_started) -eq 1 && test -e '$XDG_STATE_HOME/chalk/demo/runs/PROJ-66/io/startup/decider.log' &&
    ! grep -q 'starts once a loop fails' '$tmp/PROJ-66.log'"
chalk decider down >/dev/null 2>&1
rm -f "$XDG_STATE_HOME/chalk/decider/installed"
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
  rpg -c 'TRUNCATE lessons, runs, decisions'
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
  rpg -c 'TRUNCATE lessons, runs, decisions'
  seed other fp-1 "$error in the working tree" "rubric failed" LEXICAL-FIX
  seed other fp-2 "TypeError: Cannot read properties of undefined (reading 'map')" "rubric failed" WRONG-FIX
  recall_run PROJ-41
  check "recall: a lesson with a similar first error is recalled after a failure" \
    test "$(recalled PROJ-41):$(counted PROJ-41)" = "LEXICAL-FIX:0 1"

  # 2'. Evidence (evidence.sh): a lesson with a probe is recalled only once
  # proved, and then says what proved it; unproved and retired ones are not.
  rpg -c 'TRUNCATE lessons, runs, decisions'
  seed other fp-1 "$error in the working tree" "rubric failed" PROVED-FIX
  seed other fp-2 "$error in the working tree" "rubric failed" UNPROVED-FIX
  seed other fp-3 "$error in the working tree" "rubric failed" RETIRED-FIX
  rpg -c "UPDATE lessons SET probe = 'gcc --version', evidence = 'proved' WHERE lesson = 'PROVED-FIX'" \
      -c "UPDATE lessons SET probe = 'gcc --version', evidence = 'unproved' WHERE lesson = 'UNPROVED-FIX'" \
      -c "UPDATE lessons SET probe = 'gcc --version', evidence = 'retired' WHERE lesson = 'RETIRED-FIX'"
  recall_run PROJ-47
  check "recall: of lessons with probes, only the proved one is recalled" \
    test "$(recalled PROJ-47):$(counted PROJ-47)" = "PROVED-FIX:0 1"
  check "recall: a proved lesson says what proved it" \
    grep -qF '  Verified: `gcc --version` failed before this fix and passed after it' \
      "$XDG_STATE_HOME/chalk/demo/runs/PROJ-47/io/prompt.md"

  # 3. Legacy: a lesson from before fingerprints has no first_error, and is
  # matched on its signature. An unresolved one is never recalled.
  rpg -c 'TRUNCATE lessons, runs, decisions'
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
  rpg -c 'TRUNCATE lessons, runs, decisions'
  seed other fp-1 "$error" "rubric failed" SPEC-FIX
  seed other fp-2 "panic: runtime error: index out of range [3] with length 3" "rubric failed" NOT-IN-SPEC-FIX
  RECALL_CONTEXT="CI fails with $error after the last refactor; make the marker check pass." \
    recall_run PROJ-43 FAKE_CLAUDE_MODE=blocked
  check "recall: the first loop gets the lessons whose error the spec mentions" \
    test "$(recalled PROJ-43):$(counted PROJ-43)" = "SPEC-FIX:1"

  # 5. No match: no <lessons> block at all, and nothing counted.
  rpg -c 'TRUNCATE lessons, runs, decisions'
  seed other fp-1 "TypeError: Cannot read properties of undefined (reading 'map')" "rubric failed (exit 2)" NOPE-FIX
  recall_run PROJ-44
  check "recall: with no matching lesson the prompt has no <lessons> block" \
    sh -c "! grep -q '<lessons>' '$XDG_STATE_HOME/chalk/demo/runs/PROJ-44/io/prompt.md'"
  check "recall: with no matching lesson none are counted" test "$(counted PROJ-44)" = "0 0"

  # 6. Without fingerprints, recall matches the failure text, as it always did.
  rpg -c 'TRUNCATE lessons, runs, decisions'
  seed other "" "" "rubric failed (exit 1)
$error" TEXT-FIX
  recall_run PROJ-45 CHALK_FP_RULES=off
  check "recall: with CHALK_FP_RULES=off, lessons are matched on the failure text" \
    test "$(recalled PROJ-45):$(counted PROJ-45)" = "TEXT-FIX:0 1"

  # 7. Scope: a lesson scoped to its repository is recalled only there; a
  # general one, like one from before scopes, anywhere.
  rpg -c 'TRUNCATE lessons, runs, decisions'
  seed other fp-1 "$error" "rubric failed" OTHER-REPO-ONLY-FIX repo
  seed demo fp-2 "$error" "rubric failed" OWN-REPO-FIX repo
  seed other fp-3 "$error" "rubric failed" GENERAL-FIX general
  recall_run PROJ-46
  check "recall: a lesson scoped to another repository is not recalled; one scoped to this one is" \
    test "$(recalled PROJ-46):$(counted PROJ-46)" = "GENERAL-FIX OWN-REPO-FIX:0 2"
  # 8. With a decider (here the fake one) and CHALK_DECIDER_MIN_LESSONS
  # resolved lessons, recall adds lessons whose failure means the same
  # (semantic: pgvector, so Postgres 17 only), and the decider picks among
  # the candidates in one request per loop. LEX-FIX matches lexically.
  # SEM-FIX shares no words with the failure, but its embedding equals the
  # fake chalk-embed's (one-hot at 0); FAR-FIX's is orthogonal to it.
  rpg -c 'TRUNCATE lessons, runs, decisions'
  seed other fp-1 "$error in the working tree" "rubric failed" LEX-FIX
  seed other fp-2 "ImportError: cannot import name 'marker_guard' from 'demo.checks'" "rubric failed" SEM-FIX
  seed other fp-3 "KeyError: 'region'" "rubric failed" FAR-FIX
  pg17=0
  if [ "$(rpg -c "SELECT count(*) FROM pg_extension WHERE extname = 'vector'")" = 1 ]; then pg17=1; fi
  if [ "$pg17" = 1 ]; then
    onehot() { echo "(SELECT ('[' || string_agg(CASE WHEN i = $1 THEN '1' ELSE '0' END, ',' ORDER BY i) || ']')::vector FROM generate_series(1, 384) i)"; }
    rpg -c "UPDATE lessons SET embedding = $(onehot 1) WHERE lesson = 'SEM-FIX'" \
        -c "UPDATE lessons SET embedding = $(onehot 6) WHERE lesson = 'FAR-FIX'"
  fi
  lex="$(rpg -c "SELECT id FROM lessons WHERE lesson = 'LEX-FIX'")"
  sem="$(rpg -c "SELECT id FROM lessons WHERE lesson = 'SEM-FIX'")"
  decider_env=(CHALK_DECIDER_MIN_LESSONS=3 CHALK_DECIDER_URL=http://decider.test CHALK_EMBED_URL=http://embed.test
               FAKE_DECIDER_ANSWERS="lesson_$sem=0.97 lesson_$lex=0.93 lesson_*=0.2")
  # The fake decider is calibrated here, so that on may act (decider_calibration).
  calibrate http://decider.test fake-decider 0.95 46 0
  rm -f "$FAKE_STATE/curl.log"
  : > "$FAKE_STATE/decider.log"
  recall_run PROJ-60 CHALK_DECIDER=on "${decider_env[@]}"
  # reranks TICKET: the rerank decisions recorded with TICKET's loop calls,
  # and how many of them were used.
  reranks() {
    rpg -F ' ' -v ticket="$1" <<'SQL'
SELECT count(*) FILTER (WHERE d.kind = 'rerank'), count(*) FILTER (WHERE d.acted)
  FROM decisions d JOIN runs r ON r.id = d.call_id
 WHERE r.ticket = :'ticket' AND r.kind IN ('continue', 'retry');
SQL
  }
  if [ "$pg17" = 1 ]; then
    check "decider recall (Postgres 17): the decider's picks, most confident first, lexical and semantic" \
      test "$(recalled PROJ-60):$(counted PROJ-60)" = "SEM-FIX LEX-FIX:1 2"
    check "decider recall (Postgres 17): the query is embedded" grep -q 'http://embed.test/v1/embeddings' "$FAKE_STATE/curl.log"
    check "decider recall: every lesson asked about is recorded with its loop, and what was used" \
      test "$(reranks PROJ-60)" = "3 3"
  else
    check "decider recall (Postgres 16): no semantic step, so only the lexical candidate" \
      test "$(recalled PROJ-60):$(counted PROJ-60)" = "LEX-FIX:0 1"
    check "decider recall (Postgres 16): nothing is embedded" sh -c "! grep -q embed.test '$FAKE_STATE/curl.log'"
    check "decider recall: every lesson asked about is recorded with its loop, and what was used" \
      test "$(reranks PROJ-60)" = "1 1"
  fi
  check "decider recall: the lessons go to the decider in one request per loop" \
    test "$(grep -c '"lesson_' "$FAKE_STATE/decider.log")" -le 2
  check "decider recall: no lesson below the threshold is used" \
    sh -c "! grep -q 'FAR-FIX' '$XDG_STATE_HOME/chalk/demo/runs/PROJ-60/io/prompt.md'"

  # In shadow mode the decider is asked and recorded, and the prompt keeps
  # the lexical lessons, as with the decider off.
  rpg -c 'DELETE FROM lessons WHERE ticket <> $$SEED-1$$' -c 'TRUNCATE runs, decisions'
  recall_run PROJ-61 CHALK_DECIDER=shadow "${decider_env[@]}"
  check "decider recall in shadow mode: the prompt gets what recall without it gives" \
    test "$(recalled PROJ-61):$(counted PROJ-61)" = "LEX-FIX:0 1"
  check "decider recall in shadow mode: the answers are recorded, none used" \
    test "$(reranks PROJ-61 | cut -d' ' -f2)" = 0 -a "$(reranks PROJ-61 | cut -d' ' -f1)" -ge 1

  # A below-the-gate table: with fewer resolved lessons than
  # CHALK_DECIDER_MIN_LESSONS, the decider is not asked about lessons.
  rpg -c 'DELETE FROM lessons WHERE ticket <> $$SEED-1$$' -c 'TRUNCATE runs, decisions'
  : > "$FAKE_STATE/decider.log"
  recall_run PROJ-62 CHALK_DECIDER=on "${decider_env[@]}" CHALK_DECIDER_MIN_LESSONS=30
  check "decider recall waits for CHALK_DECIDER_MIN_LESSONS resolved lessons" \
    sh -c "test '$(recalled PROJ-62)' = LEX-FIX && ! grep -q '\"lesson_' '$FAKE_STATE/decider.log'"

  # Office hours writes the resolved lesson's embedding (Postgres 17).
  cd "$tmp/demo.worktrees/PROJ-62"
  git switch -q "$(git for-each-ref --format='%(refname:short)' 'refs/heads/detention/PROJ-62-*')"
  git rm -q BROKEN && git commit -q -m "remove the blocker"
  CHALK_DECIDER=shadow CHALK_DECIDER_URL=http://decider.test CHALK_EMBED_URL=http://embed.test FAKE_EMBED_INDEX=9 \
    chalk office-hours -m "the marker check needs no BROKEN file" > "$tmp/PROJ-62-oh.log" 2>&1 ||
    { cat "$tmp/PROJ-62-oh.log"; fail "office hours with a decider"; }
  if [ "$pg17" = 1 ]; then
    check "office hours writes the resolved lesson's embedding" \
      test "$(rpg -c "SELECT (embedding::real[])[10] FROM lessons WHERE ticket = 'PROJ-62'")" = 1
    check "... and those of resolved lessons that had none" \
      test "$(rpg -c "SELECT count(*) FROM lessons WHERE resolution IS NOT NULL AND embedding IS NULL")" = 0
  else
    check "office hours on Postgres 16 resolves the lesson, with no embedding" \
      test "$(rpg -c "SELECT count(*) FROM lessons WHERE ticket = 'PROJ-62' AND resolution IS NOT NULL")" = 1
  fi
  cd "$tmp/demo"

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
