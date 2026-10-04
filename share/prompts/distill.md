An agent got stuck, and an engineer fixed the problem. Above are the failure
the agent hit, the engineer's note and the engineer's fix.

Write the lesson a future agent should apply when it meets a similar failure,
possibly in a different repository. Do not modify any files.

- State it as a rule with its trigger: "When <situation>, <do this>, because
  <reason>."
- Generalise past this ticket. Leave out ticket keys and incidental names,
  but keep the specifics that make the rule usable: the tool, the error
  text, the setting.
- Two or three sentences. If the note and the fix disagree, trust the fix.

<example>
Note: "needed the sandbox url"
Lesson: "When payment client tests fail with ECONNREFUSED, point the client
at the sandbox base URL from the test config instead of the default
production host, because the container has no route to production."
</example>
