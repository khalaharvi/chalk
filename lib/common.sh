# Shared helpers. Compatible with bash 3.2 (macOS default).

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed (see: chalk doctor)"
  done
}

# Root of the worktree we are standing in.
repo_root() { git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"; }

# Directory holding the shared object store and refs for all worktrees.
git_common_dir() { git rev-parse --path-format=absolute --git-common-dir; }

# Root of the primary checkout, even when called from a linked worktree.
main_root() { dirname "$(git_common_dir)"; }

repo_name() { basename "$(main_root)"; }

current_branch() { git rev-parse --abbrev-ref HEAD; }

# Prints the Jira-style key embedded in a branch name, e.g. chalk/PROJ-12 -> PROJ-12.
ticket_from_branch() {
  local re='([A-Z][A-Z0-9]+-[0-9]+)'
  [[ "$1" =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

is_ticket() {
  local re='^[A-Z][A-Z0-9]+-[0-9]+$'
  [[ "$1" =~ $re ]]
}

# Number of unchecked "- [ ]" checkpoints in a spec file.
spec_open_count() {
  grep -cE '^[[:space:]]*- \[ \]' "$1" || true
}

spec_title() {
  sed -n 's/^# //p' "$1" | head -n 1
}

worktree_dir() { printf '%s.worktrees/%s\n' "$(main_root)" "$1"; }

state_dir() { printf '%s/chalk/%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$(repo_name)"; }

run_dir() { printf '%s/runs/%s\n' "$(state_dir)" "$1"; }

# True when the run recorded in the given run dir is still alive.
run_is_alive() {
  local pid_file="$1/pid"
  [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}
