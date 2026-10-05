# Local telemetry and lessons database. One Postgres container per machine,
# reached only through `docker exec`, so no port is published and no
# password ever leaves the container.

CHALK_DB_CONTAINER="chalk-db"
CHALK_DB_IMAGE="pgvector/pgvector:pg17"
CHALK_DB_VOLUME="chalk-db-data-17"
# Installs from before Postgres 17 keep these until `chalk db upgrade`,
# which parks the old container as CHALK_DB_OLD_CONTAINER until --cleanup.
CHALK_DB_LEGACY_IMAGE="postgres:16-alpine"
CHALK_DB_LEGACY_VOLUME="chalk-db-data"
CHALK_DB_OLD_CONTAINER="chalk-db-16"

db_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$CHALK_DB_CONTAINER" 2>/dev/null)" = "true" ]
}

# db_exists [CONTAINER]: true when the container exists, running or not.
db_exists() {
  docker inspect "${1:-$CHALK_DB_CONTAINER}" >/dev/null 2>&1
}

db_volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

# db_major [CONTAINER] -> REPLY: the Postgres major version a container
# runs, read from its image; empty when unknown or missing.
db_major() {
  local image
  image="$(docker inspect -f '{{.Config.Image}}' "${1:-$CHALK_DB_CONTAINER}" 2>/dev/null || true)"
  REPLY=""
  if [[ $image =~ (postgres:|pg)([0-9]+) ]]; then REPLY="${BASH_REMATCH[2]}"; fi
}

# db_volumes [CONTAINER] -> REPLY: the named volumes a container mounts.
db_volumes() {
  REPLY="$(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "${1:-$CHALK_DB_CONTAINER}" 2>/dev/null || true)"
  REPLY="${REPLY% }"
}

# db_run NAME VOLUME IMAGE: creates and starts a database container.
db_run() {
  docker run -d --name "$1" --restart unless-stopped \
    -e POSTGRES_USER=chalk -e POSTGRES_DB=chalk \
    -e POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
    -v "$2:/var/lib/postgresql/data" "$3"
}

# db_create -> REPLY: creates chalk-db on the image that matches the data
# on this machine; REPLY is 1 when the container was created here, empty
# when another chalk created it first. Postgres 17 never opens Postgres 16
# data: while only the legacy volume exists, the container comes back on 16.
db_create() {
  local image="$CHALK_DB_IMAGE" volume="$CHALK_DB_VOLUME" out
  if db_volume_exists "$CHALK_DB_LEGACY_VOLUME" && ! db_volume_exists "$CHALK_DB_VOLUME"; then
    image="$CHALK_DB_LEGACY_IMAGE" volume="$CHALK_DB_LEGACY_VOLUME"
  fi
  REPLY=1
  if ! out="$(db_run "$CHALK_DB_CONTAINER" "$volume" "$image" 2>&1)"; then
    # Created elsewhere, e.g. by a chalk from before the lock existed.
    [[ $out == *"already in use"* ]] || die "could not create $CHALK_DB_CONTAINER: $out"
    REPLY=""
  fi
}

# db_wait_ready [FRESH]: waits until the database accepts connections.
# FRESH is 1 when the container is initialising its data for the first time.
db_wait_ready() {
  local limit attempt=0
  limit="${| system_timeout 30 "${CHALK_DB_TIMEOUT:-auto}" "${1:-0}"; }"
  # Probe over TCP: the image's first-boot init server listens on the socket only.
  until docker exec "$CHALK_DB_CONTAINER" pg_isready -q -h 127.0.0.1 -U chalk -d chalk; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$limit" ] ||
      die "telemetry database did not become ready in ${limit}s (CHALK_DB_TIMEOUT sets the wait)"
    sleep 1
  done
}

db_up() {
  local fresh=""
  if ! db_running; then
    # One chalk at a time starts or creates the container. The others wait,
    # then find it there. `chalk db upgrade` holds the same lock.
    chalk_lock db 300 || die "timed out waiting for another chalk to set up $CHALK_DB_CONTAINER"
    if db_exists; then
      docker start "$CHALK_DB_CONTAINER" >/dev/null
    else
      fresh="${| db_create; }"
    fi
    chalk_unlock db
  fi
  db_wait_ready "${fresh:-0}"
  if [[ ${| db_major; } == 16 ]]; then
    warn "$CHALK_DB_CONTAINER runs Postgres 16: run \`chalk db upgrade\`; semantic recall is off until then"
  fi

  db_sql < "$CHALK_HOME/share/schema.sql" >/dev/null
}

