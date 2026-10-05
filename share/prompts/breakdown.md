Break the Jira epic named below into independent workstreams that separate
agents can build in parallel. Do not modify any files.

Read the epic and its child issues with the Jira tools available to you, and
read this repository so the plan is grounded in the real code.

For each workstream return:

- ticket: the Jira key of the child issue it implements. Use real keys only;
  the key becomes a branch name and is checked in CI.
- title: a short imperative title.
- context: what to build and why, naming the files or modules involved.
- checkpoints: ordered steps. An agent implements one per session with no one
  to ask, and a test command decides whether it is done. So each checkpoint
  must state the behaviour and how a test proves it, and leave every test
  passing: a test and the code that makes it pass go in one checkpoint.

<examples>
Good: "POST /limits returns 429 with a Retry-After header once a client
exceeds 100 requests per minute; covered by a request test."
Good: "TokenBucket.take() refills at the configured rate; unit test with a
fake clock."
Too vague: "Add rate limiting."
Not testable: "Clean up the middleware."
Too large: "Build the admin UI for limits." (split by screen or by endpoint)
</examples>

Workstreams run at the same time on separate branches, so two of them
editing the same files will conflict at merge. If two child issues must
change the same files, put them in one workstream under the first issue's
key. Prefer three to six checkpoints per workstream.
