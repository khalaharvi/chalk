# Contributing

Thanks for helping. Chalk is small on purpose: one Bash CLI, no build step.
It needs bash 5.3: `brew install bash`, or build one with
`scripts/install-bash.sh ~/.local/bash` and set
`CHALK_BASH=~/.local/bash/bin/bash`.

## Run the checks

```sh
make check
```

That runs ShellCheck (0.11.0 or newer, for bash 5.3 syntax), the convention
lint, unit tests for each module, and an end-to-end test of the whole
workflow using fake `docker`, `claude`, `gh`, `glab` and `curl` (in
`tests/fakes/`), so it needs no Docker and spends nothing. To run the same test with the SQL executed
against a real Postgres:

```sh
FAKE_PG_URL=postgresql://user:pass@127.0.0.1:5432/db make test-db
```

## Ground rules

- Follow [docs/bash-style.md](docs/bash-style.md): bash 5.3 on the host,
  bash 5.2 in `share/sandbox/scripts/`, bash 3.2 only in
  `lib/core/guard.sh`.
- A change to behaviour comes with a test in `tests/unit/` or
  `tests/e2e.sh`.
- Prompts live in `share/prompts/`. If you change one, say in the pull
  request what you observed before and after on a real run.
- Say what you tested against real Docker and the real `claude` CLI, and
  what you did not. The fakes cannot catch a wrong CLI flag.

## Layout

| Path | What it holds |
| :-- | :-- |
| `bin/chalk` | Entry point: finds bash 5.3, loads modules, dispatches commands |
| `lib/core/` | Shell runtime: messages, strict settings and traps, background jobs, the bash guard |
| `lib/` | One file per concern: repository, state, config, database, memory, sandbox, agent calls, the loop, fleet, lifecycle, dashboard, setup |
| `share/sandbox/` | The default sandbox image and the scripts that run inside it (bash 5.2) |
| `share/prompts/` | Every prompt the agents receive |
| `share/templates/` | Files `chalk init` adds to a repository |
| `share/schema.sql`, `share/dashboard.sql` | Telemetry schema and the dashboard query |
| `packaging/`, `scripts/release.sh`, `scripts/update-tap.sh` | Homebrew formula template and release scripts |
| `scripts/install-bash.sh`, `scripts/lint-conventions.sh`, `scripts/check-sandbox-syntax.sh` | Toolchain and lint |
| `tests/unit/`, `tests/e2e.sh`, `tests/fakes/` | Tests |
| `docs/` | Style guide and design specs |
