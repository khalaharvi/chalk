#!/usr/bin/env bash
# lib/tune.sh: the stop-only test of fewer retries (exact counterfactuals,
# fixed-sequence testing), what exploring rescued against its cost, the
# prompt A/B bound, drawing a run's arms under the spend ceiling, and the
# prompts a run in arm b reads.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log core/runtime db certify agent tune

fails() { ! "$@"; }

# runs N PATTERN [KEY=VALUE...]: prints N runs as db_tune_data does, each
# with one loop call per letter of PATTERN (P progressed, N did not), at
# $1.00 each, then a passing review when it ends in P (success) or a
# detention when it ends in N. X is an explored loop that did not progress,
# R one that did. KEY=VALUE sets fields of each run, such as explore=true.
runs() {
  local n="$1" pattern="$2" i
  shift 2
  for ((i = 1; i <= n; i++)); do
    jq -cn --arg p "$pattern" --arg id "r-$RANDOM-$i" --args '
      ($p | split("")) as $l
      | {run_id: $id, arm_prompts: null, explore: false,
         loops: [$l[] | {kind: "retry", progressed: (. == "P" or . == "R"), cost_usd: 1,
                          explored: (. == "X" or . == "R")}],
         success: ($l[-1] == "P" or $l[-1] == "R"), detained: ($l[-1] == "N" or $l[-1] == "X")}
      | .cost = ([.loops[].cost_usd] | add)
      | reduce ($ARGS.positional[] | split("=")) as $kv (.; .[$kv[0]] = (try ($kv[1] | fromjson) catch $kv[1]))' \
      "$@"
  done
}
judge() { tune_judge "$(cat | jq -cs .)" "${1:-2}" 46 1; jq -r "$2" <<<"$REPLY"; }

# --- fewer retries: exact, stop-only ------------------------------------------

check "46 runs that never progressed after failing: fewer retries would have saved, and both are certified" \
  test "$(runs 46 NNN | judge 2 '[.retries.candidates[] | "\(.retries):\(.judged):\(.wrong):\(.saved)"] | join(" ")')" = "1:46:0:46 0:46:0:92"
check "... and the fewest retries that clears the bar, tested most cautious first, is recommended" \
  test "$(runs 46 NNN | judge 2 .retries.recommend)" = 0
check "a run that progressed after the stop is a wrongful one" \
  test "$( { runs 46 NNN; runs 10 NNP; } | judge 2 '[.retries.candidates[] | "\(.retries):\(.wrong)"] | join(" ")')" = "1:10 0:10"
check "... and with ten wrongful in the block still filling, nothing is recommended, though the first block passed" \
  test "$( { runs 46 NNN; runs 10 NNP; } | judge 2 '"\(.retries.candidates[0] | "\(.blocks):\(.block_wrong):\(.open_wrong)") \(.retries.recommend)"')" = "1:0:10 null"
check "the bounds are the latest complete block's, not every run's: an old bad block does not count" \
  test "$( { runs 46 NNP; runs 46 NNN; } | judge 2 '"\(.retries.candidates[0] | "\(.blocks):\(.block_wrong):\(.lower)") \(.retries.recommend)"')" = "2:0:0.937 0"
# A run that fails once and then progresses is a wrongful stop for no
# retries at all, but one retry never stops it.
check "fixed sequence: the cautious setting passes, the bolder one fails, so the cautious one is recommended" \
  test "$( { runs 46 NNN; runs 6 NP; } | judge 2 '"\(.retries.candidates | map("\(.retries):\(.wrong)") | join(",")) \(.retries.recommend)"')" = "1:0,0:6 1"
check "too few judged runs: no recommendation" test "$(runs 45 NNN | judge 2 .retries.recommend)" = null
check "a run still going (neither detained nor finished) is not judged" \
  test "$(runs 3 NN detained=false | judge 2 '.retries.candidates[0].judged')" = 0
check "progress resets the count: NPN never has two failures in a row" \
  test "$(runs 1 NPNN | judge 2 '[.retries.candidates[] | .judged] | join(" ")')" = "1 1"

# --- more retries: only what exploring runs show ------------------------------

check "exploring runs: rescued when the first explored loop progressed, at that loop's cost" \
  test "$( { runs 30 NNNR explore=true; runs 10 NNNXX explore=true; } | judge 2 '.explore | "\(.runs) \(.rescued) \(.cost)"')" = "40 30 40"
check "... since one more retry adds only that loop: a rescue by the second explored loop is none" \
  test "$(runs 60 NNNXR explore=true | judge 2 '.explore | "\(.rescued) \(.recommend)"')" = "0 null"
check "... recommended when even the worst rescue rate pays for the worst cost" \
  test "$( { runs 30 NNNR explore=true; runs 10 NNNXX explore=true; } | judge 2 .explore.recommend)" = 3
