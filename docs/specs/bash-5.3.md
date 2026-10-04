# Spec: Bash 5.3 on the host, 5.2 in the sandbox

| | |
| :-- | :-- |
| Status | Draft for review |
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

## Target layout

Files are arranged in three layers. A file may use anything from a lower
layer and nothing from a higher one.

```
bin/chalk                    entry point: resolve CHALK_HOME, run the guard, load modules, dispatch

lib/core/                    layer 1: shell runtime, no Chalk knowledge
  guard.sh                   the ONLY file that must parse under bash 3.2; finds bash >= 5.3 and re-execs
  runtime.sh                 shell options, ERR and signal traps, `need`
  log.sh                     info, warn, die, quoting values for display
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

tests/
  e2e.sh                     unchanged role: the whole workflow against fakes
  unit/                      new: focused tests for lib/core and lib/repo
  fakes/

docs/
  bash-style.md              the conventions below, for contributors
  specs/bash-5.3.md          this file
```

What moves where:

| Today | After |
| :-- | :-- |
| `lib/common.sh` `info` `warn` `die` | `lib/core/log.sh` |
| `lib/common.sh` `need` | `lib/core/runtime.sh` |
| `lib/common.sh` repo, ticket and spec helpers | `lib/repo.sh` |
| `lib/common.sh` `state_dir` `run_dir` `run_is_alive` | `lib/state.sh` |
| Inline `bash -c '…'` scripts in `sandbox_clone`, `sandbox_commit`, `sandbox_reset`, `sandbox_export` | `share/sandbox/scripts/*.sh`, run with `docker exec -i … bash -s -- ARGS < script` |
| Module list in `bin/chalk` | Same loop, ordered by layer, using `source -p` |

`lib/common.sh` is removed. The container scripts become real files so they
can be linted and parse-checked under bash 5.2 in CI, which is how the 5.2
boundary is enforced.

## Conventions

These go into `docs/bash-style.md` word for word. Each rule names the
feature it governs and its minimum version.

### C1. Functions return values one of three ways

| Kind | How it returns | How it is called | Example |
| :-- | :-- | :-- | :-- |
| **Value** | Sets `REPLY`, prints nothing | `x=${\| repo_name; }` (5.3) | `repo_name`, `run_dir`, `prompt_file` |
| **Fill** | Writes into a caller-named variable through `local -n` (4.3) | `agent_usage "$file" usage` | `agent_usage`, `sandbox_otel_args`, `db_ticket_summary` |
| **Stream** | Prints to stdout | piped, redirected, or `$( )` | `run_build_prompt`, `db_sql`, anything feeding `jq` |

A value function's header comment ends with `-> REPLY`. A fill function's
header names the variable type it fills (`-> assoc`, `-> array`).

### C2. `${ … }` and `${| … }` (5.3)

- They run in the current shell. **Never `cd`** inside one; use `$( )` or a
  `( … )` subshell when a directory change is needed.
- **Never read a file with `<`** inside one; use `read -r` or `$(<file)`.
- `$( )` remains correct for external commands. Use the new forms only for
  calls to Chalk's own functions, where they save a fork.

### C3. Namerefs (4.3)

- A nameref local starts with two underscores: `local -n __out=$1`.
- No caller variable may start with two underscores. Lint enforces both.

### C4. Collections (4.0+)

- A list of words is an indexed array, never a space-separated string.
- A lookup table is an associative array with `declare -A`. Membership is
  tested with `[[ -v table[$key] ]]`.
- Arrays expand as `"${a[@]}"`. Empty arrays are safe under `set -u` in
  5.x, so the `${a[@]+"${a[@]}"}` workaround is not used.
- Lines from a command go into an array with `mapfile -t a < <(cmd)`.

### C5. Strings and time (5.x)

| Use | Not |
| :-- | :-- |
| `${v@U}`, `${v@L}` | `tr '[:lower:]' '[:upper:]'` |
| `${v//[^a-zA-Z0-9_.-]/-}` | `tr -c 'a-zA-Z0-9_.-' '-'` |
| extglob `${v/@(a\|b)/c}` or `[[ =~ ]]` + `BASH_REMATCH` | a `sed` call on a single value |
| `$EPOCHSECONDS` | `$(date +%s)` |
| `read -r v < file` for one line | `$(cat file)` |
| `${v@Q}` when showing a value the user may paste into a shell | bare `$v` |

