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
[[ -s $out/tag ]] || exp_die "$out/tag is missing: was OUT_DIR made by run.sh?"
# This experiment's repositories, and only them (run.sh).
prefix="exp-$(cat "$out/tag")-"
shopt -s nullglob

# Thesis 1: every early stop's evidence, in this experiment's repositories.
first_ws="$(find "$out/ws" -mindepth 2 -maxdepth 2 -type d -name "$prefix*" | sort | head -n 1)"
certify='{}'
if [[ -n $first_ws ]]; then certify="$(cd "$first_ws" && chalk certify --json --repos "$prefix" 2>/dev/null || echo '{}')"; fi

# Thesis 2: blockers, their probes and evidence, in this experiment's
# repositories, leaving out pre-flight's detentions, which run.sh counts on
# their own.
blockers="$(exp_sql "SELECT coalesce(json_agg(json_build_object('repo', repo, 'kind', fix_kind, 'probe', probe,
  'before', before_outcome, 'after', after_outcome, 'evidence', evidence)), '[]') FROM lessons
  WHERE repo LIKE '$prefix%' AND signature NOT LIKE 'pre-flight:%';")"
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$blockers" || blockers='[]'
exp_spent "$prefix"; spent="$REPLY"

# Thesis 3: the tuning report of each repository: attempts at instances of
# one upstream share its name, so one workspace of each name says it.
tune='[]'
declare -A seen=()
for ws in "$out"/ws/*/"$prefix"*/; do
  ws="${ws%/}"
  [[ -d $ws/.git && ! -v seen[${ws##*/}] ]] || continue
  seen[${ws##*/}]=1
  one="$(cd "$ws" && chalk tune --json 2>/dev/null || true)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$one" || continue
  tune="$(jq -c --arg ws "${ws##*/}" --argjson one "$one" '. + [$one + {workspace: $ws}]' <<<"$tune")"
done

# Thesis 4: every evidence record in a worktree, verified with this
# machine's key.
signers="$(mktemp)"
attest='[]'
if command -v ssh-keygen >/dev/null 2>&1 && chalk attest key 2>/dev/null | tail -n 1 > "$signers"; then
  for record in "$out"/ws/*/"$prefix"*.worktrees/*/.chalk/evidence/*.json; do
    wt="${record%/.chalk/evidence/*}"
    # The branch the record was made against: base/ID in an experiment.
    base="$(jq -r .payload "$record" | openssl base64 -d -A 2>/dev/null | jq -r '.predicate.base.branch // "main"' 2>/dev/null || echo main)"
    status=0
    (cd "$wt" && CHALK_ATTEST_SIGNERS="$signers" chalk attest verify --base "$base" "$(basename "$record" .json)") >/dev/null 2>&1 || status=$?
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
     oracle: {fixes: ($results | map(select(.phase == "oracle" and .skipped == null)) | length),
              proved: ($results | map(select(.phase == "oracle" and .proved)) | length),
              skipped: ($results | map(select(.skipped != null)) | length)},
     preflight: {checked: ($results | map(select(.phase == "preflight" and .skipped == null)) | length),
                 caught: ($results | map(select(.phase == "preflight" and .caught)) | length),
                 loops_before_caught: ($results | map(select(.phase == "preflight" and .caught) | .loops) | add // 0)},
     tune: $tune,
     attest: {records: ($attest | length), verified: ($attest | map(select(.verified)) | length)}}')"
printf '%s\n' "$analysis" > "$out/analysis.json"

# The paper's macros. \Exp... names are fixed; their values are this run's.
jq -r '
  # The union of the verdicts, for the agent model with the most judged
  # runs: an experiment that varies the model has one row per model, in
  # analysis.json.
  def any_verdict: ((.certify.verdicts // []) | map(select(.verdict == "any")) | max_by(.judged)) // {};
  def tex: tostring | gsub("_"; "\\_");
  [["ExpSpend", (.spent_usd * 100 | round / 100)],
   ["ExpRuns", .runs.total], ["ExpDetained", .runs.detained],
   ["ExpAnyJudged", (any_verdict.judged // 0)], ["ExpAnyWrong", (any_verdict.wrong // 0)],
   ["ExpAnyLower", (any_verdict.lower // 0)], ["ExpAnySaved", (any_verdict.saved_lower // 0)],
   ["ExpAnyNet", (any_verdict.net // 0)],
   ["ExpCertified", ((.certify.verdicts // []) | map(select(.certified and .verdict != "any")) | length)],
   ["ExpBlockers", .blockers.total], ["ExpWithProbe", .blockers.with_probe], ["ExpProbeFailed", .blockers.probe_failed],
   ["ExpProbePassed", .blockers.probe_passed], ["ExpProbeInconclusive", .blockers.probe_inconclusive],
   ["ExpProved", .blockers.proved], ["ExpOracleProved", .oracle.proved], ["ExpOracleFixes", .oracle.fixes],
   ["ExpPreflightCaught", .preflight.caught], ["ExpPreflightChecked", .preflight.checked],
   ["ExpPreflightLoops", .preflight.loops_before_caught],
   ["ExpRecords", .attest.records], ["ExpRecordsVerified", .attest.verified]][]
  | "\\newcommand{\\\(.[0])}{\(.[1] | tex)}"' <<<"$analysis" > "$out/results.tex"
exp_info "analysis: $out/analysis.json"
exp_info "macros for the paper: $out/results.tex"
