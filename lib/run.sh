# The agent loop: one checkpoint per loop, verified by the rubric, committed
# only when the rubric passes, reviewed once at the end, and sent to detention
# when it cannot progress.

# Resolves the run for the current worktree into RUN_* globals.
run_context() {
  need git
  RUN_WT="${| repo_root; }"
  RUN_BRANCH="${| current_branch; }"
  RUN_TICKET="${| ticket_from_branch "$RUN_BRANCH"; }"
  [[ -n $RUN_TICKET ]] ||
    die "branch '$RUN_BRANCH' has no ticket key (expected e.g. chalk/PROJ-123)"
  RUN_SPEC="$RUN_WT/specs/$RUN_TICKET.md"
  RUN_DIR="${| run_dir "$RUN_TICKET"; }"
  RUN_IO="$RUN_DIR/io"
  RUN_SANDBOX=""
  RUN_LOOP=0
  RUN_REVIEW_SUMMARY=""
  RUN_REVIEW_FINDINGS=""
  RUN_LESSONS=0
  RUN_CALL_SECONDS=0
  load_config "$RUN_WT"
  RUN_PROMPTS="$(run_prompts_version)"

  [ -f "$RUN_SPEC" ] || die "missing spec: specs/$RUN_TICKET.md (create one with: chalk new $RUN_TICKET)"
  [ -z "$(git -C "$RUN_WT" status --porcelain)" ] ||
    die "uncommitted changes in $RUN_WT; commit them first (the sandbox only sees commits)"
}

run_log() { info "[$RUN_TICKET] $*"; }

# A short hash of every prompt in effect, so the dashboard can compare the
# results of one prompt set against another.
run_prompts_version() {
  local name
  {
    for name in "${CHALK_PROMPTS[@]}"; do cat "${| prompt_file "$RUN_WT" "$name"; }"; done
    cat "$RUN_WT/$CHALK_TEXTBOOK" 2>/dev/null || true
  } | git hash-object --stdin | cut -c1-8
}

# run_call NAME MODEL SCHEMA ACCESS, with the prompt on stdin: an agent call
# in this run's sandbox, timed into RUN_CALL_SECONDS.
run_call() {
  local started=$SECONDS status=0
  agent_call "$RUN_SANDBOX" "$RUN_IO" "$@" || status=$?
  RUN_CALL_SECONDS=$((SECONDS - started))
  return "$status"
}

run_teardown() {
  if [ -n "${RUN_SANDBOX:-}" ]; then sandbox_stop "$RUN_SANDBOX"; fi
  rm -f "$RUN_DIR/pid"
}

# Checks the preconditions shared by every command that starts a sandbox,
# then claims the run directory for this process.
run_claim() {
  need docker jq
  agent_auth_present || die "no agent credentials; export one of: ${CHALK_AUTH_VARS[*]}"
  # A detached run finds its own pid already recorded by the command that started it.
  local pid
  pid="${| run_pid "$RUN_DIR"; }"
  [[ $pid == "$$" ]] || ! run_is_alive "$RUN_DIR" ||
    die "a run for $RUN_TICKET is already active (pid $pid)"
  rm -rf "$RUN_IO"
  mkdir -p "$RUN_IO"
}

# run_start_services [--memory]: starts the telemetry database, the sandbox
# image and, with --memory, lesson memory, all at once. Memory is best
# effort; anything else failing stops the run.
run_start_services() {
  local -A started
  local name failed=""
  jobs_init "$RUN_IO/startup"
  jobs_spawn database db_up
  jobs_spawn image sandbox_ensure_image
  if [[ ${1:-} == --memory ]] && memory_enabled; then jobs_spawn memory memory_up; fi
  jobs_wait started && return 0

  if (( ${started[memory]:-0} )); then
    warn "continuing without lesson memory"
    unset 'started[memory]'
  fi
  for name in "${!started[@]}"; do
    (( started[$name] == 0 )) || failed+=" $name"
  done
  [[ -z $failed ]] || die "could not start:$failed (see $RUN_IO/startup)"
}

