#!/usr/bin/env bash
# Turns an experiment's results into the paper's numbers (experiments/README.md):
# OUT_DIR/analysis.json, and OUT_DIR/results.tex, LaTeX macros that
# docs/paper/main.tex can \input in place of its bracketed placeholders.
#
#   experiments/analyze.sh OUT_DIR
#
# Reads OUT_DIR/results.jsonl (run.sh) and Chalk's telemetry database, and
# runs chalk certify, chalk tune and chalk attest verify in the workspaces.
# Spends nothing.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=experiments/lib.sh
. "$here/lib.sh"

out="${1:-}"
[[ -f $out/results.jsonl ]] || exp_die "usage: experiments/analyze.sh OUT_DIR (with OUT_DIR/results.jsonl from run.sh)"
exp_need jq chalk
out="$(cd "$out" && pwd)"
results="$(jq -sc . "$out/results.jsonl")"

# Thesis 1: every early stop's evidence, from the whole database.
first_ws="$(find "$out/ws" -mindepth 1 -maxdepth 1 -type d -name 'exp-*' | sort | head -n 1)"
certify='{}'
if [[ -n $first_ws ]]; then certify="$(cd "$first_ws" && chalk certify --json 2>/dev/null || echo '{}')"; fi

# Thesis 2: blockers, their probes and evidence, in the experiment's repositories.
blockers="$(exp_sql "SELECT coalesce(json_agg(json_build_object('repo', repo, 'kind', fix_kind, 'probe', probe,
  'before', before_outcome, 'after', after_outcome, 'evidence', evidence)), '[]') FROM lessons WHERE repo LIKE 'exp-%';")"
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$blockers" || blockers='[]'
exp_spent exp-; spent="$REPLY"

# Thesis 3: each workspace's tuning report.
tune='[]'
for ws in "$out"/ws/exp-*/; do
  [[ -d $ws/.git ]] || continue
  one="$(cd "$ws" && chalk tune --json 2>/dev/null || true)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$one" || continue
  tune="$(jq -c --arg ws "$(basename "$ws")" --argjson one "$one" '. + [$one + {workspace: $ws}]' <<<"$tune")"
done

# Thesis 4: every evidence record in a worktree, verified with this
# machine's key.
signers="$(mktemp)"
attest='[]'
if command -v ssh-keygen >/dev/null 2>&1 && chalk attest key 2>/dev/null | tail -n 1 > "$signers"; then
  for record in "$out"/ws/exp-*.worktrees/*/.chalk/evidence/*.json; do
    wt="${record%/.chalk/evidence/*}"
    status=0
    (cd "$wt" && CHALK_ATTEST_SIGNERS="$signers" chalk attest verify "$(basename "$record" .json)") >/dev/null 2>&1 || status=$?
    attest="$(jq -c --arg r "${record#"$out/"}" --argjson ok "$([[ $status == 0 ]] && echo true || echo false)" '. + [{record: $r, verified: $ok}]' <<<"$attest")"
  done
fi
rm -f "$signers"

analysis="$(jq -n --argjson results "$results" --argjson certify "$certify" --argjson blockers "$blockers" \
  --argjson tune "$tune" --argjson attest "$attest" --arg spent "$spent" '
  ($results | map(select(.phase == "run"))) as $runs
  | {spent_usd: ($spent | tonumber),
     runs: {total: ($runs | length), detained: ($runs | map(select(.detained)) | length),
            by_kind: ($runs | group_by(.kind) | map({key: .[0].kind, value: length}) | from_entries)},
     certify: $certify,
     blockers: {total: ($blockers | length), with_probe: ($blockers | map(select(.probe != null)) | length),
                probe_failed: ($blockers | map(select(.before == "failed")) | length),
                probe_passed: ($blockers | map(select(.before == "passed")) | length),
                probe_inconclusive: ($blockers | map(select(.before == "inconclusive")) | length),
                proved: ($blockers | map(select(.evidence == "proved")) | length),
                by_kind: ($blockers | map(select(.kind != null)) | group_by(.kind) | map({key: .[0].kind, value: length}) | from_entries)},
     oracle: {fixes: ($results | map(select(.phase == "oracle")) | length),
              proved: ($results | map(select(.phase == "oracle" and .proved)) | length)},
     preflight: {checked: ($results | map(select(.phase == "preflight")) | length),
                 caught: ($results | map(select(.phase == "preflight" and .caught)) | length),
                 loops_before_caught: ($results | map(select(.phase == "preflight" and .caught) | .loops) | add // 0)},
     tune: $tune,
     attest: {records: ($attest | length), verified: ($attest | map(select(.verified)) | length)}}')"
printf '%s\n' "$analysis" > "$out/analysis.json"

# The paper's macros. \Exp... names are fixed; their values are this run's.
jq -r '
  def any_verdict: ((.certify.verdicts // []) | map(select(.verdict == "any")) | first) // {};
  def tex: tostring | gsub("_"; "\\_");
  [["ExpSpend", (.spent_usd * 100 | round / 100)],
   ["ExpRuns", .runs.total], ["ExpDetained", .runs.detained],
   ["ExpAnyJudged", (any_verdict.judged // 0)], ["ExpAnyWrong", (any_verdict.wrong // 0)],
   ["ExpAnyLower", (any_verdict.lower // 0)], ["ExpAnySaved", (any_verdict.saved_lower // 0)],
   ["ExpAnyNet", (any_verdict.net // 0)],
   ["ExpCertified", ((.certify.verdicts // []) | map(select(.certified and .verdict != "any")) | length)],
   ["ExpBlockers", .blockers.total], ["ExpProbeFailed", .blockers.probe_failed],
   ["ExpProbePassed", .blockers.probe_passed], ["ExpProbeInconclusive", .blockers.probe_inconclusive],
   ["ExpProved", .blockers.proved], ["ExpOracleProved", .oracle.proved], ["ExpOracleFixes", .oracle.fixes],
   ["ExpPreflightCaught", .preflight.caught], ["ExpPreflightChecked", .preflight.checked],
   ["ExpPreflightLoops", .preflight.loops_before_caught],
   ["ExpRecords", .attest.records], ["ExpRecordsVerified", .attest.verified]][]
  | "\\newcommand{\\\(.[0])}{\(.[1] | tex)}"' <<<"$analysis" > "$out/results.tex"
exp_info "analysis: $out/analysis.json"
exp_info "macros for the paper: $out/results.tex"
