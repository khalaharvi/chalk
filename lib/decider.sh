# The decider (System 1): a small, fast model that answers bounded
# questions, such as "is this loop stuck?" or "does this lesson apply?",
# so that Chalk does not have to ask Claude. Chalk speaks one protocol to
# every decider (docs/decider-protocol.md): the strands-decider API, plus a
# version field and an optional bearer token.
#
# CHALK_DECIDER is off, shadow (record answers only) or on (act on answers
# at CHALK_DECIDER_THRESHOLD or above). The decider is optional and never
# holds a run up: any error, a timeout or a used-up budget is no answer,
# and a loop with no answer goes on as with CHALK_DECIDER=off.
#
# The local reference service, managed by `chalk decider up|down|status`,
# runs on 127.0.0.1 and is two processes: strands-decider, installed with
# `uv tool install`, and chalk-embed (share/decider/chalk-embed.py), the
# embedding model for semantic lesson recall. Both exit after
# CHALK_DECIDER_IDLE_MINUTES without a request, and a run starts them again
# (decider_start_once). A run never downloads anything.

DECIDER_PROTOCOL=1
DECIDER_PORT=8471
DECIDER_EMBED_PORT=8472
DECIDER_LOCAL_URL="http://127.0.0.1:$DECIDER_PORT"
DECIDER_EMBED_LOCAL_URL="http://127.0.0.1:$DECIDER_EMBED_PORT"
# Track the latest release and model revision; `chalk decider up` records
# what it resolved (maintainer's decision on #34: no pinning).
DECIDER_PACKAGE=strands-decider
DECIDER_MODEL=StrandsAgents/strands-decider-2B-hobson-v19
DECIDER_EMBED_MODEL=BAAI/bge-small-en-v1.5
DECIDER_EMBED_DIMENSIONS=384

# All host-service calls in one loop share this many milliseconds; each
# call may take what is left (eng review R2-11). A call is not started
# with less than DECIDER_MIN_CALL_MS left.
DECIDER_LOOP_BUDGET_MS=2000
DECIDER_MIN_CALL_MS=50
# Above this median per decision, measured by `chalk decider up`, the local
# service may record (shadow) but not act (on) on this machine.
DECIDER_SLOW_MS=1000
# Host memory Docker leaves free that auto-start needs: the decider (about
# 4.3 GiB) plus the embedding model plus headroom (eng review TD3).
DECIDER_HEADROOM_MB=6144
# The stuck question's text is capped near 1,500 tokens.
DECIDER_STATE_CHARS=6000
# Lessons the rerank asks about at once.
DECIDER_SHORTLIST=8

# The current loop's spend of DECIDER_LOOP_BUDGET_MS, and its limit; see
# decider_budget_reset.
DECIDER_SPENT_MS=0
DECIDER_LIMIT_MS=$DECIDER_LOOP_BUDGET_MS
# What the last call to a service came to: an error name (empty when it
# answered), its milliseconds, and the model that answered.
DECIDER_ERROR=""
DECIDER_MS=0
DECIDER_ANSWERED_BY=""
# Warnings already given in this process, by name.
declare -gA DECIDER_WARNED=()

# decider_dir -> REPLY: where the local service keeps its pids, logs and
# what `up` installed.
decider_dir() {
  REPLY="${XDG_STATE_HOME:-$HOME/.local/state}/chalk/decider"
}

# decider_warn_once NAME MESSAGE: warns, at most once per process for NAME.
decider_warn_once() {
  [[ ! -v DECIDER_WARNED[$1] ]] || return 0
  DECIDER_WARNED[$1]=1
  warn "$2"
}

# True when CHALK_DECIDER_URL is the local reference service, which Chalk
# starts and stops. Any other URL is a decider someone else runs.
decider_local() {
  [[ ${CHALK_DECIDER_URL%/} == "$DECIDER_LOCAL_URL" ]]
}

# decider_info VAR: fills the associative array VAR with what `chalk
# decider up` recorded: the models and the revisions it resolved, the
# device, the strands-decider version and the measured median (bench_ms).
# Empty when the local service was never installed.
decider_info() {
  local -n __info=$1
  local file line
  __info=()
  file="${| decider_dir; }/installed"
  [[ -f $file ]] || return 0
  while IFS= read -r line; do
    [[ $line == ?*=* ]] || continue
    __info["${line%%=*}"]="${line#*=}"
  done < "$file"
}

decider_installed() {
  [[ -f ${| decider_dir; }/installed ]]
}

# decider_slow -> REPLY: the measured median in milliseconds when it is
# above DECIDER_SLOW_MS on this machine; empty otherwise, and for a decider
# that is not local.
decider_slow() {
  local -A info
  REPLY=""
  decider_local || return 0
  decider_info info
  if [[ ${info[bench_ms]-} =~ ^[0-9]+$ ]] && (( info[bench_ms] > DECIDER_SLOW_MS )); then
    REPLY="${info[bench_ms]}"
  fi
}

