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
  # Why the final review did not run, when it did not (run_review).
  RUN_REVIEW_ERROR=""
  # Why the latest agent call failed, as agent_failure says; empty when it
  # did not. Recorded with the call, and read by run_next_step.
  RUN_CALL_FAILURE=""
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
  # 1 for a run that keeps certified early stops in shadow mode
  # (certify_holdout), drawn when the loop starts.
  RUN_HOLDOUT=0
  # The verdicts' mode for the call being recorded (run_fp_mode); empty
  # records CHALK_FP_RULES.
  RUN_FP_MODE=""
  # The fix a blocker proposes (evidence_fix), and its probe's run when the
  # run is detained or fails pre-flight, as JSON; empty when there is none.
  RUN_FIX=""
  RUN_EVIDENCE=""
  # The need pre-flight found failing, for its next step.
  RUN_PREFLIGHT_NEED=""
  RUN_FP_BASE=()
  # Set once the run has said how it ended (run_detain), so that
  # run_teardown parks the sandbox's work only after an unexpected exit.
  RUN_PARKED=""
  # Why run_sync or run_park_work failed, and whether a database write has
  # already failed in this run (run_db warns once).
  RUN_SYNC_ERROR=""
  RUN_PARK_ERROR=""
  RUN_DB_WARNED=""
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
# in this run's sandbox, timed into RUN_CALL_SECONDS, with why it failed, if
# it did, in RUN_CALL_FAILURE.
run_call() {
  local started=$SECONDS status=0
  agent_call "$RUN_SANDBOX" "$RUN_IO" "$@" || status=$?
  RUN_CALL_SECONDS=$((SECONDS - started))
  RUN_CALL_FAILURE="${| agent_failure "$RUN_IO" "$1"; }"
  return "$status"
}

# run_failure_step CLASS [RESUME] -> REPLY: what to do about an agent call
# that failed with CLASS (see agent_failure). RESUME says how to go on
# afterwards; by default, from a detention, with office hours.
run_failure_step() {
  local resume="${2:-resume with chalk office-hours}"
  case "$1" in
    tls)         REPLY="the sandbox does not trust this network's TLS certificates, as behind a proxy that re-signs HTTPS: set CHALK_EXTRA_CA_CERTS to a PEM file of its CA certificates (see Troubleshooting), then $resume" ;;
    network)     REPLY="the sandbox could not reach the API: check the network and any proxy, then $resume" ;;
    auth)        REPLY="the agent's credentials were refused: check ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN (chalk doctor says which one is used), then $resume" ;;
    cli_missing) REPLY="the claude CLI could not start in sandbox image $CHALK_IMAGE: rebuild the default image with chalk sandbox build, or install Claude Code in your own image" ;;
    usage_limit) REPLY="the Claude plan's usage limit was reached: wait until it resets, then $resume" ;;
    rate_limit|overloaded|server)
                 REPLY="the API was busy or failing: in a few minutes, $resume" ;;
    timeout)     REPLY="the agent gave no answer within CHALK_AGENT_TIMEOUT (now ${CHALK_AGENT_TIMEOUT}s): make the checkpoint smaller, or raise it" ;;
    budget)      REPLY="the call reached its spend cap: raise CHALK_BUDGET_USD (now $CHALK_BUDGET_USD), or make the checkpoint smaller" ;;
    max_turns)   REPLY="the agent ran out of turns: make the checkpoint smaller" ;;
    *)           REPLY="see why the agent stopped in $RUN_IO/loop.json and loop.err" ;;
  esac
}

# run_rubric_reason EXIT -> REPLY: why a loop failed, for a rubric that
# exited with EXIT. timeout(1) exits 124, a killed process 137 (usually out
# of memory), and bash 126 or 127 when a command cannot run.
run_rubric_reason() {
  case "$1" in
    124)     REPLY="rubric timed out after ${CHALK_RUBRIC_TIMEOUT}s (CHALK_RUBRIC_TIMEOUT)" ;;
    137)     REPLY="rubric was killed (exit 137), usually because the sandbox ran out of memory" ;;
    126|127) REPLY="rubric failed (exit $1): a command it runs was not found or cannot be executed" ;;
    *)       REPLY="rubric failed (exit $1)" ;;
  esac
}

