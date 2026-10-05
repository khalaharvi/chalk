# Bash style

Chalk is written for **bash 5.3 on the host** and **bash 5.2 inside the
sandbox**. This guide says how Chalk uses what those versions offer, so
that every feature has one idiom and the code reads the same everywhere.
The reasoning and the verification behind each rule are in
[`specs/bash-5.3.md`](specs/bash-5.3.md).

Rules marked **(lint)** are checked by `scripts/lint-conventions.sh`, which
`make lint` runs. ShellCheck 0.11.0 covers the rest.

## Where each version applies

| Code | Bash | Why |
| :-- | :-- | :-- |
| `lib/core/guard.sh` | 3.2 | Runs before Chalk knows which bash it is under, then re-executes under 5.3. |
| `share/sandbox/scripts/*.sh` | 5.2 | Runs inside the sandbox container. Debian 12, the default image, ships 5.2. |
| Everything else | 5.3 | Host code: `bin/chalk`, `lib/`, `scripts/`, `tests/`. |

The first line of `guard.sh` and of each sandbox script names its version
**(lint)**. CI parses the sandbox scripts with a real bash 5.2
(`make lint-sandbox`) and runs the guard under macOS's bash 3.2.

## Layers

```
lib/core/   shell runtime: log, runtime (options, traps), jobs, system (host profile, locks), guard
lib/        Chalk domain: repo, state, config, db, memory, sandbox, fingerprint, agent
lib/        commands (cmd_*): run, fleet, lifecycle, dashboard, setup
```

A file uses what is loaded before it, never after. `bin/chalk` loads each
layer with `source -p DIR NAME.sh`, which looks only in `DIR`. (`source -p`
does not accept a name containing `/`, hence one loop per directory.)

## C1. How a function returns a result

| Kind | Returns by | Called as | For |
| :-- | :-- | :-- | :-- |
| **Value** | setting `REPLY`, printing nothing | `x="${\| repo_name; }"` | Values computed in bash or cached |
| **Fill** | writing a caller-named variable | `agent_usage "$file" usage` | Several values at once |
| **Stream** | printing to stdout | piped, redirected, or `$( )` | Text for files, `jq`, `psql`, `git` |

- A value function's header comment ends with `-> REPLY`.
- **A value function never returns non-zero (lint).** "No value" is an
  empty `REPLY`, which the caller tests. In bash 5.3 with `inherit_errexit`,
  a `${| … }` whose function fails ends the shell even inside `&&`, `||` or
  `if`, and fires the ERR trap; `$( )` in the same place does not.
  `die` is still fine: it ends Chalk on purpose.
- Value functions run in the calling shell, so they can cache.
  `git_common_dir` asks git once per working directory; with `$( )` the
  cache would vanish with the subshell.

## C2. `${ … }` and `${| … }`

They run in the current shell, not a subshell. So:

- **No `cd` inside one (lint).** It changes Chalk's own directory. Use
  `$( )` or a `( … )` subshell.
- **No `< file` inside one (lint).** `${ <file; }` returns nothing. Use
  `read -r var < file` for a line or `$(<file)` for a whole file.
- Use them for Chalk's own functions. For external commands, `$( )` is
  just as good: the command forks either way.

## C3. Namerefs

- **A nameref local starts with two underscores (lint)**:
  `local -n __usage=$2`. Callers never name a variable with `__`. Without
  this, a caller passing a variable named like the nameref gets a circular
  reference and its value lands in the wrong place.
- When filling an associative array through a nameref, quote the keys:
  `__usage=(["input"]="$x")`. ShellCheck cannot see the nameref's type and
  otherwise reads bare keys as arithmetic.

## C4. Collections

- A list is an indexed array, never a space-separated string.
- A table is an associative array. Module-level tables use
  **`declare -gA`**: a module may be sourced from inside a function (the
  unit tests do), where a plain `declare -A` would create a local.
- Test membership with `[[ -v table[$key] ]]`. Validate keys that come from
  outside first, as `load_config` does.
- Expand as `"${a[@]}"`. Empty arrays are safe under `set -u`; the
  `${a[@]+"${a[@]}"}` workaround is not needed.
- Read lines from a command with `mapfile -t a < <(command)`.

## C5. Strings, time and files

| Use | Not |
| :-- | :-- |
| `${v@U}`, `${v@L}` | `tr '[:lower:]' '[:upper:]'` |
| `${v//[^a-zA-Z0-9_.-]/-}` | `tr -c 'a-zA-Z0-9_.-' '-'` |
| An extglob pattern, e.g. `${v/$loopback/…}` with `loopback='//@(localhost\|127.0.0.1)'` | `sed` on a single value |
| `$EPOCHSECONDS` | `$(date +%s)` |
| `read -r v < file` | `$(cat file)` |
| `${v@Q}` for a value the user may paste into a shell | bare `$v` |

## C6. Errors and signals

`lib/core/runtime.sh` sets `set -Eeuo pipefail` and
`shopt -s inherit_errexit extglob nullglob globskipdots` for every module.

- An unexpected failure prints the command and the call stack, then
  errexit ends Chalk. A function that returns non-zero on purpose is not
  reported.
- `die` is the only way to end Chalk on purpose.
- INT, TERM and HUP exit with `128 + $BASH_TRAPSIG`; EXIT traps still run.
- With `nullglob`, a loop over a glob that matches nothing runs zero
  times. Do not add `[ -e "$x" ] || continue` guards.

## C7. Background work

Only through `lib/core/jobs.sh`:

```bash
jobs_init "$RUN_IO/startup"
jobs_spawn database db_up
jobs_spawn image    sandbox_ensure_image
local -A started
jobs_wait started || …   # started[database], started[image]: exit statuses
```

Each job logs to its own file, replayed when the job ends: stdout on
success, stderr on failure. `die` inside a job ends only that job.

## Tests

- `tests/unit/*_test.sh` test one module each. They source
  `tests/unit/testlib.sh` and load modules with `load core/log repo …`.
- `tests/e2e.sh` runs the whole workflow against the fakes in
  `tests/fakes/`.
- A change to behaviour comes with a test in one of them.
