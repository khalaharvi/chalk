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
| `on` | Answers at `CHALK_DECIDER_THRESHOLD` (0.9) or above act: a stuck loop is detained at once, and the lessons the decider picks are the ones the loop gets. |

A decider can stop a run early; it can never give a run more loops.
`CHALK_FP_RULES=off` turns the stuck question off too, since it depends on
verdicts; lesson recall still uses the decider.

Start in `shadow`. Turn it `on` once the report card shows that its
confident answers are right about nine times in ten.

## The local reference service

```sh
chalk decider up        # install, download, start, measure
chalk decider status    # what runs, which model revisions, how fast
chalk decider down      # stop it
```

`chalk decider up` needs [uv](https://docs.astral.sh/uv/)
(`brew install uv`). It:

1. installs [strands-decider](https://github.com/strands-labs/strands-decider)
   with `uv tool install`, at its latest release;
2. downloads its model, `StrandsAgents/strands-decider-2B-hobson-v19`, and
   the base model it adapts, `Qwen/Qwen3.5-2B-Base`: about 4.3 GiB the
   first time, all Apache-2.0;
3. prepares `chalk-embed`, a small Chalk-owned service that serves the
   embedding model for semantic recall, `BAAI/bge-small-en-v1.5` (about
   130 MB, MIT);
4. starts both on 127.0.0.1 (ports 8471 and 8472), on Apple's GPU (MPS),
   CUDA or the CPU, whichever the machine has;
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

## A hosted decider

Set these in your environment, not in the repository:

```sh
export CHALK_DECIDER_URL=https://decider.example.com
export CHALK_DECIDER_TOKEN=...        # sent as a bearer token; never logged
```

Chalk does not start or stop a hosted decider; `chalk doctor` checks its
`/health`. The endpoint must speak [the decider protocol](../../decider-protocol.md).
Answers from a hosted model are only as good as its calibration, so start
it in `shadow`.

## Time

All the calls one loop makes to the decider and chalk-embed share a
budget of **2 seconds**. Each call gets what is left; once it is used up,
the remaining calls are skipped. A decider that is down, slow, refuses
the token or answers in a way Chalk cannot read gives **no answer**, and
the loop goes on exactly as with `CHALK_DECIDER=off`. Each such call is
recorded with the reason.

## What the decider receives

- **The stuck question:** the failing test IDs and first error line of the
  previous and the current loop, and a diffstat between their working
  trees (file names with the number of lines changed), capped at about
  1,500 tokens. Never source code, and never the diff itself.
- **The lesson question:** the current failure (its first error and
  failing tests, or before the first loop, the spec), and for each
  candidate lesson its past failure and fix note. Chalk-embed receives the
  same failure text, and the text of each resolved lesson.

With the local service this stays on your machine. A hosted decider
receives the same text at `CHALK_DECIDER_URL`.

## Where answers are kept

Each question asked is a row in the `decisions` table, with the loop's
call, the answer, its confidence, the threshold, the mode, how long it
took, whether it acted, the model and its revision, and why there was no
answer if there was none. See [The database](../../develop/database.md).
