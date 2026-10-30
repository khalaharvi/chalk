# Shared helpers for the experiment scripts (experiments/README.md). Host
# bash 5.3, like scripts/. Sourced, never run.

exp_info() { printf '%s\n' "$*"; }
exp_warn() { printf 'warning: %s\n' "$*" >&2; }
exp_die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# exp_need TOOL...: stops unless every TOOL is on PATH.
exp_need() {
  local tool
  for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || exp_die "'$tool' is required"; done
}

# exp_sql SQL: runs SQL against Chalk's telemetry database and prints the
# rows, unaligned and without headers; prints nothing when it cannot.
exp_sql() {
  docker exec -i chalk-db psql -X -q -A -t -v ON_ERROR_STOP=1 -U chalk -d chalk <<<"$1" 2>/dev/null || true
}

# exp_spent PREFIX -> REPLY: what the agent calls of every repository whose
# name starts with PREFIX have cost, in dollars; 0 when the database cannot
# say.
exp_spent() {
  REPLY="$(exp_sql "SELECT coalesce(sum(cost_usd), 0) FROM runs WHERE repo LIKE '${1//\'/\'\'}%';")"
  [[ $REPLY =~ ^[0-9]+(\.[0-9]+)?$ ]] || REPLY=0
}

# exp_worst_case -> REPLY: the most one run can cost at the settings in
# the environment: every loop up to CHALK_MAX_LOOPS, plus the explored
# loops, the spec check, the review rounds and a review fix, each at
# CHALK_BUDGET_USD. The ceiling is checked against spend so far plus this.
exp_worst_case() {
  local loops=$(( ${CHALK_MAX_LOOPS:-20} + ${CHALK_EXPLORE_RETRIES:-0} + 2 + 2 * ${CHALK_REVIEW_ROUNDS:-1} ))
  REPLY="$(awk -v n="$loops" -v b="${CHALK_BUDGET_USD:-1.00}" 'BEGIN { printf "%.2f", n * b }')"
}

# exp_over A B: true when the dollar amount A is above B.
exp_over() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
