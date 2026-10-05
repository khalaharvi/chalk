# Roadmap: October 2026 to September 2027

Chalk is maintained by one person, part-time. This roadmap is a plan, not
a promise: each quarter starts by fixing whatever real runs broke, and
items move when the numbers say they should. Quarters are calendar
quarters, so Q4 2026 means October to December.

Each item links to its design notes in the
[detailed roadmap](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md). Progress is tracked on the
[GitHub project board](https://github.com/users/khalaharvi/projects/1), and
the pinned [roadmap issue](https://github.com/khalaharvi/chalk/issues/53)
is the place to comment on priorities.

Principles that hold for every item:

- Real runs come before new features.
- Rules come before models. Anything that can change a run ships in
  shadow mode first: it records what it would have done and changes
  nothing. It is turned on only when the report card (`chalk dashboard`)
  shows it pays.
- Optional services never block a run.
- Chalk collects no usage data. Your code goes only to the model provider
  you configure, and anything else leaves your machine only when you
  choose to send it.

**Already shipped in v0.6.0:** stuck-loop verdicts in shadow mode
(`CHALK_FP_RULES`), JUnit XML test reports (`CHALK_TEST_REPORT`), and
Postgres 17 with pgvector and `chalk db upgrade`.

## Q4 2026: Make it trustworthy (v0.7)

- **[Real runs](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#real-runs).** Use Chalk on
  itself and on Node, Python and Go repositories, on both GitHub and
  GitLab. Fix what breaks.
- **[Docs site](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#docs-site)** with a glossary of
  the school terms (rubric, detention, office hours, report card) and a
  recorded demo.
- **[More test report formats](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#test-reports):**
  `go test -json` and `jest --json`.
- **[chalk doctor and clearer detentions](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#doctor).**
  Detention is where a run stops when it cannot make progress; each reason
  will say what to do next.
- **[PRIVACY.md and chalk share](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#data).** See
  "Data" below.

## Q1 2027: Cheaper loops, open models (v0.8)

- **[Lesson recall](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#recall)** by the fingerprint
  of a failure, replacing the optional Hindsight memory server. Done in
  [#55](https://github.com/khalaharvi/chalk/pull/55), in the next release.
- **[Verdicts on](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#verdicts-on):** let the
  stuck-loop verdicts stop runs early, where the shadow numbers show it
  saves money.
- **[Resume after a crash](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#resume)**, sleep or
  Ctrl-C without losing paid work.
- **[Bring your own model](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#bring-your-own-model)** inside
  Claude Code: a model per kind of call; Bedrock, Vertex and gateways such
  as LiteLLM; and a price table for providers that do not report cost, so
  the report card stays accurate and a run stops once it goes over budget.

## Q2 2027: Easier start, your own decider (v0.9)

- **[Sandbox images](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#stack-images)** for Python,
  Go, Rust and the JVM, and `chalk init` that detects your stack.
- **[chalk spec draft](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#spec-draft)** to write
  checkpoints from a ticket.
- **[GitHub and GitLab issues](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#ticket-sources)**
  as ticket sources for `chalk fleet`.
- **[Bring your own decider](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#bring-your-own-decider).** A
  decider is a small, fast model that answers bounded questions such as
  "is this loop stuck?" so Chalk does not have to ask Claude. You will be
  able to run the local reference service or point Chalk at a hosted one.
  Every decider starts in shadow mode and has to show its confidence is
  trustworthy before it may act. Hosted deciders are never the default,
  and Chalk says exactly what they receive.

## Q3 2027: Beyond Claude Code, then 1.0 (v1.0)

- **[Harness adapters](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#harnesses).** Claude Code
  becomes one adapter; Codex CLI is the first other one. The report card
  compares cost per finished checkpoint across harnesses.
- **[Run in CI](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#ci-mode).** Label an issue and
  get a pull request. Detention becomes a comment, and replying to it does
  what `chalk office-hours` does on your machine.
- **[1.0 stability](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#stability):** stable config
  keys, interfaces, schemas and flags, with a deprecation policy and a
  migration guide.

Items marked *stretch* in the detailed roadmap move to the backlog before
any quarter slips.

## Data

Chalk collects no usage data today, and that stays the default.

1. **You send it (Q4).** `chalk share` builds an anonymised summary of your
   report card: version, OS, harness, models, stack, and counts and rates.
   It never includes repository names, paths, ticket IDs, code, prompts,
   test output or lesson text. It prints the exact JSON, and you decide
   whether to post it to a GitHub Discussion.
2. **Opt-in telemetry (Q3).** Only if too few people post `chalk share`
   reports to tune the defaults. `chalk init` asks once, and the default is
   no. `chalk telemetry show` prints the next payload before it is sent;
   `CHALK_TELEMETRY=off` and `DO_NOT_TRACK=1` always win; CI runs never
   report. The ingest code lives in this repository.

## How to help

- Run Chalk on a real repository and file what breaks with the
  [`real-run` label](https://github.com/khalaharvi/chalk/labels/real-run).
- Comment on any [roadmap issue](https://github.com/khalaharvi/chalk/labels/roadmap).
- From Q4, post your `chalk share` report card in Discussions.

## Not this year

- A hosted service or paid tier.
- A web UI beyond the report card.
- Giving extra loops to runs that look like they are converging.
- A central lessons server.

## Backlog

See the [backlog](https://github.com/khalaharvi/chalk/blob/main/docs/designs/roadmap-2026-27.md#backlog) for what comes next
when there is time: shared lessons, hooks and extra gates, Linux and
Podman, budget alerts, and more.