run_teardown() {
  local status=$?
  if [[ -n ${RUN_SANDBOX:-} ]]; then
    # A run that ended any other way than detention or graduation, such as
    # a crash or a signal, still parks what the agent did since the last
    # checkpoint. Before the first loop there is no agent work to park.
    if [[ -z $RUN_PARKED ]] && (( RUN_LOOP > 0 )); then run_park_crash "$status"; fi
    if [[ $RUN_PARKED != kept ]]; then sandbox_stop "$RUN_SANDBOX"; fi
  fi
  rm -f "$RUN_DIR/pid"
}

# run_db FUNCTION ARGS...: a telemetry write during a run. The database is
# optional to a run in progress, so a failed write never ends it: the first
# failure is reported, its error kept in $RUN_IO/db.err, and the run goes on.
run_db() {
  local status=0
  "$@" 2>> "$RUN_IO/db.err" || status=$?
  if (( status != 0 )) && [[ -z $RUN_DB_WARNED ]]; then
    RUN_DB_WARNED=1
    warn "the telemetry database could not be written ($1, exit $status; see $RUN_IO/db.err). The run goes on; the report card will miss what was not recorded"
  fi
  return 0
}

# run_park_work MESSAGE [--allow-empty] -> REPLY: commits what is in the
# sandbox with MESSAGE, and fetches every commit since RUN_BASE onto a new
# detention branch, whose name it returns. Empty when there was nothing to
# park, or when parking failed; then RUN_PARK_ERROR says why.
run_park_work() {
  local branch out
  REPLY="" RUN_PARK_ERROR=""
  branch="${| run_detention_branch; }"
  if ! out="$(sandbox_commit "$RUN_SANDBOX" "$1" "${2:-}" 2>&1)"; then
    RUN_PARK_ERROR="the sandbox could not commit: ${out:-no output}"
  elif ! out="$(sandbox_export "$RUN_SANDBOX" "$RUN_BASE" 2>&1)"; then
    RUN_PARK_ERROR="the sandbox could not export its commits: ${out:-no output}"
  elif [[ ! -f $RUN_IO/out.bundle ]]; then
    :
  elif ! out="$(git -C "$RUN_WT" fetch -q "$RUN_IO/out.bundle" "HEAD:refs/heads/$branch" 2>&1)"; then
    RUN_PARK_ERROR="git could not fetch the sandbox's commits: ${out:-no output}"
  else
    REPLY="$branch"
  fi
}

# run_park_failed: says what became of the sandbox's work when
# run_park_work failed. A container that still exists is kept under a new
# name, so that the next run of the ticket does not remove it.
run_park_failed() {
  local kept="$RUN_SANDBOX-kept-$EPOCHSECONDS"
  run_log "the agent's work could not be parked on a branch: $RUN_PARK_ERROR"
  if docker rename "$RUN_SANDBOX" "$kept" >/dev/null 2>&1; then
    RUN_PARKED=kept
    run_log "the sandbox is kept as $kept; copy the work out with:"
    run_log "  docker cp $kept:/work/repo ${RUN_WT@Q}.recovered && docker rm -f $kept"
  else
    run_log "the sandbox is gone, so work since the last checkpoint is lost; $RUN_BRANCH holds every checkpoint up to there"
  fi
}

