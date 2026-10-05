-- Local Chalk telemetry. Applied idempotently on every `chalk db up`.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- pgvector ships with the Postgres 17 image. A Postgres 16 database, not
-- yet moved by `chalk db upgrade`, goes without it.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector') THEN
        CREATE EXTENSION IF NOT EXISTS vector;
    END IF;
END
$$;

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

-- Ticket milestones: detention | submitted | spec_blocked | ready.
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
-- generalised into a reusable rule. `memory_synced_at` is no longer
-- written: it recorded when a lesson was sent to Hindsight, which was
-- removed. It is kept so that existing databases need no migration.
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
-- fp_rules is CHALK_FP_RULES for the call: off | shadow | on. NULL for
-- calls recorded before it was, when shadow was the default.
ALTER TABLE runs ADD COLUMN IF NOT EXISTS fp_rules TEXT;
-- The failing test IDs behind tests_hash, one per line and sorted, for the
-- report card's tests that keep failing. Only the first 100 are kept, so a
-- row stays small; NULL when they are unknown.
ALTER TABLE runs ADD COLUMN IF NOT EXISTS failing_tests TEXT;
-- fingerprint is set only for detentions after a failed rubric.
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS run_id TEXT;
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS fingerprint TEXT;
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS first_error TEXT;
CREATE INDEX IF NOT EXISTS lessons_fingerprint_idx ON lessons (repo, fingerprint);
-- Where a lesson is recalled: repo (only in its own repository, for a
-- lesson about that repository, or a note no lesson came of) or general.
-- NULL, for lessons from before scopes and when nothing was distilled, is
-- recalled anywhere, as general.
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS scope TEXT;

-- The decider's answers (lib/decider.sh, docs/decider-protocol.md): one row
-- per question asked, or per call that got no answer.
--   call_id     the runs row of the loop the decision was taken in
--   kind        stuck (is the loop stuck on the same root cause?) | rerank
--               (does a lesson apply?)
--   answer      yes | no; NULL when there was no answer, and error says why
--               (unreachable | timeout | budget | auth | rejected | server |
--               invalid | version)
--   confidence  0 to 1; threshold is CHALK_DECIDER_THRESHOLD when asked
--   mode        shadow | on, as the decision was taken: on is held to
--               shadow on a machine too slow for it
--   acted       the answer changed the run: it detained it (stuck) or put
--               the lesson in the prompt (rerank)
--   model       the model that answered, with its revision when known
CREATE TABLE IF NOT EXISTS decisions (
    id          BIGSERIAL PRIMARY KEY,
    call_id     BIGINT REFERENCES runs (id) ON DELETE CASCADE,
    run_id      TEXT,
    kind        TEXT NOT NULL,
    question    TEXT NOT NULL,
    answer      TEXT,
    confidence  NUMERIC(4, 3),
    threshold   NUMERIC(4, 3),
    mode        TEXT NOT NULL,
    latency_ms  INT,
    acted       BOOLEAN NOT NULL DEFAULT false,
    lesson_id   BIGINT,
    model       TEXT,
    error       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS decisions_run_idx ON decisions (run_id);
CREATE INDEX IF NOT EXISTS decisions_call_idx ON decisions (call_id);

-- Semantic recall: each resolved lesson's embedding, from chalk-embed
-- (BAAI/bge-small-en-v1.5, 384 dimensions), with an HNSW index for cosine
-- distance (`<=>`). Only where pgvector is installed: a Postgres 16
-- database goes without, and recall skips the semantic step.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
        ALTER TABLE lessons ADD COLUMN IF NOT EXISTS embedding vector(384);
        CREATE INDEX IF NOT EXISTS lessons_embedding_hnsw ON lessons
            USING hnsw (embedding vector_cosine_ops);
    END IF;
END
$$;
