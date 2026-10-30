# Design: Certified stops (the stop-only gate for verdicts and the decider)

Status: APPROVED by the maintainer on 2026-10-30 (one PR per thesis, this one first)
Mode: Builder
Paper: [docs/paper/main.tex](../paper/main.tex), Section 4
Roadmap: Q1 2027 "Verdicts on", and the decider's calibration gate (#36)

## Problem Statement

Two kinds of decision can stop a run early: the stuck-loop verdicts
(`deja_vu`, `repeat`, `no_change`) under `CHALK_FP_RULES=on`, and the
decider's confident "stuck" under `CHALK_DECIDER=on`. Today they are
admitted differently, and neither is admitted on a guarantee.

1. **`CHALK_FP_RULES=on` is not gated at all.** Setting it lets every
   stopping verdict detain runs at once, whatever the ledger says. The
   roadmap item "Verdicts on" asks for exactly the missing step: let them
   stop runs early *where the shadow numbers show it pays*.
2. **The decider's gate is a point estimate.** "At least 20 runs judged,
   at least 90% right" (`DECIDER_CALIBRATION_RUNS`,
   `DECIDER_CALIBRATION_PERCENT`) admits 18 of 20. The exact one-sided 95%
   Clopper-Pearson lower bound for 18/20 is 0.717. Even 20/20 is only
   0.861.
3. **The gate is checked after every new judgment.** Admitting the first
   time the numbers clear the bar is optional stopping: it admits a
   decider that is right 85% of the time more often than the nominal
   error rate says.
4. **Once a decider acts, nothing checks it again.** The runs it stops
   cannot show what would have happened next, so the evidence stops
   growing exactly when it matters.

## What Makes This Cool

- **Stop-only decisions are exactly evaluable.** A decision that can only
  end a run earlier than the current policy sees, in a shadow run, the
  very trajectory it would have truncated (paper, Proposition 1). There is
  no importance weighting. The ledger already holds the counterfactual.
- **One gate for every stop.** Verdicts and the decider are both stop-only,
  so one rule admits both. The local decider stops being special.
- **Demotion comes free.** The same block test that admits a decision
  demotes it when a later block fails. A small random holdout keeps
  producing judged runs after admission.
- **Per-loop caps make savings bounded.** A correct stop saves at most
  `CHALK_MAX_RETRIES` loops at `CHALK_BUDGET_USD` each. That allows a
  distribution-free lower bound on the dollars saved.

## Constraints

- Bash 5.3 on the host, `docs/bash-style.md`, no new dependency. The
  binomial bound is computed in `jq` (1.6+ has `lgamma`), which Chalk
  already needs.
- Optional services never block a run. Without the database the gate
  reads `unknown`, and `on` records in shadow mode only, as the decider
  does today.
- Every external program keeps its fake. The fake database answers the
  new query from `FAKE_CERTIFY`; `make test-db` seeds real rows.
- A repository's config cannot lower the bar. The block size and error
  allowance are constants, and the holdout is machine-level.

## Premises

1. **One rule: a fixed block.** A stratum is certified when its latest
   complete block of 46 judged runs had at most 1 wrongful stop. Exactly,
   `LB_0.95(45/46) = 0.9010 >= 0.90`, while `LB_0.95(44/46) = 0.8694` and
   `LB_0.95(44/45) = 0.8989` fall short.
   Blocks are fixed-size and evaluated once each, so the gate is a fixed-n
   test, not a running one.
2. **A run is the unit.** A stop-only decision fires at most once per run,
   so each run contributes one judgment, by its first firing.
3. **Judged as today.** A firing is *correct* when the run made no progress
   after it and was detained, *wrongful* when a later loop progressed, and
   *waiting* otherwise. Blocks are ordered by when each run was judged:
   its first progressing loop after the firing, or its detention. A
   decision on a run's last loop is not a firing: the run ended there
   anyway, so stopping saved nothing and could not be wrong, and counting
   it would only pad the right ones.
4. **Strata.** A verdict is certified per verdict and agent model (the
   model the call reports), across every repository on the machine. A
   decider is certified per URL, model revision and threshold, as today. A new model is a new stratum and starts in
   shadow mode.
5. **Incremental evaluation under `on`.** When some verdicts act and
   others do not, a held verdict is judged only on the runs the acting ones
   did not stop. That is its effect on top of the policy actually
   deployed, which is what admitting it would change (paper,
   Proposition 2).
6. **`on` means "on once certified".** Under `CHALK_FP_RULES=on`, a
   stopping verdict acts only when its stratum is certified. Otherwise it
   is held to shadow, with one warning per run, as `CHALK_DECIDER=on` is
   today.
