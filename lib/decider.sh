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
# The rerank: how many lessons it asks about at once, and the characters
# of the whole request, the current failure plus every lesson question.
# The failure gets up to DECIDER_RERANK_STATE_CHARS of them; the lessons
# share the rest equally, each keeping part of its failure and of its fix.
#
# The window strands-decider-2B-hobson-v19 was evaluated at is 3,072 tokens
# (it was trained at 4,096), and its tokenizer gives about 3.1 characters a
# token on pytest failures and lesson notes. But time binds first: on an M3
# Pro (MPS) a rerank took about 0.9 ms a token, so one of 2,875 tokens
# (9,000 characters, 8 lessons) took 2.7 s, past the loop's whole 2 s
# budget. These limits make the largest about 1,340 tokens and 1.2 s, and
# leave the rest of the budget for the embedding and the stuck question.
DECIDER_SHORTLIST=5
DECIDER_RERANK_CHARS=4000
DECIDER_RERANK_STATE_CHARS=1500

# The local strands-decider must be asked one thing at a time: two requests
# at once abort it on Apple's GPU (measured with 0.1.0 on MPS: every time,
# with as few as two), and its engine keeps per-request state on itself on
# any device. So Chalk's calls to it take turns through a lock shared by
# every Chalk process on the machine. A call waits for its turn at most
# DECIDER_QUEUE_MS, and the wait counts against the loop's budget.
DECIDER_QUEUE_MS=1000
DECIDER_QUEUE_POLL=0.02

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

# ---------------------------------------------------------------- hosted services

# A host service on another machine (the decider at CHALK_DECIDER_URL, or
# chalk-embed at CHALK_EMBED_URL) is sent nothing, not even a health
# check, until the user has run `chalk decider trust URL`, which shows what
# it would receive and records URL in decider_trust_file. Until then a run
# goes on with the decider off and says why once (decider_gate). A service
# on this machine (127.0.0.0/8, localhost, ::1) needs no acknowledgement.

