# Contributing

Thanks for helping. Chalk is small on purpose: one Bash CLI, no build step.

## Set up

You need:

- **bash 5.3 or newer, first on your `PATH`.** The tests run plain `bash`,
  so the macOS `/bin/bash` (3.2) fails. Use `brew install bash`, or build
  one with `scripts/install-bash.sh ~/.local/bash` and run
  `export PATH=~/.local/bash/bin:$PATH`.
- **ShellCheck 0.11.0** (`brew install shellcheck`). CI pins this version.
  Older ones do not understand bash 5.3 syntax.
- **git, jq and make.**
- For `make test-db` only: `psql`, and a Postgres where the `pg_trgm`
  extension is available.

Check with `bash --version` and `shellcheck --version`.

## Run the checks

```sh
make check
```

That runs ShellCheck, the convention lint (`scripts/lint-conventions.sh`),
the unit tests in `tests/unit/`, and an end-to-end test of the whole
workflow. The end-to-end test uses the fake `docker`, `claude`, `gh`,
`glab`, `curl` and `timeout` in `tests/fakes/`, so it needs no Docker and
spends nothing. Each check prints `ok   …`; the first failure prints
`FAIL …` and stops. A full pass ends with `all tests passed`.

To run the end-to-end test with its SQL executed against a real Postgres:

```sh
FAKE_PG_URL=postgresql://user:pass@127.0.0.1:5432/db make test-db
```

CI also runs `make lint-sandbox`, which parses the sandbox scripts with
bash 5.2. It needs a bash 5.2 at `/usr/bin/bash` (Linux), so on macOS
leave it to CI.

## Rules

- Follow [the bash style guide](docs/bash-style.md). In short: bash 5.3 on
  the host, bash 5.2 in `share/sandbox/scripts/`, and bash 3.2 only in
  `lib/core/guard.sh`.
- A change to behaviour comes with a test in `tests/unit/` or
  `tests/e2e.sh`. A new external program the harness calls gets a fake in
  `tests/fakes/`.
- Prompts live in `share/prompts/`. Changing one changes what every agent
  does, so the pull request needs the before-and-after on a real run (see
  below).

## Open a pull request

1. Branch from `main`. Commits on your branch can be written any way you
   like; they are squashed when the pull request merges.
2. Make `make check` pass.
3. Give the pull request a title that follows the commit title rules
   below. The `pr-title` check fails until it does.
4. In the pull request, say:
   - what you tested against real Docker and the real `claude` CLI, and
     what you did not. The fakes cannot catch a wrong CLI flag. If you
     could not run it for real, say so; a maintainer can, and labels the
     issue `real-run`;
   - for a prompt change, what the agent did before and after.

`main` is protected: changes land only through pull requests that pass
CI, and each one is squash-merged with its title as the commit.

## Commit titles

Pull request titles follow
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/),
because each one becomes the commit on `main` and a line in
[CHANGELOG.md](CHANGELOG.md):

```text
type(scope): description
```

- **type** is one of `feat`, `fix`, `perf`, `docs`, `refactor`, `test`,
  `build`, `ci`, `chore` or `revert`. Only `feat`, `fix`, `perf` and `docs`
  reach the changelog.
- **scope** is optional and lower case: the module or area, such as
  `fleet`, `sandbox` or `db`.
- **description** is imperative and lower case, like the rest of the
  title: "read epics from GitHub issues", not "Reads" or "Read".
- A `!` after the type or scope marks a breaking change and puts the line
  under "Breaking changes", for example `feat(config)!: rename
  CHALK_CHEAP_MODEL`. A `BREAKING CHANGE:` line in the description does the
  same.

Check a title locally with `scripts/check-commit-title.sh "fix: …"`.

The [roadmap](docs/roadmap.md) lists planned work. Each roadmap issue links
to its design notes.

## Layout

| Path | What it holds |
| :-- | :-- |
| `bin/chalk` | Entry point: finds bash 5.3, loads modules, dispatches commands |
| `lib/core/` | Shell runtime: messages, strict settings and traps, background jobs, host profile and locks, the bash guard |
| `lib/` | One file per concern; see [Layers](docs/bash-style.md#layers) for the load order |
| `share/sandbox/` | The default sandbox image and the scripts that run inside it (bash 5.2) |
| `share/prompts/` | Every prompt the agents receive |
| `share/templates/` | Files `chalk init` adds to a repository |
| `share/*.sql`, `share/dashboard.html` | Database schema, CI audit schema, the report-card query and page |
| `packaging/`, `scripts/release.sh`, `scripts/update-tap.sh` | Homebrew formula template and release scripts |
| `scripts/install-bash.sh`, `scripts/lint-conventions.sh`, `scripts/check-sandbox-syntax.sh` | Toolchain and lint |
| `tests/unit/`, `tests/e2e.sh`, `tests/fakes/` | Tests and the fake external programs |
| `docs/` | Style guide, roadmap, design notes and specs |