# decider_mode -> REPLY: the mode decisions are taken in: CHALK_DECIDER,
# except that `on` is held to shadow on a machine where the local service
# measured slower than DECIDER_SLOW_MS (maintainer's decision on #34).
decider_mode() {
  local slow
  REPLY="${CHALK_DECIDER:-off}"
  [[ $REPLY == on ]] || return 0
  slow="${| decider_slow; }"
  [[ -n $slow ]] || { REPLY=on; return 0; }
  decider_warn_once slow "the local decider took ${slow} ms per decision when measured (over ${DECIDER_SLOW_MS} ms); it records in shadow mode only on this machine (see: chalk doctor)"
  REPLY=shadow
}

# decider_now_ms -> REPLY: wall-clock milliseconds. EPOCHREALTIME's decimal
# point follows the locale, so its digits are read whatever it is.
decider_now_ms() {
  REPLY="${EPOCHREALTIME//[!0-9]/}"
  REPLY=$((10#$REPLY / 1000))
}

# decider_budget_reset [LIMIT_MS]: starts a loop's budget for host-service
# calls, DECIDER_LOOP_BUDGET_MS unless LIMIT_MS is given (`chalk decider up`
# gives its own calls longer).
decider_budget_reset() {
  DECIDER_SPENT_MS=0
  DECIDER_LIMIT_MS="${1:-$DECIDER_LOOP_BUDGET_MS}"
}

# decider_touch: marks the local service as used now, for idle shutdown.
decider_touch() {
  local dir
  dir="${| decider_dir; }"
  [[ -d $dir ]] && : > "$dir/last-used" 2>/dev/null || true
}

# decider_post URL OUT [TOKEN_VAR]: POSTs the JSON on stdin to URL, within
# what is left of the loop's budget, and writes the response body to OUT.
# Sets DECIDER_ERROR (empty when the service answered 200) and DECIDER_MS,
# and adds DECIDER_MS to the budget spent. Returns non-zero on no answer.
# TOKEN_VAR names a variable holding a bearer token; curl reads the header
# from a file descriptor, so the token never appears in its arguments.
decider_post() {
  local url="$1" out="$2" token="" left max started now code status=0 hfd=""
  local -a auth=()
  DECIDER_ERROR="" DECIDER_MS=0
  if [[ -n ${3:-} ]]; then token="${!3-}"; fi
  left=$((DECIDER_LIMIT_MS - DECIDER_SPENT_MS))
  if (( left < DECIDER_MIN_CALL_MS )); then
    DECIDER_ERROR=budget
    return 1
  fi
  printf -v max '%d.%03d' $((left / 1000)) $((left % 1000))
  if [[ -n $token ]]; then
    exec {hfd}< <(printf 'Authorization: Bearer %s\n' "$token")
    auth=(-H "@/dev/fd/$hfd")
  fi
  started="${| decider_now_ms; }"
  code="$(curl -sS -o "$out" -w '%{http_code}' --max-time "$max" \
            -H 'Content-Type: application/json' "${auth[@]}" --data-binary @- "$url" 2>/dev/null)" || status=$?
  if [[ -n $hfd ]]; then exec {hfd}<&-; fi
  now="${| decider_now_ms; }"
  DECIDER_MS=$((now - started))
  DECIDER_SPENT_MS=$((DECIDER_SPENT_MS + DECIDER_MS))
  if (( status == 28 )); then DECIDER_ERROR=timeout
  elif (( status != 0 )) || [[ $code == 000 ]]; then DECIDER_ERROR=unreachable
  else
    case "$code" in
      200) ;;
      401|403) DECIDER_ERROR=auth ;;
      4??) DECIDER_ERROR=rejected ;;
      5??) DECIDER_ERROR=server ;;
      *)   DECIDER_ERROR=invalid ;;
    esac
  fi
  [[ -z $DECIDER_ERROR ]]
}

# decider_wake: after a call to the local service found nothing listening,
# as after an idle shutdown in a long run, starts it in the background, so
# that later loops of this run get answers. The same gate as at run start.
decider_wake() {
  ! decider_alive || return 0
  decider_autostart_ok || return 0
  local dir
  dir="${| decider_dir; }"
  mkdir -p "$dir"
  jobs_detach "$dir/start.log" decider_start_once
}

