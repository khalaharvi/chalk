# chalk share: builds the anonymised report card (lib/share.sh) from
#   $dash    the report card's data (share/dashboard.sql)
#   $extra   the counts share/share.sql adds
#   $host    {chalk, os, arch, cores, ram_mb, docker_cpus, docker_mem_mb}
#   $decider the local decider's model name, without its owner
#   $week    the ISO week the summary was made, such as 2026-W41
#
# It is an allow-list: every field below is built here from a number, a
# count, or a label from a fixed set. Nothing is copied through, so a field
# added to the report card is never shared until it is named here, and a
# string that is not one of the expected labels becomes "other". The
# allow-list and why each field is safe are in PRIVACY.md.

# A count or amount; anything that is not a number reads as 0.
def num: if type == "number" then .
         elif type == "string" and test("^-?[0-9]+(\\.[0-9]+)?$") then tonumber
         else 0 end;

# Two significant figures, so a total cannot be matched to one account's
# bill: 1234.5 -> 1200, 0.4567 -> 0.46.
def sig2: num | if . == 0 then 0 else
    (fabs | log10 | floor) as $e
    | if $e >= 1 then (. / pow(10; $e - 1) | round) * pow(10; $e - 1)
      else (. * pow(10; 1 - $e) | round) / pow(10; 1 - $e) end
  end;

# A rate from 0 to 1, to two places; null when there is nothing to divide.
def rate($n; $d): ($n | num) as $n | ($d | num) as $d
  | if $d > 0 then ($n / $d * 100 | round) / 100 else null end;

# The label when it is one of $allowed, else "other".
def one_of($allowed): if type == "string" and (. as $v | $allowed | any(. == $v)) then . else "other" end;

# A machine size as a range, so that it says what kind of machine it is
# and not which one: 6 -> "4-7", 24 -> "16-31", 200 -> "128+".
def bucket: num | floor
  | if . <= 0 then null elif . < 2 then "1" elif . < 4 then "2-3" elif . < 8 then "4-7"
    elif . < 16 then "8-15" elif . < 32 then "16-31" elif . < 64 then "32-63"
    elif . < 128 then "64-127" else "128+" end;