# Runs SQL from stdin. Pass values as `-v name=value` and reference them
# as :'name' so psql does the quoting.
db_sql() {
  docker exec -i "$CHALK_DB_CONTAINER" \
    psql -X -q -A -t -v ON_ERROR_STOP=1 -U chalk -d chalk "$@"
}

# db_record_call KIND STATUS RUBRIC_EXIT PROGRESSED MODEL SECONDS LESSONS RESULT_FILE [FP]
# Records one agent call for the current run (RUN_* globals). The model is the
# one the result reports; MODEL, the one requested, is the fallback. FP names
# an associative array filled like fp_compute's, plus its verdict; a key it
# does not set is stored as NULL. Of its failing tests, the first 100 are
# stored, which also keeps them well inside one command-line argument.
db_record_call() {
  local kind="$1" status="$2" rubric_exit="$3" progressed="$4" model="$5"
  local seconds="$6" lessons="$7" result="$8" ran tests=""
  local -A usage __no_fp=()
  local -n __fp="${9:-__no_fp}"
  if [[ ${__fp[tests]:-UNKNOWN} != UNKNOWN ]]; then tests="$(head -n 100 <<<"${__fp[tests]}")"; fi
  agent_usage "$result" usage
  ran="$(agent_model "$result")"
  model="${ran:-$model}"
  db_sql -v repo="${| repo_name; }" -v ticket="$RUN_TICKET" -v branch="$RUN_BRANCH" \
    -v loop="$RUN_LOOP" -v kind="$kind" -v status="$status" -v rubric_exit="$rubric_exit" \
    -v progressed="$progressed" -v model="${model:-default}" -v prompts="$RUN_PROMPTS" \
    -v cost="$(agent_cost "$result")" -v budget="$CHALK_BUDGET_USD" -v seconds="$seconds" \
    -v input="${usage[input]}" -v output="${usage[output]}" -v cache_read="${usage[cache_read]}" \
    -v cache_write="${usage[cache_write]}" -v turns="${usage[turns]}" -v denials="${usage[denials]}" \
    -v lessons="$lessons" -v run_id="${RUN_ID:-}" -v tests_hash="${__fp[tests_hash]-}" \
    -v failing_tests="$tests" -v failing="${__fp[failing]-}" -v first_error="${__fp[first_error]-}" \
    -v tree_id="${__fp[tree_id]-}" -v verdict="${__fp[verdict]-}" <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed,
                  model, prompts, cost_usd, budget_usd, duration_s, input_tokens,
                  output_tokens, cache_read_tokens, cache_write_tokens, turns, denials, lessons,
                  run_id, tests_hash, failing_tests, failing, first_error, tree_id, verdict)
VALUES (:'repo', :'ticket', :'branch', :'loop', :'kind', :'status', :'rubric_exit', :'progressed',
        :'model', :'prompts', :'cost', :'budget', :'seconds', :'input',
        :'output', :'cache_read', :'cache_write', :'turns', :'denials', :'lessons',
        nullif(:'run_id', ''), nullif(:'tests_hash', ''), nullif(:'failing_tests', ''),
        nullif(:'failing', '')::int,
        nullif(:'first_error', ''), nullif(:'tree_id', ''), nullif(:'verdict', ''));
SQL
}

# db_event TICKET KIND: records a ticket milestone.
db_event() {
  db_sql -v repo="${| repo_name; }" -v ticket="$1" -v kind="$2" <<'SQL'
INSERT INTO events (repo, ticket, kind) VALUES (:'repo', :'ticket', :'kind');
SQL
}

# Prints the dashboard's data for the last DAYS days as one JSON document.
db_dashboard() {
  db_sql -v days="$1" < "$CHALK_HOME/share/dashboard.sql"
}

# db_open_lesson REPO TICKET SIGNATURE RUN_ID [FINGERPRINT] [FIRST_ERROR]
# Records a detention as an open lesson. FINGERPRINT and FIRST_ERROR come
# from the loop that detained the run, and only when its rubric failed.
db_open_lesson() {
  db_sql -v repo="$1" -v ticket="$2" -v signature="$3" -v run_id="$4" \
    -v fingerprint="${5:-}" -v first_error="${6:-}" <<'SQL'
INSERT INTO lessons (repo, ticket, signature, run_id, fingerprint, first_error)
VALUES (:'repo', :'ticket', :'signature', nullif(:'run_id', ''),
        nullif(:'fingerprint', ''), nullif(:'first_error', ''));
SQL
}