### C6. Errors and signals (5.3)

- `lib/core/runtime.sh` sets `set -Eeuo pipefail` and
  `shopt -s inherit_errexit nullglob extglob globskipdots`.
- One ERR trap prints the failing command and the function stack
  (`$BASH_COMMAND`, `FUNCNAME`, `BASH_LINENO`).
- One signal handler exits with `128 + BASH_TRAPSIG`.
- `die` is the only way a function ends Chalk on purpose.

### C7. Background work (5.1)

Only through `lib/core/jobs.sh`:

```bash
jobs_spawn db     db_up
jobs_spawn image  sandbox_ensure_image
declare -A results
jobs_wait results || die "start-up failed: ${ jobs_failed results; }"
```

Each job's output goes to its own log, which is printed only if the job
fails. `die` inside a job ends only that job; the caller reports it by name.

### C8. Version boundaries

- `lib/core/guard.sh` is bash 3.2 syntax and says so in its first line.
- `share/sandbox/scripts/*.sh` is bash 5.2 syntax and says so in its first line.
- Everything else is bash 5.3.

## Feature adoption

| Feature | Min | Where | Replaces |
| :-- | :-- | :-- | :-- |
| `${\| fn; }` value substitution | 5.3 | Every value function's callers (C1) | `$(fn)` forks; enables memoizing `repo_name`, which `db_*` and `sandbox_name` call repeatedly |
| `${ fn; }` substitution | 5.3 | Callers of Chalk functions that print short output | `$(fn)` forks |
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
| `${v@Q}` | 4.4 | Detention instructions in `run_detain`, error messages that echo paths | Unquoted values in copy-paste commands |
| `$EPOCHSECONDS` | 5.0 | `run_detain`, `cmd_office_hours` | `$(date +%s)` |
| `wait -n -p` | 5.1 | `lib/core/jobs.sh` | Sequential start-up in `run_open_sandbox` |
| `patsub_replacement` (default on) | 5.2 | Dashboard data escaping | `sed 's\|</\|<\\/\|g'` + temp file + `awk` splice |

### Considered and not adopted

| Feature | Reason |
| :-- | :-- |
| `array_expand_once` (5.3) | No difference in 5.3.0 for the subscript forms Chalk uses (tested above). Adopting it would be ritual. |
| `SRANDOM` (5.1) | The one random value is the Postgres password; `openssl rand` stays. |
| `read -E` (5.3) | The only prompt is y/N. |
| `compgen -V` (5.3) | Chalk has no shell completion. Revisit if `chalk completion` is added. |
| `EPOCHREALTIME` (5.0) | `runs.duration_s` is `INT`; sub-second timing needs a schema change first. |
| `coproc` (4.0) | Nothing needs a two-way pipe. |

## Bootstrap and packaging

### The guard (`lib/core/guard.sh`)

`bin/chalk` resolves `CHALK_HOME` (existing 3.2-safe code), sources the
guard, and only then sources anything else. The guard:

1. Returns immediately if `BASH_VERSINFO` is 5.3 or newer.
2. Stops with an error if `CHALK_REEXECED` is already set (prevents loops).
3. Tries, in order: `$CHALK_BASH`, `/opt/homebrew/bin/bash`,
   `/usr/local/bin/bash`, `/home/linuxbrew/.linuxbrew/bin/bash`, then every
   `bash` on `PATH`. A candidate qualifies if
   `"$c" -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"'` reports ≥ 5.3.
