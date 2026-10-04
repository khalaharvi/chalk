# Spec: Bash 5.3 on the host, 5.2 in the sandbox

| | |
| :-- | :-- |
| Status | Implemented on `spec/bash-5.3`; awaiting CI |
| Target release | 0.5.0 (breaking) |
| Replaces | The bash 3.2 rule in `CONTRIBUTING.md` |

## Summary

Chalk is a Bash program that has been held to bash 3.2, the version macOS
ships. That rule keeps out associative arrays, namerefs, `mapfile`, case
conversion, `$EPOCHSECONDS` and everything newer, and the code pays for it
with string-encoded lists, `tr`/`sed`/`cut` forks, heredoc tricks for
reading several values, and workarounds for empty arrays under `set -u`.

This spec raises the floor to **bash 5.3 for code that runs on the host**
and **bash 5.2 for code that runs inside a sandbox container**, makes
Homebrew install the right bash, and rebuilds the code on top of what those
versions offer. Readability and file organisation are explicit goals: a new
feature is used only where it makes the code shorter, clearer or safer, and
each feature has a single documented idiom.

## Goals

1. `brew install chalk` brings its own bash 5.3 and always runs under it.
2. A clone-and-run install keeps working: Chalk finds a new enough bash and
   re-executes itself under it, or says exactly what to install.
3. The code is organised in layers with one responsibility per file, and the
   one file that must stay parseable by old bash is isolated and labelled.
4. Every bash 5.x feature Chalk uses follows one convention, written down in
   `docs/bash-style.md` and enforced by lint where a machine can check it.
5. No behaviour regresses: `tests/e2e.sh` stays green after every checkpoint.

## Non-goals

- Changing what Chalk does for users, apart from the fixes listed under
  *Behaviour changes*.
- Rewriting working pipelines through `jq`, `git`, `docker` or `psql` in
  pure bash. External tools stay where they are the right tool.
- Requiring bash 5.3 in sandbox images. See *Decisions*.

## Decisions

| # | Decision | Why |
| :-- | :-- | :-- |
| D1 | Host floor is **bash 5.3**. | It brings command substitution without a subshell (`${ cmd; }`, `${\| cmd; }`), `$BASH_TRAPSIG`, `source -p` and `GLOBSORT`, all used below. Homebrew ships it. |
| D2 | Sandbox floor is **bash 5.2**. | The default image (`node:22-bookworm-slim`) ships 5.2.15. 5.3 would mean compiling bash in the Dockerfile, and container-side code is a handful of short git snippets that gain nothing from 5.3. |
| D3 | The formula depends on Homebrew's `bash` and pins the shebang to it. | Brew installs never depend on `PATH` order. |
| D4 | Clone installs re-exec under a newer bash. | Keeps the no-Homebrew path working on macOS, where `/bin/bash` is 3.2. |
| D5 | Ship as 0.5.0 and call it breaking. | Custom `CHALK_IMAGE`s with bash < 5.2, and clone users with no new bash installed, will stop working. |

## Verified facts

Everything below was checked against bash 5.3.0 built from GNU source, with
the system bash 5.2.21 as a control, before this spec was written.