# decider_ask STATE QUESTIONS VAR: asks the decider the questions in
# QUESTIONS, a JSON object of questions by key (docs/decider-protocol.md),
# about STATE, and fills the associative array VAR with "ANSWER CONFIDENCE"
# by key: ANSWER is yes or no for a noul question (the option for choice,
# the level for score), CONFIDENCE is in thousandths. A key the decider left
# out is missing from VAR. Sets DECIDER_ERROR, DECIDER_MS and
# DECIDER_ANSWERED_BY. Returns non-zero when there is no answer.
decider_ask() {
  local state="$1" questions="$2" out key answer confidence lines
  local -n __answers=$3
  __answers=()
  DECIDER_ANSWERED_BY=""
  out="$(mktemp)"
  # Not a pipe: decider_post must run in this shell to spend the budget.
  decider_post "${CHALK_DECIDER_URL%/}/v1/systemone" "$out" CHALK_DECIDER_TOKEN \
    <<<"$(jq -cn --arg state "$state" --argjson questions "$questions" --argjson protocol "$DECIDER_PROTOCOL" \
            '{protocol: $protocol, state: $state, questions: $questions}')" || true
  if decider_local; then
    decider_touch
    if [[ $DECIDER_ERROR == unreachable ]]; then decider_wake; fi
  fi
  if [[ -z $DECIDER_ERROR ]]; then
    # One line for the protocol and model, then KEY TAB ANSWER TAB CONFIDENCE.
    lines="$(jq -r '
      if (.answers | type) != "object" then error("no answers") else . end
      | "\(.protocol // 1)\t\(.model // "")",
        (.answers | to_entries[] | .key as $k | .value
         | if .type == "noul" and (.noul | type) == "number" then
             [$k, (if .noul >= 0.5 then "yes" else "no" end), ([.noul, 1 - .noul] | max)]
           elif .type == "choice" and (.confidence | type) == "number" then [$k, .choice, .confidence]
           elif .type == "score" and (.confidence | type) == "number" then [$k, (.score | tostring), .confidence]
           else empty end
         | "\(.[0])\t\(.[1])\t\(.[2] * 1000 | round)")' "$out" 2>/dev/null)" || DECIDER_ERROR=invalid
  fi
  rm -f "$out"
  if [[ -z $DECIDER_ERROR ]]; then
    # Named so that it cannot hide the caller's VAR from __answers.
    local protocol revision
    local -A decider_ask_installed
    IFS=$'\t' read -r protocol DECIDER_ANSWERED_BY <<<"${lines%%$'\n'*}"
    # The local service's model, with the revision `chalk decider up` resolved.
    if decider_local; then
      decider_info decider_ask_installed
      if [[ ${decider_ask_installed[decider_model]-} == *@* ]]; then
        revision="${decider_ask_installed[decider_model]##*@}"
        DECIDER_ANSWERED_BY="${DECIDER_ANSWERED_BY:-${DECIDER_MODEL#*/}}@${revision:0:7}"
      fi
    fi
    if [[ $protocol != "$DECIDER_PROTOCOL" ]]; then
      DECIDER_ERROR=version
      decider_warn_once version "the decider at $CHALK_DECIDER_URL speaks protocol $protocol; Chalk speaks $DECIDER_PROTOCOL, so its answers are ignored"
    else
      while IFS=$'\t' read -r key answer confidence; do
        [[ -n $key && $confidence =~ ^[0-9]+$ ]] || continue
        __answers["$key"]="$answer $confidence"
      done < <(tail -n +2 <<<"$lines")
    fi
  fi
  if [[ $DECIDER_ERROR == auth ]]; then
    decider_warn_once auth "the decider at $CHALK_DECIDER_URL refused the request (check CHALK_DECIDER_TOKEN); continuing without it"
  fi
  [[ -z $DECIDER_ERROR ]]
}

# decider_embed TEXT... -> REPLY: the embeddings of the texts from
# chalk-embed, one JSON array per line, in pgvector's text form; empty when
# there is no answer. Shares the loop's budget.
decider_embed() {
  local out vectors=""
  out="$(mktemp)"
  decider_post "${CHALK_EMBED_URL%/}/v1/embeddings" "$out" \
    <<<"$(jq -cn --arg model "$DECIDER_EMBED_MODEL" '{model: $model, input: $ARGS.positional}' --args "$@")" || true
  if [[ ${CHALK_EMBED_URL%/} == "$DECIDER_EMBED_LOCAL_URL" ]]; then decider_touch; fi
  if [[ -z $DECIDER_ERROR ]]; then
    # Only whole answers of the right size: a vector(384) column refuses others.
    vectors="$(jq -c --argjson n "$#" --argjson dim "$DECIDER_EMBED_DIMENSIONS" '
      .data | if length == $n and all(.[]; (.embedding | length) == $dim)
              then sort_by(.index)[] | .embedding else error("wrong shape") end' "$out" 2>/dev/null)" ||
      { DECIDER_ERROR=invalid; vectors=""; }
  fi
  rm -f "$out"
  REPLY="$vectors"
}

