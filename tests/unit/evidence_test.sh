#!/usr/bin/env bash
# lib/evidence.sh: the fix a blocker proposes and its rules, the probe's
# outcomes, the needs file, and the next step by kind of fix.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime repo config sandbox evidence agent run

export FAKE_STATE="$tmp/fake"
mkdir -p "$FAKE_STATE"
PATH="$CHALK_HOME/tests/fakes:$PATH"

# --- evidence_fix: what a blocked answer proposes, and what is kept --------

# result FIX_JSON: a call result whose blocked answer proposes FIX_JSON.
result() { jq -n --argjson fix "$1" '{structured_output: {status: "blocked", blocker: "b", fix: $fix}}' > "$tmp/result.json"; }
fix() { result "$1"; evidence_fix "$tmp/result.json"; printf '%s|%s\n' "$REPLY" "$EVIDENCE_FIX_PROBLEM"; }

check "an image fix keeps its kind, why, probe and image" \
  test "$(fix '{"kind":"image","why":"gcc not found","probe":"gcc --version","image":"apt-get install -y gcc","patch":"x"}')" = \
    '{"kind":"image","why":"gcc not found","probe":"gcc --version","image":"apt-get install -y gcc"}|'
check "a config fix keeps only the settings an agent may propose" \
  test "$(fix '{"kind":"config","why":"w","probe":"test -e .ready","config":{"CHALK_SETUP_CMD":"make deps","CHALK_TEST_CMD":"true","CHALK_RUBRIC_TIMEOUT":1200}}')" = \
    '{"kind":"config","why":"w","probe":"test -e .ready","config":{"CHALK_SETUP_CMD":"make deps","CHALK_RUBRIC_TIMEOUT":"1200"}}|config keys other than CHALK_SETUP_CMD CHALK_RUBRIC_TIMEOUT were dropped'
check "a spec fix keeps its patch and has no probe" \
  test "$(fix '{"kind":"spec","why":"150 ms","probe":"true","patch":"--- a\n+++ b"}')" = '{"kind":"spec","why":"150 ms","patch":"--- a\n+++ b"}|'
check "an image fix without a probe is dropped, saying why" \
  test "$(fix '{"kind":"image","why":"w"}')" = '|an image fix needs a probe'
check "an unknown kind is dropped" sh -c 'case "$1" in "|kind must be one of"*) exit 0;; esac; exit 1' _ "$(fix '{"kind":"retryable","why":"w"}')"
check "a probe of two lines is dropped" test "$(fix '{"kind":"config","why":"w","probe":"a\nb"}')" = '|the probe must be one line'
check "a probe that the needs file could not hold is dropped" \
  test "$(fix '{"kind":"image","why":"w","probe":"echo 1  # 2"}')" = '|the probe may not contain "  # "'
echo '{"structured_output":{"status":"blocked","blocker":"b"}}' > "$tmp/result.json"
evidence_fix "$tmp/result.json"
check "no fix proposed: nothing, and no problem" test -z "$REPLY$EVIDENCE_FIX_PROBLEM"

# --- evidence_probe: passed, failed, inconclusive ----------------------------

box="$FAKE_STATE/box"
mkdir -p "$box/work/repo"
probe() { local -A got; evidence_probe box "$1" got; printf '%s %s\n' "${got[outcome]}" "${got[exit]}"; }
check "a probe that exits 0 passed" test "$(probe true)" = "passed 0"
check "a probe that exits non-zero failed" test "$(probe 'exit 3')" = "failed 3"
check "a missing tool (127) failed: that is what the blocker is" test "$(probe no-such-tool-xyz)" = "failed 127"
check "a timeout is inconclusive" test "$(FAKE_PROBE_TIMEOUT=sleepy probe 'echo sleepy')" = "inconclusive 124"
declare -A out
evidence_probe box 'echo hello; exit 1' out
check "its output is kept" test "${out[output]}" = hello
EVIDENCE_OUTPUT_CHARS=5
evidence_probe box 'printf "%0100d" 0; exit 1' out
check "... up to EVIDENCE_OUTPUT_CHARS" test "${#out[output]}" -eq 5
EVIDENCE_OUTPUT_CHARS=2000

