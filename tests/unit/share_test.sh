#!/usr/bin/env bash
# share/share.jq: the allow-list behind `chalk share`. tests/e2e.sh checks
# the whole command against seeded data; this checks the rules one by one.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"

# payload DASH [EXTRA] [HOST] [DECIDER]: share.jq's summary of the given
# report card data, share.sql counts and host, as compact JSON.
payload() {
  jq -cn --argjson dash "$1" --argjson extra "${2:-{\}}" --argjson host "${3:-{\}}" \
    --arg week 2026-W41 --arg decider "${4:-strands-decider-2B-hobson-v19}" \
    -f "$CHALK_HOME/share/share.jq"
}

# family MODEL: the family the summary names MODEL by.
family() {
  payload "$(jq -cn --arg m "$1" '{by_model: [{model: $m, loops: 1, cost: 0.1, checkpoints: 0}]}')" |
    jq -r '.by_model[0].model'
}

# Every model string Chalk may record, and what the summary may say of it.
declare -A families=(
  ["claude-opus-4-5-20251101"]=claude-opus-4-5
  ["claude-opus-4-20250514"]=claude-opus-4
  ["claude-sonnet-4-5@20250929"]=claude-sonnet-4-5
  ["us.anthropic.claude-sonnet-4-5-20250929-v1:0"]=claude-sonnet-4-5
  ["arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/claude-x"]=other
  ["claude-3-5-sonnet-20241022"]=claude-3-5-sonnet
  ["claude-haiku-4-5-20251001"]=claude-haiku-4-5
  ["claude-opus-4-5[1m]"]=claude-opus-4-5
  ["opus"]=opus
  ["default"]=default
  ["my-gateway/acme-corp-model"]=other
  ["claude-secretproject-1"]=other
)
for model in "${!families[@]}"; do
  check "model $model is shared as ${families[$model]}" test "$(family "$model")" = "${families[$model]}"
done
check "no model is shared as default" test "$(family "")" = default

# cost AMOUNT: the summary's total cost for a report card costing AMOUNT.
cost() {
  payload "{\"totals\": {\"cost\": $1}}" | jq -r '.totals.cost_usd'
}
check "amounts keep two significant figures: 1234.5 is 1200" test "$(cost 1234.5)" = 1200
check "... 0.4567 is 0.46" test "$(cost 0.4567)" = 0.46
check "... 12.34 is 12" test "$(cost 12.34)" = 12
check "... 0.003456 is 0.0035" test "$(cost 0.003456)" = 0.0035
check "... 0 is 0" test "$(cost 0)" = 0
check "an amount that is not a number is 0" test "$(payload '{"totals": {"cost": "SENTINEL"}}' | jq '.totals.cost_usd')" = 0

host='{"chalk": "0.7.1", "os": "darwin", "arch": "aarch64", "cores": "12", "ram_mb": "36864",
       "docker_cpus": "6", "docker_mem_mb": "8192"}'
check "the host is its OS, architecture and size ranges" \
  test "$(payload '{}' '{}' "$host" | jq -c '.host')" \
    = '{"os":"darwin","arch":"arm64","cpus":"8-15","ram_gib":"32-63","docker_cpus":"4-7","docker_mem_gib":"8-15"}'
check "an unknown OS, architecture or version reads as other" \
  test "$(payload '{}' '{}' '{"chalk": "SENTINEL", "os": "my-host", "arch": "SENTINEL"}' | jq -c '[.chalk, .host.os, .host.arch]')" \
    = '["other","other","other"]'

check "the local decider is named without its revision" \
  test "$(payload '{"decider": {"models": ["strands-decider-2B-hobson-v19@0123456"]}}' | jq -c '.decider.models')" \
    = '["strands-decider-2B-hobson-v19"]'
check "a hosted decider's model is only hosted" \
  test "$(payload '{"decider": {"models": ["acme.example.com/our-model@9"]}}' | jq -c '.decider.models')" = '["hosted"]'

