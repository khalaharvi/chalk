# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Primary: individual developers who already use Claude Code and want agents to
finish tickets unattended without burning money or shipping unchecked work.
Secondary: engineering leads and platform teams rolling agents out to a team,
who care about required CI gates, a central audit trail, cost control and
ISO/IEC 42001 evidence. The README speaks to the solo developer first and has
a section for teams.

## Product Purpose

Chalk is a bash 5.3 CLI harness that runs Claude Code agents in disposable
Docker sandboxes, one small checkpoint at a time. Each loop has a spend cap,
the harness runs the test command (the rubric) itself, an independent agent
reviews the finished change, and finished work arrives as a GitHub pull
request or GitLab merge request. When an agent gets stuck, the work is parked
locally (detention) and a human unblocks it (office hours); the fix becomes a
lesson that later loops receive. Success: a ticket goes from spec to reviewed
pull request with no babysitting, and every dollar is accounted for.

## Positioning

The harness, not the agent, decides whether a checkpoint is done: it runs the
rubric itself, outside the agent's say-so, and gates the pull request again in
CI. Failures turn into reusable lessons through a human in the loop. Everything
is local: no service, no usage data.

## Operating Context

Terminal, git worktrees, Docker (Docker Desktop, OrbStack, Colima), `gh` or
`glab`, Homebrew install, a local Postgres 17 + pgvector container for
telemetry and lessons, optional Jira MCP for `chalk fleet`, optional
OpenTelemetry export. Specs are Markdown files with checkbox checkpoints in
`specs/<TICKET>.md`.

## Capabilities and Constraints

- Commands: doctor, init, db, sandbox build, prompts, new, check, run, fleet,
  status, logs, dashboard, office-hours, submit, cleanup.
- School vocabulary is product terminology and the brand: rubric (test
  command), textbook (repo-wide agent rules), spec checkpoints, detention
  (parked failure), office hours (human fix + resume), tutoring branch,
  lessons, report card (`chalk dashboard`), end of sprint (cleanup).
- Status is early (v0.6.0). Covered by an end-to-end test with fakes; few real
  runs yet. Maintained by one person, part-time. Apache-2.0.
- Planned (not shipped): docs site, more test report formats, PRIVACY.md and
  `chalk share`. See docs/roadmap.md.

## Brand Commitments

- Embrace the classroom metaphor as the identity (confirmed 2026-10-04).
- Existing visual traits in `share/dashboard.html`: chalkboard green
  `#1c342d`, chalk cream `#f1eee3`, chalk yellow `#f0d878`, typewriter display
  face (American Typewriter), plain sans body.
- Voice: plain, precise, British-leaning spelling in places ("organisation"),
  no hype, states limits honestly.

## Evidence on Hand

Real CLI help output (`bin/chalk help`), the real dashboard template, the
config table, the CHANGELOG. No users, testimonials, benchmarks, stars or
recorded demo yet; none may be invented.

## Product Principles

- The harness verifies; the agent only reports.
- Real runs before new features; rules before models; shadow mode first.
- Optional services never block a run.
- Nothing leaves the machine unless the user sends it.
- Honest about maturity.
