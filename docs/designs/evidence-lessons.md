# Design: Evidence-carrying lessons

Status: APPROVED by the maintainer on 2026-10-30 (Thesis 2 of the paper, one PR)
Mode: Builder
Paper: [docs/paper/main.tex](../paper/main.tex), Section 5
Builds on: [blocker-ladder.md](blocker-ladder.md) (PR 1 and the needs half of PR 4)
Stacked on: [certified-stops.md](certified-stops.md)

## Problem Statement

All 4 blockers in Chalk's 51 real runs were environment problems, and in
each one the agent's blocker text already named the fix. Yet the run
printed a generic `next:` line, and distillation learned "report missing
gcc as a blocker" rather than "this repository's image needs gcc". Lessons
stored as prose and validated by a model learn the wrong thing silently,
and nothing ever checks them again.

## What Makes This Cool

A lesson about the environment becomes a regression test for the
environment. One command, the probe:

- proves the blocker real at detention, with no model involved;
- proves the fix at office hours, in a fresh sandbox, before the lesson
  may be recalled;
- guards every later run as a saved need, before any loop spend;
- retires the lesson when the environment no longer needs the fix.

## Premises

1. **Only proved lessons with a probe are recalled.** A lesson whose probe
   failed before the fix and passed after it is `proved`, and its recalled
   text says so. `unproved` and `retired` lessons are never recalled.
   Lessons without a probe are recalled as before.
2. **The agent proposes, you dispose.** The fix is shown; nothing is
   applied. `--accept` (blocker-ladder PR 2) is a follow-up.
3. **Rules are explicit.** A fix's kind is one of image, config, spec,
   credential or decision. Only image and config fixes have a probe. A
   config fix may name only `CHALK_SETUP_CMD` and `CHALK_RUBRIC_TIMEOUT`
   (blocker-ladder R2-6). A probe is one line, at most 300 characters, and
   never contains the needs file's separator (R2-11). A fix that breaks a
   rule is dropped, with the reason logged, and the detention is as before.
4. **Outcomes are defined once** (R2-1, R2-2): passed (exit 0); failed
   (any other exit, a missing tool's 127 included); inconclusive (a
   timeout after 30 s, a sandbox that is not running, or a setup command
   that failed before the probe). At detention every outcome detains. At
   office hours failed stops, unless `--unproved`, and inconclusive goes
   on, unproved. In pre-flight failed detains and inconclusive goes on.
5. **Needs live in the repository** (R2-10). A proved image or config probe
   is appended to `.chalk/needs` and committed on the detention branch, so
   it reaches the resumed run and, by merge, every other branch.

## Recommended Approach

- **Schema.** The loop answer gains an optional `fix` object. The
  `lessons` table gains `fix`, `fix_kind`, `probe`, `before_*`, `after_*`,
  `evidence` and `retired_at`, with no separate blockers table: a
  detention is one lesson row.
- **`lib/evidence.sh`.** `evidence_fix` (the rules), `evidence_probe` (the
  outcomes), `evidence_check` (a fresh sandbox), `evidence_needs` and
  `evidence_need_line` (the file), `evidence_fix_text`.
- **Run.** A blocked loop keeps its fix (`RUN_FIX`). `run_detain` shows
  the fix, runs the probe after parking the work, and records both. The
  `next:` line follows the kind: for an image fix it says how to build on
  the default image, or how to change a custom one. `run_preflight` runs
  every need after the setup command, and detains as `preflight` with the
  need's probe on the lesson.
- **Office hours.** `office_hours_check` re-runs the probe in a fresh
  sandbox before anything is recorded. Distillation gets the proposed fix
  and what the probe showed, in `<proposed_fix>`. `office_hours_save_need`
  commits a proved need.
- **Prompts.** `continue.md` and `retry.md` ask for the fix. `distill.md`
  replaces its registry-token example, which taught "report a blocker",
  with a fix-shaped one, and adds the rule that a lesson states the fix.
- **`chalk needs [--prune]`.** It checks each need with its fix (it must
  pass) and without it (the default image for an image need, no setup
  command for a config need). A pass without the fix retires the need and
  its lesson. It exits non-zero when a need fails, for CI.

## Not in scope

- `office-hours --accept` and `--retry`, and the rule-based kind sort
  (blocker-ladder PR 2).
- The decider on blockers (blocker-ladder PR 3).
- A failing `CHALK_SETUP_CMD` as a pre-flight detention, the rubric
  baseline, and #48's question (the rest of blocker-ladder PR 4).
- Sharing lessons across repositories (paper Section 5, future work).

## Success Criteria

- The next real environment blocker shows its fix, the probe's outcome and
  a kind-specific `next:` line.
- Office hours refuses a fix the probe does not confirm, and saves a
  proved one as a committed need.
- A run whose environment lost a saved need detains in pre-flight with no
  loop spend.
- Recall never returns an unproved or retired lesson.

## Failure modes

| Failure | Effect |
|---|---|
| The agent proposes no fix, or a bad one | Detention as before; the reason is logged |
| Database down at office hours | No pending evidence: the `-m` flow as before |
| The probe writes to the tree | It runs after the detention commit, so the branch is safe; the sandbox is discarded |
| A probe that hangs | Inconclusive after 30 s; nothing detains on it alone |
| A malformed line in `.chalk/needs` | Skipped with a warning |
