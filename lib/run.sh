# The agent loop: one checkpoint per loop, verified by the rubric, committed
# only when the rubric passes, reviewed once at the end, and sent to detention
# when it cannot progress.

# The baseline for loop verdicts (fp_verdict): the latest fingerprinted loop
# of the current non-progress streak.
declare -gA RUN_FP_BASE=()

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
  # Permission refusals in the latest loop, and the ticket whose open
  # detention the latest failure matched (see run_fingerprint).
  RUN_DENIALS=0
  RUN_OPEN_TICKET=""
  # The decider's confidence when it judged the run stuck (run_next_step).
  RUN_STUCK_CONFIDENCE=""
  # Set by cmd_run when the loop starts; calls outside a run record none.
  RUN_ID=""
  RUN_FP_BASE=()
  load_config "$RUN_WT"
  RUN_PROMPTS="$(run_prompts_version)"

  [ -f "$RUN_SPEC" ] || die "missing spec: specs/$RUN_TICKET.md (create one with: chalk new $RUN_TICKET)"
  [ -z "$(git -C "$RUN_WT" status --porcelain)" ] ||
    die "uncommitted changes in $RUN_WT; commit them first (the sandbox only sees commits)"
}

# run_log TEXT...: prints TEXT with the ticket in front of every line, so
# that an agent's summary of several paragraphs still greps by ticket.
run_log() {
  local line
  while IFS= read -r line; do info "[$RUN_TICKET]${line:+ $line}"; done <<<"$*"
}

