# The report card: a single self-contained HTML page built from the local
# telemetry database. Nothing is served and nothing leaves the machine.

# dashboard_ledger_note REACH -> REPLY: why the verdict ledger may count no
# detained run, from REACH (as db_decider_reach prints it): how many loops
# failed their rubric or passed with no checkpoint ticked, the only loops a
# stopping verdict can judge, and how many runs ended in a blocker
# instead. Empty when REACH is empty or has no loops.
dashboard_ledger_note() {
  local days="" loops=0 failed=0 unticked=0 blocked=0 n
  REPLY=""
  [[ -n ${1:-} ]] || return 0
  IFS=$'\t' read -r days loops failed unticked blocked < <(jq -r '
    [.days, .loops, .failed, .unticked, .blocked_runs] | map(tostring) | @tsv' <<<"$1" 2>/dev/null) || true
  for n in "$days" "$loops" "$failed" "$unticked" "$blocked"; do [[ $n =~ ^[0-9]+$ ]] || return 0; done
  (( loops > 0 )) || return 0
  if (( failed + unticked == 0 )); then
    REPLY="No loop failed its rubric or passed without ticking a checkpoint in the last $days days ($loops loop(s)), so no verdict could stop a run"
    if (( blocked > 0 )); then
      REPLY+="; agents that could not progress reported a blocker instead ($blocked run(s))"
    fi
  else
    REPLY="Of $loops loop(s) in the last $days days, $failed failed their rubric and $unticked passed without ticking a checkpoint, but none of their runs was detained in shadow mode"
  fi
  REPLY+="."
}

cmd_dashboard() {
  local days=30 open_it=1 output=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="${2:-}"; shift ;;
      --output|-o) output="${2:-}"; shift ;;
      --no-open) open_it=0 ;;
      *) die "usage: chalk dashboard [--days N] [--output FILE] [--no-open]" ;;
    esac
    shift
  done
  case "$days" in ''|*[!0-9]*) die "--days takes a whole number" ;; esac
  # For CHALK_DECIDER_THRESHOLD, which the calibration gate is judged at.
  load_config "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

  need docker jq
  db_up
  : "${output:=${XDG_STATE_HOME:-$HOME/.local/state}/chalk/dashboard.html}"
  mkdir -p "$(dirname "$output")"

  local data line
  local -a page
  data="$(db_dashboard "$days")" || die "could not read telemetry for the dashboard"
  jq -e . >/dev/null 2>&1 <<<"$data" || die "could not read telemetry for the dashboard"
  # The calibration gate, judged as runs judge it (decider_calibration_judge),
  # over every answer recorded, not only this window's.
  # The verdicts are judged by the same bar (certify_judge).
  data="$(jq -c --argjson gate "${| decider_calibration_judge "${| decider_calibration_data; }"; }" \
             --argjson certify "${| certify_judge "${| certify_data; }"; }" \
             --arg threshold "$CHALK_DECIDER_THRESHOLD" --argjson block "$CERTIFY_BLOCK" \
             --argjson max_wrong "$CERTIFY_MAX_WRONG" --argjson pct "$CERTIFY_TARGET_PERCENT" '
    .decider.gate = $gate
    | .decider.gate_rules = {threshold: ($threshold | tonumber), block: $block, max_wrong: $max_wrong, percent: $pct}
    | .certify = {verdicts: $certify, rules: {block: $block, max_wrong: $max_wrong, percent: $pct}}' <<<"$data")" ||
    die "could not read telemetry for the dashboard"
  # Why the decider panel and the verdict ledger are empty, when they are.
  local reach decider_note=""
  reach="$(db_decider_reach "$days" 2>/dev/null || true)"
  jq -e '(.loops | type) == "number"' >/dev/null 2>&1 <<<"$reach" || reach=""
  if [[ -n $reach && $CHALK_DECIDER != off ]]; then
    decider_note="${| decider_quiet_note "$reach"; }"
    [[ -z $decider_note ]] || decider_note="0 questions in the last $days days: $decider_note."
  fi
  data="$(jq -c --arg decider "$decider_note" --arg ledger "${| dashboard_ledger_note "$reach"; }" '
    .empty = {decider: $decider, ledger: $ledger}' <<<"$data")" ||
    die "could not read telemetry for the dashboard"
  # "</" is escaped so that no stored text can close the page's script tag.
  data="${data//<\//<\\/}"

  # The data replaces the template line holding the /*CHALK_DATA*/ marker.
  mapfile -t page < "$CHALK_HOME/share/dashboard.html"
  for line in "${page[@]}"; do
    if [[ $line == *'/*CHALK_DATA*/'* ]]; then line="$data"; fi
    printf '%s\n' "$line"
  done > "$output"
  info "report card for the last $days days: $output"

  [ "$open_it" -eq 1 ] || return 0
  if command -v open >/dev/null 2>&1; then open "$output"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$output" >/dev/null 2>&1 || true
  fi
}

