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
