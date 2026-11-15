# JSON output

For a script, CI or another agent that operates Chalk, three commands
answer in JSON, so that nothing has to be read out of a log written for
people. Together with the [exit codes](exit-codes.md), this is the whole
interface an operator needs: start a run, learn how it ended, and learn
what to do next.

Every object has a `schema` field, now `1`. It goes up when a field is
renamed or removed, never when one is added, so ignore fields you do not
know.

## `chalk run --json` and `chalk office-hours --json`

With `--json`, everything Chalk normally prints goes to stderr, and stdout
carries exactly one line when the command ends: the run's **outcome
record**.

```json
{
  "schema": 1,
  "ticket": "API-7",
  "run_id": "API-7-1794755644",
  "outcome": "detained",
  "exit_code": 3,
  "kind": "blocked",
  "reason": "agent reported a blocker",
  "detail": "needs the staging API key",
  "next": "provide what the agent asked for above, such as a credential, access or a decision",
  "branch": "chalk/API-7",
  "detention_branch": "detention/API-7-1794755644",
  "request_url": null,
  "loops": 2,
  "cost_usd": 0.5,
  "fixes": 0,
  "ended_at": "2026-11-15T15:14:05Z"
}
```

| Field | What it holds |
| :-- | :-- |
| `outcome` | How the run ended; see the table below |
| `exit_code` | The status the command ended with |
| `kind` | For a detention, why: `blocked`, `failed`, `loop_limit`, `review`, `review_error`, `agent_error`, `passed`, `protected`, `sync`, `deja_vu`, `repeat`, `no_change` or `stuck`. Otherwise `null` |
| `reason` | One line saying what happened |
| `detail` | More, when there is more: the agent's own blocker, the review's findings, the spec check's objections, the protected files |
| `next` | What to do about it, the same line the log prints after `next:` |
| `branch` | The branch the run worked on |
| `detention_branch` | The local branch the unfinished work is parked on, or `null` |
| `request_url` | The pull or merge request that was opened, when the forge's CLI printed its address, or `null` |
| `loops`, `cost_usd`, `fixes` | The ticket's totals so far: agent loops, spend, and office-hours fixes. `null` when the telemetry database could not be read |
| `ended_at` | When the run ended, in UTC |

| `outcome` | `exit_code` | Meaning |
| :-- | :-- | :-- |
| `submitted` | 0 | Every checkpoint is done and the request is open |
| `ready` | 0 | Every checkpoint is done; `CHALK_AUTO_MR` is off, so `chalk submit` opens the request |
| `detained` | 3 | The run could not make progress. The work is on `detention_branch`; fix the blocker there and run `chalk office-hours` |
| `spec_blocked` | 4 | The spec check refused the checkpoints before any loop. `detail` lists its objections |
| `unready` | 4 | Nothing was attempted: a tool, credential, image, service or setting is missing or wrong, or the repository is not in the state the command needs |
| `stopped` | 128 + n | A signal stopped the run. Work since the last checkpoint is on `detention_branch`, when there was any |
| `failed` | 1 | Chalk itself failed |
| `usage` | 2 | The command line was wrong |
| `started` | 0 | Only from `--detach`: the run is under way in the background. The record holds `pid` and `log` in place of the fields above |

A command that ends before any run starts, such as one refused for
uncommitted changes, still prints a record, with only `schema`, `ticket`,
`outcome`, `exit_code` and `reason`.

The record of the latest run is also kept as `outcome.json` in the run's
directory under `~/.local/state/chalk/<repo>/runs/<TICKET>/`, whether or
not `--json` was given. A new run removes it when it starts.

## `chalk status [TICKET] --json`

An array with one object per ticket, most recently active first, or the
one ticket named. A ticket with no run gives an empty array.

```json
[
  {
    "schema": 1,
    "ticket": "API-7",
    "state": "detained",
    "running": false,
    "pid": null,
    "loops": 2,
    "cost_usd": 0.5,
    "fixes": 0,
    "detentions": ["detention/API-7-1794755644"],
    "log": null,
    "outcome": { "schema": 1, "outcome": "detained", "…": "…" }
  }
]
```

| Field | What it holds |
| :-- | :-- |
| `state` | What the table shows: `running`, `submitted`, `detained`, `spec-blocked`, `done`, `stopped` or `new` |
| `running`, `pid` | Whether a run of the ticket is alive now, and its process |
| `detentions` | The ticket's detention branches, by name |
| `log` | The log of the latest background run, or `null` when there was none |
| `outcome` | The latest run's outcome record, as above; `null` while a run is alive and before any has ended |

`state` comes from the telemetry database and `outcome` from the run's own
record, so `outcome` is the one to act on: it is there even when the
database could not be written.

## Operating a run from a program

```sh
chalk new API-7 "Add rate limiting"        # then write and commit specs/API-7.md
chalk run --detach --json                  # {"outcome":"started","pid":…}
chalk status API-7 --json                  # poll until .[0].running is false
# .[0].outcome.outcome == "detained":
git switch "$(chalk status API-7 --json | jq -r '.[0].outcome.detention_branch')"
# fix what .outcome.next and .outcome.detail name, commit, then:
chalk office-hours -m "what was wrong" --detach --json
chalk stop API-7                           # to give up on a run that is under way
```
