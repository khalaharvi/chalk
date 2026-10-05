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
- **Which tests keep failing?**: the tests that failed in the most loops,
  up to ten per repository, with how many loops and tickets they failed
  in. A test that fails loop after loop, or on more than one ticket, is
  worth a closer look or an office-hours note;
- the fifty most recently active tickets and their state.

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