# run_park_crash STATUS: parks the sandbox's work after the run exited
# with STATUS without saying how it ended: a signal (above 128) or an
# unexpected failure. Runs from the EXIT trap, so nothing here may fail.
run_park_crash() {
  local status="$1" reason branch
  RUN_PARKED=1
  if (( status > 128 )); then reason="run stopped by a signal (exit $status)"
  else reason="Chalk stopped unexpectedly (exit $status)"
  fi
  branch="${| run_park_work "detention($RUN_TICKET): $reason"; }"
  if [[ -n $branch ]]; then
    run_db db_open_lesson "${| repo_name; }" "$RUN_TICKET" "$reason" "$RUN_ID"
    run_db db_event "$RUN_TICKET" detention
    run_log "$reason; the agent's work since the last checkpoint is parked on local branch $branch. To go on:"
    run_log "  cd ${RUN_WT@Q} && git switch ${branch@Q}"
    run_log "  fix what stopped the run, then: chalk office-hours -m \"what stopped it\""
  elif [[ -n $RUN_PARK_ERROR ]]; then
    run_log "$reason"
    run_park_failed
  else
    run_log "$reason; the sandbox had no work beyond $RUN_BRANCH, which holds every checkpoint so far"
  fi
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

# run_call_model RESULT -> REPLY: the model an agent call ran on, as
# db_record_call records it: the one RESULT reports, else CHALK_MODEL, else
# "default". Verdicts are certified per model (certify_verdict).
run_call_model() {
  REPLY="$(agent_model "$1" 2>/dev/null || true)"
  REPLY="${REPLY:-${CHALK_MODEL:-default}}"
}

# run_fp_mode VERDICT MODEL -> REPLY: the mode a loop's verdict is taken in.
# off and shadow are CHALK_FP_RULES. Under on, it is on only for a stopping
# verdict (fp_stops) that is certified for MODEL (certify_verdict), in a
# run that is not a holdout (RUN_HOLDOUT); otherwise the loop records it in
# shadow mode, saying why once per run.
run_fp_mode() {
  local -A cert
  REPLY="$CHALK_FP_RULES"
  [[ $REPLY == on ]] || return 0
  REPLY=shadow
  fp_stops "$1" || return 0
  certify_verdict "$1" "$2" cert
  if [[ ${cert[status]} != certified ]]; then
    certify_warn_once "held:$1" "CHALK_FP_RULES=on records $1 in shadow mode only: ${| certify_note cert; } (see: chalk certify)"
    return 0
  fi
  if (( RUN_HOLDOUT )); then
    if [[ ! -v CERTIFY_WARNED[holdout] ]]; then
      CERTIFY_WARNED["holdout"]=1
      run_log "this run is a holdout (CHALK_HOLDOUT=$CHALK_HOLDOUT): certified verdicts are recorded, not acted on, so that they go on being judged"
    fi
    return 0
  fi
  REPLY=on
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

# Brings commits made in the sandbox onto the host branch (fast-forward
# only). Returns non-zero when they cannot be brought over, as when the
# branch moved on the host during the run, with RUN_SYNC_ERROR saying why;
# the commits are still in the sandbox then, for run_detain to park.
run_sync() {
  local out
  RUN_SYNC_ERROR=""
  if ! out="$(sandbox_export "$RUN_SANDBOX" "$RUN_BASE" 2>&1)"; then
    RUN_SYNC_ERROR="the sandbox could not export its commits: ${out:-no output}"
    return 1
  fi
  [ -f "$RUN_IO/out.bundle" ] || return 0
  if ! out="$(git -C "$RUN_WT" fetch -q "$RUN_IO/out.bundle" HEAD 2>&1)" ||
     ! out="$(git -C "$RUN_WT" -c advice.diverging=false merge -q --ff-only FETCH_HEAD 2>&1)"; then
    RUN_SYNC_ERROR="${out:-git gave no reason}"
    return 1
  fi
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
  local class
  class="${| agent_failure_class "$RUN_CALL_FAILURE"; }"
  if [[ -n $RUN_CALL_FAILURE ]] && ! agent_failure_retryable "$class"; then
    run_db db_record_call spec-check none 0 false "$CHALK_CHEAP_MODEL" "$RUN_CALL_SECONDS" 0 "$result"
    die "the spec check could not run ($RUN_CALL_FAILURE); ${| run_failure_step "$class" "run chalk run again"; }"
  fi

  verdict="$(agent_field "$result" '.verdict')"
  run_db db_record_call spec-check "${verdict:-none}" 0 false "$CHALK_CHEAP_MODEL" "$RUN_CALL_SECONDS" 0 "$result"
  case "$verdict" in
    pass)
      printf '%s\n' "$hash" > "$stamp"
      run_log "spec check passed (${| agent_usd "$(agent_cost "$result")"; }, ${RUN_CALL_SECONDS}s)" ;;
    fail)
      run_db db_event "$RUN_TICKET" spec_blocked
      run_log "spec check found checkpoints that are not ready:"
      run_log "$(agent_field "$result" '.problems[] | "  - \(.checkpoint)\n    problem: \(.problem)"
        + (if .suggestion then "\n    suggestion: \(.suggestion)" else "" end)')"
      return 1 ;;
    *) warn "spec check returned no verdict${RUN_CALL_FAILURE:+ ($RUN_CALL_FAILURE)}; continuing without it" ;;
  esac
}

