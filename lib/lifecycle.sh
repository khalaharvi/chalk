# What happens after the loop stops: office hours, submission, cleanup.

# office_hours_fix: prints what the engineer changed in the repository since
# the detention commit, for the distillation prompt: the diff, or, when there
# is none, that the fix was made outside the repository. Said plainly, so
# that an empty or partial diff is not read as the whole fix.
office_hours_fix() {
  local start count
  start="$(git -C "$RUN_WT" log --grep='^detention(' -1 --format=%H)"
  if [ -z "$start" ]; then
    printf 'The detention commit was not found, so what changed in this repository is unknown. Rely on the note.\n'
    return 0
  fi
  count="$(git -C "$RUN_WT" rev-list --count "$start..HEAD")"
  if [ "$count" -eq 0 ]; then
    printf 'No commits since the detention: the engineer changed nothing in this repository. The fix was made outside it (for example the sandbox image, the environment, a credential or access), and the note is the only record of it.\n'
    return 0
  fi
  printf '%s commit(s) since the detention. They show only what changed inside this repository; the note says whether anything changed outside it.\n\n' "$count"
  git -C "$RUN_WT" diff --stat "$start" HEAD
  printf '\n'
  git -C "$RUN_WT" diff "$start" HEAD | head -n 300
}

# office_hours_distill NOTE: turns the engineer's note and fix into a
# reusable rule, using a short-lived sandbox. Prints the lesson's scope
# (general, repo or none), a tab and the lesson, which is empty for none.
# Prints nothing if the call gave no answer; the note is always kept, so
# this is best effort.
office_hours_distill() {
  local note="$1" io sandbox signature fix started lesson scope
  [ "$CHALK_DISTILL" = "true" ] && agent_auth_present || return 0
  io="$RUN_DIR/distill"
  sandbox="${| sandbox_name "$RUN_TICKET-distill"; }"
  rm -rf "$io"
  mkdir -p "$io"

  signature="$(db_pending_signature "$RUN_TICKET")"
  fix="$(office_hours_fix)"

  sandbox_ensure_image >/dev/null
  agent_write_system "$io" "$RUN_WT"
  sandbox_start "$sandbox" "$RUN_TICKET" "$io"
  sandbox_clone "$sandbox" "$RUN_BRANCH"
  started=$SECONDS
  {
    printf '<failure>\n%s\n</failure>\n' "$signature"
    printf '<engineer_note>\n%s\n</engineer_note>\n' "$note"
    printf '<fix_diff>\n%s\n</fix_diff>\n' "$fix"
    if [[ -n $OFFICE_FIX_TEXT ]]; then printf '<proposed_fix>\n%s\n</proposed_fix>\n' "$OFFICE_FIX_TEXT"; fi
    printf '\n'
    cat "${| prompt_file "$RUN_WT" distill; }"
  } > "$io/distill.prompt.md"
  agent_call "$sandbox" "$io" distill "$CHALK_CHEAP_MODEL" "${CHALK_SCHEMA[lesson]}" read < "$io/distill.prompt.md" || true
  sandbox_stop "$sandbox"

  lesson="$(agent_field "$io/distill.json" '.lesson')"
  scope="$(agent_field "$io/distill.json" '.scope')"
  # A lesson that is empty or just says "none" is no lesson, whatever the scope.
  if [[ $scope == none || ${lesson@L} =~ ^[[:space:]]*(none)?[.[:space:]]*$ ]]; then lesson=""; fi
  db_record_call distill "$([ -n "$lesson" ] && echo ok || echo none)" 0 false "$CHALK_CHEAP_MODEL" "$((SECONDS - started))" 0 "$io/distill.json"
  # No answer at all: the call failed, and the note stands alone, as before.
  [[ -n $scope || -n $lesson ]] || return 0
  if [[ -z $lesson ]]; then
    scope=none
  elif [[ $scope != general ]]; then
    scope=repo
  fi
  printf '%s\t%s\n' "$scope" "$lesson"
}

# What office_hours_check found, for distillation and saving a need: the
# fix the agent proposed and its probe's results in words, the lesson's id,
# its probe and kind, and what the probe proves (proved, unproved or empty).
OFFICE_FIX_TEXT="" OFFICE_LESSON_ID="" OFFICE_PROBE="" OFFICE_KIND="" OFFICE_EVIDENCE=""