| Fact | Result |
| :-- | :-- |
| Current `tests/e2e.sh` under bash 5.3.0 | Passes unchanged |
| Current tree under ShellCheck 0.11.0 | Clean |
| ShellCheck 0.11.0 parses `${ cmd; }`, `${\| cmd; }`, `source -p`, `read -E`, `GLOBSORT` | Yes |
| `${ cmd; }`, `${\| cmd; }`, `source -p`, `read -E`, `compgen -V` on bash 5.2; `$BASH_TRAPSIG` on bash 5.2 | Syntax errors or invalid options; `$BASH_TRAPSIG` is unset. All are 5.3-only |
| A 3.2-syntax guard that `exec`s a newer bash before any 5.3 syntax is reached | Works: the old bash never parses the later code |
| Exit status of `x=${ f; }` | Is `f`'s status |
| `exit` or `die` inside `${ … }` | Exits Chalk itself (today `$( )` + `set -e` ends the run too) |
| `cd` inside `${ … }` | **Leaks** into the caller |
| `local` inside `${ … }` | Scoped to the substitution |
| `${ <file; }` | **Returns empty**; the `$(<file)` shortcut does not apply |
| `$BASH_TRAPSIG` | The signal number (TERM = 15), so `128 + BASH_TRAPSIG` is the conventional exit code |
| `wait -n -p pid` with a pid→name associative array | Collects each background job's exit status by name |
| `local -n out=$1` called with a variable named `out` | Circular-reference warning; assignment goes to the wrong variable |
| `shopt -s array_expand_once` vs subscript injection | No difference found in 5.3.0 for the forms Chalk would use, so it is not adopted |

### Found during implementation

Checked against bash 5.3.20 (5.3 with the official patches), which CI builds.
One precaution is not verified here, since no bash 3.2 was available: the
guard passes arguments as `${1+"$@"}`, the form that is safe for an empty
argument list under `set -u` in every bash. The macOS job exercises the
guard under the real 3.2.

| Fact | Consequence |
| :-- | :-- |
| With `inherit_errexit`, a `${\| f; }` whose `f` fails **ends the shell even inside `&&`, `\|\|` or `if`**, and fires the ERR trap. `$(f)` in the same place does neither. | Value functions never return non-zero; "no value" is an empty `REPLY`. Linted. |
| `BASH_COMMAND` in an ERR trap after a deliberate `return 1` is `return 1`, not the call | The failure report skips `return`, so detentions and failed checks stay quiet |
| `declare -A` in a file sourced from inside a function creates a local | Module-level tables use `declare -gA` |
| `source -p DIR NAME` rejects a `NAME` containing `/`, and never falls back to the working directory | One `source -p` loop per layer directory |
| ShellCheck cannot see a nameref's type, so bare keys in `__ref=([key]=…)` read as arithmetic | Keys assigned through a nameref are quoted |
| `wait -n -p pid` also returns jobs that finished before the call; background jobs do not run the parent's EXIT trap | `jobs_wait` needs no bookkeeping beyond pid → name |
| An `exec` inside a loop reading a heredoc on stdin passes that heredoc to the new process as its stdin | The guard reads its candidate list on fd 3 and closes it on `exec` |

## Target layout

Files are arranged in three layers. A file may use anything from a lower
layer and nothing from a higher one.

```
bin/chalk                    entry point: resolve CHALK_HOME, run the guard, load modules, dispatch

lib/core/                    layer 1: shell runtime, no Chalk knowledge
  guard.sh                   the ONLY file that must parse under bash 3.2; finds bash >= 5.3 and re-execs
  runtime.sh                 shell options, ERR and signal traps, `need`, `bash_at_least`
  log.sh                     info, warn, die
  jobs.sh                    run named background jobs and collect their results

lib/                         layer 2: Chalk domain
  repo.sh                    repository identity (memoized), worktrees, ticket keys, spec parsing
  state.sh                   state and run directories, pid files
  config.sh                  config keys, defaults and loading
  db.sh  memory.sh  sandbox.sh  agent.sh

lib/                         layer 3: commands (cmd_* functions)
  run.sh  fleet.sh  lifecycle.sh  dashboard.sh  setup.sh

share/sandbox/               runs INSIDE the container, bash 5.2
  Dockerfile
  scripts/clone.sh  commit.sh  reset.sh  export.sh

scripts/
  install-bash.sh            builds the pinned, patched bash 5.3 (CI and contributors)
  lint-conventions.sh        the conventions ShellCheck cannot check
  check-sandbox-syntax.sh    parses the sandbox scripts with bash 5.2

tests/
  e2e.sh                     unchanged role: the whole workflow against fakes
  unit/                      new: one *_test.sh per module, sharing testlib.sh
  fakes/

docs/
  bash-style.md              the conventions, for contributors
  specs/bash-5.3.md          this file
```

