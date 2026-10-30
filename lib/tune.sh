# Ledger-gated tuning (docs/designs/ledger-tuning.md). chalk tune looks
# at a repository's own runs and says which harness settings to change,
# admitting a change only on evidence, by the kind of change:
#
#   stop-only      a lower CHALK_MAX_RETRIES can only stop runs earlier, so
#                  the ledger shows exactly what it would have done in every
#                  run (as certify.sh does for verdicts). Candidates are
#                  tested from the most cautious down, each at the full 5%,
#                  stopping at the first that fails (fixed-sequence testing,
#                  which needs no correction for testing several).
#   spend-extending  more retries cannot be judged from runs that stopped:
#                  the loops after the stop never ran. With CHALK_EXPLORE=true
#                  a random share of runs get CHALK_EXPLORE_RETRIES more loops
#                  once, under a 30-day spend ceiling (CHALK_EXPLORE_BUDGET_USD),
#                  and tune weighs what those loops rescued against their cost.
#   trajectory     a prompt change alters what the agent does, so only a
#                  randomized comparison judges it: with CHALK_PROMPT_AB=true a
#                  run draws the prompts in .chalk/prompts-b/ half the time,
#                  and tune adopts them only when a 95% lower bound on their
#                  advantage is above zero.
#
# Nothing here touches the rubric, the tests or the gates on early stops.

TUNE_AB_DIR=.chalk/prompts-b
TUNE_DAYS=90
TUNE_EXPLORE_DAYS=30

# The arms of this run (tune_draw): a or b for the prompts (empty without
# an A/B test), and how many extra loops it may use once (0 without).
RUN_ARM_PROMPTS="" RUN_EXPLORE_LEFT=0 RUN_EXPLORING=""