# db_open_match TICKET FINGERPRINT -> REPLY: the ticket of the newest open
# lesson for another ticket in this repository, from the last 30 days, with
# the same fingerprint; empty when there is none, and when the database
# cannot be read.
db_open_match() {
  REPLY=""
  [[ -n $2 ]] || return 0
  REPLY="$(db_sql -v repo="${| repo_name; }" -v ticket="$1" -v fingerprint="$2" 2>/dev/null <<'SQL' || true
SELECT ticket FROM lessons
 WHERE repo = :'repo' AND ticket <> :'ticket' AND resolution IS NULL
   AND fingerprint = :'fingerprint' AND created_at >= now() - interval '30 days'
 ORDER BY id DESC LIMIT 1;
SQL
)"
  is_ticket "$REPLY" || REPLY=""
}

# Attaches the engineer's fix to the newest unresolved lesson for a ticket.
# LESSON is the generalised rule distilled from the note; it may be empty.
db_resolve_lesson() {
  local ticket="$1" resolution="$2" who="$3" lesson="${4:-}"
  db_sql -v repo="${| repo_name; }" -v ticket="$ticket" -v resolution="$resolution" \
    -v who="$who" -v lesson="$lesson" <<'SQL'
UPDATE lessons
   SET resolution = :'resolution', lesson = nullif(:'lesson', ''),
       resolved_by = :'who', resolved_at = now()
 WHERE id = (SELECT id FROM lessons
              WHERE repo = :'repo' AND ticket = :'ticket' AND resolution IS NULL
              ORDER BY id DESC LIMIT 1);
SQL
}

# The failure text of the newest unresolved lesson for a ticket.
db_pending_signature() {
  db_sql -v repo="${| repo_name; }" -v ticket="$1" <<'SQL'
SELECT signature FROM lessons
 WHERE repo = :'repo' AND ticket = :'ticket' AND resolution IS NULL
 ORDER BY id DESC LIMIT 1;
SQL
}

# db_recall_lessons REPO MODE QUERY [FINGERPRINT] [FIRST_ERROR]: prints up
# to three resolved lessons as a markdown list (MODE and QUERY as for
# memory_recall). The recall ladder:
#   1 exact    same repository, same non-NULL fingerprint. Listed first, and
#              never pushed out by a lexical match.
#   2 lexical  any repository, by pg_trgm score, best first, above:
#     failure  0.5 for similarity(first_error, FIRST_ERROR). The same failure
#              scores about 0.8 or more; two different errors of one type
#              ("AssertionError: ...") still score about 0.4. A lesson from
#              before fingerprints has no first_error, and falls back to
#              similarity(signature, QUERY) above 0.1, recall's old threshold.
#     spec     0.6 (pg_trgm's default) for word_similarity(coalesce(first_error,
#              signature), QUERY): the lesson's error appears in the spec. Plain
#              similarity of one error line to a whole spec stays near zero.
#     text     0.1 for similarity(signature, QUERY), as recall always did.
db_recall_lessons() {
  db_sql -v repo="$1" -v mode="$2" -v query="$3" -v fingerprint="${4:-}" -v first_error="${5:-}" <<'SQL'
WITH candidates AS (
  SELECT id, signature, coalesce(lesson, resolution) AS fix,
         coalesce(repo = :'repo' AND fingerprint = nullif(:'fingerprint', ''), false) AS exact,
         CASE WHEN :'mode' = 'spec'
                THEN word_similarity(coalesce(nullif(first_error, ''), signature), :'query')
              WHEN :'mode' = 'failure' AND nullif(first_error, '') IS NOT NULL
                THEN similarity(first_error, nullif(:'first_error', ''))
              ELSE similarity(signature, :'query')
         END AS score,
         CASE WHEN :'mode' = 'spec' THEN 0.6
              WHEN :'mode' = 'failure' AND nullif(first_error, '') IS NOT NULL THEN 0.5
              ELSE 0.1
         END AS threshold
    FROM lessons
   WHERE resolution IS NOT NULL
)
SELECT '- Seen before: ' || left(regexp_replace(signature, '\s+', ' ', 'g'), 240)
       || E'\n  Fix: ' || fix
  FROM candidates
 WHERE exact OR score > threshold
 ORDER BY exact DESC, score DESC NULLS LAST, id DESC
 LIMIT 3;
SQL
}

