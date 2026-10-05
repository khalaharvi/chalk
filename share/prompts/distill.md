An agent got stuck, and an engineer fixed the problem. Above are the failure
the agent hit, the engineer's note and the engineer's fix to this
repository.

Write the lesson a future agent should apply when it meets a similar
failure. Do not modify any files.

The note is the source of truth about what was wrong and what changed
where. The fix diff shows only what the engineer committed to this
repository. Part or all of a fix can be outside it: the sandbox image, the
environment, a credential, access, a CI variable. A partial or empty diff
is not a gap to fill: do not invent a mechanism that would explain it. If
the note and the diff disagree about the repository's code, trust the diff;
about anything outside the repository, trust the note. A wrong lesson costs
more than none, because later agents act on it.

- State it as a rule with its trigger: "When <situation>, <do this>, because
  <reason>." Use only facts the failure, the note or the diff shows.
- Keep the specifics that make the rule usable: the tool, the error text,
  the setting. Leave out ticket keys.
- Two or three sentences.

Set "scope" to how far the lesson holds:

- "general": in any repository. It is about a tool, a library or a
  language, and nothing in it depends on this repository.
- "repo": only here. It depends on this repository's code, layout,
  configuration, sandbox image or environment. It is recalled only in this
  repository.
- "none": the evidence supports no rule an agent could act on, for example
  a one-off fix outside the repository. Leave "lesson" empty. The note is
  still kept.

<examples>
Note: "jest hung after the tests passed; a test left an interval running,
now cleared in afterAll"
Lesson: "When jest reports every test passed but does not exit, find the
timer or socket a test leaves open and close it in afterAll, because jest
waits for open handles."
Scope: general

Note: "needed the sandbox url"
Lesson: "When payment client tests fail with ECONNREFUSED, point the client
at the sandbox base URL from the test config instead of the default
production host, because the container has no route to production."
Scope: repo

Note: "the registry token had expired; rotated it in the runner settings"
Fix diff: none
Lesson: "When installing dependencies fails with 401 from the package
registry, report a blocker asking for the registry token to be rotated,
because the token is set outside the repository."
Scope: repo
</examples>
