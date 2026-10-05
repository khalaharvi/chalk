# Verdicts and the report card

Chalk records every agent call in a local Postgres database, gives every
loop that made no progress a verdict, and turns both into one HTML page,
the report card, that says what the runs cost and what to change.

## The report card

```sh
chalk dashboard            # last 30 days; --days N, --output FILE, --no-open
```

`chalk dashboard` builds one self-contained HTML page from the telemetry
database on your machine and opens it. Nothing is served and nothing is
sent anywhere. The page is written to
`~/.local/state/chalk/dashboard.html` unless you pass `--output`.

![The report card, light theme, with sample data: $0.57 per finished checkpoint, the totals, two notes for next term and spend by kind of call.](../../assets/report-card-light.png#only-light)
![The report card, dark theme, with sample data: $0.57 per finished checkpoint, the totals, two notes for next term and spend by kind of call.](../../assets/report-card-dark.png#only-dark)

*Sample data, not from a real run.*

It shows:

- **The grade:** cost per finished checkpoint, counting every call Chalk
  made, with total spend, pull or merge requests opened and detentions;
- the share of loop spend that made no progress;
- **Notes for next term:** plain rules over the numbers, such as a spend
  cap far above what loops use, a review that never fails anything, or
  retries that do better with lessons than without. They appear once
  there are about twenty loops;
- spend by kind of call (first attempts, retries, review fixes, reviews,
  spec checks, lesson distillation) and by day;
- loop cost against `CHALK_BUDGET_USD`;
- results by prompt set and by model, so a prompt or model change shows up
  as a before and after;
- whether the spec check and final review are earning their cost;
- **Would stopping early have paid?**, the verdict ledger (below);
- **Is the decider worth asking?**, once a [decider](#the-decider) has
  been asked anything, or while one is wanted (`CHALK_DECIDER` is not
  `off`) but was asked nothing, to say why;
- **Which tests keep failing?**: the tests that failed in the most loops,
  up to ten per repository, with how many loops and tickets they failed
  in. A test that fails loop after loop, or on more than one ticket, is
  worth a closer look or an office-hours note;
- the fifty most recently active tickets and their state.

### Sharing it

```sh
chalk share                # last 30 days; --days N, --output FILE, --json
```

`chalk share` prints an anonymised summary of the same numbers as JSON:
counts, rates, rounded costs, model families and the size of your machine.
It holds no repository, path, ticket, test name, error or note, and it
sends nothing. If you choose to post it in the
[Report cards](https://github.com/khalaharvi/chalk/discussions/new?category=report-cards)
discussions, it helps tune Chalk's defaults. [Privacy](../../privacy.md#chalk-share)
lists every field and why it is safe.

## Verdicts

After the rubric runs, Chalk reduces each loop to its **fingerprint**:

- **T**, the failing tests: sorted, unique test IDs, from the test
  report when `CHALK_TEST_REPORT` names one (JUnit XML, `go test -json` or
  `jest --json`), otherwise from pytest, go, cargo or jest output;
  `UNKNOWN` when neither names any;
- **E**, the first error line, normalized so that timestamps, addresses,
  temporary paths, line numbers and durations do not tell two runs of the
  same failure apart;
- **D**, the working tree's git tree ID.

A loop that made no progress is compared with the last loop of the
current streak without progress, and gets a **verdict**:

| Verdict | Meaning | Stops a run with `CHALK_FP_RULES=on` |
| :-- | :-- | :-- |
| `first` | The first loop of a streak without progress | |
| `deja_vu` | The same failure as an open detention on another ticket | yes |
| `repeat` | The same failure on the same tree as the loop before | yes |
| `no_change` | The agent changed nothing | yes |
| `improving` | Fewer tests fail than in the loop before | |
| `spinning` | The same failure, on a different tree | |
| `other` | None of the above | |
| `blocked`, `agent_error` | The agent reported a blocker, or the call failed | |

`CHALK_FP_RULES` decides what happens with them:

- **`shadow`** (the default) records the verdicts and changes nothing.
  This is shadow mode: Chalk measures what the rules would have done
  before they are allowed to act.
- **`on`** also detains a run at once on a stopping verdict, with the
  verdict as the reason.
- **`off`** computes nothing.

### The verdict ledger

The report card's "Would stopping early have paid?" section replays each
detained run as if `CHALK_FP_RULES=on` had been set: the spend after the
first stopping verdict is what it would have saved, and a run that made
progress after that verdict is a **false stop**. It also lists runs that
were detained while still improving.

Only runs in shadow mode count: every call records the `CHALK_FP_RULES`
it ran under, so runs already stopped early under `on` cannot make the
case for turning it on. They are shown apart, as "Runs stopped early under
CHALK_FP_RULES=on".

Only runs with a loop that the stopping rules judge count, too: a loop
whose verdict is not `blocked` or `agent_error`. A run whose every loop
ended in a blocker or an agent error, such as one detained because the
agent reported a blocker, says nothing about `deja_vu`, `repeat` or
`no_change`, and no rule could have saved its spend. Those runs, and
detained runs with no verdicts at all (`CHALK_FP_RULES=off`), are shown
apart, with their counts. The kind of detention does not decide it: a run
detained at the loop limit or by the review counts when its loops were
judged.

When there are at least twenty detained runs with verdicts, stopping early
would have saved at least a fifth of their spend without progress, and
there was at most one false stop, the notes recommend turning the rules
on.

**When it counts no run.** A stopping verdict judges only a loop that
failed its rubric or passed without ticking a checkpoint. When no
detained run had one, the ledger says so with the numbers instead of
showing zeros, for example "No loop failed its rubric or passed without
ticking a checkpoint in the last 30 days (85 loop(s)), so no verdict
could stop a run; agents that could not progress reported a blocker
instead (4 run(s))". Runs detained for a blocker are still counted
apart below it.

### The decider

A loop the rules call `spinning` or `other` is the gray zone the
verdicts cannot settle. With `CHALK_DECIDER=shadow` or `on`, a
[decider](../configuring/decider.md) is asked whether such a loop is stuck
on the same root cause as the loop before. In the ledger's runs, the
**Decider** column shows the first loop it judged stuck at or above its
threshold.

The report card's "Is the decider worth asking?" section shows:

- how many questions it was asked, how many it answered, and why the rest
  got no answer (unreachable, still starting, timeout, used-up budget,
  refused token, …). When it was asked nothing, it says why instead,
  as `chalk doctor` does: no loop failed its rubric, none of those that
  did was `spinning` or `other`, or there are too few resolved lessons for
  lesson rerank (see [When nothing is asked](../configuring/decider.md#when-nothing-is-asked));
- its median time per answer, and the model and revision that answered;
- how many answers acted (`on` only);
- for shadow runs: how many a confident "stuck" would have stopped, what
  that would have saved, and the **false stops**, runs that still made
  progress after it;
- **Were confident answers right?**: shadow-mode "stuck" answers by
  confidence (0.5 to 0.7, 0.7 to 0.9, 0.9 to 1), and how many matched what
  the run did next. A "yes" is right when no later loop progressed, a
  "no" when one did. Answers at 0.9 or more should be right about nine
  times in ten before `CHALK_DECIDER=on` is worth it.
- **May it act yet?**: the [calibration gate](../configuring/decider.md#the-calibration-gate)
  for each decider, by its URL and model revision: whether it is
  calibrated at `CHALK_DECIDER_THRESHOLD`, how many shadow runs it is
  judged by out of the 20 it needs, how many of those it was right about,
  how many are not settled yet, and the **suggested threshold**, the
  lowest at which it would be calibrated. Over every run recorded, not
  only the report card's period. When the suggested threshold is below
  yours, lowering `CHALK_DECIDER_THRESHOLD` to it lets `on` act.

### Better fingerprints

- **`CHALK_TEST_REPORT`**: have the rubric write a test report and set
  this to its path in the repository. Three formats are read, told apart
  by their content: JUnit XML (`pytest --junitxml=report.xml`),
  `go test -json` output and a jest report
  (`jest --json --outputFile=report.json`). The rubric must still print
  its failures, since a retry is told the last lines of its output:
  `go test -json` prints only JSON, so for Go use
  `go test -json ./... > report.json || { go test ./...; exit 1; }`,
  which runs the tests again for readable output when they fail. A rubric
  that prints nothing at all gets the failing tests and first error in
  its retry, as with `CHALK_FP_FEEDBACK=true`. The failing tests are
  then read from the report instead of from the output, and are stored
  with the loop for "Which tests keep failing?". The notes point this out for repositories where most
  failed loops named no tests.
- **`CHALK_FP_FEEDBACK=true`** tells a retry which tests still fail
  ("these 3 tests still fail:", then the list) and the first error,
  normalized, plus the last 20 lines of output, instead of the last 60
  lines. It changes the prompt, so the report card's prompt sets
  compare the two.

## The database

Every agent call is a row in the `runs` table, with its kind, model, prompt
set, cost, duration, tokens, cache use, outcome and fingerprint. Query it
directly:

```sh
chalk db psql
```

The database runs Postgres 17 with pgvector in the `chalk-db` container,
started on the first run (or with `chalk db up`). A machine set up before
that keeps working on Postgres 16, with a warning once a day (`chalk doctor`
shows it every time), until you run
`chalk db upgrade` (no runs may be active). It dumps the old database,
restores it into a new container on a new volume and checks the row
counts; if anything fails, the old container is put back as it was. The
old container and volume are kept until `chalk db upgrade --cleanup`.

See [The database](../../develop/database.md) for the tables.

## OpenTelemetry

To see inside a loop (each API request and tool call), have the agents
export Claude Code's own telemetry. Set this on your machine, not in the
repository:

```sh
export CHALK_OTEL_ENDPOINT=http://localhost:4317   # e.g. local Jaeger
export CHALK_OTEL_SIGNALS=traces                   # any of traces,metrics,logs
export CHALK_OTEL_PROTOCOL=grpc
```

`localhost` is rewritten so the container reaches a collector on your
machine. Each run is tagged `chalk.repo` and `chalk.ticket`. Traces are a
beta feature of Claude Code. Jaeger takes traces only; for metrics and
logs, point the endpoint at a collector that accepts them, and export
`OTEL_EXPORTER_OTLP_HEADERS` if it needs credentials.
