# The shell runtime every other file relies on: strict settings, a report
# for unexpected failures, conventional exit codes on signals, and checks
# for the tools and bash version Chalk needs.

set -Eeuo pipefail
shopt -s inherit_errexit extglob nullglob globskipdots

# Reports a command that failed unexpectedly, with the functions it was
# called from, before errexit ends Chalk. Two failures are not reported:
# a function that returns non-zero on purpose (the trap then sees its
# `return`), and a failed command substitution, which was already reported
# where it failed inside.
runtime_on_err() {
  local status=$? command=$BASH_COMMAND i
  if [[ $command == @(return|return *) || $command == *@('$('|'${ '|'${|')* ]]; then
    return "$status"
  fi
  printf 'error: unexpected failure (exit %s): %s\n' "$status" "$command" >&2
  for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
    printf '  in %s (%s:%s)\n' "${FUNCNAME[i]}" "${BASH_SOURCE[i]#"$CHALK_HOME/"}" "${BASH_LINENO[i - 1]}" >&2
  done
  return "$status"
}

# A signal ends Chalk with 128 + the signal's number, the code a shell
# reports for a process killed by that signal. EXIT traps still run.
runtime_on_signal() { exit $((128 + BASH_TRAPSIG)); }

trap runtime_on_err ERR
trap runtime_on_signal INT TERM HUP

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
