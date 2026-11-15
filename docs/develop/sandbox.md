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
- **Labels.** `chalk cleanup` finds a repository's containers and
  networks by the `chalk.repo` label.
- **Network.** Open by default: the container can reach anything your
  machine can. `CHALK_EGRESS=allowlist` changes that; see
  [Limiting the network](#limiting-the-network).

## Limiting the network

With `CHALK_EGRESS=open`, an agent that reads something hostile in a
dependency, a web page or an issue could be talked into sending your code,
or the model credential the sandbox holds, anywhere. With
`CHALK_EGRESS=allowlist`, `sandbox_egress_start` gives each sandbox:

- **A network with no route out** (`docker network create --internal`),
  named `<sandbox>-net`. The sandbox is on that network and no other, so a
  direct connection fails and outside names do not resolve.
- **An egress proxy**, a second container named `<sandbox>-egress` from
  the same image, on that network and on Docker's default one. It runs
  `share/sandbox/egress-proxy.js` with node, as your user, with every
  capability dropped, a read-only file system and no credentials.
- **Proxy settings** (`HTTPS_PROXY`, `HTTP_PROXY` and their lower-case
  forms) pointing at the proxy, which Claude Code, npm, pip, curl, git and
  Go follow. A program that ignores them reaches nothing.

The proxy forwards only to the host of the API the agent calls
(`ANTHROPIC_BASE_URL`, or `api.anthropic.com`), to `platform.claude.com`,
where Claude Code renews a subscription's token, and to the hosts in
`CHALK_EGRESS_ALLOW`. HTTPS is tunnelled, never decrypted. A rule is a
host (ports 80 and 443), `HOST:PORT`, or `.DOMAIN` for a domain and every
name under it. A setup command usually needs your package registry:

```ini
CHALK_EGRESS=allowlist
CHALK_EGRESS_ALLOW=registry.npmjs.org
```

When a run ends, it names the hosts the sandbox asked for and was
refused, so a setup command or a loop that failed for want of one says
which to add. `sandbox_stop` removes the proxy and the network with the
sandbox.

What this does not do:

- It limits where the sandbox can send data, not what an allowed host
  receives. Anything the agent can read can still reach the model
  provider, and a registry that accepts uploads is a way out.
- A network that itself needs an HTTP proxy to reach the internet is not
  supported yet: the egress proxy connects directly.
- OpenTelemetry export from the sandbox (`CHALK_OTEL_ENDPOINT`) to a
  collector on your machine does not get out of an allowlisted sandbox.
- The image needs node, which the default image and any image built
  `FROM` it have.

## Why a RAM disk

The clone borrows objects from the read-only store (`--shared`), so
nothing is copied and starting a sandbox is fast. The working copy and
its dependencies live in memory, so installs and test runs avoid the
slow file sharing between a Mac and Docker's VM, and everything is gone
when the container is removed. Nothing the agent does can touch your
checkout: the only thing that leaves is a git bundle.

## What leaves the sandbox

Five short scripts, run with `docker exec … bash -c`, do the git work:

| Script | Does |
| :-- | :-- |
| `clone.sh BRANCH AUTHOR EMAIL` | Clones the branch into `/work/repo`, committing as you |
| `commit.sh MESSAGE [--allow-empty]` | Commits everything in the tree |
| `export.sh BASE` | Writes the commits since BASE to `/chalk/out.bundle` |
| `reset.sh` | Discards whatever a read-only call left in the tree |
| `protected.sh BASE SPEC [PATH...]` | Lists the protected files the tree changes since BASE, and SPEC when more than its ticks changed |

After a passing loop that left the [protected files](../guide/operating/merge-request-gates.md#what-an-agent-may-not-change)
alone, `run_sync` fetches the bundle on the host and
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
