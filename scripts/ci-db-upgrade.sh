#!/usr/bin/env bash
# A real Postgres 16 -> 17 upgrade, done by chalk itself against real
# Docker (issue #13). It sets up an install from before Postgres 17, fills
# it with representative rows, then checks that:
#   - an upgrade that fails puts the Postgres 16 container back, unchanged,
#     both when the new container cannot be created and when it is
#     interrupted by a timeout (the EXIT trap)
#   - `chalk db upgrade` moves it to Postgres 17 with pgvector, every row
#     the same, non-ASCII text included
#   - `chalk db upgrade --cleanup` removes the old container and volume
#
#   scripts/ci-db-upgrade.sh
#
# It works only on containers and volumes of its own, named from
# CHALK_CI_DB_PREFIX (default chalk-ci), refuses the names a real install
# uses, and removes them when it ends (CHALK_CI_DB_KEEP=1 keeps them). Its
# locks, dumps and other state go to a temporary XDG_STATE_HOME.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

prefix="${CHALK_CI_DB_PREFIX:-chalk-ci}"
export CHALK_DB_CONTAINER="$prefix-db" CHALK_DB_OLD_CONTAINER="$prefix-db-16" \
  CHALK_DB_LEGACY_VOLUME="$prefix-db-data" CHALK_DB_VOLUME="$prefix-db-data-17"
legacy_image="postgres:16-alpine" new_image="pgvector/pgvector:pg17"
unset CHALK_DB_IMAGE CHALK_DB_LEGACY_IMAGE CHALK_DB_TIMEOUT
names=("$CHALK_DB_CONTAINER" "$CHALK_DB_OLD_CONTAINER" "$CHALK_DB_LEGACY_VOLUME" "$CHALK_DB_VOLUME")
for name in "${names[@]}"; do
  case "$name" in
    chalk-db|chalk-db-16|chalk-db-data|chalk-db-data-17)
      echo "refusing to touch $name: a real chalk install uses that name; change CHALK_CI_DB_PREFIX" >&2
      exit 2 ;;
  esac
done

XDG_STATE_HOME="$(mktemp -d)"
export XDG_STATE_HOME
out="$XDG_STATE_HOME/out"
mkdir -p "$out"

remove_all() {
  docker rm -f "$CHALK_DB_CONTAINER" "$CHALK_DB_OLD_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$CHALK_DB_LEGACY_VOLUME" "$CHALK_DB_VOLUME" >/dev/null 2>&1 || true
}
finish() {
  local status=$?
  if [[ ${CHALK_CI_DB_KEEP:-} == 1 ]]; then
    echo "kept: ${names[*]}"
  else
    remove_all
  fi
  rm -rf "$XDG_STATE_HOME"
  exit "$status"
}
trap finish EXIT

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; exit 1; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }
# chalk LOG ARGS...: runs this checkout's chalk, its output in $out/LOG.
chalk() { local log="$out/$1"; shift; "$root/bin/chalk" "$@" > "$log" 2>&1; }
show() { sed 's/^/    /' "$out/$1"; }

sql() { docker exec -i "$CHALK_DB_CONTAINER" psql -X -q -A -t -v ON_ERROR_STOP=1 -U chalk -d chalk "$@"; }
field() { docker inspect -f "$2" "$1" 2>/dev/null || true; }
# state: the database container's image, whether it runs, and its volumes.
state() { echo "$(field "$CHALK_DB_CONTAINER" '{{.Config.Image}}') $(field "$CHALK_DB_CONTAINER" '{{.State.Running}}') $(field "$CHALK_DB_CONTAINER" '{{range .Mounts}}{{.Name}}{{end}}')"; }
gone() { ! docker inspect "$1" >/dev/null 2>&1; }
volume_gone() { ! docker volume inspect "$1" >/dev/null 2>&1; }
same() { [[ $1 == "$2" ]]; }

# The columns runs, events and lessons have before the upgrade. The digests
# cover only these, so a column the schema adds on Postgres 17 (such as
# lessons.embedding, which needs pgvector) is not mistaken for changed data.
declare -A columns=()
columns_now() {
  local table
  for table in runs events lessons; do
    columns[$table]="$(sql -v table="$table" <<'SQL'
SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
  FROM information_schema.columns WHERE table_schema = 'public' AND table_name = :'table';
SQL
)"
  done
}