# Independent review of the finished work. Returns 1 on an explicit "fail"
# verdict, leaving the findings in RUN_REVIEW_FINDINGS, and 2 when the
# review gave no verdict and CHALK_REVIEW_REQUIRED is true, with why in
# RUN_REVIEW_ERROR.
run_review() {
  RUN_REVIEW_FINDINGS="" RUN_REVIEW_ERROR=""
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
  run_db db_record_call review "${verdict:-none}" 0 false "${CHALK_REVIEW_MODEL:-$CHALK_MODEL}" "$RUN_CALL_SECONDS" 0 "$result"
  RUN_REVIEW_SUMMARY="$(agent_field "$result" '.summary')"
  run_log "final review: ${verdict:-no verdict}. $RUN_REVIEW_SUMMARY"

  if [ "$verdict" = "fail" ]; then
    RUN_REVIEW_FINDINGS="$(agent_field "$result" \
      '.findings[] | "- [\(.severity)] " + (if .file then "\(.file): " else "" end) + .issue')"
    return 1
  fi
  if [[ -z $verdict ]]; then
    RUN_REVIEW_ERROR="${RUN_CALL_FAILURE:-it gave no verdict}"
    [[ $CHALK_REVIEW_REQUIRED != true ]] || return 2
    warn "the final review did not run ($RUN_REVIEW_ERROR); opening the request without it, as CHALK_REVIEW_REQUIRED=false"
  fi
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
    blocked)     run_fix_step ;;
    preflight)   REPLY="the environment lacks what an earlier ticket needed (${RUN_PREFLIGHT_NEED:-a saved need}); restore it in CHALK_IMAGE or CHALK_SETUP_CMD, check with: chalk needs" ;;
    loop_limit)  REPLY="split the open checkpoints into smaller ones, or raise CHALK_MAX_LOOPS (now $CHALK_MAX_LOOPS)" ;;
    review)      REPLY="fix the review findings above, or raise CHALK_REVIEW_ROUNDS (now $CHALK_REVIEW_ROUNDS)" ;;
    failed)      REPLY="the rubric still fails after $CHALK_MAX_RETRIES retries; fix the failure in $RUN_IO/rubric.log, or make the checkpoint smaller" ;;
    agent_error) run_failure_step "${| agent_failure_class "$RUN_CALL_FAILURE"; }" ;;
    review_error) REPLY="the final review could not run: ${| run_failure_step "${| agent_failure_class "$RUN_CALL_FAILURE"; }"; }; or set CHALK_REVIEW_REQUIRED=false to open requests without a review" ;;
    sync)        REPLY="$RUN_BRANCH changed in $RUN_WT during the run, so the loop's commits could not be fast-forwarded onto it; merge the detention branch into $RUN_BRANCH yourself, and commit nothing to a branch while Chalk runs on it" ;;
    passed)      REPLY="the rubric passes but no checkpoint was ticked; tick it if it is done, or make it testable" ;;
    deja_vu)     REPLY="this fails like the open detention of ${RUN_OPEN_TICKET:-another ticket}; fix that one first" ;;
    repeat)      REPLY="the agent made the same failing change twice; fix the failure yourself, a retry would repeat it" ;;
    no_change)   REPLY="the agent changed nothing; make the checkpoint clearer, or do this step yourself" ;;
    stuck)       REPLY="the decider judged the agent stuck on the same root cause as the loop before (confidence $RUN_STUCK_CONFIDENCE); fix that cause yourself, a retry would likely fail the same way" ;;
    *)           REPLY="fix what stopped the run" ;;
  esac
}