7. **The holdout.** With probability `CHALK_HOLDOUT` (default 0.10,
   environment only), a run keeps every certified stop in shadow mode.
   Without it, an admitted decision would never be judged again. Only the
   stops are held: the rest of the run, the decider's lesson rerank
   included, is the deployed policy, which the holdout must measure.

## Recommended Approach

### `lib/certify.sh` (new, domain layer, after `db`)

- Constants: `CERTIFY_BLOCK=46`, `CERTIFY_MAX_WRONG=1`,
  `CERTIFY_TARGET_PERCENT=90`, `CERTIFY_ALPHA=0.05`. A unit test proves they
  are the smallest block meeting the target with one error allowed.
- `CERTIFY_JQ`: `jq` definitions for the binomial tail, `cp_lower`,
  `cp_upper`, `hoeffding_lower` and `certified($max)`, shared by the gate,
  `chalk certify`, the report card and doctor.
- `certify_lower X N -> REPLY` and `certify_upper W N -> REPLY`.
- `certify_data -> REPLY`: `db_certify_verdicts`, read once per process.
- `certify_verdict VERDICT MODEL VAR`: fills `status` (certified,
  uncertified, unknown), `judged`, `correct`, `waiting`, `blocks` and
  `block_wrong`.
- `certify_note VAR -> REPLY`: the judgement in words.
- `certify_holdout -> REPLY`: 1 with probability `CHALK_HOLDOUT`.

### `db_certify_verdicts` (db.sh)

For every shadow loop call with a stopping verdict, the first such loop per
run and verdict is the firing, plus a pseudo-verdict `any` for their union.
For each firing it reads `progressed_after` and its time, the detention
time, and the dollars after the firing. It then aggregates per (verdict,
model): `judged`, `correct`, `wrong`, `waiting`, `blocks`, `block_wrong`
(latest complete block), `saved` and `saved_max` (over correct firings).
It also gives the count of distinct runs judged, for the Hoeffding bound.

A call records `fp_rules = on` only when its verdict detained the run.
Otherwise it records `shadow`. That keeps the old meaning for old rows (a
stopping verdict on an `on` call acted) while letting held verdicts under
`on` count as evidence.

### `db_decider_calibration` (db.sh)

Each level gains `blocks` and `block_wrong`, computed the same way.
`decider_calibration_judge` uses `certified($max_wrong)`, and its note
says the rule in words. `DECIDER_CALIBRATION_RUNS` and `_PERCENT` are
removed, and the report card shows `{threshold, block, max_wrong}`.

### Run loop (run.sh)

- `RUN_HOLDOUT` is drawn at run start. When it is 1 and a certified stop
  is held, the run says so once.
- After the verdict, `run_fp_mode VERDICT MODEL -> REPLY` decides `on`
  (acts) or `shadow` (records), warning once per verdict when it is held.
  The call is recorded with that mode, then acts on it.
- `decider_stop_mode` holds the decider's stuck decision to shadow on a
  holdout run; `decider_mode`, which the lesson rerank uses, does not.

### `chalk certify [--json] [--false-stop-usd N]` (dashboard.sh)

A table per stratum: judged, right, wrongful, waiting, the 95% lower bound
over every judged run, the latest block, its status, the dollars saved on
correct stops with a Hoeffding lower bound on the mean per firing, the
upper bound on the wrongful rate, and the net bound at `N` dollars per
wrongful stop (default 5). It covers the union row `any` and each decider
provider at `CHALK_DECIDER_THRESHOLD`. `--json` prints the same data.
Nothing leaves the machine.

### Doctor

When `CHALK_FP_RULES=on`, `chalk doctor` gets one optional line per
stopping verdict for the configured model: certified, or how far it is.

## Not in scope

- Certifying per repository or per prompt version. There is too little
  data. Recorded as an open question.
- Turning the net-savings bound into part of admission. A wrongful stop's
  price is the operator's judgement, so it is reported, not gated on.
- A sequential test with error spending. The fixed block is simpler, and
  its multiplicity across blocks is reported (`blocks`).

## Success Criteria

- `make check` and `make test-db` pass.
- Under `CHALK_FP_RULES=on`, an uncertified verdict changes nothing and
  says why once. A certified one detains, and records `on` on that call
  only.
- The decider and the verdicts are admitted by the same `jq` definition.
- `chalk certify` reproduces `cp_bounds.py`'s numbers for the same counts.

## Failure modes

| Failure | Effect |
|---|---|
| Database down | Gate `unknown`: `on` held to shadow, one warning |
| `jq` without `lgamma` (< 1.6) | Bound empty; the gate is uncertified, as unknown |
| Block straddles a model change | Impossible: blocks are per model |
| Holdout draws 0 forever | Demotion waits; `chalk certify` shows blocks unchanged |
