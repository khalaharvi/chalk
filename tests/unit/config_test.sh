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
  test "$CHALK_RUBRIC_TIMEOUT:$CHALK_MAX_PARALLEL:$CHALK_CHEAP_MODEL" = "900:4:haiku"
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
check "fingerprint verdicts are recorded in shadow by default, with no test report" \
  test "$CHALK_FP_RULES:$CHALK_TEST_REPORT" = "shadow:"
check "an invalid CHALK_FP_RULES stops Chalk" \
  sh -c '! (CHALK_FP_RULES=maybe; . "$0/lib/core/log.sh"; . "$0/lib/config.sh"; load_config /nowhere) 2>/dev/null' "$CHALK_HOME"