# run_open_sandbox [--memory]: starts the services this run needs, then its
# sandbox with the branch cloned inside it.
run_open_sandbox() {
  echo $$ > "$RUN_DIR/pid"
  trap run_teardown EXIT

  run_start_services "$@"
  agent_write_system "$RUN_IO" "$RUN_WT"

  RUN_SANDBOX="${| sandbox_name "$RUN_TICKET"; }"
  RUN_BASE="$(git -C "$RUN_WT" rev-parse HEAD)"
  run_log "starting sandbox $RUN_SANDBOX on $RUN_BRANCH"
  sandbox_start "$RUN_SANDBOX" "$RUN_TICKET" "$RUN_IO"
  sandbox_clone "$RUN_SANDBOX" "$RUN_BRANCH"
}

# run_build_prompt MODE FEEDBACK FINDINGS: context first, in tags, so that
# test output and lessons are read as data; the instructions come last.
run_build_prompt() {
  local mode="$1" feedback="$2" findings="$3" lessons
  printf '<spec_file>specs/%s.md</spec_file>\n' "$RUN_TICKET"
  printf '<notes_file>specs/%s.notes.md</notes_file>\n' "$RUN_TICKET"
  printf '<rubric_command>%s</rubric_command>\n' "$CHALK_TEST_CMD"

  lessons="$(memory_recall "${feedback:-$(<"$RUN_SPEC")}")"
  RUN_LESSONS="$(printf '%s\n' "$lessons" | grep -c '^- ' || true)"
  if [ -n "$lessons" ]; then printf '<lessons>\n%s\n</lessons>\n' "$lessons"; fi
  if [ -n "$findings" ]; then printf '<review_findings>\n%s\n</review_findings>\n' "$findings"; fi
  if [ -n "$feedback" ]; then printf '<failure>\n%s\n</failure>\n' "$feedback"; fi

  printf '\n'
  cat "${| prompt_file "$RUN_WT" "$mode"; }"
}

run_rubric() {
  docker exec -w /work/repo "$RUN_SANDBOX" \
    timeout "$CHALK_RUBRIC_TIMEOUT" bash -c "$CHALK_TEST_CMD" > "$RUN_IO/rubric.log" 2>&1
}

# Brings commits made in the sandbox onto the host branch (fast-forward only).
run_sync() {
  sandbox_export "$RUN_SANDBOX" "$RUN_BASE"
  [ -f "$RUN_IO/out.bundle" ] || return 0
  git -C "$RUN_WT" fetch -q "$RUN_IO/out.bundle" HEAD
  git -C "$RUN_WT" merge -q --ff-only FETCH_HEAD
  RUN_BASE="$(git -C "$RUN_WT" rev-parse HEAD)"
}

# Asks a cheap model whether the checkpoints are fit to hand to an agent.
# Returns non-zero only on an explicit "fail" verdict. A spec that passed is
# not checked again until its checkpoints change.
run_spec_check() {
  local stamp="$RUN_DIR/spec-check.ok" hash passed="" verdict result="$RUN_IO/spec-check.json"
  hash="$(sed 's/- \[x\]/- [ ]/' "$RUN_SPEC" | git hash-object --stdin)"
  [[ -f $stamp ]] && read -r passed < "$stamp"
  if [[ $passed == "$hash" ]]; then return 0; fi

  {
    printf '<spec_file>specs/%s.md</spec_file>\n\n' "$RUN_TICKET"
    cat "${| prompt_file "$RUN_WT" spec-check; }"
  } > "$RUN_IO/spec-check.prompt.md"
  run_call spec-check "$CHALK_CHEAP_MODEL" "${CHALK_SCHEMA[spec]}" read < "$RUN_IO/spec-check.prompt.md" || true
  sandbox_reset "$RUN_SANDBOX"

  verdict="$(agent_field "$result" '.verdict')"
  db_record_call spec-check "${verdict:-none}" 0 false "$CHALK_CHEAP_MODEL" "$RUN_CALL_SECONDS" 0 "$result"
  case "$verdict" in
    pass) printf '%s\n' "$hash" > "$stamp" ;;
    fail)
      db_event "$RUN_TICKET" spec_blocked
      run_log "spec check found checkpoints that are not ready:"
      agent_field "$result" '.problems[] | "  - \(.checkpoint)\n    problem: \(.problem)"
        + (if .suggestion then "\n    suggestion: \(.suggestion)" else "" end)'
      return 1 ;;
    *) warn "spec check returned no verdict; continuing without it" ;;
  esac
}

