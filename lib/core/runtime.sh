# The shell runtime every other file relies on.

need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed (see: chalk doctor)"
  done
}

# bash_at_least MIN_MAJOR MIN_MINOR [MAJOR MINOR]: true when a bash version,
# by default this one, is at least MIN_MAJOR.MIN_MINOR.
bash_at_least() {
  local major="${3:-${BASH_VERSINFO[0]}}" minor="${4:-${BASH_VERSINFO[1]}}"
  (( major > $1 || (major == $1 && minor >= $2) ))
}
