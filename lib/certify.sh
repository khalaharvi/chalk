# Certified stops (docs/designs/certified-stops.md). A decision that can
# only end a run earlier, never extend it, is judged exactly by the shadow
# runs it would have stopped: what came after the loop it fired on is what
# it would have saved, or the progress it would have cost. Both kinds of
# early stop, the stuck-loop verdicts (CHALK_FP_RULES=on) and the decider's
# confident "stuck" (CHALK_DECIDER=on), may act only once that evidence
# clears one bar, per stratum:
#
#   the latest complete block of CERTIFY_BLOCK judged runs had at most
#   CERTIFY_MAX_WRONG wrongful stops
#
# that is, 95% sure it is right at least nine times in ten (exact one-sided
# Clopper-Pearson: 45/46 gives 0.9010; 44/46 and 44/45 fall short). A run
# counts once, by its first firing. Blocks are fixed and taken in the order
# runs were judged, so each is one fixed-size test, not a bound re-checked
# after every judgment; a later block that fails demotes. A block still
# filling that already has more wrongful stops than it may can no longer
# pass, so it demotes at once: that only settles its test early. These are
# constants: a repository's config cannot lower the bar.
CERTIFY_BLOCK=46
CERTIFY_MAX_WRONG=1
CERTIFY_TARGET_PERCENT=90
CERTIFY_ALPHA=0.05

# The verdicts that stop a run (fp_stops), and the pseudo-verdict for the
# first of any of them: the policy CHALK_FP_RULES=on deploys once all are
# certified.
CERTIFY_VERDICTS=(deja_vu repeat no_change)
CERTIFY_ANY=any

# jq definitions shared by the gate, chalk certify, doctor and the report
# card. cp_lower(x; n; a) is the exact one-sided (1 - a) lower bound on a
# rate after x successes in n, by bisection on the binomial tail;
# cp_upper(w; n; a) the upper bound after w events. hoeffding_lower(mean;
# range; n; a) bounds the mean of n values in [0, range]. certified($max)
# reads a stratum's latest complete block, and the one still filling.
# shellcheck disable=SC2016
CERTIFY_JQ='
def cp_tail($x; $n; $p):
  if $p <= 0 then (if $x <= 0 then 1 else 0 end)
  elif $p >= 1 then 1
  else [range($x; $n + 1) as $k
        | ((($n + 1) | lgamma) - (($k + 1) | lgamma) - (($n - $k + 1) | lgamma)
           + $k * ($p | log) + ($n - $k) * ((1 - $p) | log))
        | exp] | add // 0
  end;
def cp_lower($x; $n; $a):
  if $x <= 0 or $n <= 0 then 0
  else reduce range(60) as $i ([0, 1];
         ((.[0] + .[1]) / 2) as $m
         | if cp_tail($x; $n; $m) < $a then [$m, .[1]] else [.[0], $m] end) | .[0]
  end;
def cp_upper($w; $n; $a): if $n <= 0 then 1 else 1 - cp_lower($n - $w; $n; $a) end;
def hoeffding_lower($mean; $range; $n; $a):
  if $n <= 0 then 0 else $mean - $range * ((1 / $a | log) / (2 * $n) | sqrt) end;