check "labels outside the fixed set are counted together as other" \
  test "$(payload '{"by_kind": [{"kind": "retry", "calls": 1}, {"kind": "SENT-1", "calls": 2}, {"kind": "SENT-2", "calls": 3}]}' \
            '{"verdicts": {"repeat": 2, "/SENTINEL/path": 1, "SENT-123": 4}}' |
          jq -c '[(.by_kind | map("\(.kind)=\(.calls)")), .verdicts]')" \
    = '[["other=5","retry=1"],{"other":5,"repeat":2}]'

# The allow-list, field by field. A new field must be added here, to
# share.jq and to PRIVACY.md together. Keys of the count maps are a fixed
# set each, shown as *.
fields="$(payload \
  '{"by_kind": [{"kind": "retry"}], "by_model": [{"model": "opus"}], "ledger": {"by_verdict": [{"verdict": "repeat"}]},
    "decider": {"models": ["x"], "by_kind": [{"kind": "stuck"}], "errors": [{"error": "timeout", "calls": 1}],
                "calibration": [{"low": 0.9}]}}' \
  '{"verdicts": {"first": 1}, "fp_rules": {"on": 1}, "detentions_by_reason": {"stuck": 1}, "decider_modes": {"on": 1}}' |
  jq -r '[paths(type | . != "object" and . != "array")
          | map(if type == "number" then "[]" else . end)
          | if .[0] | IN("verdicts", "fp_rules", "detentions_by_reason") then [.[0], "*"]
            elif .[0] == "decider" and (.[1] | IN("modes", "errors")) then [.[0], .[1], "*"] else . end
          | join(".")] | unique | join(" ")')"
expected="agent.blocked agent.error agent.ok agent.turns budget.cap_usd budget.max_usd budget.near_cap
budget.p50_usd budget.p90_usd by_kind.[].avg_cost_usd by_kind.[].avg_seconds by_kind.[].calls
by_kind.[].cost_usd by_kind.[].kind by_model.[].checkpoints by_model.[].cost_usd by_model.[].loops
by_model.[].model chalk days decider.acted decider.answered decider.by_kind.[].acted
decider.by_kind.[].answered decider.by_kind.[].kind decider.by_kind.[].questions
decider.calibration.[].agreed decider.calibration.[].answers decider.calibration.[].low decider.errors.*
decider.false_stops decider.median_ms decider.models.[] decider.modes.* decider.questions
decider.would_save_usd decider.would_stop detentions_by_reason.* events.detention events.ready
events.spec_blocked events.submitted fp_rules.* harness host.arch host.cpus host.docker_cpus
host.docker_mem_gib host.os host.ram_gib ledger.blocked_only ledger.blocked_only_usd
ledger.by_verdict.[].runs ledger.by_verdict.[].saved_usd ledger.by_verdict.[].verdict ledger.converging
ledger.detained_runs ledger.failed_loops ledger.failed_loops_no_tests ledger.false_stop_usd
ledger.false_stops ledger.no_progress_usd ledger.no_verdicts ledger.saved_usd ledger.stopped_on
lessons.distilled lessons.fingerprinted lessons.opened lessons.passed_with lessons.passed_without
lessons.resolved lessons.retries_with_lessons lessons.retries_without lessons.scope_general
lessons.scope_repo rates.cache_read_share rates.cost_per_checkpoint_usd rates.detention_rate
rates.loops_per_checkpoint rates.review_pass_rate rates.spec_check_pass_rate rates.wasted_share
review.cost_usd review.failed review.fix_cost_usd review.reviews schema spec_check.checks
spec_check.cost_usd spec_check.failed totals.cache_read_tokens totals.cache_write_tokens totals.calls
totals.checkpoints totals.cost_usd totals.denials totals.detentions totals.input_tokens
totals.loop_cost_usd totals.loops totals.output_tokens totals.repositories totals.runs totals.submitted
totals.tickets totals.wasted_usd verdicts.* week"
check "the summary holds exactly the fields on the allow-list" test "$fields" = "$(tr '\n' ' ' <<<"$expected" | sed 's/ $//')"

check "every string in the summary is a label, a version or a range" \
  test "$(payload '{"by_model": [{"model": "SENTINEL"}], "decider": {"models": ["SENTINEL"]}}' '{}' "$host" |
          jq '[.. | strings] - ["claude-code", "0.7.1", "2026-W41", "darwin", "arm64", "8-15", "32-63", "4-7",
                                "other", "hosted"] | length')" = 0
