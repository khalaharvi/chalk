#!/usr/bin/env bash
# lib/core/guard.sh: an old bash re-executes Chalk under a new one, or stops
# with instructions. Needs a system bash older than 5.3 to run against.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"

old="$(old_bash)"
new="$BASH"
if [ -z "$old" ]; then
  printf 'skip guard tests: no system bash older than 5.3 on this machine\n'
  exit 0
fi

# Prints the bash version it ends up under, its arguments, one line of
# stdin, and whether the re-exec marker leaked.
cat > "$tmp/harness" <<'HARNESS'
. "$CHALK_HOME/lib/core/guard.sh"
chalk_guard "$@"
read -r line || true
printf '%s.%s|%s|%s|%s\n' "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "$*" "${line:-}" "${CHALK_REEXECED-unset}"
HARNESS

under_old() { env PATH=/usr/bin:/bin "$@"; }

check "a new bash runs without re-executing" \
  test "$(echo in | "$new" "$tmp/harness" a | cut -d'|' -f1)" = \
       "$("$new" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"

result="$(echo hello | under_old CHALK_BASH="$new" "$old" "$tmp/harness" a "b c")"
check "an old bash re-executes under CHALK_BASH" test "${result%%|*}" = "$("$new" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
check "arguments survive the re-exec" test "$(cut -d'|' -f2 <<<"$result")" = "a b c"
check "stdin survives the re-exec" test "$(cut -d'|' -f3 <<<"$result")" = "hello"
check "the re-exec marker is not passed on" test "$(cut -d'|' -f4 <<<"$result")" = "unset"

check "the real entry point re-executes" \
  test "$(under_old CHALK_BASH="$new" "$old" "$CHALK_HOME/bin/chalk" version)" = \
       "$(sed -n 's/^CHALK_VERSION="\(.*\)"$/\1/p' "$CHALK_HOME/bin/chalk")"

if output="$(under_old CHALK_REEXECED=1 "$old" "$tmp/harness" 2>&1 </dev/null)"; then
  fail "a second re-exec is refused"
fi
check "a second re-exec is refused with instructions" \
  grep -q "chalk needs bash >= 5.3.*brew install bash" <<<"${output//$'\n'/ }"

homebrew_bash=""
for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash; do
  if [ -x "$candidate" ]; then homebrew_bash="$candidate"; fi
done
if [ -n "$homebrew_bash" ]; then
  printf 'skip "no new bash anywhere": %s exists\n' "$homebrew_bash"
else
  if output="$(under_old env -u CHALK_BASH "$old" "$tmp/harness" 2>&1 </dev/null)"; then
    fail "no new bash anywhere stops with an error"
  fi
  check "no new bash anywhere stops with an error" grep -q "set CHALK_BASH" <<<"$output"
fi
