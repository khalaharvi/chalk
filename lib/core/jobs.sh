# Named background jobs: start several things at once and collect each
# result by name.
#
#   jobs_init "$RUN_IO/startup"
#   jobs_spawn database db_up
#   jobs_spawn image    sandbox_ensure_image
#   local -A results
#   jobs_wait results || ...
#
# A job's output goes to LOG_DIR/NAME.log and is replayed when the job
# ends: on stdout if it succeeded, on stderr if it failed. `die` inside a
# job ends only that job; its caller decides what the failure means.

declare -gA JOBS_RUNNING=()   # pid -> name
JOBS_LOG_DIR=""

# jobs_init LOG_DIR: starts a new set of jobs logging to LOG_DIR.
jobs_init() {
  JOBS_LOG_DIR="$1"
  JOBS_RUNNING=()
  mkdir -p "$JOBS_LOG_DIR"
}

# jobs_spawn NAME COMMAND [ARGS...]: runs COMMAND in the background.
jobs_spawn() {
  local name="$1"
  shift
  "$@" > "$JOBS_LOG_DIR/$name.log" 2>&1 &
  JOBS_RUNNING[$!]="$name"
}

# jobs_detach LOG COMMAND [ARGS...]: starts COMMAND in the background and
# lets it go: it is never waited for, outlives this process, and runs in a
# process group of its own, so a Ctrl-C meant for Chalk does not reach it.
# Its output is appended to LOG. It does not inherit the locks this
# process holds through flock (see chalk_lock).
jobs_detach() {
  local log="$1" fd
  shift
  (
    for fd in "${CHALK_LOCK_FDS[@]}"; do exec {fd}>&-; done
    set -m
    "$@" < /dev/null >> "$log" 2>&1 &
  )
}

# jobs_wait VAR: waits for every job, in the order they finish, and fills
# the associative array VAR with each job's exit status by name. Returns
# non-zero when any job failed.
jobs_wait() {
  local -n __results=$1
  local pid status name failed=0
  __results=()
  while (( ${#JOBS_RUNNING[@]} )); do
    pid="" status=0
    wait -n -p pid "${!JOBS_RUNNING[@]}" || status=$?
    [[ -n $pid ]] || break
    name="${JOBS_RUNNING[$pid]}"
    unset 'JOBS_RUNNING[$pid]'
    __results["$name"]="$status"
    if (( status == 0 )); then
      cat "$JOBS_LOG_DIR/$name.log"
    else
      failed=1
      cat "$JOBS_LOG_DIR/$name.log" >&2
    fi
  done
  return "$failed"
}