# run_preflight: before the first loop, runs every need saved in
# .chalk/needs (evidence_needs) in the sandbox, so that an environment gap
# an earlier ticket paid for is caught at no loop spend. A need that fails
# detains the run as preflight, its lesson carrying the need's probe, so
# that office hours checks the fix. An inconclusive one (a timeout) is
# reported, and the run goes on: it proves nothing either way.
run_preflight() {
  local need probe kind ticket id
  local -a needs
  local -A got
  evidence_needs "$RUN_WT" needs
  (( ${#needs[@]} )) || return 0
  for need in "${needs[@]}"; do
    IFS=$'\t' read -r probe kind ticket id <<<"$need"
    evidence_probe "$RUN_SANDBOX" "$probe" got
    case "${got[outcome]}" in
      passed) continue ;;
      inconclusive)
        run_log "pre-flight: the saved need \`$probe\` was inconclusive (${got[output]%%$'\n'*}); going on"
        continue ;;
    esac
    RUN_PREFLIGHT_NEED="\`$probe\`, saved by $ticket"
    RUN_FIX="$(jq -cn --arg kind "$kind" --arg probe "$probe" --arg ticket "$ticket" --arg id "$id" \
                 '{kind: $kind, why: "a need saved by \($ticket) (lesson \($id)) fails", probe: $probe}')"
    RUN_EVIDENCE="$(jq -cn --argjson fix "$RUN_FIX" --arg o failed --arg e "${got[exit]}" --arg out "${got[output]}" \
                      --arg image "${| evidence_image; }" '{fix: $fix, outcome: $o, exit: $e, output: $out, image: $image}')"
    run_detain preflight "pre-flight: a saved need fails: $probe" "${got[output]}"
    return 1
  done
  run_log "pre-flight: ${#needs[@]} saved need(s) hold"
}

# run_fix_step -> REPLY: the next step for a blocker, by the kind of fix
# the agent proposed (RUN_FIX); without one, what it always was.
run_fix_step() {
  local kind="" image config
  if [[ -n $RUN_FIX ]]; then kind="$(jq -r '.kind // empty' <<<"$RUN_FIX" 2>/dev/null || true)"; fi
  case "$kind" in
    image)
      image="$(jq -r '.image // "what the probe needs"' <<<"$RUN_FIX")"
      if [[ $CHALK_IMAGE == "$CHALK_DEFAULT_IMAGE" ]]; then
        REPLY="build a repository image FROM $CHALK_DEFAULT_IMAGE that adds: $image; set CHALK_IMAGE to it in .chalk/config and commit"
      else
        REPLY="add to the image you build as CHALK_IMAGE ($CHALK_IMAGE): $image"
      fi ;;
    config)
      config="$(jq -r '[.config // {} | to_entries[] | "\(.key)=\(.value)"] | join(", ")' <<<"$RUN_FIX")"
      REPLY="set in .chalk/config and commit: ${config:-the setting the agent names above}" ;;
    spec)       REPLY="change specs/$RUN_TICKET.md as the agent suggests above, and commit" ;;
    credential) REPLY="provide the access the agent asked for above; the sandbox holds no credentials" ;;
    *)          REPLY="provide what the agent asked for above, such as a credential, access or a decision" ;;
  esac
  if [[ $kind == @(image|config) ]]; then REPLY+="; the probe is checked again in a fresh sandbox at office hours"; fi
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
# (deja_vu, repeat or no_change), or stuck when the decider stopped it;
# or sync when the loop's commits could not be brought onto the branch.
# FINGERPRINT and FIRST_ERROR are given only
# when the loop that detained the run failed its rubric.
# The work is parked and the next step said before anything is written to
# the database, and a failed write does not stop either (run_db).
run_detain() {
  local kind="$1" reason="$2" detail="${3:-}" fingerprint="${4:-}" first_error="${5:-}" branch signature
  RUN_PARKED=1
  branch="${| run_park_work "detention($RUN_TICKET): $reason" --allow-empty; }"

  run_log "DETENTION: $reason"
  if [ -n "$detail" ]; then run_log "$detail"; fi
  if [[ -n $RUN_FIX ]]; then run_blocker_evidence; fi
  run_log "next: ${| run_next_step "$kind"; }"
  if [[ -n $branch ]]; then
    run_log "work parked on local branch $branch. To unblock:"
    run_log "  cd ${RUN_WT@Q} && git switch ${branch@Q}"
    run_log "  fix the blocker, commit, then: chalk office-hours -m \"what was wrong\""
  else
    run_park_failed
  fi

  signature="$reason"
  if [ -n "$detail" ]; then
    signature="$signature
$detail"
  elif [[ $kind != @(agent_error|review_error) && -s $RUN_IO/rubric.log ]]; then
    signature="$signature
$(tail -n 40 "$RUN_IO/rubric.log")"
  fi
  run_db db_open_lesson "${| repo_name; }" "$RUN_TICKET" "$signature" "$RUN_ID" "$fingerprint" "$first_error" \
    "$RUN_EVIDENCE"
  run_db db_event "$RUN_TICKET" detention
}

