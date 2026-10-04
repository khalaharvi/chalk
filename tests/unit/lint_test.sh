#!/usr/bin/env bash
# scripts/lint-conventions.sh: each rule catches its violation, and the
# real code passes.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"

lint="$CHALK_HOME/scripts/lint-conventions.sh"

# flags LABEL CODE: the lint reports CODE.
flags() {
  printf '%s\n' "$2" > "$tmp/sample.sh"
  check "lint flags $1" eval '! "$lint" "$tmp/sample.sh"'
}

flags "a nameref without the __ prefix" 'f() { local -n out=$1; }'
flags "a file read inside \${ }" 'x=${ <file; }'
flags "cd inside \${| }" 'x=${| cd /tmp; REPLY=$PWD; }'
flags "a value function that returns non-zero" '# f -> REPLY: a value
f() {
  return 1
}'

printf '%s\n' 'f() { local -n __out=$1; __out=1; }' 'x=$(<file)' '# g -> REPLY
g() {
  REPLY=1
}' > "$tmp/good.sh"
check "lint accepts code that follows the conventions" "$lint" "$tmp/good.sh"
check "the repository follows the conventions" "$lint"
