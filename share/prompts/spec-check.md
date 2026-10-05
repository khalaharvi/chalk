Review the spec above before an agent is paid to work on it. Do not modify
any files.

An agent will implement the checkpoints one at a time, one session each, with
no one to ask. After each session a test command, the rubric, decides
whether the checkpoint is done. The harness commits a checkpoint only when
the whole rubric passes, so a checkpoint that leaves a test failing can
never land. A checkpoint is ready when it is:

- Small: one focused session, touching a handful of files.
- Testable: an automated test can prove it. It should be clear what that
  test asserts.
- Unambiguous: two engineers would build the same thing from it.
- Ordered: it depends only on checkpoints above it.
- Green on its own: once it is done, the rubric passes, without any later
  checkpoint. "Write the failing test" followed by "make it pass" fails
  this: merge the test and the code that makes it pass into one checkpoint.
- Self-contained: it needs nothing the agent cannot reach, such as
  production credentials or a decision that has not been made.

<examples>
Ready: "POST /limits returns 429 with a Retry-After header once a client
exceeds 100 requests per minute; covered by a request test."
Not ready: "Add rate limiting." (no behaviour stated, nothing to assert)
Not ready: "Make the dashboard feel faster." (not testable)
Not ready: "Migrate the production database." (needs access the agent lacks)
Not ready: "Add a test that totals match the legacy export.", then "Fix the
rounding." (the test fails until the second checkpoint; make it one:
"Fix the rounding so totals match the legacy export; covered by a test
over the legacy invoices.")
</examples>

Read the repository where you need to judge size, ordering or whether the
rubric can pass after a checkpoint. Return verdict "fail" only if at least
one checkpoint would likely waste a session; list each such checkpoint with
the problem and a rewritten version in "suggestion". Otherwise return
"pass" with an empty list. Do not fail a spec over wording you would merely
have chosen differently.