# dashboard_columns: prints tab-separated lines from stdin as aligned
# columns, indented by two spaces.
dashboard_columns() {
  awk -F '\t' '
    { for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > width[i]) width[i] = length($i) }
      if (NF > cols) cols = NF }
    END { for (r = 1; r <= NR; r++) {
            line = ""
            for (i = 1; i < cols; i++) line = line sprintf("%-" width[i] "s  ", cell[r, i])
            print "  " line cell[r, cols] } }'
}

# chalk certify: what the shadow runs show about every decision that may
# stop a run early, against the bar it must clear before it acts (certify.sh):
# each stopping verdict, and their union, per agent model; and each decider
# at CHALK_DECIDER_THRESHOLD. Read from the local database; nothing leaves
# the machine. --false-stop-usd prices a wrongful stop for the net bound.
cmd_certify() {
  local json=0 usd=5 data deciders
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --false-stop-usd) usd="${2:-}"; shift ;;
      # Only for reading: the gate always judges every repository's runs.
      --repos) CERTIFY_REPOS="${2:-}"; shift ;;
      *) die "usage: chalk certify [--json] [--false-stop-usd N] [--repos PREFIX]" ;;
    esac
    shift
  done
  [[ $usd =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--false-stop-usd takes a number of dollars (got '$usd')"
  load_config "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  need docker jq
  db_up

  data="${| certify_data; }"
  [[ -n $data ]] || die "could not read the shadow runs from the telemetry database"
  data="${| certify_judge "$data" "$usd"; }"
  deciders="${| decider_calibration_judge "${| decider_calibration_data; }"; }"
  deciders="$(certify_jq -c 'map(. + {lower: (cp_lower(.correct; .judged; $alpha) | round4)})' <<<"$deciders")"
  if (( json )); then
    jq -n --argjson verdicts "$data" --argjson deciders "$deciders" --argjson usd "$usd" \
      --argjson block "$CERTIFY_BLOCK" --argjson max_wrong "$CERTIFY_MAX_WRONG" \
      --argjson pct "$CERTIFY_TARGET_PERCENT" --arg threshold "$CHALK_DECIDER_THRESHOLD" '
      {rules: {block: $block, max_wrong: $max_wrong, percent: $pct, false_stop_usd: $usd,
               decider_threshold: ($threshold | tonumber)},
       verdicts: $verdicts, deciders: $deciders}'
    return 0
  fi

  info "An early stop may act once its latest block of $CERTIFY_BLOCK judged shadow runs had at most $CERTIFY_MAX_WRONG wrongful stop(s): right at least $CERTIFY_TARGET_PERCENT% of the time, 95% sure."
  info ""
  info "Stuck-loop verdicts (CHALK_FP_RULES=$CHALK_FP_RULES), per agent model:"
  if [[ $(jq length <<<"$data") == 0 ]]; then
    info "  none fired in a shadow run yet"
  else
    jq -r --argjson usd "$usd" '
      def dollars: (. * 100 | round / 100) as $d
        | (if $d < 0 then "-$" else "$" end) + ($d | fabs | tostring
          | if test("\\.") then (. + "0" | capture("(?<v>[0-9]+\\.[0-9]{2})").v) else . + ".00" end);
      (["verdict", "model", "gate", "judged", "wrongful", "waiting", "blocks", "lower", "saved/firing", "net"] | @tsv),
      (.[] | [.verdict, .model, (if .certified then "certified" else "shadow only" end),
              .judged, .wrong, .waiting,
              (if .blocks > 0 then "\(.blocks) (latest \(.block_wrong) wrongful)" else "none" end),
              .lower, (.saved_lower | dollars), (.net | dollars)] | map(tostring) | @tsv)' <<<"$data" |
      dashboard_columns
    info "  lower: 95% lower bound on how often it was right; saved/firing: 95% lower bound on the spend"
    info "  each firing saved; net: that, less \$$usd per wrongful stop at its 95% upper bound."
  fi
  info ""
  info "Deciders (CHALK_DECIDER=$CHALK_DECIDER, at CHALK_DECIDER_THRESHOLD=$CHALK_DECIDER_THRESHOLD):"
  if [[ $(jq length <<<"$deciders") == 0 ]]; then
    info "  none answered yet"
  else
    jq -r '
      (["decider", "gate", "judged", "right", "waiting", "blocks", "lower", "suggested"] | @tsv),
      (.[] | ["\(.model) at \(.url)", (if .calibrated then "certified" else "shadow only" end),
              .judged, .correct, .waiting,
              (if .blocks > 0 then "\(.blocks) (latest \(.block_wrong) false)" else "none" end),
              .lower, (.suggested // "none")] | map(tostring) | @tsv)' <<<"$deciders" |
      dashboard_columns
  fi
}
