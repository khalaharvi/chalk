# Local telemetry and lessons database. One Postgres container per machine,
# reached only through `docker exec`, so no port is published and no
# password ever leaves the container.

CHALK_DB_CONTAINER="chalk-db"
CHALK_DB_VOLUME="chalk-db-data"

db_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$CHALK_DB_CONTAINER" 2>/dev/null)" = "true" ]
}

db_up() {
  if ! db_running; then
    if docker inspect "$CHALK_DB_CONTAINER" >/dev/null 2>&1; then
      docker start "$CHALK_DB_CONTAINER" >/dev/null
    else
      docker run -d --name "$CHALK_DB_CONTAINER" --restart unless-stopped \
        -e POSTGRES_USER=chalk -e POSTGRES_DB=chalk \
        -e POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
        -v "$CHALK_DB_VOLUME:/var/lib/postgresql/data" \
        postgres:16-alpine >/dev/null
    fi
  fi

  # Probe over TCP: the image's first-boot init server listens on the socket only.
  local attempt=0
  until docker exec "$CHALK_DB_CONTAINER" pg_isready -q -h 127.0.0.1 -U chalk -d chalk; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || die "telemetry database did not become ready"
    sleep 1
  done

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
# does not set is stored as NULL.
db_record_call() {
  local kind="$1" status="$2" rubric_exit="$3" progressed="$4" model="$5"
  local seconds="$6" lessons="$7" result="$8" ran
  local -A usage __no_fp=()
  local -n __fp="${9:-__no_fp}"
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
    -v failing="${__fp[failing]-}" -v first_error="${__fp[first_error]-}" \
    -v tree_id="${__fp[tree_id]-}" -v verdict="${__fp[verdict]-}" <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed,
                  model, prompts, cost_usd, budget_usd, duration_s, input_tokens,
                  output_tokens, cache_read_tokens, cache_write_tokens, turns, denials, lessons,
                  run_id, tests_hash, failing, first_error, tree_id, verdict)
VALUES (:'repo', :'ticket', :'branch', :'loop', :'kind', :'status', :'rubric_exit', :'progressed',
        :'model', :'prompts', :'cost', :'budget', :'seconds', :'input',
        :'output', :'cache_read', :'cache_write', :'turns', :'denials', :'lessons',
        nullif(:'run_id', ''), nullif(:'tests_hash', ''), nullif(:'failing', '')::int,
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

# db_open_match TICKET FINGERPRINT -> REPLY: 1 when an open lesson for
# another ticket in this repository, from the last 30 days, has the same
# fingerprint; empty otherwise, and when the database cannot be read.
db_open_match() {
  REPLY=""
  [[ -n $2 ]] || return 0
  REPLY="$(db_sql -v repo="${| repo_name; }" -v ticket="$1" -v fingerprint="$2" 2>/dev/null <<'SQL' || true
SELECT 1 FROM lessons
 WHERE repo = :'repo' AND ticket <> :'ticket' AND resolution IS NULL
   AND fingerprint = :'fingerprint' AND created_at >= now() - interval '30 days'
 LIMIT 1;
SQL
)"
  [[ $REPLY == 1 ]] || REPLY=""
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

# Prints resolved lessons whose failure text resembles the query, best first.
db_similar_lessons() {
  db_sql -v query="$1" <<'SQL'
SELECT '- Seen before: ' || left(regexp_replace(signature, '\s+', ' ', 'g'), 240)
       || E'\n  Fix: ' || coalesce(lesson, resolution)
  FROM lessons
 WHERE resolution IS NOT NULL AND similarity(signature, :'query') > 0.1
 ORDER BY similarity(signature, :'query') DESC
 LIMIT 3;
SQL
}

# One JSON object per line for each resolved lesson not yet sent to memory.
db_unsynced_lessons() {
  db_sql <<'SQL'
SELECT json_build_object('id', id, 'repo', repo, 'ticket', ticket,
                         'signature', signature, 'resolution', resolution,
                         'lesson', lesson)
  FROM lessons
 WHERE resolution IS NOT NULL AND memory_synced_at IS NULL
 ORDER BY id;
SQL
}

db_mark_lesson_synced() {
  db_sql -v id="$1" <<'SQL'
UPDATE lessons SET memory_synced_at = now() WHERE id = :'id';
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

cmd_db() {
  need docker
  case "${1:-}" in
    up)   db_up; info "telemetry database is up ($CHALK_DB_CONTAINER)" ;;
    down) docker stop "$CHALK_DB_CONTAINER" >/dev/null
          info "telemetry database stopped (data kept in volume $CHALK_DB_VOLUME)" ;;
    psql) exec docker exec -it "$CHALK_DB_CONTAINER" psql -U chalk -d chalk ;;
    *)    die "usage: chalk db up|down|psql" ;;
  esac
}