# run_blocker_evidence: shows the fix the agent proposed (RUN_FIX) and, for
# one with a probe, runs it, after the detention commit so that nothing it
# writes reaches the detention branch, unless pre-flight already did
# (RUN_EVIDENCE). Its outcome is proof, not a verdict: the run is detained
# either way. Sets RUN_EVIDENCE for the lesson.
run_blocker_evidence() {
  local probe line
  local -A got
  run_log "the agent proposes a fix:"
  while IFS= read -r line; do run_log "  $line"; done <<<"${| evidence_fix_text "$RUN_FIX"; }"
  probe="$(jq -r '.probe // empty' <<<"$RUN_FIX")"
  if [[ -z $RUN_EVIDENCE ]]; then
    RUN_EVIDENCE="$(jq -c '{fix: .}' <<<"$RUN_FIX")"
    [[ -n $probe ]] || return 0
    evidence_probe "$RUN_SANDBOX" "$probe" got
    RUN_EVIDENCE="$(jq -c --arg o "${got[outcome]}" --arg e "${got[exit]}" --arg out "${got[output]}" \
                       --arg image "${| evidence_image; }" '. + {outcome: $o, exit: $e, output: $out, image: $image}' \
                       <<<"$RUN_EVIDENCE")"
  fi
  [[ -n $probe ]] || return 0
  case "$(jq -r '.outcome // empty' <<<"$RUN_EVIDENCE")" in
    failed) run_log "proof: the probe fails (exit $(jq -r .exit <<<"$RUN_EVIDENCE")), so the blocker is real; it must pass once you fix it" ;;
    passed) run_log "the probe passes, so this blocker may not be real: check it before changing anything" ;;
    *)      run_log "the probe was inconclusive ($(jq -r '.output // "no output"' <<<"$RUN_EVIDENCE" | head -n 1)), so it proves nothing" ;;
  esac
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
  elif [[ -n $RUN_REVIEW_ERROR ]]; then
    review="
