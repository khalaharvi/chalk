# Operating Chalk from another agent (A2A)

`chalk a2a up` starts a small server that speaks the
[Agent2Agent protocol](https://a2a-protocol.org/latest/specification/)
(A2A) 1.0, so that another agent can do what you do at the terminal: hand
Chalk a ticket and its spec, watch the run, answer a detention, and
cancel. It is optional, and nothing else in Chalk needs it.

It is a thin front end. Everything it does, it does by running the same
`chalk` and `git` commands you would, and everything it knows about a run
comes from [`chalk status --json`](../../reference/json-output.md). The
harness still runs the rubric itself, still reviews the work, and still
opens a request for a person to read.

## Start it

```sh
cd your-repository
export ANTHROPIC_API_KEY=...     # or CLAUDE_CODE_OAUTH_TOKEN, as for chalk run
chalk a2a up                     # needs uv; listens on http://127.0.0.1:8473/
chalk a2a token                  # the bearer token a caller must send
chalk a2a status
chalk a2a down
```

- **One server, one repository.** It serves the repository it was started
  in. For a second repository, set `CHALK_A2A_PORT` to another port.
- **This machine only.** It listens on 127.0.0.1 and nowhere else. There is
  no setting to change that.
- **A token for every call.** `chalk a2a token` prints it, and creates it
  on first use in a file only you can read. Anyone who holds it can start
  runs, which spend money and execute code in sandboxes, and can commit a
  patch to a detained run's branch. Give it only to agents you would let
  type `chalk run` for you.
- **Your shell's environment.** The runs it starts take their credentials
  and `CHALK_*` settings from the shell that ran `chalk a2a up`.

A caller finds everything else in the Agent Card, which needs no token:

```sh
curl -s http://127.0.0.1:8473/.well-known/agent-card.json
```

## What a task is

A task is one ticket's journey to a pull or merge request.

| Task state | What it means in Chalk |
| :-- | :-- |
| `TASK_STATE_WORKING` | A run of the ticket is alive |
| `TASK_STATE_COMPLETED` | Every checkpoint is done and the request is open (or ready for `chalk submit`). The task's artifact holds the request's address and the outcome record |
| `TASK_STATE_INPUT_REQUIRED` | The run went to [detention](../running/failures.md), or the spec check refused the checkpoints. The status message says why, what the run needs, and what to send |
| `TASK_STATE_FAILED` | Nothing could be attempted, such as missing credentials, or Chalk itself failed |
| `TASK_STATE_CANCELED` | The caller cancelled it. Unfinished work stays parked on a `detention/…` branch |

Every status message has a text part for a reader and, once a run has
ended, a data part with the [outcome record](../../reference/json-output.md).

## The calls

Send JSON-RPC 2.0 to `/` with two headers, `Authorization: Bearer <token>`
and `A2A-Version: 1.0`.

**Start a ticket** with `SendMessage` and no `taskId`. A data part names
the ticket and carries its spec:

```sh
curl -s http://127.0.0.1:8473/ \
  -H "Authorization: Bearer $(chalk a2a token)" -H "A2A-Version: 1.0" \
  -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0", "id": 1, "method": "SendMessage",
  "params": {
    "message": {
      "messageId": "m-1", "role": "ROLE_USER",
      "parts": [{"data": {
        "ticket": "API-7", "title": "Add rate limiting",
        "spec": "# API-7: Add rate limiting\n\n## Context\nPublic endpoints have no rate limit.\n\n## Checkpoints\n- [ ] Token bucket with unit tests in src/middleware/limiter.ts\n- [ ] Wire the limiter into the router, with a test for the 429 response\n"
      }}]
    },
    "configuration": {"returnImmediately": true}
  }}'
```

The server creates the worktree with `chalk new`, commits the spec and
starts `chalk run`. A text part works too, when it starts with the ticket
key and holds a `- [ ]` checkpoint list. A ticket that is new must come
with a spec.

As A2A requires, `SendMessage` waits until the task has ended or needs
input, which for a run can be a long time. With
`"returnImmediately": true` it answers at once, and you poll.

**Watch it** with `GetTask` (`{"id": "<task id>"}`), or list every task
with `ListTasks`, which filters by `contextId` and `status` and pages with
`pageSize` and `pageToken`.

**Answer a detention** with `SendMessage` to the same task. This is office
hours, held by the caller:

```json
{"message": {"messageId": "m-2", "taskId": "<task id>", "parts": [
  {"text": "The payments client needs the sandbox base URL in tests."},
  {"data": {"patch": "<a unified diff to apply to the parked work>"}}
]}}
```

- The text is recorded as the office-hours note, and is distilled into a
  [lesson](../configuring/lesson-memory.md) for later runs, as yours would
  be. It is required.
- `patch`, if given, is applied to the detention branch and committed
  before the run resumes. `spec`, if given, replaces the spec.
- When the spec check refused the checkpoints, the answer must carry a
  rewritten `spec`, and needs no note.

**Cancel** with `CancelTask`. A run that is alive is stopped with
[`chalk stop`](../../reference/commands.md), which parks its work.

## What it does not do

- **No streaming and no push notifications.** The card says so, and
  `SendStreamingMessage`, `SubscribeToTask` and the push-notification
  methods answer with A2A's errors for an unsupported operation. Poll with
  `GetTask`.
- **No messages to a run that is under way.** A run takes input only when
  it has stopped and asked.
- **No remote callers.** To reach it from another machine you would have
  to put something in front of it yourself, and that something would then
  hold the power to run code here.
- **No second check on the answer.** A caller that answers detentions
  stands where you stand at office hours. The rubric, the review and the
  [protected files](merge-request-gates.md#what-an-agent-may-not-change)
  still apply to what the run does next, but the caller's own patch is
  committed as an engineer's would be. The request Chalk opens is still
  for a person to review.

## Where things are kept

Under `~/.local/state/chalk/<repo>/a2a/`: the token, the server's log
(`server.log`), its pid, and one JSON file per task in `tasks/`, so tasks
outlive a restart. `chalk cleanup --all` stops the server and removes them.
