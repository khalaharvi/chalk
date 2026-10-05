# Testing

Chalk is tested without Docker, without the Claude CLI and without
spending anything: fakes stand in for every external program.

```sh
make check    # shellcheck, convention lint, unit tests, end-to-end test with fakes
make test-db  # the end-to-end test with SQL run against a real Postgres (FAKE_PG_URL)
scripts/ci-db-upgrade.sh  # a real Postgres 16 -> 17 `chalk db upgrade` on Docker, on throwaway containers
```

The tests need bash 5.3 first on your `PATH`. Setting up, the rules for a
change and how to open a pull request are in
[CONTRIBUTING.md](https://github.com/khalaharvi/chalk/blob/main/CONTRIBUTING.md).

`make check` needs bash 5.3 and ShellCheck 0.11.0 or newer (for bash 5.3
syntax). It runs:

| Step | What it checks |
| :-- | :-- |
| `shellcheck` | `bin/chalk`, `lib/`, the sandbox scripts, `scripts/*.sh`, the tests and the fakes |
| `scripts/lint-conventions.sh` | The [bash style](../bash-style.md) rules ShellCheck cannot see, marked **(lint)** there |
| `tests/unit/*_test.sh` | One module each |
| `tests/e2e.sh` | The whole workflow, against the fakes |

To run the same end-to-end test with every SQL statement executed against
a real Postgres (with `pg_trgm`; CI uses `pgvector/pgvector:pg17`, the image
Chalk runs):

```sh
FAKE_PG_URL=postgresql://user:pass@127.0.0.1:5432/db make test-db
```

Everything the test writes goes to a schema of its own, made afresh on
every run, so `make test-db` can be repeated against the same database.

`scripts/ci-db-upgrade.sh` does a real `chalk db upgrade` against Docker:
it sets up an install from before Postgres 17 with representative rows,
checks that an upgrade that fails (the new container cannot be created,
or a timeout interrupts it) puts the Postgres 16 container back
unchanged, then upgrades, compares every row and runs `--cleanup`. It uses
only containers and volumes of its own (named from `CHALK_CI_DB_PREFIX`,
`chalk-ci` by default), refuses the names a real install uses, and
removes them at the end unless `CHALK_CI_DB_KEEP=1`. The container,
volume and image names in `lib/db.sh` can be set from the environment for
this test only. CI runs it as the `db-upgrade` job.

`make lint-sandbox` parses the sandbox scripts with a bash 5.2
(`SANDBOX_BASH`, `/usr/bin/bash` by default); CI runs it on Ubuntu.

## The fakes

`tests/fakes/` is put first on `PATH`. Each fake logs its calls under
`$FAKE_STATE`, where tests check them.

| Fake | Stands in for | Knobs |
| :-- | :-- | :-- |
| `docker` | Containers are directories under `$FAKE_STATE`; `exec` runs the command on the host with container paths rewritten. `chalk-db` answers canned SQL results, or runs the SQL against `FAKE_PG_URL` | `FAKE_DB_MODEL=1` models database containers and volumes, for `chalk db upgrade`; `FAKE_DB_BROKEN`, `FAKE_DB_RESTORE_FAIL`, `FAKE_SANDBOX_BASH="5 1"` |
| `claude` | Reads the prompt, works out which Chalk prompt it is from its tags, and answers in that prompt's JSON shape. A loop ticks the next checkpoint and appends to `work.txt` | `FAKE_CLAUDE_MODE=break`, `blocked` or `slow`; `FAKE_SPEC=fail`; `FAKE_REVIEW=fail-once` or `fail` |
| `gh`, `glab` | Log their arguments | |
| `curl` | Logs the call and answers `{}`; no test reaches the network | |
| `timeout` | Drops the time limit, since stock macOS has no `timeout` | |

The fakes cannot catch a wrong CLI flag. Say in a pull request what you
tested against real Docker and the real `claude` CLI, and what you did
not.

## Adding a test

- **A module's behaviour:** add a `check` to its `tests/unit/<module>_test.sh`.
  Tests source `tests/unit/testlib.sh` and load modules with
  `load core/log repo …`.
- **A workflow:** add a numbered case to `tests/e2e.sh`. Each case creates
  a ticket with `chalk new`, runs commands with fake knobs set, and checks
  the branches, the logs under `$FAKE_STATE` and the run files under
  `$XDG_STATE_HOME`:

```bash
chalk new PROJ-30 Example >/dev/null
cd "$tmp/demo.worktrees/PROJ-30"
git add -A && git commit -q -m "spec"
if FAKE_CLAUDE_MODE=blocked chalk run > "$tmp/run30.log" 2>&1; then fail "should stop"; fi
check "a blocker goes to detention" grep -q 'needs the staging API key' "$tmp/run30.log"
cd "$tmp/demo"
```

A change to behaviour comes with a test in one of them.

## The docs site

```sh
python3 -m venv .venv && .venv/bin/pip install -r docs/requirements.txt
.venv/bin/mkdocs serve           # or: make docs (with mkdocs on PATH)
.venv/bin/mkdocs build --strict  # what CI runs
scripts/check-links.sh           # needs lychee; checks the built site/
```

The build fails on a broken internal link or anchor, and on a
configuration template that disagrees with `lib/config.sh`
(`scripts/mkdocs_hooks.py`). Pages under `docs/designs/`, `docs/specs/`
and `docs/superpowers/` are working notes and are not published; link to
them by their full GitHub URL.

The pictures are made by scripts, so they can be made again after a
change:

| Picture | Made by |
| :-- | :-- |
| The demo recording, `docs/assets/demo.{cast,txt,svg}` and `demo-poster.svg` | `make demo`: `scripts/demo.sh` runs the real `chalk` against the fakes and records it, then `scripts/render-demo.py` draws it |
| The report card, `docs/assets/report-card-{light,dark}.png` | `scripts/screenshots.sh`, from the sample in `docs/assets/report-card.json` (needs Chrome or Chromium) |
| The README banner, `docs/assets/banner-{light,dark}.svg` | `scripts/render-banner.py` (needs `fonttools` and `brotli`) |
