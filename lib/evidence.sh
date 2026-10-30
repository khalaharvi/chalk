# Evidence-carrying lessons (docs/designs/evidence-lessons.md). A blocker
# about the environment comes with a probe: one command that fails now and
# must pass once the environment is fixed, such as `gcc --version` or
# `python3 -c 'import yaml'`. The probe is run when the run is detained,
# which proves the blocker real; again in a fresh sandbox after the
# engineer's fix, which proves the fix; and from then on as a saved need
# (.chalk/needs) before every run's first loop, so the same gap is never
# paid for twice. A lesson enters recall only once its probe failed before
# the fix and passed after it, and it retires when the probe passes in an
# environment without the fix (chalk needs).

# Seconds a probe may take, and how much of its output is kept.
EVIDENCE_TIMEOUT=30
EVIDENCE_OUTPUT_CHARS=2000
# Kinds of fix an agent may propose. Only image and config fixes have a
# probe: a spec change proves itself when the agent meets the new spec, and
# the sandbox holds no credentials to check.
EVIDENCE_KINDS=(image config spec credential decision)
# The settings a config fix may change. Anything else, such as the rubric,
# the permission mode or the budget, is not the agent's to propose.
EVIDENCE_CONFIG_KEYS=(CHALK_SETUP_CMD CHALK_RUBRIC_TIMEOUT)
# Saved needs, one per line: PROBE  # KIND TICKET lesson=ID
EVIDENCE_NEEDS_FILE=.chalk/needs
EVIDENCE_NEEDS_SEP='  # '

# Why the last evidence_fix dropped what the agent proposed; empty when it
# did not.
EVIDENCE_FIX_PROBLEM=""

