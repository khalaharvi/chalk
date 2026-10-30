# Design: Ledger-gated tuning (chalk tune)

Status: APPROVED by the maintainer on 2026-10-30 (Thesis 3 of the paper, one PR; spend-extending exploration included, opt-in, with a ceiling)
Mode: Builder
Paper: [docs/paper/main.tex](../paper/main.tex), Section 6
Builds on: [harness2-hardening.md](harness2-hardening.md) Part 4, [certified-stops.md](certified-stops.md)
Stacked on: [evidence-prs.md](evidence-prs.md)

## Problem Statement

Chalk's report card groups loops by prompt hash, and prompts can be
ejected per repository. Yet nothing tells a repository which settings to
change, and nothing tests a change before it is kept. Harness optimisers
in the literature (Harness², Meta-Harness, AHE, Self-Harness) tune offline
on benchmarks, and Harness² deliberately selects without a ground-truth
verifier. A repository has its own verifier, the rubric the harness runs,
and its own stream of tickets.

## What Makes This Cool

- **The right test for each kind of change.**
  - Stop-only changes are judged exactly from every run.
  - Spend-extending changes are judged only from randomized exploring runs.
  - Trajectory-altering changes are judged only by a randomized A/B test.
- **No correction needed for many candidates.** Fewer retries are tested
  in a fixed sequence, most cautious first, each at the full 5%. Stop-only
  candidates are nested (a bolder one fires wherever a cautious one does,
  and earlier), so the sequence is natural.
- **Exploration has a hard ceiling.** Exploring runs get at most
  `CHALK_EXPLORE_RETRIES` extra loops once, and the machine stops
  exploring at `CHALK_EXPLORE_BUDGET_USD` per 30 days. A database that
  cannot say what was spent counts as spent.

## Constraints

- A tuning change never touches the rubric, the tests, the textbook or the
  gates of `certify.sh`.
- Nothing is applied without `--apply`, and what is applied is a file
  change for you to commit.
- "Never spend more" holds by default. Exploring is opt-in, and bounded per
  run and per machine.

## Recommended Approach

- `lib/tune.sh`:
  - `tune_draw` draws a run's arms: prompts `a`/`b`, and exploring under
    the ceiling;
  - `tune_judge` holds the three tests;
  - `cmd_tune [--json] [--days N] [--checkpoint-usd N] [--success-usd N] [--apply]`.
- `runs` gains `arm_prompts`, `arm_explore` and `explored`.
  `db_tune_data` gives per-run calls, outcome and cost; `db_explore_spent`
  gives the 30-day spend.
- `prompt_file` reads `.chalk/prompts-b/` first in arm `b`. `RUN_PROMPTS`
  is recomputed, so the report card's per-prompt-set view separates the
  arms too.
- In the run loop, where a run would be detained for failing, an exploring
  run takes one more loop instead, up to its extra loops. Progress ends the
  exploring.

### The three tests

1. **Fewer retries** (`CHALK_MAX_RETRIES = j < K`). For each run outside
   the exploring arm, `j` fires at the first loop that ends `j+1` loops in
   a row without progress. A firing is judged once the run was detained,
   finished, or progressed later. It is wrongful when a later loop
   progressed; otherwise it saved the cost of the loops after it. `j`
   passes when it has at least 46 judged runs, a 95% Clopper-Pearson lower
   bound of at least 0.90 on being right, and a positive net: a Hoeffding
   lower bound on dollars saved per firing, less `--checkpoint-usd` per
   wrongful stop at its upper bound, each bound at 2.5%.
2. **More retries.** Among exploring runs that used extra loops, a run is
   rescued when an explored loop progressed. Raising `K` by one is
   recommended when the lower bound on the rescue rate times
   `--checkpoint-usd` exceeds the Hoeffding upper bound on explored cost
   per run.
3. **Prompts.** Per judged run (finished or detained), its value is
   `--success-usd` if it finished, less its cost. `b` is adopted when a
   two-sample Hoeffding lower bound on `mean(b) - mean(a)` is above zero.
   The range is the largest run cost plus the success value.

## Not in scope

- Proposing prompt variants with a model (Harness²'s Propose step). The
  variants are written by you; tune judges them. That is a follow-up once
  the judging has data.
- Off-policy estimators for trajectory-altering changes. The A/B test is
  the honest tool at this data volume.
- Tuning `CHALK_BUDGET_USD`. A lower cap changes what each loop does, so
  it is not stop-only.

## Failure modes

| Failure | Effect |
|---|---|
| Database down at run start | No exploring; the warning says why |
| Ceiling reached | No exploring; the warning names the setting |
| `CHALK_PROMPT_AB=true` without `.chalk/prompts-b/` | No test; warning |
| Too few runs | Every test says "no change" |