# A model's family and version, without the date, revision, region, account
# or deployment around it: "claude-opus-4-5-20251101" -> "claude-opus-4-5",
# "us.anthropic.claude-sonnet-4-5-20250929-v1:0" -> "claude-sonnet-4-5". The
# aliases Claude Code takes stay as they are; anything else is "other".
def model_family:
  (if type == "string" then ascii_downcase else "" end) as $m
  | if $m == "" or $m == "default" then "default"
    elif ($m | test("^(opus|sonnet|haiku|fable)(\\[1m\\])?$")) then ($m | sub("\\[1m\\]$"; ""))
    else ([$m | match("claude-(?:(?:opus|sonnet|haiku|fable)-[0-9](?:-[0-9](?![0-9]))?|[0-9](?:-[0-9](?![0-9]))?-(?:opus|sonnet|haiku))(?![0-9a-z])").string]
          | first // "other")
    end;

# The decider's model: the local one by name, without its revision; any
# other (a hosted decider names its own) only as "hosted".
def decider_model: if type == "string" and $decider != "" and (sub("@.*$"; "") | sub("^.*/"; "")) == $decider
                   then $decider else "hosted" end;

# Sums the counts of rows that fall under one label after labelling.
def regroup(key; $fields): group_by(key)
  | map(. as $rows | {key: ($rows[0] | key)}
        + ($fields | map(. as $f | {($f): ([$rows[][$f] | num] | add)}) | add));

def kinds: ["continue", "retry", "fix-review", "spec-check", "review", "distill"];
def verdicts: ["blocked", "agent_error", "first", "deja_vu", "repeat", "no_change",
               "improving", "spinning", "other", "none"];
def counts($allowed): (. // {}) | if type == "object" then . else {} end
  | to_entries | map(.key |= one_of($allowed)) | group_by(.key)
  | map({(.[0].key): (map(.value | num) | add)}) | add // {};

($dash.totals // {}) as $t
| ($dash.review // {}) as $rv
| ($dash.spec // {}) as $sp
| ($dash.lessons // {}) as $ls
| ($dash.budget // {}) as $b
| ($dash.ledger // {}) as $lg
| ($dash.decider // {}) as $dc
| ($extra.events // {}) as $ev
| {
  schema: 1,
  chalk: ($host.chalk | if type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$") then . else "other" end),
  week: ($week | if type == "string" and test("^[0-9]{4}-W[0-9]{2}$") then . else null end),
  days: ($dash.days | num),
  harness: "claude-code",
  host: {
    os: ($host.os | one_of(["darwin", "linux"])),
    arch: ($host.arch | if . == "aarch64" then "arm64" elif . == "amd64" then "x86_64" else . end
           | one_of(["arm64", "x86_64"])),
    cpus: ($host.cores | bucket),
    ram_gib: ($host.ram_mb | num / 1024 | bucket),
    docker_cpus: ($host.docker_cpus | bucket),
    docker_mem_gib: ($host.docker_mem_mb | num / 1024 | bucket)
  },
  totals: {
    calls: ($t.calls | num),
    loops: ($t.loops | num),
    checkpoints: ($t.checkpoints | num),
    tickets: ($t.tickets | num),
    runs: ($extra.runs | num),
    repositories: ($extra.repositories | num),
    submitted: ($dash.submitted | num),
    detentions: ($dash.detentions | num),
    cost_usd: ($t.cost | sig2),
    loop_cost_usd: ($t.loop_cost | sig2),
    wasted_usd: ($t.wasted | sig2),
    input_tokens: ($t.input_tokens | sig2),
    output_tokens: ($t.output_tokens | sig2),
    cache_read_tokens: ($t.cache_read_tokens | sig2),
    cache_write_tokens: ($t.cache_write_tokens | sig2),
    denials: ($t.denials | num)
  },
  rates: {
    cost_per_checkpoint_usd: (if ($t.checkpoints | num) > 0 then ($t.loop_cost | num) / ($t.checkpoints | num) | sig2 else null end),
    loops_per_checkpoint: (if ($t.checkpoints | num) > 0 then ($t.loops | num) / ($t.checkpoints | num) * 100 | round / 100 else null end),
    wasted_share: rate($t.wasted; $t.loop_cost),
    detention_rate: rate($dash.detentions; ($dash.detentions | num) + ($dash.submitted | num)),
    review_pass_rate: rate(($rv.reviews | num) - ($rv.failed | num); $rv.reviews),
    spec_check_pass_rate: rate(($sp.checks | num) - ($sp.failed | num); $sp.checks),
    cache_read_share: rate($t.cache_read_tokens; ($t.input_tokens | num) + ($t.cache_read_tokens | num) + ($t.cache_write_tokens | num))
  },
  by_kind: ([$dash.by_kind // [] | .[] | {kind: (.kind | one_of(kinds)), calls, cost, s: ((.avg_seconds | num) * (.calls | num))}]
            | regroup(.kind; ["calls", "cost", "s"])
            | map({kind: .key, calls, cost_usd: (.cost | sig2),
                   avg_cost_usd: (if .calls > 0 then .cost / .calls | sig2 else 0 end),
                   avg_seconds: (if .calls > 0 then .s / .calls | round else 0 end)})),
  by_model: ([$dash.by_model // [] | .[] | {model: (.model | model_family), loops, checkpoints, cost}]
             | regroup(.model; ["loops", "checkpoints", "cost"])
             | map({model: .key, loops, checkpoints, cost_usd: (.cost | sig2)})),
  budget: {
    cap_usd: ($b.cap | num * 100 | round / 100),
    p50_usd: ($b.p50 | sig2),
    p90_usd: ($b.p90 | sig2),
    max_usd: ($b.max | sig2),
    near_cap: ($b.near_cap | num)
  },
  review: {reviews: ($rv.reviews | num), failed: ($rv.failed | num),
           cost_usd: ($rv.cost | sig2), fix_cost_usd: ($rv.fix_cost | sig2)},
  spec_check: {checks: ($sp.checks | num), failed: ($sp.failed | num), cost_usd: ($sp.cost | sig2)},
  agent: {ok: ($extra.agent.ok | num), blocked: ($extra.agent.blocked | num),
          error: ($extra.agent.error | num), turns: ($extra.agent.turns | num)},
  events: {detention: ($ev.detention | num), submitted: ($ev.submitted | num),
           spec_blocked: ($ev.spec_blocked | num), ready: ($ev.ready | num)},
  detentions_by_reason: ($extra.detentions_by_reason
    | counts(["blocked", "loop_limit", "review", "deja_vu", "repeat", "no_change", "stuck",
              "failed", "agent_error", "no_checkpoint", "other"])),
  verdicts: ($extra.verdicts | counts(verdicts)),
  fp_rules: ($extra.fp_rules | counts(["off", "shadow", "on", "unrecorded", "other"])),
  lessons: {
    retries_with_lessons: ($ls.with | num), passed_with: ($ls.with_passed | num),
    retries_without: ($ls.without | num), passed_without: ($ls.without_passed | num),
    opened: ($extra.lessons.opened | num), resolved: ($extra.lessons.resolved | num),
    distilled: ($extra.lessons.distilled | num), fingerprinted: ($extra.lessons.fingerprinted | num),
    scope_repo: ($extra.lessons.scope_repo | num), scope_general: ($extra.lessons.scope_general | num)
  },
  ledger: {
    detained_runs: ($lg.detained_runs | num),
    no_progress_usd: ($lg.no_progress_cost | sig2),
    saved_usd: ($lg.saved | sig2),
    blocked_only: ($lg.blocked_only | num),
    blocked_only_usd: ($lg.blocked_only_cost | sig2),
    no_verdicts: ($lg.no_verdicts | num),
    false_stops: ($lg.false_stops | num),
    false_stop_usd: ($lg.false_stop_cost | sig2),
    converging: ($lg.converging | num),
    stopped_on: ($lg.stopped_on | num),
    failed_loops: ([$lg.unknown_tests // [] | .[] | .loops | num] | add // 0),
    failed_loops_no_tests: ([$lg.unknown_tests // [] | .[] | .unknown | num] | add // 0),
    by_verdict: ([$lg.by_verdict // [] | .[] | {verdict: (.verdict | one_of(["deja_vu", "repeat", "no_change"])), runs, saved}]
                 | regroup(.verdict; ["runs", "saved"])
                 | map({verdict: .key, runs, saved_usd: (.saved | sig2)}))
  },
  decider: {
    questions: ($dc.questions | num),
    answered: ($dc.answered | num),
    acted: ($dc.acted | num),
    median_ms: ($dc.median_ms | num / 10 | round * 10),
    models: ([$dc.models // [] | .[] | decider_model] | unique),
    modes: ($extra.decider_modes | counts(["shadow", "on", "other"])),
    by_kind: ([$dc.by_kind // [] | .[] | {kind: (.kind | one_of(["stuck", "rerank"])), questions, answered, acted}]
              | regroup(.kind; ["questions", "answered", "acted"])
              | map({kind: .key, questions, answered, acted})),
    errors: ([$dc.errors // [] | .[] | {error: (.error | one_of(["unreachable", "timeout", "budget", "auth",
                                                                "rejected", "server", "invalid", "version"])), calls}]
             | regroup(.error; ["calls"]) | map({(.key): .calls}) | add // {}),
    calibration: ([$dc.calibration // [] | .[]
                   | {low: (.low | num | . * 100 | round / 100), answers: (.answers | num), agreed: (.agreed | num)}]
                  | map(select(.low >= 0 and .low <= 1)) | sort_by(.low)),
    would_stop: ($dc.would_stop | num),
    would_save_usd: ($dc.would_save | sig2),
    false_stops: ($dc.false_stops | num)
  }
}
