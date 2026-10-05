# The decider

A **decider** (System 1) is a small, fast model that answers bounded
questions so Chalk does not have to ask Claude. Chalk asks it two:

- **Is this loop stuck?** For a failed loop the
  [verdicts](../operating/dashboard.md#verdicts) cannot settle, `spinning`
  or `other`: is the agent stuck on the same root cause as in the loop
  before, so that another attempt would fail the same way?
- **Does this lesson apply?** When choosing which past lessons a loop is
  given, once there are enough of them. See
  [Lesson recall](lesson-memory.md#with-a-decider).

It is optional and off by default. Chalk speaks one protocol to every
decider, [the decider protocol](../../decider-protocol.md), so it can be
the local reference service below or any hosted endpoint that speaks it.

## Modes

`CHALK_DECIDER` in `.chalk/config`:

| Mode | What happens |
| :-- | :-- |
| `off` (default) | Nothing is asked. |
| `shadow` | Every question is asked and its answer recorded, and nothing changes: not the run, not the prompt. The [report card](../operating/dashboard.md#the-decider) shows what the answers would have done. |
| `on` | Answers at `CHALK_DECIDER_THRESHOLD` (0.9) or above act: a stuck loop is detained at once, and the lessons the decider picks are the ones the loop gets. Only once the decider is [calibrated](#the-calibration-gate); until then, `on` records as `shadow`. |

A decider can stop a run early; it can never give a run more loops.
`CHALK_FP_RULES=off` turns the stuck question off too, since it depends on
verdicts; lesson recall still uses the decider.

Start in `shadow`. `on` acts only once the decider has shown, in shadow
mode, that its confident answers are right nine times in ten.

## The calibration gate

"Act at 0.9 or above" is safe only if answers at 0.9 are right about nine
times in ten. That has to be shown for each decider, not assumed: every
decider starts held to shadow, and `CHALK_DECIDER=on` acts only once it is
**calibrated**.

- **A decider** here is a URL and the model that answered there, with its
  revision. A new revision of the local model, after `chalk decider up`,
  or a hosted provider's new model, starts again.
- **What it is judged by.** Under `on`, a run stops at its first
  confident "stuck". So each shadow run counts once, by its first "stuck"
  at `CHALK_DECIDER_THRESHOLD` or above: **right** when the run made no
  progress after it and was detained, a **false stop** when a later loop
  made progress. A run that has done neither yet is not settled, and does
  not count.
- **The bar.** At least **20** such runs, and at least **90%** of them
  right. 90% is what a 0.9 threshold promises. 20 runs is the sample the
  [verdict ledger](../operating/dashboard.md#verdicts) asks before
  `CHALK_FP_RULES=on`, so both ways of stopping a run early need the same
  evidence; it allows two false stops, and a false stop costs a detention
  you resolve, never a wrong change. Runs, not answers, are counted, so a
  run asked loop after loop does not fill the sample alone. The bar is
  fixed, not a setting: a repository's config cannot lower it.
- **What it holds.** Until the decider is calibrated, `on` behaves as
  `shadow` for both questions, the stuck question and lesson recall, and
  its answers are recorded as shadow answers, which count towards the
  gate. The run says why once, with the numbers:

  ```text
  warning: CHALK_DECIDER=on records in shadow mode only: strands-decider-2B-hobson-v19@1a2b3c4
  at http://127.0.0.1:8471 is not calibrated yet: 0 shadow run(s) judged at
  CHALK_DECIDER_THRESHOLD=0.9; it needs 90% right over at least 20; it would be at
  CHALK_DECIDER_THRESHOLD=0.7 (see: chalk doctor)
  ```

  `chalk doctor` and `chalk decider status` show the same numbers, and the
  report card's [May it act yet?](../operating/dashboard.md#the-decider)
  shows them for every decider. Without the database, the gate cannot be
  read, and `on` records as `shadow`.
- **The threshold.** The gate is judged at your `CHALK_DECIDER_THRESHOLD`,
  over every answer recorded, so changing the threshold changes which
  answers count. The **suggested threshold** is the lowest at which the
  decider would be calibrated. A decider whose confidence runs low can be
  right far more often than its numbers say: on an M3 Pro the local
  decider's answers ranged from 0.55 to 0.83, so at 0.9 none of them
  count and it can never act; at a lower suggested threshold it can. Lower
  `CHALK_DECIDER_THRESHOLD` to the suggestion only once it appears.

## The local reference service

```sh
chalk decider up        # install, download, start, measure
chalk decider status    # what runs, which model revisions, how fast
chalk decider down      # stop it
```

`chalk decider up` needs [uv](https://docs.astral.sh/uv/)
(`brew install uv`). It:

1. installs [strands-decider](https://github.com/strands-labs/strands-decider)
   with `uv tool install`, at its latest release (on Apple silicon with its
   `[mlx]` extra, which uv skips with a warning while there is none);
2. downloads its model, `StrandsAgents/strands-decider-2B-hobson-v19`, and
   the base model it adapts, `Qwen/Qwen3.5-2B-Base`: about 4.3 GiB the
   first time, all Apache-2.0;
3. prepares `chalk-embed`, a small Chalk-owned service that serves the
   embedding model for semantic recall, `BAAI/bge-small-en-v1.5` (about
   130 MB, MIT);
4. starts both on 127.0.0.1 (ports 8471 and 8472). On Apple silicon the
   decider gets `--device mlx` once the installed strands-decider offers
   it (its README says 1.4 to 1.6 times as fast as MPS; 0.1.0 does not
   have it yet), and `--device mps` until then, or if MLX does not start.
   Elsewhere strands-decider picks CUDA or the CPU itself.
   `chalk decider status` and `chalk doctor` say which, and why;
5. measures the median time per decision over five warm questions;
6. writes embeddings for the resolved lessons that have none.

Chalk tracks the latest release and model revision rather than pinning
them, and records the revisions it resolved: `chalk decider status`,
`chalk doctor` and every recorded answer name them.

**Runs start it, and never download.** When the service is installed and
`CHALK_DECIDER` is not `off`, `chalk run` starts it in the background and
does not wait for it: loops that come before it is ready simply get no
answers. Concurrent runs, such as a fleet, start exactly one copy. A run
never installs or downloads anything.

**It stops when idle.** After `CHALK_DECIDER_IDLE_MINUTES` (30) without a
question it exits and frees its memory, several GB with the models
loaded; the next run starts it again.

**It needs memory beside Docker.** A run starts it only when the host has
at least 6 GiB free beside what Docker takes, unless `CHALK_DECIDER=on`.
Otherwise the run warns once and goes on without it.

**A slow machine records but does not act.** If `chalk decider up`
measures more than 1 second per decision, as on some CPU-only machines,
the decider may run in shadow mode but `CHALK_DECIDER=on` acts as
`shadow` on that machine. `chalk doctor` says so. On an M3 Pro (MPS),
strands-decider 0.1.0 took about 210 ms for a short stuck question and
about 680 ms for the benchmark's, which is near the 1,500-token cap;
starting it took about 10 seconds.

## Several loops at once

A fleet runs several loops, and their questions can arrive together. The
local strands-decider must answer them **one at a time**: asked two things
at once on Apple's GPU, strands-decider 0.1.0 aborts (`A command encoder
is already encoding to this command buffer`), and its engine keeps
per-request state on itself on any device. So the loops take turns:

- A loop's call to the local decider waits for its turn for at most
  **1 second**, and the wait counts against the loop's
  [2-second budget](#time). A loop whose turn does not come in time gets
  no answer, recorded as `busy`, and goes on as with `CHALK_DECIDER=off`.
- chalk-embed answers one embedding at a time too; each takes
  milliseconds.

Measured on an M3 Pro (18 GB, MPS) with four loops asking at once, each
with its own 2-second budget, over five rounds:

| Stuck question | One loop alone | Four loops at once |
| :-- | :-- | :-- |
| Short (a failing test and its error) | 0.26–0.28 s | all four answered, in 0.35–1.0 s |
| At the 1,500-token cap | 0.71–0.74 s | two answered, in 0.87–1.0 s and 1.5–1.7 s; two `busy` after 1.2–1.3 s |
| Either, without turns | | the decider aborted on the first round, with two loops or four |

Times are as a loop sees them, from asking to having read the answer.
chalk-embed, asked four at a time 40 times: every one answered, in 81 ms
on average and 0.63 s at most. Without turns it aborted on the first
round.

So four concurrent loops are fine with ordinary questions; with large
ones, some loops go without an answer that loop. A hosted decider is not
made to take turns: concurrency is its own concern.

## A hosted decider

Set these in your environment, not in the repository:

```sh
export CHALK_DECIDER_URL=https://decider.example.com
export CHALK_DECIDER_TOKEN=...        # sent as a bearer token; never logged
```

Then acknowledge it, once on each machine:

```sh
chalk decider trust https://decider.example.com
```

**A hosted decider gets nothing until you do.** Any address whose host is
not this machine (127.0.0.0/8, `localhost` or `::1`) is sent nothing, not
even a health check. `chalk decider trust URL` prints exactly what it
would receive ([below](#what-the-decider-receives)) and records the URL
(less any trailing slash) under `~/.local/state/chalk/decider/trusted`. Until
then:

- a run goes on with the decider off, and says so once, with the same
  list and the command to run;
- `chalk doctor` and `chalk decider status` say it is not acknowledged,
  and list what it would receive.

Pointing `CHALK_DECIDER_URL` at another address needs a new
acknowledgement. `chalk decider untrust URL` takes one back. A
`CHALK_EMBED_URL` on another machine needs the same.

Why a command rather than a setting: the acknowledgement is given where
the list of what is sent is printed, it names the one address it allows,
and it lives in your state directory, so neither a repository's
`.chalk/config` nor an environment file that comes with a repository can
give it. In CI, run `chalk decider trust URL` as a setup step.

Chalk does not start or stop a hosted decider; `chalk doctor` checks its
health, through `/health` or, for a decider without it, one question (see
[Health](../../decider-protocol.md#health)). The endpoint must speak
[the decider protocol](../../decider-protocol.md). Answers from a hosted
model are only as good as its calibration, so it too has to pass
[the calibration gate](#the-calibration-gate) before `on` acts.

## Time

All the calls one loop makes to the decider and chalk-embed share a
budget of **2 seconds**. Each call gets what is left; once it is used up,
the remaining calls are skipped. A decider that is down, slow, busy with
other loops, refuses the token or answers in a way Chalk cannot read
gives **no answer**, and the loop goes on exactly as with
`CHALK_DECIDER=off`. Each such call is recorded with the reason.

The lesson question asks about up to 5 lessons in one request of at most
4,000 characters (about 1,300 tokens). The request's time grows with its
size, about 0.9 ms a token on an M3 Pro: a request of 8 lessons at the
earlier limits took 3.7 s, and 2.7 s even held to 3,000 tokens, more than
the whole budget, so it could never be answered. At 4,000 characters the
largest takes about 1.2 s, and leaves time for the stuck question.

## What the decider receives

This is the list `chalk decider trust`, `chalk doctor` and
`chalk decider status` print.

- **The stuck question**, after a failed loop the verdicts call `spinning`
  or `other`: the failing test IDs (up to 20) and the first error line of
  that loop and the one before, and `git diff --stat` between their
  working trees (file paths and the number of lines changed, at most 41
  lines); 6,000 characters at most, about 1,500 tokens. Never the diff
  itself.
- **The lesson question**, once 30 lessons are resolved: the current
  failure, up to 1,500 characters, and for each of up to 5 candidate
  lessons its past failure (first error or signature) and fix note,
  shortened to fit 4,000 characters in all. The current failure is its
  first error and failing test IDs; before the first loop, the start of
  the spec; when the rubric gave neither, the failure reason and the last
  lines of the rubric's output, which can quote source lines from a stack
  trace.
- **chalk-embed**, with Postgres 17: the same current failure, up to
  4,000 characters, and each resolved lesson's failure (up to 1,500
  characters) and fix note.
- `CHALK_DECIDER_TOKEN`, when set, as a bearer token; and for health
  checks, `GET /health` or a fixed question about a fixed text.

Never the repository's files, the changes themselves, or the Claude
credentials. With the local service all of this stays on your machine. A
hosted decider receives the same text at `CHALK_DECIDER_URL`, once you
have [acknowledged it](#a-hosted-decider).

## Where answers are kept

Each question asked is a row in the `decisions` table, with the loop's
call, the answer, its confidence, the threshold, the mode, how long it
took, whether it acted, the model and its revision, and why there was no
answer if there was none. See [The database](../../develop/database.md).
