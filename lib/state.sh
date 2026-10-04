# Per-repository state on this machine: run directories and their pid files.

state_dir() { printf '%s/chalk/%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$(repo_name)"; }

run_dir() { printf '%s/runs/%s\n' "$(state_dir)" "$1"; }

# True when the run recorded in the given run dir is still alive.
run_is_alive() {
  local pid_file="$1/pid"
  [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}
