# The workflow

One ticket is one branch, one worktree and one spec. This page follows a
ticket from `chalk new` to the pull or merge request.

## One ticket

```sh
chalk new PROJ-123 "Add rate limiting"   # worktree ../<repo>.worktrees/PROJ-123 on branch chalk/PROJ-123
cd ../<repo>.worktrees/PROJ-123
$EDITOR specs/PROJ-123.md                # write the checkpoints
git add -A && git commit -m "spec"
chalk run                                # or: chalk run --detach
```

`chalk run` works on the worktree you are in. With `--detach` it runs in
the background; follow it with `chalk logs PROJ-123 -f`, and see every
ticket's state, loops, cost, office-hours fixes and detentions with
`chalk status`.

## What a run does

1. **Sandbox.** Chalk starts a container with the repository cloned into a
   RAM disk. The host repository is mounted read-only, and the container
   has no GitHub or GitLab credentials. Inside it, the agent runs in auto
   mode (see [Permissions](../configuring/permissions.md)).
   `CHALK_SETUP_CMD` runs once.
2. **Spec check.** A cheap model (`CHALK_CHEAP_MODEL`) confirms every
   checkpoint is small, testable and unambiguous. If not, it lists the
   problems with suggestions, and the run stops before any money is spent
   on loops. A spec that passed is not checked again until its checkpoints
   change. Run the check alone with `chalk check`.
3. **Loops.** Each loop, the agent works on the first unchecked checkpoint
   under a `CHALK_BUDGET_USD` cap and reports `done` or `blocked`. The
   harness then runs the rubric, `CHALK_TEST_CMD`, itself, with a
   `CHALK_RUBRIC_TIMEOUT`.
4. **Commit or retry.** When the rubric passes and a checkpoint was ticked
   in the spec, the harness commits in the sandbox and fast-forwards your
   local branch. Otherwise the next loop is a retry: the agent gets the
   failure and a prompt that asks for the root cause first. After
   `CHALK_MAX_RETRIES` failed loops in a row, the run goes to detention.
5. **Final review.** When every checkpoint is ticked, an independent agent
   reviews the change against the base branch for stubs, weakened tests
   and drift from the spec. Findings get `CHALK_REVIEW_ROUNDS` fix rounds
   (one by default), each followed by another review.
6. **Pull or merge request.** The branch is pushed and a pull request
   (GitHub) or merge request (GitLab) is opened, with the loops, cost,
   human interventions and the review summary in its description. With
   `CHALK_AUTO_MR=false`, Chalk stops here and `chalk submit` opens it.
7. **Detention.** A reported blocker, the loop limit (`CHALK_MAX_LOOPS`),
   exhausted retries or a review that still fails sends the run to
   [detention](failures.md). Nothing is pushed.

The worst-case spend of one run is `CHALK_BUDGET_USD` × `CHALK_MAX_LOOPS`,
plus the spec check and the reviews.

The agent keeps `specs/<TICKET>.notes.md` up to date as it works, so each
loop starts from what earlier loops learned. The file is committed and
appears in the pull or merge request.

## Writing a spec an agent can finish

The spec check rejects checkpoints that are too big, untestable or vague.
What passes it:

- **One loop's work.** A checkpoint should be finishable within one loop's
  budget: one function with its tests, one endpoint, one migration. Split
  anything you would split into separate commits.
- **Provable by the rubric.** Say what a test will show: "rejects an
  expired token with 401", not "handle tokens properly".
- **In order.** The agent always takes the first unchecked checkpoint.
  Put foundations first.
- **Context names files.** The Context section says what is being built,
  why, and which files or modules are involved. Link the ticket.

Rules that apply to every ticket belong in the textbook
(`.chalk/textbook.md`); rules for this repository belong in `CLAUDE.md`.

## When the run ends

- **Success:** the pull or merge request is open. The
  [gates](../operating/merge-request-gates.md) re-run the rubric in CI, and
  a person reviews the diff.
- **Spec not ready:** rewrite the checkpoints the check named, commit, and
  run again. `CHALK_SPEC_CHECK=false` skips the check.
- **Detention:** see [Detention and office hours](failures.md).

## End of sprint

```sh
chalk cleanup         # stops runs, removes sandboxes and clean worktrees, deletes merged or pushed branches
chalk cleanup --all   # also deletes unmerged branches, including detention work
```

Without `--all`, worktrees with uncommitted changes and branches that are
neither merged nor pushed are kept, so no work is lost. The telemetry
database is never touched.

## Where things live

| What | Where |
| :-- | :-- |
| Specs | `specs/<TICKET>.md`, one file per ticket so parallel branches never conflict |
| Agent notes | `specs/<TICKET>.notes.md`, kept by the agent, committed with the work |
| Global rules | `.chalk/textbook.md`, appended to the agent's system prompt |
| Local rules | `CLAUDE.md` |
| Run logs, prompts and answers | `~/.local/state/chalk/<repo>/runs/<TICKET>/` |
| Fleet plans | `~/.local/state/chalk/<repo>/plans/<EPIC>.json` |
| Telemetry and lessons | Postgres in the `chalk-db` container (`chalk db psql`), tables `runs`, `events` and `lessons` |
