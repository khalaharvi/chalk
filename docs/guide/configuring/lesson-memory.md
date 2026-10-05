# Lesson recall

A lesson is what a person said in [office hours](../running/failures.md),
distilled into a general rule. Lessons live in the `lessons` table of the
local Postgres database, `chalk-db`, and are matched there, so there is
nothing extra to run and nothing leaves your machine. Recall is best
effort: if the database cannot answer, the loop runs without lessons.

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
computes no fingerprints. Then only steps 2 and 3, on the failure text,
remain.

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
SELECT ticket, left(signature, 60), lesson, resolved_by
  FROM lessons ORDER BY id DESC LIMIT 10;
```

Open lessons, with no `resolution`, are detentions nobody has resolved
yet; they are never recalled.
