-- Local Chalk telemetry. Applied idempotently on every `chalk db up`.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- One row per agent call: what it cost, what it used and what came of it.
--   kind          continue | retry | fix-review | spec-check | review | distill
--   agent_status  loops: ok | blocked | <cli error>; checks: pass | fail | none
--   loop          position in the run; 0 for calls outside the loop
--   progressed    the call moved the ticket forward (a checkpoint was ticked
--                 and committed, or review findings were fixed)
--   prompts       short hash of the prompt set in use, for comparing versions
CREATE TABLE IF NOT EXISTS runs (
    id                  BIGSERIAL PRIMARY KEY,
    repo                TEXT NOT NULL,
    ticket              TEXT NOT NULL,
    branch              TEXT NOT NULL,
    loop                INT  NOT NULL,
    kind                TEXT NOT NULL,
    agent_status        TEXT NOT NULL,
    rubric_exit         INT  NOT NULL,
    progressed          BOOLEAN NOT NULL,
    model               TEXT NOT NULL,
    prompts             TEXT NOT NULL,
    cost_usd            NUMERIC(10, 4) NOT NULL,
    budget_usd          NUMERIC(10, 4) NOT NULL,
    duration_s          INT  NOT NULL,
    input_tokens        BIGINT NOT NULL,
    output_tokens       BIGINT NOT NULL,
    cache_read_tokens   BIGINT NOT NULL,
    cache_write_tokens  BIGINT NOT NULL,
    turns               INT  NOT NULL,
    denials             INT  NOT NULL,
    lessons             INT  NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS runs_ticket_idx ON runs (repo, ticket);
CREATE INDEX IF NOT EXISTS runs_created_idx ON runs (created_at);

-- Ticket milestones: detention | submitted | spec_blocked.
CREATE TABLE IF NOT EXISTS events (
    id          BIGSERIAL PRIMARY KEY,
    repo        TEXT NOT NULL,
    ticket      TEXT NOT NULL,
    kind        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS events_ticket_idx ON events (repo, ticket);

-- One row per detention. `resolution` is the engineer's note from office
-- hours and is the record of human intervention; `lesson` is that note
-- generalised into a reusable rule.
CREATE TABLE IF NOT EXISTS lessons (
    id                BIGSERIAL PRIMARY KEY,
    repo              TEXT NOT NULL,
    ticket            TEXT NOT NULL,
    signature         TEXT NOT NULL,
    resolution        TEXT,
    lesson            TEXT,
    resolved_by       TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at       TIMESTAMPTZ,
    memory_synced_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS lessons_signature_trgm ON lessons USING gin (signature gin_trgm_ops);

-- Loop fingerprints (lib/fingerprint.sh). Added to existing databases in
-- place; every column is nullable, so older rows stay valid.
--   run_id       one `chalk run`: TICKET-EPOCHSECONDS; links a lesson to its run
--   tests_hash   sha256 of the failing test IDs; NULL when they are unknown
--   failing      how many tests failed; NULL when unknown, never 0 for unknown
--   first_error  the first error line, normalized
--   tree_id      git tree ID of the working tree after the loop
--   verdict      for loops that made no progress: blocked | agent_error |
--                first | deja_vu | repeat | no_change | improving |
--                spinning | other
ALTER TABLE runs ADD COLUMN IF NOT EXISTS run_id TEXT;
ALTER TABLE runs ADD COLUMN IF NOT EXISTS tests_hash TEXT;
ALTER TABLE runs ADD COLUMN IF NOT EXISTS failing INT;
ALTER TABLE runs ADD COLUMN IF NOT EXISTS first_error TEXT;
ALTER TABLE runs ADD COLUMN IF NOT EXISTS tree_id TEXT;
ALTER TABLE runs ADD COLUMN IF NOT EXISTS verdict TEXT;
-- fingerprint is set only for detentions after a failed rubric.
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS run_id TEXT;
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS fingerprint TEXT;
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS first_error TEXT;
CREATE INDEX IF NOT EXISTS lessons_fingerprint_idx ON lessons (repo, fingerprint);
