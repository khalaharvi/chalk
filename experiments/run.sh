#!/usr/bin/env bash
# Runs a corpus of task instances through Chalk, for the paper's evaluation
# (experiments/README.md). Each instance becomes a ticket in a workspace
# repository made from its base commit alone, so no later history is there
# to read. Spend is capped: EXP_BUDGET_USD must be set, and no run starts
# unless what was spent so far, plus the most one run can cost, is within it.
#
#   EXP_BUDGET_USD=50 experiments/run.sh CORPUS_DIR OUT_DIR [--attempts N] [--oracle] [KEY=VALUE...]
#
# CORPUS_DIR holds instance files (*.json, see the README). KEY=VALUE pairs
# are Chalk settings for every run, such as CHALK_FP_RULES=shadow or
# CHALK_MODEL=haiku; an instance's own settings come first. --oracle
# resolves a fault instance's detention with its recorded fix (office hours,
# as an engineer would) and then runs it once more against the faulty image
# (pre-flight). Results go to OUT_DIR/results.jsonl, one line per run.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=experiments/lib.sh
. "$here/lib.sh"

corpus="${1:-}" out="${2:-}"
[[ -d $corpus && -n $out ]] ||
  exp_die "usage: EXP_BUDGET_USD=N experiments/run.sh CORPUS_DIR OUT_DIR [--attempts N] [--oracle] [KEY=VALUE...]"
shift 2
attempts=1 oracle=0
declare -a settings=()
while (( $# )); do
  case "$1" in
    --attempts) attempts="${2:-}"; shift ;;
    --oracle) oracle=1 ;;
    CHALK_*=*) settings+=("$1") ;;
    *) exp_die "unknown argument: $1" ;;
  esac
  shift
