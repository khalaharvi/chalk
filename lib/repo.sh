# The repository Chalk is working in: its location and name, worktrees,
# ticket keys and specs.

# Root of the worktree we are standing in.
repo_root() { git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"; }

# Directory holding the shared object store and refs for all worktrees.
git_common_dir() { git rev-parse --path-format=absolute --git-common-dir; }

# Root of the primary checkout, even when called from a linked worktree.
main_root() { dirname "$(git_common_dir)"; }

repo_name() { basename "$(main_root)"; }

current_branch() { git rev-parse --abbrev-ref HEAD; }

worktree_dir() { printf '%s.worktrees/%s\n' "$(main_root)" "$1"; }

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