# Independent review of the finished work. Returns non-zero only on an
# explicit "fail" verdict, leaving the findings in RUN_REVIEW_FINDINGS.
run_review() {
  RUN_REVIEW_FINDINGS=""
  [ "$CHALK_REVIEW" = "true" ] || return 0
  local result="$RUN_IO/review.json" verdict

  {
    printf '<spec_file>specs/%s.md</spec_file>\n' "$RUN_TICKET"
    printf '<base_ref>origin/%s</base_ref>\n\n' "$CHALK_BASE_BRANCH"
    cat "${| prompt_file "$RUN_WT" review; }"
  } > "$RUN_IO/review.prompt.md"
  run_call review "$CHALK_REVIEW_MODEL" "${CHALK_SCHEMA[review]}" read < "$RUN_IO/review.prompt.md" || true
  sandbox_reset "$RUN_SANDBOX"

  verdict="$(agent_field "$result" '.verdict')"
  db_record_call review "${verdict:-none}" 0 false "${CHALK_REVIEW_MODEL:-$CHALK_MODEL}" "$RUN_CALL_SECONDS" 0 "$result"
  RUN_REVIEW_SUMMARY="$(agent_field "$result" '.summary')"
  run_log "final review: ${verdict:-no verdict}. $RUN_REVIEW_SUMMARY"

  if [ "$verdict" = "fail" ]; then
    RUN_REVIEW_FINDINGS="$(agent_field "$result" \
      '.findings[] | "- [\(.severity)] " + (if .file then "\(.file): " else "" end) + .issue')"
    return 1
  fi
  if [ -z "$verdict" ]; then warn "final review returned no verdict; continuing without it"; fi
}

# run_detain REASON [DETAIL]: parks the sandbox's work on a local detention
# branch, logs the failure as an open lesson, and halts this run.
run_detain() {
  local reason="$1" detail="${2:-}" branch signature
  branch="detention/$RUN_TICKET-$EPOCHSECONDS"

  sandbox_commit "$RUN_SANDBOX" "detention($RUN_TICKET): $reason" --allow-empty
  sandbox_export "$RUN_SANDBOX" "$RUN_BASE"
  git -C "$RUN_WT" fetch -q "$RUN_IO/out.bundle" "HEAD:refs/heads/$branch"

  signature="$reason"
  if [ -n "$detail" ]; then
    signature="$signature
$detail"
  elif [ -s "$RUN_IO/rubric.log" ]; then
    signature="$signature
$(tail -n 40 "$RUN_IO/rubric.log")"
  fi
  db_open_lesson "$RUN_TICKET" "$signature"
  db_event "$RUN_TICKET" detention

  run_log "DETENTION: $reason"
  if [ -n "$detail" ]; then printf '%s\n' "$detail"; fi
  run_log "work parked on local branch $branch. To unblock:"
  run_log "  cd ${RUN_WT@Q} && git switch ${branch@Q}"
  run_log "  fix the blocker, commit, then: chalk office-hours -m \"what was wrong\""
}