# decider_loopback URL: true when URL's host is this machine.
decider_loopback() {
  local host="${1#*://}"
  host="${host%%/*}"
  host="${host##*@}"
  if [[ $host == \[* ]]; then host="${host#\[}"; host="${host%%\]*}"
  else host="${host%%:*}"
  fi
  host="${host@L}"
  [[ $host == localhost || $host == ::1 || $host =~ ^127(\.[0-9]{1,3}){3}$ ]]
}

# decider_trust_file -> REPLY: where `chalk decider trust` records the URLs
# it was given, one a line.
decider_trust_file() {
  REPLY="${| decider_dir; }/trusted"
}

# decider_acknowledged URL: true when Chalk may send to URL, which may name
# an endpoint under a service's base URL: it is on this machine, or its
# service was acknowledged with `chalk decider trust`.
decider_acknowledged() {
  local url="$1" line file
  decider_loopback "$url" && return 0
  file="${| decider_trust_file; }"
  [[ -f $file ]] || return 1
  while IFS= read -r line; do
    [[ -n $line && $line != \#* ]] || continue
    if [[ $url == "$line" || $url == "$line"/* ]]; then return 0; fi
  done < "$file"
  return 1
}

# decider_unacknowledged VAR: fills the indexed array VAR with the host
# services in use, CHALK_DECIDER_URL and CHALK_EMBED_URL, that are on
# another machine and not acknowledged.
decider_unacknowledged() {
  local -n __unacked=$1
  local url
  __unacked=()
  for url in "${CHALK_DECIDER_URL%/}" "${CHALK_EMBED_URL%/}"; do
    decider_acknowledged "$url" || __unacked+=("$url")
  done
}

# decider_disclosure PREFIX DECIDER_URL EMBED_URL: prints, each line after
# PREFIX, exactly what Chalk sends the decider at DECIDER_URL and
# chalk-embed at EMBED_URL; an empty URL leaves its part out.
decider_disclosure() {
  local p="$1" where
  if [[ -n $2 ]]; then
    where="${2%/}"
    if decider_loopback "$where"; then where+=", on this machine"; fi
    printf '%s\n' \
      "${p}The decider ($where) gets, in POST /v1/systemone:" \
      "${p}- Is a loop stuck? Asked after a failed loop the verdicts call spinning or other:" \
      "${p}  the failing test IDs (up to 20) and the first error line of that loop and" \
      "${p}  the one before, and git diff --stat between their working trees (file paths" \
      "${p}  and line counts, not the changes); at most $DECIDER_STATE_CHARS characters." \
      "${p}- Which lessons apply? Asked once $CHALK_DECIDER_MIN_LESSONS lessons are resolved: the current failure," \
      "${p}  up to $DECIDER_RERANK_STATE_CHARS characters (its first error and failing test IDs; before the first" \
      "${p}  loop, the start of the spec; when the rubric gave neither, the failure reason" \
      "${p}  and the last lines of its output, which can quote source lines), and the" \
      "${p}  failure and fix note of up to $DECIDER_SHORTLIST past lessons; at most $DECIDER_RERANK_CHARS characters in all." \
      "${p}- CHALK_DECIDER_TOKEN, when it is set, as a bearer token." \
      "${p}- For chalk decider status and chalk doctor: GET /health or, without it, one" \
      "${p}  fixed question about a fixed text."
  fi
  if [[ -n $3 ]]; then
    where="${3%/}"
    if decider_loopback "$where"; then where+=", on this machine"; fi
    printf '%s\n' \
      "${p}The embedding service ($where) gets, in POST /v1/embeddings, with Postgres 17:" \
      "${p}- the same current failure, up to 4000 characters, and the failure (up to" \
      "${p}  1500 characters) and fix note of each resolved lesson." \
      "${p}- For office hours and chalk doctor: GET /health or, without it, the word \"health\"."
  fi
  printf '%s\n' "${p}Never the repository's files, the changes themselves, or your Claude credentials."
}

# decider_untrusted_hint URL... -> REPLY: why nothing is sent to the URLs,
# and what to run to send.
decider_untrusted_hint() {
  local url verb=is
  (( $# == 1 )) || verb=are
  REPLY=""
  for url in "$@"; do REPLY+="${REPLY:+ and }$url"; done
  REPLY+=" $verb on another machine, and nothing is sent there until you acknowledge what it receives (see: chalk decider status); to send it, run:"
  for url in "$@"; do REPLY+=" chalk decider trust $url;"; done
  REPLY="${REPLY%;}"
}

# decider_gate: before a run or office hours asks anything. When
# CHALK_DECIDER is not off and the decider or chalk-embed is on another
# machine that was not acknowledged, turns the decider off for this
# process and says so, once, with what it would receive. With an
# acknowledged one, says where questions go.
decider_gate() {
  local -a unacked=()
  [[ ${CHALK_DECIDER:-off} != off ]] || return 0
  decider_unacknowledged unacked
  if (( ${#unacked[@]} )); then
    CHALK_DECIDER=off
    if [[ ! -v DECIDER_WARNED[untrusted] ]]; then
      decider_warn_once untrusted "continuing with the decider off: ${| decider_untrusted_hint "${unacked[@]}"; }"
      decider_disclosure "  " "$CHALK_DECIDER_URL" "$CHALK_EMBED_URL" >&2
    fi
    return 0
  fi
  if ! decider_loopback "$CHALK_DECIDER_URL" && [[ ! -v DECIDER_WARNED[hosted] ]]; then
    DECIDER_WARNED[hosted]=1
    info "decider: questions go to ${CHALK_DECIDER_URL%/} (acknowledged; what it gets: chalk decider status)"
  fi
}

# decider_trust URL: shows what URL would receive, then records it as
# acknowledged.
decider_trust() {
  local url="${1:-}" file decider="" embed="" line
  [[ -n $url ]] || die "usage: chalk decider trust URL"
  [[ $url =~ ^https?://[^[:space:]]+$ ]] || die "not an http:// or https:// URL: $url"
  url="${url%%+(/)}"
  if decider_loopback "$url"; then
    info "$url is on this machine: nothing to acknowledge"
    return 0
  fi
  # What it gets as the configured decider, chalk-embed or, for neither, either.
  [[ $url != "${CHALK_DECIDER_URL%/}" ]] || decider="$url"
  [[ $url != "${CHALK_EMBED_URL%/}" ]] || embed="$url"
  if [[ -z $decider$embed ]]; then decider="$url" embed="$url"; fi
  decider_disclosure "" "$decider" "$embed"
  file="${| decider_trust_file; }"
  mkdir -p "${file%/*}"
  if [[ -f $file ]]; then
    while IFS= read -r line; do
      if [[ $line == "$url" ]]; then info "already acknowledged: $url"; return 0; fi
    done < "$file"
  fi
  printf '%s\n' "$url" >> "$file"
  info "acknowledged: runs with CHALK_DECIDER shadow or on now send the above to $url (to stop: chalk decider untrust $url)"
}

# decider_untrust URL: takes back `chalk decider trust URL`.
decider_untrust() {
  local url="${1:-}" file line found=0
  local -a keep=()
  [[ -n $url ]] || die "usage: chalk decider untrust URL"
  url="${url%%+(/)}"
  file="${| decider_trust_file; }"
  if [[ -f $file ]]; then
    while IFS= read -r line; do
      if [[ $line == "$url" ]]; then found=1; else keep+=("$line"); fi
    done < "$file"
  fi
  if (( ! found )); then info "$url was not acknowledged"; return 0; fi
  if (( ${#keep[@]} )); then printf '%s\n' "${keep[@]}" > "$file"; else rm -f "$file"; fi
  info "nothing more is sent to $url; runs go on with the decider off while it is configured"
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

# decider_hold -> REPLY: why CHALK_DECIDER=on may not act yet, and so is
# held to shadow; empty when it may act. Two reasons, in this order: the
# local service measured slower than DECIDER_SLOW_MS on this machine
# (maintainer's decision on #34), or the decider is not calibrated
# (decider_calibration, #36).
decider_hold() {
  local slow
  local -A cal
  REPLY=""
  slow="${| decider_slow; }"
  if [[ -n $slow ]]; then
    REPLY="the local decider took ${slow} ms per decision when measured (over ${DECIDER_SLOW_MS} ms); it records in shadow mode only on this machine (see: chalk doctor)"
    return 0
  fi
  decider_calibration cal
  [[ ${cal[status]} != calibrated ]] || return 0
  REPLY="CHALK_DECIDER=on records in shadow mode only: ${| decider_calibration_note cal; } (see: chalk doctor)"
}

# decider_mode -> REPLY: the mode decisions are taken in: CHALK_DECIDER,
# except that `on` is held to shadow for as long as decider_hold gives a
# reason. The reason is said once per run, and not after a call that got
# no answer: a decider that is down stays quiet.
decider_mode() {
  local why
  REPLY="${CHALK_DECIDER:-off}"
  [[ $REPLY == on ]] || return 0
  why="${| decider_hold; }"
  [[ -n $why ]] || { REPLY=on; return 0; }
  if [[ -z $DECIDER_ERROR ]]; then decider_warn_once "hold: $why" "$why"; fi
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

# decider_turn STARTED_MS: waits for this call's turn at the local decider,
# from STARTED_MS, for at most DECIDER_QUEUE_MS and never past what the
# loop's budget leaves for the call itself. Holds the lock decider-ask on
# success; the caller releases it.
decider_turn() {
  local started="$1" limit now
  limit=$((DECIDER_LIMIT_MS - DECIDER_SPENT_MS - DECIDER_MIN_CALL_MS))
  (( limit < DECIDER_QUEUE_MS )) || limit=$DECIDER_QUEUE_MS
  until chalk_lock decider-ask 0; do
    now="${| decider_now_ms; }"
    (( now - started < limit )) || return 1
    sleep "$DECIDER_QUEUE_POLL"
  done
}

# decider_post URL OUT [TOKEN_VAR]: POSTs the JSON on stdin to URL, within
# what is left of the loop's budget, and writes the response body to OUT.
# Sets DECIDER_ERROR (empty when the service answered 200) and DECIDER_MS,
# and adds DECIDER_MS to the budget spent. Returns non-zero on no answer.
# TOKEN_VAR names a variable holding a bearer token; curl reads the header
# from a file descriptor, so the token never appears in its arguments.
# A call to the local decider first waits its turn (decider_turn); its wait
# is part of DECIDER_MS, and a turn that does not come is the error busy.
decider_post() {
  local url="$1" out="$2" token="" left max started now code status=0 hfd="" turn=0
  local -a auth=()
  DECIDER_ERROR="" DECIDER_MS=0
  if [[ -n ${3:-} ]]; then token="${!3-}"; fi
  # Nothing goes to another machine before the user acknowledged it.
  if ! decider_acknowledged "$url"; then
    DECIDER_ERROR=untrusted
    decider_warn_once untrusted "${| decider_untrusted_hint "${url%/v1/*}"; }"
    return 1
  fi
  left=$((DECIDER_LIMIT_MS - DECIDER_SPENT_MS))
  if (( left < DECIDER_MIN_CALL_MS )); then
    DECIDER_ERROR=budget
    return 1
  fi
  # chalk_lock needs the host profile; a run has it by now, and probing it
  # here (docker info) would not be waiting for a turn.
  if [[ $url == "$DECIDER_LOCAL_URL"/* ]]; then system_profile; fi
  started="${| decider_now_ms; }"
  if [[ $url == "$DECIDER_LOCAL_URL"/* ]]; then
    if decider_turn "$started"; then turn=1; fi
    now="${| decider_now_ms; }"
    left=$((left - (now - started)))
    # The turn came too late if the poll that took it overshot the wait.
    if (( ! turn || left < DECIDER_MIN_CALL_MS )); then
      if (( turn )); then chalk_unlock decider-ask; fi
      DECIDER_MS=$((now - started))
      DECIDER_SPENT_MS=$((DECIDER_SPENT_MS + DECIDER_MS))
      DECIDER_ERROR=busy
      return 1
    fi
  fi
  printf -v max '%d.%03d' $((left / 1000)) $((left % 1000))
  if [[ -n $token ]]; then
    exec {hfd}< <(printf 'Authorization: Bearer %s\n' "$token")
    auth=(-H "@/dev/fd/$hfd")
  fi
  code="$(curl -sS -o "$out" -w '%{http_code}' --max-time "$max" \
            -H 'Content-Type: application/json' "${auth[@]}" --data-binary @- "$url" 2>/dev/null)" || status=$?
  if [[ -n $hfd ]]; then exec {hfd}<&-; fi
  if (( turn )); then chalk_unlock decider-ask; fi
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
# as after an idle shutdown in a long run or a crash of strands-decider
# alone, starts it in the background, so that later loops of this run get
# answers. The same gate as at run start.
decider_wake() {
  [[ -z ${| decider_pid decider; } ]] || return 0
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
     --arg model "$DECIDER_ANSWERED_BY" --arg error "$DECIDER_ERROR" --arg url "${| decider_url; }" '
    def num: if . == "" then null else tonumber end;
    {kind: $kind, question: $question, answer: ($answer | if . == "" then null else . end),
     confidence: ($confidence | num), threshold: ($threshold | num), mode: $mode,
     latency_ms: ($ms | num), acted: ($acted == "true"), lesson_id: ($lesson | num),
     model: ($model | if . == "" then null else . end),
     error: ($error | if . == "" then null else . end), url: $url}' >> "$RUN_IO/decisions.jsonl"
}

# decider_flush: stores the current loop's decisions with its call (the
# runs row of RUN_ID and RUN_LOOP). Best effort: a failure loses them.
decider_flush() {
  local file="${RUN_IO:-}/decisions.jsonl"
  [[ -s $file ]] || return 0
  db_record_decisions "$(jq -cs . "$file")" 2>/dev/null || warn "could not record this loop's decider answers"
  rm -f "$file"
}

# ---------------------------------------------------------------- the calibration gate

# "Act at 0.9 or above" is safe only if answers at 0.9 are right about nine
# times in ten, and that is shown per provider, not assumed (#36). A
# provider is a decider URL and the model that answered there, with its
# revision: a new revision is a new provider, and starts again in shadow.
# Under CHALK_DECIDER=on a run stops at its first confident "stuck", so a
# provider is judged by what that answer would have done in each shadow run
# (db_decider_calibration): right when the run went on to be detained with
# no progress after it, a false stop when a later loop progressed. It may
# act once, at the current CHALK_DECIDER_THRESHOLD, at least
# DECIDER_CALIBRATION_RUNS runs are judged and at least
# DECIDER_CALIBRATION_PERCENT of them were right.
#
# 90%: what a 0.9 threshold promises, and the bar the report card set from
# the start ("right about nine times in ten"). 20 runs: the sample the
# verdict ledger asks before CHALK_FP_RULES=on (docs/designs/
# system-1-decider.md), so both ways of stopping a run early clear the same
# evidence; at 20 it allows two false stops, and a false stop costs a
# detention an engineer resolves, never a wrong change. Counting runs, not
# answers, keeps one run that is asked loop after loop from filling the
# sample alone. These are constants, not settings: a repository's config
# cannot lower the bar for acting on the decider.
#
# The gate holds `on` as a whole, the lesson rerank too: the stuck question
# is the one whose answers the runs later prove right or wrong.
DECIDER_CALIBRATION_RUNS=20
DECIDER_CALIBRATION_PERCENT=90

# What db_decider_calibration gave, read once per process: the gate is
# judged once per run. DECIDER_CALIBRATION_READ is 1 once it was asked;
# DECIDER_CALIBRATION_DATA stays empty when the database did not answer.
DECIDER_CALIBRATION_READ=0
DECIDER_CALIBRATION_DATA=""

# decider_url -> REPLY: CHALK_DECIDER_URL as decisions record it: without a
# trailing slash or any user:password@.
decider_url() {
  REPLY="${CHALK_DECIDER_URL%/}"
  if [[ $REPLY =~ ^([a-z]+://)[^/@]*@(.*)$ ]]; then REPLY="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; fi
}

# decider_calibration_data -> REPLY: db_decider_calibration's JSON, read
# once per process; empty when the database could not give it.
decider_calibration_data() {
  if (( ! DECIDER_CALIBRATION_READ )); then
    DECIDER_CALIBRATION_READ=1
    DECIDER_CALIBRATION_DATA="$(db_decider_calibration 2>/dev/null || true)"
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$DECIDER_CALIBRATION_DATA" || DECIDER_CALIBRATION_DATA=""
  fi
  REPLY="$DECIDER_CALIBRATION_DATA"
}

# decider_calibration_judge DATA -> REPLY: every provider of DATA (as
# db_decider_calibration prints it) judged at CHALK_DECIDER_THRESHOLD, as
# one JSON array: url, model and last; at the threshold, judged, correct
# and waiting; calibrated; and suggested, the lowest threshold at which it
# would be calibrated, or null. The one place the gate is decided, for
# runs, doctor, status and the report card alike.
decider_calibration_judge() {
  REPLY="$(jq -c --arg t "$CHALK_DECIDER_THRESHOLD" --argjson runs "$DECIDER_CALIBRATION_RUNS" \
             --argjson pct "$DECIDER_CALIBRATION_PERCENT" '
    def passes: .judged >= $runs and .correct * 100 >= $pct * .judged;
    ($t | tonumber) as $t
    | [.[] | ((.levels | map(select(.t >= $t)) | first) // {judged: 0, correct: 0, waiting: 0}) as $at
       | {url, model, last, judged: $at.judged, correct: $at.correct, waiting: $at.waiting,
          calibrated: ($at | passes),
          suggested: ([.levels[] | select(passes) | .t] | min)}]' <<<"${1:-[]}" 2>/dev/null || echo '[]')"
}

# decider_provider_model DATA -> REPLY: the model the gate judges the
# decider at CHALK_DECIDER_URL by: the one that just answered; before any
# answer, the latest one recorded there in DATA, and for the local service
# the latest of the revision `chalk decider up` installed, which is new
# when none is recorded.
decider_provider_model() {
  local url rev=""
  local -A got
  REPLY="$DECIDER_ANSWERED_BY"
  [[ -z $REPLY ]] || return 0
  url="${| decider_url; }"
  if decider_local; then
    decider_info got
    if [[ ${got[decider_model]-} == *@* ]]; then
      rev="${got[decider_model]##*@}"
      rev="${rev:0:7}"
    fi
  fi
  REPLY="$(jq -r --arg url "$url" --arg rev "$rev" '
    [.[] | select(.url == $url and ($rev == "" or (.model | endswith("@" + $rev))))][0].model // empty' \
           <<<"${1:-[]}" 2>/dev/null || true)"
  if [[ -z $REPLY && -n $rev ]]; then REPLY="${DECIDER_MODEL#*/}@$rev"; fi
}

# decider_calibration VAR: fills the associative array VAR with the gate's
# judgement of the decider at CHALK_DECIDER_URL: status (calibrated,
# uncalibrated, or unknown when the database did not answer), url, model,
# judged, correct, waiting and suggested (empty when there is none).
decider_calibration() {
  local -n __cal=$1
  local data judged line
  __cal=(["status"]=unknown ["url"]="${| decider_url; }" ["model"]="$DECIDER_ANSWERED_BY"
         ["judged"]=0 ["correct"]=0 ["waiting"]=0 ["suggested"]="")
  data="${| decider_calibration_data; }"
  [[ -n $data ]] || return 0
  __cal["model"]="${| decider_provider_model "$data"; }"
  judged="${| decider_calibration_judge "$data"; }"
  line="$(jq -r --arg url "${__cal[url]}" --arg model "${__cal[model]}" '
    (.[] | select(.url == $url and .model == $model)) // {judged: 0, correct: 0, waiting: 0, calibrated: false}
    | [(if .calibrated then "calibrated" else "uncalibrated" end), .judged, .correct, .waiting,
       (.suggested // "")] | @tsv' <<<"$judged" 2>/dev/null || true)"
  [[ -n $line ]] || line=$'uncalibrated\t0\t0\t0\t'
  IFS=$'\t' read -r '__cal[status]' '__cal[judged]' '__cal[correct]' '__cal[waiting]' '__cal[suggested]' <<<"$line" || true
}

# decider_calibration_note VAR -> REPLY: the judgement in VAR (as
# decider_calibration fills it) in words, for doctor, status and warnings.
decider_calibration_note() {
  local -n __note=$1
  local who="${__note[model]:-the decider}" counts
  local judged="${__note[judged]:-0}" correct="${__note[correct]:-0}" waiting="${__note[waiting]:-0}"
  who+=" at ${__note[url]}"
  if [[ ${__note[status]} == unknown ]]; then
    REPLY="$who: its calibration could not be read from the telemetry database"
    return 0
  fi
  counts="$judged shadow run(s) judged at CHALK_DECIDER_THRESHOLD=$CHALK_DECIDER_THRESHOLD"
  if (( judged > 0 )); then counts+=", $correct right ($((correct * 100 / judged))%)"; fi
  if (( waiting > 0 )); then counts+=", $waiting not settled yet"; fi
  if [[ ${__note[status]} == calibrated ]]; then
    REPLY="$who is calibrated: $counts"
    return 0
  fi
  REPLY="$who is not calibrated yet: $counts; it needs ${DECIDER_CALIBRATION_PERCENT}% right over at least ${DECIDER_CALIBRATION_RUNS}"
  if [[ -n ${__note[suggested]} ]]; then
    REPLY+="; it would be at CHALK_DECIDER_THRESHOLD=${__note[suggested]}"
  fi
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

# The question asked of each candidate lesson, before its failure and fix.
DECIDER_LESSON_QUESTION="Does this past lesson apply to the current failure, so that its fix would help?"

# decider_rerank_questions SHORTLIST CHARS -> REPLY: the rerank's questions,
# as a JSON object of noul questions by key (lesson_ID), one for each lesson
# of SHORTLIST (db_recall_shortlist) that is not an exact match, in no more
# than CHARS characters in all. The lessons share CHARS equally; within its
# share, a lesson's failure and its fix get half each, and what one does
# not need goes to the other. A part that is cut ends in "…".
decider_rerank_questions() {
  REPLY="$(jq -c --argjson chars "$2" --arg ask "$DECIDER_LESSON_QUESTION" '
    def cut($n): if length <= $n then . elif $n < 1 then "" else .[:$n - 1] + "…" end;
    [.[] | select(.exact | not)] as $lessons
    | ($ask + "\nPast failure: ") as $head | "\nIts fix: " as $mid
    | if ($lessons | length) == 0 then {} else
        ($chars / ($lessons | length) | floor) as $each
        | ($each - ($head | length) - ($mid | length)) as $room
        | [$lessons[]
           | ([(.failure | length), ([($room / 2 | floor), $room - (.fix | length)] | max)] | min) as $f
           | {key: "lesson_\(.id)",
              value: {type: "noul",
                      instructions: ($head + (.failure | cut($f)) + $mid + (.fix | cut($room - $f)))}}]
        | from_entries
      end' <<<"$1" 2>/dev/null || true)"
}

# decider_recall VAR REPO MODE QUERY [FINGERPRINT] [FIRST_ERROR]: the recall
# ladder's last two steps, once there are CHALK_DECIDER_MIN_LESSONS resolved
# lessons. Semantic recall (pgvector, Postgres 17 only) adds lessons whose
# failure means the same as QUERY to the lexical ones; the decider then
# reranks up to DECIDER_SHORTLIST of them in one batched request, within
# DECIDER_RERANK_CHARS. Exact matches are not asked about: they come first
# and are always kept. With CHALK_DECIDER=on, fills VAR with up to three
# lessons, as memory_recall prints them, and returns 0. In shadow mode, or
# without an answer, it only records, and returns non-zero: the caller keeps
# the lexical list.
decider_recall() {
  local -n __recalled=$1
  local repo="$2" mode="$3" query="$4" fingerprint="${5:-}" first_error="${6:-}"
  local resolved=0 vector=0 qvec="" shortlist state questions id answer confidence threshold
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
  # The whole request within DECIDER_RERANK_CHARS: the failure first, then
  # the lessons in what is left. Exact matches are not asked about.
  state="Current failure:
${query:0:$DECIDER_RERANK_STATE_CHARS}"
  questions="${| decider_rerank_questions "$shortlist" $((DECIDER_RERANK_CHARS - ${#state})); }"
  [[ -n $questions ]] || return 1

  if ! decider_ask "$state" "$questions" answers; then
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

# How long a health check may take: /health, and the probe after it.
DECIDER_HEALTH_MS=2000

# decider_healthy URL [TOKEN_VAR]: true when the decider at URL answers
# within two seconds: GET /health with status ok or, from a decider with no
# /health (404 or 405: the endpoint is optional), one noul question
# (decider_probe). TOKEN_VAR names the variable holding its bearer token.
decider_healthy() {
  decider_health "$1" "${2:-}" systemone
}

# decider_embed_healthy URL: the same for chalk-embed, whose probe is one
# embedding.
decider_embed_healthy() {
  decider_health "$1" "" embeddings
}

# decider_health URL TOKEN_VAR PROBE: decider_healthy and
# decider_embed_healthy, PROBE being systemone or embeddings. A service on
# another machine that was not acknowledged is not asked.
decider_health() {
  local url="${1%/}" token="" hfd="" status=0 code="" out healthy=1
  local -a auth=()
  decider_acknowledged "$url" || return 1
  if [[ -n $2 ]]; then token="${!2-}"; fi
  if [[ -n $token ]]; then
    exec {hfd}< <(printf 'Authorization: Bearer %s\n' "$token")
    auth=(-H "@/dev/fd/$hfd")
  fi
  out="$(mktemp)"
  code="$(curl -sS -o "$out" -w '%{http_code}' --max-time $((DECIDER_HEALTH_MS / 1000)) "${auth[@]}" \
            "$url/health" 2>/dev/null)" || status=$?
  if [[ -n $hfd ]]; then exec {hfd}<&-; fi
  if (( status == 0 )) && [[ $code == 200 ]] && jq -e '.status == "ok"' "$out" >/dev/null 2>&1; then healthy=0; fi
  rm -f "$out"
  if (( healthy && status == 0 )) && [[ $code == 404 || $code == 405 ]]; then
    if decider_probe "$url" "$2" "$3"; then healthy=0; fi
  fi
  return "$healthy"
}

# decider_probe URL TOKEN_VAR PROBE: true when the service at URL answers
# the smallest real request: for systemone, one noul question about a fixed
# text; for embeddings, one word. It has DECIDER_HEALTH_MS of its own,
# outside any loop's budget, which it leaves as it was; at the local
# decider it waits its turn like any question.
decider_probe() {
  local url="$1" out body path check ok=1
  local spent="$DECIDER_SPENT_MS" limit="$DECIDER_LIMIT_MS" error="$DECIDER_ERROR" ms="$DECIDER_MS"
  if [[ $3 == embeddings ]]; then
    path=/v1/embeddings check='(.data | type) == "array" and (.data | length) == 1'
    body="$(jq -cn --arg model "$DECIDER_EMBED_MODEL" '{model: $model, input: ["health"]}')"
  else
    path=/v1/systemone check='(.answers | type) == "object"'
    body="$(jq -cn --argjson protocol "$DECIDER_PROTOCOL" '{protocol: $protocol, state: "Chalk health check.",
      questions: {health: {type: "noul", instructions: "Is this text a health check?"}}}')"
  fi
  out="$(mktemp)"
  decider_budget_reset "$DECIDER_HEALTH_MS"
  # Not a pipe: decider_post must run in this shell, so the budget is restored.
  if decider_post "$url$path" "$out" "$2" <<<"$body" && jq -e "$check" "$out" >/dev/null 2>&1; then ok=0; fi
  rm -f "$out"
  DECIDER_SPENT_MS="$spent" DECIDER_LIMIT_MS="$limit" DECIDER_ERROR="$error" DECIDER_MS="$ms"
  return "$ok"
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

# True on Apple silicon, where strands-decider runs on the GPU through MPS
# or, from the release after 0.1.0, MLX.
decider_apple_silicon() {
  system_profile
  [[ ${SYS[os]:-} == darwin && ${SYS[arch]:-} == arm64 ]]
}

# decider_serve_device BIN -> REPLY: the --device strands-decider at BIN is
# to serve on. On Apple silicon: mlx when its `serve --help` offers it
# (strands-decider's README: 1.4 to 1.6 times as fast as MPS there, from the
# release after 0.1.0), otherwise mps. Elsewhere empty: it picks CUDA or the
# CPU itself.
decider_serve_device() {
  local help
  REPLY=""
  decider_apple_silicon || return 0
  # Wide and plain, so that its help is not wrapped or coloured.
  help="$(COLUMNS=200 NO_COLOR=1 TERM=dumb "$1" serve --help 2>/dev/null || true)"
  if [[ $help == *mlx* ]]; then REPLY=mlx; else REPLY=mps; fi
}

# The device `chalk decider up` is starting the decider on, while it runs;
# afterwards, launches read serve_device from what it recorded.
DECIDER_SERVE_DEVICE=""

# decider_launch [ONLINE]: starts both service processes in the background,
# each in a process group of its own, with pidfiles, and the idle watcher.
# They never download unless ONLINE is 1 (only `chalk decider up`).
decider_launch() {
  local dir bin offline=1 device
  local -A got
  dir="${| decider_dir; }"
  bin="${| decider_bin; }"
  [[ -n $bin ]] || { warn "strands-decider is not installed; run: chalk decider up"; return 1; }
  [[ ${1:-0} != 1 ]] || offline=0
  decider_info got
  device="${DECIDER_SERVE_DEVICE:-${got[serve_device]-}}"
  [[ $device != auto ]] || device=""
  mkdir -p "$dir"
  rm -f "$dir/decider.pid" "$dir/embed.pid"
  : > "$dir/last-used"
  if (( offline )); then export HF_HUB_OFFLINE=1; fi
  jobs_detach "$dir/decider.log" decider_exec_serve "$bin" "$dir/decider.pid" "$device"
  jobs_detach "$dir/embed.log" uv run --script "$CHALK_HOME/share/decider/chalk-embed.py" \
    --port "$DECIDER_EMBED_PORT" --pidfile "$dir/embed.pid"
  jobs_detach "$dir/watch.log" decider_watch
  if (( offline )); then unset HF_HUB_OFFLINE; fi
}

# decider_exec_serve BIN PIDFILE [DEVICE]: becomes strands-decider serving
# on DECIDER_PORT, on DEVICE when given, after writing its own pid (exec
# keeps the pid).
decider_exec_serve() {
  local -a device=()
  [[ -z ${3:-} ]] || device=(--device "$3")
  printf '%s\n' "$BASHPID" > "$2"
  exec "$1" serve "$DECIDER_MODEL" --host 127.0.0.1 --port "$DECIDER_PORT" "${device[@]}"
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
# It is running while strands-decider is: if that died alone, what is left
# (chalk-embed, the watcher) is stopped and both start again.
decider_start_once() {
  local limit waited=0
  if [[ -n ${| decider_pid decider; } ]]; then decider_touch; return 0; fi
  chalk_lock decider 0 || return 0
  if [[ -n ${| decider_pid decider; } ]]; then
    chalk_unlock decider
    decider_touch
    return 0
  fi
  decider_stop
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
    if decider_embed_healthy "$DECIDER_EMBED_LOCAL_URL"; then
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

# decider_up_wait LIMIT VAR: waits up to LIMIT seconds for both service
# processes to answer /health, and sets VAR to the seconds it waited. False
# when they did not, or one of them died first.
decider_up_wait() {
  local -n __waited=$2
  __waited=0
  until decider_healthy "$DECIDER_LOCAL_URL" && decider_embed_healthy "$DECIDER_EMBED_LOCAL_URL"; do
    __waited=$((__waited + 1))
    if (( __waited >= $1 )) || [[ -z ${| decider_pid decider; } ]]; then return 1; fi
    sleep 1
  done
}

decider_up() {
  local dir bin base base_rev rev embed_line median version device health package
  decider_local ||
    die "CHALK_DECIDER_URL is $CHALK_DECIDER_URL; 'chalk decider up' manages only the local service ($DECIDER_LOCAL_URL)"
  command -v uv >/dev/null 2>&1 ||
    die "the local decider is installed with uv, which is not installed: brew install uv (or see https://docs.astral.sh/uv/)"
  need curl jq
  dir="${| decider_dir; }"
  mkdir -p "$dir"
  chalk_lock decider 300 || die "another chalk is starting the decider; try again in a moment"

  # On Apple silicon with the [mlx] extra, which the release after 0.1.0
  # adds for --device mlx; uv installs the package without it, with a
  # warning, while there is none.
  package="$DECIDER_PACKAGE"
  if decider_apple_silicon; then package+="[mlx]"; fi
  info "installing $package with uv (latest release)"
  uv tool install --upgrade "$package" >"$dir/install.log" 2>&1 ||
    { chalk_unlock decider; die "could not install $package (see $dir/install.log)"; }
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
  DECIDER_SERVE_DEVICE="${| decider_serve_device "$bin"; }"
  info "starting the decider on $DECIDER_LOCAL_URL${DECIDER_SERVE_DEVICE:+ with --device $DECIDER_SERVE_DEVICE}"
  decider_launch || { chalk_unlock decider; die "could not start the decider"; }
  local waited=0 limit up=1
  limit="${| system_timeout 300 "${CHALK_DECIDER_TIMEOUT:-auto}"; }"
  local mlx_failed=0
  decider_up_wait "$limit" waited || up=0
  if (( ! up )) && [[ $DECIDER_SERVE_DEVICE == mlx ]]; then
    mlx_failed=1
    # MLX support that does not work on this machine: MPS does.
    warn "the decider did not start with --device mlx (see $dir/decider.log); starting it with --device mps"
    decider_stop
    DECIDER_SERVE_DEVICE=mps
    decider_launch || { chalk_unlock decider; die "could not start the decider"; }
    up=1
    decider_up_wait "$limit" waited || up=0
  fi
  if (( ! up )); then
    decider_stop
    chalk_unlock decider
    die "the decider did not become healthy in ${waited}s (see $dir/decider.log and $dir/embed.log)"
  fi
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
    printf 'serve_device=%s\n' "${DECIDER_SERVE_DEVICE:-auto}"
    printf 'mlx_failed=%s\n' "$mlx_failed"
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

# decider_device_note -> REPLY: the --device `chalk decider up` chose for
# the local decider, and why; empty when it recorded none (an install by
# an older Chalk).
decider_device_note() {
  local -A got
  decider_info got
  REPLY=""
  case "${got[serve_device]-}" in
    "")   ;;
    auto) REPLY="chosen by strands-decider: CUDA or the CPU" ;;
    mlx)  REPLY="mlx (Apple silicon)" ;;
    mps)  if [[ ${got[mlx_failed]-} == 1 ]]; then
            REPLY="mps (Apple silicon): --device mlx did not start"
          else
            REPLY="mps (Apple silicon): ${got[package]:-strands-decider} has no --device mlx; chalk decider up picks it once it does"
          fi ;;
    *)    REPLY="${got[serve_device]}" ;;
  esac
}

# decider_status_hosted: for `chalk decider status`, when the decider or
# chalk-embed is on another machine: whether it was acknowledged, and
# exactly what it receives.
decider_status_hosted() {
  local url
  local -a hosted=() unacked=()
  for url in "${CHALK_DECIDER_URL%/}" "${CHALK_EMBED_URL%/}"; do
    decider_loopback "$url" || hosted+=("$url")
  done
  (( ${#hosted[@]} )) || return 0
  decider_unacknowledged unacked
  for url in "${hosted[@]}"; do
    if [[ " ${unacked[*]} " == *" $url "* ]]; then
      info "$url: on another machine and not acknowledged, so nothing is sent to it, and runs go on with the decider off; to send it what is below, run: chalk decider trust $url"
    else
      info "$url: on another machine, acknowledged with chalk decider trust (to stop: chalk decider untrust $url)"
    fi
  done
  decider_disclosure "  " "$CHALK_DECIDER_URL" "$CHALK_EMBED_URL"
}

decider_status() {
  local -A got cal
  local mode slow note
  mode="${| decider_mode; }"
  info "CHALK_DECIDER=$CHALK_DECIDER (acting as $mode), CHALK_DECIDER_URL=$CHALK_DECIDER_URL"
  decider_calibration cal
  info "calibration: ${| decider_calibration_note cal; }"
  decider_status_hosted
  if ! decider_local; then
    if ! decider_acknowledged "$CHALK_DECIDER_URL"; then :
    elif decider_healthy "$CHALK_DECIDER_URL" CHALK_DECIDER_TOKEN; then info "decider: healthy"
    else info "decider: not answering at ${CHALK_DECIDER_URL%/} (GET /health, or one question without it)"
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
  note="${| decider_device_note; }"
  if [[ -n $note ]]; then info "  device:  $note"; fi
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
    trust)  decider_trust "${2:-}" ;;
    untrust) decider_untrust "${2:-}" ;;
    *)      die "usage: chalk decider up|down|status|trust URL|untrust URL" ;;
  esac
}