# A short hash of every prompt in effect, so the dashboard can compare the
# results of one prompt set against another. The form of the retry
# feedback (CHALK_FP_FEEDBACK) is part of the prompt, so it is hashed too.
run_prompts_version() {
  local name
  {
    for name in "${CHALK_PROMPTS[@]}"; do cat "${| prompt_file "$RUN_WT" "$name"; }"; done
    cat "$RUN_WT/$CHALK_TEXTBOOK" 2>/dev/null || true
    printf 'fp-feedback=%s\n' "$CHALK_FP_FEEDBACK"
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

# run_start_services: starts the telemetry database and the sandbox image
# side by side. Either failing stops the run. Then the local decider
# (run_start_decider).
run_start_services() {
  local -A started
  local name failed=""
  jobs_init "$RUN_IO/startup"
  decider_gate
  jobs_spawn database db_up
  jobs_spawn image sandbox_ensure_image
  if jobs_wait started; then
    run_start_decider
    return 0
  fi

  for name in "${!started[@]}"; do
    (( started[$name] == 0 )) || failed+=" $name"
  done
  [[ -z $failed ]] || die "could not start:$failed (see $RUN_IO/startup)"
}

# run_start_decider: the local decider, when it is installed and wanted, is
# started in the background and never waited for: until it answers, loops
# go on without it. It holds several GB, so it is started only once it can
# be asked something: here when lesson rerank can be, from the first
# loop's prompt on; otherwise by the first loop that fails its rubric
# (cmd_run), since the stuck question needs a failed loop before it.
run_start_decider() {
  local have
  [[ $CHALK_DECIDER != off ]] && decider_local && decider_installed || return 0
  have="${| decider_lessons; }"
  if [[ -n $have ]] && (( have >= CHALK_DECIDER_MIN_LESSONS )); then
    decider_start_bg "$RUN_IO/startup/decider.log" || true
  elif [[ -z ${| decider_pid decider; } ]]; then
    have="${have:+this machine has $have}"
    run_log "the local decider starts once a loop fails its rubric: until then it cannot be asked anything (lesson rerank needs $CHALK_DECIDER_MIN_LESSONS resolved lessons, ${have:-and the database did not say how many there are})"
  fi
}

# run_open_sandbox: starts the services this run needs, then its sandbox
# with the branch cloned inside it.
run_open_sandbox() {
  echo $$ > "$RUN_DIR/pid"
  trap run_teardown EXIT

  run_log "starting the database and the sandbox image"
  run_start_services
  agent_write_system "$RUN_IO" "$RUN_WT"

  RUN_SANDBOX="${| sandbox_name "$RUN_TICKET"; }"
  RUN_BASE="$(git -C "$RUN_WT" rev-parse HEAD)"
  run_log "starting sandbox $RUN_SANDBOX on $RUN_BRANCH"
  sandbox_start "$RUN_SANDBOX" "$RUN_TICKET" "$RUN_IO"
  run_log "cloning $RUN_BRANCH into the sandbox"
  sandbox_clone "$RUN_SANDBOX" "$RUN_BRANCH"
}

# run_build_prompt MODE FEEDBACK FINDINGS [RECALL]: context first, in tags,
# so that test output and lessons are read as data; the instructions come
# last. RECALL names an associative array filled by run_recall; while it is
# empty, as before the first failure, lessons are recalled for the spec.
run_build_prompt() {
  local mode="$1" feedback="$2" findings="$3" lessons
  local -A __no_recall=()
  local -n __recall="${4:-__no_recall}"
  printf '<spec_file>specs/%s.md</spec_file>\n' "$RUN_TICKET"
  printf '<notes_file>specs/%s.notes.md</notes_file>\n' "$RUN_TICKET"
  printf '<rubric_command>%s</rubric_command>\n' "$CHALK_TEST_CMD"

  if [[ -n ${__recall[mode]-} ]]; then
    lessons="${| memory_recall "${__recall[mode]}" "${__recall[query]-}" \
      "${__recall[fingerprint]-}" "${__recall[first_error]-}"; }"
  else
    lessons="${| memory_recall spec "$(<"$RUN_SPEC")"; }"
  fi
  RUN_LESSONS="$(printf '%s\n' "$lessons" | grep -c '^- ' || true)"
  if [ -n "$lessons" ]; then printf '<lessons>\n%s\n</lessons>\n' "$lessons"; fi
  if [ -n "$findings" ]; then printf '<review_findings>\n%s\n</review_findings>\n' "$findings"; fi
  if [ -n "$feedback" ]; then printf '<failure>\n%s\n</failure>\n' "$feedback"; fi

  printf '\n'
  cat "${| prompt_file "$RUN_WT" "$mode"; }"
}

run_rubric() {
  if [[ $CHALK_FP_RULES != off ]]; then fp_report_clear "$RUN_SANDBOX"; fi
  docker exec -w /work/repo "$RUN_SANDBOX" \
    timeout "$CHALK_RUBRIC_TIMEOUT" bash -c "$CHALK_TEST_CMD" > "$RUN_IO/rubric.log" 2>&1
}

# run_fingerprint VAR RUBRIC_EXIT: fills VAR with this loop's fingerprint,
# which must be taken before anything is committed. A passing rubric needs
# only the tree ID. A failing one is also checked against open lessons for
# other tickets (CUR[open_match], see fp_verdict); the newest such ticket is
# kept in RUN_OPEN_TICKET.
run_fingerprint() {
  local -n __loop_fp=$1
  __loop_fp=()
  RUN_OPEN_TICKET=""
  [[ $CHALK_FP_RULES != off ]] || return 0
  if (( $2 == 0 )); then
    __loop_fp=(["tree_id"]="${| fp_tree_id "$RUN_SANDBOX"; }")
    return 0
  fi
  # The copy has no extension: the report may be XML or JSON.
  fp_report_fetch "$RUN_SANDBOX" "$RUN_IO/report"
  fp_compute "$1" "$RUN_SANDBOX" "$RUN_IO/rubric.log" "$RUN_IO/report"
  if [[ ${__loop_fp[tests]} != UNKNOWN ]]; then
    RUN_OPEN_TICKET="${| db_open_match "$RUN_TICKET" "${__loop_fp[fingerprint]}"; }"
    if [[ -n $RUN_OPEN_TICKET ]]; then __loop_fp["open_match"]=1; fi
  fi
}

# run_verdict VAR WHY: sets VAR[verdict] for a loop that ended as WHY
# (blocked, agent_error, failed, passed or progressed; see fp_verdict), and
# moves the streak's baseline on. Progress ends the streak.
run_verdict() {
  local -n __verdict_fp=$1
  [[ $CHALK_FP_RULES != off ]] || return 0
  if [[ $2 == progressed ]]; then
    RUN_FP_BASE=()
    return 0
  fi
  __verdict_fp["verdict"]="${| fp_verdict "$2" RUN_FP_BASE "$1"; }"
  # A loop the agent did not finish has no fingerprint, so never becomes the baseline.
  [[ $2 == @(failed|passed) ]] || return 0
  local key
  RUN_FP_BASE=()
  for key in "${!__verdict_fp[@]}"; do RUN_FP_BASE[$key]="${__verdict_fp[$key]}"; done
}

# run_fp_feedback REASON FP -> REPLY: the retry feedback for a failed rubric
# with CHALK_FP_FEEDBACK=true, or for one that printed nothing. FP names an
# array filled by fp_compute. In place of the last 60 lines of output: the
# tests that still fail (T), the first error (E), both normalized, and only
# the last 20 lines. The retry prompt points the agent at this <failure>
# block.
run_fp_feedback() {
  local -n __feedback_fp=$2
  local tests="${__feedback_fp[tests]-UNKNOWN}" output
  local -a ids
  if [[ $tests == UNKNOWN ]]; then
    tests="failing tests: unknown (the output names none)"
  else
    mapfile -t ids <<<"$tests"
    if (( ${#ids[@]} == 1 )); then tests="this test still fails:"
    else tests="these ${#ids[@]} tests still fail:"
    fi
    tests+=$'\n'"$(printf -- '- %s\n' "${ids[@]}")"
  fi
  output="$(tail -n 20 "$RUN_IO/rubric.log" 2>/dev/null || true)"
  if run_blank "$output"; then
    output="the rubric printed no output"
  else
    output="last 20 lines of output:
$output"
  fi
  REPLY="$1
$tests
first error: ${__feedback_fp[first_error]:-none found}
$output"
}

# run_blank TEXT: true when TEXT is only white space, as the output of a
# rubric that writes everything to its test report.
run_blank() {
  [[ $1 != *[^[:space:]]* ]]
}

# run_recall VAR TEXT FP: fills VAR with what the next loop recalls lessons
# by (see memory_recall). After a failed rubric whose fingerprint (FP) says
# something: the fingerprint and E, with E and T as the query. Otherwise
# the failure as TEXT, which is how recall worked before fingerprints.
run_recall() {
  local -n __recall_var=$1 __recall_fp=$3
  local tests="${__recall_fp[tests]-UNKNOWN}" error="${__recall_fp[first_error]-}"
  [[ $tests != UNKNOWN ]] || tests=""
  if [[ -n ${__recall_fp[fingerprint]-} || -n $error ]]; then
    __recall_var=(["mode"]="failure" ["fingerprint"]="${__recall_fp[fingerprint]-}"
                  ["first_error"]="$error" ["query"]="$error${tests:+
$tests}")
  else
    __recall_var=(["mode"]="text" ["query"]="$2")
  fi
}

# run_stuck_state PREV CUR -> REPLY: what the decider is told about a loop
# the fingerprint rules could not settle (maintainer's decision on #34):
# compact facts only, the failing tests and first error of the previous
# loop (PREV, the baseline) and of this one (CUR), and a diffstat between
# their working trees. Never the diff itself. decider_stuck caps it.
run_stuck_state() {
  local -n __stuck_prev=$1 __stuck_cur=$2
  local stat=""
  REPLY="${| run_stuck_facts previous "$1"; }${| run_stuck_facts current "$2"; }"
  if [[ -n ${__stuck_prev[tree_id]-} && -n ${__stuck_cur[tree_id]-} ]]; then
    # shellcheck disable=SC2016 # expanded by the sandbox's bash
    stat="$(sandbox_sh "$RUN_SANDBOX" 'git diff --stat=120 "$1" "$2" | tail -n 41' \
              "${__stuck_prev[tree_id]}" "${__stuck_cur[tree_id]}" 2>/dev/null || true)"
  fi
  REPLY+="changes between the two loops (git diff --stat):
${stat:-  none, or unknown}"
}

# run_stuck_facts LABEL FP -> REPLY: one loop's lines of run_stuck_state.
# FP names an array filled by fp_compute. At most 20 test IDs are listed.
run_stuck_facts() {
  local -n __facts=$2
  local tests="${__facts[tests]-UNKNOWN}" count="${__facts[failing]-}"
  if [[ $tests == UNKNOWN ]]; then
    tests="unknown"
  else
    tests="($count): $(head -n 20 <<<"$tests" | paste -sd ',' - | sed 's/,/, /g')"
    if (( ${count:-0} > 20 )); then tests+=", ..."; fi
  fi
  REPLY="$1 loop:
  failing tests $tests
  first error: ${__facts[first_error]:-none found}
"
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
  if [[ $passed == "$hash" ]]; then
    run_log "spec check skipped: it passed before and the checkpoints have not changed"
    return 0
  fi

  run_log "checking the spec with $CHALK_CHEAP_MODEL"
  {
    printf '<spec_file>specs/%s.md</spec_file>\n\n' "$RUN_TICKET"
    cat "${| prompt_file "$RUN_WT" spec-check; }"
  } > "$RUN_IO/spec-check.prompt.md"
  run_call spec-check "$CHALK_CHEAP_MODEL" "${CHALK_SCHEMA[spec]}" read < "$RUN_IO/spec-check.prompt.md" || true
  sandbox_reset "$RUN_SANDBOX"

  verdict="$(agent_field "$result" '.verdict')"
  db_record_call spec-check "${verdict:-none}" 0 false "$CHALK_CHEAP_MODEL" "$RUN_CALL_SECONDS" 0 "$result"
  case "$verdict" in
    pass)
      printf '%s\n' "$hash" > "$stamp"
      run_log "spec check passed (${| agent_usd "$(agent_cost "$result")"; }, ${RUN_CALL_SECONDS}s)" ;;
    fail)
      db_event "$RUN_TICKET" spec_blocked
      run_log "spec check found checkpoints that are not ready:"
      run_log "$(agent_field "$result" '.problems[] | "  - \(.checkpoint)\n    problem: \(.problem)"
        + (if .suggestion then "\n    suggestion: \(.suggestion)" else "" end)')"
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

  run_log "final review started"
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

# A loop with at least this many permission refusals points to auto mode.
RUN_MANY_DENIALS=3

# run_next_step KIND -> REPLY: the one line that says what to do about a
# detention of KIND (see run_detain). Many refusals in the last loop win
# over KIND: they are what a loop looks like when auto mode is unavailable.
run_next_step() {
  if (( RUN_DENIALS >= RUN_MANY_DENIALS )); then
    REPLY="$RUN_DENIALS actions were refused in the last loop, as when auto mode is unavailable for the model; run: chalk doctor"
    return 0
  fi
  case "$1" in
    blocked)     REPLY="provide what the agent asked for above, such as a credential, access or a decision" ;;
    loop_limit)  REPLY="split the open checkpoints into smaller ones, or raise CHALK_MAX_LOOPS (now $CHALK_MAX_LOOPS)" ;;
    review)      REPLY="fix the review findings above, or raise CHALK_REVIEW_ROUNDS (now $CHALK_REVIEW_ROUNDS)" ;;
    failed)      REPLY="the rubric still fails after $CHALK_MAX_RETRIES retries; fix the failure in $RUN_IO/rubric.log, or make the checkpoint smaller" ;;
    agent_error) REPLY="see why the agent stopped in $RUN_IO/loop.json; if it ran out of budget, raise CHALK_BUDGET_USD (now $CHALK_BUDGET_USD)" ;;
    passed)      REPLY="the rubric passes but no checkpoint was ticked; tick it if it is done, or make it testable" ;;
    deja_vu)     REPLY="this fails like the open detention of ${RUN_OPEN_TICKET:-another ticket}; fix that one first" ;;
    repeat)      REPLY="the agent made the same failing change twice; fix the failure yourself, a retry would repeat it" ;;
    no_change)   REPLY="the agent changed nothing; make the checkpoint clearer, or do this step yourself" ;;
    stuck)       REPLY="the decider judged the agent stuck on the same root cause as the loop before (confidence $RUN_STUCK_CONFIDENCE); fix that cause yourself, a retry would likely fail the same way" ;;
    *)           REPLY="fix what stopped the run" ;;
  esac
}

