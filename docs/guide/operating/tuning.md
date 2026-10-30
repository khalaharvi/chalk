# Tuning a repository's harness

`chalk tune` reads this repository's own runs from the telemetry database
and says which settings to change. A change is recommended only on
evidence, and the evidence a change needs depends on what kind of change
it is. Nothing is sent anywhere; nothing changes until you apply it.

```sh
chalk tune                      # the report
chalk tune --apply              # also apply what it recommends, for you to commit
chalk tune --json --days 30
```

`--checkpoint-usd N` (5 by default) prices a checkpoint and
`--success-usd N` (10) prices a finished run, for weighing spend against
what it buys.

## Fewer retries: judged from every run

Lowering `CHALK_MAX_RETRIES` can only stop runs earlier, never spend more.
So every run already shows exactly what a lower setting would have done:
where it would have stopped, what the loops after that cost, and whether
one of them made progress (a wrongful stop). Each lower setting is tested
from the most cautious down, and the first that fails ends the testing. A
setting is judged as an early stop is (see `chalk certify`): it is
recommended when its latest block of 46 judged runs, and the block still
filling, each have at most one wrongful stop, which shows it right at
least 90% of the time with 95% confidence, and what it saves is worth more
than its wrongful stops.

## More retries: only from runs that explored

Raising `CHALK_MAX_RETRIES` cannot be judged that way: the loops after a
detention never ran. To measure it, set:

```sh
CHALK_EXPLORE=true          # in .chalk/config
CHALK_EXPLORE_SHARE=0.20    # the share of runs that may explore
CHALK_EXPLORE_RETRIES=2     # how many more loops they get, once
```

An exploring run that would be detained for failing gets that many more
loops, once, and they are recorded as explored. The run log says so. On
the machine, `CHALK_EXPLORE_BUDGET_USD` (10 by default, environment only)
caps what explored loops may cost in 30 days: before each extra loop, a
run checks that one more, at `CHALK_BUDGET_USD`, stays within it. Runs
exploring at the same moment can each take the last room, so with
parallel runs the cap can be passed by one loop per other run. When the
database cannot say what was spent, no run explores. `chalk tune` judges
only the first extra loop of each exploring run, which is what one more
retry adds, and recommends raising the setting by one when even the
lowest likely rescue rate of that loop pays for its highest likely cost.

## Prompts: a randomized comparison

A prompt change alters what the agent does, so neither of the above can
judge it. Put the prompts to try in `.chalk/prompts-b/`, under the same
names as `chalk prompts` lists, and set `CHALK_PROMPT_AB=true`. Each run
then draws prompts `a` (the usual ones) or `b` at even odds, says which,
and records it. A prompt missing from `.chalk/prompts-b/` comes from the
usual place. `chalk tune` compares the value per run of the two arms (a
finished run is worth `--success-usd`, less what it cost). It recommends
`b` only when the 95% interval on b's advantage is above zero, and `a`
when it is below zero. `--apply` moves `.chalk/prompts-b/` into
`.chalk/prompts/`. `CHALK_PROMPT_AB=a` or `b` runs every run on one of
them; such runs did not draw their arm, so they are not counted.

The exploring and prompt bounds hold at 95% when read once, at a number
of runs you choose before you start. Running `chalk tune` after every run
and acting on the first recommendation makes a wrong one more likely.

## What tuning never touches

The rubric, the tests, the textbook, and the bars that early stops and
the decider must clear. Prompts to try are yours to write; `chalk tune`
only judges them.
