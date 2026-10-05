# Decider protocol

A decider is a small, fast model that answers bounded questions, such as
"is this loop stuck on the same root cause as the last one?", so that
Chalk does not have to ask Claude. Every decider Chalk talks to, the local
reference service or a hosted endpoint, speaks the protocol on this page,
so Chalk has one client for all of them.

This is **version 1**.

## The shape, and why it is this one

The protocol **is** the HTTP API of
[strands-decider](https://github.com/strands-labs/strands-decider), the
model the local reference service runs, `POST /v1/systemone`, plus two
things Chalk needs from every provider: a version field and a bearer
token. strands-decider serves it unchanged, so the reference service
needs no adapter, and a provider that wants to serve Chalk implements one
documented API rather than a Chalk-only one.

| Option | What Chalk would own | Chosen |
| :-- | :-- | :-- |
| The strands-decider API, plus `protocol` and `Authorization` | The client (`lib/decider.sh`) | yes |
| A Chalk-specific API | The client, plus an adapter in front of strands-decider, kept in step with it | no |

Both additions fit the existing API without changing it: strands-decider
ignores request fields it does not know, and a response with no version
is read as version 1.

## Endpoints

A decider is reached at a base URL, `CHALK_DECIDER_URL`.

| Method and path | Purpose | Required |
| :-- | :-- | :-- |
| `POST /v1/systemone` | Answer the questions about one text | yes |
| `GET /health` | Say that the model is loaded, and which | no; see [Health](#health) |

Chalk checks health only from `chalk decider up`, `chalk decider status`,
`chalk doctor`, a run starting the local service, and office hours before
it writes a lesson's embedding; never during a loop. During a loop, a
decider that is down is found out by its first question.

## Request

```http
POST /v1/systemone HTTP/1.1
Content-Type: application/json
Authorization: Bearer <CHALK_DECIDER_TOKEN>
```

```json
{
  "protocol": 1,
  "state": "previous loop: ...\ncurrent loop: ...",
  "questions": {
    "stuck": {
      "type": "noul",
      "instructions": "Is the agent stuck on the same root cause as in the previous loop?"
    }
  }
}
```

| Field | Type | Meaning |
| :-- | :-- | :-- |
| `protocol` | integer | The protocol version, `1`. A server ignores it if it has only one version. |
| `state` | string | The text the questions are about. Never empty. |
| `questions` | object | One or more questions about `state`, by key. Keys are Chalk's own and come back in the response. |

Each question has a `type` and `instructions`, plus `criteria` for some
types:

| `type` | Asks | `criteria` |
| :-- | :-- | :-- |
| `noul` | Yes, no or unknown: is the statement in `instructions` true of `state`? | Optional: `{"true": "...", "false": "..."}`, what each answer means |
| `choice` | Pick one of the named options | Required: `{"option": "description", ...}`, at least 2 |
| `score` | Rate on an ordered scale, from 0 (the first level) up | Required: `["lowest level", ..., "highest level"]`, 2 to 10 levels |

One request carries every question Chalk has about one text, so a
decider can read the text once. Chalk sends at most 8 questions per
request (the [lesson rerank](#the-questions-chalk-asks)).

A server must ignore request fields it does not know, so that later
versions can add optional fields without breaking it.

## Response

`200 OK` with:

```json
{
  "protocol": 1,
  "model": "strands-decider-2B-hobson-v19",
  "answers": {
    "stuck": {"type": "noul", "noul": 0.96}
  },
  "latency_ms": 141.2
}
```

| Field | Type | Meaning |
| :-- | :-- | :-- |
| `protocol` | integer | Optional; absent means `1`. |
| `model` | string | Which model answered. Chalk records it with every decision. |
| `answers` | object | One answer per question key. A key that is missing is an `unknown` answer. |
| `latency_ms`, `usage` | | Optional, ignored by Chalk, which measures time itself. |

Each answer has the `type` of its question:

| `type` | Fields | How Chalk reads it |
| :-- | :-- | :-- |
| `noul` | `noul`: the probability, 0 to 1, that the statement is true | `yes` when `noul` ≥ 0.5, otherwise `no`, with confidence `max(noul, 1 − noul)` |
| `choice` | `choice`: the option picked; `confidence`: 0 to 1; `probabilities`: per option, optional | the option, with `confidence` |
| `score` | `score`: the expected level, from 0; `confidence`: 0 to 1; `probabilities`, `legend`: optional | the score, with `confidence` |

A `noul` answer has no separate confidence: with two outcomes, the
probability is the confidence. So `noul` = 0.96 is "yes, at 0.96", and
`noul` = 0.02 is "no, at 0.98".

**Unknown.** A decider that cannot answer a question leaves its key out.
Chalk records it as `unknown`, as it does an answer whose confidence is
below `CHALK_DECIDER_THRESHOLD`: neither ever changes a run.

**Calibration.** Chalk acts on an answer only at or above
`CHALK_DECIDER_THRESHOLD`, 0.9 by default. That is safe only if
confidence is calibrated: answers given at 0.9 should be right about 9
times in 10. strands-decider publishes its calibration (an expected
calibration error of 0.05; `noul` answers at 0.9 or more are right about
95% of the time). Every answer is recorded with what happened next, and
the report card shows how often confident answers were right.

## Versions

- A request carries `"protocol": 1`.
- A response may carry `protocol`. With none, it is version 1.
- A response with any other version is treated as no answer, and
  `chalk decider status` and `chalk doctor` name both versions.
- Adding an optional field, a question type or an endpoint does not
  change the version. Changing or removing anything does.

## Authentication

When `CHALK_DECIDER_TOKEN` is set, every request carries
`Authorization: Bearer <token>`. Chalk never writes the token to a log,
the database or a process's arguments (curl reads the header from a file
descriptor). The local reference service listens on 127.0.0.1 only and
needs no token.

## Errors and time

A decider is optional and never holds a run up. Anything other than a
`200` with a readable body is **no answer**, and a loop with no answer
goes on exactly as with `CHALK_DECIDER=off`:

| What happened | Chalk records | Says so |
| :-- | :-- | :-- |
| Could not connect | `unreachable` | no; the decider may simply not be running |
| Could not connect to the local service while it loads its model | `starting` | no |
| No full answer within the time left | `timeout` | no |
| The loop's time was already used up | `budget`, and sends nothing | no |
| The local service was answering other loops for longer than this one could wait | `busy`, and sends nothing | no |
| `401` or `403` | `auth` | a warning, once per run |
| `422` or another `4xx` | `rejected` | no |
| `5xx` | `server` | no |
| Unreadable JSON, or no `answers` | `invalid` | no |
| A `protocol` other than 1 | `version` | a warning, once per run |

Chalk never retries within a loop.

**Concurrent requests.** A fleet's loops may ask at the same time, so a
hosted decider should answer concurrent requests, or queue them within
the time each allows. The local reference service cannot (strands-decider
0.1.0 aborts on Apple's GPU when asked two things at once), so Chalk's
loops take turns at it: each waits at most 1 second for its turn, out of
its budget, and records `busy` if the turn does not come. See
[Several loops at once](guide/configuring/decider.md#several-loops-at-once).

**Time is one budget per loop, not per call.** All the calls one loop
makes to the host services, the stuck question, the lesson embedding and
the lesson rerank, share **2 seconds**. Each call may take whatever is
left of it (curl's `--max-time`); once it is gone, the remaining calls are
skipped and recorded as `budget`. So no loop waits more than 2 seconds,
however many questions it asks.

A decider should answer one request in well under a second. strands-decider
publishes about 150 ms warm on an M3 Pro. `chalk decider up` measures the
local service: if its median is above 1 second, it may record in shadow
mode but cannot act (`on`) on that machine, and `chalk doctor` says why.

## The questions Chalk asks

| Key | Type | Asked when | `state` |
| :-- | :-- | :-- | :-- |
| `stuck` | `noul` | A loop failed and its verdict is `spinning` or `other`, the cases the fingerprint rules cannot settle. Not with `CHALK_FP_RULES=off`. | The failing tests and first error of the previous and the current loop, and a diffstat between their working trees (file names and line counts, no contents), capped at about 1,500 tokens |
| `lesson_<id>` | `noul` | Choosing which past lessons to give the next loop, once there are 30 resolved lessons (`CHALK_DECIDER_MIN_LESSONS`); up to 5 at once | The current failure, then each candidate lesson's failure and fix in its question; 4,000 characters in all |

What each answer can do:

- `CHALK_DECIDER=shadow`: nothing. The answers are recorded in the
  `decisions` table and shown on the report card.
- `CHALK_DECIDER=on`: a `yes` to `stuck` at or above the threshold sends
  the run to detention at once. A `yes` to `lesson_<id>` at or above it
  keeps that lesson in the prompt. A decider can stop a run early; it can
  never give a run more loops.

## What a decider receives

Only what the `state` and `instructions` above hold, and the bearer token:

| Question | `state` | In the questions |
| :-- | :-- | :-- |
| `stuck` | For the failed loop and the one before: up to 20 failing test IDs and the first error line of each, then `git diff --stat` between their working trees (file paths and line counts, at most 41 lines). At most 6,000 characters. | The fixed question |
| `lesson_<id>` | `Current failure:` and up to 1,500 characters of it: its first error and failing test IDs; before the first loop, the start of the spec; when the rubric gave neither, the failure reason and the last lines of the rubric's output, which can quote source lines from a stack trace | Each of up to 5 past lessons: its failure (first error or signature) and the fix note someone wrote, shortened so the whole request is at most 4,000 characters |

Never the repository's files, the changes themselves, or the Claude
credentials. Health checks send nothing of yours (see [Health](#health)).

The local reference service runs on your machine, so with it nothing
leaves the machine. **A decider on another machine gets nothing until
you acknowledge it.** Any `CHALK_DECIDER_URL` (or `CHALK_EMBED_URL`)
whose host is not 127.0.0.0/8, `localhost` or `::1` is sent nothing, not
even a health check, until you run:

```sh
chalk decider trust https://decider.example.com
```

which prints exactly what that address would receive, as in the table
above, and records it as acknowledged. Until then a run goes on with the
decider off and says why, once; `chalk doctor` and `chalk decider status`
say so too, with the same list. `chalk decider untrust URL` takes it back.

## Health

`GET /health` is **optional**. A decider that has it answers `200` with
JSON once the model is loaded, and only `status` is required:

```json
{"status": "ok", "model": "strands-decider-2B-hobson-v19", "device": "mps"}
```

strands-decider also reports its checkpoint and base model, which
`chalk decider status` shows with the revisions it resolved.

When `/health` answers `404` or `405`, Chalk checks the decider with the
smallest real request instead: one `POST /v1/systemone` with a single
`noul` question about a fixed text, with the bearer token:

```json
{"protocol": 1, "state": "Chalk health check.",
 "questions": {"health": {"type": "noul", "instructions": "Is this text a health check?"}}}
```

A `200` with an `answers` object is healthy, whatever the answer. The
probe has 2 seconds of its own, outside any loop's budget, and at the
local reference service it waits its turn like any question (see
[Concurrent requests](#errors-and-time)). Anything else from `/health`,
such as a `503` while the model loads, or no connection, is not healthy,
and nothing is probed. So a decider need not implement `/health`; one
that does is checked without spending a question.

## Embeddings

Semantic lesson recall needs embeddings, which are not part of the
decider protocol: strands-decider does not make them. The local reference
service runs a second, Chalk-owned process for them, `chalk-embed`, with
the OpenAI-compatible API:

```http
POST /v1/embeddings
```

```json
{"input": ["AssertionError: BROKEN exists"], "model": "BAAI/bge-small-en-v1.5"}
```

```json
{
  "object": "list",
  "model": "BAAI/bge-small-en-v1.5",
  "data": [{"object": "embedding", "index": 0, "embedding": [0.0123, -0.0456, ...]}]
}
```

Vectors have 384 dimensions and unit length, so cosine distance is
`1 − dot product`. `GET /health` answers like the decider's, with the
model's `dimensions` and `revision`; it is optional too, and without it
Chalk embeds the one word `health` instead. Embedding calls share the
loop's 2-second budget.

chalk-embed receives the current failure, up to 4,000 characters (the
same text as the `lesson_<id>` question's, before it is cut to 1,500),
and, to store their embeddings, each resolved lesson's failure (up to
1,500 characters) and fix note. An embedding service at a
`CHALK_EMBED_URL` on another machine needs `chalk decider trust` like a
decider.

## Testing a decider

Chalk's tests drive a fake decider, `tests/fakes/curl`, that implements
this page: it checks each request and answers it from a script, so a
change to the protocol fails the tests until the fake follows it. To
check your own service by hand:

```sh
curl -s "$CHALK_DECIDER_URL/v1/systemone" \
  -H 'Content-Type: application/json' \
  -d '{"protocol": 1, "state": "FAILED tests/test_app.py::test_marker",
       "questions": {"q": {"type": "noul", "instructions": "Does a test fail?"}}}'
```