done
[[ $attempts =~ ^[1-9][0-9]*$ ]] || exp_die "--attempts takes a positive whole number"
[[ ${EXP_BUDGET_USD:-} =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
  exp_die "set EXP_BUDGET_USD to the most this experiment may spend, in dollars; there is no default"
exp_need git jq chalk
mkdir -p "$out/ws"
out="$(cd "$out" && pwd)"
results="$out/results.jsonl"
prefix="exp-"

# workspace INSTANCE -> REPLY: the workspace repository for an instance,
# made on first use. Instances of one upstream repository share it, so
# chalk tune sees their runs together.
workspace() {
  local name
  name="$(jq -r '.workspace // (.repo | sub("/+$"; "") | split("/")[-1] | sub("\\.git$"; ""))' "$1")"
  REPLY="$out/ws/$prefix${name//[^a-zA-Z0-9_.-]/-}"
  if [[ ! -d $REPLY/.git ]]; then
    git init -q -b main "$REPLY"
    git -C "$REPLY" commit -q --allow-empty -m "experiment workspace"
  fi
}

# base INSTANCE WS: fetches the instance's base commit, and nothing after
# it, into WS as the branch base/ID.
base() {
  local id repo commit
  id="$(jq -r .id "$1")" repo="$(jq -r .repo "$1")" commit="$(jq -r '.base_commit // "HEAD"' "$1")"
  [[ $repo == /* || $repo == *://* ]] || repo="$(cd "$(dirname "$1")" && cd "$repo" && pwd)"
  git -C "$2" show-ref -q --verify "refs/heads/base/$id" && return 0
  git -C "$2" fetch -q --depth 1 "$repo" "$commit"
  git -C "$2" branch -q "base/$id" FETCH_HEAD
}

# spec INSTANCE: prints the spec for an instance: its problem, then one
# checkpoint per test it must make pass, or its own checkpoints.
spec() {
  jq -r '
    "# \(.ticket): \(.title // .id)", "", "## Context", (.problem // "Make the failing tests pass."), "",
    "## Checkpoints", "Each checkpoint must leave the tests passing.",
    ((.checkpoints // [(.fail_to_pass // [])[] | "Make `\(.)` pass"])[] | "- [ ] \(.)")' "$1"
}

# instance_env INSTANCE VAR: fills the array VAR with the instance's own
# Chalk settings, then the experiment's.
instance_env() {
  local -n __env=$2
  mapfile -t __env < <(jq -r '
    {CHALK_TEST_CMD: .test_cmd, CHALK_SETUP_CMD: (.setup_cmd // ""), CHALK_IMAGE: (.image // empty),
     CHALK_AUTO_MR: "false"} + (.settings // {}) | to_entries[] | "\(.key)=\(.value)"' "$1")
  __env+=("${settings[@]}")
}

# record FIELDS_JSON: appends one result line.
record() { jq -c . <<<"$1" >> "$results"; }

n=0
for file in "$corpus"/*.json; do
  id="$(jq -r .id "$file")"
  [[ $id =~ ^[a-zA-Z0-9_.-]+$ ]] || exp_die "$file: id must be letters, digits, dot, dash or underscore"
  workspace "$file"; ws="$REPLY"
  base "$file" "$ws"
  declare -a env=()
  instance_env "$file" env
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    n=$((n + 1))
    ticket="EXP-$n"
    exp_spent "$prefix"; spent="$REPLY"
    worst="$(env "${env[@]}" bash -c ". '$here/lib.sh'; exp_worst_case; printf '%s' \"\$REPLY\"")"
    if exp_over "$(awk -v a="$spent" -v b="$worst" 'BEGIN { print a + b }')" "$EXP_BUDGET_USD"; then
      exp_warn "stopping before $id (attempt $attempt): \$$spent spent, and a run may cost up to \$$worst, over EXP_BUDGET_USD=\$$EXP_BUDGET_USD"
      break 2
    fi
    (
      cd "$ws"
      env "${env[@]}" CHALK_BASE_BRANCH="base/$id" chalk new "$ticket" "$id" >/dev/null
      cd "$ws.worktrees/$ticket"
      spec <(jq --arg t "$ticket" '. + {ticket: $t}' "$file") > "specs/$ticket.md"
      git add -A && git commit -q -m "spec for $id"
    )
    log="$out/logs/$ticket.log"
    mkdir -p "${log%/*}"
    status=0
    (cd "$ws.worktrees/$ticket" && env "${env[@]}" CHALK_BASE_BRANCH="base/$id" chalk run) > "$log" 2>&1 || status=$?
    detained=false
    if grep -q '\] DETENTION: ' "$log"; then detained=true; fi
    record "$(jq -n --arg id "$id" --arg kind "$(jq -r '.kind // "replay"' "$file")" --arg ticket "$ticket" \
                --arg ws "${ws##*/}" --argjson attempt "$attempt" --argjson exit "$status" --argjson detained "$detained" \
                --arg log "${log#"$out/"}" --arg phase run \
                '{id: $id, kind: $kind, ticket: $ticket, workspace: $ws, attempt: $attempt, phase: $phase,
                  exit: $exit, detained: $detained, log: $log}')"
    if [[ $detained == true ]]; then exp_info "$id attempt $attempt ($ticket): detained"
    else exp_info "$id attempt $attempt ($ticket): exit $status"; fi

    if (( ! oracle )) || [[ $detained != true ]] || ! jq -e '.oracle' "$file" >/dev/null; then continue; fi
    # The oracle: the recorded fix, as an engineer would make it, then
    # office hours, which checks it with the blocker's probe.
    (
      cd "$ws.worktrees/$ticket"
      git switch -q "$(git for-each-ref --sort=-committerdate --count=1 --format='%(refname:short)' "refs/heads/detention/$ticket-*")"
      mkdir -p .chalk
      jq -r '.oracle.config // {} | to_entries[] | "\(.key)=\(.value)"' "$file" >> .chalk/config
      if [[ -n $(jq -r '.oracle.image // empty' "$file") ]]; then
        printf 'CHALK_IMAGE=%s\n' "$(jq -r .oracle.image "$file")" >> .chalk/config
      fi
      git add -A && git commit -q -m "oracle fix for $id"
      # The fix lives in .chalk/config, so the instance's own image and setup
      # must not override it from the environment.
      mapfile -t oracle_env < <(printf '%s\n' "${env[@]}" | grep -v -e '^CHALK_IMAGE=' -e '^CHALK_SETUP_CMD=')
      env "${oracle_env[@]}" CHALK_BASE_BRANCH="base/$id" \
        chalk office-hours -m "$(jq -r '.oracle.note // "applied the recorded fix"' "$file")"
    ) > "$out/logs/$ticket.oracle.log" 2>&1 || true
    proved=false
    if grep -q 'the fix is proved' "$out/logs/$ticket.oracle.log"; then proved=true; fi
    record "$(jq -n --arg id "$id" --arg ticket "$ticket" --argjson proved "$proved" \
                --arg log "logs/$ticket.oracle.log" '{id: $id, ticket: $ticket, phase: "oracle", proved: $proved, log: $log}')"
    if [[ $proved != true ]]; then exp_info "  oracle fix: not proved"; continue; fi
    exp_info "  oracle fix: proved"
    # Pre-flight: a later ticket, branched from the fixed work, run on the
    # faulty environment again, must be detained before any loop.
    tutoring="$(git -C "$ws.worktrees/$ticket" rev-parse --abbrev-ref HEAD)"
    n=$((n + 1))
    later="EXP-$n"
    (
      cd "$ws"
      env "${env[@]}" CHALK_BASE_BRANCH="$tutoring" chalk new "$later" "$id regression" >/dev/null
      cd "$ws.worktrees/$later"
      spec <(jq --arg t "$later" '. + {ticket: $t}' "$file") > "specs/$later.md"
      git add -A && git commit -q -m "spec for $id regression"
      # The instance's environment, without the oracle's fix: CHALK_IMAGE
      # and CHALK_SETUP_CMD from the environment win over .chalk/config.
      env "${env[@]}" CHALK_IMAGE="$(jq -r '.image // "chalk-sandbox:local"' "$file")" \
        CHALK_SETUP_CMD="$(jq -r '.setup_cmd // ""' "$file")" CHALK_BASE_BRANCH="$tutoring" chalk run
    ) > "$out/logs/$later.log" 2>&1 || true
    caught=false loops="$(grep -c '\] loop [0-9]* (.*) started' "$out/logs/$later.log" || true)"
    if grep -q '\] DETENTION: pre-flight: a saved need fails' "$out/logs/$later.log"; then caught=true; fi
    record "$(jq -n --arg id "$id" --arg ticket "$later" --argjson caught "$caught" --argjson loops "${loops:-0}" \
                --arg log "logs/$later.log" '{id: $id, ticket: $ticket, phase: "preflight", caught: $caught, loops: $loops, log: $log}')"
    if [[ $caught == true ]]; then exp_info "  pre-flight on the faulty environment: caught, after $loops loop(s)"
    else exp_info "  pre-flight on the faulty environment: not caught"; fi
  done
done
exp_info "done: $n run(s); results in $results"
