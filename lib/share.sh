# chalk share: an anonymised summary of the report card, for the user to
# post if they choose. It prints the exact JSON and never sends anything:
# no network call is made here, and the summary leaves the machine only if
# the user copies it somewhere. What it may hold is the allow-list in
# share/share.jq; PRIVACY.md says why each field is safe.

# Where a summary can be posted: the "Report cards" Discussions category.
CHALK_SHARE_URL="https://github.com/khalaharvi/chalk/discussions/new?category=report-cards"

# share_host VAR: fills the associative array VAR with this machine's
# version, OS, architecture and sizes, as share.jq's $host. A probe that
# fails leaves its key empty.
share_host() {
  local -n __host=$1
  local arch
  system_profile
  arch="$(uname -m 2>/dev/null || true)"
  __host=(["chalk"]="$CHALK_VERSION" ["os"]="${SYS[os]:-}" ["arch"]="$arch"
          ["cores"]="${SYS[cores]:-}" ["ram_mb"]="${SYS[ram_mb]:-}"
          ["docker_cpus"]="${SYS[docker_cpus]:-}" ["docker_mem_mb"]="${SYS[docker_mem_mb]:-}")
}

# share_payload DAYS: prints the summary of the last DAYS days as JSON.
# Returns non-zero when the database cannot be read.
share_payload() {
  local days="$1" dash extra week key
  local -A host
  local -a args=()
  dash="$(db_dashboard "$days")" || return 1
  extra="$(db_sql -v days="$days" < "$CHALK_HOME/share/share.sql")" || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$dash" || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$extra" || return 1
  share_host host
  for key in "${!host[@]}"; do args+=(--arg "$key" "${host[$key]}"); done
  printf -v week '%(%G-W%V)T' -1
  jq -n --argjson dash "$dash" --argjson extra "$extra" --arg week "$week" \
    --arg decider "${DECIDER_MODEL##*/}" \
    --argjson host "$(jq -n '$ARGS.named' "${args[@]}")" \
    -f "$CHALK_HOME/share/share.jq"
}

cmd_share() {
  local days=30 output="" json_only=0 payload
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="${2:-}"; shift ;;
      --output|-o) output="${2:-}"; shift ;;
      --json) json_only=1 ;;
      *) die "usage: chalk share [--days N] [--output FILE] [--json]" ;;
    esac
    shift
  done
  [[ $days =~ ^[1-9][0-9]*$ ]] || die "--days takes a positive whole number"

  need docker jq
  db_up
  payload="$(share_payload "$days")" || die "could not read telemetry for the summary"
  if [[ -n $output ]]; then
    printf '%s\n' "$payload" > "$output" || die "could not write $output"
  fi
  printf '%s\n' "$payload"
  (( ! json_only )) || return 0

  # The guidance goes to stderr, so `chalk share > file` holds only the JSON.
  {
    info ""
    info "This is everything the summary holds: counts, rates, rounded costs,"
    info "model families and the size of this machine. No repository, path,"
    info "branch, ticket, test name, error, note, lesson or prompt is in it."
    info "Nothing has been sent. To share it, post the JSON above in Report cards:"
    info "  $CHALK_SHARE_URL"
    if [[ -n $output ]]; then info "It is also saved in $output."; fi
    info "What it holds and why: $CHALK_DOCS_URL/privacy/"
  } >&2
}
