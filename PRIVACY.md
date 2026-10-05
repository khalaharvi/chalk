# Privacy

Chalk collects no usage data. It has no server of its own: no analytics,
no crash reports, no update check. Your code goes to the model provider
you configure, because that is how an agent works on it. Anything else
leaves your machine only when you set it up, or when you choose to send it.

This page lists what Chalk keeps on your machine, every way data can leave
it, and what `chalk share` puts in a report card you may post. It describes
Chalk as of the version it ships with, and is the same text as
[PRIVACY.md](https://github.com/khalaharvi/chalk/blob/main/PRIVACY.md) in the
repository and [Privacy](https://khalaharvi.github.io/chalk/privacy/) on the
docs site.

## What Chalk keeps on your machine

### The database

One Postgres container, `chalk-db`, on the Docker volume
`chalk-db-data-17`. No port is published: Chalk reaches it only through
`docker exec`, and its password is random and never leaves the container.
[The database](https://khalaharvi.github.io/chalk/develop/database/) lists
every column.

| Table | What it holds |
| :-- | :-- |
| `runs` | One row per agent call: repository name, ticket ID, branch, loop, kind of call, how it ended, the rubric's exit code, the model, a hash of the prompts, cost, budget, duration, tokens, turns and refused actions. For a loop that made no progress, its fingerprint: the run ID, the first 100 failing test IDs and their hash, the first error line, the git tree ID and the verdict. |
| `events` | Ticket milestones: detention, submitted, spec blocked, ready. |
| `lessons` | One row per detention: why the run stopped, with up to 40 lines of rubric output or the agent's blocker; your office-hours note; the lesson distilled from it and where it applies; who resolved it (your git email, or your user name); and, on Postgres 17, the lesson's embedding. |
| `decisions` | One row per question to the decider: the question text, the answer, its confidence, the decider URL (without credentials) and the model and revision that answered, how long it took, or why there was no answer. |

### The state directory

`~/.local/state/chalk/` (or `$XDG_STATE_HOME/chalk/`):

- `<repository>/runs/<ticket>/`: a background run's log (`run.log`) and the
  run's `io/` directory:
  the prompts given to the agent, the agent's results, the setup and rubric
  output, the decider's answers (`decisions.jsonl`) and the git bundle of
  the sandbox's commits.
- `dashboard.html`: the report card, when you build it.
- `decider/`: the local decider's process IDs, logs, and the model
  revisions it installed.
- `db-upgrade/`: during `chalk db upgrade`, a full dump of the old database,
  removed by `chalk db upgrade --cleanup`.
- `locks/`: locks between `chalk` processes.

### Elsewhere

- **Your repository:** `.chalk/config`, the textbook, specs, worktrees, and
  the `detention/…` and `tutoring/…` branches. Detention branches stay
  local.
- **Sandbox containers:** each run's container keeps the clone on a RAM disk
  and is removed when the run ends.
- **The local decider's models,** when you run `chalk decider up`: in the
  Hugging Face cache (`~/.cache/huggingface`) and `uv`'s tool directory.

To remove it all: `chalk cleanup --all`, then
`docker rm -f chalk-db && docker volume rm chalk-db-data-17`, then delete
`~/.local/state/chalk/`.

## What leaves your machine, and when

| Where it goes | What | When |
| :-- | :-- | :-- |
| **The model provider** (the Anthropic API, or Bedrock, Vertex or a gateway you set with `ANTHROPIC_BASE_URL`) | The prompt: the spec, the textbook, retry feedback with test output, recalled lessons and review findings. Every file the agent reads in the sandbox, and the output of every command it runs there. | Every agent call. Also `chalk fleet` (the epic's text, to plan it) and office hours (your note, the failure and the fix's diff, to distill a lesson). |
| **Claude Code's own telemetry** | Usage metrics and error reports, which Anthropic says never include your code, prompts or file paths. | On by default with the Anthropic API, off on Bedrock and Vertex. See [Claude Code's data usage](https://code.claude.com/docs/en/data-usage). Chalk passes no setting for it into the sandbox; set `DISABLE_TELEMETRY=1` or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` with `ENV` in your own sandbox image to turn it off. |
| **The network, from the sandbox** | Whatever the agent, your setup command and your rubric fetch: packages, and web pages if the agent's permissions allow it. | During a run. See [Permissions](https://khalaharvi.github.io/chalk/guide/configuring/permissions/). |
| **Your forge** (GitHub or GitLab, through `git`, `gh` or `glab`) | The ticket's branch and its commits; a pull or merge request with its title and an execution summary (loops, cost, human interventions). | `chalk submit`, or at the end of a run when `CHALK_AUTO_MR=true`. Never a detention branch. |
| **An OpenTelemetry collector** | What Claude Code exports as metrics, logs or traces, tagged with the repository name and ticket ID. See [Claude Code's monitoring](https://code.claude.com/docs/en/monitoring-usage). | Only when `CHALK_OTEL_ENDPOINT` is set. |
| **A hosted decider** | For the stuck question: up to 20 failing test IDs and the first error line for the failed loop and the one before, plus a diffstat (file names and line counts), at most 6,000 characters. For the lesson question: the current failure (up to 1,500 characters; before the first loop, the start of the spec) and the failure and fix of up to 5 candidate lessons, 4,000 characters in all. When a loop has no fingerprint, the failure is the reason plus the last lines of the rubric's output, which can quote source lines from a stack trace. The same failure and lesson text go to `CHALK_EMBED_URL` when it is not local. | Only when `CHALK_DECIDER` is `shadow` or `on`, the URL points away from this machine (only the environment can set that, never a repository's config), and you have run `chalk decider trust URL`, which prints exactly this and records that one URL. Until then nothing is sent to it, not even a health check, and runs go on with the decider off. Loopback addresses are never gated; the default local decider listens on 127.0.0.1. `chalk decider untrust URL` takes it back. |
| **Your CI audit table** | Project, ticket ID, merge request number, commit SHA, pipeline ID and status ([`share/ci-audit-schema.sql`](https://github.com/khalaharvi/chalk/blob/main/share/ci-audit-schema.sql)). | From CI, only when the `CHALK_AUDIT_DB_URL` secret is set, to the database it names. |
| **Registries** (Docker Hub, Debian, npm, PyPI, Hugging Face) | Downloads only: the sandbox and database images, the `claude` CLI, and the local decider and its models. They see your IP address. | `chalk sandbox build`, the first `chalk db up`, and `chalk decider up`. |
| **A report card you post** | The `chalk share` summary below. | Only when you copy it somewhere. Chalk never sends it. |

Older versions could send lessons to Hindsight, an optional lesson server
with its own model. It was removed in
[#55](https://github.com/khalaharvi/chalk/pull/55); nothing goes to it now.

## What never leaves

Nothing on the list above happens without a run you started, a setting you
made, or a summary you posted. In particular, Chalk never sends your run
logs, the database, your office-hours notes, lessons or the decider's
questions anywhere except as listed: lessons and test output reach the
model provider inside prompts, and a hosted decider if you configure one.

## chalk share

`chalk share` builds an anonymised summary of your report card, so you can
help tune Chalk's defaults (budgets, verdict thresholds, the decider) with
numbers from your machine. It prints the exact JSON, says where it could be
posted, and **sends nothing**. Posting it is up to you; you can edit it
first.

```sh
chalk share                     # the last 30 days
chalk share --days 7 --output report-card.json
chalk share --json              # only the JSON, for scripts
```

To share it, start a discussion in
[Report cards](https://github.com/khalaharvi/chalk/discussions/new?category=report-cards)
and paste the JSON.

### What it holds

The summary is built from an allow-list
([`share/share.jq`](https://github.com/khalaharvi/chalk/blob/main/share/share.jq)):
every field is a count, a rounded amount, or a label from a fixed set.
Nothing is copied through from the database, so a field that is not named
here is never shared. A test seeds the database and state directory with
repository names, ticket IDs, paths, test names, errors, notes, an email,
a host name, model revisions and a cloud account ID, and fails if any of
them appears in the summary.

| Field | What it is | Why it is safe |
| :-- | :-- | :-- |
| `schema`, `chalk`, `harness` | The summary's format, the Chalk version, and `claude-code` | Fixed values or a version number. |
| `week`, `days` | The ISO week it was made (such as `2026-W41`) and the window in days | No date or time of any run. |
| `host` | OS (`darwin`, `linux`), architecture (`arm64`, `x86_64`), and CPUs and memory of the host and of Docker as ranges (`8-15`, `32-63`) | Says what kind of machine, not which one. No host name, user name or exact size. |
| `totals` | Calls, loops, checkpoints, tickets, runs, repositories, submitted, detentions and refused actions, as counts; cost, loop cost, cost with no progress and tokens, rounded to two significant figures | Counts, and amounts rounded so they cannot be matched to a bill. |
| `rates` | Cost per checkpoint, loops per checkpoint, share of spend with no progress, detention rate, review and spec-check pass rates, share of input read from cache | Ratios of the totals. |
| `by_kind` | Per kind of call (`continue`, `retry`, `fix-review`, `spec-check`, `review`, `distill`, else `other`): calls, cost, average cost and seconds | Fixed labels; rounded amounts. |
| `by_model` | Per model family (`claude-opus-4-5`, an alias such as `opus`, `default`, else `other`): loops, checkpoints, cost | The family only: no date, revision, region, deployment or account. A Bedrock ARN, a gateway's model name or anything unrecognised is `other`. |
| `budget` | The loop budget cap, the median, 90th percentile and largest loop cost, and loops near the cap | A setting and rounded amounts. |
| `review`, `spec_check` | How many ran and failed, and what they cost | Counts and rounded amounts. |
| `agent` | How loops' agent calls ended: `ok`, `blocked`, or an error, and their turns | Counts; never the error text. |
| `events` | Detentions, submissions, blocked specs, ready tickets | Counts. |
| `detentions_by_reason` | Detentions by why the run stopped (`blocked`, `loop_limit`, `review`, `deja_vu`, `repeat`, `no_change`, `stuck`, `failed`, `agent_error`, `no_checkpoint`, `other`) | The reason is read from the start of the stored text into one of these labels; the text itself is never read out. |
| `verdicts`, `fp_rules` | Loops by verdict, and by `CHALK_FP_RULES` mode | Fixed labels; anything else is `other`. |
| `lessons` | Retries with and without recalled lessons and how many passed; detentions opened, resolved, distilled and fingerprinted; lessons by scope | Counts; never a lesson, note or signature. |
| `ledger` | The verdict ledger's totals: detained runs, spend with no progress, what the rules would have saved, false stops, converging runs, failed loops and those that named no tests, and savings by stopping verdict | Counts and rounded amounts; no run, repository or ticket. |
| `decider` | Questions asked, answered and acted on; the median answer time to 10 ms; questions by kind, mode and error; calibration buckets (answers and how many were right per confidence band); what stopping would have saved and its false stops; the models | Counts and fixed labels. The local decider is named without its revision; any other model is only `hosted`, since a hosted decider names itself. |

It never holds repository names or URLs, paths, branch names, ticket IDs,
run IDs, code, diffs, prompts or their hash, test names or output, error
text, lesson or note text, decider questions, email addresses, user or host
names, model revisions, timestamps, or anything you typed.
