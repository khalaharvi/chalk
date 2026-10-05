# The sandbox

Every run, and every office-hours distillation, gets its own throwaway
container. The agent and the rubric run only there. The code is in
`lib/sandbox.sh`; the scripts that run inside are in
`share/sandbox/scripts/`.

## Container layout

`sandbox_start` runs, in outline:

```sh
docker run -d --name chalk-sandbox-<repo>-<TICKET> \
  --label chalk.repo=<repo> --label chalk.ticket=<TICKET> \
  --user "$(id -u):$(id -g)" \
  --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /work:rw,exec,mode=1777,size=$CHALK_TMPFS_SIZE \
  --tmpfs /home/chalk:rw,exec,mode=1777,size=1g \
  -v <git common dir>:/src.git:ro \
  -v <run io dir>:/chalk \
  -e HOME=/home/chalk -e ANTHROPIC_API_KEY ... \
  $CHALK_IMAGE sleep infinity
```

| Path in the container | What it is |
| :-- | :-- |
| `/src.git` | The host repository's git store, read-only |
| `/work/repo` | The working copy: a `git clone --shared` of the branch on a RAM disk (`/work`, `CHALK_TMPFS_SIZE`, 4 GiB by default) |
| `/home/chalk` | A 1 GiB RAM disk for the agent's home: caches, Claude Code's own files |
| `/chalk` | The run's `io/` directory on the host: the system prompt in, answers and the commit bundle out |

- **Your user, no capabilities.** The container runs as your uid and gid,
  with every Linux capability dropped and no privilege escalation.
- **No forge credentials.** Only the agent credentials
  (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` or
  `ANTHROPIC_AUTH_TOKEN`), `ANTHROPIC_BASE_URL` and the OpenTelemetry
  settings are passed in, by name, so their values never show in `ps`.
  Pushing and opening requests happen on the host.
- **Labels.** `chalk cleanup` finds a repository's containers by the
  `chalk.repo` label.

## Why a RAM disk

The clone borrows objects from the read-only store (`--shared`), so
nothing is copied and starting a sandbox is fast. The working copy and
its dependencies live in memory, so installs and test runs avoid the
slow file sharing between a Mac and Docker's VM, and everything is gone
when the container is removed. Nothing the agent does can touch your
checkout: the only thing that leaves is a git bundle.

## What leaves the sandbox

Four short scripts, run with `docker exec … bash -c`, do the git work:

| Script | Does |
| :-- | :-- |
| `clone.sh BRANCH AUTHOR EMAIL` | Clones the branch into `/work/repo`, committing as you |
| `commit.sh MESSAGE [--allow-empty]` | Commits everything in the tree |
| `export.sh BASE` | Writes the commits since BASE to `/chalk/out.bundle` |
| `reset.sh` | Discards whatever a read-only call left in the tree |

After a passing loop, `run_sync` fetches the bundle on the host and
fast-forwards the branch; it never merges. A detention fetches it into a
new `detention/…` branch instead.

## Bash inside the sandbox

The sandbox scripts are written for bash 5.2, the bash Debian 12 and so
the default image ship. Each starts with the line `# bash 5.2 syntax`,
which the convention lint checks, and CI parses them with a real bash 5.2
(`make lint-sandbox`). When a sandbox starts, `sandbox_check_bash` asks
its bash for its version and stops Chalk with a clear message if it is
older than 5.2.

## Images

`share/sandbox/Dockerfile` builds the default image,
`chalk-sandbox:local`: `node:22-bookworm-slim` with git, ca-certificates,
jq, ripgrep and the `claude` CLI. `chalk sandbox build` (or the first run)
builds it. A custom image, set with `CHALK_IMAGE`, needs bash 5.2 or
newer, git, coreutils and `claude` on `PATH`, and must already exist
locally. [Use your own stack](../guide/configuring/your-stack.md) has
Python and Go examples built `FROM chalk-sandbox:local`.

The rubric and `CHALK_SETUP_CMD` run with `bash -c` (`run_rubric` in
`lib/run.sh`, `sandbox_sh` in `lib/sandbox.sh`). The CI gates run them
with `bash -c` too, so a rubric that relies on bash behaves the same in
the sandbox and in CI.
