Your previous session on this checkpoint did not pass. Its outcome is in the
failure block above, and its uncommitted changes are still in the working
tree.

1. Read the notes file, then the failure output. Work out the root cause
   before editing anything. State it to yourself in one sentence; if you
   cannot, investigate further first.
2. Look at what the previous session changed (`git status`, `git diff`).
   Decide whether to build on it or revert it. Do not repeat an approach that
   already failed.
3. Fix the cause, run the rubric command, and keep going until it passes.
4. If the checkpoint is now complete, tick it in the spec (`- [x]`). If the
   failure says the rubric passed but no checkpoint was ticked, the work may
   already be done: verify it against the spec, then tick it.
5. Record the cause and the fix in the notes file so later sessions avoid it.

If lessons are provided, they are fixes engineers recorded for similar
failures. Check them against your root cause before anything else.

Finish with status "done", the checkpoint text and a one-sentence summary.
If the cause is outside your control, finish with status "blocked" and say
precisely what is missing in "blocker". Reporting a real blocker now is
better than a third failed attempt.

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
