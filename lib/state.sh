# Per-repository state on this machine: run directories and their pid files.
# Functions marked `-> REPLY` are value functions (docs/bash-style.md).

# state_dir -> REPLY
state_dir() {
  repo_name
  REPLY="${XDG_STATE_HOME:-$HOME/.local/state}/chalk/$REPLY"
}

# run_dir TICKET -> REPLY
run_dir() {
  state_dir
  REPLY="$REPLY/runs/$1"
}

# run_pid RUN_DIR -> REPLY: the pid recorded for a run, or empty.
run_pid() {
  REPLY=""
  if [[ -f $1/pid ]]; then read -r REPLY < "$1/pid" || true; fi
}

# True when the run recorded in the given run dir is still alive.
run_is_alive() {
  local pid
  pid="${| run_pid "$1"; }"
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}
