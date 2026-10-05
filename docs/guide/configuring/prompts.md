# Prompts

Every agent call gets the same system prompt, appended to Claude Code's
own with `--append-system-prompt-file`: Chalk's harness rules (the
`system` prompt) followed by the textbook, `.chalk/textbook.md`, inside
`<engineering_rules>` tags. Each call also has to answer in JSON of a
fixed shape (`--json-schema`), so the harness never parses prose.

| Prompt | Used for |
| :-- | :-- |
| `system` | Sandbox facts and harness rules, with the reasons for them |
| `continue` | A loop on the next checkpoint |
| `retry` | A loop after a failed attempt: root cause first |
| `fix-review` | A loop that fixes final-review findings |
| `spec-check` | Checking checkpoints before a run |
| `review` | The final review |
| `distill` | Turning an office-hours note into a general lesson |
| `breakdown` | Splitting an epic for `chalk fleet` |

The shipped prompts are in
[`share/prompts/`](https://github.com/khalaharvi/chalk/tree/main/share/prompts).

## What a loop's prompt contains

Context comes first, in tags, so that test output and lessons are read as
data; the instructions come last:

```text
<spec_file>specs/PROJ-123.md</spec_file>
<notes_file>specs/PROJ-123.notes.md</notes_file>
<rubric_command>npm test</rubric_command>
<lessons>          up to three recalled lessons, when any match
<review_findings>  for a fix-review loop
<failure>          for a retry: what went wrong in the loop before

(the continue, retry or fix-review prompt)
```

What a retry is told in `<failure>` depends on `CHALK_FP_FEEDBACK`: by
default the reason and the last 60 lines of the rubric's output; with
`true`, the tests that still fail and the first error, normalized, and the last 20
lines.

## Changing a prompt for one repository

```sh
chalk prompts                 # lists the prompts; overridden ones are marked
chalk prompts eject review    # copies share/prompts/review.md to .chalk/prompts/review.md
$EDITOR .chalk/prompts/review.md
git add .chalk/prompts && git commit -m "Tune the review prompt"
```

A file at `.chalk/prompts/NAME.md` replaces the shipped prompt of that
name for the repository.

The reviewer is the one most worth tuning: read
`~/.local/state/chalk/<repo>/runs/<TICKET>/io/review.json` after a few
runs and adjust the prompt where its judgement differs from yours.

## Comparing prompt sets

Every call records a short hash of the prompt set in use: every prompt
that applies to the repository, the textbook and the `CHALK_FP_FEEDBACK`
setting. Change any of them and the [report card](../operating/dashboard.md)
starts a new row under "By prompt set", so you can compare cost per
finished checkpoint and retry share before and after.
