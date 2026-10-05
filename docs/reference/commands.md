# Commands

`chalk help` prints this summary. It is generated from `bin/chalk` when
the site is built:

<!-- generated: usage -->

`chalk version` prints the version.

## Setup

**`chalk doctor`** checks the tools, credentials, database and sandbox
image, and whether loops on `CHALK_MODEL` get auto mode (asked of the
`claude` CLI in the sandbox image, at no cost), and prints what Chalk
found about the machine. It exits non-zero
when a required check fails. See
[Troubleshooting](../guide/operating/troubleshooting.md#chalk-doctor).

**`chalk init`** adds `.chalk/config`, `.chalk/textbook.md`, `specs/`, a
section in `CLAUDE.md` and the CI gates for the repository's forge. Files
that exist are kept. Its closing message says where to set `CHALK_IMAGE`
and `CHALK_CI_IMAGE` for a stack other than Node 22, as an action when
`CHALK_IMAGE` is already set. See [Getting started](../getting-started.md#set-up-a-repository)
and [Use your own stack](../guide/configuring/your-stack.md).

**`chalk db up | down | psql | upgrade [--cleanup]`** manages the local
telemetry database, the `chalk-db` container. `up` starts it (runs start it
too), `down` stops it and keeps the data, `psql` opens a shell on it,
`upgrade` moves a Postgres 16 database to Postgres 17, and
`upgrade --cleanup` removes the old container and volume afterwards. See
[the database](../guide/operating/dashboard.md#the-database).

**`chalk decider up | down | status`** manages the local
[decider](../guide/configuring/decider.md). `up` installs strands-decider
with `uv`, downloads its models and the embedding model (about 4.3 GiB the
first time), starts both services on 127.0.0.1, measures the time per
decision and records the model revisions it resolved. `down` stops them;
a run starts them again. `status` shows whether they run, the revisions
and the measured time, or, for a hosted `CHALK_DECIDER_URL`, whether it
was acknowledged, what it receives and whether it answers.

**`chalk decider trust URL`** prints exactly what a decider or embedding
service at URL, on another machine, would receive, then records URL as
acknowledged. Until then Chalk sends it nothing, and runs go on with the
decider off. **`chalk decider untrust URL`** takes it back. See
[a hosted decider](../guide/configuring/decider.md#a-hosted-decider).

**`chalk sandbox build`** builds the default sandbox image,
`chalk-sandbox:local`, from `share/sandbox/Dockerfile`. The first run does
this too.

**`chalk prompts [list | eject NAME]`** lists the prompts and which are
overridden in this repository, or copies one into `.chalk/prompts/` to
edit. See [Prompts](../guide/configuring/prompts.md).

## Work

**`chalk new TICKET [title]`** creates branch `chalk/TICKET` in a new
worktree, `../<repo>.worktrees/TICKET`, from `CHALK_BASE_BRANCH`, with a
spec template at `specs/TICKET.md`.

**`chalk check`** runs only the spec check for the current worktree, in a
sandbox, so a spec can be fixed before any loop is paid for.

**`chalk run [--detach | -d]`** runs the loop for the current worktree.
`--detach` runs it in the background and logs to `run.log`. A run that
is detained exits non-zero and prints the reason, a `next:` line saying
what to do, and how to switch to the detention branch. See
[The workflow](../guide/running/workflow.md).

**`chalk fleet EPIC [--plan FILE] [--yes | -y]`** plans an epic as
workstreams, from Jira or from FILE, and launches them in the background,
`CHALK_MAX_PARALLEL` at a time. See [Fleet runs](../guide/running/fleet.md).

**`chalk status`** lists this repository's tickets, most recently active
first: state, loops, cost, office-hours fixes and detention branches. The
state is `running`, or what the ticket was left in:

| State | Meaning |
| :-- | :-- |
| `submitted` | The branch was pushed and the pull or merge request opened |
| `detained` | Waiting in detention for office hours |
| `spec-blocked` | The spec check found checkpoints that are not ready |
| `done` | Every checkpoint is done and reviewed, but nothing was submitted (`CHALK_AUTO_MR=false`, or the push failed); run `chalk submit` |
| `stopped` | The run ended with none of these, as when it was stopped or failed |
| `new` | No agent call was ever made |

**`chalk logs TICKET [-f]`** prints the log of a background run; `-f`
follows it.

**`chalk dashboard [--days N] [--output FILE] [--no-open]`** writes the
report card for the last N days (30 by default) and opens it. See
[Verdicts and the report card](../guide/operating/dashboard.md).

## Failure lifecycle

**`chalk office-hours -m NOTE [--detach | -d]`**, run from a `detention/…`
branch after you have committed a fix, records the note, distils it into a
lesson, moves to a `tutoring/…` branch and resumes the run. See
[Detention and office hours](../guide/running/failures.md).

**`chalk submit`** pushes the current branch and opens the pull or merge
request, for when `CHALK_AUTO_MR` is off. Every checkpoint must be ticked.

**`chalk cleanup [--all]`** stops this repository's runs, removes its
sandboxes and clean worktrees, and deletes merged or pushed branches.
`--all` also removes worktrees with changes and unmerged branches,
detention work included. The telemetry database is never touched.

## Kept for old setups

**`chalk memory`** says that Hindsight lesson memory was removed and how
to remove its container. See [Lesson recall](../guide/configuring/lesson-memory.md#hindsight-was-removed).