# --- the needs file ---------------------------------------------------------

check "a need line names the probe, its kind, ticket and lesson" \
  test "${| evidence_need_line 'gcc --version' image GO-5 12; }" = 'gcc --version  # image GO-5 lesson=12'
check "a probe the line could not hold gives no line" test -z "${| evidence_need_line 'a  # b' image T 1; }"
mkdir -p "$tmp/repo/.chalk"
cat > "$tmp/repo/.chalk/needs" <<'NEEDS'
# environment needs, saved by chalk office-hours
gcc --version  # image GO-5 lesson=12
python3 -c 'import yaml'  # config PY-3 lesson=7

echo "a # b"  # image T-1 lesson=3
not a need line
true  # spec T-2 lesson=1
NEEDS
needs=()
evidence_needs "$tmp/repo" needs 2>"$tmp/needs.err"
check "needs are read in order, the probe up to the last separator" \
  test "$(printf '%s\n' "${needs[@]}" | cut -f 1)" = "$(printf '%s\n' 'gcc --version' "python3 -c 'import yaml'" 'echo "a # b"')"
check "... with kind, ticket and lesson" test "$(printf '%s' "${needs[0]}" | cut -f 2-)" = "$(printf 'image\tGO-5\t12')"
check "a malformed line, or one of a kind with no probe, is skipped with a warning" \
  test "$(grep -c '^warning: skipping line' "$tmp/needs.err")" -eq 2
needs=(x)
evidence_needs "$tmp/nowhere" needs
check "no needs file: no needs" test "${#needs[@]}" -eq 0

# --- the next step, by kind of fix -------------------------------------------

RUN_TICKET=T-1 CHALK_DEFAULT_IMAGE="chalk-sandbox:local"
step() { RUN_FIX="$1"; CHALK_IMAGE="${2:-chalk-sandbox:local}"; run_fix_step; printf '%s\n' "$REPLY"; }
check "image fix, default image: build a repository image on it" \
  test "$(step '{"kind":"image","why":"w","probe":"gcc --version","image":"apt-get install -y gcc"}')" = \
    "build a repository image FROM chalk-sandbox:local that adds: apt-get install -y gcc; set CHALK_IMAGE to it in .chalk/config and commit; the probe is checked again in a fresh sandbox at office hours"
check "image fix, custom image: add it to that image" \
  sh -c 'case "$1" in "add to the image you build as CHALK_IMAGE (acme:1): apt-get install -y gcc;"*) exit 0;; esac; exit 1' _ \
    "$(step '{"kind":"image","why":"w","probe":"gcc --version","image":"apt-get install -y gcc"}' acme:1)"
check "config fix: the settings to set" \
  sh -c 'case "$1" in "set in .chalk/config and commit: CHALK_SETUP_CMD=make deps;"*) exit 0;; esac; exit 1' _ \
    "$(step '{"kind":"config","why":"w","probe":"p","config":{"CHALK_SETUP_CMD":"make deps"}}')"
check "spec fix: change the spec" test "$(step '{"kind":"spec","why":"w"}')" = "change specs/T-1.md as the agent suggests above, and commit"
check "no fix: what it always said" test "$(step '')" = "provide what the agent asked for above, such as a credential, access or a decision"

# --- evidence_fix_text: the fix in words -------------------------------------

check "the fix in words, one line per part" \
  test "${| evidence_fix_text '{"kind":"config","why":"deps missing","probe":"test -e x","config":{"CHALK_SETUP_CMD":"make"}}'; }" = \
    "$(printf 'kind: config\nwhy: deps missing\nprobe: test -e x\nconfig: CHALK_SETUP_CMD=make')"
