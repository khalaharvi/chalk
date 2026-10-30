# Glossary

Chalk names its parts after school, so that a run reads like a term: the
agent does its work against a rubric, follows the textbook, ends up in
detention when it is stuck, gets help in office hours, and the term ends
with a report card. On every page of this site, the school terms have a
dotted underline; hover over one to see its definition.

## School terms

Rubric
:   The test command, `CHALK_TEST_CMD`, that decides whether a loop's work is
    acceptable. The harness runs it itself, inside the sandbox, after
    every loop, and again in CI. Only work that passes it is committed.
    *Mechanism:* `run_rubric` in `lib/run.sh`; the `chalk / rubric` gate.

Textbook
:   `.chalk/textbook.md`: your engineering rules, appended to every agent's
    system prompt inside `<engineering_rules>`. It applies to every ticket
    and takes precedence over `CLAUDE.md`.
    *Mechanism:* `agent_write_system` in `lib/agent.sh`.

Detention
:   Where a run stops when it cannot make progress: a reported blocker,
    exhausted retries, the loop limit, a review that still fails, or a
    stopping verdict. The work is parked on a local
    `detention/<TICKET>-<timestamp>` branch, nothing is pushed, and an open
    lesson is logged.
    *Mechanism:* `run_detain` in `lib/run.sh`. See
    [Detention and office hours](../guide/running/failures.md).

Office hours
:   `chalk office-hours -m NOTE`. A person fixes the blocker on the
    detention branch, leaves a note, and the loop resumes. The note
    becomes a lesson.
    *Mechanism:* `cmd_office_hours` in `lib/lifecycle.sh`.

Tutoring
:   The `tutoring/<TICKET>-<timestamp>` branch a run resumes on after office
    hours. The CI gates treat it like a `chalk/` branch.

Lesson
:   A rule distilled from an office-hours note and the fix, stored in the
    `lessons` table and recalled into the prompts of later loops whose
    failures look the same. Its scope says whether it holds in any
    repository (`general`) or only in its own (`repo`).
    *Mechanism:* `office_hours_distill` in `lib/lifecycle.sh`,
    `memory_recall` in `lib/memory.sh`. See
    [Lesson recall](../guide/configuring/lesson-memory.md).

Report card
:   `chalk dashboard`: one static HTML page built from the local `runs`
    table. Its grade is the cost per finished checkpoint.
    *Mechanism:* `lib/dashboard.sh`, `share/dashboard.sql`,
    `share/dashboard.html`. See
    [Verdicts and the report card](../guide/operating/dashboard.md).

Notes for next term
:   The report card's recommendations: plain rules over the numbers, such
    as lowering a spend cap that loops never come near.

## Work

Ticket
:   One unit of work, named by a key like `PROJ-123`. One ticket is one
    branch (`chalk/PROJ-123`), one worktree and one spec.

Spec
:   `specs/<TICKET>.md`: the context and the checkpoints for a ticket.

Checkpoint
:   One line `- [ ] …` in the spec: a step small enough for one loop and
    provable by the rubric. The agent ticks it (`- [x]`) when done.

Spec check
:   A cheap model's check, before the first loop, that every checkpoint is
    small, testable and unambiguous, and leaves the rubric passing on its
    own.

Loop
:   One agent call that works on a checkpoint (`continue`), retries after a
    failure (`retry`) or fixes review findings (`fix-review`), followed by
    the rubric. Each has a spend cap, `CHALK_BUDGET_USD`.

Run
:   One `chalk run`: a sandbox, the spec check, loops, the final review and
    either a pull or merge request or detention.

Final review
:   An independent agent's read-only review of the finished change for
    stubs, weakened tests and drift from the spec.

Sandbox
:   The throwaway container a run works in. See
    [The sandbox](../develop/sandbox.md).

Fleet, epic, workstream
:   `chalk fleet EPIC` splits an epic into workstreams, one ticket each,
    and runs them in parallel.

Forge
:   Where the repository is hosted: GitHub (pull requests, `gh`) or GitLab
    (merge requests, `glab`).

## Verdicts and the future

Fingerprint
:   What a loop reduces to after the rubric runs: the failing tests, the
    normalized first error and the working tree's ID.
    *Mechanism:* `lib/fingerprint.sh`.

Verdict
:   The label a loop that made no progress gets from its fingerprint, such
    as `repeat` or `no_change`. Three of them, `deja_vu`, `repeat` and
    `no_change`, can stop a run early when `CHALK_FP_RULES=on`. See
    [Verdicts](../guide/operating/dashboard.md#verdicts).

Shadow mode
:   A rule records what it would have done and changes nothing.
    `CHALK_FP_RULES=shadow` is the default; the report card shows whether
    turning a rule `on` would pay.

Certified
:   An early stop, a stopping verdict or the decider's confident "stuck",
    that shadow runs have shown right often enough to act: its latest block
    of 46 judged runs had at most one wrongful stop. Under `on`, only a
    certified stop acts. See `chalk certify` and
    [May the verdicts act yet?](../guide/operating/dashboard.md#may-the-verdicts-act-yet).

Probe
:   One command that fails while an environment blocker stands and passes
    once it is fixed, such as `gcc --version`. The agent proposes it with
    its fix; Chalk runs it at detention, after your fix at office hours,
    and before every later run as a need. See
    [Blockers with a fix](../guide/running/failures.md#blockers-with-a-fix).

Need
:   A proved probe saved in `.chalk/needs`, checked before every run's
    first loop (pre-flight) and by `chalk needs`. See
    [Saved needs](../guide/running/failures.md#saved-needs).

Holdout
:   A run, a tenth by default (`CHALK_HOLDOUT`), that keeps certified
    stops in shadow mode, so that they go on being judged after they act.

Harness
:   The coding-agent CLI that runs each loop. Today it is always Claude
    Code.

Decider
:   System 1: a small, fast model that answers bounded questions, such as
    "is this loop stuck?" or "does this lesson apply?", each with a
    confidence, so Chalk does not have to ask Claude. Optional, off by
    default, and in shadow mode until turned on.
    *Mechanism:* `lib/decider.sh`. See [The decider](../guide/configuring/decider.md)
    and [the decider protocol](../decider-protocol.md).

Hindsight
:   An optional lesson-memory server, removed in favour of recall from the
    `lessons` table.

The roadmap's design notes keep the
[same terms](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#terms).
