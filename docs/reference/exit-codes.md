# Exit codes

Every `chalk` command ends with a status that says what happened, so that
a script, CI or another agent can tell "a person is needed" from "Chalk
broke" without reading the output.

| Code | Meaning | What to do |
| :-- | :-- | :-- |
| `0` | The command did what it was asked. For `chalk run` and `chalk office-hours`: every checkpoint is done, and the request is open or ready for `chalk submit`. | Nothing |
| `1` | Chalk itself failed: an unexpected error, or a step that could not be completed, such as a push that was refused. | Read the message; it is a bug or a broken step, not a verdict on the work |
| `2` | The command line was wrong. | Fix the arguments; `chalk help` lists them |
| `3` | The run went to [detention](glossary.md#detention): it stopped because it could not make progress, and the work is parked on a local `detention/…` branch. | Fix the blocker and run `chalk office-hours`; the line starting `next:` says what the run needs |
| `4` | Nothing was attempted, because something is not ready: a tool, credential, image or service is missing, the configuration is invalid, the repository is not in the state the command needs (uncommitted changes, a missing spec, a run already active), a required `chalk doctor` check failed, or the spec check refused the checkpoints. | Fix what the message names and run the command again. No loop ran, so nothing is parked |
| `5` | `chalk fleet` launched some tickets of the plan and not others: they are waiting for a free slot, or could not be launched. | Run the same `chalk fleet` command again when a slot frees up |
| `128 + n` | Chalk was stopped by signal `n`, as a shell reports it: 130 for Ctrl-C, 143 for `kill`. A run stopped this way still parks its work. | See [When a run fails](../guide/running/failures.md) |

Notes:

- `chalk run --detach` and `chalk office-hours --detach` exit `0` once the
  run has started in the background. How that run ends is in its log
  (`chalk logs TICKET`) and in `chalk status`.
- A run that crashes after its first loop parks its work on a detention
  branch, as a detained run does, but still exits `1` or `128 + n`: the
  status says why it stopped, and the log says where the work is.
- Codes `3` and `4` both mean a person, or an agent acting for one, has
  something to do. The difference is whether work was done and parked
  (`3`) or nothing was spent (`4`).

In the code these are `CHALK_EXIT_*` in `lib/core/log.sh`, with `die`
(`1`), `die_usage` (`2`) and `die_unready` (`4`) to end Chalk with them.