What moves where:

| Today | After |
| :-- | :-- |
| `lib/common.sh` `info` `warn` `die` | `lib/core/log.sh` |
| `lib/common.sh` `need` | `lib/core/runtime.sh` |
| `lib/common.sh` repo, ticket and spec helpers | `lib/repo.sh` |
| `lib/common.sh` `state_dir` `run_dir` `run_is_alive` | `lib/state.sh` |
| Inline `bash -c '…'` scripts in `sandbox_clone`, `sandbox_commit`, `sandbox_reset`, `sandbox_export` | `share/sandbox/scripts/*.sh`, run by `sandbox_script` as `docker exec … bash -c "$(<script)" chalk ARGS` |
| Module list in `bin/chalk` | Same loop, ordered by layer, using `source -p` |

`lib/common.sh` is removed. The container scripts become real files so they
can be linted and parse-checked under bash 5.2 in CI, which is how the 5.2
boundary is enforced.

## Conventions

The conventions live in [`docs/bash-style.md`](../bash-style.md), the
document contributors use. In summary:

| Rule | Gist |
| :-- | :-- |
| C1 | A function returns a result by setting `REPLY` (value), filling a caller-named variable (fill), or printing (stream). Value functions never return non-zero. |
| C2 | No `cd` and no `< file` inside `${ … }` or `${\| … }`. |
| C3 | Nameref locals start with `__`; keys assigned through them are quoted. |
| C4 | Lists are arrays, tables are `declare -gA`, lines are read with `mapfile`. |
| C5 | Parameter expansion, `$EPOCHSECONDS` and `read -r` instead of `tr`, `sed`, `date` and `cat`. |
| C6 | `lib/core/runtime.sh` owns shell options, the failure report and signal exit codes. |
| C7 | Background work only through `lib/core/jobs.sh`. |
| C8 | `guard.sh` is bash 3.2, sandbox scripts are bash 5.2, everything else 5.3; first lines say so. |

`scripts/lint-conventions.sh` checks C1 (value functions), C2, C3
(prefixes) and C8; ShellCheck and the unit tests cover the rest.

## Feature adoption

| Feature | Min | Where | Replaces |
| :-- | :-- | :-- | :-- |
| `${\| fn; }` value substitution | 5.3 | Every value function's callers (C1) | `$(fn)` forks; enables memoizing `repo_name`, which `db_*` and `sandbox_name` call repeatedly |
| `$BASH_TRAPSIG` | 5.3 | `lib/core/runtime.sh` signal handler | `trap 'exit 130' INT TERM` (`run.sh:67`), which exits 130 for TERM |
| `source -p` | 5.3 | Module loading in `bin/chalk` | `. "$CHALK_HOME/lib/$module.sh"` |
| `GLOBSORT=-mtime` | 5.3 | `chalk status` | Unsorted listing; most recently active runs now come first |
| `inherit_errexit` | 4.4 | `lib/core/runtime.sh` | Failures inside `$( )` being ignored |
| `nullglob`, `globskipdots` | 4.0 / 5.2 | `lib/core/runtime.sh` | `[ -d "$dir" ] \|\| continue` guards in `run.sh`, `fleet.sh`, `lifecycle.sh` |
| `declare -A` | 4.0 | `CHALK_CONFIG_DEFAULTS`, `CHALK_SCHEMA`, usage fields, job table | `CHALK_CONFIG_KEYS` string + `case` + 23 `: ${X:=…}` lines; four schema globals; positional `read a b c …` |
| Indexed arrays for lists | — | `CHALK_PROMPTS`, `CHALK_AUTH_VARS`, cleanup ref patterns, container ids | Space-separated strings and two `shellcheck disable=SC2086` |
| `local -n` | 4.3 | Fill functions (C1) | Functions that write to fixed globals (`SANDBOX_OTEL_ARGS`) |
| `mapfile -t` | 4.0 | `memory_sync`, `cmd_fleet`, `cmd_cleanup`, `cmd_status` | `while read … <<ROWS $(…)`, `wc -l \| tr -d ' '` |
| `[[ -v name ]]` | 4.2 | `load_config` | `${!key+set}` |
| `${v@U}` | 5.1 | `sandbox_otel_args` | `tr` |
| `${v@Q}` | 4.4 | Detention instructions in `run_detain` | Unquoted values in copy-paste commands |
| `$EPOCHSECONDS` | 5.0 | `run_detain`, `cmd_office_hours` | `$(date +%s)` |
| `wait -n -p` | 5.1 | `lib/core/jobs.sh` | Sequential start-up in `run_open_sandbox` |
| `${v//pattern/replacement}` + `mapfile` | 4.0 | Dashboard data escaping and template splice | `sed 's\|</\|<\\/\|g'` + temp file + `awk` splice |