# Pushes the finished branch and opens the pull or merge request. chalk
# submit passes --force to open it even when CHALK_AUTO_MR is off.
# shellcheck disable=SC2120
run_graduate() {
  local -A summary
  local review="" request
  request="${| forge_request; }"
  db_ticket_summary "$RUN_TICKET" summary
  run_log "all checkpoints complete (${summary[loops]} loops, \$${summary[cost]}, ${summary[fixes]} human interventions)"

  if [ "$CHALK_AUTO_MR" != "true" ] && [ "${1:-}" != "--force" ]; then
    run_log "CHALK_AUTO_MR is off; open the $request with: chalk submit"
    return 0
  fi
  if [ -n "$RUN_REVIEW_SUMMARY" ]; then
    review="
- Agent review before submission: $RUN_REVIEW_SUMMARY"
  fi

  need "${| forge_cli; }"
  git -C "$RUN_WT" push -q -u origin "$RUN_BRANCH"
  forge_open_request "$RUN_WT" "$RUN_BRANCH" "$CHALK_BASE_BRANCH" "$(spec_title "$RUN_SPEC")" \
    "## Chalk execution summary

- Spec: \`specs/$RUN_TICKET.md\`, all checkpoints complete
- Agent loops: ${summary[loops]}
- Agent cost: \$${summary[cost]}
- Human interventions (office hours): ${summary[fixes]}
- Rubric: \`$CHALK_TEST_CMD\` passed in the sandbox$review

This change was written by an agent. Review the diff as you would any other."
  db_event "$RUN_TICKET" submitted 2>/dev/null || true
}

cmd_run() {
  local detach=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --detach|-d) detach=1 ;;
      *) die "usage: chalk run [--detach]" ;;
    esac
    shift
  done

  run_context
  [ -n "$CHALK_TEST_CMD" ] || die "CHALK_TEST_CMD is not set in .chalk/config (run: chalk init)"
  run_claim

  if [ "$detach" -eq 1 ]; then
    nohup "$BASH" "$CHALK_HOME/bin/chalk" run < /dev/null > "$RUN_DIR/run.log" 2>&1 &
    # Recorded here as well as by the run itself, so `chalk status` sees it at once.
    echo $! > "$RUN_DIR/pid"
    info "$RUN_TICKET running in background (pid $!). Follow with: chalk logs $RUN_TICKET -f"
    return 0
  fi

  run_open_sandbox --memory
  if [ -n "$CHALK_SETUP_CMD" ]; then
    sandbox_sh "$RUN_SANDBOX" "$CHALK_SETUP_CMD" > "$RUN_IO/setup.log" 2>&1 ||
      die "setup command failed in sandbox; see $RUN_IO/setup.log"
  fi
  if [ "$CHALK_SPEC_CHECK" = "true" ]; then
    run_spec_check ||
      die "rewrite the checkpoints in specs/$RUN_TICKET.md and commit, or set CHALK_SPEC_CHECK=false to skip this check"
  fi

  local failures=0 failed_reviews=0 feedback="" findings="" mode reason
  local open remaining result agent_status rubric_exit progressed
  local -A usage
  result="$RUN_IO/loop.json"
  while :; do
    open="$(spec_open_count "$RUN_SPEC")"

    # Every checkpoint is ticked: review, then either submit or fix findings.
    if [ "$open" -eq 0 ] && [ -z "$findings" ]; then
      if run_review; then
        run_graduate
        return 0
      fi
      failed_reviews=$((failed_reviews + 1))
      if [ "$failed_reviews" -gt "$CHALK_REVIEW_ROUNDS" ]; then
        run_detain "final review still finds problems after $CHALK_REVIEW_ROUNDS fix round(s)" "$RUN_REVIEW_FINDINGS"
        return 1
      fi
      findings="$RUN_REVIEW_FINDINGS"
    fi

    if [ "$open" -eq 0 ]; then mode="fix-review"
    elif [ -n "$feedback" ]; then mode="retry"
    else mode="continue"
    fi

    RUN_LOOP=$((RUN_LOOP + 1))
    if [ "$RUN_LOOP" -gt "$CHALK_MAX_LOOPS" ]; then
      run_detain "loop limit of $CHALK_MAX_LOOPS reached with $open checkpoints open"
      return 1
    fi

    run_build_prompt "$mode" "$feedback" "$findings" > "$RUN_IO/prompt.md"
    agent_status="ok"
    run_call loop "$CHALK_MODEL" "${CHALK_SCHEMA[loop]}" write < "$RUN_IO/prompt.md" || agent_status="error"
    if [ -n "$(agent_error "$result")" ]; then agent_status="$(agent_error "$result")"; fi

    # A reported blocker goes straight to an engineer; retrying cannot fix it.
    if [ "$(agent_field "$result" '.status')" = "blocked" ]; then
      db_record_call "$mode" blocked 0 false "$CHALK_MODEL" "$RUN_CALL_SECONDS" "$RUN_LESSONS" "$result"
      run_detain "agent reported a blocker" "$(agent_field "$result" '.blocker // .summary')"
      return 1
    fi

    rubric_exit=0
    run_rubric || rubric_exit=$?

    reason=""
    progressed="false"
    if [ "$agent_status" != "ok" ]; then
      reason="agent stopped early ($agent_status)"
    elif [ "$rubric_exit" -ne 0 ]; then
      reason="rubric failed (exit $rubric_exit)"
    else
      sandbox_commit "$RUN_SANDBOX" "chalk($RUN_TICKET): $mode, loop $RUN_LOOP"
      run_sync
      remaining="$(spec_open_count "$RUN_SPEC")"
      if [ "$mode" = "fix-review" ] || [ "$remaining" -lt "$open" ]; then
        progressed="true"
      else
        reason="rubric passed but no checkpoint was ticked in the spec"
      fi
    fi

    db_record_call "$mode" "$agent_status" "$rubric_exit" "$progressed" "$CHALK_MODEL" \
      "$RUN_CALL_SECONDS" "$RUN_LESSONS" "$result"
    run_log "loop $RUN_LOOP ($mode): agent $agent_status (\$$(agent_cost "$result"), ${RUN_CALL_SECONDS}s), rubric exit $rubric_exit. $(agent_field "$result" '.summary')"
    agent_usage "$result" usage
    if (( usage[denials] > 0 )); then
      run_log "  ${usage[denials]} action(s) were refused by permission checks; see $result"
    fi

    if [ "$progressed" = "true" ]; then
      failures=0
      feedback=""
      findings=""
      continue
    fi

    failures=$((failures + 1))
    if [ "$failures" -gt "$CHALK_MAX_RETRIES" ]; then
      run_detain "$reason"
      return 1
    fi
    feedback="$reason
$(tail -n 60 "$RUN_IO/rubric.log" 2>/dev/null || true)"
  done
}

# Runs only the spec check, so a spec can be fixed before any agent starts.
cmd_check() {
  run_context
  run_claim
  run_open_sandbox
  rm -f "$RUN_DIR/spec-check.ok"
  run_spec_check || die "specs/$RUN_TICKET.md is not ready for an agent"
  run_log "spec check passed"
}

cmd_status() {
  need git
  local runs dir ticket state
  local -A summary
  local -a detentions
  # The most recently active runs first.
  local GLOBSORT=-mtime
  runs="${| state_dir; }/runs"
  printf '%-14s %-8s %-6s %-9s %-6s %s\n' TICKET STATE LOOPS COST FIXES DETENTIONS
  for dir in "$runs"/*/; do
    ticket="$(basename "$dir")"
    state="idle"
    if run_is_alive "${dir%/}"; then state="running"; fi
    db_ticket_summary "$ticket" summary -
    mapfile -t detentions < <(git for-each-ref --format='%(refname:short)' "refs/heads/detention/$ticket-*")
    printf '%-14s %-8s %-6s %-9s %-6s %s\n' "$ticket" "$state" "${summary[loops]}" "${summary[cost]}" "${summary[fixes]}" "${#detentions[@]}"
  done
}

cmd_logs() {
  local ticket="${1:-}" log
  [ -n "$ticket" ] || die "usage: chalk logs TICKET [-f]"
  log="${| run_dir "$ticket"; }/run.log"
  [ -f "$log" ] || die "no background run log for $ticket"
  if [ "${2:-}" = "-f" ]; then exec tail -f "$log"; fi
  cat "$log"
}
