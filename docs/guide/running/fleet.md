# Fleet runs

`chalk fleet` splits an epic into tickets and runs them in parallel, each
in its own worktree, branch and sandbox.

```sh
chalk fleet PROJ-900            # Claude drafts a plan, you confirm, agents launch in the background
chalk status
chalk logs PROJ-901 -f
```

## How it works

1. **The plan.** Claude Code, on your machine, reads the epic through your
   Jira MCP server and proposes workstreams: one ticket each, with a
   title, context and checkpoints. Or you pass a plan with `--plan FILE`.
2. **Confirmation.** Chalk prints the plan and asks before launching.
   `--yes` skips the question.
3. **Launch.** For each workstream, Chalk creates the worktree and branch,
   writes `specs/<TICKET>.md` from the plan, commits it and starts
   `chalk run --detach`. A ticket whose branch already exists is skipped.
4. **Waiting.** Only `CHALK_MAX_PARALLEL` runs go at once. The rest wait;
   re-run `chalk fleet PROJ-900 --yes` when a slot frees up and the saved
   plan launches what is left.

Each workstream is an ordinary ticket from then on: it goes to its own
pull or merge request, or to detention and office hours.

## How many at once

`CHALK_MAX_PARALLEL=auto`, the default, asks Docker what it can take and
runs the smallest of:

- 8;
- half of Docker's CPUs;
- Docker's memory, less 1 GiB for everything else, divided by
  `CHALK_SANDBOX_MEM_MB` (2048 MiB by default).

At least one runs, and 4 when Docker cannot be asked. `chalk doctor`
prints the number. Set a whole number to choose it yourself.

## Plans from Jira

`chalk fleet EPIC` asks Claude Code on your machine to read the epic, so
your Jira MCP server must be configured and its read tools allowed for
non-interactive use. For Atlassian's server:

```sh
claude mcp add --scope user --transport http atlassian https://mcp.atlassian.com/v1/mcp
```

then sign in once from `/mcp` in an interactive `claude` session. A Jira
connector added on claude.ai is not enough: while `ANTHROPIC_API_KEY` or
another API credential is set, Claude Code does not load claude.ai
connectors.

## Your own plan

To skip Jira, or to edit a plan, pass your own:

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

Every workstream needs a `ticket` like `PROJ-901`, a `title` and at least
one checkpoint; `context` is optional. The plan is saved as
`~/.local/state/chalk/<repo>/plans/<EPIC>.json`, so re-running
`chalk fleet PROJ-900 --yes` launches anything that was waiting for a free
slot, without asking Claude again.
