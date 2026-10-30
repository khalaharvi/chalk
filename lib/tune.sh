# Ledger-gated tuning (docs/designs/ledger-tuning.md). chalk tune looks
# at a repository's own runs and says which harness settings to change,
# admitting a change only on evidence, by the kind of change:
#
#   stop-only      a lower CHALK_MAX_RETRIES can only stop runs earlier, so
#                  the ledger shows exactly what it would have done in every
#                  run (as certify.sh does for verdicts). Candidates are
#                  tested from the most cautious down, each at the full 5%,
#                  stopping at the first that fails (fixed-sequence testing,
#                  which needs no correction for testing several), each on
#                  its latest complete block of judged runs, as the gate is.
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
# an A/B test), whether that was drawn at random (only drawn runs are
# evidence), and how many extra loops it may use once (0 without).
RUN_ARM_PROMPTS="" RUN_ARM_DRAWN="" RUN_EXPLORE_LEFT=0 RUN_EXPLORING=""

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
# and ROOT/TUNE_AB_DIR present, a or b at even odds; a or b set by name,
# which is not recorded as an arm, since a run that did not draw it is no
# evidence. Exploration: with CHALK_EXPLORE true, CHALK_EXPLORE_RETRIES
# extra loops on a CHALK_EXPLORE_SHARE of runs, while there is room under
# the ceiling (tune_explore_room). Reports each arm.
tune_draw() {
  local root="$1" pct
  RUN_ARM_PROMPTS="" RUN_ARM_DRAWN="" RUN_EXPLORE_LEFT=0 RUN_EXPLORING=""
  case "${CHALK_PROMPT_AB:-false}" in
    a) RUN_ARM_PROMPTS=a ;;
    b)
      if [[ -d $root/$TUNE_AB_DIR ]]; then
        RUN_ARM_PROMPTS=b
      else
        warn "CHALK_PROMPT_AB=b, but there is no $TUNE_AB_DIR/; running on the usual prompts"
      fi ;;
    true)
      if [[ -d $root/$TUNE_AB_DIR ]]; then
        RUN_ARM_PROMPTS=a RUN_ARM_DRAWN=1
        if (( SRANDOM % 2 )); then RUN_ARM_PROMPTS=b; fi
      else
        warn "CHALK_PROMPT_AB=true, but there is no $TUNE_AB_DIR/ with the prompts to compare; running without the test"
      fi ;;
  esac
  [[ ${CHALK_EXPLORE:-false} == true ]] || return 0
  pct="${| tune_share_percent "$CHALK_EXPLORE_SHARE"; }"
  (( SRANDOM % 100 < pct )) || return 0
  tune_explore_room || return 0
  RUN_EXPLORE_LEFT="$CHALK_EXPLORE_RETRIES"
}

