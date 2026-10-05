#!/usr/bin/env bash
# lib/run.sh: the prompt-set hash, the retry feedback and the recall input
# after a loop that made no progress.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log agent run

RUN_WT="$tmp/repo"
RUN_IO="$tmp/io"
CHALK_TEXTBOOK=.chalk/textbook.md
mkdir -p "$RUN_WT" "$RUN_IO"

# --- run_prompts_version: CHALK_FP_FEEDBACK is part of the prompt set ------

CHALK_FP_FEEDBACK=false
off="$(run_prompts_version)"
check "the prompts hash is stable" test "$(run_prompts_version)" = "$off"
CHALK_FP_FEEDBACK=true
on="$(run_prompts_version)"
check "the prompts hash changes when CHALK_FP_FEEDBACK flips" test "$on" != "$off"
check "the prompts hash is a short hex id either way" \
  test "$(printf '%s\n' "$off" "$on" | grep -Ecx '[0-9a-f]{8}')" -eq 2

# --- run_fp_feedback: T, E and a 20-line tail ------------------------------

for n in $(seq 1 40); do echo "line-$n"; done > "$RUN_IO/rubric.log"
echo "AssertionError: BROKEN exists" >> "$RUN_IO/rubric.log"
declare -A fp=(["tests"]=$'demo::a\ndemo::b' ["first_error"]="AssertionError: BROKEN exists"
               ["fingerprint"]="f00d")
feedback="${| run_fp_feedback "rubric failed (exit 1)" fp; }"
check "fp feedback starts with the reason" test "$(head -n 1 <<<"$feedback")" = "rubric failed (exit 1)"
check "fp feedback lists each failing test" \
  sh -c 'printf "%s\n" "$1" | grep -qx -- "- demo::a" && printf "%s\n" "$1" | grep -qx -- "- demo::b"' _ "$feedback"
check "fp feedback names the first error" grep -qx "first error: AssertionError: BROKEN exists" <<<"$feedback"
check "fp feedback keeps only the last 20 lines of output" \
  sh -c 'printf "%s\n" "$1" | grep -qx line-22 && ! printf "%s\n" "$1" | grep -qx line-21' _ "$feedback"

declare -A unknown=(["tests"]="UNKNOWN" ["first_error"]="")
feedback="${| run_fp_feedback "rubric failed (exit 2)" unknown; }"
check "fp feedback says when no failing tests or error were found" \
  sh -c 'printf "%s\n" "$1" | grep -q "^unknown" && printf "%s\n" "$1" | grep -qx "first error: none found"' _ "$feedback"

# --- run_recall: what the next loop recalls lessons by ---------------------

declare -A recall
run_recall recall "rubric failed (exit 1)
log" fp
check "after a fingerprinted failure, recall uses the fingerprint and E" \
  test "${recall[mode]}:${recall[fingerprint]}:${recall[first_error]}" = "failure:f00d:AssertionError: BROKEN exists"
check "after a fingerprinted failure, the query is E then T" \
  test "${recall[query]}" = $'AssertionError: BROKEN exists\ndemo::a\ndemo::b'

declare -A only_error=(["tests"]="UNKNOWN" ["first_error"]="panic: boom" ["fingerprint"]="beef")
run_recall recall "text" only_error
check "an UNKNOWN test set is left out of the query" test "${recall[query]}" = "panic: boom"

declare -A none=() generic=(["tests"]="UNKNOWN" ["first_error"]="" ["fingerprint"]="")
run_recall recall "rubric failed (exit 1)
tail" none
check "without a fingerprint, recall falls back to the failure text" \
  test "${recall[mode]}:${recall[query]}" = $'text:rubric failed (exit 1)\ntail'
check "without a fingerprint, no fingerprint is passed on" test -z "${recall[fingerprint]-}"
run_recall recall "fallback" generic
check "a fingerprint that says nothing falls back to the failure text" \
  test "${recall[mode]}:${recall[query]}" = "text:fallback"

# --- run_detention_branch: a free name, even within one second ------------

git init -q "$tmp/dt"
git -C "$tmp/dt" commit -q --allow-empty -m init
taken="detention/PROJ-1-$EPOCHSECONDS"
git -C "$tmp/dt" branch "$taken"
git -C "$tmp/dt" branch "$taken-2"
name="$(RUN_WT="$tmp/dt" RUN_TICKET=PROJ-1; run_detention_branch; echo "$REPLY")"
check "a detention branch name is never one that exists" \
  sh -c '! git -C "$1" show-ref -q --verify "refs/heads/$2"' _ "$tmp/dt" "$name"
check "a detention branch keeps the ticket and the detention/ prefix" \
  test "${name#detention/PROJ-1-}" != "$name"
