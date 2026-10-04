# The repository Chalk is working in: its location and name, worktrees,
# ticket keys and specs.
#
# Functions marked `-> REPLY` are value functions (docs/bash-style.md):
# they set REPLY instead of printing, are called as ${| fn ARGS; }, and
# never return non-zero; "no value" is an empty REPLY.

# git_common_dir asks git once per working directory. Value functions run
# in the calling shell, so the answer outlives the call; with $( ) every
# call paid for a git process.
declare -gA REPO_COMMON_DIRS=()

# repo_root -> REPLY: root of the worktree we are standing in.
repo_root() {
  REPLY="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
}

# git_common_dir -> REPLY: directory holding the shared object store and
# refs for all worktrees.
git_common_dir() {
  if [[ ! -v REPO_COMMON_DIRS[$PWD] ]]; then
    REPO_COMMON_DIRS[$PWD]="$(git rev-parse --path-format=absolute --git-common-dir)"
  fi
  REPLY="${REPO_COMMON_DIRS[$PWD]}"
}

# main_root -> REPLY: root of the primary checkout, even from a linked worktree.
main_root() {
  git_common_dir
  REPLY="${REPLY%/*}"
  REPLY="${REPLY:-/}"
}

# repo_name -> REPLY
repo_name() {
  main_root
  REPLY="${REPLY##*/}"
}

# current_branch -> REPLY
current_branch() {
  REPLY="$(git rev-parse --abbrev-ref HEAD)"
}

# worktree_dir TICKET -> REPLY: where `chalk new` puts the ticket's worktree.
worktree_dir() {
  main_root
  REPLY="$REPLY.worktrees/$1"
}

# ticket_from_branch BRANCH -> REPLY: the Jira-style key in a branch name,
# e.g. chalk/PROJ-12 -> PROJ-12, or empty when there is none.
ticket_from_branch() {
  local re='([A-Z][A-Z0-9]+-[0-9]+)'
  REPLY=""
  if [[ $1 =~ $re ]]; then REPLY="${BASH_REMATCH[1]}"; fi
}

is_ticket() {
  local re='^[A-Z][A-Z0-9]+-[0-9]+$'
  [[ $1 =~ $re ]]
}

# Number of unchecked "- [ ]" checkpoints in a spec file.
spec_open_count() {
  grep -cE '^[[:space:]]*- \[ \]' "$1" || true
}

spec_title() {
  sed -n 's/^# //p' "$1" | head -n 1
}
