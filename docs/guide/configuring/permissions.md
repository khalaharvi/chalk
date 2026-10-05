# Permissions

Chalk never needs a `settings.json` allow list. What an agent may do
depends on the kind of call.

- **Loops** run in Claude Code's auto mode (`--permission-mode auto`),
  where a safety classifier reviews actions and no prompts appear. Set
  `CHALK_PERMISSION_MODE=bypass` to use `--dangerously-skip-permissions`
  instead, where your organisation allows it.
- **The spec check, the final review and lesson distillation** run with
  `--permission-mode dontAsk` and an allow list of read tools (`Read`,
  `Grep`, `Glob`) plus `git diff`, `git log`, `git show` and `git status`.
  They cannot edit files or run other commands, and anything they leave in
  the tree is reset before the next call.

Every call also has a spend cap, `--max-budget-usd` set to
`CHALK_BUDGET_USD`, and runs inside the [sandbox](../../develop/sandbox.md),
which has no forge credentials and sees the host repository read-only.

## Auto mode requirements

Auto mode needs a supported model (not Haiku), and an administrator can
disable it. Chalk refuses to start a run with auto mode and a Haiku
`CHALK_MODEL`. If auto mode is unavailable for another reason, Claude Code
starts in manual mode without an error, and in a headless run that means
every edit and command is refused.

`chalk doctor` checks this before you spend anything. It asks the `claude`
CLI in the sandbox image, with your credentials, which permission mode a
loop on `CHALK_MODEL` would start in; this is the Agent SDK's
`initialize` request, answered before any message is sent, so it costs
nothing. The check fails when the answer is manual mode, and says "could
not verify" when Docker or the image is not available. With
`CHALK_PERMISSION_MODE=bypass` it is skipped.

Chalk also logs how many actions were refused in each loop:

```text
[PROJ-123]   4 action(s) were refused by permission checks; see …/io/loop.json
```

When a run is detained after a loop with three or more refusals, its
`next:` line says so and tells you to run `chalk doctor`. A run that makes
no progress with refusals in the log points here. The
[report card](../operating/dashboard.md) adds a note when loops have
actions refused.

Classifier checks add a round trip per shell command and, on Enterprise
and API accounts, can count toward token usage. If routine actions get
blocked, an administrator can describe trusted infrastructure in the
`autoMode` settings; for Chalk, those settings must be in the sandbox
image.

## Compliance note

Chalk produces evidence that supports an ISO/IEC 42001 management system:
per-loop cost and outcome records, a log of human interventions, enforced
test gates and an optional central audit trail (see
[the gates](../operating/merge-request-gates.md)). It does not make a team
compliant by itself. That depends on your policies, risk assessments and
review practice, including people actually reviewing agent-written diffs.
