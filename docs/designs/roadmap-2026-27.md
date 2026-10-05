# Design: Chalk roadmap, October 2026 to September 2027

- **Status:** approved 2026-10-04
- **Public summary:** [the roadmap page](../roadmap.md)
- **Tracking:** [GitHub project board](https://github.com/users/khalaharvi/projects/1),
  grouped by its `Quarter` field, and the pinned
  [roadmap issue](https://github.com/khalaharvi/chalk/issues/53)

This document holds the detail that the roadmap issues link to. Every
section names its milestone, issue, dependencies and finish line, and
should make sense without reading anything else first. If an issue and this
document disagree, fix one of them in the same PR.

Section headings are link targets for the issues. Do not rename them
without updating the issues that link to them.

## Direction and capacity

- **Who it is for:** individual developers and small teams who install Chalk
  from Homebrew. It is open source. There is no hosted service or paid tier
  this year.
- **Capacity:** one maintainer, part-time, about 25 to 35 PRs in the year.
  Each quarter has one theme and ends in a release.
- **When a quarter slips:** items marked *stretch* move to the
  [backlog](#backlog) first.
- **Where it starts:** v0.6.0 (released 2026-10-05) shipped stuck-loop
  verdicts in shadow mode
  ([#5](https://github.com/khalaharvi/chalk/pull/5), `lib/fingerprint.sh`),
  JUnit XML input through `CHALK_TEST_REPORT`, and Postgres 17 with pgvector
  and `chalk db upgrade`
  ([#6](https://github.com/khalaharvi/chalk/pull/6)). Those were PR 1 and
  PR 3a of [the decider design](system-1-decider.md).

## Terms

- **Rubric:** the test command (`CHALK_TEST_CMD`) that the harness runs
  itself after every loop.
- **Detention:** where a run stops when it cannot make progress. Its work
  is parked on a local `detention/…` branch.
- **Office hours:** `chalk office-hours`. A person fixes the blocker, leaves
  a note, and the loop resumes. The note becomes a lesson.
- **Lesson:** a general rule distilled from an office-hours note, recalled
  on later loops.
- **Report card:** `chalk dashboard`, a static HTML page built from the
  local `runs` table.
- **Shadow mode:** a rule or model records what it would have done and
  changes nothing. `on` lets it act.
- **Fingerprint:** what a loop reduces to after the rubric runs: the
  failing tests, the normalised first error and the working-tree id
  (`lib/fingerprint.sh`).
- **Verdict:** the label a loop that made no progress gets, from its
  fingerprint. These three can stop a run early:
  - `deja_vu`: the same failure as an unresolved past lesson;
  - `repeat`: the same failure and the same tree as the previous loop;
  - `no_change`: the agent changed nothing.
- **Decider (System 1):** a small, fast model that answers bounded
  questions so Chalk does not have to ask Claude: yes / no / unknown
  (`noul`), pick one (`choice`), or a score. Each answer comes with a
  confidence. "System 1" is the fast, intuitive half of Kahneman's
  thinking model; Claude is System 2.
- **Hindsight:** an optional external lesson-memory server
  (`CHALK_MEMORY=hindsight`), removed in Q1.
- **Harness:** the coding-agent CLI that runs each loop. Today it is always
  Claude Code.

## Rules that apply to every item

1. **Real runs before features.** Each quarter starts by fixing `real-run`
   issues.
2. **Rules before models; shadow before on.** Anything that can change a
   run's outcome ships in shadow mode first (see `CHALK_FP_RULES`). It is
   switched on only when the report card shows it pays.
3. **Optional services never block a run.** When a decider, memory server or
   gateway is down or slow, the run behaves as if the feature were off.
4. **Chalk collects no usage data.** Code goes only to the model provider
   the user configures. Anything else leaves the machine only when the user
   chooses to send it. See [Data](#data).
5. **Every feature that changes a run shows up on the report card**
   (`share/dashboard.sql`, `lib/dashboard.sh`).
6. **House rules:** bash 5.3 on the host and 5.2 in the sandbox
   ([the bash style guide](../bash-style.md)), a fake in `tests/fakes/` for
   every external service the harness drives (today `docker`, `claude`,
   `gh`, `glab`, `curl`; not local tools such as `git` or `jq`), and a unit test or e2e case (`tests/e2e.sh`)
   with every behaviour change. `make check` and `make test-db` stay green.

## Milestones

| Milestone | Due | Theme |
| :-- | :-- | :-- |
| v0.6 | released | Stuck-loop verdicts, JUnit XML, Postgres 17 |
| v0.7 | 2026-12-31 | Make it trustworthy |
| v0.8 | 2027-03-31 | Cheaper loops, open models |
| v0.9 | 2027-06-30 | Easier start, your own decider |
| v1.0 | 2027-09-30 | Beyond Claude Code, then 1.0 |

---

## Q4 2026: Make it trustworthy (v0.7)

### Real runs

Milestone v0.7 · [#7](https://github.com/khalaharvi/chalk/issues/7) ·
Depends on nothing

Run Chalk on Chalk and on 2–3 outside repositories: Node, Python and Go,
with at least one on GitHub and one on GitLab. Use real Docker (Docker
Desktop, OrbStack or Colima), the real `claude` CLI and real `gh`/`glab`.

- File every rough edge as an issue labelled `real-run`, with an excerpt
  of the run log (under `~/.local/state/chalk/`) and the `chalk doctor`
  output.
- Keep the runs in the local database. They are the baseline for every
  later "did it pay?" question, and for [Verdicts on](#verdicts-on).
- **Done when:** 50+ real runs are recorded and there are no open crash bugs
  in `run`, `fleet` or `office-hours`.

### Docs site

Milestone v0.7 · [#8](https://github.com/khalaharvi/chalk/issues/8) ·
Depends on nothing

Build the approved docs-site design (in `docs/superpowers/specs/`, dated
2026-10-03): MkDocs Material on GitHub Pages, a glossary of the school
terms, and a recorded demo of a run going to detention, through office
hours, to a merged change. The demo is recorded against the test fakes. CI
checks links.

- Add `roadmap.md` to the site navigation.
- Exclude `docs/designs/` and `docs/specs/` from the build, next to
  `docs/superpowers/`. They hold working notes. Pages on the site link to
  them by full GitHub URL, so `mkdocs build --strict` does not fail.
- **Done when:** the site rebuilds on every push to `main`.

### Test reports

Milestone v0.7 · [#14](https://github.com/khalaharvi/chalk/issues/14),
[#4](https://github.com/khalaharvi/chalk/issues/4) · Depends on nothing

JUnit XML shipped in v0.6.0 (`CHALK_TEST_REPORT`, read by
`fp_failing_tests` in `lib/fingerprint.sh`). What remains is #4: readers for
`go test -json` and `jest --json`, chosen by file content.

- Feed the failing test names into fingerprints, into the `retry` prompt
  ("these 2 tests still fail") and into a report-card panel.
- **Done when:** each format has fixtures in
  `tests/unit/fingerprint_test.sh` and produces the same fingerprint fields
  as JUnit XML.

### Doctor

Milestone v0.7 · [#16](https://github.com/khalaharvi/chalk/issues/16) ·
Depends on nothing

Extend `cmd_doctor` in `lib/setup.sh`, using its `doctor_check` helper:

- **Auto mode:** check that it is available for `CHALK_MODEL`. Without it,
  a headless run starts in manual mode and every edit is refused. That is
  the most confusing failure today (see "Permissions" in the README).
- **Next step on detention:** every detention reason (`blocked`, loop
  limit, retries exhausted, review failed, and each verdict) prints one
  line saying what to do next. This is `run_detain` in `lib/run.sh`.
- **Done when:** each detention reason has a next-step line covered by an
  e2e assertion.

---

## Data

Milestone v0.7 (step 1), v1.0 (step 2) ·
[#17](https://github.com/khalaharvi/chalk/issues/17) · Depends on nothing

Chalk collects no usage data today. The report card says "Nothing is served
and nothing leaves the machine" (`lib/dashboard.sh`), and that stays the
default for good. Usage data is gathered in two steps. Step 2 is more
automatic than step 1, and both need the user to act.

**What may ever be shared:** the Chalk version, OS, harness, model names,
the detected stack, and counts and rates from the `runs` table: loops, cost
per finished checkpoint, detentions by reason, review pass rate,
verdict-ledger outcomes and spend by kind of call.

**What is never shared:** repository names or URLs, paths, branch names,
ticket IDs, code, diffs, prompts, test output, lesson text, office-hours
notes, or anything a user typed.

### Privacy page

Milestone v0.7 · [#18](https://github.com/khalaharvi/chalk/issues/18)

Write `PRIVACY.md` and a matching docs page. They list what Chalk stores on
the machine (the `runs` and `lessons` tables, and the run logs under
`~/.local/state/chalk/`) and every way data can leave it:

- **The model provider** (Anthropic API, Bedrock, Vertex or a gateway), on
  every agent call: the prompt, the code the agent reads in the sandbox,
  and test output;
- **a Hindsight server and its LLM**, while that backend exists;
- **a hosted decider or an OpenTelemetry endpoint**, when the user
  configures one;
- **the CI audit table** (`share/ci-audit-schema.sql`), when configured;
- **`chalk share` and opt-in telemetry**, only when the user acts.

### chalk share

Milestone v0.7 · [#19](https://github.com/khalaharvi/chalk/issues/19)

`chalk share [--days N] [--json]` lives in a new `lib/share.sh`. It runs one
query in the style of `share/dashboard.sql` and builds the payload
described under [Data](#data).

- It prints the exact JSON first.
- Then it offers to open a prefilled GitHub Discussion in the "Report cards"
  category, or to copy the JSON to the clipboard.
- It never sends anything itself.

### Templates

Milestone v0.7 · [#20](https://github.com/khalaharvi/chalk/issues/20)

Add issue templates in `.github/ISSUE_TEMPLATE/`:

- **"Real-run report":** asks for `chalk doctor` output and an optional
  `chalk share`;
- **"Detention I couldn't fix";**
- **"Harness or model request".**

Turn on Discussions with a "Report cards" category.

### Payload test

Milestone v0.7 · [#21](https://github.com/khalaharvi/chalk/issues/21) ·
Depends on [chalk share](#chalk-share)

An e2e case seeds the database and state directory with sentinel strings,
for example `SENTINEL_REPO`, `/SENTINEL/path`, `SENT-123` and a note
containing `SENTINEL_TEXT`. It asserts that none of them appear in the
`chalk share` output or in the telemetry payload. It runs in `make check`.

### Telemetry

Milestone v1.0 · [#22](https://github.com/khalaharvi/chalk/issues/22) ·
Depends on [chalk share](#chalk-share) · *stretch*

This is step 2. It ships only if too few people post `chalk share` reports
to tune the defaults.

- `chalk init` asks once, and the default is **No**.
- Subcommands: `chalk telemetry on|off|show|reset`.
- `CHALK_TELEMETRY=off` and `DO_NOT_TRACK=1` always win. Runs in CI (where
  `CI` is set) never report.
- It sends the same payload as `chalk share`, at most once a week, with a
  random install ID that `reset` rotates. `show` prints the next payload.
- The ingest code lives in this repository, its retention is published, and
  the README names the endpoint.

---

## Q1 2027: Cheaper loops, open models (v0.8)

### Recall

Milestone v0.8 · [#11](https://github.com/khalaharvi/chalk/issues/11) ·
Depends on nothing

This is PR 2 of [the decider design](system-1-decider.md).

- Recall lessons by exact fingerprint first, then by lexical similarity on
  the normalised first error. Today `memory_recall` (`lib/memory.sh`,
  called from `run_build_prompt` in `lib/run.sh`) matches against the whole
  spec or against raw log lines.
- Remove Hindsight: its backend in `lib/memory.sh` and the `CHALK_MEMORY*`
  keys in `lib/config.sh`.
- The design also changes the retry feedback. Ship that behind a new
  `CHALK_FP_FEEDBACK` key, default off, for a measurement window, so the
  effect of recall and the effect of feedback can be told apart
  ([reviewer concern R2-12](system-1-decider.md#r2-12--scope)).
- **Done when:** recall finds the right lesson for a repeated failure in an
  e2e case, and nothing references Hindsight.

### Verdicts on

Milestone v0.8 · [#12](https://github.com/khalaharvi/chalk/issues/12) ·
Depends on [Real runs](#real-runs)

v0.6.0 records verdicts in shadow mode, and the report card's "Would
stopping early have paid?" panel shows what each one would have saved and
how often it would have been wrong.

- From the real runs, decide for each of `deja_vu`, `repeat` and
  `no_change` whether it may stop runs early (`CHALK_FP_RULES=on`) or should
  stay in shadow mode.
- **Done when:** the PR that changes the default includes those numbers.

### Resume

Milestone v0.8 · [#23](https://github.com/khalaharvi/chalk/issues/23) ·
Depends on nothing

`chalk run` survives laptop sleep, a Docker restart or Ctrl-C without
losing a loop's paid work.

The pieces it builds on already exist:
- `run_claim` (`lib/run.sh`) and the pid files in `lib/state.sh`;
- `sandbox_export`, which writes a git bundle (`lib/sandbox.sh`);
- the signal handling in `lib/core/runtime.sh`.

A resumed run starts from the last committed checkpoint and the notes file.

**Done when:** an e2e case kills a run in the middle of a loop and resumes
it to completion.

### Bring your own model

Milestone v0.8 · [#24](https://github.com/khalaharvi/chalk/issues/24) ·
Depends on nothing

The goal is any model or provider Claude Code can reach, while keeping the
spend cap and the report card. This all happens inside Claude Code. Other
harnesses come in [Harnesses](#harnesses).

**What exists today:**
- `CHALK_MODEL` for loops, `CHALK_REVIEW_MODEL` for review, and
  `CHALK_CHEAP_MODEL` for the spec check and distillation
  (`lib/run.sh:198`, `lib/lifecycle.sh:28`);
- `CHALK_AUTH_VARS` (`lib/sandbox.sh:14`) plus `ANTHROPIC_BASE_URL`,
  passed into the sandbox at `lib/sandbox.sh:79`.

#### Model per call kind

[#25](https://github.com/khalaharvi/chalk/issues/25)

Add `CHALK_MODEL_RETRY`, `CHALK_MODEL_FIX`, `CHALK_MODEL_SPEC_CHECK` and
`CHALK_MODEL_DISTILL`. Each falls back to the existing keys, so nothing
breaks. `CHALK_CHEAP_MODEL` stays as the fallback for the last two. Each
call already records the model that ran it (`agent_model`), so the report
card's per-model panel works unchanged.

#### Providers

[#26](https://github.com/khalaharvi/chalk/issues/26)

Test and document these providers:

- the Anthropic API;
- Bedrock (`CLAUDE_CODE_USE_BEDROCK` plus AWS credentials);
- Vertex (`CLAUDE_CODE_USE_VERTEX` plus Google Cloud credentials);
- gateways through `ANTHROPIC_BASE_URL`, such as LiteLLM in front of
  non-Anthropic models.

Adding the provider variables to `CHALK_AUTH_VARS` does two jobs: it
passes them into the sandbox and makes `agent_auth_present` accept them. As
now, they are passed as `-e VAR` with no value, which keeps secrets out of
`ps`.

#### Price table

[#27](https://github.com/khalaharvi/chalk/issues/27)

The spend cap is `--max-budget-usd` (`lib/agent.sh:56`). The Claude CLI
enforces it using its own price list. The report card uses
`total_cost_usd` (`agent_cost`). With a gateway or a non-Anthropic model,
both can be wrong or zero.

- Add `CHALK_PRICE_TABLE`, a file of `model input_per_mtok output_per_mtok`
  rows. When a model appears in it, `agent_cost` prices tokens from
  `agent_usage` instead of trusting `total_cost_usd`.
- Record `cost_estimated=true`, and the report card marks those costs as
  estimated.
- When the cost comes from the table, the harness checks after each call
  whether the run went over `CHALK_BUDGET_USD`. If it did, it stops the
  run. This is detect-and-stop, not a cap: one call can overspend before it
  is caught. The docs must say so.

#### Model check

[#28](https://github.com/khalaharvi/chalk/issues/28)

`chalk doctor` warns when the loop model cannot use auto mode.
`load_config` already refuses Haiku with auto mode (`lib/config.sh:77`).
Generalise that check, either with a probe or with a known list per
provider.

**Done when:** a run on Bedrock and a run through a LiteLLM gateway each
complete in a real-run test, with the costs on the report card marked
correctly.

---

## Q2 2027: Easier start, your own decider (v0.9)

### Stack images

Milestone v0.9 · [#29](https://github.com/khalaharvi/chalk/issues/29) ·
Depends on nothing

Publish sandbox images for Python, Go, Rust and the JVM, built `FROM`
`share/sandbox/Dockerfile` with bash 5.2+ and the `claude` CLI.

- `chalk init` (`cmd_init`, `lib/setup.sh`) detects the stack from
  lockfiles. It proposes `CHALK_TEST_CMD`, `CHALK_SETUP_CMD`,
  `CHALK_TEST_REPORT` and `CHALK_IMAGE`.
- **Done when:** someone new to Chalk with a Python or Go repository gets
  from `brew install` to a merged PR by following only the docs.

### Spec draft

Milestone v0.9 · [#30](https://github.com/khalaharvi/chalk/issues/30) ·
Depends on nothing

`chalk spec draft TICKET [TEXT]` drafts `specs/TICKET.md` from a ticket or
a sentence, using the `breakdown` prompt (`share/prompts/breakdown.md`). It
then runs `chalk check` on the draft and prints the spec check's findings.
A bad spec is the most likely reason a new user's first run fails.

**Done when:** an e2e case drafts a spec that passes `chalk check`.

### Ticket sources

Milestone v0.9 · [#31](https://github.com/khalaharvi/chalk/issues/31) ·
Depends on nothing

`chalk fleet` reads an epic through Claude Code and the Jira MCP server on
the host (`fleet_plan`, `lib/fleet.sh`). Add GitHub and GitLab issues as
sources, using `gh issue view` / `glab issue view` and sub-issues or task
lists, with no MCP setup. The source is picked from the ticket format (for
example `#123`) or from `--source`. Add Linear only if users ask for it.

**Done when:** `chalk fleet '#123'` plans and launches from a GitHub issue
with sub-issues, against the fake `gh`.

### Bring your own decider

Milestone v0.9 · [#32](https://github.com/khalaharvi/chalk/issues/32) ·
Depends on [Verdicts on](#verdicts-on)

This is PR 3b of [the decider design](system-1-decider.md), reframed as an
interface with several providers rather than one local service. The
decider answers bounded questions, such as "is this loop stuck?" or "which
lessons apply?", using whatever the user has: the local reference service
or a hosted endpoint.

#### Decider protocol

[#33](https://github.com/khalaharvi/chalk/issues/33)

Write `docs/decider-protocol.md`:

- **Request:** one text (the loop's evidence) and up to N questions, each
  of type `noul` (yes / no / unknown), `choice` (one of a list) or `score`
  (0 to 1).
- **Response:** for each question, an answer and a confidence from 0 to 1.
- **Errors:** timeouts, auth, and a version field. The timeout is one
  budget per loop, not per call
  ([reviewer concern R2-11](system-1-decider.md#r2-11--consistency)).

The local service and every adapter speak this protocol.

#### Decider endpoint

[#34](https://github.com/khalaharvi/chalk/issues/34)

- New keys: `CHALK_DECIDER=off|shadow|on`, `CHALK_DECIDER_URL` and
  `CHALK_DECIDER_TOKEN`, in a new `lib/decider.sh`.
- `chalk decider up` installs and runs the reference service on 127.0.0.1
  through `uv`. It serves the decider model plus a small embedding model on
  Apple's MLX, CUDA, Apple's MPS or the CPU. It never runs in the sandbox,
  and the Homebrew formula does not depend on it.
- A fake service in `tests/fakes/` covers the e2e cases.

#### Chat adapter

[#35](https://github.com/khalaharvi/chalk/issues/35) · *stretch*

Some hosted providers offer only a chat or classification API, such as
OpenAI-compatible endpoints or hosted small models. An adapter behind the
same protocol covers them:

- it turns each question into a constrained prompt with an enum answer and
  JSON output;
- it takes confidence from log-probs where the provider returns them, or
  from a score the provider returns. Otherwise it reports the answer as
  uncalibrated, and an uncalibrated answer never acts.

Before building it, name the hosted providers it targets and check their
API style.

#### Calibration gate

[#36](https://github.com/khalaharvi/chalk/issues/36)

"Act only at ≥ 0.9 confidence" is safe only if the model's confidence is
calibrated, meaning a 0.9 answer is right about 90% of the time.

- Every provider starts in `shadow`.
- The ledger records each high-confidence answer next to what actually
  happened in later loops.
- `on` is allowed only once a provider's high-confidence answers agree with
  outcomes at the required rate over a minimum sample. `chalk doctor` shows
  the current numbers.

#### Hosted disclosure

[#37](https://github.com/khalaharvi/chalk/issues/37)

A hosted decider receives test output and diffs. `chalk doctor`, and the
first run that uses one, print exactly what will be sent and where. A
hosted decider is never the default, and the [Privacy page](#privacy-page)
lists it.

**Done when:** the local service and one hosted provider both run in
shadow mode on real runs, and the calibration numbers show on the report
card.

---

## Q3 2027: Beyond Claude Code, then 1.0 (v1.0)

### Harnesses

Milestone v1.0 · [#38](https://github.com/khalaharvi/chalk/issues/38) ·
Depends on [Bring your own model](#bring-your-own-model) (for the price
table)

Every agent call goes through `agent_call` (`lib/agent.sh:53-68`). Its
results are read by `agent_field`, `agent_cost`, `agent_model` and
`agent_usage`. That makes the harness the one place to abstract.
`fleet_plan` also calls `claude` on the host to plan a fleet.

#### Harness interface

[#39](https://github.com/khalaharvi/chalk/issues/39)

Move that code into `lib/harness/claude.sh` behind an interface chosen by
`CHALK_HARNESS` (default `claude`). An adapter must provide:

1. a headless call with the prompt on stdin and Chalk's system prompt
   appended;
2. structured output against Chalk's schemas (`CHALK_SCHEMA`), natively or
   through a parse-and-validate fallback that counts as an agent error when
   it fails;
3. two access levels: `write`, which runs autonomously like auto mode, and
   `read`, which is read-only for the spec check, review and distillation;
4. a spend cap per call, or the harness-side check in
   [Price table](#price-table);
5. cost, tokens, turns, permission denials and the model used, normalised
   to what `db_record_call` stores;
6. sandbox image requirements: the CLI installed, and its auth variables
   passed through.

Claude Code's behaviour does not change, and the existing tests pass
untouched.

#### Codex adapter

[#40](https://github.com/khalaharvi/chalk/issues/40) · Depends on
[Harness interface](#harness-interface)

`lib/harness/codex.sh` uses `codex exec`. It ships with a fake
`tests/fakes/codex`, an image variant with the Codex CLI installed, and an
e2e run through a whole ticket, including detention and office hours.

#### Report by harness

[#41](https://github.com/khalaharvi/chalk/issues/41) · Depends on
[Harness interface](#harness-interface)

Record the harness on each call in `runs`. The report card then breaks
down cost per finished checkpoint, detentions and review pass rate by
harness, so users get a like-for-like comparison.

#### Second adapter

[#42](https://github.com/khalaharvi/chalk/issues/42) · Depends on
[Codex adapter](#codex-adapter) · *stretch*

Gemini CLI or opencode, picked by the number of "Harness or model request"
issues.

**Done when:** one ticket completes end to end on Codex CLI in a real run,
and the report card compares it with Claude Code.

### CI mode

Milestone v1.0 · [#43](https://github.com/khalaharvi/chalk/issues/43) ·
Depends on [Resume](#resume)

A GitHub Action, and a GitLab CI component (*stretch*), that run a ticket
in CI. They build on the existing gate templates in `share/templates/`.

- Label an issue `chalk`, or comment `/chalk run`. The job runs the loop
  and opens the PR.
- On detention, the job posts a comment with the failure and the parked
  branch. A reply of `/chalk office-hours <note>` resumes the loop.
- **Done when:** at least one outside repository uses it.

### Stability

Milestone v1.0 · [#44](https://github.com/khalaharvi/chalk/issues/44) ·
Depends on every other v1.0 item

For 1.0, freeze:

- the configuration keys: the repository keys in `CHALK_CONFIG_DEFAULTS`
  and the machine keys in `CHALK_ENV_DEFAULTS` (both in `lib/config.sh`),
  including the keys this roadmap adds (`CHALK_MODEL_*`,
  `CHALK_PRICE_TABLE`, `CHALK_DECIDER*`, `CHALK_HARNESS`, `CHALK_TELEMETRY`);
- the prompt override names;
- the JSON schemas;
- the database schema;
- the harness and decider interfaces;
- the CLI commands and flags.

Add a deprecation policy: deprecated keys warn for one minor release before
they are removed, and `chalk doctor` flags them. Write a migration guide
from 0.x and an announcement with real report-card numbers.

**Done when:** v1.0 is tagged, and no breaking change is needed in the
month after.

---

## Not this year

- A hosted service or paid tier.
- A web UI beyond the static report card.
- Giving extra loops to runs that look like they are converging (decider
  v2 in [the decider design](system-1-decider.md)).
- A central lessons server.

## Backlog

These are pulled in when there is time or a user asks. Each has an issue
labelled `roadmap` with no milestone.

- **Shared lessons**
  ([#45](https://github.com/khalaharvi/chalk/issues/45)):
  `chalk lessons export|import` to a committed `.chalk/lessons.jsonl`, so a
  team shares lessons through git.
- **Hooks and gates**
  ([#46](https://github.com/khalaharvi/chalk/issues/46)): pre- and post-loop
  hooks, and extra gates such as lint, typecheck and coverage, as commands
  in config, each recorded like the rubric.
- **Linux and Podman**
  ([#47](https://github.com/khalaharvi/chalk/issues/47)): run the e2e suite
  on Linux in CI, and document Podman and Docker Engine.
- **Pre-flight check**
  ([#48](https://github.com/khalaharvi/chalk/issues/48)): before the first
  loop, ask a decider one `noul` question per checkpoint: "does this need
  network, secrets or a human decision?"
- **Budget alerts**
  ([#49](https://github.com/khalaharvi/chalk/issues/49)): a warning in
  `chalk status` and on the report card when spend across runs passes a
  daily or weekly limit.
- **Fleet ordering**
  ([#50](https://github.com/khalaharvi/chalk/issues/50)): dependencies
  between workstreams in the fleet plan, so dependent work waits.
- **WSL2** ([#51](https://github.com/khalaharvi/chalk/issues/51)): a docs
  page for running Chalk on Windows through WSL2.
- **Image signing**
  ([#52](https://github.com/khalaharvi/chalk/issues/52)): sign published
  sandbox images and attach a software bill of materials (SBOM).
