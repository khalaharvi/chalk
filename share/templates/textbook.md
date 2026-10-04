# Global engineering rules (the Textbook)

These rules apply to every agent in every repository and override CLAUDE.md
where the two conflict. Keep this file in sync with your organisation's
source of truth; it is versioned here so that every run is reproducible and
reviewable.

Replace the examples below with your own standards.

## Architecture
- Use only approved packages. Do not add a dependency that duplicates one
  already in the project.
- Persist data in PostgreSQL only. SQLite is allowed in tests.
- Protect every API route with the shared authentication middleware. Never
  write bespoke authentication.

## Quality
- Write the failing test before the implementation.
- Never weaken or delete a test to make a change pass.
- Send business-critical events to the telemetry library, not to stdout.

## Safety
- Never read, print or commit secrets.
- Never change CI configuration, `.chalk/`, or this file.