# evidence_fix RESULT -> REPLY: the fix a blocked answer in the call result
# RESULT proposes, as compact JSON with kind, why and, by kind, probe,
# image, config (allowed keys only) and patch; empty when it proposes none
# or one that breaks the rules, with the reason in EVIDENCE_FIX_PROBLEM.
evidence_fix() {
  local fix out
  REPLY="" EVIDENCE_FIX_PROBLEM=""
  fix="$(jq -c '.structured_output.fix // empty | select(type == "object")' "$1" 2>/dev/null || true)"
  [[ -n $fix ]] || return 0
  out="$(jq -c --args '
    ($ARGS.positional[0] | split(" ")) as $kinds | ($ARGS.positional[1] | split(" ")) as $keys
    | if (.kind | IN($kinds[])) | not then error("kind must be one of \($kinds | join(", "))")
      elif (.why // "" | type) != "string" then error("why must be text")
      else . end
    | {kind, why: (.why // "")}
      + (if .kind == "image" or .kind == "config" then
           if (.probe // "" | type) != "string" or (.probe // "") == "" then error("an \(.kind) fix needs a probe")
           elif (.probe | test("\n")) then error("the probe must be one line")
           elif (.probe | length) > 300 then error("the probe is over 300 characters")
           elif (.probe | contains("  # ")) then error("the probe may not contain \"  # \"")
           else {probe} end
         else {} end)
      + (if .kind == "image" and (.image | type) == "string" then {image} else {} end)
      + (if .kind == "config" and (.config | type) == "object" then
           {config: (.config | with_entries(select(.key | IN($keys[])) | .value |= tostring))}
           # .chalk/config is read a line at a time: a value with a line
           # break in it would set keys the allow-list does not allow.
           | if any(.config[]; test("[\r\n]")) then error("a config value must be one line") else . end
         else {} end)
      + (if .kind == "spec" and (.patch | type) == "string" then {patch} else {} end)' \
    "${EVIDENCE_KINDS[*]}" "${EVIDENCE_CONFIG_KEYS[*]}" <<<"$fix" 2>&1 || true)"
  if [[ $out != \{* ]]; then
    EVIDENCE_FIX_PROBLEM="$(sed -n 's/^jq: error ([^)]*): //p' <<<"$out" | head -n 1)"
    EVIDENCE_FIX_PROBLEM="${EVIDENCE_FIX_PROBLEM:-the fix could not be read}"
    return 0
  fi
  REPLY="$out"
  if [[ $(jq -c '.config | if type == "object" then keys else [] end' <<<"$fix" 2>/dev/null || true) != \
        "$(jq -c '.config | if type == "object" then keys else [] end' <<<"$REPLY" 2>/dev/null || true)" ]]; then
    EVIDENCE_FIX_PROBLEM="config keys other than ${EVIDENCE_CONFIG_KEYS[*]} were dropped"
  fi
}

# evidence_probe NAME PROBE VAR: runs PROBE in the cloned repository of the
# sandbox NAME, for at most EVIDENCE_TIMEOUT seconds, and fills the
# associative array VAR with outcome, exit and output (its first
# EVIDENCE_OUTPUT_CHARS characters); its locals start with __, so that VAR
# can be any name the caller uses. The outcome is passed (exit 0); failed
# (any other exit, a missing tool's 127 included, since a missing tool is
# what most environment blockers are); or inconclusive: a timeout (124), or
# a sandbox that is not running, when no claim can be made.
evidence_probe() {
  local __name="$1" __cmd="$2" __text __status=0
  local -n __probe=$3
  __probe=(["outcome"]=inconclusive ["exit"]="" ["output"]="")
  if [[ $(docker inspect -f '{{.State.Running}}' "$__name" 2>/dev/null) != true ]]; then
    __probe["output"]="the sandbox $__name is not running"
    return 0
  fi
  __text="$(docker exec -w /work/repo "$__name" timeout "$EVIDENCE_TIMEOUT" bash -c "$__cmd" 2>&1)" || __status=$?
  __probe["exit"]="$__status"
  __probe["output"]="${__text:0:$EVIDENCE_OUTPUT_CHARS}"
  case "$__status" in
    0)   __probe["outcome"]=passed ;;
    124) __probe["outcome"]=inconclusive
         __probe["output"]="timed out after ${EVIDENCE_TIMEOUT}s${__text:+: ${__text:0:$EVIDENCE_OUTPUT_CHARS}}" ;;
    *)   __probe["outcome"]=failed ;;
  esac
}

# evidence_image -> REPLY: the ID of CHALK_IMAGE, for the record of which
# environment a probe ran in; empty when Docker cannot say.
evidence_image() {
  REPLY="$(docker image inspect -f '{{.Id}}' "$CHALK_IMAGE" 2>/dev/null || true)"
}

# evidence_check BRANCH PROBE VAR [SETUP]: runs PROBE in a fresh sandbox on
# CHALK_IMAGE with BRANCH cloned and, when given, SETUP run first, then
# removes the sandbox. Fills VAR as evidence_probe does, plus image; a
# SETUP that fails makes the outcome inconclusive. It costs a sandbox
# start, and no agent spend.
evidence_check() {
  local __branch="$1" __cmd="$2" __setup="${4:-}" __name __io
  local -n __check=$3
  __name="${| sandbox_name "${RUN_TICKET:-chalk}-probe"; }"
  __io="$(mktemp -d)"
  sandbox_ensure_image >/dev/null
  sandbox_start "$__name" "${RUN_TICKET:-chalk}" "$__io"
  sandbox_clone "$__name" "$__branch" >/dev/null
  if [[ -n $__setup ]] && ! sandbox_sh "$__name" "$__setup" > "$__io/setup.log" 2>&1; then
    __check=(["outcome"]=inconclusive ["exit"]="" ["output"]="the setup command failed: $(tail -n 5 "$__io/setup.log")")
  else
    evidence_probe "$__name" "$__cmd" "$3"
  fi
  __check["image"]="${| evidence_image; }"
  sandbox_stop "$__name"
  rm -rf "$__io"
}

# evidence_need_line PROBE KIND TICKET LESSON_ID -> REPLY: the line that
# saves PROBE as a need in EVIDENCE_NEEDS_FILE; empty for a probe that the
# line could not hold unambiguously.
evidence_need_line() {
  REPLY=""
  [[ -n $1 && $1 != *$'\n'* && $1 != *"$EVIDENCE_NEEDS_SEP"* ]] || return 0
  REPLY="$1$EVIDENCE_NEEDS_SEP$2 $3 lesson=$4"
}

# evidence_needs ROOT VAR: fills the indexed array VAR with the needs saved
# in ROOT's EVIDENCE_NEEDS_FILE, each as "PROBE<tab>KIND<tab>TICKET<tab>ID".
# The probe is everything before the last separator. A line that is blank
# or a comment is skipped; a malformed one is skipped with a warning.
evidence_needs() {
  local file="$1/$EVIDENCE_NEEDS_FILE" line probe tail kind ticket id n=0
  local -n __needs=$2
  __needs=()
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ -n ${line//[[:space:]]/} && $line != \#* ]] || continue
    probe="${line%"$EVIDENCE_NEEDS_SEP"*}" tail="${line##*"$EVIDENCE_NEEDS_SEP"}"
    read -r kind ticket id _ <<<"$tail" || true
    if [[ $probe == "$line" || -z $probe || ! $kind =~ ^(image|config)$ || ! $id =~ ^lesson=[0-9]*$ ]]; then
      warn "skipping line $n of $EVIDENCE_NEEDS_FILE: expected 'PROBE${EVIDENCE_NEEDS_SEP}KIND TICKET lesson=ID'"
      continue
    fi
    __needs+=("$probe"$'\t'"$kind"$'\t'"$ticket"$'\t'"${id#lesson=}")
  done < "$file"
}

# evidence_fix_text FIX -> REPLY: the fix JSON in words, one line per part,
# for the detention message and the distillation prompt.
evidence_fix_text() {
  REPLY="$(jq -r '
    "kind: \(.kind)", (select(.why != "") | "why: \(.why)"),
    (.probe // empty | "probe: \(.)"), (.image // empty | "image needs: \(.)"),
    (.config // {} | to_entries[] | "config: \(.key)=\(.value)"),
    (.patch // empty | "spec patch:\n\(.)")' <<<"$1" 2>/dev/null || true)"
}
