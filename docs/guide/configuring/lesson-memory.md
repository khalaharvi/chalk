# Lesson recall

A lesson is what a person said in [office hours](../running/failures.md),
distilled into a rule. Lessons live in the `lessons` table of the
local Postgres database, `chalk-db`, and are matched there, so there is
nothing extra to run and nothing leaves your machine. An optional
[decider](decider.md) adds two steps. Recall is best effort: if the
database cannot answer, the loop runs without lessons.

## The recall ladder

Each loop's prompt gets up to three resolved lessons, from any repository
on your machine, chosen in this order:

1. **The same failure** in this repository: a lesson whose fingerprint
   (the failing tests and the normalized first error) equals the current
   loop's. These always come first.
2. **Similar errors** from any repository, by trigram similarity of the
   first error lines (above 0.5). Lessons recorded before fingerprints
   existed are matched on their stored failure output instead, at a lower
   bar.
3. **Before the first failure**, lessons whose error appears in the spec
   (word similarity above 0.6). Plain similarity between one error line and
   a whole spec would stay near zero.

A lesson scoped to its repository (`repo`, see
[office hours](../running/failures.md#office-hours)) takes part only in
its own repository. Lessons from before scopes existed, and lessons
recorded when distillation was off or failed, are recalled anywhere.

Within each step, the closest matches come first. The number of lessons a
loop was given is recorded with it, so the report card can compare retries
with and without lessons.

A lesson appears in the prompt as the failure it was recorded for and the
fix:

```text
<lessons>
- Seen before: rubric failed (exit 1) FAIL: stray BROKEN file
  Fix: When a test rejects a stray marker file, delete it before committing, because …
</lessons>
```

## With a decider

With a [decider](decider.md) (`CHALK_DECIDER=shadow` or `on`), and once
there are `CHALK_DECIDER_MIN_LESSONS` (30) resolved lessons, the ladder
gets two more steps:

- **The same meaning:** lessons whose failure means the same as the
  current one in other words, by the cosine distance between embeddings
  (`BAAI/bge-small-en-v1.5`, from the local `chalk-embed`), with a
  similarity of at least 0.7. This needs Postgres 17 with pgvector; a
  Postgres 16 database skips it.
- **The decider's choice:** up to 5 candidates, the similar errors first
  and then those with the same meaning, go to the decider in one request,
  one yes-or-no question each: does this lesson apply? Those it answers
  yes at `CHALK_DECIDER_THRESHOLD` or above are kept, most confident
  first. The request is held to 4,000 characters, about 1,300 tokens, so
  that it answers within the loop's
  [2-second budget](decider.md#time): the current failure gets up to
  1,500 of them, and each lesson's failure and fix share the rest.

The same failure always comes first and is never dropped, and a loop
still gets at most three lessons. In `shadow` mode the two new steps only
record their choice, and the prompt gets the lessons the ladder above
found. In `on` mode the prompt gets the same-failure lessons and the
decider's choice. When the decider gives no answer, recall works as
without it.

A lesson's embedding is written when office hours resolves it, or, when
chalk-embed is not running then, the next time the local decider starts.

## Fingerprints

After a failed rubric, the loop is reduced to its
[fingerprint](../operating/dashboard.md#verdicts): the failing tests, from
a test report (`CHALK_TEST_REPORT`: JUnit XML, `go test -json` or
`jest --json`) or the test runner's output, and
the first error line, normalized so that timestamps, addresses, temporary
paths, line numbers and durations do not stop two runs of the same failure
from matching. A detention stores the fingerprint with its lesson; that is
what step 1 matches.

Recall works with any setting of `CHALK_FP_RULES` except `off`, which
computes no fingerprints. Then step 1 is skipped, and lessons are matched
on the failure text.

## Hindsight was removed

Hindsight, the optional lesson server that ran as the `chalk-memory`
container, was removed. Old `CHALK_MEMORY=hindsight` and `CHALK_MEMORY_*`
settings are ignored with a warning. If you ran it, remove it with:

```sh
docker rm -f chalk-memory && docker volume rm chalk-memory-data
```

`chalk memory` prints the same instructions.

## Looking at lessons

```sh
chalk db psql
```

```sql
SELECT ticket, left(signature, 60), lesson, scope, resolved_by
  FROM lessons ORDER BY id DESC LIMIT 10;
```

Open lessons, with no `resolution`, are detentions nobody has resolved
yet; they are never recalled.
