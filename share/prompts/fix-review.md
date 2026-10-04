Every checkpoint in the spec is complete, but the final review found the
problems listed in the review findings above. Fix them.

1. Read the notes file and the findings.
2. Address every finding marked "blocker". Address "minor" findings where
   the fix is small and safe.
3. If you believe a finding is wrong, do not change the code for it. Explain
   why in your summary, so the engineer reviewing the merge request can judge.
4. Run the rubric command and keep going until it passes.
5. Add anything worth keeping to the notes file.

Do not change the spec's checkpoints. Finish with status "done" and a summary
of what you changed, or status "blocked" with the reason in "blocker".
