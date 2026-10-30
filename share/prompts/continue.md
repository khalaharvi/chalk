Implement the next checkpoint of the spec.

1. Read the notes file if it exists. It holds what earlier sessions learned
   about this ticket, so you do not need to rediscover it.
2. Read the spec and take the first unchecked checkpoint (`- [ ]`). Work on
   that one only. Small steps keep every commit reviewable and let the
   harness tell exactly which step failed.
3. Write or update a test that fails for the right reason, then implement
   until it passes. The test and the code that makes it pass belong to the
   same checkpoint. If this checkpoint cannot leave the rubric passing on
   its own, for example because it only adds a test that the next
   checkpoint makes pass, do the next one too, tick both, and say so in
   your summary.
4. Run the rubric command and keep going until it passes.
5. Tick that checkpoint in the spec (`- [x]`).
6. Update the notes file: where the relevant code lives, decisions you made
   and why, and anything the next session should know. Keep it short and
   current. Replace stale notes; do not append a diary.

If lessons are provided, they are fixes engineers recorded for similar
failures. Apply the ones that fit.

Finish with status "done", the checkpoint text and a one-sentence summary.
If you cannot finish because of something outside your control (missing
credentials, an unavailable service, a spec that contradicts itself or the
code), finish with status "blocked" and say precisely what is missing in
"blocker". An engineer will read that sentence and nothing else, so make it
specific enough to act on.

When you finish "blocked", also propose the fix in "fix", so that the
engineer can act on it at once:

- "kind": "image" when the sandbox lacks a tool or system package,
  "config" when the setup command or the rubric timeout is wrong, "spec"
  when the spec contradicts itself or the code or asks for the impossible,
  "credential" for missing access, "decision" for a choice only a person
  can make.
- "why": one or two sentences with the evidence: the error line, or the
  measurement.
- For "image": "image", the packages or Dockerfile lines it needs, such as
  `apt-get install -y gcc libc6-dev`.
- For "config": "config", the settings to change. Only CHALK_SETUP_CMD and
  CHALK_RUBRIC_TIMEOUT may be proposed.
- For "image" and "config": "probe", one shell command that fails now and
  will pass once the environment is fixed, such as `gcc --version` or
  `python3 -c 'import yaml'`. It runs again before later runs to check the
  environment, so it must only read, never change anything.
- For "spec": "patch", a unified diff of the spec file and nothing else.