# office_hours_check UNPROVED: when the detention's lesson carries a probe
# (evidence.sh), runs it in a fresh sandbox on this branch, with the
# setup command, as the resumed run will see the environment. Passing,
# after failing at detention, proves the lesson. Still failing stops office
# hours before anything is recorded, so it can be run again once fixed,
# unless UNPROVED is 1: then the run resumes and the lesson is kept out of
# recall. An inconclusive check proves nothing, and does not stop.
office_hours_check() {
  local unproved="$1" pending before first
  local -A after
  OFFICE_FIX_TEXT="" OFFICE_LESSON_ID="" OFFICE_PROBE="" OFFICE_KIND="" OFFICE_EVIDENCE=""
  pending="$(db_pending_evidence "$RUN_TICKET" 2>/dev/null || true)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$pending" || return 0
  OFFICE_LESSON_ID="$(jq -r '.id // empty' <<<"$pending")"
  if jq -e '.fix | type == "object"' >/dev/null <<<"$pending"; then
    OFFICE_FIX_TEXT="${| evidence_fix_text "$(jq -c .fix <<<"$pending")"; }"
  fi
  OFFICE_PROBE="$(jq -r '.probe // empty' <<<"$pending")"
  OFFICE_KIND="$(jq -r '.fix_kind // empty' <<<"$pending")"
  before="$(jq -r '.before_outcome // empty' <<<"$pending")"
  [[ -n $OFFICE_PROBE ]] || return 0

  info "checking your fix: running the probe in a fresh sandbox on $RUN_BRANCH: $OFFICE_PROBE"
  evidence_check "$RUN_BRANCH" "$OFFICE_PROBE" after "$CHALK_SETUP_CMD"
  first="${after[output]%%$'\n'*}"
  case "${after[outcome]}" in
    passed)
      if [[ $before == failed ]]; then
        OFFICE_EVIDENCE=proved
        info "the probe passes now, and failed at detention: the fix is proved"
      else
        OFFICE_EVIDENCE=unproved
        warn "the probe passes, but did not fail at detention (${before:-not run}), so it proves nothing; the lesson is kept out of recall"
      fi ;;
    failed)
      if (( ! unproved )); then
        die "the probe still fails after your fix (exit ${after[exit]}${first:+: $first})." \
          "Fix the environment, commit, and run office hours again; or add --unproved to resume anyway, with the lesson kept out of recall"
      fi
      OFFICE_EVIDENCE=unproved
      warn "the probe still fails (exit ${after[exit]}); resuming as asked, with the lesson kept out of recall" ;;
    *)
      OFFICE_EVIDENCE=unproved
      warn "the probe's check was inconclusive (${first:-no output}); the lesson is kept out of recall until a probe proves it" ;;
  esac
  OFFICE_FIX_TEXT+=$'\n'"probe at detention: ${before:-not run}; after your fix: ${after[outcome]}"
  db_set_evidence "$OFFICE_LESSON_ID" "${after[outcome]}" "${after[image]-}" "$OFFICE_EVIDENCE"
}

# office_hours_save_need: when the fix is proved and about the environment
# (an image or config fix), saves its probe as a need in .chalk/needs and
# commits it on the detention branch, so that the resumed run, and every
# branch this one merges into, checks it before its first loop.
office_hours_save_need() {
  local file line
  [[ $OFFICE_EVIDENCE == proved && $OFFICE_KIND == @(image|config) ]] || return 0
  line="${| evidence_need_line "$OFFICE_PROBE" "$OFFICE_KIND" "$RUN_TICKET" "$OFFICE_LESSON_ID"; }"
  if [[ -z $line ]]; then
    warn "the probe could not be saved as a need: one line in $EVIDENCE_NEEDS_FILE cannot hold it"
    return 0
  fi
  file="$RUN_WT/$EVIDENCE_NEEDS_FILE"
  if [[ -f $file ]] && grep -qF -- "$OFFICE_PROBE$EVIDENCE_NEEDS_SEP" "$file"; then return 0; fi
  mkdir -p "${file%/*}"
  printf '%s\n' "$line" >> "$file"
  git -C "$RUN_WT" add "$EVIDENCE_NEEDS_FILE"
  git -C "$RUN_WT" commit -q -m "chalk: save the need $RUN_TICKET proved" -m "$line"
  info "saved as a need in $EVIDENCE_NEEDS_FILE, checked before every run's first loop: $OFFICE_PROBE"
}

