-- Apply once to the central database behind $CHALK_AUDIT_DB_URL.
CREATE TABLE IF NOT EXISTS chalk_audit (
    id             BIGSERIAL PRIMARY KEY,
    project        TEXT NOT NULL,
    ticket         TEXT NOT NULL,
    merge_request  INT NOT NULL,
    commit_sha     TEXT NOT NULL,
    pipeline_id    BIGINT NOT NULL,
    status         TEXT NOT NULL,
    recorded_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
