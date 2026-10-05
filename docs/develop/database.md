# The database

One Postgres container per machine, `chalk-db`, holds the telemetry of
every run and the lessons from office hours. The code is in `lib/db.sh`;
the schema is `share/schema.sql`.

## The container

| | |
| :-- | :-- |
| Image | `pgvector/pgvector:pg17` (Postgres 17 with pgvector) |
| Volume | `chalk-db-data-17` |
| Reached by | `docker exec chalk-db psql …` only. No port is published, and the password is random and never leaves the container |
| Started by | The first run, `chalk db up`, or any command that needs it; one `chalk` at a time creates it, under a lock |
| Schema | `share/schema.sql`, applied idempotently every time the database is brought up, so a new column is added in place |

SQL is passed on stdin, with values as `psql -v name=value` and
referenced as `:'name'`, so psql does the quoting (`db_sql`).

## Tables

**`runs`**: one row per agent call.

| Column | Meaning |
| :-- | :-- |
| `repo`, `ticket`, `branch`, `loop` | Where the call happened; `loop` is 0 for calls outside the loop |
| `kind` | `continue`, `retry`, `fix-review`, `spec-check`, `review` or `distill` |
| `agent_status` | Loops: `ok`, `blocked` or the CLI's error. Checks: `pass`, `fail` or `none` |
| `rubric_exit`, `progressed` | The rubric's exit code; whether the call moved the ticket forward |
| `model`, `prompts` | The model that answered; a short hash of the prompt set in use |
| `cost_usd`, `budget_usd`, `duration_s` | What it cost, its cap and how long it took |
| `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `turns` | Usage |
| `denials`, `lessons` | Actions refused by permission checks; lessons given in the prompt |
| `run_id` | One `chalk run`: `TICKET-EPOCHSECONDS` |
| `tests_hash`, `failing`, `first_error`, `tree_id`, `verdict` | The loop's fingerprint and verdict, when `CHALK_FP_RULES` is not `off` |
| `failing_tests` | The failing test IDs behind `tests_hash`, one per line and sorted, the first 100 only; NULL when unknown. The report card's "Which tests keep failing?" reads them |
| `fp_rules` | The `CHALK_FP_RULES` the call ran under (`off`, `shadow` or `on`); NULL for calls recorded before it was, when `shadow` was the default. The verdict ledger counts only shadow-mode runs |

**`events`**: ticket milestones: `detention`, `submitted`,
`spec_blocked`, or `ready` (done and reviewed, but not submitted because
`CHALK_AUTO_MR` is off). The report card shows a ticket's latest one as
its state; `chalk status` does too, unless an agent call came after it.

**`lessons`**: one row per detention. `signature` is the failure;
`resolution` is the engineer's office-hours note, and the record of
human intervention; `lesson` is that note distilled into a rule;
`resolved_by` and `resolved_at` say who and when. `run_id`,
`fingerprint` and `first_error` link the lesson to the run and failure it
came from. `scope` is where the lesson is recalled: `repo` only in its
own repository, `general` anywhere; NULL, for lessons from before scopes
or when nothing was distilled, is recalled anywhere. `memory_synced_at` is no longer written: it belonged to
Hindsight, and is kept so existing databases need no migration.

On Postgres 17, `embedding` (`vector(384)`) holds the lesson's embedding
from chalk-embed (`BAAI/bge-small-en-v1.5`), written when office hours
resolves it. A Postgres 16 database has no such column: the schema adds
it only where pgvector is installed.

The trigram index on `signature`, the index on `(repo, fingerprint)` and
the HNSW index on `embedding` (`vector_cosine_ops`, for `<=>`) serve
[lesson recall](../guide/configuring/lesson-memory.md). The semantic query
sets `hnsw.ef_search` to 100; on a small table the planner reads every
row, which is exact, and the index takes over as the table grows.

**`decisions`**: one row per question put to the
[decider](../guide/configuring/decider.md), or per call that got no
answer.

| Column | Meaning |
| :-- | :-- |
| `call_id` | The `runs` row of the loop the decision was taken in |
| `run_id` | The run |
| `kind` | `stuck` (is the loop stuck?) or `rerank` (does a lesson apply?) |
| `question`, `lesson_id` | What was asked; for `rerank`, about which lesson |
| `answer`, `confidence`, `threshold` | `yes` or `no`, the confidence from 0 to 1, and `CHALK_DECIDER_THRESHOLD` at the time; NULL answer when there was none |
| `error` | Why there was no answer: `unreachable`, `timeout`, `budget`, `busy`, `auth`, `rejected`, `server`, `invalid` or `version` |
| `mode`, `acted` | `shadow` or `on`, as the decision was taken; whether it changed the run |
| `latency_ms`, `model` | How long it took; the model that answered, with the revision `chalk decider up` resolved |

## The report card query

`share/dashboard.sql` returns everything the report card shows as one JSON
document, for a window of days. `lib/dashboard.sh` puts it into
`share/dashboard.html` in place of the `/*CHALK_DATA*/` line, escaping
`</` so no stored text can close the page's script tag. A loop is a call
of kind `continue`, `retry` or `fix-review`, in the query and in
`chalk status` alike.

## Moving to Postgres 17

Installs from before v0.6.0 have `chalk-db` on `postgres:16-alpine` with
the volume `chalk-db-data`. They keep working, with a warning at most
once a day (`chalk doctor` reports it every time), until
`chalk db upgrade`, which:

1. refuses while runs are active;
2. dumps the old database with `pg_dumpall` into
   `~/.local/state/chalk/db-upgrade/`;
3. stops the old container and renames it `chalk-db-16`;
4. creates a new `chalk-db` on Postgres 17 with the new volume, restores
   the dump and compares the row counts of `runs`, `events` and `lessons`;
5. on any failure, removes the new container and puts the old one back as
   it was.

The old container and volume stay until `chalk db upgrade --cleanup`.
CI tests a real upgrade, failures and rollbacks included, with
`scripts/ci-db-upgrade.sh` (see [Testing](testing.md)).

Creating, starting and upgrading the container are serialised by a
machine-wide lock: `flock` where it exists, otherwise a directory made
with `mkdir`, whose holder writes its pid. A lock left by a process that
died is cleared by the next process that wants it, one waiter at a time,
so two cannot both take it.

## The CI audit table

`share/ci-audit-schema.sql` is a separate, optional table in a database
your organisation runs, written by the
[gates](../guide/operating/merge-request-gates.md#the-audit-table), not
by `chalk`.