cmd_office_hours() {
  local note="" unproved=0 run_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -m) note="${2:-}"; shift ;;
      --detach|-d) run_args=(--detach) ;;
      --unproved) unproved=1 ;;
      *) die "usage: chalk office-hours -m \"what was wrong and how you fixed it\" [--detach] [--unproved]" ;;
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
  local distilled scope lesson stored
  office_hours_check "$unproved"
  distilled="$(office_hours_distill "$note" || true)"
  scope="${distilled%%$'\t'*}" lesson="${distilled#*$'\t'}"
  # The scope says where the lesson is recalled. A repo lesson is recalled
  # only in this repository, and so is the note when no lesson came of it.
  # When nothing was distilled the scope stays NULL, which is recalled
  # anywhere, as before scopes existed.
  stored="$scope"
  if [[ $scope == none ]]; then stored=repo; fi
  db_resolve_lesson "$RUN_TICKET" "$note" "$(git config user.email || whoami)" "$lesson" "$stored"
  case "$scope" in
    general) info "lesson: $lesson" ;;
    repo)    info "lesson, recalled in this repository only: $lesson" ;;
    none)    info "no lesson distilled: the fix does not support a rule for other tickets; your note is recalled in this repository only" ;;
  esac
  # Its embedding, for semantic recall. When chalk-embed is not running,
  # the local decider writes it the next time it starts.
  decider_gate
  if [[ $CHALK_DECIDER != off ]] && decider_embed_healthy "$CHALK_EMBED_URL"; then
    decider_embed_lessons 16
  fi

  office_hours_save_need
  RUN_BRANCH="tutoring/$RUN_TICKET-$EPOCHSECONDS"
  git -C "$RUN_WT" switch -q -c "$RUN_BRANCH"
  info "lesson recorded; continuing on $RUN_BRANCH"

  if [ "$(spec_open_count "$RUN_SPEC")" -gt 0 ]; then
    cmd_run "${run_args[@]}"
  else
    run_graduate --force
  fi
}

# needs_without KIND BRANCH PROBE VAR: runs PROBE as evidence_check does,
# in the environment without the fix a need of KIND records: the default
# image with no setup command for an image fix, CHALK_IMAGE with no setup
# command for a config fix.
needs_without() {
  local CHALK_IMAGE="$CHALK_IMAGE"
  if [[ $1 == image ]]; then CHALK_IMAGE="$CHALK_DEFAULT_IMAGE"; fi
  evidence_check "$2" "$3" "$4" ""
}

# chalk needs [--prune]: checks every need saved in .chalk/needs, each in a
# fresh sandbox: with the fix (CHALK_IMAGE and CHALK_SETUP_CMD, as a run
# sees them) it must pass; without it (needs_without), a pass means the
# environment no longer needs the fix, so the need and its lesson retire.
# Exits non-zero when a need fails, so CI can run it. --prune removes
# retired needs from the file, to commit.
cmd_needs() {
  local prune=0 root branch need probe kind ticket id status failed=0 retired=0
  local -a needs keep=()
  local -A with without
  case "${1:-}" in
    --prune) prune=1 ;;
    '') ;;
    *) die "usage: chalk needs [--prune]" ;;
  esac
  need git docker jq
  root="${| repo_root; }"
  load_config "$root"
  evidence_needs "$root" needs
  if (( ! ${#needs[@]} )); then
    info "no saved needs in $EVIDENCE_NEEDS_FILE"
    return 0
  fi
  branch="${| current_branch; }"
  local RUN_TICKET=needs RUN_WT="$root"
  db_up >/dev/null 2>&1 || true
  for need in "${needs[@]}"; do
    IFS=$'\t' read -r probe kind ticket id <<<"$need"
    evidence_check "$branch" "$probe" with "$CHALK_SETUP_CMD"
    status="${with[outcome]}"
    case "$status" in
      failed) status="FAILS (exit ${with[exit]})"; failed=1 ;;
      passed)
        needs_without "$kind" "$branch" "$probe" without
        if [[ ${without[outcome]} == passed ]]; then
          status="retired: passes without the fix too"
          retired=$((retired + 1))
          if [[ -n $id ]]; then db_retire_lesson "$id" >/dev/null 2>&1 || true; fi
          (( prune )) && continue
        else
          status="holds"
        fi ;;
    esac
    keep+=("${| evidence_need_line "$probe" "$kind" "$ticket" "$id"; }")
    info "  $status  $probe  ($kind, from $ticket)"
  done
  if (( prune && retired )); then
    printf '%s\n' "${keep[@]}" > "$root/$EVIDENCE_NEEDS_FILE"
    info "removed $retired retired need(s) from $EVIDENCE_NEEDS_FILE; commit it"
  elif (( retired )); then
    info "$retired need(s) retired; remove them with: chalk needs --prune"
  fi
  (( ! failed )) || die "a saved need fails: the environment lacks what an earlier ticket needed"
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
