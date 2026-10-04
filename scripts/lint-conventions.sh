#!/usr/bin/env bash
# Checks the conventions in docs/bash-style.md that ShellCheck cannot see.
# Run by `make lint`. Prints each violation as FILE:LINE: message.
#
#   scripts/lint-conventions.sh [FILE...]
#
# With no files it checks the host code and the version-boundary headers.
set -euo pipefail
cd "$(dirname "$0")/.."

if (( $# )); then files=("$@"); else files=(bin/chalk lib/core/*.sh lib/*.sh); fi
status=0

# report PATTERN MESSAGE: flags lines in the host code matching PATTERN.
report() {
  local line
  while IFS= read -r line; do
    printf '%s: %s\n' "$line" "$2"
    status=1
  done < <(grep -nE "$1" "${files[@]}" | cut -d: -f1,2 || true)
}

report '(local|declare)( -[a-zA-Z]+)* -[a-zA-Z]*n[a-zA-Z]* +([^_ -]|_[^_])' \
  'nameref locals start with __ (C3)'
report '\$\{[|]? +<' \
  'a file read with < inside ${ } returns nothing; use read -r or $(<file) (C2)'
report '\$\{[|]? [^}]*\bcd\b' \
  'cd inside ${ } changes Chalk'"'"'s own directory; use $( ) or ( ) (C2)'

# Value functions (a "-> REPLY" header comment) must never return non-zero:
# a failing ${| } ends bash 5.3 even inside && or if (C1).
while IFS= read -r line; do
  printf '%s: value functions never return non-zero (C1)\n' "$line"
  status=1
done < <(awk '
  /^#.*-> REPLY/            { value = 1; next }
  /^[a-z_]+\(\) *\{/ && value { inside = 1; value = 0; next }
  /^}/                       { inside = 0 }
  !/^#/                      { if (!inside) value = 0 }
  inside && /return +[1-9]|return +"?\$[a-z?]/ { print FILENAME ":" FNR }
' "${files[@]}")

(( $# )) && exit "$status"

# Version boundaries are declared on the first line (C8).
for file in share/sandbox/scripts/*.sh; do
  head -n 1 "$file" | grep -q '^# bash 5.2 syntax' ||
    { printf '%s:1: sandbox scripts start with "# bash 5.2 syntax" (C8)\n' "$file"; status=1; }
done
head -n 1 lib/core/guard.sh | grep -q '^# bash 3.2 syntax' ||
  { printf 'lib/core/guard.sh:1: must start with "# bash 3.2 syntax" (C8)\n'; status=1; }

exit "$status"
