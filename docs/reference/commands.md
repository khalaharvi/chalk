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

**`chalk certify [--json] [--false-stop-usd N] [--repos PREFIX]`** shows, for every
decision that may stop a run early, what the shadow runs say about it:
each stuck-loop verdict per agent model, and each decider at
`CHALK_DECIDER_THRESHOLD`. It prints the runs judged, the wrongful stops,
the latest block of 46 and whether it may act, a 95% lower bound on how
often it is right, one on what each firing saved, and the net after `N`
dollars (5 by default) per wrongful stop. `--repos` counts the verdicts'
runs only in repositories whose name starts with `PREFIX`, for reading
(the experiments use it); the gate always counts every repository's. Nothing leaves the machine. See
[May the verdicts act yet?](../guide/operating/dashboard.md#may-the-verdicts-act-yet).

**`chalk tune [--json] [--days N] [--checkpoint-usd N] [--success-usd N] [--apply]`**
reads this repository's runs and recommends settings, each on the evidence
its kind of change needs: fewer retries from every run, more retries only
from exploring runs (`CHALK_EXPLORE`), prompts only from an A/B test
(`CHALK_PROMPT_AB`). `--apply` writes what it recommends, for you to
commit. See [Tuning](../guide/operating/tuning.md).

**`chalk share [--days N] [--output FILE] [--json]`** prints an anonymised
summary of the report card for the last N days (30 by default) as JSON:
counts, rates, rounded costs, model families and the size of the machine,
never a repository, path, ticket, test name, error or note. `--output`
also saves it, and `--json` prints only the JSON. It sends nothing; you
decide whether to post it. See [Privacy](../privacy.md#chalk-share).

## Failure lifecycle

**`chalk office-hours -m NOTE [--detach | -d] [--unproved]`**, run from a
`detention/…` branch after you have committed a fix, checks the fix with
the blocker's probe when it has one, records the note, distils it into a
lesson, saves a proved environment probe as a need, moves to a
`tutoring/…` branch and resumes the run. While the probe still fails it
stops, unless `--unproved` resumes anyway with the lesson kept out of
recall. See [Detention and office hours](../guide/running/failures.md).

**`chalk attest key`** prints the line that lets CI trust evidence records
this machine signs, for `.chalk/allowed_signers`. **`chalk attest verify
[--rerun] [--base REF] [TICKET...]`** checks the records a branch added
since its merge base with `REF` (by default `origin/CHALK_BASE_BRANCH`),
or the named tickets' records: signature, subject tree, changed test
files and cost, and with `--rerun` the recorded rubric and the saved needs
in a fresh sandbox. See [Evidence records](attestation.md).

**`chalk needs [--prune]`** checks every need saved in `.chalk/needs`, in
fresh sandboxes, with and without its fix: `holds`, `FAILS`, or
`retired` when it passes without the fix too. `--prune` removes retired
needs from the file. Exits non-zero when a need fails. See
[Saved needs](../guide/running/failures.md#saved-needs).

**`chalk submit`** pushes the current branch and opens the pull or merge
request, for when `CHALK_AUTO_MR` is off. Every checkpoint must be ticked.

**`chalk cleanup [--all]`** stops this repository's runs, removes its
sandboxes and clean worktrees, and deletes merged or pushed branches.
`--all` also removes worktrees with changes and unmerged branches,
detention work included. The telemetry database is never touched.

## Kept for old setups

**`chalk memory`** says that Hindsight lesson memory was removed and how
to remove its container. See [Lesson recall](../guide/configuring/lesson-memory.md#hindsight-was-removed).
