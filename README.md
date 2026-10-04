# Chalk

A harness that runs Claude Code agents in disposable sandboxes, one small
checkpoint at a time, with a spend cap per loop, a test gate the harness
verifies itself, and a human escalation path when an agent gets stuck.
Finished work arrives as a GitLab merge request.

## Status

Early. The whole workflow is covered by an end-to-end test that uses fake
`docker`, `claude` and `glab`, the SQL is tested against a real Postgres, and
the Homebrew formula is tested with a real install. It has not yet had many
runs against real Docker, the real Claude CLI and a real GitLab project, so
expect rough edges and please [report them](https://github.com/khalaharvi/chalk/issues).

Chalk works on repositories hosted on GitLab (merge requests via `glab`,
gates in GitLab CI). The tool itself is developed on GitHub at
[khalaharvi/chalk](https://github.com/khalaharvi/chalk).

## Install

```sh
brew install khalaharvi/chalk/chalk
export CLAUDE_CODE_OAUTH_TOKEN=...   # or ANTHROPIC_API_KEY, or ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL for a gateway
chalk doctor
```

You also need a Docker runtime (Docker Desktop, OrbStack or Colima) and
`glab auth login`. Homebrew installs the bash 5.3 Chalk runs under.

Without Homebrew, clone `https://github.com/khalaharvi/chalk` and put
`bin/chalk` on your `PATH`. Chalk needs bash 5.3 or newer; started from an
older bash it finds a newer one and re-runs itself, or tells you how to
get one (`scripts/install-bash.sh PREFIX` builds it, then set
`CHALK_BASH=PREFIX/bin/bash`).

Sandbox images need bash 5.2 or newer. The default image has it; if you
set `CHALK_IMAGE` to your own, `chalk doctor` checks it.

## Set up a repository (once)

```sh
chalk init          # adds .chalk/config, .chalk/textbook.md, CI gates, a CLAUDE.md section, specs/
$EDITOR .chalk/config    # set CHALK_TEST_CMD (the rubric) and CHALK_SETUP_CMD
git add -A && git commit -m "Add Chalk"
```

## The workflow

**One ticket**

```sh
chalk new PROJ-123 "Add rate limiting"   # worktree ../<repo>.worktrees/PROJ-123 on branch chalk/PROJ-123
cd ../<repo>.worktrees/PROJ-123
$EDITOR specs/PROJ-123.md                # write the checkpoints
git add -A && git commit -m "spec"
chalk run                                # or: chalk run --detach
```

**An epic, in parallel**

```sh
chalk fleet PROJ-900            # Claude drafts a plan, you confirm, agents launch in the background
chalk status
chalk logs PROJ-901 -f
```

**What a run does**

1. Starts a container with the repository cloned into a RAM disk. The host
   repository is mounted read-only. The container has no GitLab credentials.
   Inside it, the agent runs in auto mode (see "Permissions").
2. Spec check: a cheap model confirms every checkpoint is small, testable and
   unambiguous. If not, the run stops before any money is spent on loops.
   Run it alone with `chalk check`.
3. Each loop: the agent works on the first unchecked checkpoint under a
   `CHALK_BUDGET_USD` cap and reports `done` or `blocked`. The harness then
   runs the rubric itself.
4. Rubric passes and a checkpoint was ticked: the harness commits and
   fast-forwards your local branch. Otherwise the agent gets the failure
   output and a retry prompt, up to `CHALK_MAX_RETRIES`.
5. All checkpoints done: an independent agent reviews the change for stubs,
   weakened tests and drift from the spec. Findings get one fix round
   (`CHALK_REVIEW_ROUNDS`) and a second review.
6. Review passes: the branch is pushed and a merge request is opened with
   loops, cost, human interventions and the review summary.
7. A reported blocker, the loop limit, exhausted retries or a review that
   still fails: **detention**.

The agent keeps `specs/<TICKET>.notes.md` up to date as it works, so each
loop starts from what earlier loops learned. The file is committed and
appears in the merge request.

**Detention and office hours**

Nothing is pushed on failure. The agent's work is parked on a local
`detention/PROJ-123-<timestamp>` branch and the failure is logged.

```sh
git switch detention/PROJ-123-1764000000
# fix the blocker (missing mock, wrong assumption, unclear spec), commit
chalk office-hours -m "Payments client needs the sandbox base URL in tests"
```

That records your note, distils it with your fix into a general lesson,
moves to a `tutoring/…` branch and resumes the loop. Relevant lessons are given to the agent on future loops,
in any repository on your machine. See "Lesson memory" for how they are matched.

**End of sprint**

```sh
chalk cleanup         # stops runs, removes sandboxes and clean worktrees, deletes merged or pushed branches
chalk cleanup --all   # also deletes unmerged branches, including detention work
```

## Merge request gates

`chalk init` adds `.gitlab/chalk.gitlab-ci.yml`. On merge requests from
`chalk/*` and `tutoring/*` branches it:

- fails if the spec has unfinished checkpoints or governance files are missing;
- re-runs the rubric outside the agent's sandbox;
- optionally writes a row to a central audit table (`CHALK_AUDIT_DB_URL`,
  schema in `share/ci-audit-schema.sql`).

Turn on GitLab approval rules as well. The gates show the checks passed;
the approval shows a person reviewed the diff.

## Configuration

`.chalk/config` is plain `KEY=value` and is never executed. Every key is
documented in the file. Environment variables override it. The important ones:

| Key | Default | Meaning |
| :-- | :-- | :-- |
| `CHALK_TEST_CMD` | none, required | The rubric |
| `CHALK_SETUP_CMD` | none | Runs once per sandbox, e.g. `npm ci` |
| `CHALK_BUDGET_USD` | `1.00` | Spend cap per loop |
| `CHALK_MAX_LOOPS` | `20` | Loops per run; worst-case spend is budget × loops |
| `CHALK_MAX_RETRIES` | `2` | Consecutive failed loops before detention |
| `CHALK_MAX_PARALLEL` | `4` | Concurrent agents for `chalk fleet` |
| `CHALK_SPEC_CHECK` | `true` | Check the spec before the first loop |
| `CHALK_REVIEW` | `true` | Review the finished change before the merge request |
| `CHALK_CHEAP_MODEL` | `haiku` | Model for the spec check and lesson distillation |
| `CHALK_IMAGE` | `chalk-sandbox:local` | Sandbox image; the default is Node 22 |

For other stacks, build an image with your toolchain plus the `claude` CLI
(start `FROM` the Dockerfile in `share/sandbox/`) and set `CHALK_IMAGE`.

## Report card

```sh
chalk dashboard            # last 30 days; --days N, --output FILE, --no-open
```

Builds one self-contained HTML page from the telemetry database on your
machine and opens it. Nothing is served and nothing is sent anywhere. It shows:

- cost per finished checkpoint, total spend, merge requests and detentions;
- the share of loop spend that made no progress;
- spend by kind of call (first attempts, retries, review fixes, reviews, spec
  checks, lesson distillation) and by day;
- loop cost against `CHALK_BUDGET_USD`;
- results by prompt set and by model, so a prompt or model change shows up as
  a before and after;
- whether the spec check and final review are earning their cost;
- "Notes for next term": plain rules over the numbers, such as a cap that is
  far above what loops use, or a review that never fails anything.

Every agent call is recorded in the `runs` table with its kind, model, prompt
set, cost, duration, tokens, cache use and outcome. Query it directly with
`chalk db psql`.

### OpenTelemetry

To see inside a loop (each API request and tool call), have the agents export
Claude Code's own telemetry. Set this on your machine, not in the repository:

```sh
export CHALK_OTEL_ENDPOINT=http://localhost:4317   # e.g. local Jaeger
export CHALK_OTEL_SIGNALS=traces                   # any of traces,metrics,logs
export CHALK_OTEL_PROTOCOL=grpc
```

`localhost` is rewritten so the container reaches a collector on your machine.
Each run is tagged `chalk.repo` and `chalk.ticket`. Traces are a beta feature
of Claude Code. Jaeger takes traces only; for metrics and logs, point the
endpoint at a collector that accepts them, and export
`OTEL_EXPORTER_OTLP_HEADERS` if it needs credentials.

## Permissions

Chalk never needs a `settings.json` allow list.

- **Loops** run in Claude Code's auto mode (`--permission-mode auto`), where
  a safety classifier reviews actions and no prompts appear. Set
  `CHALK_PERMISSION_MODE=bypass` to use `--dangerously-skip-permissions`
  instead, where your organisation allows it.
- **Spec check, review and distillation** run with `--permission-mode
  dontAsk` and an allow list of read tools plus `git diff`, `log`, `show`
  and `status`. They cannot edit files or run other commands.

Auto mode has requirements. It needs a supported model (not Haiku), and an
administrator can disable it. If it is unavailable, Claude Code starts in
manual mode without an error, and in a headless run that means every edit
and command is refused. Chalk logs how many actions were refused in each
loop, so a run that makes no progress with refusals in the log points here.

Classifier checks add a round trip per shell command and, on Enterprise and
API accounts, can count toward token usage. If routine actions get blocked,
an administrator can describe trusted infrastructure in the `autoMode`
settings; for Chalk those settings must be in the sandbox image.

## Prompts

Every agent call gets the same system prompt, appended to Claude Code's own
with `--append-system-prompt-file`: Chalk's harness rules followed by
`.chalk/textbook.md`. Each call also returns JSON in a fixed schema, so the
harness never parses prose.

| Prompt | Used for |
| :-- | :-- |
| `system` | Sandbox facts and harness rules, with the reasons for them |
| `continue` | A loop on the next checkpoint |
| `retry` | A loop after a failed attempt: root cause first |
| `fix-review` | A loop that fixes final-review findings |
| `spec-check` | Checking checkpoints before a run |
| `review` | The final review |
| `distill` | Turning an office-hours note into a general lesson |
| `breakdown` | Splitting an epic for `chalk fleet` |

To change one for a repository, run `chalk prompts eject NAME`, edit
`.chalk/prompts/NAME.md` and commit it. `chalk prompts` shows which are
overridden. The reviewer is the one most worth tuning: read
`~/.local/state/chalk/<repo>/runs/<TICKET>/io/review.json` after a few runs
and adjust the prompt where its judgement differs from yours.

## Lesson memory

Lessons always live in the `lessons` table in Postgres. `CHALK_MEMORY`
chooses how they are matched to a new failure:

- `builtin` (default): text similarity in Postgres. Nothing extra to run.
- `hindsight`: a local [Hindsight](https://hindsight.vectorize.io) server on
  each machine, which adds semantic, keyword, graph and temporal recall.

To use Hindsight, set `CHALK_MEMORY=hindsight` in `.chalk/config`. Chalk
starts the `chalk-memory` container on first use, bound to localhost only.

- Hindsight calls an LLM to extract facts from each lesson, so it needs an
  API key. Chalk passes `ANTHROPIC_API_KEY` if set; otherwise export
  `HINDSIGHT_API_LLM_PROVIDER` and `HINDSIGHT_API_LLM_API_KEY`. A Claude
  subscription token (`CLAUDE_CODE_OAUTH_TOKEN`) does not work here.
- The key is stored in the container's configuration. Recreate the container
  to rotate it: `docker rm -f chalk-memory && chalk memory up`.
- Expect roughly 2 GB of RAM for the server. Pin a version with
  `CHALK_MEMORY_IMAGE` rather than tracking `latest`.
- Memory never blocks work. If the server is down, runs continue without
  recalled lessons, and lessons recorded meanwhile are sent by
  `chalk memory sync`. That command also loads lessons recorded before you
  switched Hindsight on.
- To move to a shared server later, point `CHALK_MEMORY_URL` at it.

## Fleet plans

`chalk fleet EPIC` asks Claude Code on your machine to read the epic, so
your Jira MCP server must be configured and its read tools allowed for
non-interactive use. To skip that, or to edit a plan, pass your own:

```sh
chalk fleet PROJ-900 --plan plan.json
```

```json
{"workstreams": [
  {"ticket": "PROJ-901", "title": "Add limiter middleware",
   "context": "What and why, files involved",
   "checkpoints": ["Token bucket with tests", "Wire into router"]}
]}
```

The plan is saved, so re-running `chalk fleet PROJ-900 --yes` launches
anything that was waiting for a free slot.

## Where things live

| What | Where |
| :-- | :-- |
| Specs | `specs/<TICKET>.md`, one file per ticket so parallel branches never conflict |
| Global rules | `.chalk/textbook.md`, appended to the agent's system prompt |
| Local rules | `CLAUDE.md` |
| Run logs and plans | `~/.local/state/chalk/<repo>/` |
| Telemetry and lessons | Postgres in the `chalk-db` container (`chalk db psql`), tables `runs` and `lessons` |
| Lesson index (optional) | Hindsight in the `chalk-memory` container, bank `chalk` |

## Compliance note

Chalk produces evidence that supports an ISO/IEC 42001 management system:
per-loop cost and outcome records, a log of human interventions, enforced
test gates and an optional central audit trail. It does not make a team
compliant by itself. That depends on your policies, risk assessments and
review practice, including people actually reviewing agent-written diffs.

## Developing Chalk

```sh
make check    # shellcheck, convention lint, unit tests, end-to-end test with fakes
make test-db  # the end-to-end test with SQL run against a real Postgres (FAKE_PG_URL)
```

Chalk is written for bash 5.3 on the host and 5.2 in the sandbox; see
[docs/bash-style.md](docs/bash-style.md).

## Releasing

```sh
scripts/release.sh 0.5.0
```

That runs the checks, sets the version, then tags and pushes. The pushed tag
starts the release workflow, which runs the checks again, creates the GitHub
Release, points the formula in
[khalaharvi/homebrew-chalk](https://github.com/khalaharvi/homebrew-chalk) at
the new tarball, and installs it from the tap on macOS to confirm it works.

The workflow pushes to the tap with a deploy key stored in this repository's
`TAP_DEPLOY_KEY` secret. To update the tap by hand instead, run
`scripts/update-tap.sh 0.5.0 ../homebrew-chalk` from a clone of it.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