# tune_share_percent SHARE -> REPLY: a share from 0 to 1, to two places, as
# a whole percentage; 0 for anything else.
tune_share_percent() {
  local frac
  REPLY=0
  if [[ ${1:-} =~ ^([01])(\.([0-9]{1,2}))?$ ]]; then
    frac="${BASH_REMATCH[3]}00"
    REPLY=$((10#${BASH_REMATCH[1]} * 100 + 10#${frac:0:2}))
    (( REPLY <= 100 )) || REPLY=100
  fi
}

# tune_draw ROOT: draws this run's arms. Prompts: with CHALK_PROMPT_AB true
# and ROOT/TUNE_AB_DIR present, a or b at even odds; a or b set by name.
# Exploration: with CHALK_EXPLORE true, CHALK_EXPLORE_RETRIES extra loops on
# a CHALK_EXPLORE_SHARE of runs, unless the last TUNE_EXPLORE_DAYS days'
# extra loops already cost CHALK_EXPLORE_BUDGET_USD (a database that cannot
# say counts as spent: no exploring without a ceiling). Reports each arm.
tune_draw() {
  local root="$1" spent pct
  RUN_ARM_PROMPTS="" RUN_EXPLORE_LEFT=0 RUN_EXPLORING=""
  case "${CHALK_PROMPT_AB:-false}" in
    a|b) RUN_ARM_PROMPTS="$CHALK_PROMPT_AB" ;;
    true)
      if [[ -d $root/$TUNE_AB_DIR ]]; then
        RUN_ARM_PROMPTS=a
        if (( SRANDOM % 2 )); then RUN_ARM_PROMPTS=b; fi
      else
        warn "CHALK_PROMPT_AB=true, but there is no $TUNE_AB_DIR/ with the prompts to compare; running without the test"
      fi ;;
  esac
  [[ ${CHALK_EXPLORE:-false} == true ]] || return 0
  pct="${| tune_share_percent "$CHALK_EXPLORE_SHARE"; }"
  (( SRANDOM % 100 < pct )) || return 0
  spent="$(db_explore_spent "$TUNE_EXPLORE_DAYS" 2>/dev/null || true)"
  if [[ ! $spent =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    warn "CHALK_EXPLORE=true, but the spend on exploring could not be read, so this run does not explore"
    return 0
  fi
  if awk -v s="$spent" -v c="$CHALK_EXPLORE_BUDGET_USD" 'BEGIN { exit !(s >= c) }'; then
    warn "exploring has spent \$$spent in the last $TUNE_EXPLORE_DAYS days, at its ceiling (CHALK_EXPLORE_BUDGET_USD=$CHALK_EXPLORE_BUDGET_USD); this run does not explore"
    return 0
  fi
  RUN_EXPLORE_LEFT="$CHALK_EXPLORE_RETRIES"
}

# tune_judge DATA RETRIES BLOCK -> REPLY: tune's findings from DATA (as
# db_tune_data prints it), as one JSON object: retries (the stop-only test
# of each lower CHALK_MAX_RETRIES than RETRIES, and the one recommended),
# explore (what the extra loops rescued and cost) and ab (prompts a against
# b). CHECKPOINT_USD and SUCCESS_USD (globals TUNE_CHECKPOINT_USD and
# TUNE_SUCCESS_USD) price a checkpoint and a finished run; a stop needs at
# least BLOCK judged runs before it is tested.
tune_judge() {
  REPLY="$(certify_jq -c --argjson k "$2" --argjson need "$3" --argjson cp "${TUNE_CHECKPOINT_USD:-5}" \
             --argjson win "${TUNE_SUCCESS_USD:-10}" '
    def loops: [.loops[] | select(.kind == "continue" or .kind == "retry" or .kind == "fix-review")];
    # The loop index at which j+1 non-progress loops in a row are reached.
    def fires($j): reduce (loops | to_entries[]) as $e ({run: 0, at: null};
        if .at != null then .
        elif $e.value.progressed then .run = 0
        else .run += 1 | if .run >= $j + 1 then .at = $e.key else . end end) | .at;
    def candidate($j):
      [.[] | select(.explore | not) | . as $r | ($r | fires($j)) as $at | select($at != null)
       | ($r | loops) as $l | {saved: ([$l[$at + 1:][].cost_usd] | add // 0),
                               wrong: ([$l[$at + 1:][] | select(.progressed)] | length > 0),
                               judged: ($r.detained or $r.success or ([$l[$at + 1:][] | select(.progressed)] | length > 0))}
       | select(.judged)] as $f
      | ($f | length) as $n | ([$f[] | select(.wrong)] | length) as $w
      | ([$f[] | select(.wrong | not) | .saved] | add // 0) as $saved
      | {retries: $j, judged: $n, wrong: $w, lower: (cp_lower($n - $w; $n; $alpha) | round4),
         saved: ($saved | round4),
         saved_lower: ([hoeffding_lower((if $n > 0 then $saved / $n else 0 end);
                         ([$f[].saved] | max // 0); $n; $alpha / 2), 0] | max | round4),
         wrong_upper: (cp_upper($w; $n; $alpha / 2) | round4)};
    . as $runs
    | [range($k - 1; -1; -1) | . as $j | $runs | candidate($j)] as $c
    # Fixed sequence: most cautious first; stop at the first that fails.
    | (reduce $c[] as $x ({ok: true, pick: null};
         if .ok and $x.judged >= $need and $x.lower >= 0.9 and ($x.saved_lower - $cp * $x.wrong_upper) > 0
         then .pick = $x.retries else .ok = false end) | .pick) as $pick
    | ([$runs[] | select(.explore) | . as $r
        | [($r | loops)[] | select(.explored)] as $x | select(($x | length) > 0)
        | {cost: ([$x[].cost_usd] | add // 0), rescued: ([$x[] | select(.progressed)] | length > 0)}]) as $e
    | ($e | length) as $en | ([$e[] | select(.rescued)] | length) as $er
    | ([$e[].cost] | add // 0) as $ecost
    | ([$runs[] | select(.arm_prompts == "a" or .arm_prompts == "b") | select(.success or .detained)
        | {arm: .arm_prompts, value: ((if .success then $win else 0 end) - .cost)}]) as $ab
    | ([$ab[] | select(.arm == "a") | .value]) as $va | ([$ab[] | select(.arm == "b") | .value]) as $vb
    | (([$runs[].cost] | max // 0) + $win) as $range
    | {retries: {current: $k, candidates: $c, recommend: $pick},
       explore: {runs: $en, rescued: $er, cost: ($ecost | round4),
                 rescue_lower: (cp_lower($er; $en; $alpha / 2) | round4),
                 cost_upper: ([if $en > 0 then $ecost / $en + ([$e[].cost] | max // 0) * ((1 / ($alpha / 2) | log) / (2 * $en) | sqrt) else 0 end, 0] | max | round4),
                 recommend: null}
       , ab: {a: ($va | length), b: ($vb | length),
              mean_a: (if ($va | length) > 0 then ($va | add) / ($va | length) else 0 end | round4),
              mean_b: (if ($vb | length) > 0 then ($vb | add) / ($vb | length) else 0 end | round4),
              range: ($range | round4)}}
    | .explore.recommend = (if .explore.runs > 0 and (.explore.rescue_lower * $cp - .explore.cost_upper) > 0
                            then $k + 1 else null end)
    | .ab += (if .ab.a > 0 and .ab.b > 0 then
                (.ab.mean_b - .ab.mean_a) as $d
                | ($range * ((1 / $alpha | log) / 2 * (1 / .ab.a + 1 / .ab.b) | sqrt)) as $m
                | {diff: ($d | round4), lower: ($d - $m | round4), upper: ($d + $m | round4)}
                | . + {recommend: (if .lower > 0 then "b" elif .upper < 0 then "a" else null end)}
              else {diff: null, lower: null, upper: null, recommend: null} end)' <<<"${1:-[]}" 2>/dev/null || true)"
}

# cmd_tune [--json] [--days N] [--checkpoint-usd N] [--success-usd N] [--apply]
cmd_tune() {
  local json=0 apply=0 days="$TUNE_DAYS" root data judged pick explore ab file
  TUNE_CHECKPOINT_USD=5 TUNE_SUCCESS_USD=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --apply) apply=1 ;;
      --days) days="${2:-}"; shift ;;
      --checkpoint-usd) TUNE_CHECKPOINT_USD="${2:-}"; shift ;;
      --success-usd) TUNE_SUCCESS_USD="${2:-}"; shift ;;
      *) die "usage: chalk tune [--json] [--days N] [--checkpoint-usd N] [--success-usd N] [--apply]" ;;
    esac
    shift
  done
  [[ $days =~ ^[1-9][0-9]*$ ]] || die "--days takes a whole number of days (got '$days')"
  [[ $TUNE_CHECKPOINT_USD =~ ^[0-9]+(\.[0-9]+)?$ && $TUNE_SUCCESS_USD =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
    die "--checkpoint-usd and --success-usd take a number of dollars"
  need git docker jq
  root="${| repo_root; }"
  load_config "$root"
  db_up
  data="$(db_tune_data "$days")" || die "could not read this repository's runs from the telemetry database"
  judged="${| tune_judge "$data" "$CHALK_MAX_RETRIES" "$CERTIFY_BLOCK"; }"
  [[ -n $judged ]] || die "could not judge this repository's runs"
  if (( json )); then
    jq --arg days "$days" '. + {days: ($days | tonumber)}' <<<"$judged"
  else
    info "Tuning from this repository's runs of the last $days days (95% bounds; a checkpoint priced at \$$TUNE_CHECKPOINT_USD, a finished run at \$$TUNE_SUCCESS_USD):"
    info ""
    info "Fewer retries (stop-only, judged exactly from every run; CHALK_MAX_RETRIES=$CHALK_MAX_RETRIES now):"
    jq -r --argjson need "$CERTIFY_BLOCK" '
      (["retries", "judged", "wrongful", "lower", "saved", "saved/run"] | @tsv),
      (.retries.candidates[] | [.retries, .judged, .wrong, .lower, "$\(.saved)", "$\(.saved_lower)"] | map(tostring) | @tsv)' \
      <<<"$judged" | dashboard_columns
    pick="$(jq -r '.retries.recommend // empty' <<<"$judged")"
    if [[ -n $pick ]]; then
      info "  recommend CHALK_MAX_RETRIES=$pick: right at least 90% of the time, 95% sure, and it saves money net of wrongful stops"
    else
      info "  keep CHALK_MAX_RETRIES=$CHALK_MAX_RETRIES: no lower setting clears the bar yet ($CERTIFY_BLOCK judged runs, 90% right, positive net)"
    fi
    info ""
    info "More retries (spend-extending, judged only from exploring runs; CHALK_EXPLORE=$CHALK_EXPLORE):"
    explore="$(jq -r '.explore | "  \(.runs) run(s) explored, \(.rescued) rescued by the extra loops, for $\(.cost); rescue rate at least \(.rescue_lower), cost per run at most $\(.cost_upper)"' <<<"$judged")"
    info "$explore"
    if [[ -n $(jq -r '.explore.recommend // empty' <<<"$judged") ]]; then
      info "  recommend raising CHALK_MAX_RETRIES by one: the rescued checkpoints are worth more than the extra loops cost"
    else
      info "  no change: the evidence does not show more retries paying"
    fi
    info ""
    info "Prompts a against b (randomized; CHALK_PROMPT_AB=$CHALK_PROMPT_AB):"
    ab="$(jq -r '.ab | "  \(.a) run(s) on a, \(.b) on b; value per run a $\(.mean_a), b $\(.mean_b)" + (if .diff != null then "; b - a = \(.diff), 95% between \(.lower) and \(.upper)" else "" end)' <<<"$judged")"
    info "$ab"
    case "$(jq -r '.ab.recommend // empty' <<<"$judged")" in
      b) info "  recommend adopting $TUNE_AB_DIR/ (chalk tune --apply moves it into .chalk/prompts/)" ;;
      a) info "  recommend dropping $TUNE_AB_DIR/: the current prompts do better" ;;
      *) info "  no change: the difference is not clear yet" ;;
    esac
  fi
  (( apply )) || return 0
  file="$root/.chalk/config"
  pick="$(jq -r '.retries.recommend // empty' <<<"$judged")"
  if [[ -n $pick ]]; then
    if grep -q '^CHALK_MAX_RETRIES=' "$file" 2>/dev/null; then
      sed -i.bak "s/^CHALK_MAX_RETRIES=.*/CHALK_MAX_RETRIES=$pick/" "$file" && rm -f "$file.bak"
    else
      printf 'CHALK_MAX_RETRIES=%s\n' "$pick" >> "$file"
    fi
    info "applied: CHALK_MAX_RETRIES=$pick in .chalk/config; commit it"
  fi
  if [[ $(jq -r '.ab.recommend // empty' <<<"$judged") == b ]]; then
    mkdir -p "$root/.chalk/prompts"
    cp "$root/$TUNE_AB_DIR"/*.md "$root/.chalk/prompts/"
    rm -rf "${root:?}/$TUNE_AB_DIR"
    info "applied: $TUNE_AB_DIR/ moved into .chalk/prompts/; commit it"
  fi
}
