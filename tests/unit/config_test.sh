#!/usr/bin/env bash
# lib/config.sh: precedence, defaults and validation of .chalk/config.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log config

mkdir -p "$tmp/repo/.chalk"
cat > "$tmp/repo/.chalk/config" <<'CONFIG'
# a comment
CHALK_TEST_CMD=make test

CHALK_MAX_LOOPS=7
CHALK_BASE_BRANCH=
CHALK_BUDGET_USD=2.50
NOT_A_CHALK_KEY=1
$(touch pwned)=1
CHALK_MODEL=sonnet
CONFIG

CHALK_BUDGET_USD=9.00
warnings="$(cd "$tmp" && load_config "$tmp/repo" 2>&1 >/dev/null)"
load_config "$tmp/repo" 2>/dev/null

check "file values are read" test "$CHALK_TEST_CMD" = "make test"
check "numbers are read as given" test "$CHALK_MAX_LOOPS" = 7
check "the environment wins over the file" test "$CHALK_BUDGET_USD" = 9.00
check "an empty value takes the default" test "$CHALK_BASE_BRANCH" = main
check "unset settings take their defaults" \
  test "$CHALK_RUBRIC_TIMEOUT:$CHALK_MAX_PARALLEL:$CHALK_CHEAP_MODEL" = "900:auto:haiku"
check "environment-only settings take their defaults" test "$CHALK_OTEL_PROTOCOL" = grpc
check "unknown keys are reported" grep -q "unknown key in .chalk/config: NOT_A_CHALK_KEY" <<<"$warnings"
check "malformed keys are reported" grep -q 'unknown key.*touch pwned' <<<"$warnings"
check "malformed keys are never evaluated" test ! -e "$tmp/pwned"

unset "${!CHALK_CONFIG_DEFAULTS[@]}" "${!CHALK_ENV_DEFAULTS[@]}"
load_config "$tmp/nowhere"
all_set=1
for key in "${!CHALK_CONFIG_DEFAULTS[@]}" "${!CHALK_ENV_DEFAULTS[@]}"; do
  [[ -v $key && ${!key} == "${CHALK_CONFIG_DEFAULTS[$key]-${CHALK_ENV_DEFAULTS[$key]-}}" ]] || all_set=0
done
check "without a config file every setting has its default" test "$all_set" -eq 1

check "an invalid forge stops Chalk" \
  sh -c '! (CHALK_FORGE=bitbucket; . "$0/lib/core/log.sh"; . "$0/lib/config.sh"; load_config /nowhere) 2>/dev/null' "$CHALK_HOME"
check "an invalid permission mode stops Chalk" \
  sh -c '! (CHALK_PERMISSION_MODE=ask; . "$0/lib/core/log.sh"; . "$0/lib/config.sh"; load_config /nowhere) 2>/dev/null' "$CHALK_HOME"
for value in zero -1 0 4x; do
  check "CHALK_MAX_PARALLEL=$value stops Chalk with a message" \
    "$BASH" -c '(CHALK_MAX_PARALLEL=$1; . "$0/lib/core/log.sh"; . "$0/lib/config.sh"; load_config /nowhere) 2>&1 |
      grep -q "CHALK_MAX_PARALLEL must be .auto. or a positive whole number"' "$CHALK_HOME" "$value"
done
check "CHALK_MAX_PARALLEL accepts a positive number" \
  "$BASH" -c '(CHALK_MAX_PARALLEL=6; . "$0/lib/core/log.sh"; . "$0/lib/config.sh"; load_config /nowhere)' "$CHALK_HOME"
check "fingerprint verdicts are recorded in shadow by default, with no test report" \
  test "$CHALK_FP_RULES:$CHALK_TEST_REPORT" = "shadow:"
check "an invalid CHALK_FP_RULES stops Chalk" \
  sh -c '! (CHALK_FP_RULES=maybe; . "$0/lib/core/log.sh"; . "$0/lib/config.sh"; load_config /nowhere) 2>/dev/null' "$CHALK_HOME"

# Hindsight was removed: its settings still load, are ignored, and are
# named in a single warning that gives the replacement.
mkdir -p "$tmp/old/.chalk"
cat > "$tmp/old/.chalk/config" <<'CONFIG'
CHALK_TEST_CMD=make test
CHALK_MEMORY=hindsight
CHALK_MEMORY_BANK=chalk
CHALK_MEMORY_TOKENS=800
CONFIG
old_warnings="$("$BASH" -c 'CHALK_MEMORY_URL=http://127.0.0.1:18888 CHALK_MEMORY_IMAGE=img
  . "$0/lib/core/log.sh"; . "$0/lib/config.sh"
  load_config "$1"; load_config "$1"
  printf "memory=%s\n" "$CHALK_MEMORY"' "$CHALK_HOME" "$tmp/old" 2>&1)"
check "old Hindsight settings load" grep -qx "memory=builtin" <<<"$old_warnings"
check "old Hindsight settings give one warning, however often config loads" \
  test "$(grep -c '^warning:' <<<"$old_warnings")" -eq 1
check "the warning names every old setting" \
  sh -c 'for key in CHALK_MEMORY=hindsight CHALK_MEMORY_BANK CHALK_MEMORY_TOKENS CHALK_MEMORY_URL CHALK_MEMORY_IMAGE; do
           printf "%s\n" "$1" | grep -q "$key" || exit 1; done' _ "$old_warnings"
check "the warning names the replacement, not an unknown key" \
  sh -c 'printf "%s\n" "$1" | grep -q "recalled from the chalk-db lessons table" &&
         ! printf "%s\n" "$1" | grep -q "unknown key"' _ "$old_warnings"
check "CHALK_MEMORY=builtin loads without a warning" \
  test -z "$("$BASH" -c 'CHALK_MEMORY=builtin; . "$0/lib/core/log.sh"; . "$0/lib/config.sh"; load_config /nowhere' "$CHALK_HOME" 2>&1)"
check "an invalid CHALK_MEMORY still stops Chalk" \
  sh -c '! (CHALK_MEMORY=redis; . "$0/lib/core/log.sh"; . "$0/lib/config.sh"; load_config /nowhere) 2>/dev/null' "$CHALK_HOME"

check "retry feedback keeps its old form by default" test "$CHALK_FP_FEEDBACK" = false
check "CHALK_FP_FEEDBACK accepts true" \
  "$BASH" -c '(CHALK_FP_FEEDBACK=true; . "$0/lib/core/log.sh"; . "$0/lib/config.sh"; load_config /nowhere)' "$CHALK_HOME"
check "an invalid CHALK_FP_FEEDBACK stops Chalk with a message" \
  "$BASH" -c '(CHALK_FP_FEEDBACK=yes; . "$0/lib/core/log.sh"; . "$0/lib/config.sh"; load_config /nowhere) 2>&1 |
    grep -q "CHALK_FP_FEEDBACK must be .true. or .false."' "$CHALK_HOME"