### Considered and not adopted

| Feature | Reason |
| :-- | :-- |
| `array_expand_once` (5.3) | No difference in 5.3.0 for the subscript forms Chalk uses (tested above). Adopting it would be ritual. |
| `SRANDOM` (5.1) | The one random value is the Postgres password; `openssl rand` stays. |
| `read -E` (5.3) | The only prompt is y/N. |
| `compgen -V` (5.3) | Chalk has no shell completion. Revisit if `chalk completion` is added. |
| `EPOCHREALTIME` (5.0) | `runs.duration_s` is `INT`; sub-second timing needs a schema change first. |
| `coproc` (4.0) | Nothing needs a two-way pipe. |
| `${ fn; }` (5.3) | Chalk's own functions now set `REPLY` (`${\| }`) or feed external tools, which fork anyway. No caller was left that `${ }` would improve. |
| `patsub_replacement` (5.2) | On by default, but no replacement Chalk makes uses `&`. |

## Bootstrap and packaging

### The guard (`lib/core/guard.sh`)

`bin/chalk` resolves `CHALK_HOME` (existing 3.2-safe code), sources the
guard, and only then sources anything else. The guard:

1. Returns if `BASH_VERSINFO` is 5.3 or newer, first unsetting
   `CHALK_REEXECED` so a Chalk this one starts runs its own guard.
2. Stops with an error if `CHALK_REEXECED` is already set (prevents loops).
3. Tries, in order: `$CHALK_BASH`, `/opt/homebrew/bin/bash`,
   `/usr/local/bin/bash`, `/home/linuxbrew/.linuxbrew/bin/bash`, then every
   `bash` on `PATH`. A candidate qualifies if
   `"$c" -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"'` reports ≥ 5.3.
4. Exports `CHALK_REEXECED=1` and runs `exec "$c" "$0" ${1+"$@"}` with the
   first match, keeping stdin (the candidate list is read on fd 3).
5. Otherwise stops with:
   `chalk needs bash >= 5.3 (this is X.Y). Install it with 'brew install bash', or set CHALK_BASH to a bash 5.3 or newer.`

Chalk starts its own background runs with `"$BASH"`, so they skip the search.

### Homebrew formula (`packaging/chalk.rb.in`)

- `depends_on "bash"`.
- In `install`, `inreplace` the shebang of `libexec/"bin/chalk"` with
  `#{Formula["bash"].opt_bin}/bash`.
- `test do` also asserts that the installed `bin/chalk` shebang is Homebrew's bash and that `chalk version` runs under it.

### `chalk doctor`

- New required check: host bash version.
- New optional check: sandbox image bash version, once the image exists.
  When Docker is not running the check warns and moves on; it never fails
  `doctor` on its own.

## Sandbox boundary (bash 5.2)