# run_detention_branch -> REPLY: a name for this run's detention branch that
# is not taken yet. Two detentions of one ticket within the same second get
# -2, -3 and so on, instead of the second one failing to fetch.
run_detention_branch() {
  local base="detention/$RUN_TICKET-$EPOCHSECONDS" n=1
  REPLY="$base"
  while git -C "$RUN_WT" show-ref -q --verify "refs/heads/$REPLY"; do
    n=$((n + 1))
    REPLY="$base-$n"
  done
}

# run_detain KIND REASON [DETAIL] [FINGERPRINT] [FIRST_ERROR]: parks the
# sandbox's work on a local detention branch, logs the failure as an open
# lesson, says what to do next, and halts this run. KIND is blocked,
# loop_limit or review; how the last loop ended when the retries ran out
# (failed, agent_error or passed); or the verdict that stopped the run
# (deja_vu, repeat or no_change), or stuck when the decider stopped it.
# FINGERPRINT and FIRST_ERROR are given only
# when the loop that detained the run failed its rubric.
run_detain() {
  local kind="$1" reason="$2" detail="${3:-}" fingerprint="${4:-}" first_error="${5:-}" branch signature
  branch="${| run_detention_branch; }"

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
  db_open_lesson "${| repo_name; }" "$RUN_TICKET" "$signature" "$RUN_ID" "$fingerprint" "$first_error"
  db_event "$RUN_TICKET" detention

  run_log "DETENTION: $reason"
  if [ -n "$detail" ]; then run_log "$detail"; fi
  run_log "next: ${| run_next_step "$kind"; }"
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
  run_log "all checkpoints complete (${summary[loops]} loops, ${| agent_usd "${summary[cost]}"; }, ${summary[fixes]} human interventions)"

  if [ "$CHALK_AUTO_MR" != "true" ] && [ "${1:-}" != "--force" ]; then
    db_event "$RUN_TICKET" ready 2>/dev/null || true
    run_log "CHALK_AUTO_MR is off; open the $request with: chalk submit"
    return 0
  fi
  if [ -n "$RUN_REVIEW_SUMMARY" ]; then
    review="
- Agent review before submission: $RUN_REVIEW_SUMMARY"
  fi

  need "${| forge_cli; }"
  forge_push "$RUN_WT" "$RUN_BRANCH"
  forge_open_request "$RUN_WT" "$RUN_BRANCH" "$CHALK_BASE_BRANCH" "$(spec_title "$RUN_SPEC")" \
    "## Chalk execution summary

- Spec: \`specs/$RUN_TICKET.md\`, all checkpoints complete
- Agent loops: ${summary[loops]}
- Agent cost: ${| agent_usd "${summary[cost]}"; }
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

  RUN_ID="$RUN_TICKET-$EPOCHSECONDS"
  run_open_sandbox
  if [ -n "$CHALK_SETUP_CMD" ]; then
    run_log "running the setup command: $CHALK_SETUP_CMD"
    sandbox_sh "$RUN_SANDBOX" "$CHALK_SETUP_CMD" > "$RUN_IO/setup.log" 2>&1 ||
      die "setup command failed in sandbox; see $RUN_IO/setup.log"
  fi
  if [ "$CHALK_SPEC_CHECK" = "true" ]; then
    run_spec_check ||
      die "rewrite the checkpoints in specs/$RUN_TICKET.md and commit, or set CHALK_SPEC_CHECK=false to skip this check"
  fi

  local failures=0 failed_reviews=0 feedback="" findings="" mode reason ended woke=""
  local open remaining result agent_status rubric_exit progressed output stuck key
  local -a lesson
  local -A usage fp base recall=()
  result="$RUN_IO/loop.json"
  while :; do
    # Every host-service call of this loop shares one budget.
    decider_budget_reset
    open="$(spec_open_count "$RUN_SPEC")"

    # Every checkpoint is ticked: review, then either submit or fix findings.
    if [ "$open" -eq 0 ] && [ -z "$findings" ]; then
      if run_review; then
        run_graduate
        return 0
      fi
      failed_reviews=$((failed_reviews + 1))
      if [ "$failed_reviews" -gt "$CHALK_REVIEW_ROUNDS" ]; then
        run_detain review "final review still finds problems after $CHALK_REVIEW_ROUNDS fix round(s)" "$RUN_REVIEW_FINDINGS"
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
      run_detain loop_limit "loop limit of $CHALK_MAX_LOOPS reached with $open checkpoints open"
      return 1
    fi

    run_build_prompt "$mode" "$feedback" "$findings" recall > "$RUN_IO/prompt.md"
    run_log "loop $RUN_LOOP ($mode) started"
    agent_status="ok"
    run_call loop "$CHALK_MODEL" "${CHALK_SCHEMA[loop]}" write < "$RUN_IO/prompt.md" || agent_status="error"
    if [ -n "$(agent_error "$result")" ]; then agent_status="$(agent_error "$result")"; fi
    agent_usage "$result" usage
    RUN_DENIALS="${usage[denials]}"

    # A reported blocker goes straight to an engineer; retrying cannot fix it.
    if [ "$(agent_field "$result" '.status')" = "blocked" ]; then
      fp=()
      run_verdict fp blocked
      db_record_call "$mode" blocked 0 false "$CHALK_MODEL" "$RUN_CALL_SECONDS" "$RUN_LESSONS" "$result" fp
      decider_flush
      run_detain blocked "agent reported a blocker" "$(agent_field "$result" '.blocker // .summary')"
      return 1
    fi

    rubric_exit=0
    run_rubric || rubric_exit=$?
    fp=()
    if [ "$agent_status" = "ok" ]; then run_fingerprint fp "$rubric_exit"; fi

    reason=""
    progressed="false"
    if [ "$agent_status" != "ok" ]; then
      reason="agent stopped early ($agent_status)"
      ended="agent_error"
    elif [ "$rubric_exit" -ne 0 ]; then
      reason="rubric failed (exit $rubric_exit)"
      ended="failed"
    else
      sandbox_commit "$RUN_SANDBOX" "chalk($RUN_TICKET): $mode, loop $RUN_LOOP"
      run_sync
      remaining="$(spec_open_count "$RUN_SPEC")"
      if [ "$mode" = "fix-review" ] || [ "$remaining" -lt "$open" ]; then
        progressed="true"
        ended="progressed"
      else
        reason="rubric passed but no checkpoint was ticked in the spec"
        ended="passed"
      fi
    fi
    # The baseline this loop is judged against, before run_verdict moves it on.
    base=()
    for key in "${!RUN_FP_BASE[@]}"; do base[$key]="${RUN_FP_BASE[$key]}"; done
    run_verdict fp "$ended"

    # A stuck question can follow from the next loop on, so the local
    # decider starts now if it is not running (run_start_decider). Logged
    # once a run; decider_start_once's lock keeps a start that is still
    # loading from being joined by a second copy.
    if [[ $ended == failed && $CHALK_FP_RULES != off ]] &&
       decider_start_bg "$RUN_IO/startup/decider.log" && [[ -z $woke ]]; then
      woke=1
      run_log "loop $RUN_LOOP failed its rubric: starting the local decider for the stuck question"
    fi

    # The gray zone: a failed loop the rules call spinning or other is put
    # to the decider. Only with fingerprints (not CHALK_FP_RULES=off).
    stuck=""
    if [[ $CHALK_DECIDER != off && $CHALK_FP_RULES != off && $ended == failed &&
          ${fp[verdict]-} == @(spinning|other) ]]; then
      stuck="${| decider_stuck "${| run_stuck_state base fp; }"; }"
    fi

    db_record_call "$mode" "$agent_status" "$rubric_exit" "$progressed" "$CHALK_MODEL" \
      "$RUN_CALL_SECONDS" "$RUN_LESSONS" "$result" fp
    decider_flush
    run_log "loop $RUN_LOOP ($mode): agent $agent_status (${| agent_usd "$(agent_cost "$result")"; }, ${RUN_CALL_SECONDS}s), rubric exit $rubric_exit. $(agent_field "$result" '.summary')"
    if (( usage[denials] > 0 )); then
      run_log "  ${usage[denials]} action(s) were refused by permission checks; see $result"
    fi

    if [ "$progressed" = "true" ]; then
      failures=0
      feedback=""
      findings=""
      recall=()
      continue
    fi

    # A lesson carries the fingerprint only of a loop whose rubric failed.
    lesson=("" "")
    if [ "$ended" = "failed" ]; then lesson=("${fp[fingerprint]-}" "${fp[first_error]-}"); fi
    # With CHALK_FP_RULES=on, a loop that repeats itself, changes nothing, or
    # fails like an open detention on another ticket is detained at once.
    if [ "$CHALK_FP_RULES" = "on" ] && fp_stops "${fp[verdict]-}"; then
      run_detain "${fp[verdict]}" "${fp[verdict]}: $reason" "" "${lesson[@]}"
      return 1
    fi
    # With CHALK_DECIDER=on, a confident "stuck" detains at once. A decider
    # can only stop a run early, never give it more loops.
    if [[ -n $stuck ]]; then
      printf -v RUN_STUCK_CONFIDENCE '%d.%02d' $((${stuck#* } / 1000)) $((${stuck#* } % 1000 / 10))
      run_detain stuck "stuck: $reason" "" "${lesson[@]}"
      return 1
    fi

    failures=$((failures + 1))
    if [ "$failures" -gt "$CHALK_MAX_RETRIES" ]; then
      run_detain "$ended" "$reason" "" "${lesson[@]}"
      return 1
    fi
    output="$(tail -n 60 "$RUN_IO/rubric.log" 2>/dev/null || true)"
    feedback="$reason
$output"
    # Recall goes by the failure itself, whatever form the feedback takes.
    run_recall recall "$feedback" fp
    # A rubric that printed nothing, such as one that writes only its test
    # report, gets the failing tests in place of its empty output.
    if [[ -v fp[tests] ]] && { [[ $CHALK_FP_FEEDBACK == true ]] || run_blank "$output"; }; then
      feedback="${| run_fp_feedback "$reason" fp; }"
    elif run_blank "$output"; then
      feedback="$reason
the rubric printed no output"
    fi
  done
}

# Runs only the spec check, so a spec can be fixed before any agent starts.
cmd_check() {
  run_context
  run_claim
  run_open_sandbox
  rm -f "$RUN_DIR/spec-check.ok"
  run_spec_check || die "specs/$RUN_TICKET.md is not ready for an agent"
}

# What `chalk status` calls each state of db_ticket_summary.
declare -gA RUN_STATE_NAMES=(
  [submitted]=submitted [detention]=detained [spec_blocked]=spec-blocked
  [ready]="done" [stopped]=stopped [new]=new
)

cmd_status() {
  need git
  local runs dir ticket state
  local -A summary
  local -a detentions
  # The most recently active runs first.
  local GLOBSORT=-mtime
  runs="${| state_dir; }/runs"
  printf '%-14s %-12s %-6s %-9s %-6s %s\n' TICKET STATE LOOPS COST FIXES DETENTIONS
  for dir in "$runs"/*/; do
    ticket="$(basename "$dir")"
    db_ticket_summary "$ticket" summary -
    state="${RUN_STATE_NAMES[${summary[state]}]-${summary[state]}}"
    if run_is_alive "${dir%/}"; then state="running"; fi
    mapfile -t detentions < <(git for-each-ref --format='%(refname:short)' "refs/heads/detention/$ticket-*")
    printf '%-14s %-12s %-6s %-9s %-6s %s\n' "$ticket" "$state" "${summary[loops]}" "${| agent_usd "${summary[cost]}"; }" "${summary[fixes]}" "${#detentions[@]}"
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
