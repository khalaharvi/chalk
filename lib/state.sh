# Per-repository state on this machine: run directories and their pid files.

state_dir() { printf '%s/chalk/%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$(repo_name)"; }

run_dir() { printf '%s/runs/%s\n' "$(state_dir)" "$1"; }

# run_pid RUN_DIR: prints the pid recorded for a run, or fails if none is.
run_pid() {
  local pid
  [[ -f $1/pid ]] && read -r pid < "$1/pid" && printf '%s\n' "$pid"
}

# True when the run recorded in the given run dir is still alive.
run_is_alive() {
  local pid
  pid="$(run_pid "$1")" && kill -0 "$pid" 2>/dev/null
}
