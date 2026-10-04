#!/usr/bin/env bash
# Fill functions in lib/agent.sh and lib/db.sh: agent_usage and
# db_ticket_summary write into the caller's associative array.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"
load core/log repo db agent

cat > "$tmp/result.json" <<'JSON'
{"usage":{"input_tokens":1200,"output_tokens":900,"cache_read_input_tokens":42000,
 "cache_creation_input_tokens":3000},"num_turns":6,"permission_denials":[{},{}]}
JSON

declare -A usage
agent_usage "$tmp/result.json" usage
check "agent_usage reads token counts" \
  test "${usage[input]}:${usage[output]}:${usage[cache_read]}:${usage[cache_write]}" = "1200:900:42000:3000"
check "agent_usage reads turns and denials" test "${usage[turns]}:${usage[denials]}" = "6:2"

echo '{"usage":{"input_tokens":5}}' > "$tmp/partial.json"
agent_usage "$tmp/partial.json" usage
check "agent_usage fills missing fields with 0" \
  test "${usage[input]}:${usage[turns]}:${usage[denials]}" = "5:0:0"

agent_usage "$tmp/missing.json" usage
check "agent_usage gives zeros for an unreadable result" \
  test "${usage[input]}${usage[output]}${usage[turns]}${usage[denials]}" = "0000"

cat > "$tmp/models.json" <<'JSON'
{"modelUsage":{"claude-haiku-x":{"costUSD":0.01},"claude-opus-x":{"costUSD":0.2}}}
JSON
check "agent_model names the model that cost the most" test "$(agent_model "$tmp/models.json")" = claude-opus-x
check "agent_model is empty when the result does not say" test -z "$(agent_model "$tmp/partial.json")"
check "agent_model is empty for an unreadable result" test -z "$(agent_model "$tmp/missing.json")"

# A caller's variable may share a name with the function's own locals.
values="untouched"
declare -A values_usage
agent_usage "$tmp/result.json" values_usage
check "agent_usage leaves the caller's variables alone" test "$values" = "untouched"

# Stand-ins for the database: db_sql answers with $db_row, or fails when
# it is empty.
db_row=""
repo_name() { REPLY=demo; }
db_sql() { cat >/dev/null; [[ -n $db_row ]] && echo "$db_row"; }

declare -A summary
db_ticket_summary PROJ-1 summary
check "db_ticket_summary falls back to ? when the database fails" \
  test "${summary[loops]}${summary[cost]}${summary[fixes]}" = "???"
db_ticket_summary PROJ-1 summary -
check "db_ticket_summary uses the given fallback" test "${summary[loops]}" = "-"

db_row="3 1.2500 1"
db_ticket_summary PROJ-1 summary
check "db_ticket_summary reads loops, cost and fixes" \
  test "${summary[loops]}:${summary[cost]}:${summary[fixes]}" = "3:1.2500:1"