def certified($max): (.blocks // 0) > 0 and (.block_wrong // 0) <= $max and (.open_wrong // 0) <= $max;
def round4: . * 10000 | round / 10000;
'

# What db_certify_verdicts gave, read once per process, as the decider's
# calibration is: CERTIFY_READ is 1 once it was asked; CERTIFY_DATA stays
# empty when the database did not answer.
CERTIFY_READ=0
CERTIFY_DATA=""
# Warnings given, by name, so each is given once per process.
declare -gA CERTIFY_WARNED=()

# certify_jq [JQ OPTIONS...] FILTER: runs jq with CERTIFY_JQ's definitions
# and the gate's constants ($block, $max_wrong, $alpha) in scope. Reads
# stdin unless -n is among the options.
certify_jq() {
  local filter="${*: -1}"
  jq --argjson block "$CERTIFY_BLOCK" --argjson max_wrong "$CERTIFY_MAX_WRONG" \
     --argjson alpha "$CERTIFY_ALPHA" "${@:1:$#-1}" "$CERTIFY_JQ $filter"
}

# certify_lower X N -> REPLY: the one-sided 95% lower bound on a rate after
# X successes in N, to four places; empty when jq cannot compute it.
certify_lower() {
  REPLY="$(certify_jq -rn --argjson x "$1" --argjson n "$2" 'cp_lower($x; $n; $alpha) | round4' 2>/dev/null || true)"
}

# certify_upper W N -> REPLY: the one-sided 95% upper bound on a rate after
# W events in N, to four places; empty when jq cannot compute it.
certify_upper() {
  REPLY="$(certify_jq -rn --argjson w "$1" --argjson n "$2" 'cp_upper($w; $n; $alpha) | round4' 2>/dev/null || true)"
}

# certify_warn_once NAME MESSAGE: warns, at most once per process for NAME.
certify_warn_once() {
  [[ ! -v CERTIFY_WARNED[$1] ]] || return 0
  CERTIFY_WARNED[$1]=1
  warn "$2"
}

# certify_data -> REPLY: db_certify_verdicts's JSON, read once per process;
# empty when the database could not give it.
certify_data() {
  if (( ! CERTIFY_READ )); then
    CERTIFY_READ=1
    CERTIFY_DATA="$(db_certify_verdicts 2>/dev/null || true)"
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$CERTIFY_DATA" || CERTIFY_DATA=""
  fi
  REPLY="$CERTIFY_DATA"
}

# certify_verdict VERDICT MODEL VAR: fills the associative array VAR with
# the gate's judgement of VERDICT for runs of MODEL: status (certified,
# uncertified, or unknown when the database did not answer), verdict,
# model, judged, correct, wrong, waiting, blocks, block_wrong (in the
# latest complete block) and open_wrong (in the block still filling).
certify_verdict() {
  local -n __cv=$3
  local data line
  __cv=(["status"]=unknown ["verdict"]="$1" ["model"]="$2" ["judged"]=0 ["correct"]=0
        ["wrong"]=0 ["waiting"]=0 ["blocks"]=0 ["block_wrong"]=0 ["open_wrong"]=0)
  data="${| certify_data; }"
  [[ -n $data ]] || return 0
  line="$(certify_jq -r --arg verdict "$1" --arg model "$2" '
    (.[] | select(.verdict == $verdict and .model == $model))
      // {judged: 0, correct: 0, wrong: 0, waiting: 0, blocks: 0, block_wrong: 0}
    | [(if certified($max_wrong) then "certified" else "uncertified" end),
       .judged, .correct, .wrong, .waiting, .blocks, .block_wrong, (.open_wrong // 0)] | map(tostring) | @tsv' \
    <<<"$data" 2>/dev/null || true)"
  [[ -n $line ]] || line=$'uncertified\t0\t0\t0\t0\t0\t0\t0'
  IFS=$'\t' read -r '__cv[status]' '__cv[judged]' '__cv[correct]' '__cv[wrong]' '__cv[waiting]' \
    '__cv[blocks]' '__cv[block_wrong]' '__cv[open_wrong]' <<<"$line" || true
}

# certify_rule -> REPLY: the bar, in words.
certify_rule() {
  REPLY="it needs a block of $CERTIFY_BLOCK judged runs with at most $CERTIFY_MAX_WRONG wrongful stop(s), which shows it right at least ${CERTIFY_TARGET_PERCENT}% of the time, 95% sure"
}

# certify_note VAR -> REPLY: the judgement in VAR (as certify_verdict fills
# it) in words, for warnings, doctor and chalk certify.
certify_note() {
  local -n __cn=$1
  local who="${__cn[verdict]} for ${__cn[model]}" counts
  if [[ ${__cn[status]} == unknown ]]; then
    REPLY="$who: its evidence could not be read from the telemetry database"
    return 0
  fi
  counts="${__cn[judged]} shadow run(s) judged, ${__cn[wrong]} wrongful stop(s)"
  if [[ ${__cn[waiting]} != 0 ]]; then counts+=", ${__cn[waiting]} not settled yet"; fi
  if [[ ${__cn[blocks]} != 0 ]]; then
    counts+="; the latest block of $CERTIFY_BLOCK had ${__cn[block_wrong]} wrongful"
  fi
  if (( ${__cn[open_wrong]:-0} > CERTIFY_MAX_WRONG )); then
    counts+="; the block still filling already has ${__cn[open_wrong]}"
  fi
  if [[ ${__cn[status]} == certified ]]; then
    REPLY="$who is certified: $counts"
    return 0
  fi
  REPLY="$who is not certified: $counts; ${| certify_rule; }"
}

# certify_holdout_percent -> REPLY: CHALK_HOLDOUT as a whole percentage.
certify_holdout_percent() {
  local frac
  REPLY=0
  if [[ ${CHALK_HOLDOUT:-0} =~ ^([01])(\.([0-9]{1,2}))?$ ]]; then
    frac="${BASH_REMATCH[3]}00"
    REPLY=$((10#${BASH_REMATCH[1]} * 100 + 10#${frac:0:2}))
  fi
}

# certify_holdout -> REPLY: 1 for a run that keeps every certified stop in
# shadow mode, with probability CHALK_HOLDOUT, so that admitted decisions
# go on being judged; 0 otherwise.
certify_holdout() {
  local pct
  pct="${| certify_holdout_percent; }"
  REPLY=0
  if (( SRANDOM % 100 < pct )); then REPLY=1; fi
}

# certify_judge DATA FALSE_STOP_USD -> REPLY: every stratum of DATA (as
# db_certify_verdicts prints it) judged, as one JSON array: its counts;
# certified; lower, the 95% lower bound on how often it is right over every
# judged run; wrong_upper, the upper bound on its wrongful stops; and, per
# firing, saved_mean, the spend it saved on correct stops, saved_lower, a
# Hoeffding lower bound on that mean, and net, saved_lower less
# FALSE_STOP_USD for each wrongful stop at wrong_upper. A correct stop saves
# at most CHALK_MAX_RETRIES loops at CHALK_BUDGET_USD, which bounds the
# range (or the largest saving seen, when a call spent over its cap). The
# two bounds take half the error each, so net holds 95% sure. The one
# place verdicts are judged, for runs, doctor, chalk certify and the report
# card alike.
certify_judge() {
  local range
  range="$(awk -v r="${CHALK_MAX_RETRIES:-2}" -v b="${CHALK_BUDGET_USD:-1}" 'BEGIN { print r * b }')"
  REPLY="$(certify_jq -c --argjson range "$range" --argjson usd "${2:-5}" '
    [.[] | ([.saved_max, $range] | max) as $r
     | (if .judged > 0 then .saved / .judged else 0 end) as $mean
     | . + {certified: certified($max_wrong),
            lower: (cp_lower(.correct; .judged; $alpha) | round4),
            wrong_upper: (cp_upper(.wrong; .judged; $alpha / 2) | round4),
            saved_mean: ($mean | round4),
            saved_lower: ([hoeffding_lower($mean; $r; .judged; $alpha / 2), 0] | max | round4)}
     | . + {net: (.saved_lower - $usd * .wrong_upper | round4)}]' <<<"${1:-[]}" 2>/dev/null || echo '[]')"
}
