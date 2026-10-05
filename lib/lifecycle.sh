# What happens after the loop stops: office hours, submission, cleanup.

# Turns the engineer's note and fix into a reusable rule, using a short-lived
# sandbox. Prints the lesson, or nothing if it could not be produced; the
# note is always kept, so this is best effort.
office_hours_distill() {
  local note="$1" io sandbox signature start fix started lesson
  [ "$CHALK_DISTILL" = "true" ] && agent_auth_present || return 0
  io="$RUN_DIR/distill"
  sandbox="${| sandbox_name "$RUN_TICKET-distill"; }"
  rm -rf "$io"
  mkdir -p "$io"

  signature="$(db_pending_signature "$RUN_TICKET")"
  start="$(git -C "$RUN_WT" log --grep='^detention(' -1 --format=%H)"
  fix="$(git -C "$RUN_WT" diff "${start:-HEAD}" HEAD | head -n 300)"

  sandbox_ensure_image >/dev/null
  agent_write_system "$io" "$RUN_WT"
  sandbox_start "$sandbox" "$RUN_TICKET" "$io"
  sandbox_clone "$sandbox" "$RUN_BRANCH"
  started=$SECONDS
  {
    printf '<failure>\n%s\n</failure>\n' "$signature"
    printf '<engineer_note>\n%s\n</engineer_note>\n' "$note"
    printf '<fix_diff>\n%s\n</fix_diff>\n\n' "$fix"
    cat "${| prompt_file "$RUN_WT" distill; }"
  } | agent_call "$sandbox" "$io" distill "$CHALK_CHEAP_MODEL" "${CHALK_SCHEMA[lesson]}" read || true
  sandbox_stop "$sandbox"

  lesson="$(agent_field "$io/distill.json" '.lesson')"
  db_record_call distill "$([ -n "$lesson" ] && echo ok || echo none)" 0 false "$CHALK_CHEAP_MODEL" "$((SECONDS - started))" 0 "$io/distill.json"
  printf '%s\n' "$lesson"
}

cmd_office_hours() {
  local note="" run_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -m) note="${2:-}"; shift ;;
      --detach|-d) run_args=(--detach) ;;
      *) die "usage: chalk office-hours -m \"what was wrong and how you fixed it\" [--detach]" ;;
    esac
    shift
  done
  [ -n "$note" ] || die "a note is required: chalk office-hours -m \"what was wrong and how you fixed it\""

  need docker jq
  run_context
  case "$RUN_BRANCH" in
    detention/*) ;;
    *) die "run this from a detention/* branch (current: $RUN_BRANCH)" ;;
  esac

  db_up
  local lesson
  lesson="$(office_hours_distill "$note" || true)"
  db_resolve_lesson "$RUN_TICKET" "$note" "$(git config user.email || whoami)" "$lesson"
  if [ -n "$lesson" ]; then info "lesson: $lesson"; fi

  RUN_BRANCH="tutoring/$RUN_TICKET-$EPOCHSECONDS"
  git -C "$RUN_WT" switch -q -c "$RUN_BRANCH"
  info "lesson recorded; continuing on $RUN_BRANCH"

  if [ "$(spec_open_count "$RUN_SPEC")" -gt 0 ]; then
    cmd_run "${run_args[@]}"
  else
    run_graduate --force
  fi
}

cmd_submit() {
  run_context
  [ "$(spec_open_count "$RUN_SPEC")" -eq 0 ] ||
    die "specs/$RUN_TICKET.md still has open checkpoints"
  run_graduate --force
}

cmd_cleanup() {
  local all=0
  case "${1:-}" in
    --all) all=1 ;;
    '') ;;
    *) die "usage: chalk cleanup [--all]" ;;
  esac
  need git docker

  local root runs dir ref kept=0
  local -a containers refs
  local -a patterns=(refs/heads/chalk refs/heads/tutoring refs/heads/detention)
  root="${| main_root; }"
  runs="${| state_dir; }/runs"

  for dir in "$runs"/*/; do
    if run_is_alive "${dir%/}"; then kill "${| run_pid "$dir"; }" 2>/dev/null || true; fi
  done
  mapfile -t containers < <(docker ps -aq --filter "label=chalk.repo=${| repo_name; }")
  if (( ${#containers[@]} )); then
    docker rm -f "${containers[@]}" >/dev/null
  fi
  info "stopped runs and removed sandboxes"

  # Without --all, git refuses to remove worktrees with uncommitted changes
  # and branches that are neither merged nor pushed, so no work is lost.
  for dir in "$root".worktrees/*/; do
    if [ "$all" -eq 1 ]; then
      git -C "$root" worktree remove --force "$dir"
    elif ! git -C "$root" worktree remove "$dir" 2>/dev/null; then
      warn "kept worktree with uncommitted changes: $dir"
    fi
  done
  git -C "$root" worktree prune

  mapfile -t refs < <(git -C "$root" for-each-ref --format='%(refname:short)' "${patterns[@]}")
  for ref in "${refs[@]}"; do
    if [ "$all" -eq 1 ]; then
      git -C "$root" branch -q -D "$ref"
    elif ! git -C "$root" branch -q -d "$ref" 2>/dev/null; then
      kept=$((kept + 1))
    fi
  done
  if [ "$kept" -gt 0 ]; then
    info "kept $kept branch(es) that are neither merged nor pushed; 'chalk cleanup --all' deletes them too"
  fi

  rm -rf "$runs"
  if [ "$all" -eq 1 ]; then rm -rf "${| state_dir; }"; fi
  info "cleanup complete (telemetry database untouched)"
}