# decider_threshold_milli -> REPLY: CHALK_DECIDER_THRESHOLD in thousandths.
decider_threshold_milli() {
  local whole frac
  whole="${CHALK_DECIDER_THRESHOLD%%.*}" frac=""
  [[ $CHALK_DECIDER_THRESHOLD != *.* ]] || frac="${CHALK_DECIDER_THRESHOLD#*.}"
  frac="${frac}000"
  REPLY=$((10#${whole:-0} * 1000 + 10#${frac:0:3}))
}

# decider_record KIND QUESTION ANSWER CONFIDENCE ACTED [LESSON_ID]: keeps one
# decision of the current loop until decider_flush stores it with the
# loop's call. ANSWER and CONFIDENCE (thousandths) are empty when there was
# no answer; DECIDER_ERROR says why. Decisions outside a run are not kept.
decider_record() {
  [[ -n ${RUN_ID:-} && -d ${RUN_IO:-} ]] || return 0
  local confidence=""
  if [[ -n $4 ]]; then printf -v confidence '%d.%03d' $(($4 / 1000)) $(($4 % 1000)); fi
  jq -cn --arg kind "$1" --arg question "$2" --arg answer "$3" --arg confidence "$confidence" \
     --arg acted "$5" --arg lesson "${6:-}" --arg mode "${| decider_mode; }" \
     --arg threshold "$CHALK_DECIDER_THRESHOLD" --arg ms "$DECIDER_MS" \
     --arg model "$DECIDER_ANSWERED_BY" --arg error "$DECIDER_ERROR" '
    def num: if . == "" then null else tonumber end;
    {kind: $kind, question: $question, answer: ($answer | if . == "" then null else . end),
     confidence: ($confidence | num), threshold: ($threshold | num), mode: $mode,
     latency_ms: ($ms | num), acted: ($acted == "true"), lesson_id: ($lesson | num),
     model: ($model | if . == "" then null else . end),
     error: ($error | if . == "" then null else . end)}' >> "$RUN_IO/decisions.jsonl"
}

# decider_flush: stores the current loop's decisions with its call (the
# runs row of RUN_ID and RUN_LOOP). Best effort: a failure loses them.
decider_flush() {
  local file="${RUN_IO:-}/decisions.jsonl"
  [[ -s $file ]] || return 0
  db_record_decisions "$(jq -cs . "$file")" 2>/dev/null || warn "could not record this loop's decider answers"
  rm -f "$file"
}

# ---------------------------------------------------------------- the stuck question

# The question asked of a loop the fingerprint rules cannot settle.
DECIDER_STUCK_QUESTION="Is the agent stuck on the same root cause as in the previous loop, so that another attempt would fail the same way?"

# decider_stuck STATE -> REPLY: "yes CONFIDENCE" when the decider judges
# the loop stuck at CHALK_DECIDER_THRESHOLD or above and may act (on);
# empty otherwise. Records the decision either way.
decider_stuck() {
  local state="$1" questions answer="" confidence="" mode acted=false
  local -A answers
  REPLY=""
  questions="$(jq -cn --arg q "$DECIDER_STUCK_QUESTION" '{stuck: {type: "noul", instructions: $q}}')"
  if decider_ask "${state:0:$DECIDER_STATE_CHARS}" "$questions" answers && [[ -v answers[stuck] ]]; then
    read -r answer confidence <<<"${answers[stuck]}"
  fi
  mode="${| decider_mode; }"
  if [[ $answer == yes && $mode == on ]] && (( confidence >= ${| decider_threshold_milli; } )); then
    acted=true
    REPLY="yes $confidence"
  fi
  decider_record stuck "$DECIDER_STUCK_QUESTION" "$answer" "$confidence" "$acted"
}

# ---------------------------------------------------------------- lesson recall

# decider_recall VAR REPO MODE QUERY [FINGERPRINT] [FIRST_ERROR]: the recall
# ladder's last two steps, once there are CHALK_DECIDER_MIN_LESSONS resolved
# lessons. Semantic recall (pgvector, Postgres 17 only) adds lessons whose
# failure means the same as QUERY to the lexical ones; the decider then
# reranks up to 8 of them in one batched request. Exact matches come first
# and are always kept. With CHALK_DECIDER=on, fills VAR with up to three
# lessons, as memory_recall prints them, and returns 0. In shadow mode, or
# without an answer, it only records, and returns non-zero: the caller keeps
# the lexical list.
decider_recall() {
  local -n __recalled=$1
  local repo="$2" mode="$3" query="$4" fingerprint="${5:-}" first_error="${6:-}"
  local resolved=0 vector=0 qvec="" shortlist questions id answer confidence threshold
  local -a exact=() kept=() rows=()
  local -A answers line
  read -r resolved vector < <(db_decider_gate 2>/dev/null || true) || true
  [[ $resolved =~ ^[0-9]+$ ]] && (( resolved >= CHALK_DECIDER_MIN_LESSONS )) || return 1

  if [[ $vector == 1 ]]; then qvec="${| decider_embed "$query"; }"; fi
  shortlist="$(db_recall_shortlist "$repo" "$mode" "$query" "$fingerprint" "$first_error" "$qvec" \
                 "$DECIDER_SHORTLIST" 2>/dev/null)" || return 1
  [[ -n $shortlist ]] || return 1
  mapfile -t exact < <(jq -r '.[] | select(.exact) | .line | @json' <<<"$shortlist")
  # ID, a tab, then the line as a JSON string, which holds no raw tab or newline.
  mapfile -t rows < <(jq -r '.[] | select(.exact | not) | "\(.id)\t\(.line | @json)"' <<<"$shortlist")
  (( ${#rows[@]} )) || return 1
  questions="$(jq -c '[.[] | select(.exact | not)
      | {key: "lesson_\(.id)", value: {type: "noul", instructions:
          ("Does this past lesson apply to the current failure, so that its fix would help?\n" + .text)}}]
      | from_entries' <<<"$shortlist")"

  if ! decider_ask "Current failure:
${query:0:$DECIDER_STATE_CHARS}" "$questions" answers; then
    decider_record rerank "rerank ${#rows[@]} lessons" "" "" false
    return 1
  fi
  threshold="${| decider_threshold_milli; }"
  local -a scored=()
  for row in "${rows[@]}"; do
    id="${row%%$'\t'*}"
    line[$id]="${row#*$'\t'}"
    answer="" confidence=""
    if [[ -v answers[lesson_$id] ]]; then read -r answer confidence <<<"${answers[lesson_$id]}"; fi
    if [[ $answer == yes ]] && (( confidence >= threshold )); then scored+=("$confidence $id"); fi
  done
  # The kept lessons, most confident first, after every exact match, up to three in all.
  mapfile -t kept < <(printf '%s\n' "${scored[@]}" | sort -rn | cut -d' ' -f2 | head -n "$((3 - ${#exact[@]} > 0 ? 3 - ${#exact[@]} : 0))")
  local acting=false
  [[ ${| decider_mode; } != on ]] || acting=true
  for row in "${rows[@]}"; do
    id="${row%%$'\t'*}"
    answer="" confidence=""
    if [[ -v answers[lesson_$id] ]]; then read -r answer confidence <<<"${answers[lesson_$id]}"; fi
    local acted=false
    if [[ $acting == true && " ${kept[*]} " == *" $id "* ]]; then acted=true; fi
    decider_record rerank "Does lesson $id apply to the current failure?" "$answer" "$confidence" "$acted" "$id"
  done
  [[ $acting == true ]] || return 1

  local -a lines=()
  for row in "${exact[@]:0:3}"; do lines+=("$(jq -r . <<<"$row")"); done
  for id in "${kept[@]}"; do [[ -z $id ]] || lines+=("$(jq -r . <<<"${line[$id]}")"); done
  __recalled="$(printf '%s\n' "${lines[@]}")"
  [[ -n ${lines[*]} ]] || __recalled=""
  return 0
}

# decider_embed_lessons [LIMIT] -> REPLY: writes embeddings for resolved
# lessons that have none, 16 per request, at most LIMIT of them (default
# all), and gives how many it wrote. Needs Postgres 17 and chalk-embed;
# without either it writes none.
decider_embed_lessons() {
  local limit="${1:-0}" written=0 batch vectors pairs
  local -a texts
  while :; do
    batch="$(db_lessons_to_embed 16 2>/dev/null || true)"
    [[ -n $batch && $batch != '[]' ]] || break
    mapfile -d '' -t texts < <(jq -j '.[] | .text + "\u0000"' <<<"$batch")
    decider_budget_reset 30000
    vectors="${| decider_embed "${texts[@]}"; }"
    [[ -n $vectors ]] || break
    pairs="$(jq -cn --argjson rows "$batch" --slurpfile vectors <(printf '%s\n' "$vectors") '
      if ($vectors | length) == ($rows | length)
      then [range(0; $rows | length) as $i | {id: $rows[$i].id, embedding: ($vectors[$i] | tostring)}]
      else error("one vector per lesson") end' 2>/dev/null)" || break
    db_set_embeddings "$pairs" >/dev/null 2>&1 || break
    written=$((written + $(jq length <<<"$pairs")))
    (( limit == 0 || written < limit )) || break
  done
  decider_budget_reset
  REPLY="$written"
}

# ---------------------------------------------------------------- the local service

# decider_pid NAME -> REPLY: the pid in NAME.pid when that process is alive;
# empty otherwise.
decider_pid() {
  local pid=""
  REPLY=""
  { read -r pid < "${| decider_dir; }/$1.pid"; } 2>/dev/null || true
  if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then REPLY="$pid"; fi
}

# True when either service process of the local decider is alive.
decider_alive() {
  [[ -n ${| decider_pid decider; } || -n ${| decider_pid embed; } ]]
}

# decider_healthy [URL] [TOKEN_VAR]: true when the service at URL (default
# CHALK_DECIDER_URL) answers GET /health with status ok within two seconds.
decider_healthy() {
  local url="${1:-$CHALK_DECIDER_URL}" token="" hfd="" status=0
  local -a auth=()
  if [[ -n ${2:-} ]]; then token="${!2-}"; fi
  if [[ -n $token ]]; then
    exec {hfd}< <(printf 'Authorization: Bearer %s\n' "$token")
    auth=(-H "@/dev/fd/$hfd")
  fi
  curl -sS --max-time 2 "${auth[@]}" "${url%/}/health" 2>/dev/null | jq -e '.status == "ok"' >/dev/null 2>&1 || status=$?
  if [[ -n $hfd ]]; then exec {hfd}<&-; fi
  return "$status"
}

# decider_bin -> REPLY: the strands-decider command uv installed; empty
# when it is not there.
decider_bin() {
  local dir
  REPLY=""
  dir="$(uv tool dir --bin 2>/dev/null || true)"
  if [[ -n $dir && -x $dir/strands-decider ]]; then REPLY="$dir/strands-decider"; fi
}

# decider_headroom -> REPLY: MiB of host memory Docker leaves free; empty
# when the host profile could not tell.
decider_headroom() {
  system_profile
  REPLY=""
  if [[ -n ${SYS[ram_mb]:-} && -n ${SYS[docker_mem_mb]:-} ]]; then
    REPLY=$((SYS[ram_mb] - SYS[docker_mem_mb]))
  fi
}

# decider_autostart_ok: true when a run may start the local service: it is
# installed, and the host has DECIDER_HEADROOM_MB free beside Docker. An
# explicit CHALK_DECIDER=on starts it whatever the headroom. Warns once
# when headroom is what stops it; the run then goes on as with
# CHALK_DECIDER=off.
decider_autostart_ok() {
  local free
  decider_local && decider_installed || return 1
  [[ $CHALK_DECIDER != on ]] || return 0
  free="${| decider_headroom; }"
  if [[ -n $free ]] && (( free < DECIDER_HEADROOM_MB )); then
    decider_warn_once headroom "not starting the local decider: Docker leaves ${free} MiB of host memory free and it needs ${DECIDER_HEADROOM_MB} (set CHALK_DECIDER=on to start it anyway); continuing without it"
    return 1
  fi
}

# decider_launch [ONLINE]: starts both service processes in the background,
# each in a process group of its own, with pidfiles, and the idle watcher.
# They never download unless ONLINE is 1 (only `chalk decider up`).
decider_launch() {
  local dir bin offline=1
  dir="${| decider_dir; }"
  bin="${| decider_bin; }"
  [[ -n $bin ]] || { warn "strands-decider is not installed; run: chalk decider up"; return 1; }
  [[ ${1:-0} != 1 ]] || offline=0
  mkdir -p "$dir"
  rm -f "$dir/decider.pid" "$dir/embed.pid"
  : > "$dir/last-used"
  if (( offline )); then export HF_HUB_OFFLINE=1; fi
  jobs_detach "$dir/decider.log" decider_exec_serve "$bin" "$dir/decider.pid"
  jobs_detach "$dir/embed.log" uv run --script "$CHALK_HOME/share/decider/chalk-embed.py" \
    --port "$DECIDER_EMBED_PORT" --pidfile "$dir/embed.pid"
  jobs_detach "$dir/watch.log" decider_watch
  if (( offline )); then unset HF_HUB_OFFLINE; fi
}

# decider_exec_serve BIN PIDFILE: becomes strands-decider serving on
# DECIDER_PORT, after writing its own pid (exec keeps the pid).
decider_exec_serve() {
  printf '%s\n' "$BASHPID" > "$2"
  exec "$1" serve "$DECIDER_MODEL" --host 127.0.0.1 --port "$DECIDER_PORT"
}

# Seconds between the idle watcher's checks, and the idle time after which
# it stops the service. Tests set both lower.
DECIDER_WATCH_SECONDS="${DECIDER_WATCH_SECONDS:-30}"

# decider_watch: runs beside the service, and stops it once it has had no
# request for CHALK_DECIDER_IDLE_MINUTES (eng review TD2), or ends when the
# service is gone. Its pid is in watch.pid, so only one watches.
decider_watch() {
  local dir age idle
  dir="${| decider_dir; }"
  idle="${DECIDER_IDLE_SECONDS:-$((CHALK_DECIDER_IDLE_MINUTES * 60))}"
  printf '%s\n' "$BASHPID" > "$dir/watch.pid"
  while :; do
    sleep "$DECIDER_WATCH_SECONDS"
    # Started again by someone else: that start has its own watcher.
    [[ ${| decider_pid watch; } == "$BASHPID" ]] || return 0
    decider_alive || break
    age="${| chalk_lock_age "$dir/last-used"; }"
    if [[ -n $age ]] && (( age >= idle )); then
      info "idle for ${age}s; stopping the decider"
      decider_stop
      break
    fi
  done
  rm -f "$dir/watch.pid"
}

# decider_stop: stops the service processes and the watcher, and removes
# their pidfiles.
decider_stop() {
  local dir name pid
  local -a pids=()
  dir="${| decider_dir; }"
  for name in decider embed watch; do
    pid="${| decider_pid "$name"; }"
    # The watcher stopping the service does not stop itself.
    if [[ -n $pid && $pid != "$BASHPID" ]]; then pids+=("$pid"); fi
  done
  if (( ${#pids[@]} )); then
    kill -TERM "${pids[@]}" 2>/dev/null || true
    local tries alive
    for tries in {1..50}; do
      alive=0
      for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then alive=1; fi
      done
      (( alive )) || break
      sleep 0.1
    done
    if (( alive )); then kill -KILL "${pids[@]}" 2>/dev/null || true; fi
  fi
  rm -f "$dir/decider.pid" "$dir/embed.pid"
  [[ ${| decider_pid watch; } != "$BASHPID" ]] || rm -f "$dir/watch.pid"
}

# decider_start_once: starts the local service unless it is running, and
# exactly once however many runs ask at the same time (eng review A3): one
# starter takes the decider lock, starts both processes, and holds the lock
# until the decider is healthy or the wait is over; the others find the
# lock held, or the service alive, and leave it. Run in the background by
# run_start_services (never in jobs_wait), so a run does not wait for it.
decider_start_once() {
  local limit waited=0
  if decider_alive; then decider_touch; return 0; fi
  chalk_lock decider 0 || return 0
  if decider_alive; then
    chalk_unlock decider
    decider_touch
    return 0
  fi
  info "starting the local decider"
  if ! decider_launch; then
    chalk_unlock decider
    return 1
  fi
  limit="${| system_timeout 120 "${CHALK_DECIDER_TIMEOUT:-auto}"; }"
  until decider_healthy "$DECIDER_LOCAL_URL"; do
    waited=$((waited + 1))
    if (( waited >= limit )) || ! decider_alive; then
      warn "the local decider did not become healthy in ${waited}s (see ${| decider_dir; }/decider.log)"
      chalk_unlock decider
      return 1
    fi
    sleep 1
  done
  chalk_unlock decider
  info "the local decider is up after ${waited}s"
  # Lessons resolved while it was stopped get their embeddings, once
  # chalk-embed, which loads faster, is up too.
  for waited in {1..30}; do
    if decider_healthy "$DECIDER_EMBED_LOCAL_URL"; then
      info "embedded ${| decider_embed_lessons; } resolved lesson(s)"
      break
    fi
    sleep 1
  done
}

# ---------------------------------------------------------------- chalk decider up

# A stuck question about the size the run sends, for the benchmark.
decider_bench_state() {
  local i
  REPLY="previous loop:
  failing tests (3): tests/test_api.py::test_create, tests/test_api.py::test_update, tests/test_api.py::test_delete
  first error: AssertionError: assert 500 == 201
current loop:
  failing tests (3): tests/test_api.py::test_create, tests/test_api.py::test_update, tests/test_api.py::test_delete
  first error: AssertionError: assert 500 == 201
changes between the two loops (git diff --stat):"
  for i in {1..40}; do REPLY+=$'\n'"  src/service/module_$i.py | $((i % 7 + 1)) +-"; done
}

# decider_bench -> REPLY: the median milliseconds of five warm stuck
# questions to the local service, after one to warm it; empty when it did
# not answer.
decider_bench() {
  local state questions i
  local -a times=()
  local -A answers
  state="${| decider_bench_state; }"
  questions="$(jq -cn --arg q "$DECIDER_STUCK_QUESTION" '{stuck: {type: "noul", instructions: $q}}')"
  REPLY=""
  for i in {0..5}; do
    decider_budget_reset 60000
    decider_ask "$state" "$questions" answers || { decider_budget_reset; return 0; }
    (( i == 0 )) || times+=("$DECIDER_MS")
  done
  decider_budget_reset
  REPLY="$(printf '%s\n' "${times[@]}" | sort -n | sed -n 3p)"
}

# decider_hf_cache -> REPLY: the Hugging Face hub cache.
decider_hf_cache() {
  REPLY="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
}

# decider_revision REPO -> REPLY: the commit of REPO that the hub cache
# resolved for main; empty when it is not cached.
decider_revision() {
  local file
  REPLY=""
  file="${| decider_hf_cache; }/models--${1//\//--}/refs/main"
  if [[ -f $file ]]; then read -r REPLY < "$file" || true; fi
}

decider_up() {
  local dir bin base base_rev rev embed_line median version device health
  decider_local ||
    die "CHALK_DECIDER_URL is $CHALK_DECIDER_URL; 'chalk decider up' manages only the local service ($DECIDER_LOCAL_URL)"
  command -v uv >/dev/null 2>&1 ||
    die "the local decider is installed with uv, which is not installed: brew install uv (or see https://docs.astral.sh/uv/)"
  need curl jq
  dir="${| decider_dir; }"
  mkdir -p "$dir"
  chalk_lock decider 300 || die "another chalk is starting the decider; try again in a moment"

  info "installing $DECIDER_PACKAGE with uv (latest release)"
  uv tool install --upgrade "$DECIDER_PACKAGE" >"$dir/install.log" 2>&1 ||
    { chalk_unlock decider; die "could not install $DECIDER_PACKAGE (see $dir/install.log)"; }
  bin="${| decider_bin; }"
  [[ -n $bin ]] || { chalk_unlock decider; die "uv installed $DECIDER_PACKAGE, but its command is not in $(uv tool dir --bin)"; }
  version="$(uv tool list 2>/dev/null | awk -v p="$DECIDER_PACKAGE" '$1 == p { sub(/^v/, "", $2); print $2; exit }')"

  info "downloading $DECIDER_MODEL and its base model (about 4.3 GiB the first time)"
  uv tool run --from huggingface_hub hf download "$DECIDER_MODEL" >/dev/null ||
    { chalk_unlock decider; die "could not download $DECIDER_MODEL"; }
  rev="${| decider_revision "$DECIDER_MODEL"; }"
  base="$(jq -r '.base_model // empty' "${| decider_hf_cache; }/models--${DECIDER_MODEL//\//--}/snapshots/$rev/"*config.json 2>/dev/null | head -n 1)"
  [[ -n $base ]] || { chalk_unlock decider; die "could not read the base model from $DECIDER_MODEL's config"; }
  uv tool run --from huggingface_hub hf download "$base" >/dev/null ||
    { chalk_unlock decider; die "could not download $base"; }
  base_rev="${| decider_revision "$base"; }"

  info "preparing chalk-embed ($DECIDER_EMBED_MODEL)"
  embed_line="$(uv run --script "$CHALK_HOME/share/decider/chalk-embed.py" --download 2>"$dir/embed-install.log" | tail -n 1)" ||
    { chalk_unlock decider; die "could not prepare chalk-embed (see $dir/embed-install.log)"; }

  decider_stop
  info "starting the decider on $DECIDER_LOCAL_URL"
  decider_launch || { chalk_unlock decider; die "could not start the decider"; }
  local waited=0 limit
  limit="${| system_timeout 300 "${CHALK_DECIDER_TIMEOUT:-auto}"; }"
  until decider_healthy "$DECIDER_LOCAL_URL" && decider_healthy "$DECIDER_EMBED_LOCAL_URL"; do
    waited=$((waited + 1))
    if (( waited >= limit )) || ! decider_alive; then
      decider_stop
      chalk_unlock decider
      die "the decider did not become healthy in ${waited}s (see $dir/decider.log and $dir/embed.log)"
    fi
    sleep 1
  done
  health="$(curl -sS --max-time 2 "$DECIDER_LOCAL_URL/health" 2>/dev/null || true)"
  device="$(jq -r '.device // empty' <<<"$health" 2>/dev/null || true)"

  info "measuring the time per decision"
  median="${| decider_bench; }"
  local embed_rev="" embed_device=""
  read -r _ embed_rev embed_device <<<"$embed_line" || true
  {
    printf 'installed_at=%(%F %T)T\n' -1
    printf 'package=%s %s\n' "$DECIDER_PACKAGE" "${version:-?}"
    printf 'decider_model=%s@%s\n' "$DECIDER_MODEL" "${rev:-?}"
    printf 'base_model=%s@%s\n' "$base" "${base_rev:-?}"
    printf 'embed_model=%s@%s\n' "$DECIDER_EMBED_MODEL" "${embed_rev:-?}"
    printf 'device=%s\n' "${device:-?}"
    printf 'embed_device=%s\n' "${embed_device:-?}"
    printf 'bench_ms=%s\n' "$median"
  } > "$dir/installed"
  chalk_unlock decider

  local -A got
  decider_info got
  info "decider: ${got[decider_model]} on ${got[device]}"
  info "  base:  ${got[base_model]}"
  info "  embed: ${got[embed_model]} on ${got[embed_device]}"
  if [[ -z $median ]]; then
    warn "the decider did not answer the benchmark; check: chalk decider status"
  elif (( median > DECIDER_SLOW_MS )); then
    warn "median ${median} ms per decision, over ${DECIDER_SLOW_MS} ms: on this machine the decider records in shadow mode only, and CHALK_DECIDER=on acts as shadow"
  else
    info "  median ${median} ms per decision (warm)"
  fi
  if db_running 2>/dev/null; then
    # The embedding column needs the current schema.
    db_sql < "$CHALK_HOME/share/schema.sql" >/dev/null 2>&1 || true
    info "  embedded ${| decider_embed_lessons; } resolved lesson(s) that had none"
  fi
  info "it stops after ${CHALK_DECIDER_IDLE_MINUTES} idle minutes, and runs start it again. To use it, set CHALK_DECIDER=shadow."
}

decider_status() {
  local -A got
  local mode slow
  mode="${| decider_mode; }"
  info "CHALK_DECIDER=$CHALK_DECIDER (acting as $mode), CHALK_DECIDER_URL=$CHALK_DECIDER_URL"
  if ! decider_local; then
    if decider_healthy "$CHALK_DECIDER_URL" CHALK_DECIDER_TOKEN; then info "decider: healthy"
    else info "decider: not answering at $CHALK_DECIDER_URL/health"
    fi
    return 0
  fi
  decider_info got
  if [[ -z ${got[decider_model]-} ]]; then
    info "the local decider is not installed; run: chalk decider up"
    return 0
  fi
  if decider_healthy "$DECIDER_LOCAL_URL"; then info "local decider: running and healthy"
  elif decider_alive; then info "local decider: starting"
  else info "local decider: stopped (a run starts it; or: chalk decider up)"
  fi
  info "  package: ${got[package]-?}, installed ${got[installed_at]-?}"
  info "  decider: ${got[decider_model]} on ${got[device]-?}"
  info "  base:    ${got[base_model]-?}"
  info "  embed:   ${got[embed_model]-?} on ${got[embed_device]-?}"
  slow="${| decider_slow; }"
  if [[ -n $slow ]]; then
    info "  median ${slow} ms per decision: over ${DECIDER_SLOW_MS} ms, so shadow only on this machine"
  else
    info "  median ${got[bench_ms]:-?} ms per decision"
  fi
  info "  stops after ${CHALK_DECIDER_IDLE_MINUTES} idle minutes"
}

cmd_decider() {
  load_config "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  case "${1:-}" in
    up)     decider_up ;;
    down)   decider_stop; info "the local decider is stopped" ;;
    status) decider_status ;;
    *)      die "usage: chalk decider up|down|status" ;;
  esac
}
