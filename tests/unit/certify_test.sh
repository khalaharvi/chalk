#!/usr/bin/env bash
# lib/certify.sh: the exact bounds, the block rule and its constants, a
# verdict's judgement per model, the savings and net bounds, the holdout,
# and run_fp_mode, which decides whether a loop's verdict may act.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime db certify fingerprint agent run

fails() { ! "$@"; }

# --- the bounds: the same numbers as docs/paper/cp_bounds.py ---------------

bound() { "certify_$1" "$2" "$3"; printf '%s\n' "$REPLY"; }
check "18 right of 20: 95% sure of no more than 0.7174" test "$(bound lower 18 20)" = 0.7174
check "20 right of 20 is still only 0.8609" test "$(bound lower 20 20)" = 0.8609
check "29 right of 29 is the fewest for 0.90 with no error" \
  test "$(bound lower 29 29):$(bound lower 28 28)" = "0.9019:0.8985"
check "0 rubric failures in 51 runs: at most 5.7%" test "$(bound upper 0 51)" = 0.057
check "4 blockers in 51 runs: at most 17.06%" test "$(bound upper 4 51)" = 0.1706
check "nothing judged gives no bound" test "$(bound lower 0 0):$(bound upper 0 0)" = "0:1"

# The block rule's constants are the smallest that meet the target with
# one wrongful stop allowed.
at_target() { awk -v b="$1" -v t="$CERTIFY_TARGET_PERCENT" 'BEGIN { exit !(b * 100 >= t) }'; }
check "a block of 46 with 1 wrongful stop clears 90%" at_target "$(bound lower 45 46)"
check "... 2 wrongful stops in 46 do not" fails at_target "$(bound lower 44 46)"
check "... and 1 in a block of 45 does not either" fails at_target "$(bound lower 44 45)"
check "the constants are those" test "$CERTIFY_BLOCK:$CERTIFY_MAX_WRONG:$CERTIFY_ALPHA" = "46:1:0.05"

# --- a verdict's judgement, per verdict and agent model ---------------------

