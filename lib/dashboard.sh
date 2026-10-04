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

  need docker jq
  db_up
  : "${output:=${XDG_STATE_HOME:-$HOME/.local/state}/chalk/dashboard.html}"
  mkdir -p "$(dirname "$output")"

  # "</" is escaped so that no stored text can close the page's script tag.
  local data="$output.json"
  db_dashboard "$days" | sed 's|</|<\\/|g' > "$data"
  jq -e . "$data" >/dev/null 2>&1 || die "could not read telemetry for the dashboard"

  awk -v data="$data" '
    /\/\*CHALK_DATA\*\// { while ((getline line < data) > 0) print line; next }
    { print }
  ' "$CHALK_HOME/share/dashboard.html" > "$output"
  rm -f "$data"
  info "report card for the last $days days: $output"

  [ "$open_it" -eq 1 ] || return 0
  if command -v open >/dev/null 2>&1; then open "$output"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$output" >/dev/null 2>&1 || true
  fi
}