# snapshot: row counts and a digest of every row of runs, events and lessons,
# over the columns they had before the upgrade.
snapshot() {
  sql -v runs="${columns[runs]}" -v events="${columns[events]}" -v lessons="${columns[lessons]}" <<'SQL'
SELECT concat_ws(' ',
  (SELECT count(*) FROM runs), (SELECT count(*) FROM events), (SELECT count(*) FROM lessons),
  (SELECT md5(string_agg((SELECT jsonb_object_agg(k, v) FROM jsonb_each(to_jsonb(t)) e(k, v)
                           WHERE k = ANY (string_to_array(:'runs', ',')))::text, E'\n' ORDER BY id)) FROM runs t),
  (SELECT md5(string_agg((SELECT jsonb_object_agg(k, v) FROM jsonb_each(to_jsonb(t)) e(k, v)
                           WHERE k = ANY (string_to_array(:'events', ',')))::text, E'\n' ORDER BY id)) FROM events t),
  (SELECT md5(string_agg((SELECT jsonb_object_agg(k, v) FROM jsonb_each(to_jsonb(t)) e(k, v)
                           WHERE k = ANY (string_to_array(:'lessons', ',')))::text, E'\n' ORDER BY id)) FROM lessons t));
SQL
}

# counts SNAPSHOT -> REPLY: its row counts, the first three fields.
counts() { local -a f; read -r -a f <<<"$1"; REPLY="${f[*]:0:3}"; }

unicode='Größe überschritten: ファイルが見つかりません — ✓ 🚀 «quoted» '"'"'single'"'"
lesson_text() { sql -c "SELECT signature || '|' || lesson FROM lessons WHERE ticket = 'UNI-1'"; }

remove_all

# 1. An install from before Postgres 17: only the legacy volume exists, so
# `chalk db up` creates the container on Postgres 16.
docker volume create "$CHALK_DB_LEGACY_VOLUME" >/dev/null
chalk up16.log db up || { show up16.log; fail "chalk db up on the legacy volume"; }
check "db up on the legacy volume starts Postgres 16 on it" \
  same "$(state)" "$legacy_image true $CHALK_DB_LEGACY_VOLUME"
check "the server is Postgres 16" same "$(sql -c 'SHOW server_version_num' | cut -c1-2)" 16
check "Postgres 16 warns to upgrade" grep -q 'run `chalk db upgrade`' "$out/up16.log"
check "Postgres 16 has no vector extension" \
  same "$(sql -c "SELECT count(*) FROM pg_extension WHERE extname = 'vector'")" 0

# Representative rows: every kind of run, verdicts and fingerprints, NULLs,
# events, open and resolved lessons, multi-line and non-ASCII text, and a
# few thousand rows so the dump is more than a page.
sql -v unicode="$unicode" <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons,
                  run_id, tests_hash, failing, first_error, tree_id, verdict, fp_rules)
VALUES ('demo', 'PROJ-1', 'chalk/PROJ-1', 1, 'continue', 'ok', 0, true, 'claude-sonnet', 'abc123',
        0.4123, 1, 61, 12000, 3400, 50000, 2000, 14, 0, 0, 'PROJ-1-1700000000', NULL, NULL, NULL,
        'd4e5f6', NULL, 'shadow'),
       ('demo', 'PROJ-2', 'chalk/PROJ-2', 2, 'retry', 'ok', 1, false, 'claude-sonnet', 'abc123',
        0.2, 1, 30, 9000, 1200, 0, 0, 9, 2, 3, 'PROJ-2-1700000100', repeat('ab', 32), 2,
        :'unicode', 'a1b2c3', 'repeat', 'on'),
       ('démo', 'ПРОЕКТ-3', 'chalk/ПРОЕКТ-3', 0, 'spec-check', 'pass', 0, false, 'haiku', 'abc123',
        0.001, 1, 3, 100, 10, 0, 0, 1, 0, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed, model,
                  prompts, cost_usd, budget_usd, duration_s, input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, turns, denials, lessons, run_id, verdict)
SELECT 'bulk', 'BULK-' || (n % 50), 'chalk/BULK-' || (n % 50), n % 7, 'continue', 'ok', n % 2,
       n % 2 = 0, 'm', 'p', n / 1000.0, 1, n % 90, n, n, n, n, n % 20, 0, 0,
       'BULK-' || (n % 50) || '-1', CASE WHEN n % 3 = 0 THEN 'no_change' END
  FROM generate_series(1, 3000) n;
INSERT INTO events (repo, ticket, kind)
VALUES ('demo', 'PROJ-1', 'submitted'), ('demo', 'PROJ-2', 'detention'), ('démo', 'ПРОЕКТ-3', 'spec_blocked');
INSERT INTO lessons (repo, ticket, signature, resolution, lesson, resolved_by, resolved_at,
                     run_id, fingerprint, first_error)
