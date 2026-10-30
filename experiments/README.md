# Experiments

The scripts here produce the data for the paper's pre-registered evaluation
([docs/paper/main.tex](../docs/paper/main.tex), Section 8). They drive the
real `chalk` CLI, so they need what a run needs: Docker, a sandbox image,
the telemetry database (`chalk db up`), and Claude credentials. **They
spend real money.** Every run is capped by `EXP_BUDGET_USD`, which has no
default.

| Script | What it does | Spends |
| :-- | :-- | :-- |
| `faults.sh OUT [--build]` | Writes the seeded environment faults (C3) as instances, and with `--build` builds their faulty and fixed images | No |
| `run.sh CORPUS OUT [--attempts N] [--oracle] [KEY=VALUE...]` | Runs every instance in `CORPUS` through Chalk, within `EXP_BUDGET_USD` | Yes |
| `analyze.sh OUT` | Turns the results and the database into `analysis.json` and `results.tex` | No |

## Quick start: the seeded faults

```sh
chalk db up && chalk sandbox build
experiments/faults.sh /tmp/exp --build
EXP_BUDGET_USD=20 experiments/run.sh /tmp/exp/corpus /tmp/exp/out --oracle \
  CHALK_FP_RULES=shadow CHALK_MAX_RETRIES=1 CHALK_MAX_LOOPS=3
experiments/analyze.sh /tmp/exp/out
```

Each fault is a one-checkpoint task whose rubric needs a tool the sandbox
image lacks, such as `python3`, a C compiler or `make`, or one whose
faulty image removes `jq`. The agent runs without root and cannot install
it, so the run should end with a blocker carrying an image fix and a
probe. Run with `--oracle`, `run.sh` then:

1. applies the recorded fix: it points `CHALK_IMAGE` at the fixed image in
   `.chalk/config` and commits;
2. runs `chalk office-hours`, which checks the fix with the probe in a
   fresh sandbox and saves it as a need;
3. starts a later ticket from the fixed branch on the faulty image again,
   which pre-flight should detain before any loop.

`analysis.json` counts what happened at each step: probes that failed,
passed or were inconclusive; fixes proved; and regressions caught with
zero loops.

## Instances

An instance is one JSON file:

| Field | Meaning |
| :-- | :-- |
| `id` | Letters, digits, `.`, `-`, `_` |
| `kind` | `replay`, `impossible`, `fault` or `synthetic`; used to group results |
| `repo` | A git URL, an absolute path, or a path relative to the instance file |
| `base_commit` | The commit to start from (default: the repository's `HEAD`). Only this commit is fetched, so later history cannot leak into the run |
| `workspace` | The repository name of its runs in the database: attempts at instances with the same workspace are counted together by `chalk tune` (default: the repository's name). Each attempt still runs in a repository of its own, since a sandbox sees every branch of its repository |
| `title`, `problem` | The spec's title and context |
| `fail_to_pass` | Test IDs; each becomes a checkpoint "Make `ID` pass" |
| `checkpoints` | Or the checkpoints themselves |
| `test_cmd` | `CHALK_TEST_CMD` |
| `setup_cmd`, `image` | `CHALK_SETUP_CMD` and `CHALK_IMAGE`, when not the default |
| `settings` | Any other Chalk settings for this instance |
| `oracle` | Fault instances only: `image` and `config` that fix the fault, and the engineer's `note` |

**Replay (C1)** instances come from SWE-bench-style datasets. Map each
task's repository, base commit, `FAIL_TO_PASS` tests and test command to
the fields above. **Unsolvable controls (C2)** come from ImpossibleBench
the same way, with `"kind": "impossible"`. Converting a dataset is left to
you: these scripts download nothing.

## Spend

Each experiment gets a tag, kept in `OUT_DIR/tag`, and its workspaces are
named `exp-TAG-*`, so its runs stay apart from your own and from other
experiments' in the database. An `OUT_DIR` holds one experiment: give the
next one another.

Before every run, `run.sh` checks the spend so far in this experiment's
repositories, plus the most one run can cost: each loop up to
`CHALK_MAX_LOOPS`, the explored loops, the spec check, the review rounds
and a review fix, each at `CHALK_BUDGET_USD`. If that would pass
`EXP_BUDGET_USD`, it stops before the run. Office hours (one more call, to
distill the lesson, then the resumed run) and the pre-flight run are
checked the same way, and skipped, with a line in `results.jsonl`, when
they do not fit. Lower `CHALK_MAX_LOOPS` and `CHALK_BUDGET_USD` to fit more
runs in a budget. `chalk cleanup --all` in a workspace removes its
branches.

## Filling the paper

`analyze.sh` writes `results.tex`, one `\newcommand` per number. Copy it
to `docs/paper/results.tex` and rebuild the paper: each `\expval{Name}` in
the Results section shows its value, and any not yet measured stays a red
placeholder.