# tune_explore_room: true when one more explored loop, at most
# CHALK_BUDGET_USD, keeps what explored loops cost on this machine in the
# last TUNE_EXPLORE_DAYS days within CHALK_EXPLORE_BUDGET_USD. Checked when
# a run draws its arms and again before each extra loop. A database that
# cannot say counts as full: no exploring without a ceiling. Runs that
# explore at the same moment can each take the last room, so the ceiling
# can be passed by at most one loop per other parallel run.
tune_explore_room() {
  local spent
  spent="$(db_explore_spent "$TUNE_EXPLORE_DAYS" 2>/dev/null || true)"
  if [[ ! $spent =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    warn "CHALK_EXPLORE=true, but the spend on exploring could not be read, so this run does not explore"
    return 1
  fi
  if awk -v s="$spent" -v b="$CHALK_BUDGET_USD" -v c="$CHALK_EXPLORE_BUDGET_USD" 'BEGIN { exit !(s + b > c) }'; then
    warn "exploring has spent \$$spent in the last $TUNE_EXPLORE_DAYS days; one more loop, up to \$$CHALK_BUDGET_USD, would pass its ceiling (CHALK_EXPLORE_BUDGET_USD=$CHALK_EXPLORE_BUDGET_USD), so this run does not explore"
    return 1
  fi
}

# tune_judge DATA RETRIES BLOCK [MAX_WRONG] -> REPLY: tune's findings from DATA (as
# db_tune_data prints it), as one JSON object: retries (the stop-only test
# of each lower CHALK_MAX_RETRIES than RETRIES, and the one recommended),
# explore (what the extra loops rescued and cost) and ab (prompts a against
# b). CHECKPOINT_USD and SUCCESS_USD (globals TUNE_CHECKPOINT_USD and
# TUNE_SUCCESS_USD) price a checkpoint and a finished run. A lower setting
# passes as an early stop does (certify.sh): its latest complete block of
# BLOCK judged runs, and the block still filling, have at most MAX_WRONG
# (CERTIFY_MAX_WRONG) wrongful stops, and it saves money net of them.
tune_judge() {
  REPLY="$(certify_jq -c --argjson k "$2" --argjson need "$3" --argjson maxw "${4:-$CERTIFY_MAX_WRONG}" --argjson cp "${TUNE_CHECKPOINT_USD:-5}" \
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
      # The bounds are those of the latest complete block of $need runs, in
      # the order they ran, as certify.sh judges early stops: a fixed-size
      # test per block, not a bound re-checked every time tune is run.
      # Before a block is complete, they are those of every run, to read.
      | (($n / $need) | floor) as $blocks
      | (if $blocks > 0 then $f[($blocks - 1) * $need:$blocks * $need] else $f end) as $b
      | ($b | length) as $bn | ([$b[] | select(.wrong)] | length) as $bw
      | ([$f[$blocks * $need:][] | select(.wrong)] | length) as $ow
      | ([$b[] | select(.wrong | not) | .saved] | add // 0) as $bsaved
      | {retries: $j, judged: $n, wrong: $w, blocks: $blocks, block_wrong: $bw, open_wrong: $ow,
         lower: (cp_lower($bn - $bw; $bn; $alpha) | round4),
         saved: ($saved | round4),
         saved_lower: ([hoeffding_lower((if $bn > 0 then $bsaved / $bn else 0 end);
                         ([$b[].saved] | max // 0); $bn; $alpha / 2), 0] | max | round4),
         wrong_upper: (cp_upper($bw; $bn; $alpha / 2) | round4)};
    . as $runs
    | [range($k - 1; -1; -1) | . as $j | $runs | candidate($j)] as $c
    # Fixed sequence: most cautious first; stop at the first that fails.
    | (reduce $c[] as $x ({ok: true, pick: null};
         if .ok and $x.blocks > 0 and $x.block_wrong <= $maxw and $x.open_wrong <= $maxw and ($x.saved_lower - $cp * $x.wrong_upper) > 0
         then .pick = $x.retries else .ok = false end) | .pick) as $pick
    | ([$runs[] | select(.explore) | . as $r
        # Only the first extra loop: it is what one more retry would add.
        | [($r | loops)[] | select(.explored)][:1] as $x | select(($x | length) > 0)
        | {cost: $x[0].cost_usd, rescued: $x[0].progressed}]) as $e
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
                # Each side at alpha/2: a 95% interval, and at most a 5%
                # chance of recommending either arm wrongly.
                | ($range * ((2 / $alpha | log) / 2 * (1 / .ab.a + 1 / .ab.b) | sqrt)) as $m
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
      info "  keep CHALK_MAX_RETRIES=$CHALK_MAX_RETRIES: no lower setting clears the bar yet (a block of $CERTIFY_BLOCK judged runs with at most $CERTIFY_MAX_WRONG wrongful stop(s), and a positive net)"
    fi
    info ""
    info "More retries (spend-extending, judged only from exploring runs; CHALK_EXPLORE=$CHALK_EXPLORE):"
    explore="$(jq -r '.explore | "  \(.runs) run(s) explored, \(.rescued) rescued by the extra loops, for $\(.cost); rescue rate at least \(.rescue_lower), cost per run at most $\(.cost_upper)"' <<<"$judged")"
    info "$explore"
    if [[ -n $(jq -r '.explore.recommend // empty' <<<"$judged") ]]; then
      info "  recommend raising CHALK_MAX_RETRIES by one: the checkpoints the first extra loop rescued are worth more than it cost"
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
      # A last line without its newline would run into the new one.
      if [[ -s $file && $(tail -c 1 "$file") != "" ]]; then printf '\n' >> "$file"; fi
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
