# Getting started

This page installs Chalk, sets up one repository and runs a first ticket.

## Install

```sh
brew install khalaharvi/chalk/chalk
claude setup-token                   # once, with a Claude plan: prints a token
export CLAUDE_CODE_OAUTH_TOKEN=...   # that token; see "Sign in to Claude" for an API key or a gateway
chalk doctor
```

You also need:

- **A Docker runtime:** Docker Desktop, OrbStack or Colima. Every run
  happens in a container.
- **The forge's CLI, signed in:** `gh auth login` for a repository on
  GitHub, `glab auth login` for one on GitLab. Chalk picks the forge from
  the `origin` remote: github.com means GitHub, anything else GitLab. Set
  `CHALK_FORGE=github` for GitHub Enterprise.
- **bash 5.3 or newer** on your machine. Homebrew installs it with Chalk.
- `git`, `jq` and `openssl`.

### Sign in to Claude

Every agent call goes to Claude with a credential you export. Chalk passes
it into each sandbox by name, so the value never appears in `ps` or in the
repository. Use one of these:

| You have | Export | You pay |
| :-- | :-- | :-- |
| A Claude Pro, Max, Team or Enterprise plan: run `claude setup-token` once | `CLAUDE_CODE_OAUTH_TOKEN` | Your plan; runs count against its usage limits |
| An Anthropic API account: create a key in the Claude Console | `ANTHROPIC_API_KEY` | Per call, at API prices |
| A gateway in front of Claude: ask its administrator | `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL` | Whatever the gateway charges |

**With a subscription:**

- `claude setup-token` needs [Claude Code](https://code.claude.com/docs)
  installed on your machine. It opens a browser to sign in and prints a
  token that lasts a year. It does not save the token, so put the
  `export` line in your shell profile or a secrets manager.
- Runs count against your plan's usage limits: a rolling session limit and
  a weekly one. `chalk fleet` runs several agents at once
  (`CHALK_MAX_PARALLEL`), so it reaches them sooner than one ticket would.
  Check what is left at [claude.ai/settings/usage](https://claude.ai/settings/usage).
- The costs Chalk shows, in the run log and on the report card, are what
  Claude Code reports for each call. On a subscription they measure use;
  they are not a bill.
- Chalk has not yet been tested against a run that reaches a plan limit.
  If loops start failing with agent errors partway through, check your
  usage first.

**If more than one is set,** Claude Code uses `ANTHROPIC_API_KEY` before
`CLAUDE_CODE_OAUTH_TOKEN`. A key left in your environment from other work
bills the API account even when you meant to use your plan; run
`unset ANTHROPIC_API_KEY` to use the subscription. `chalk doctor` says
which account your calls bill, and flags this case.

### Without Homebrew

Clone `https://github.com/khalaharvi/chalk` and put `bin/chalk` on your
`PATH`. Started from an older bash, Chalk finds a newer one and re-runs
itself, or tells you how to get one: `scripts/install-bash.sh PREFIX`
builds bash 5.3, then set `CHALK_BASH=PREFIX/bin/bash`.

### Check the machine

`chalk doctor` checks the tools, the credentials, the database and the
sandbox image. Items marked `FAIL` stop Chalk from working and say how to
fix them; items marked `--` are optional or are set up on first use (the
telemetry database and the sandbox image are both started or built by the
first run). It also prints what it found about the machine: CPUs, memory,
how many agents `chalk fleet` will run at once, and how long Chalk waits
for the database. See [Troubleshooting](guide/operating/troubleshooting.md)
for what each check means.

## Set up a repository

Once per repository:

```sh
chalk init
$EDITOR .chalk/config    # set CHALK_TEST_CMD (the rubric) and CHALK_SETUP_CMD
git add -A && git commit -m "Add Chalk"
```

`chalk init` adds:

| File | What it is |
| :-- | :-- |
| `.chalk/config` | Settings, one `KEY=value` per line, each one explained in the file. See [Configuration](guide/configuring/configuration.md). |
| `.chalk/textbook.md` | The textbook: your engineering rules, appended to every agent's system prompt. Replace the examples with your own. |
| `CLAUDE.md` | A "Chalk agent rules" section, added to the file or creating it. Fill in the stack, how to run one test, and local gotchas. |
| `specs/` | Where each ticket's spec lives. |
| `.github/workflows/chalk.yml` (GitHub) or `.gitlab/chalk.gitlab-ci.yml` (GitLab) | The [pull and merge request gates](guide/operating/merge-request-gates.md). On GitLab, `.gitlab-ci.yml` gets an `include:` for it, or Chalk tells you what to add to yours. |

Files that already exist are kept. Two settings matter before the first
run:

- **`CHALK_TEST_CMD`**, the rubric. It must exit 0 only when the work is
  acceptable, for example `npm test` or `pytest -q`. Chalk runs it itself
  after every loop, inside the sandbox, and again in CI.
- **`CHALK_SETUP_CMD`**, run once in each fresh sandbox before the rubric,
  for example `npm ci`.

The default sandbox image is Node 22. For other stacks, see
[custom sandbox images](guide/configuring/configuration.md#custom-sandbox-images).

## Run a first ticket

```sh
chalk new PROJ-123 "Add rate limiting"   # worktree ../<repo>.worktrees/PROJ-123 on branch chalk/PROJ-123
cd ../<repo>.worktrees/PROJ-123
$EDITOR specs/PROJ-123.md                # write the checkpoints
git add -A && git commit -m "spec"
chalk check                              # optional: is the spec ready for an agent?
chalk run                                # or: chalk run --detach
```

Ticket keys look like `PROJ-123`: capital letters, a dash, a number. Each
ticket gets its own branch, `chalk/PROJ-123`, in its own worktree next to
your repository, so several tickets can run at once.

The spec starts from a template:

```markdown
# PROJ-123: Add rate limiting

## Context
What is being built and why. Link the ticket. Name the files or modules involved.

## Checkpoints
Each checkpoint must be small enough for one agent loop and provable by a test.
- [ ] First checkpoint
- [ ] Second checkpoint
```

Commit the spec before `chalk run`: the sandbox sees only commits. When the
run finishes, the pull or merge request is open, with the number of loops,
the cost, any human interventions and the review summary in its
description.

## Next

- [The workflow](guide/running/workflow.md): what a run does, step by step,
  and how to write checkpoints an agent can finish.
- [Detention and office hours](guide/running/failures.md): what to do when
  a run stops.
- [Fleet runs](guide/running/fleet.md): an epic split into tickets that run
  in parallel.
