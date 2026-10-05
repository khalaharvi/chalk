# Use your own stack

The default sandbox image has Node 22 and nothing else. A Python, Go or
any other repository needs two images before its first run:

1. **A sandbox image** with your toolchain, built on your machine and
   named in `CHALK_IMAGE`. The agent and the rubric run in it.
2. **A CI image** with the same toolchain, pulled from a registry and
   named in `CHALK_CI_IMAGE`. The `rubric` gate on each pull or merge
   request runs in it.

Skip the second and every pull request fails the `rubric` gate: CI runs
the rubric in `node:22`, which has no `go` or `pytest`.

Chalk publishes no images for other stacks yet; that is
[planned](https://github.com/khalaharvi/chalk/issues/29). Until then,
build one as below.

## What the sandbox can install

Put every tool and system library the rubric needs in the image. The
sandbox cannot add them while it runs:

- **No system packages.** The container runs as your user, not root, with
  every Linux capability dropped and no privilege escalation (see
  [the sandbox](../../develop/sandbox.md#container-layout)), so `apt-get`
  and `sudo` fail.
- **No pip on Debian's Python.** Debian's `python3` has no `pip`, and
  refuses `pip install` outside a virtual environment
  ([PEP 668](https://peps.python.org/pep-0668/)). Making a virtual
  environment needs the `python3-venv` package.
- **Language packages, into writable places only.** The network is open
  and two directories are writable: the working copy, `/work/repo`, and
  the home directory, `$HOME` (`/home/chalk`, a 1 GiB RAM disk). `npm ci`,
  `go mod download` and `pip` inside a virtual environment under `$HOME`
  all work there, if the image has the tool.

The harness commits everything in the working copy, so anything installed
there must be in `.gitignore` (as `node_modules/` usually is). Install into
`$HOME` instead when it is not.

Project dependencies can go in either of two places:

| | In the image | In `CHALK_SETUP_CMD` |
| :-- | :-- | :-- |
| When it runs | Once, when you build the image | At the start of every run, in a fresh sandbox, and in CI |
| Network during runs | Not needed | Needed |
| When dependencies change | Rebuild the image | Nothing to do: each run installs from the branch's own files |
| In CI | The CI image needs them too | Installs them in the CI image as well |

## Build the base image

Start `FROM chalk-sandbox:local`, the default image. Build it once:

```sh
chalk sandbox build      # builds chalk-sandbox:local from share/sandbox/Dockerfile
```

It is `node:22-bookworm-slim` (Debian 12, bash 5.2) with git, jq, ripgrep
and the `claude` CLI. The first `chalk run` also builds it, but only when
`CHALK_IMAGE` is the default, so on another stack build it yourself. Run
`chalk sandbox build` again, then rebuild your image, to update the
`claude` CLI.

Any other base works if it has bash 5.2 or newer, git, coreutils and
`claude` on `PATH`.

## Python

Keep the Dockerfile in the repository, for example at
`.chalk/Dockerfile`. This one installs Python 3 and the project's
`requirements.txt` into a virtual environment first on `PATH`:

```dockerfile
FROM chalk-sandbox:local

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv \
 && rm -rf /var/lib/apt/lists/*

# Dependencies go into a virtual environment first on PATH, so `python3`
# and `pytest` find them. Rebuild the image when requirements.txt changes.
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt
ENV PATH=/opt/venv/bin:$PATH
```

Build it from the repository root, so `requirements.txt` is in the build
context, and point Chalk at it:

```sh
docker build -f .chalk/Dockerfile -t chalk-sandbox-python:local .
```

```ini
CHALK_IMAGE=chalk-sandbox-python:local
CHALK_TEST_CMD=python3 -m pytest -q
CHALK_SETUP_CMD=
```

The virtual environment belongs to root, so neither the agent nor the
rubric can add to it. To install the dependencies at run time instead,
keep only `python3` and `python3-venv` in the image and make the
environment under `$HOME`:

```ini
CHALK_SETUP_CMD=python3 -m venv $HOME/venv && $HOME/venv/bin/pip install -r requirements.txt
CHALK_TEST_CMD=$HOME/venv/bin/python -m pytest -q
```

Both commands run under bash, which expands `$HOME`, in the sandbox and
in CI.

## Go

`go test -race` needs cgo, and so a C compiler and the C library headers:
`gcc` and `libc6-dev`. Without them it stops with
`go: -race requires cgo; enable cgo by setting CGO_ENABLED=1`.

```dockerfile
FROM chalk-sandbox:local

RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev make \
 && rm -rf /var/lib/apt/lists/*

COPY --from=golang:1.23-bookworm /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH
```

```sh
docker build -f .chalk/Dockerfile -t chalk-sandbox-go:local .
```

```ini
CHALK_IMAGE=chalk-sandbox-go:local
CHALK_SETUP_CMD=go mod download
CHALK_TEST_CMD=go vet ./... && go test -race ./...
```

Modules and the build cache go under `$HOME/go` and `$HOME/.cache`,
which are writable, so `CHALK_SETUP_CMD` fetches the modules at the start
of each run. Change `golang:1.23-bookworm` to the Go version in your
`go.mod`.

## Check the image

Set `CHALK_IMAGE` in `.chalk/config`, then:

```sh
chalk doctor
```

It reports `sandbox image` when the image exists locally and
`sandbox bash 5.2+` when its bash is new enough for the scripts Chalk
runs inside it. Each run checks the bash again when its sandbox starts.
Chalk never builds or pulls an image other than the default; when
`CHALK_IMAGE` names one that is missing, the run stops and says so.

## The CI image

The `rubric` gate re-runs `CHALK_SETUP_CMD` and `CHALK_TEST_CMD` in CI,
in the image named by `CHALK_CI_IMAGE`, `node:22` unless you set it. CI
pulls that image from a registry, so the sandbox image you built locally
cannot be used as it is. Either:

- **Push your sandbox image** to a registry your CI can pull from, for
  example `ghcr.io/ORG/chalk-sandbox-go:1`. CI then has exactly the tools
  the sandbox had. A private image needs registry credentials on the job.
- **Use an official toolchain image** with the same language version,
  such as `golang:1.23-bookworm` (which has gcc) or
  `python:3.12-bookworm`. Dependencies that the sandbox image has built in
  must then come from `CHALK_SETUP_CMD`, as in the run-time Python
  example above.

The image needs bash: CI runs both commands with `bash -c`, as the sandbox
does, so a rubric that relies on bash (`set -o pipefail`, `[[ ]]`)
behaves the same in both. Debian and Ubuntu based images have it; Alpine
images do not, and the job stops with "CHALK_CI_IMAGE needs bash".

On **GitHub**, `CHALK_CI_IMAGE` is a repository variable (Settings,
Secrets and variables, Actions, Variables):

```sh
gh variable set CHALK_CI_IMAGE --body golang:1.23-bookworm
```

On **GitLab**, it is set under `variables:` in
`.gitlab/chalk.gitlab-ci.yml`; edit it there, or set a CI/CD variable of
the same name, which takes precedence:

```yaml
variables:
  CHALK_CI_IMAGE: golang:1.23-bookworm
```

`chalk init` reminds you of this, and asks for it as an action when
`CHALK_IMAGE` is already set to something other than the default. See
[Pull and merge request gates](../operating/merge-request-gates.md) for
the rest of the gates.
