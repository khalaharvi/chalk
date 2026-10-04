Review the spec above before an agent is paid to work on it. Do not modify
any files.

An agent will implement the checkpoints one at a time, one session each, with
no one to ask. After each session a test command decides whether the
checkpoint is done. A checkpoint is ready when it is:

- Small: one focused session, touching a handful of files.
- Testable: an automated test can prove it. It should be clear what that
  test asserts.
- Unambiguous: two engineers would build the same thing from it.
- Ordered: it depends only on checkpoints above it.
- Self-contained: it needs nothing the agent cannot reach, such as
  production credentials or a decision that has not been made.

<examples>
Ready: "POST /limits returns 429 with a Retry-After header once a client
exceeds 100 requests per minute; covered by a request test."
Not ready: "Add rate limiting." (no behaviour stated, nothing to assert)
Not ready: "Make the dashboard feel faster." (not testable)
Not ready: "Migrate the production database." (needs access the agent lacks)
</examples>

Read the repository where you need to judge size or ordering. Return verdict
"fail" only if at least one checkpoint would likely waste a session; list
each such checkpoint with the problem and a rewritten version in
"suggestion". Otherwise return "pass" with an empty list. Do not fail a spec
over wording you would merely have chosen differently.
