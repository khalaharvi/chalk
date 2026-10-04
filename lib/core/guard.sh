# bash 3.2 syntax: this file runs before Chalk knows which bash it is under.
# Keep it that way; everything else in lib/ requires bash 5.3.
#
# chalk_guard ARGS...: returns if this bash is new enough. Otherwise it
# re-executes the running script under the first bash >= 5.3 it finds, or
# exits with instructions. The search order is CHALK_BASH, the Homebrew
# locations, then every bash on PATH.

CHALK_BASH_MIN="5.3"

# chalk_bash_new_enough MAJOR MINOR
chalk_bash_new_enough() {
  [ "$1" -gt 5 ] || { [ "$1" -eq 5 ] && [ "$2" -ge 3 ]; }
}

chalk_guard() {
  if chalk_bash_new_enough "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"; then
    # Not passed on, so a Chalk that this one starts runs its own guard.
    unset CHALK_REEXECED
    return 0
  fi
  if [ -z "${CHALK_REEXECED:-}" ]; then
    local candidates candidate version
    candidates="${CHALK_BASH:-}
/opt/homebrew/bin/bash
/usr/local/bin/bash
/home/linuxbrew/.linuxbrew/bin/bash
$(type -ap bash 2>/dev/null || true)"
    # The list is read on fd 3 so that the re-executed Chalk keeps our stdin.
    while IFS= read -r candidate <&3; do
      [ -n "$candidate" ] && [ -x "$candidate" ] || continue
      version="$("$candidate" -c "echo \"\${BASH_VERSINFO[0]} \${BASH_VERSINFO[1]}\"" 2>/dev/null)" || continue
      if chalk_bash_new_enough "${version% *}" "${version#* }"; then
        export CHALK_REEXECED=1
        exec "$candidate" "$0" ${1+"$@"} 3<&-
      fi
    done 3<<CANDIDATES
$candidates
CANDIDATES
  fi
  printf 'error: chalk needs bash >= %s (this is %s).\n' "$CHALK_BASH_MIN" "$BASH_VERSION" >&2
  printf "Install it with 'brew install bash', or set CHALK_BASH to a bash %s or newer.\n" "$CHALK_BASH_MIN" >&2
  exit 1
}