# db_ticket_summary TICKET VAR [FALLBACK]: fills the associative array VAR
# with the ticket's loops, total cost and human interventions (fixes). Each
# is FALLBACK, by default "?", when the database cannot be read.
db_ticket_summary() {
  local -n __summary=$2
  local loops="${3:-?}" cost="${3:-?}" fixes="${3:-?}" row
  if row="$(db_sql -F ' ' -v repo="${| repo_name; }" -v ticket="$1" 2>/dev/null <<'SQL'
SELECT count(*) FILTER (WHERE kind IN ('continue', 'retry', 'fix-review')), coalesce(sum(cost_usd), 0),
       (SELECT count(*) FROM lessons
         WHERE repo = :'repo' AND ticket = :'ticket' AND resolution IS NOT NULL)
  FROM runs WHERE repo = :'repo' AND ticket = :'ticket';
SQL
)" && [[ -n $row ]]; then
    read -r loops cost fixes <<<"$row"
  fi
  __summary=(["loops"]="$loops" ["cost"]="$cost" ["fixes"]="$fixes")
}

# How far `chalk db upgrade` has got, for db_upgrade_rollback:
#   stopping  the Postgres 16 container may be stopped
#   renamed   it is CHALK_DB_OLD_CONTAINER, and a new chalk-db may exist
DB_UPGRADE_STEP=""

# db_upgrade_dir -> REPLY: where the upgrade keeps its dump and restore log.
db_upgrade_dir() {
  REPLY="${XDG_STATE_HOME:-$HOME/.local/state}/chalk/db-upgrade"
}

# Prints the row counts of runs, events and lessons on one line.
db_counts() {
  db_sql -F ' ' <<'SQL'
-- chalk db upgrade: row counts
SELECT (SELECT count(*) FROM runs), (SELECT count(*) FROM events), (SELECT count(*) FROM lessons);
SQL
}

# Puts the Postgres 16 container back as it was before the upgrade touched
# it: the new container and its volume go, the old one gets its name back
# and is started. Returns non-zero when that could not be done.
db_upgrade_rollback() {
  local step="$DB_UPGRADE_STEP"
  DB_UPGRADE_STEP=""
  trap - EXIT
  [[ -n $step ]] || return 0
  warn "rolling back to the Postgres 16 container"
  if [[ $step == renamed ]]; then
    docker rm -f "$CHALK_DB_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$CHALK_DB_VOLUME" >/dev/null 2>&1 || true
    if ! docker rename "$CHALK_DB_OLD_CONTAINER" "$CHALK_DB_CONTAINER"; then
      warn "could not rename it back; run: docker rename $CHALK_DB_OLD_CONTAINER $CHALK_DB_CONTAINER"
      return 1
    fi
  fi
  if ! docker start "$CHALK_DB_CONTAINER" >/dev/null; then
    warn "could not start it; run: docker start $CHALK_DB_CONTAINER"
    return 1
  fi
  warn "rolled back: $CHALK_DB_CONTAINER is on Postgres 16 again, with its data unchanged"
}

# db_upgrade_fail MESSAGE: rolls back, then ends Chalk with MESSAGE.
db_upgrade_fail() {
  db_upgrade_rollback || true
  die "upgrade failed: $1"
}

