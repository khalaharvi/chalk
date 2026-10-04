# Contributing

Thanks for helping. Chalk is small on purpose: one Bash CLI, no build step.

## Run the checks

```sh
make check
```

That runs shellcheck and an end-to-end test of the whole workflow using fake
`docker`, `claude`, `glab` and `curl` (in `tests/fakes/`), so it needs no
Docker and spends nothing. To run the same test with the SQL executed
against a real Postgres:

```sh
FAKE_PG_URL=postgresql://user:pass@127.0.0.1:5432/db make test-db
```

## Ground rules

- Keep it compatible with bash 3.2, the version that ships with macOS. No
  associative arrays, `mapfile`, or `${var,,}`.
- A change to behaviour comes with a test in `tests/e2e.sh`.
- Prompts live in `share/prompts/`. If you change one, say in the pull
  request what you observed before and after on a real run.
- Say what you tested against real Docker and the real `claude` CLI, and
  what you did not. The fakes cannot catch a wrong CLI flag.

## Layout

| Path | What it holds |
| :-- | :-- |
| `bin/chalk` | Entry point and command dispatch |
| `lib/` | One file per concern: sandbox, agent calls, the loop, database, memory, lifecycle, dashboard, setup |
| `share/prompts/` | Every prompt the agents receive |
| `share/templates/` | Files `chalk init` adds to a repository |
| `share/schema.sql`, `share/dashboard.sql` | Telemetry schema and the dashboard query |
| `packaging/`, `scripts/release.sh`, `scripts/update-tap.sh` | Homebrew formula template and release scripts |
