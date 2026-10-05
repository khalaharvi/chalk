# Troubleshooting

Start with `chalk doctor`, then the run's own files.

## chalk doctor

`chalk doctor` prints one line per check. `FAIL` lines stop Chalk from
working and end with what to do; `--` lines are optional or are set up on
first use.

| Check | Needed | If it fails |
| :-- | :-- | :-- |
| bash 5.3 or newer | yes | `brew install bash`, or `scripts/install-bash.sh PREFIX` and `CHALK_BASH=PREFIX/bin/bash` |
| git, jq, openssl | yes | Install them |
| Docker CLI and daemon | yes | Install and start Docker Desktop, OrbStack or Colima |
| `gh` or `glab`, signed in | yes | Install it and run `gh auth login` or `glab auth login`. Which one depends on the `origin` remote, or `CHALK_FORGE` |
| Agent credentials | yes | Run `claude setup-token` and export `CLAUDE_CODE_OAUTH_TOKEN` to use your Claude subscription, or export `ANTHROPIC_API_KEY`. See [Sign in to Claude](../../getting-started.md#sign-in-to-claude) |
| Which account agent calls bill | no | Says whether calls bill the API account or use your Claude plan. Shows `--` when both `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` are set, because the API key wins; `unset ANTHROPIC_API_KEY` to use your plan |
| `claude` on the host | no | Only `chalk fleet` planning needs it |
| Telemetry database | no | Starts on the first run, or `chalk db up` |
| Database on Postgres 17 | no | `chalk db upgrade`; see [the database](dashboard.md#the-database) |
| Host and Docker resources | no | Informational: CPUs, memory, how many fleet runs at once, how long Chalk waits for the database |
| Sandbox image and its bash | no | Built on the first run, or `chalk sandbox build`. A custom `CHALK_IMAGE` needs bash 5.2 or newer |
| Auto mode for `CHALK_MODEL` | yes, when it can be asked | `FAIL` when loops would start in manual mode and have every edit refused: choose another `CHALK_MODEL`, ask an administrator to allow auto mode, or set `CHALK_PERMISSION_MODE=bypass`. "could not verify" when Docker or the image is not ready. See [auto mode requirements](../configuring/permissions.md#auto-mode-requirements) |
| Repository configured | no | `chalk init`, then set `CHALK_TEST_CMD` |

## Where a run keeps its files

Everything about the latest run of a ticket is under
`~/.local/state/chalk/<repo>/runs/<TICKET>/`:

| File | What it holds |
| :-- | :-- |
| `run.log` | The output of a run started with `--detach` (`chalk logs TICKET`) |
| `io/prompt.md` | The last loop's prompt, lessons and failure feedback included |
| `io/system.md` | The system prompt: harness rules and your textbook |
| `io/loop.json`, `io/loop.err` | The last loop's answer from Claude Code, cost and usage included, and its errors |
| `io/rubric.log` | The rubric's output from the last loop |
| `io/spec-check.json`, `io/review.json` | The spec check's and the final review's answers |
| `io/setup.log` | The output of `CHALK_SETUP_CMD` |
| `io/startup/` | Logs from starting the database and the sandbox image |

## Common problems

**A run was detained. What now?** Read the `next:` line under
`DETENTION:` in the log: each reason has its own advice. The table in
[Detention and office hours](../running/failures.md#what-sends-a-run-to-detention)
lists them all.

**A run makes no progress, and the log reports refused actions.** Auto
mode is probably unavailable, so every edit is refused; a detention after
a loop with three or more refusals says so in its `next:` line. Run
`chalk doctor`, which checks auto mode for `CHALK_MODEL`, and see
[auto mode requirements](../configuring/permissions.md#auto-mode-requirements).

**"uncommitted changes in …; commit them first".** The sandbox clones the
branch, so it sees only commits. Commit the spec and anything else first.

**"a run for PROJ-123 is already active".** Another `chalk run` for the
ticket is still going (`chalk status`). Wait for it, or stop it with
`chalk cleanup`.

**"branch '…' has no ticket key".** `chalk run` works out the ticket from
the branch name. Run it from a worktree made by `chalk new`, or on a
branch like `chalk/PROJ-123`.

**The spec check stops the run.** It lists each problem with a suggestion.
Rewrite those checkpoints, commit and run again; `chalk check` runs the
check alone. `CHALK_SPEC_CHECK=false` skips it.

**"sandbox image '…' has bash 5.1".** The sandbox scripts need bash 5.2 or
newer. Use an image based on Debian 12 or later, or install a newer bash
in your image.

**"chalk-db runs Postgres 16".** Runs keep working; run
`chalk db upgrade` when no runs are active. Runs print this warning at
most once a day; `chalk doctor` reports it every time.

**"ignoring CHALK_MEMORY…: Hindsight lesson memory was removed".** Delete
those settings from `.chalk/config` or your environment. See
[Lesson recall](../configuring/lesson-memory.md#hindsight-was-removed).

**"ignoring unknown key in .chalk/config".** A typo, or a setting from a
newer Chalk. Compare with [Configuration](../configuring/configuration.md).

**`chalk fleet` cannot generate a plan.** Claude Code on your machine needs
your Jira MCP server; see [Plans from Jira](../running/fleet.md#plans-from-jira).
Or write the plan yourself and pass `--plan`.

**The database is slow to start.** Chalk waits `CHALK_DB_TIMEOUT` seconds,
`auto` by default, which allows more on a slower machine. Set a number to
wait longer.

If none of this helps, please
[open an issue](https://github.com/khalaharvi/chalk/issues) with the
relevant part of the run's files and the `chalk doctor` output.
