# The report card: a single self-contained HTML page built from the local
# telemetry database. Nothing is served and nothing leaves the machine.

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
  data="$(jq -c --argjson gate "${| decider_calibration_judge "${| decider_calibration_data; }"; }" \
             --arg threshold "$CHALK_DECIDER_THRESHOLD" --argjson runs "$DECIDER_CALIBRATION_RUNS" \
             --argjson pct "$DECIDER_CALIBRATION_PERCENT" '
    .decider.gate = $gate
    | .decider.gate_rules = {threshold: ($threshold | tonumber), runs: $runs, percent: $pct}' <<<"$data")" ||
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
