# Shared helpers for the unit tests in this directory. Each test file sources
# this, loads the modules it needs with `load`, and calls `check`.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHALK_HOME="$(cd "$here/../.." && pwd)"
export CHALK_HOME

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Tests that commit must not depend on the machine's git identity.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; exit 1; }

# check LABEL COMMAND...: passes when COMMAND succeeds.
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

# load MODULE...: sources lib/MODULE.sh, e.g. `load core/log repo`.
load() {
  local module
  for module in "$@"; do
    # shellcheck source=/dev/null
    . "$CHALK_HOME/lib/$module.sh"
  done
}

# old_bash: prints a system bash older than 5.3 (macOS /bin/bash is 3.2,
# Ubuntu's is 5.2), or nothing when this machine has none.
old_bash() {
  local candidate
  for candidate in /bin/bash /usr/bin/bash; do
    [ -x "$candidate" ] || continue
    if ! "$candidate" -c '[ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }'; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}