VALUES ('demo', 'PROJ-2', E'rubric failed (exit 1)\nAssertionError: BROKEN exists', 'removed BROKEN',
        'Never commit marker files.', 'engineer', now(), 'PROJ-2-1700000100', repeat('cd', 32),
        'AssertionError: BROKEN exists'),
       ('demo', 'UNI-1', :'unicode', 'note', :'unicode', 'エンジニア', now(), NULL, NULL, NULL),
       ('demo', 'OPEN-1', 'rubric failed (exit 2)', NULL, NULL, NULL, NULL, NULL, NULL, NULL);
SQL
columns_now
before="$(snapshot)"
check "the rows are written" same "${before%% *}" 3003
check "non-ASCII text reads back as written" same "$(lesson_text)" "$unicode|$unicode"

# assert_rolled_back LOG: the Postgres 16 container is back as it was.
assert_rolled_back() {
  check "$1: the upgrade says it rolled back" grep -q 'rolled back' "$out/$1"
  check "$1: the database is Postgres 16 again, running, on the legacy volume" \
    same "$(state)" "$legacy_image true $CHALK_DB_LEGACY_VOLUME"
  check "$1: no old container or new volume is left" gone "$CHALK_DB_OLD_CONTAINER"
  check "$1: ... nor the new volume" volume_gone "$CHALK_DB_VOLUME"
  check "$1: every row is unchanged" same "$(snapshot)" "$before"
}

# 2. Failures roll back. The Postgres 17 container cannot be created:
if CHALK_DB_IMAGE="$prefix-no-such-image:pg17" chalk fail-create.log db upgrade; then
  show fail-create.log; fail "an upgrade whose image cannot be pulled must fail"
fi
check "fail-create.log: the failure is named" grep -q 'upgrade failed: could not create the Postgres 17 container' "$out/fail-create.log"
assert_rolled_back fail-create.log

# The new container does not come up in time: chalk dies, and the EXIT trap
# rolls back.
if CHALK_DB_TIMEOUT=1 chalk fail-timeout.log db upgrade; then
  show fail-timeout.log; fail "an upgrade whose database is not ready in time must fail"
fi
check "fail-timeout.log: the failure is named" grep -q 'did not become ready in 1s' "$out/fail-timeout.log"
assert_rolled_back fail-timeout.log

# 3. The upgrade.
chalk upgrade.log db upgrade || { show upgrade.log; fail "chalk db upgrade"; }
show upgrade.log
check "the database is Postgres 17 with pgvector, running, on the new volume" \
  same "$(state)" "$new_image true $CHALK_DB_VOLUME"
check "the server is Postgres 17" same "$(sql -c 'SHOW server_version_num' | cut -c1-2)" 17
check "the vector extension is installed" \
  same "$(sql -c "SELECT count(*) FROM pg_extension WHERE extname = 'vector'")" 1
check "pg_trgm came across" same "$(sql -c "SELECT count(*) FROM pg_extension WHERE extname = 'pg_trgm'")" 1
after="$(snapshot)"
check "row counts are identical (runs events lessons: ${| counts "$after"; })" \
  same "${| counts "$after"; }" "${| counts "$before"; }"
check "every row is identical" same "$after" "$before"
check "non-ASCII text is identical" same "$(lesson_text)" "$unicode|$unicode"
check "the old container is kept, stopped, as $CHALK_DB_OLD_CONTAINER" \
  same "$(field "$CHALK_DB_OLD_CONTAINER" '{{.Config.Image}} {{.State.Running}}')" "$legacy_image false"
check "the legacy volume is kept" docker volume inspect "$CHALK_DB_LEGACY_VOLUME"
chalk up17.log db up || { show up17.log; fail "chalk db up on Postgres 17"; }
check "Postgres 17 does not warn" sh -c "! grep -q 'chalk db upgrade' '$out/up17.log'"
check "a second upgrade has nothing to do" chalk again.log db upgrade
check "... and says so" grep -q 'already runs Postgres 17' "$out/again.log"

# 4. Cleanup.
chalk cleanup.log db upgrade --cleanup || { show cleanup.log; fail "chalk db upgrade --cleanup"; }
check "cleanup removes the old container" gone "$CHALK_DB_OLD_CONTAINER"
check "cleanup removes the legacy volume" volume_gone "$CHALK_DB_LEGACY_VOLUME"
check "cleanup removes the dump" test ! -e "$XDG_STATE_HOME/chalk/db-upgrade"
check "cleanup keeps the upgraded database and its rows" \
  same "$(state) $(snapshot)" "$new_image true $CHALK_DB_VOLUME $before"

echo "database upgrade passed"
