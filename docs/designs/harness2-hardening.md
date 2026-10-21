# Design: Hardening, fleet scheduling and a self-tuning harness, informed by Harness²

Generated on 2026-10-21
Branch: main
Repo: khalaharvi/chalk
Status: DRAFT, four review decisions recorded (see Decisions)
Mode: Research. No code changes; each part below proposes PRs to be approved one at a time.
Reference: [google-research/harness2](https://github.com/google-research/harness2) (Apache-2.0), read at its default branch on 2026-10-21. Nothing from it was run.

## Problem Statement

Four gaps, in the order they hurt real runs:

1. **Errors lose work and hide their cause.** A database hiccup, a failed sync or a dead container ends a run through errexit, and `run_teardown` then deletes the sandbox that holds the agent's uncommitted work. When the agent's CLI itself fails, its stderr goes to a file nothing reads, and the detention points at evidence that the next command deletes. An audit found 27 issues; 5 can lose paid work or let unreviewed work through (Part 1).
2. **`chalk fleet` is a launcher, not a scheduler.** It fires detached runs into the slots free at launch time and exits. Nothing refills a slot, nothing backs off when the account hits a rate or usage limit (every run detains at once), first use builds the image N times in parallel, and the decider is serialised machine-wide, so under a fleet most decider questions get `busy` (Part 2).
3. **Chalk is welded to Claude Code, Docker and Jira-style tickets** beyond the parts the Harness interface (#39) already plans to abstract (Part 3).
4. **Chalk has no answer to "is my harness right for this repo?"** Prompts can be ejected per repo and the report card groups loops by prompt hash, but nothing proposes a better harness, tests it, or keeps what works. This is where Harness² points, and where Chalk can have a niche of its own (Part 4).

## What Harness² is, and what transfers

Harness² is a Python research framework that optimises the *harness* around a fixed model: system prompt, guardrails, memory, tool guidance, subagents, skills, scripts and plugins. For one task it runs **Propose–Probe–Compose**: an improver model proposes harness edits (one "invariant" edit about how the agent works and one "domain" edit about what a practitioner knows), each candidate is run on the same task, and a composer builds a final harness from the behavioural differences between runs. Across tasks it keeps a **library** of adopted harnesses and evidence-gated lessons. It has no ground truth while it optimises: a blind, anonymised selector picks among finals, and the real grader runs only afterwards.

| Harness² mechanism | Where | Chalk today | Verdict |
|---|---|---|---|
| Harness as a file tree, "omitted is inherited", edit surface allowed per executor | `core/tree.py:19-60` | Prompt overrides per file in `.chalk/prompts/` (`agent.sh:27-30`), textbook | **Adopt** as the harness pack (Part 4) |
| Tree validation, error fed back verbatim, one retry, then fall back to the base | `tree.py:336-390`, `recursion.py:180-251` | Schema-validated loop answers only | **Adopt** for proposals |
| Invariant vs domain edit split; rank forms by context cost (skill < script < always-on prose) | `prompts.py:129-146, 347-407` | — | **Adopt** in the proposer prompt |
| Evidence rule: every edit must trace to a moment in a trajectory | `prompts.py:858-877` | Distill uses note + diff | **Adopt** |
| Blind selector, judging without ground truth | `selection.py:71-357` | Chalk **has** ground truth: the rubric, plus the independent review | **Replace** with the rubric, review and cost |
| Library entry needs cue + lesson + evidence; a `confounded` verdict; `NO_ENTRY` allowed | `library.py:43-123`, `prompts.py:1105-1163` | Lessons need only a distilled rule (`lifecycle.sh:30-68`) | **Adopt** for lessons |
| Completion markers with a tree fingerprint; reuse or re-run with a logged reason | `runmark.py:41-115` | Branch existence is the only marker (`fleet.sh:140`) | **Adopt** for fleet and resume |
| Ledger that asserts the expected count of rollouts and sessions | `ledger.py:89-113` | `runs` rows, no expected-count check | **Adopt** for `chalk tune` |
| Ungraded is `None`, never a zero, and leaves the denominator | `judge.py:15-18`, `report.py:17-19` | A failed review counts as a pass (Part 1, E3) | **Adopt** |
| Exit 0 all ok / 2 partial / 1 died; every CLI ends with a `next:` hint | `cli/run_sweep.py:183-206` | Everything is 1; `next:` exists for detentions | **Adopt** (Part 1, E-PR4) |
| Preflight collects every problem before spending anything | `preflight.py:28-160` | `chalk doctor`, pre-flight in the blocker ladder PR 4 | Already planned; borrow "collect all, then refuse" |
| Executor substrates (OpenCode, Codex): `surface`, `materialise`, `execute`, `read_trajectory`, `preflight` | `substrate/base.py:47-80` | Planned Harness interface (#39) | **Extend #39** with `surface` and `materialise` (Part 3) |
| Codex with its sandbox off; the Claude improver runs with `--dangerously-skip-permissions`; open network | README:166-171 | Docker sandbox, caps dropped, no forge credentials | **Reject.** Chalk's sandbox stays the boundary for every call, including the improver's |
| Executor rollouts recorded at $0; no USD cap | `recursion.py:299,338` | Per-call cap | **Reject.** Every probe is costed and capped |
| WorkBuddy runner (custom Tencent licence, not for use in the EU) | `third_party/wb_runner/LICENSE` | — | **Reject.** Never copy |

The integration is **ideas, not code**: Chalk stays a bash 5.3 CLI with no Python dependency. Where a passage is close enough to a Harness² prompt to count as derived, it carries an Apache-2.0 attribution in `NOTICE`.

## Premises

1. **Real runs come before new features, so Part 1 ships first.** Losing paid work to a database restart costs more than any tuning gains.
2. **Optional services never end a run.** Telemetry, decider bookkeeping and recall are best effort everywhere, not only in the decider.
3. **Every way a run can end parks the work.** Success graduates; anything else, including a Chalk crash, leaves a named branch and a `next:` line.
4. **Chalk's advantage over Harness² is that it has ground truth.** The rubric is a real grader, so Chalk does not need a blind model judge to compare harnesses; it needs attribution and a fair comparison.
5. **The data says the signal is not rubric failures.** In 51 real runs no loop failed its rubric (blocker-ladder design); runs stopped on environment blockers. So a harness is judged on cost per finished checkpoint, loops per checkpoint, review pass rate, review-fix cost and blockers, not on pass/fail.
6. **Anything that changes a run ships in shadow first,** with a counterfactual panel on the report card, the same `off|shadow|on` pattern as `CHALK_FP_RULES` and `CHALK_DECIDER`.

---

## Part 1: Error handling and reporting

### Findings

From a read-only audit of `lib/`, `bin/chalk` and `share/sandbox/scripts/`. Findings E1 to E4 and the runtime filter in E13 were re-checked against the code while writing this design.

| # | Sev | Where | What goes wrong |
|---|---|---|---|
| E1 | High | `run.sh:574, 628, 341, 347, 373, 447-448` (`db_record_call`, `db_event`) | A failing `db_sql` ends the run by errexit; teardown deletes the sandbox with the agent's uncommitted work and the blocker text. `chalk db down` (`db.sh:655`) stops Postgres without checking for live runs, though `db_upgrade` does. |
| E2 | High | `agent.sh:66-67`, `run.sh:565` | The CLI's stderr goes to `$name.err`, which nothing reads; the exit code is dropped. The detention says "agent stopped early (error)" and points at an empty `loop.json`. The lesson signature is the tail of `rubric.log`, unrelated to the failure. |
| E3 | High | `run.sh:369, 382` | A review that crashed, timed out or ran out of budget is `|| true` and only warns; the PR opens as if it had passed, and the body does not say so. The spec check fails open the same way (`run.sh:337, 352`). |
| E4 | High | `run.sh:312-318` (`run_sync`) | A failed fetch or `--ff-only` merge (for example the user committed in the worktree) crashes the run; teardown deletes the sandbox; the commits survive only in `out.bundle`, unmentioned, which the next run deletes. |
| E5 | High/Med | `run.sh:435-448` (`run_detain`) | The failure path has no error handling: a dead container fails `sandbox_commit` and there is no detention branch; a DB failure after the fetch skips the "work parked on …" and `next:` lines. |
| E6 | Med-High | `run.sh:86` | `rm -rf "$RUN_IO"` on every run, check and resume deletes the evidence the last detention pointed at. Per-loop files are overwritten, so only the last loop survives; foreground runs keep no log. |
| E7 | Med | `agent.sh:66`, `fleet.sh:48` | No wall-clock timeout on agent calls. A hung CLI or stalled network blocks the loop for ever, in detached and fleet runs too. |
| E8 | Med | `repo.sh:32-36`, `state.sh:5-8`, `sandbox.sh:52-55` | Repositories are keyed by directory basename. `chalk cleanup` in `~/a/api` kills runs of `~/b/api`; `sandbox_start` can `docker rm -f` the other repo's sandbox for the same ticket; lessons and status mix. |
| E9 | Med | `run.sh:176-177, 591` | Rubric exit codes are not interpreted: 124 (timeout), 137 (OOM/kill), 125-127 (docker or command not found) are handed to the agent as test failures to fix. |
| E10 | Med | `fleet.sh:140-155` | The branch is created first; any later launch failure aborts the loop, and on re-run the ticket is "already started, skipping" for ever. A detached child's errors go only to its `run.log`; fleet exits 0. |
| E11 | Med | `db.sh:109-116`, `sandbox.sh:40-48` | The schema is applied after the `db` lock is released, so N fleet runs race `CREATE EXTENSION/TABLE IF NOT EXISTS` on a fresh database. The default image build has no lock. |
| E12 | Med | `repo.sh:20-25, 41-43`, `decider.sh:783-797` | Three value functions can return non-zero, against bash-style rule C1 (`git_common_dir` outside a repo, `current_branch` with no commits, `decider_stuck` when `decider_record` cannot write). |
| E13 | Med | `runtime.sh:15` | The ERR trap's filter matches the unexpanded command text, so any external command with `$(` in its arguments (`docker run --user "$(id -u):…"`) fails with no "unexpected failure" line or stack. |
| E14 | Med | `forge.sh:62-66`, `run.sh:469, 479-490` | A failure to open the PR/MR after the push is a raw trace with no "branch is pushed; open it with …"; "already exists" is not treated as success; the `submitted` event hides its own failure. |
| E15 | Med | `db.sh:210-221`, `lifecycle.sh:99, 114` | Office hours prints "lesson recorded" when the UPDATE matched 0 rows. |
| E16 | Med-Low | `lifecycle.sh:43-53, 91` | `office_hours_distill … || true` disables errexit for the whole function, so failures run on silently; there is no EXIT trap, so Ctrl-C leaves the distill sandbox running. |
| E17 | Med-Low | `db.sh:49, 63, 72-82` | The DB wait polls for the whole timeout even when the container has exited; without `openssl` the password is empty and the container crash-loops; the advice says to raise the timeout. |
| E18 | Med-Low | throughout | Exit codes do not say what happened: detention, `die`, failed spec check and most crashes are all 1; usage errors are 2 at the top level, 1 in subcommands. CI cannot tell "needs a human" from "Chalk broke". |
| E19 | Low | `jobs.sh:28` | Background startup jobs are never killed on Ctrl-C and keep the `db` lock and a `docker build` running. |
| E20 | Low | `sandbox.sh:97-106` | `CHALK_SANDBOX_MEM_MB` sizes fleets but is not passed as `--memory`; a runaway test can take the Docker VM's memory and kill `chalk-db` (then E1). |
| E21 | Low | `db.sh:121-124`, `memory.sh:24` | No `statement_timeout`/`lock_timeout`; recall hides every error, so a broken schema turns recall off with no trace. |
| E22 | Low | `decider.sh:1311` | Under pipefail a jq error ends Chalk before the intended `die`; an empty `$rev` makes jq wait on the terminal. |
| E23 | Low | `decider.sh:472, 531, 967, 995`, `fleet.sh:118` | `mktemp` files with no cleanup trap. |
| E24 | Low | `lifecycle.sh:147-177` | `cleanup --all` stops at the first git error and does not wait for the runs it killed. |
| E25 | Low | `share/sandbox/scripts/export.sh:8` | `git bundle create … >/dev/null 2>&1` hides git's error. |
| E26 | Low | `run.sh:83-86, 132` | Two `chalk run` of the same ticket can both pass `run_claim`; the second deletes the first's io directory. |
| E27 | Low | `decider.sh:266, 1351-1362` | `installed` and `trusted` are rewritten in place while runs read them. |
| E28 | Med | `db.sh:58-63`, `sandbox.sh:36-48` | Found in a real run: a Docker Hub `429 Too Many Requests` on `pgvector/pgvector:pg17` is passed through raw, with no advice (retry later, `docker login`, or a mirror through `CHALK_DB_IMAGE`). |
| E29 | Med | `share/sandbox/Dockerfile:11`, `sandbox.sh:87-107` | Found in a real run: behind a TLS-intercepting proxy (corporate networks), the image build's `npm install` and every agent call fail with `SELF_SIGNED_CERT_IN_CHAIN`. There is no way to give the build or the sandbox an extra CA (`CHALK_EXTRA_CA_CERTS`, passed as `NODE_EXTRA_CA_CERTS` and `SSL_CERT_FILE`), and the failure is a stack trace. |
| E30 | Low | repository | Found in a real run: Chalk has no `.chalk/config` in its own repository, so "Real runs: use Chalk on itself" cannot start; `chalk doctor` says `run 'chalk init'`. |

### Themes

1. **Best-effort host services.** Telemetry, events, decider bookkeeping and recall must never end a run (E1, E12, E21).
2. **Park on every exit.** One function decides what happens to the sandbox's work on any non-success exit, crash included (E1, E4, E5).
3. **Keep evidence, and quote it.** Per-run, per-loop files, and a short excerpt in the detention reason (E2, E6, E25).
4. **Name the reason.** Map raw exit codes to named outcomes: timeout, OOM, infrastructure, auth, rate limit, no verdict (E3, E9, E14, E18).
5. **Use the `db_upgrade` pattern** (a step variable plus an EXIT-trap rollback that names a log) for every multi-step operation: sync, detain, graduate, distill.

### Approach

**E-PR1: Never lose the sandbox's work (`fix(run)`)**, covering E1, E4, E5 and E20.
- `run_park REASON` replaces the ad-hoc failure paths. It is idempotent and ordered so the cheapest, surest step comes first: (1) commit and export from the sandbox, if it is alive; (2) fetch into `detention/$TICKET-$RUN_ID`, falling back to `recovered/$TICKET-$RUN_ID` when the export already exists in `out.bundle`; (3) print the branch and a `next:` line; (4) write DB rows last, best effort.
- `run_teardown` calls `run_park crash` when the exit is not a graduation or a detention, and keeps the container (renamed `…-failed`) when the export itself failed, printing the `docker cp` command.
- `run_sync` failures park instead of crashing.
- `db_try` wraps `db_record_call`, `db_event` and `db_open_lesson` during a run: on failure it warns once per run and appends the SQL to `$RUN_DIR/pending.sql`; `chalk db up` and the next run replay it.
- `chalk db down` refuses while `state_live_runs` is non-empty, unless `--force`.
- *Moved to F-PR3:* the sandbox memory limit. `CHALK_SANDBOX_MEM_MB` defaults to 2048 while the `/work` tmpfs is 4g, and tmpfs pages are charged to the container's memory, so `--memory "${CHALK_SANDBOX_MEM_MB}m"` would kill real runs on large repos. The limit needs its own default that counts the tmpfs.
- **Done when:** e2e (fake docker, fake claude) cases for a DB that dies mid-loop, a sync conflict, a container that dies before detention, and a SIGTERM mid-loop each end with a named branch holding the agent's last commit and a `next:` line, and no stack trace.

**E-PR2: The agent's own failure is shown and recorded (`fix(agent)`)**, covering E2, E3, E7 and E9.
- `agent_call` records its exit code in `$io/$name.exit` and wraps the call in `timeout "$CHALK_AGENT_TIMEOUT"` (new key, default 1800 s), as `agent_start_mode` already does.
- `agent_failure -> REPLY` classifies a failed call from the exit code, `.subtype` and the last lines of `.err` into one of `timeout`, `auth`, `rate_limit`, `usage_limit`, `overloaded`, `budget`, `cli_missing`, `crash`. Patterns live in one table with tests against recorded CLI outputs. It is a value function and never fails.
- The detention reason and the `runs` row (new nullable `failure` column) carry the class and the first useful `.err` line; the lesson signature for `agent_error` uses that, not `rubric.log`.
- Review and spec check: "no verdict" becomes its own outcome. `CHALK_REVIEW_REQUIRED` (new key, default `true`, Decision 2) detains with kind `review_error` and exit 3, so no pull request opens without a review; when `false`, the PR body says "the final review did not run: <class>".
- Rubric exit codes 124, 137 and 125-127 map to `rubric_timeout` (names `CHALK_RUBRIC_TIMEOUT`), `rubric_oom` and `rubric_broken`; `rubric_broken` detains at once instead of asking the agent to fix it.

**E-PR3: Evidence that survives (`fix(run)`)**, covering E6, E25 and E26.
- `RUN_IO` becomes `runs/T/$RUN_ID/io/`, with per-loop files `loop-03.json`, `loop-03.err`, `rubric-03.log`. The newest 5 run directories per ticket are kept (`CHALK_KEEP_RUNS`).
- Every run, foreground included, tees to `runs/T/$RUN_ID/run.log`.
- `export.sh` writes git's stderr to `/chalk/export.err`.
- `run_claim` takes `chalk_lock "run-$TICKET" 0`.

**E-PR4: Exit codes, the ERR trap and value functions (`fix(core)`)**, covering E12, E13, E18, E19 and E23.
- Exit codes (Decision 1), documented in `docs/reference/exit-codes.md`, with the CI gate templates updated in the same PR, and frozen at 1.0: `0` success, `1` Chalk internal error, `2` usage, `3` detention (a human is needed), `4` environment not ready (doctor or pre-flight), `5` a fleet where some tickets did not launch, `128+n` signals.
- The ERR trap tells a failed substitution apart with a `RUNTIME_IN_SUBST` flag set by the substitution helpers, instead of matching command text.
- The three value functions end with `:` and return an empty REPLY. A `make check` lint flags any `-> REPLY` function whose last command can fail.
- `jobs` kills `JOBS_RUNNING` from the EXIT handler; one per-process temp directory is removed on EXIT.

**E-PR5: Repository identity and the remaining Mediums (`fix(repo)`)**, covering E8, E10, E11, E14, E15, E16, E17, E21, E22, E24 and E27.
- `repo_id` is a short hash of the realpath of the common git directory. It keys the state directory, sandbox names, labels and DB rows; `repo_name` stays for display. A migration in `chalk db upgrade` backfills `repo_id` for existing rows; rows from two same-named repos are already mixed and are left as they are, with a note in the release notes.
- E10 is fixed by fleet markers (F-PR1); the rest are local fixes as the audit suggests.

---

## Part 2: Fleet efficiency

### Findings

| # | Where | What |
|---|---|---|
| F1 | `fleet.sh:133-147` | Slots are computed once at launch; nothing refills them. No queue, priority or dependency ordering (#50). |
| F2 | `fleet.sh:85-91` | Slots count only this repo's live runs, but the limit is derived from machine-wide Docker resources; `state_live_runs` (`state.sh:29-37`) exists and is unused. Two fleets oversubscribe the machine. |
| F3 | `run.sh:587-589, 661-665` | A 429 or usage-limit error counts as an ordinary failure; after `CHALK_MAX_RETRIES` the run detains. An account-wide limit detains the whole fleet at once. |
| F4 | `sandbox.sh:40-48`, `db.sh:109-116` | First use: N image builds and N schema applies in parallel (E11). |
| F5 | `run.sh:517-521`, `lifecycle.sh:41-44` | `CHALK_SETUP_CMD` runs in every fresh tmpfs sandbox and every distill, with no dependency cache. |
| F6 | `decider.sh:362-410` | The local decider is serialised machine-wide with a 1 s queue; under a fleet most questions return `busy` and give the calibration gate no data. |
| F7 | `agent.sh:56`, `share/templates/config:33-36` | Spend is capped per call only. No per-run, per-fleet or per-day budget (#49). |
| F8 | `fleet.sh:53-61` | Plan validation does not check duplicate tickets or overlapping files between workstreams. |
| F9 | `run.sh:697-714`, `share/schema.sql` | No epic in the DB; no fleet-level status or report. |

### Approach

**F-PR1: A fleet that finishes (`feat(fleet)`)**, covering F1, F2, F8, F9 and E10.
- Fleet state lives in `plans/EPIC.state.json`, one record per ticket: `queued | launching | running | detained | graduated | failed_launch`, with the run id and a fingerprint of the workstream's spec (the Harness² completion marker). It is written atomically (temp file plus `mv`). A changed spec means the ticket is re-queued, with the reason logged.
- `chalk fleet EPIC --yes` becomes a supervisor: it launches up to the machine-wide limit (`state_live_runs` across all repos), then waits on its children and launches the next queued ticket when a slot frees up. `--detach` runs the supervisor itself under `nohup`, using `jobs_detach`. Re-running the command attaches to a live supervisor or resumes from the state file.
- `depends_on` in the plan schema (#50): a ticket waits until its dependencies graduate; a detained dependency holds its dependants and says so.
- `fleet_validate` refuses duplicate tickets and warns when two workstreams' checkpoints name the same paths.
- `runs.epic` (nullable) and `chalk status --epic EPIC`; the report card gains a per-epic row (cost, checkpoints, detentions, wall time).
- Exit code 5 when a ticket failed to launch; the summary lists each with its `run.log` path.
- **Done when:** e2e with fake claude: a 5-ticket fleet with `CHALK_MAX_PARALLEL=2` and one dependency ends with all 5 graduated from one command; killing the supervisor and re-running resumes without relaunching finished tickets.

**F-PR2: Shared limits and backoff (`feat(fleet)`)**, covering F3 and F7.
- With E-PR2's classes, `rate_limit` and `overloaded` retry with exponential backoff and jitter (30 s, 60 s, 120 s, max 3), and the retries do not count against `CHALK_MAX_RETRIES`.
- `usage_limit` writes a machine-wide `limits/claude.until` file with the reset time the CLI reports (or +15 min when it reports none). Runs about to call the agent sleep until then instead of failing; the supervisor stops launching; `chalk status` shows "paused: usage limit until 14:05". The run is not detained, because no human is needed.
- Budgets: `CHALK_RUN_BUDGET_USD` (per run) and `CHALK_DAILY_BUDGET_USD` (machine-wide, summed from `runs` for today). Reaching either parks the run with detention kind `budget`, whose `next:` line names the key. #49's warning comes for free at 80%.
- Shadow first: for one release, F-PR2 records what it would have done (`runs.backoff_shadow`) and the report card shows how many detentions it would have avoided.

**F-PR3: Do shared work once (`perf(sandbox)`)**, covering F4, F5 and F6.
- The image build and the schema apply run under `chalk_lock`; the schema carries a version row and is skipped when current.
- Opt-in `CHALK_CACHE_DIRS` (for example `~/.npm ~/.cache/pip ~/go/pkg/mod`), default off. The rules (Decision 4):
  - **Keyed by the base commit's dependency files.** The key is a hash of the lockfiles and manifests (`package-lock.json`, `pnpm-lock.yaml`, `poetry.lock`, `uv.lock`, `requirements*.txt`, `go.sum`, `Cargo.lock`, …) *at the run's base commit*, plus the image digest. A merge to main that changes dependencies changes the key, so the next run never sees stale libraries.
  - **Seeded only before the agent runs.** A snapshot for a key is written once, from the state after `CHALK_SETUP_CMD` succeeds at the base commit, before loop 1. Installs the agent makes later stay in that run's tmpfs and are thrown away with the sandbox; they never reach the snapshot.
  - **Copy-on-start, never shared writable.** Each run gets its own copy of the snapshot (`docker cp` from a read-only volume, or an overlay); concurrent runs never write to the same directory. Seeding takes `chalk_lock "cache-$KEY"`; a run that finds the lock held runs setup without a cache instead of waiting.
  - **Setup still runs.** With a hit, `CHALK_SETUP_CMD` still runs and is expected to be fast; a hit is never trusted in place of setup.
  - **Bounded.** The newest 3 keys per repo are kept; `chalk cleanup` and `chalk doctor` report and prune them.
  - The report card shows setup time with and without a hit.
- The decider queue grows with the fleet: `DECIDER_QUEUE_MS` scales with live runs up to the loop's 2 s host budget, and `busy` answers are counted on the decider panel so the starvation is visible. A decider with `parallel > 1` in its `/health` is not serialised.

---

## Part 3: Broader tooling

The Harness interface (#39) plans a headless call, structured output, read/write access, a spend cap, normalised usage and image requirements. The coupling map turned up more Claude-specific surface than that list covers. Proposed additions to #39, so the Codex adapter (#40) does not stall on them:

| Add to the interface | Why | Today |
|---|---|---|
| `harness_surface` -> the paths it can load from the repo: always-on instructions file, skills dir, hooks, subagents | Part 4 tunes these; Harness² shows each executor exposes a different surface (`substrate/opencode.py:42-88`, `codex.py:39-103`) | CLAUDE.md is assumed (`system.md:39`, `setup.sh:224`, the CI gate template) |
| `harness_materialise PACK_DIR SANDBOX` -> writes a harness pack into the sandbox in that executor's layout | Same | Only `--append-system-prompt-file` |
| `harness_failure` -> E-PR2's classes | Backoff and limits must not depend on Claude's error text | `.is_error/.subtype` only |
| `harness_read_tools` | `CHALK_READ_TOOLS` is in Claude's tool vocabulary (`agent.sh:47`) | Hard-coded |
| `harness_plan` | `fleet_plan` calls `claude` on the host (`fleet.sh:48-50`) | Hard-coded |
| `harness_probe` | `agent_start_mode` drives Claude's stream-json control protocol (`agent.sh:73-91`) | Hard-coded |
| `harness_telemetry_env` | `CLAUDE_CODE_ENABLE_TELEMETRY` and friends (`sandbox.sh:62-85`) | Hard-coded |

Two smaller items widen who can use Chalk without new infrastructure:

- **The instructions file name.** Read `AGENTS.md` when it exists and `CLAUDE.md` is absent, and let `chalk init` write whichever the chosen harness reads. This is the only change Codex and OpenCode both need from the repo side.
- **Ticket IDs.** The Jira-style regex (`repo.sh:51-62`, `fleet.sh:57`) becomes `CHALK_TICKET_PATTERN`, defaulting to today's, so `GH-123` and `#123` work. The breakdown prompt's Jira MCP assumption becomes a section that is dropped when no ticket source is configured. This lands before Ticket sources (Q2).

The container runtime stays Docker plus Podman (#47); a runtime adapter is not proposed this year.

---

## Part 4: A harness that tunes itself to the repo

### What makes it Chalk's own

Harness² optimises without ground truth and spends most of its machinery making a model judge fair. Chalk already has the grader it lacks: the repo's own tests, run by the harness, plus an independent review and an exact cost on every call. Combine Harness²'s propose-probe-compose with that grader and you get something neither project offers today: **a per-repository harness, proposed from your own runs' evidence, kept only when your own tests and spend say it pays.** "Your repo teaches the harness" fits the school vocabulary: the harness pack is the repo's *syllabus*.

### Constraints the data puts on it

- **No rubric failures in 51 runs** (premise 5). A probe cannot be scored by pass/fail; it is scored by `cost per finished checkpoint`, `loops per checkpoint`, `review pass on first try`, `review-fix cost` and `blocked`. These all exist or can be derived from `runs` and `events` today.
- **Noise.** Harness² itself calls a k=1 gap a "noise floor" (`report.py:122-165`). A single re-run of a ticket varies in cost on its own; a difference counts only when it is beyond the spread of repeated runs of the *base* harness on the same ticket.
- **Cost.** Harness² spends R = 4k executor rollouts and P = 3k improver sessions per task (`ledger.py:26-32`). For Chalk a rollout is a whole ticket run, so k = 1 is 4 ticket runs. The real per-ticket cost must be taken from users' report cards before any default is set; this design sets none.
- **Attribution.** Today only the prompt hash (`run_prompts_version`, `run.sh:53-60`) and the *count* of injected lessons are recorded. The hash omits CLAUDE.md, the model, the image and which lessons were recalled. A comparison is not fair until those are recorded.

### Approaches considered

- **A: Offline `chalk tune`, Harness²-style.** Replay finished tickets at their base commit with candidate harnesses and compare. Strongest evidence, highest cost; needs every piece below first.
- **B: Online shadow proposals.** After each graduated or detained run, an improver reads that run's evidence and proposes a harness edit that is recorded, not applied. Cheap (one read-only call), gives a corpus of proposals to judge by hand, proves nothing on its own.
- **C: Online assignment across a fleet.** Give some fleet tickets a candidate pack and compare. Free probes, but tickets differ, so with fleet sizes of a handful the comparison is confounded for months.

### Recommended approach: groundwork, then B, then A; C not this year

**T-PR1: Attribution (`feat(db)`).** No behaviour change.
- `runs.harness` (jsonb): the hash of each file actually in effect (prompts, textbook, the instructions file, pack files), the model per kind, the image digest, `CHALK_FP_FEEDBACK`, and the ids of recalled lessons (`runs.lesson_ids int[]`).
- The report card's `by_prompts` panel becomes `by_harness` and shows the spread (min, median, max) of cost per checkpoint, so readers see the noise next to any difference.
- **Done when:** two runs differing only in an ejected prompt, or only in a recalled lesson, show as different rows.

**T-PR2: The harness pack (`feat(agent)`).**
- `.chalk/harness/`, committed in the repo, is a file tree with Harness²'s "omitted is inherited" rule on top of Chalk's defaults: `system.md`, `textbook.md`, `skills/<name>/SKILL.md`, `scripts/<name>.sh`. The allowed paths come from `harness_surface` (Part 3); for Claude Code, skills are materialised into `/work/repo/.claude/skills/` in the sandbox clone only, never in the user's checkout.
- `harness_validate` checks what Harness²'s `tree.py:336-390` checks, translated: an always-on size cap (`CHALK_HARNESS_ALWAYS_ON_MAX`, 8000 chars), skill frontmatter with a trigger line, scripts pass `bash -n` and `shellcheck`, every referenced script exists, and nothing names a forge credential or a path outside the repo.
- `.chalk/prompts/` keeps working as a legacy location; `.chalk/harness/` wins when both define a prompt, and `chalk doctor` warns (Decision 3). `chalk prompts eject` writes into the pack. `chalk doctor` validates the pack.
- **Done when:** a pack with one skill runs a ticket end to end with fake claude, the skill reaches the sandbox, and a pack that fails validation stops before loop 1 with exit 4 and the reason.

**T-PR3: Evidence-gated lessons (`feat(lifecycle)`).** Harness²'s library gate applied to what Chalk already has.
- The distill schema gains `cue` (when it applies), `evidence` (the moment in the run: the error line, the diff hunk) and `confidence`, and may answer `NO_ENTRY`. A lesson with empty `cue` or `evidence` is not kept, and office hours says so instead of "lesson recorded" (with E15).
- With T-PR1's `lesson_ids`, the report card shows per lesson: times recalled, and progress on the loop it was recalled into versus loops with similar fingerprints without it, marked `confounded` until each side has at least 5 loops.
- This also lands blocker-ladder PR 1's "lessons state fixes" rule in the schema, not only in the prompt.

**T-PR4: Shadow proposals, `CHALK_TUNE=shadow` (`feat(tune)`).** Approach B.
- After a run ends, one read-only call (`share/prompts/propose.md`) sees the run's evidence (per-loop prompts and answers, rubric logs, review findings, blocker, cost), the current pack and the lessons, and proposes at most one invariant edit (how the agent works: a script for a repeated mechanical step, a tool-error rule) and one domain edit (what this repo needs: a skill for its build, a convention), each traced to a moment in the run, or `KEEP_BASE`. The INV/DOM split, the context-cost ranking and the "trace to a moment" rule are taken from Harness²'s prompts and attributed.
- The proposal is validated by `harness_validate`; one retry with the error fed back; then it is dropped and the drop is recorded.
- It is stored in a `proposals` table and `chalk tune list|show|accept|reject ID`. `accept` writes the files into `.chalk/harness/` as an ordinary commit for the user to review; nothing applies itself.
- The call runs in a sandbox like every other call, is capped by `CHALK_TUNE_BUDGET_USD` (default $0.25) and is skipped when the daily budget (F-PR2) is reached.
- **Done when:** the next 20 real runs each leave a proposal or a `KEEP_BASE`, and the report card shows how many were accepted.

**T-PR5: `chalk tune TICKET... --k N` (`feat(tune)`).** Approach A, opt-in, after T-PR1 to T-PR4 have real data.
- For each finished ticket, it checks out the ticket's base commit and spec, runs the base pack `N` times (the noise floor), and runs each candidate (accepted-but-untested proposals, or `N` fresh ones) once per base run. It reports, per candidate, the change in cost per checkpoint, loops per checkpoint, first-try review pass and blocks, against the base spread, and says `no observed effect` when inside it.
- No composer model at first: with ground truth, the candidate that beats the base spread on the most tickets is shown, and the user accepts it. A Harness²-style composer is reconsidered only if candidates routinely help on different tickets.
- It never pushes and never opens a request: probe branches are `tune/…` and are deleted afterwards. Spend is capped by `--budget` (required), and a pre-run estimate from the report card is printed before anything starts.
- The ledger asserts the expected count (`N` base + `N × candidates` runs per ticket) before reporting, and an ungraded run is excluded, never scored as zero.
- **Done when:** on Chalk itself and on one Node and one Python repo from Real runs, `chalk tune` either finds a pack that beats the base spread or honestly reports `no observed effect`, and the cost of finding out is on the report card.

**C (online assignment) is not this year.** It joins "Giving extra loops to runs that look like they are converging" under *Not this year*, until fleets are large enough that confounding can be controlled.

---

## Sequencing against the roadmap

| Quarter | From this design | Fits with |
|---|---|---|
| Q4 2026 (v0.7, "Make it trustworthy") | E-PR1, E-PR2, E-PR3, E-PR4 | Real runs, Doctor and clearer detentions |
| Q1 2027 (v0.8) | E-PR5, F-PR1, F-PR2 (shadow), T-PR1 | Resume (#23) reuses `run_park` and the fleet state file; Verdicts on |
| Q2 2027 (v0.9) | F-PR2 on, F-PR3, Part 3 interface additions, ticket pattern, T-PR2, T-PR3 | Ticket sources, Bring your own decider, blocker ladder PR 1 to 2 |
| Q3 2027 (v1.0) | T-PR4; T-PR5 as *stretch* | Harness adapters (#39 to #41); Stability freezes the exit codes and the pack layout |

Housekeeping found along the way: the detailed roadmap describes `lib/decider.sh` as new Q2 work, but it is already on main (1491 lines, with off/shadow/on, the calibration gate and the rerank). The roadmap should be updated to say so.

## Decisions

Settled in review on 2026-10-21:

1. **Detention gets its own exit code, 3, now, before 1.0.** Every consumer that learns from outcomes (the fleet supervisor, `chalk tune`'s ledger, CI mode) needs to tell "a human is needed" from "Chalk broke" without parsing logs, and a crash counted as a detention would teach the tuner the wrong thing. E-PR4 updates the CI gate templates in `share/templates/` in the same PR, and the release notes call out the change for scripts that test for 1.
2. **A review that fails to run blocks the pull request.** `CHALK_REVIEW_REQUIRED` defaults to `true` and the run detains with kind `review_error` (exit 3). `false` remains for repos that opt out, and then the request body says the review did not run, and why.
3. **The harness pack lives in `.chalk/harness/`.** `.chalk/prompts/` keeps working as a legacy location; when both define the same prompt, `.chalk/harness/` wins and `chalk doctor` warns. "Syllabus" stays an internal metaphor for now and is not added to the glossary.
4. **Dependency caches never carry one run's dependency changes into another.** Each run starts from a fresh branch off the latest base, and something may have merged in between, so a cache must reflect the run's own base commit, never another run's edits. See F-PR3's cache rules.

5. **`chalk share` includes tuning counts.** Proposals made, accepted and rejected, `KEEP_BASE` answers, and `chalk tune` outcomes (`effect`, `no observed effect`, `ungraded`), as counts only. Never pack contents, proposal text, file names or evidence. T-PR4 updates `PRIVACY.md` and the payload test in the same PR.
6. **The improver is an agent call, never a decider.** A proposal is open-ended writing over a whole run's evidence, which is the opposite of the bounded questions a decider answers and is calibrated on. A new key, `CHALK_TUNE_MODEL`, defaults to `CHALK_REVIEW_MODEL` (the strongest read-only model already configured), so it goes through the harness interface and is costed and capped like every other call.

## Open Questions

None at present.

## Not doing

- Depending on Harness² or Python at run time.
- Running any call, the improver's included, outside the Docker sandbox, or with forge credentials.
- A model judge in place of the rubric.
- Copying anything from Harness²'s `third_party/`.

## Success Criteria

- No real-run issue reports paid work lost to a Chalk crash, a DB restart or a sync failure; every non-success exit leaves a named branch and a `next:` line.
- Every `agent_error` detention names a class and quotes the CLI's own error line.
- A fleet of N tickets reaches a final state from one command, survives an account usage limit without detaining, and builds the image once.
- `chalk fleet`, `chalk run` and `chalk check` exit codes let a CI job tell "needs a human" from "Chalk broke".
- The report card attributes cost per checkpoint to the exact harness and lessons in effect, with the noise visible.
- After T-PR4, at least one accepted pack edit on a real repo, and after T-PR5 a measured answer, positive or `no observed effect`, with its cost.