check "... and not when few rescues come of many explored loops" \
  test "$( { runs 2 NNNR explore=true; runs 38 NNNXX explore=true; } | judge 2 .explore.recommend)" = null
check "exploring runs are left out of the stop-only test" \
  test "$(runs 46 NNNXX explore=true | judge 2 '.retries.candidates[0].judged')" = 0

# --- prompts a and b: randomized, with a 95% bound ----------------------------

check "b finishes far more often than a: adopt b" \
  test "$( { runs 60 NNN arm_prompts=a; runs 60 PP arm_prompts=b; } | judge 2 .ab.recommend)" = b
check "the same on both: no change" \
  test "$( { runs 30 PP arm_prompts=a; runs 30 PP arm_prompts=b; } | judge 2 '"\(.ab.diff) \(.ab.recommend)"')" = "0 null"
check "only one arm run: no comparison" test "$(runs 5 PP arm_prompts=a | judge 2 .ab.lower)" = null

# --- drawing a run's arms -----------------------------------------------------

draw() { tune_draw "$tmp" 2>"$tmp/draw.err"; printf '%s %s\n' "${RUN_ARM_PROMPTS:--}" "$RUN_EXPLORE_LEFT"; }
CHALK_EXPLORE=false CHALK_PROMPT_AB=false CHALK_EXPLORE_SHARE=1 CHALK_EXPLORE_RETRIES=2 CHALK_EXPLORE_BUDGET_USD=10.00
CHALK_BUDGET_USD=1.00
check "no experiment: no arm" test "$(draw)" = "- 0"
CHALK_PROMPT_AB=b
check "CHALK_PROMPT_AB=b without .chalk/prompts-b: the usual prompts, saying why" \
  sh -c 'test "$1" = "- 0" && grep -q "no .chalk/prompts-b/" "$2"' _ "$(draw)" "$tmp/draw.err"
mkdir -p "$tmp/.chalk/prompts-b"
check "CHALK_PROMPT_AB=b: every run on b, recorded as no arm, since none drew it" \
  test "$(draw; printf '%s' "${RUN_ARM_DRAWN:--}")" = "$(printf 'b 0\n-')"
rmdir "$tmp/.chalk/prompts-b"
CHALK_PROMPT_AB=true
check "CHALK_PROMPT_AB=true without .chalk/prompts-b: no test, saying why" \
  sh -c 'test "$1" = "- 0" && grep -q "no .chalk/prompts-b/" "$2"' _ "$(draw)" "$tmp/draw.err"
mkdir -p "$tmp/.chalk/prompts-b"
check "CHALK_PROMPT_AB=true: drawn, so recorded" test "$(draw >/dev/null; printf '%s' "$RUN_ARM_DRAWN")" = 1
check "CHALK_PROMPT_AB=true: a or b, at even odds" \
  test "$(for i in $(seq 1 60); do draw; done | cut -d' ' -f1 | sort -u | paste -sd ' ' -)" = "a b"
CHALK_PROMPT_AB=false CHALK_EXPLORE=true
db_explore_spent() { printf "%s\n" "${explore_spent-}"; }
explore_spent=2.50
check "exploring under its ceiling: the extra loops" test "$(draw)" = "- 2"
explore_spent=9.50
check "exploring where one more loop would pass the ceiling: none, saying why" \
  sh -c 'test "$1" = "- 0" && grep -q "would pass its ceiling (CHALK_EXPLORE_BUDGET_USD=10.00)" "$2"' _ "$(draw)" "$tmp/draw.err"
check "... and the room is checked again before each extra loop" fails tune_explore_room 2>/dev/null
explore_spent=8.00
check "... which there is while one more loop fits" tune_explore_room
explore_spent=""
check "a database that cannot say what was spent: no exploring" test "$(draw)" = "- 0"
explore_spent=0 CHALK_EXPLORE_SHARE=0
check "a share of 0: no run explores" test "$(draw)" = "- 0"

# --- the prompts of arm b -----------------------------------------------------

mkdir -p "$tmp/.chalk/prompts"
echo b > "$tmp/.chalk/prompts-b/continue.md"
echo ejected > "$tmp/.chalk/prompts/retry.md"
RUN_ARM_PROMPTS=b
check "arm b reads .chalk/prompts-b first" test "${| prompt_file "$tmp" continue; }" = "$tmp/.chalk/prompts-b/continue.md"
check "... then the repository's own, then the shipped ones" \
  test "${| prompt_file "$tmp" retry; }:${| prompt_file "$tmp" review; }" = "$tmp/.chalk/prompts/retry.md:$CHALK_HOME/share/prompts/review.md"
RUN_ARM_PROMPTS=a
check "arm a never reads .chalk/prompts-b" test "${| prompt_file "$tmp" continue; }" = "$CHALK_HOME/share/prompts/continue.md"