4. Runs `CHALK_REEXECED=1 exec "$c" "$0" "$@"` with the first match.
5. Otherwise stops with:
   `chalk needs bash >= 5.3 (this is X.Y). Install it with 'brew install bash', or set CHALK_BASH.`

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
| `lint-and-test` (Ubuntu) | `setup-bash` and `setup-shellcheck` (0.11.0, sha256-pinned); `make check` under 5.3. `make lint-floors` calls `/usr/bin/bash`, which is 5.2 on `ubuntu-latest`. |
| `macos` | `setup-bash` (Homebrew's bash); `make test` under it. |
| `macos-guard` (new) | Run `/bin/bash bin/chalk version` with Homebrew bash installed (must re-exec), and with `PATH` and `CHALK_BASH` stripped of any new bash (must print the guard error). |
| `postgres` | `setup-bash`; `make test-db` under 5.3. |

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

`make lint-floors` (new) runs `bash -n` under the bash on `PATH` (5.2 in
CI) over `share/sandbox/scripts/*.sh`, and greps for convention
violations a parser cannot see: nameref locals without the `__` prefix,
`${ <`, and `cd` inside `${ … }` on the same line.

`make test` runs `tests/unit/*.sh` before `tests/e2e.sh`.

## Behaviour changes

All intentional, all called out in the 0.5.0 release notes:

1. Chalk refuses to run under bash < 5.3 when no newer bash can be found.
2. Sandbox images with bash < 5.2 are rejected at start.
3. A run stopped by SIGTERM exits 143 instead of 130.
4. An unexpected command failure prints the failing command and call stack.
5. `chalk status` lists the most recently active runs first.
6. Start-up of the database, sandbox image and lesson memory happens in
   parallel; a failure names the step that failed.

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

- [ ] **1. Toolchain.** `setup-bash` and `setup-shellcheck` actions, `scripts/install-bash.sh`; every CI job runs under bash 5.3. Proof: each job prints `bash --version` 5.3.x and passes. (Done locally under 5.3.20; ticks when CI is green.)
- [ ] **2. Layout, moves only.** Create `lib/core/`, split `lib/common.sh` into `core/log.sh`, `core/runtime.sh`, `repo.sh`, `state.sh`; move sandbox snippets to `share/sandbox/scripts/`. No content changes beyond the moves and the module list. Proof: e2e green; diff is moves only.
- [ ] **3. Guard.** Add `lib/core/guard.sh` and source it first from `bin/chalk`. Proof: `tests/unit/guard.sh` covers re-exec via `CHALK_BASH`, loop prevention, and the error message; the `macos-guard` job passes.
- [ ] **4. Formula.** `depends_on "bash"`, shebang pinned, `chalk doctor` reports host bash. Proof: formula `test do` passes in the macOS job.
- [ ] **5. Runtime settings.** Shell options, ERR trap, `BASH_TRAPSIG` handler in `core/runtime.sh`; remove now-dead glob guards. Proof: new e2e cases for a TERM'd run exiting 143 and for the ERR trace.
- [ ] **6. Config table.** `CHALK_CONFIG_DEFAULTS` associative array drives key checks and defaults. Proof: unit tests for unknown-key warning, environment-over-file precedence, every default.
- [ ] **7. Collections and fill functions.** Arrays for lists, `CHALK_SCHEMA`, namerefs for `agent_usage`, `sandbox_otel_args`, `db_ticket_summary`; drop both `SC2086` disables and the empty-array workarounds. Proof: unit test of `agent_usage` on fixture JSON; e2e green.
- [ ] **8. Strings and time.** Apply C5 throughout. Proof: unit tests for `sandbox_name` and OTel endpoint rewriting; e2e green.
- [ ] **9. Value functions.** Convert to `REPLY` + `${| }`, memoize repository identity. Proof: unit test with a counting `git` fake shows `repo_name` runs git once per process.
- [ ] **10. Sandbox floor.** Version check in `sandbox_start`, `make lint-floors`, docs for custom images. Proof: fake `docker` reporting bash 5.1 makes `chalk run` stop with the documented message.
- [ ] **11. Smaller 5.3 features.** `source -p` loading, `GLOBSORT` in `chalk status`, dashboard escaping without `sed`/`awk`. Proof: e2e asserts status ordering and dashboard output.
- [ ] **12. Background jobs.** `lib/core/jobs.sh` and parallel start-up in `run_open_sandbox`. Proof: `tests/unit/jobs.sh` covers success, a named failure and log capture; e2e green.
- [ ] **13. Docs and release.** `docs/bash-style.md` from *Conventions*; `CONTRIBUTING.md` points to it instead of the 3.2 rule; README install notes; `CHALK_VERSION=0.5.0`; release notes list *Behaviour changes*.

## Definition of done

- All checkpoints ticked, CI green on every job.
- `grep -rn 'bash 3.2' .` finds only `lib/core/guard.sh` and this spec.
- No `shellcheck disable` comments were added; the two `SC2086` disables are gone.
- `docs/bash-style.md` exists and every rule in it is either linted or
  covered by a test.

## Open questions

None. Resolved:

1. `chalk doctor` warns, and does not fail, when the sandbox image's bash
   cannot be checked because Docker is not running.
2. Linux CI builds bash 5.3 from the GNU tarball in a cached step (see
   *Tooling and CI*).