- `sandbox_start` asks the image for its bash version and stops with
  `sandbox image 'IMAGE' has bash X.Y; Chalk needs >= 5.2 in the sandbox`.
- The default image already passes; the Dockerfile is unchanged.
- `share/templates/config` and the Dockerfile header say custom images need
  bash ≥ 5.2.
- `CHALK_SETUP_CMD` and `CHALK_TEST_CMD` are the user's own commands. They
  run under the image's bash and are not affected.

## Tooling and CI

| Job | Change |
| :-- | :-- |
| `lint-and-test` (Ubuntu) | `setup-bash` and `setup-shellcheck` (0.11.0, sha256-pinned); `make check lint-sandbox` under 5.3. `lint-sandbox` parses the sandbox scripts with `/usr/bin/bash`, which is 5.2 on `ubuntu-latest`. |
| `macos` | `setup-bash` (Homebrew's bash); `make test` under it. The guard unit tests run here against `/bin/bash` 3.2, the real old bash. |
| `postgres` | `setup-bash`; `make test-db` under 5.3. |
| `release` (publish) | `setup-bash` and `setup-shellcheck` before its `make check`. |

A separate `macos-guard` job, as first planned, turned out unnecessary:
`tests/unit/guard_test.sh` runs the guard under whichever older system bash
the machine has (3.2 on macOS, 5.2 on Ubuntu), including the real
`bin/chalk` entry point.

Two composite actions keep the workflow short and the setup in one place:

- `.github/actions/setup-bash`: on macOS, `brew install bash`. On Linux,
  `scripts/install-bash.sh` builds bash 5.3 from the GNU tarball with the
  official patches (5.3.20 today), both checked against pinned sha256
  values, and `actions/cache` keeps the result keyed on that script, so
  only a version bump rebuilds. A source build was chosen over Homebrew on
  Linux because it pulls in no toolchain and its version cannot drift.
- `.github/actions/setup-shellcheck`: the pinned ShellCheck release.

`scripts/install-bash.sh PREFIX` also serves contributors without
Homebrew: build once, then set `CHALK_BASH=PREFIX/bin/bash`.

`make lint` runs ShellCheck (now with `-x`, to follow the test helpers)
and `scripts/lint-conventions.sh`. `make lint-sandbox` runs
`scripts/check-sandbox-syntax.sh`, which refuses to run with anything but a
bash 5.2. `make test` runs `tests/unit/*_test.sh` before `tests/e2e.sh`.

## Behaviour changes

All intentional, all called out in the 0.5.0 release notes:

1. Chalk refuses to run under bash < 5.3 when no newer bash can be found.
2. Sandbox images with bash < 5.2 are rejected at start.
3. A run stopped by SIGTERM exits 143 instead of 130.
4. An unexpected command failure prints the failing command and call stack.
5. `chalk status` lists the most recently active runs first.
6. Start-up of the database, sandbox image and lesson memory happens in
   parallel; a failure names the service that failed.
7. Lesson memory failing to start for any reason, including a missing
   `curl`, skips memory with a warning; a missing `curl` used to stop the
   run.
8. `chalk dashboard` reports a failed database read as "could not read
   telemetry for the dashboard", like bad data.

## Risks

| Risk | Mitigation |
| :-- | :-- |
| `inherit_errexit` or `nullglob` surfaces failures and empty globs that are silently tolerated today | Lands alone as checkpoint 5 with nothing else in the commit; e2e must stay green. |
| A `cd` inside `${ … }` changes Chalk's working directory | Convention C2, lint grep, code review. |
| Parallel start-up interleaves output or hides an error | Per-job logs, printed only on failure, job named in the error. Lands last. |
| Moving files breaks `git blame` | Moves are their own commit with no content changes, so `git log --follow` and blame's move detection work. |
| Users without Homebrew on macOS | Guard error names the exact fix. README updated. |

## Checkpoints

Each checkpoint is one reviewable commit (or a small series), proven by a
test, with `make check` green. The order keeps moves, behaviour changes and
refactors in separate commits.

- [x] **1. Toolchain.** `setup-bash` and `setup-shellcheck` actions, `scripts/install-bash.sh`; every CI job runs under bash 5.3. Proof: each job prints `bash --version` 5.3.x and passes. (Verified locally under 5.3.20 and with actionlint; CI confirms on the pull request.)
- [x] **2. Layout, moves only.** Create `lib/core/`, split `lib/common.sh` into `core/log.sh`, `core/runtime.sh`, `repo.sh`, `state.sh`; move sandbox snippets to `share/sandbox/scripts/`. No content changes beyond the moves and the module list. Proof: e2e green; diff is moves only.
- [x] **3. Guard.** Add `lib/core/guard.sh` and source it first from `bin/chalk`. Proof: `tests/unit/guard_test.sh` covers re-exec via `CHALK_BASH`, arguments, stdin, the marker not leaking, the real entry point, loop prevention, and the error message.
- [x] **4. Formula.** `depends_on "bash"`, shebang pinned, `chalk doctor` reports host bash. Proof: formula `test do` passes in the macOS job.
- [x] **5. Runtime settings.** Shell options, ERR trap, `BASH_TRAPSIG` handler in `core/runtime.sh`; remove now-dead glob guards. Proof: new e2e cases for a TERM'd run exiting 143 and for the ERR trace.
- [x] **6. Config table.** `CHALK_CONFIG_DEFAULTS` associative array drives key checks and defaults. Proof: unit tests for unknown-key warning, environment-over-file precedence, every default.
- [x] **7. Collections and fill functions.** Arrays for lists, `CHALK_SCHEMA`, namerefs for `agent_usage`, `sandbox_otel_args`, `db_ticket_summary`; drop both `SC2086` disables and the empty-array workarounds. Proof: unit test of `agent_usage` on fixture JSON; e2e green.
- [x] **8. Strings and time.** Apply C5 throughout. Proof: unit tests for `sandbox_name` and OTel endpoint rewriting; e2e green.
- [x] **9. Value functions.** Convert to `REPLY` + `${| }`, memoize repository identity. Proof: unit test with a counting `git` fake shows `repo_name` runs git once per process.
- [x] **10. Sandbox floor.** Version check in `sandbox_start`, `make lint-sandbox`, `scripts/lint-conventions.sh`, docs for custom images. Proof: fake `docker` reporting bash 5.1 makes `chalk run` stop with the documented message.
- [x] **11. Smaller 5.3 features.** `source -p` loading, `GLOBSORT` in `chalk status`, dashboard escaping without `sed`/`awk`. Proof: e2e asserts status ordering and dashboard output.
- [x] **12. Background jobs.** `lib/core/jobs.sh` and parallel start-up in `run_open_sandbox`. Proof: `tests/unit/jobs_test.sh` covers ordering, output, a named failure and `die` inside a job; e2e covers start-up logs and a broken database.
- [x] **13. Docs.** `docs/bash-style.md`; `CONTRIBUTING.md` points to it instead of the 3.2 rule; README install notes. The version moves to 0.5.0 when `scripts/release.sh 0.5.0` runs, which sets `CHALK_VERSION` and tags; the release notes list *Behaviour changes*.

## Definition of done

- All checkpoints ticked, CI green on every job.
- `bash 3.2` appears only in `lib/core/guard.sh`, the top of `bin/chalk`
  that runs before it, the lint rule that checks it, and the docs.
- No `shellcheck disable` comments were added; the two `SC2086` disables are gone.
- `docs/bash-style.md` exists and every rule in it is either linted or
  covered by a test.

## Open questions

None. Resolved:

1. `chalk doctor` warns, and does not fail, when the sandbox image's bash
   cannot be checked because Docker is not running.
2. Linux CI builds bash 5.3 from the GNU tarball in a cached step (see
   *Tooling and CI*).