# chalk db upgrade: moves chalk-db from Postgres 16 to 17 by dump and
# restore into a new container on a new volume. The old container and
# volume are kept, so any failure puts them back as they were.
db_upgrade() {
  local major active dir dump before after
  db_exists || die "there is no $CHALK_DB_CONTAINER container; 'chalk db up' creates one on Postgres 17"
  major="${| db_major; }"
  if [[ $major == 17 ]]; then
    info "$CHALK_DB_CONTAINER already runs Postgres 17"
    return 0
  fi
  [[ $major == 16 ]] || die "$CHALK_DB_CONTAINER runs an image chalk does not recognise; upgrade it by hand"
  ! db_exists "$CHALK_DB_OLD_CONTAINER" ||
    die "$CHALK_DB_OLD_CONTAINER is left from an earlier upgrade; remove it first (docker rm $CHALK_DB_OLD_CONTAINER)"
  ! db_volume_exists "$CHALK_DB_VOLUME" ||
    die "volume $CHALK_DB_VOLUME is left from an earlier upgrade; remove it first (docker volume rm $CHALK_DB_VOLUME)"
  active="${| state_live_runs; }"
  (( active == 0 )) || die "$active chalk run(s) still active; upgrade once they have finished"
  # Holding the database lock keeps db_up from starting or recreating
  # chalk-db while it is stopped or renamed.
  chalk_lock db 0 || die "another chalk is starting the database; try again in a moment"

  if ! db_running; then docker start "$CHALK_DB_CONTAINER" >/dev/null; fi
  db_wait_ready
  dir="${| db_upgrade_dir; }"
  dump="$dir/postgres-16.sql"
  mkdir -p "$dir"
  before="$(db_counts)"
  info "dumping $CHALK_DB_CONTAINER (Postgres 16) to $dump"
  (umask 077; docker exec "$CHALK_DB_CONTAINER" pg_dumpall -U chalk > "$dump") ||
    die "could not dump the database; nothing was changed"
  [[ -s $dump ]] || die "the dump is empty; nothing was changed"

  # From here on, any failure or interruption rolls back.
  trap 'db_upgrade_rollback || true' EXIT
  DB_UPGRADE_STEP=stopping
  docker stop "$CHALK_DB_CONTAINER" >/dev/null || db_upgrade_fail "could not stop $CHALK_DB_CONTAINER"
  docker rename "$CHALK_DB_CONTAINER" "$CHALK_DB_OLD_CONTAINER" ||
    db_upgrade_fail "could not rename $CHALK_DB_CONTAINER to $CHALK_DB_OLD_CONTAINER"
  DB_UPGRADE_STEP=renamed
  info "creating $CHALK_DB_CONTAINER on $CHALK_DB_IMAGE with volume $CHALK_DB_VOLUME"
  db_run "$CHALK_DB_CONTAINER" "$CHALK_DB_VOLUME" "$CHALK_DB_IMAGE" >/dev/null ||
    db_upgrade_fail "could not create the Postgres 17 container"
  db_wait_ready 1
  info "restoring the dump"
  docker exec -i "$CHALK_DB_CONTAINER" psql -X -q -U chalk -d postgres < "$dump" > "$dir/restore.log" 2>&1 ||
    db_upgrade_fail "the restore failed (see $dir/restore.log)"
  # The new server already has the chalk role and database, so recreating
  # them fails harmlessly. Any other error is a real failure.
  if awk '/ERROR:/ && !/(role|database) "chalk" already exists/ { bad = 1 } END { exit !bad }' "$dir/restore.log"; then
    db_upgrade_fail "the restore reported errors (see $dir/restore.log)"
  fi
  after="$(db_counts)" || db_upgrade_fail "could not count rows after the restore"
  [[ $after == "$before" ]] ||
    db_upgrade_fail "row counts differ (runs events lessons: $before before, $after after)"
  db_sql < "$CHALK_HOME/share/schema.sql" >/dev/null || db_upgrade_fail "could not apply the schema"
  DB_UPGRADE_STEP=""
  trap - EXIT
  chalk_unlock db

  info "upgraded $CHALK_DB_CONTAINER to Postgres 17 (runs events lessons: $after rows)"
  info "kept $CHALK_DB_OLD_CONTAINER and volume $CHALK_DB_LEGACY_VOLUME; remove them with: chalk db upgrade --cleanup"
}

# chalk db upgrade --cleanup: removes what a successful upgrade kept.
db_upgrade_cleanup() {
  [[ ${| db_major; } == 17 ]] ||
    die "$CHALK_DB_CONTAINER is not on Postgres 17 yet; run 'chalk db upgrade' first"
  [[ " ${| db_volumes; } " != *" $CHALK_DB_LEGACY_VOLUME "* ]] ||
    die "$CHALK_DB_CONTAINER still uses volume $CHALK_DB_LEGACY_VOLUME; nothing removed"
  if db_exists "$CHALK_DB_OLD_CONTAINER"; then
    docker rm -f "$CHALK_DB_OLD_CONTAINER" >/dev/null
    info "removed container $CHALK_DB_OLD_CONTAINER"
  fi
  if db_volume_exists "$CHALK_DB_LEGACY_VOLUME"; then
    docker volume rm "$CHALK_DB_LEGACY_VOLUME" >/dev/null
    info "removed volume $CHALK_DB_LEGACY_VOLUME"
  fi
  rm -rf "${| db_upgrade_dir; }"
}

cmd_db() {
  need docker
  case "${1:-}:${2:-}" in
    up:)   db_up; info "telemetry database is up ($CHALK_DB_CONTAINER)" ;;
    down:) docker stop "$CHALK_DB_CONTAINER" >/dev/null
           info "telemetry database stopped (data kept in volume ${| db_volumes; })" ;;
    psql:) exec docker exec -it "$CHALK_DB_CONTAINER" psql -U chalk -d chalk ;;
    upgrade:) db_upgrade ;;
    upgrade:--cleanup) db_upgrade_cleanup ;;
    *)     die "usage: chalk db up|down|psql|upgrade [--cleanup]" ;;
  esac
}
