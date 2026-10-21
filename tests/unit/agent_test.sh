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

# cost_for VALUE: agent_cost for a result whose total_cost_usd is VALUE.
cost_for() { printf '{"total_cost_usd":%s}\n' "$1" > "$tmp/cost.json"; agent_cost "$tmp/cost.json"; }
check "agent_cost rounds to four places" test "$(cost_for 0.13829080000000002)" = 0.1383
check "agent_cost pads to four places" test "$(cost_for 0.25)" = 0.2500
check "agent_cost writes a decimal point whatever the locale" \
  test "$(export LC_ALL=de_DE.UTF-8; cost_for 0.25)" = 0.2500
check "agent_cost reads costs written in exponent form" test "$(cost_for 1.5e-03)" = 0.0015
check "agent_cost gives 0.0000 for a value that is not a cost" test "$(cost_for '"n/a"')" = 0.0000
check "agent_cost gives 0.0000 for an unreadable result" test "$(agent_cost "$tmp/missing.json")" = 0.0000

check "agent_usd shows dollars and cents" test "${| agent_usd 0.3800; }" = '$0.38'
check "agent_usd rounds to the nearest cent" test "${| agent_usd 1.4760; }" = '$1.48'
check "agent_usd shows a sum from the database in cents" test "${| agent_usd 12.0000; }" = '$12.00'
check "agent_usd shows zero as zero" test "${| agent_usd 0.0000; }" = '$0.00'
check "agent_usd marks a cost below a cent" test "${| agent_usd 0.0031; }" = '<$0.01'
check "agent_usd passes through a value that is not a cost" test "${| agent_usd '?'; }" = '$?'

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

# agent_failure: why a call failed, from what agent_call left in IO_DIR.
# call NAME EXIT JSON [STDERR]: writes what a call NAME left behind.
call() {
  printf '%s\n' "$2" > "$tmp/$1.exit"
  printf '%s\n' "$3" > "$tmp/$1.json"
  printf '%s' "${4:-}" > "$tmp/$1.err"
}
failure() { agent_failure "$tmp" "$1"; printf '%s' "$REPLY"; }
CHALK_AGENT_TIMEOUT=1800

# Recorded from Claude Code 2.1.306 with an invalid key: exit 1, nothing on
# stderr, and is_error true with subtype "success".
call refused 1 '{"type":"result","subtype":"success","is_error":true,"api_error_status":401,"duration_ms":412,"num_turns":1,"result":"Invalid API key · Fix external API key","stop_reason":"stop_sequence","terminal_reason":"api_error","total_cost_usd":0}'
check "agent_failure: a refused key is auth, with the CLI's message and the HTTP status" \
  test "$(failure refused)" = "auth: Invalid API key · Fix external API key (HTTP 401)"
call ok 0 '{"type":"result","subtype":"success","is_error":false,"result":"done","structured_output":{"status":"done"}}'
check "agent_failure: a call that succeeded has no failure" test -z "$(failure ok)"
# Recorded from Claude Code 2.1.306 behind a proxy that re-signs HTTPS.
call untrusted 1 '{"type":"result","subtype":"success","is_error":true,"api_error_status":null,"result":"API Error: Unable to connect to API: Self-signed certificate detected (SELF_SIGNED_CERT_IN_CHAIN). The certificate comes from an authority Claude Code doesn'"'"'t trust, usually a TLS-inspecting corporate proxy or a gateway signed by a private CA: set NODE_EXTRA_CA_CERTS to that CA bundle, or add it to the system certificate store · see https://code.claude.com/docs/en/network-config","terminal_reason":"api_error"}'
check "agent_failure: an untrusted certificate is tls, not a network error" \
  sh -c 'case "$1" in "tls: API Error: Unable to connect to API: Self-signed certificate detected"*) ;; *) exit 1 ;; esac' _ "$(failure untrusted)"
check "agent_failure: a message over 300 characters is cut, and marked" \
  sh -c 'case "$1" in *…) ;; *) exit 1 ;; esac' _ "$(failure untrusted)"
call offline 1 '{"is_error":true,"subtype":"success","result":"API Error: Unable to connect to API (ECONNREFUSED)"}'
check "agent_failure: a refused connection is network" test "$(failure offline)" = "network: API Error: Unable to connect to API (ECONNREFUSED)"
call limited 1 '{"is_error":true,"subtype":"success","api_error_status":429,"result":"Rate limited"}'
check "agent_failure: HTTP 429 is rate_limit" test "$(failure limited)" = "rate_limit: Rate limited (HTTP 429)"
call plan 1 '{"is_error":true,"subtype":"success","result":"Claude AI usage limit reached|1792600000"}'
check "agent_failure: a used-up plan is usage_limit" sh -c 'case "$1" in usage_limit:*) ;; *) exit 1 ;; esac' _ "$(failure plan)"
call busy 1 '{"is_error":true,"subtype":"success","api_error_status":529,"result":"Overloaded"}'
check "agent_failure: HTTP 529 is overloaded" test "$(failure busy)" = "overloaded: Overloaded (HTTP 529)"
call capped 1 '{"is_error":true,"subtype":"error_max_budget_usd"}'
check "agent_failure: the spend cap is budget, named by its subtype" test "$(failure capped)" = "budget: error_max_budget_usd"
call turns 1 '{"is_error":true,"subtype":"error_max_turns"}'
check "agent_failure: running out of turns is max_turns" test "$(failure turns)" = "max_turns: error_max_turns"
call slow 124 ''
check "agent_failure: exit 124 is timeout, naming the setting" \
  test "$(failure slow)" = "timeout: no answer within 1800s (CHALK_AGENT_TIMEOUT)"
call nocli 127 '' 'OCI runtime exec failed: exec: "claude": executable file not found in $PATH'
check "agent_failure: no claude in the image is cli_missing, with docker's message" \
  test "$(failure nocli)" = 'cli_missing: OCI runtime exec failed: exec: "claude": executable file not found in $PATH'
call gone 1 '' $'\nError response from daemon: No such container: chalk-sandbox-x\n'
check "agent_failure: no answer at all is crash, with the last line of stderr" \
  test "$(failure gone)" = "crash: Error response from daemon: No such container: chalk-sandbox-x"
check "agent_failure: a call that left nothing behind is crash" test "$(failure never)" = "crash: exit 0, and no answer"
fails() { ! "$@"; }
for class in tls auth cli_missing usage_limit; do
  check "agent_failure_retryable: $class is not retried" fails agent_failure_retryable "$class"
done
for class in network rate_limit overloaded server timeout budget max_turns error crash; do
  check "agent_failure_retryable: $class is retried" agent_failure_retryable "$class"
done