# A stand-in for the database: db_certify_verdicts prints $certify; with
# certify unset, the database does not answer.
db_certify_verdicts() {
  [[ -v certify ]] || return 1
  printf '%s\n' "$certify"
}
row() {
  jq -cn --arg v "$1" --arg m "$2" --argjson j "$3" --argjson c "$4" --argjson w "$5" --argjson b "$6" --argjson bw "$7" \
    '{verdict: $v, model: $m, judged: $j, correct: $c, wrong: ($j - $c), waiting: $w, blocks: $b,
      block_wrong: $bw, saved: ($c * 1.5), saved_max: 2, last: "2026-10-01T00:00:00Z"}'
}
# evidence ROWS...: the database holds ROWS, read afresh.
evidence() {
  if (( $# )); then certify="$(printf '%s\n' "$@" | jq -cs .)"; else unset certify; fi
  CERTIFY_READ=0 CERTIFY_WARNED=()
}
judged() {
  local -A cert
  local field out=()
  certify_verdict "$1" "$2" cert
  shift 2
  for field in "$@"; do out+=("${cert[$field]}"); done
  printf '%s\n' "${out[*]}"
}

evidence
check "with no database, a verdict's judgement is unknown" test "$(judged repeat m status)" = unknown
evidence "$(row repeat m 46 45 0 1 1)" "$(row no_change m 45 45 2 0 0)" "$(row repeat other 46 46 0 1 0)"
check "a block of 46 with one wrongful stop certifies" test "$(judged repeat m status judged wrong blocks)" = "certified 46 1 1"
check "45 judged, no block complete: not yet" test "$(judged no_change m status waiting)" = "uncertified 2"
check "a verdict never seen is not certified" test "$(judged deja_vu m status judged)" = "uncertified 0"
check "certified for one model is not certified for another" test "$(judged no_change other status)" = uncertified
evidence "$(row repeat m 50 46 0 1 0 | jq -c '.open_wrong = 4')"
check "a block still filling that already has too many wrongful stops demotes" \
  test "$(judged repeat m status block_wrong open_wrong)" = "uncertified 0 4"
evidence "$(row repeat m 46 45 0 1 1)" "$(row no_change m 45 45 2 0 0)" "$(row repeat other 46 46 0 1 0)"
note() { local -A cert; certify_verdict "$1" "$2" cert; printf '%s\n' "${| certify_note cert; }"; }
check "... and says so in words" test "$(note no_change m)" = \
  "no_change for m is not certified: 45 shadow run(s) judged, 0 wrongful stop(s), 2 not settled yet; it needs a block of 46 judged runs with at most 1 wrongful stop(s), which shows it right at least 90% of the time, 95% sure"
check "a certified verdict in words" test "$(note repeat m)" = \
  "repeat for m is certified: 46 shadow run(s) judged, 1 wrongful stop(s); the latest block of 46 had 1 wrongful"

# --- certify_judge: what it saved per firing, 95% sure, and the net --------

CHALK_MAX_RETRIES=2 CHALK_BUDGET_USD=1.00
certify_judge "$(row repeat m 46 45 0 1 1 | jq -cs .)" 5
judge() { jq -r ".[0] | $1" <<<"$REPLY"; }
# mean 45 * 1.5 / 46 = 1.4674; range 2 (two loops at $1); Hoeffding at
# alpha / 2: 1.4674 - 2 * sqrt(ln(40) / 92) = 1.0669.
check "saved per firing: the mean, and its Hoeffding lower bound" test "$(judge '"\(.saved_mean) \(.saved_lower)"')" = "1.4674 1.0669"
# shellcheck disable=SC2016
check "the wrongful rate's upper bound takes the other half of the error" \
  test "$(judge .wrong_upper)" = "$(certify_jq -rn 'cp_upper(1; 46; $alpha / 2) | round4')"
check "net is what it saved less \$5 per wrongful stop at that bound" \
  test "$(judge .net)" = "$(jq -rn --argjson s "$(judge .saved_lower)" --argjson w "$(judge .wrong_upper)" '$s - 5 * $w | . * 10000 | round / 10000')"
check "the lower bound over every judged run is reported too" test "$(judge .lower)" = "$(bound lower 45 46)"

# --- the holdout ------------------------------------------------------------

draws() { local i n=0; for i in $(seq 1 200); do n=$((n + ${| certify_holdout; })); done; printf '%s\n' "$n"; }
CHALK_HOLDOUT=0
check "CHALK_HOLDOUT=0: no run is a holdout" test "$(draws)" -eq 0
CHALK_HOLDOUT=1
check "CHALK_HOLDOUT=1: every run is" test "$(draws)" -eq 200
CHALK_HOLDOUT=0.5
check "CHALK_HOLDOUT=0.5: about half are" sh -c "n=$(draws); test \$n -gt 60 && test \$n -lt 140"
check "the share is read as a whole percentage" \
  test "$(CHALK_HOLDOUT=0.1 certify_holdout_percent; printf '%s' "$REPLY") $(CHALK_HOLDOUT=0.07 certify_holdout_percent; printf '%s' "$REPLY")" = "10 7"

# --- run_fp_mode: whether a loop's verdict acts -----------------------------

RUN_TICKET=T-1 RUN_HOLDOUT=0 CHALK_HOLDOUT=0.10
mode() { REPLY=""; run_fp_mode "$1" "$2" >"$tmp/mode.out" 2>"$tmp/mode.err"; printf '%s\n' "$REPLY"; }
evidence "$(row repeat m 46 45 0 1 1)"
CHALK_FP_RULES=shadow
check "shadow: every verdict is recorded only" test "$(mode repeat m)" = shadow
CHALK_FP_RULES=off
check "off is off" test "$(mode repeat m)" = off
CHALK_FP_RULES=on
check "on: a certified stopping verdict acts" test "$(mode repeat m)" = on
check "on: a verdict that does not stop is recorded in shadow mode" test "$(mode spinning m)" = shadow
evidence "$(row repeat m 46 45 0 1 1)"
check "on: an uncertified stopping verdict is held to shadow" test "$(mode no_change m)" = shadow
check "... saying why" grep -q '^warning: CHALK_FP_RULES=on records no_change in shadow mode only: no_change for m is not certified: 0 shadow run(s) judged' "$tmp/mode.err"
evidence "$(row repeat m 46 45 0 1 1)"
check "... once per run" test "$({ run_fp_mode no_change m; run_fp_mode no_change m; } 2>&1 | grep -c '^warning')" -eq 1
check "on: certified for one model, held for another" test "$(mode repeat other)" = shadow
evidence
check "on: with no database, held to shadow" test "$(mode repeat m)" = shadow
evidence "$(row repeat m 46 45 0 1 1)"
RUN_HOLDOUT=1
check "on, in a holdout run: a certified verdict is recorded, not acted on" test "$(mode repeat m)" = shadow
check "... and the run log says so" grep -q '^\[T-1\] this run is a holdout (CHALK_HOLDOUT=0.10)' "$tmp/mode.out"
RUN_HOLDOUT=0

# --- run_call_model: the stratum a call is judged in ------------------------

echo '{"modelUsage":{"claude-a":{"costUSD":0.1},"claude-b":{"costUSD":0.4}}}' > "$tmp/result.json"
check "the model that did most of the call's work" test "${| run_call_model "$tmp/result.json"; }" = claude-b
CHALK_MODEL=""
check "... else CHALK_MODEL, else default" \
  test "${| run_call_model "$tmp/none.json"; }:${| CHALK_MODEL=opus run_call_model "$tmp/none.json"; }" = "default:opus"