- Agent review before submission: did not run ($RUN_REVIEW_ERROR)"
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
  RUN_HOLDOUT="${| certify_holdout; }"
  run_open_sandbox
  if [ -n "$CHALK_SETUP_CMD" ]; then
    run_log "running the setup command: $CHALK_SETUP_CMD"
    sandbox_sh "$RUN_SANDBOX" "$CHALK_SETUP_CMD" > "$RUN_IO/setup.log" 2>&1 ||
      die "setup command failed in sandbox; see $RUN_IO/setup.log"
  fi
  run_preflight || return 1
  if [ "$CHALK_SPEC_CHECK" = "true" ]; then
    run_spec_check ||
      die "rewrite the checkpoints in specs/$RUN_TICKET.md and commit, or set CHALK_SPEC_CHECK=false to skip this check"
  fi

  local failures=0 failed_reviews=0 feedback="" findings="" mode reason ended woke="" reviewed
  local open remaining result agent_status rubric_exit progressed output stuck key fp_mode
  local -a lesson
  local -A usage fp base recall=()
  result="$RUN_IO/loop.json"
  while :; do
    # Every host-service call of this loop shares one budget.
    decider_budget_reset
    open="$(spec_open_count "$RUN_SPEC")"

    # Every checkpoint is ticked: review, then either submit or fix findings.
    if [ "$open" -eq 0 ] && [ -z "$findings" ]; then
      reviewed=0
      run_review || reviewed=$?
      if (( reviewed == 0 )); then
        run_graduate
        return 0
      fi
      if (( reviewed == 2 )); then
        run_detain review_error "the final review did not run ($RUN_REVIEW_ERROR)"
        return 1
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
    run_call loop "$CHALK_MODEL" "${CHALK_SCHEMA[loop]}" write < "$RUN_IO/prompt.md" || true
    agent_status="ok"
    if [[ -n $RUN_CALL_FAILURE ]]; then agent_status="${| agent_failure_class "$RUN_CALL_FAILURE"; }"; fi
    agent_usage "$result" usage
    RUN_DENIALS="${usage[denials]}"

    # A reported blocker goes straight to an engineer; retrying cannot fix it.
    if [ "$(agent_field "$result" '.status')" = "blocked" ]; then
      fp=()
      run_verdict fp blocked
      run_db db_record_call "$mode" blocked 0 false "$CHALK_MODEL" "$RUN_CALL_SECONDS" "$RUN_LESSONS" "$result" fp
      decider_flush
      RUN_FIX="${| evidence_fix "$result"; }"
      if [[ -n $EVIDENCE_FIX_PROBLEM ]]; then run_log "the agent's proposed fix was not kept: $EVIDENCE_FIX_PROBLEM"; fi
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
      reason="agent stopped early ($RUN_CALL_FAILURE)"
      ended="agent_error"
    elif [ "$rubric_exit" -ne 0 ]; then
      reason="${| run_rubric_reason "$rubric_exit"; }"
      ended="failed"
    else
      sandbox_commit "$RUN_SANDBOX" "chalk($RUN_TICKET): $mode, loop $RUN_LOOP"
      if ! run_sync; then
        run_db db_record_call "$mode" "$agent_status" "$rubric_exit" false "$CHALK_MODEL" \
          "$RUN_CALL_SECONDS" "$RUN_LESSONS" "$result" fp
        decider_flush
        run_detain sync "the loop's commits could not be brought onto $RUN_BRANCH" "$RUN_SYNC_ERROR"
        return 1
      fi
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

    # Whether this loop's verdict may stop the run, decided before the call
    # is recorded, since the call records the mode it was taken in.
    fp_mode="${| run_fp_mode "${fp[verdict]-}" "${| run_call_model "$result"; }"; }"
    RUN_FP_MODE="$fp_mode"
    run_db db_record_call "$mode" "$agent_status" "$rubric_exit" "$progressed" "$CHALK_MODEL" \
      "$RUN_CALL_SECONDS" "$RUN_LESSONS" "$result" fp
    RUN_FP_MODE=""
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

    # A call that fails the same way every time, such as one whose
    # credentials were refused, is not retried.
    if [[ $ended == agent_error ]] && ! agent_failure_retryable "$agent_status"; then
      run_detain agent_error "$reason"
      return 1
    fi
    # A lesson carries the fingerprint only of a loop whose rubric failed.
    lesson=("" "")
    if [ "$ended" = "failed" ]; then lesson=("${fp[fingerprint]-}" "${fp[first_error]-}"); fi
    # With CHALK_FP_RULES=on, a loop that repeats itself, changes nothing, or
    # fails like an open detention on another ticket is detained at once,
    # once that verdict is certified (run_fp_mode).
    if [[ $fp_mode == on ]]; then
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
