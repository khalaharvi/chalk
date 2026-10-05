# Configuration

`.chalk/config` holds a repository's settings: plain `KEY=value` lines,
with no quotes and no shell expansion. It is read, never executed.
`chalk init` writes it with every key explained in a comment.

- **Precedence:** an environment variable of the same name wins over the
  file, even when it is set to an empty value; a key that is unset or
  empty takes its default.
- **Unknown keys** are ignored with a warning, so a typo does not go
  unnoticed.
- **Removed keys:** the settings of Hindsight, the lesson server that was
  removed (`CHALK_MEMORY=hindsight` and `CHALK_MEMORY_URL`,
  `CHALK_MEMORY_BANK`, `CHALK_MEMORY_TOKENS`, `CHALK_MEMORY_IMAGE`), are
  ignored with one warning. Delete them. See
  [Lesson recall](lesson-memory.md).
- **Checked values:** Chalk stops with a message when `CHALK_FORGE`,
  `CHALK_PERMISSION_MODE`, `CHALK_FP_RULES`, `CHALK_FP_FEEDBACK`,
  `CHALK_MAX_PARALLEL` or `CHALK_SANDBOX_MEM_MB` has a value it does not
  accept, or when auto mode is combined with a Haiku `CHALK_MODEL`.

The rest of this page lists every key in the order of the template,
`share/templates/config`, with the template's own explanation. It is
generated from that file when the site is built, and the build fails if
the template and the defaults in `lib/config.sh` disagree.

<!-- generated: config-reference -->

## Machine settings

These are read from the environment only, never from a repository, so a
repository cannot point your agents' telemetry somewhere else. Generated
from `CHALK_ENV_DEFAULTS` in `lib/config.sh`.

<!-- generated: env-reference -->

See [OpenTelemetry](../operating/dashboard.md#opentelemetry) for the
`CHALK_OTEL_*` settings.

Other environment variables Chalk reads:

| Variable | Meaning |
| :-- | :-- |
| `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_AUTH_TOKEN` | Agent credentials; one is required. `CLAUDE_CODE_OAUTH_TOKEN` comes from `claude setup-token` and uses your Claude subscription; `ANTHROPIC_API_KEY` wins when both are set. Passed into each sandbox by name, so the value never appears in `ps`. See [Sign in to Claude](../../getting-started.md#sign-in-to-claude). |
| `ANTHROPIC_BASE_URL` | Passed into the sandbox when set, for a gateway (usually with `ANTHROPIC_AUTH_TOKEN`). |
| `OTEL_EXPORTER_OTLP_HEADERS` | Passed into the sandbox when set, for a collector that needs credentials. |
| `CHALK_BASH` | The bash 5.3 or newer to re-run Chalk under, when the one that started it is older. |
| `XDG_STATE_HOME` | Where run logs, plans and the report card go: `$XDG_STATE_HOME/chalk`, by default `~/.local/state/chalk`. |

## Custom sandbox images

The default image, `chalk-sandbox:local`, is built from
`share/sandbox/Dockerfile` on the first run: Node 22 on Debian 12, with
git, jq, ripgrep and the `claude` CLI. For other stacks, build an image
with your toolchain plus the `claude` CLI, for example starting `FROM`
that Dockerfile, and set `CHALK_IMAGE`.

A sandbox image needs bash 5.2 or newer, git, coreutils and `claude` on
`PATH`. Chalk checks the bash version when a sandbox starts, and
`chalk doctor` checks it for the configured image. An image other than the
default is never built by Chalk; pull or build it first.
