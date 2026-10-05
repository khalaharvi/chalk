# Local telemetry and lessons database. One Postgres container per machine,
# reached only through `docker exec`, so no port is published and no
# password ever leaves the container.
#
# The names and images can be set from the environment, only so that a test
# (scripts/ci-db-upgrade.sh) can run a real upgrade on containers and
# volumes of its own. Nothing else sets them.
CHALK_DB_CONTAINER="${CHALK_DB_CONTAINER:-chalk-db}"
CHALK_DB_IMAGE="${CHALK_DB_IMAGE:-pgvector/pgvector:pg17}"
CHALK_DB_VOLUME="${CHALK_DB_VOLUME:-chalk-db-data-17}"
# Installs from before Postgres 17 keep these until `chalk db upgrade`,
# which parks the old container as CHALK_DB_OLD_CONTAINER until --cleanup.
CHALK_DB_LEGACY_IMAGE="${CHALK_DB_LEGACY_IMAGE:-postgres:16-alpine}"
CHALK_DB_LEGACY_VOLUME="${CHALK_DB_LEGACY_VOLUME:-chalk-db-data}"
CHALK_DB_OLD_CONTAINER="${CHALK_DB_OLD_CONTAINER:-chalk-db-16}"

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

# True when the Postgres 16 warning has not been given today on this
# machine, and records that it now has. Every run starts the database, so
# without this a fleet would print it on every run. `chalk doctor` still
# reports it every time.
db_upgrade_nag_due() {
  local stamp today last=""
  stamp="${XDG_STATE_HOME:-$HOME/.local/state}/chalk/db-upgrade-warned"
  printf -v today '%(%F)T' -1
  { read -r last < "$stamp"; } 2>/dev/null || true
  [[ $last != "$today" ]] || return 1
  # A stamp that cannot be written only means the warning comes again.
  { mkdir -p "${stamp%/*}" && printf '%s\n' "$today" > "$stamp"; } 2>/dev/null || true
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
  if [[ ${| db_major; } == 16 ]] && db_upgrade_nag_due; then
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
# CHALK_FP_RULES is stored with every call, so the dashboard can tell what
# a verdict did (on) from what it would have done (shadow).
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
    -v lessons="$lessons" -v fp_rules="${CHALK_FP_RULES:-}" -v run_id="${RUN_ID:-}" -v tests_hash="${__fp[tests_hash]-}" \
    -v failing_tests="$tests" -v failing="${__fp[failing]-}" -v first_error="${__fp[first_error]-}" \
    -v tree_id="${__fp[tree_id]-}" -v verdict="${__fp[verdict]-}" <<'SQL'
INSERT INTO runs (repo, ticket, branch, loop, kind, agent_status, rubric_exit, progressed,
                  model, prompts, cost_usd, budget_usd, duration_s, input_tokens,
                  output_tokens, cache_read_tokens, cache_write_tokens, turns, denials, lessons,
                  fp_rules, run_id, tests_hash, failing_tests, failing, first_error, tree_id, verdict)
VALUES (:'repo', :'ticket', :'branch', :'loop', :'kind', :'status', :'rubric_exit', :'progressed',
        :'model', :'prompts', :'cost', :'budget', :'seconds', :'input',
        :'output', :'cache_read', :'cache_write', :'turns', :'denials', :'lessons',
        nullif(:'fp_rules', ''), nullif(:'run_id', ''), nullif(:'tests_hash', ''), nullif(:'failing_tests', ''),
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
# SCOPE is where it is recalled: repo (this repository only), general, or
# empty for anywhere, as before scopes existed.
db_resolve_lesson() {
  local ticket="$1" resolution="$2" who="$3" lesson="${4:-}" scope="${5:-}"
  db_sql -v repo="${| repo_name; }" -v ticket="$ticket" -v resolution="$resolution" \
    -v who="$who" -v lesson="$lesson" -v scope="$scope" <<'SQL'
UPDATE lessons
   SET resolution = :'resolution', lesson = nullif(:'lesson', ''),
       scope = nullif(:'scope', ''), resolved_by = :'who', resolved_at = now()
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
# A lesson whose scope is repo is recalled only in its own repository.
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
     AND (scope IS DISTINCT FROM 'repo' OR repo = :'repo')
)
SELECT '- Seen before: ' || left(regexp_replace(signature, '\s+', ' ', 'g'), 240)
       || E'\n  Fix: ' || fix
  FROM candidates
 WHERE exact OR score > threshold
 ORDER BY exact DESC, score DESC NULLS LAST, id DESC
 LIMIT 3;
SQL
}

# db_decider_gate: prints how many lessons are resolved, and 1 when the
# lessons table has the embedding column (Postgres 17 with pgvector), else
# 0, on one line. The decider's recall steps wait for enough lessons.
db_decider_gate() {
  db_sql -F ' ' <<'SQL'
SELECT count(*) FILTER (WHERE resolution IS NOT NULL),
       (EXISTS (SELECT 1 FROM pg_attribute
                 WHERE attrelid = 'lessons'::regclass AND attname = 'embedding'
                   AND NOT attisdropped))::int
  FROM lessons;
SQL
}

# db_decider_reach DAYS: prints, as one JSON object, what could have put a
# question to the decider in the last DAYS days, so that an empty record
# can say why (decider_quiet_note): its loops (continue, retry and
# fix-review calls); failed, those whose rubric failed after the agent
# finished; gray, the failed ones the verdicts call spinning or other,
# which get the stuck question; unticked, those whose rubric passed with
# no checkpoint ticked; blocked_runs, the runs whose agent reported a
# blocker; questions, the decider's recorded questions; and lessons, the
# resolved lessons, of every period, that lesson rerank waits for.
db_decider_reach() {
  db_sql -v days="$1" <<'SQL'
WITH l AS (
  SELECT * FROM runs
   WHERE kind IN ('continue', 'retry', 'fix-review')
     AND created_at >= now() - make_interval(days => :'days'::int)
)
SELECT json_build_object(
  'days', :'days'::int,
  'loops', (SELECT count(*) FROM l),
  'failed', (SELECT count(*) FROM l WHERE rubric_exit <> 0 AND agent_status = 'ok'),
  'gray', (SELECT count(*) FROM l
            WHERE rubric_exit <> 0 AND agent_status = 'ok' AND verdict IN ('spinning', 'other')),
  'unticked', (SELECT count(*) FROM l WHERE rubric_exit = 0 AND agent_status = 'ok' AND NOT progressed),
  'blocked_runs', (SELECT count(DISTINCT coalesce(run_id, repo || ' ' || ticket)) FROM l
                    WHERE agent_status = 'blocked'),
  'questions', (SELECT count(*) FROM decisions
                 WHERE created_at >= now() - make_interval(days => :'days'::int)),
  'lessons', (SELECT count(*) FROM lessons WHERE resolution IS NOT NULL));
SQL
}

# db_recall_shortlist REPO MODE QUERY FINGERPRINT FIRST_ERROR QVEC SIZE:
# prints, as one JSON array, what the decider reranks: every exact match
# (exact: true), then up to SIZE other lessons, lexical matches first (the
# same rules as db_recall_lessons), then semantic ones. Each has its id,
# the markdown line memory_recall would print (line), and the failure and
# fix the decider reads (failure, fix), each at most 400 characters, which
# decider_recall may trim further to fit DECIDER_RERANK_CHARS.
#   semantic  only with QVEC, the query's embedding (Postgres 17): the
#             nearest resolved lessons by cosine distance, `<=>`, which the
#             HNSW index (vector_cosine_ops) serves, with a similarity of at
#             least 0.7. hnsw.ef_search is fixed at 100 (eng review S1): on a
#             small table the planner scans every row, which is exact.
db_recall_shortlist() {
  local semantic=0
  [[ -z $6 ]] || semantic=1
  db_sql -v repo="$1" -v mode="$2" -v query="$3" -v fingerprint="$4" -v first_error="$5" \
    -v qvec="$6" -v size="$7" -v semantic="$semantic" <<'SQL'
BEGIN;
SET LOCAL hnsw.ef_search = 100;
CREATE TEMP TABLE shortlist ON COMMIT DROP AS
WITH candidates AS (
  SELECT id, signature, first_error, coalesce(lesson, resolution) AS fix,
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
SELECT id, exact, CASE WHEN exact THEN 0 ELSE 1 END AS step, score AS rank_score
  FROM candidates WHERE exact OR score > threshold;
\if :semantic
INSERT INTO shortlist
SELECT n.id, false, 2, n.similarity
  FROM (SELECT id, 1 - (embedding <=> :'qvec'::vector) AS similarity
          FROM lessons
         WHERE embedding IS NOT NULL AND resolution IS NOT NULL
         ORDER BY embedding <=> :'qvec'::vector
         LIMIT :'size'::int) n
 WHERE n.similarity >= 0.7 AND n.id NOT IN (SELECT id FROM shortlist);
\endif
SELECT coalesce(json_agg(json_build_object(
         'id', l.id, 'exact', s.exact, 'step', s.step,
         'line', '- Seen before: ' || left(regexp_replace(l.signature, '\s+', ' ', 'g'), 240)
                 || E'\n  Fix: ' || coalesce(l.lesson, l.resolution),
         'failure', left(regexp_replace(coalesce(nullif(l.first_error, ''), l.signature), '\s+', ' ', 'g'), 400),
         'fix', left(coalesce(l.lesson, l.resolution), 400))
         ORDER BY s.step, s.rank_score DESC, l.id DESC), '[]')
  FROM (SELECT * FROM shortlist WHERE exact
        UNION ALL
        (SELECT * FROM shortlist WHERE NOT exact ORDER BY step, rank_score DESC, id DESC LIMIT :'size'::int)) s
  JOIN lessons l ON l.id = s.id;
COMMIT;
SQL
}

# db_record_decisions ROWS: stores the decider's answers for the current
# loop (RUN_ID, RUN_LOOP) with that loop's call. ROWS is a JSON array of
# objects with the decisions table's columns (see decider_record).
db_record_decisions() {
  db_sql -v run_id="${RUN_ID:-}" -v loop="$RUN_LOOP" -v rows="$1" <<'SQL'
INSERT INTO decisions (call_id, run_id, kind, question, answer, confidence, threshold, mode,
                       latency_ms, acted, lesson_id, model, error, url)
SELECT (SELECT id FROM runs
         WHERE run_id = :'run_id' AND loop = :'loop'::int
           AND kind IN ('continue', 'retry', 'fix-review')
         ORDER BY id DESC LIMIT 1),
       :'run_id', d.kind, d.question, d.answer, d.confidence, d.threshold, d.mode,
       d.latency_ms, d.acted, d.lesson_id, d.model, d.error, d.url
  FROM json_to_recordset(:'rows'::json) AS d(kind text, question text, answer text,
       confidence numeric, threshold numeric, mode text, latency_ms int, acted boolean,
       lesson_id bigint, model text, error text, url text);
SQL
}

# db_decider_calibration: prints, as one JSON array, what the calibration
# gate (decider_calibration_judge) judges each decider by: one object per
# provider, a url and a model (with its revision) that ever answered, most
# recent first, with when it last did (last) and its levels. A level is a
# confidence t at which the provider said "stuck" in shadow mode, and what
# acting at t would have done: under CHALK_DECIDER=on a run stops at its
# first "stuck" at or above the threshold, so each run counts once, by
# that answer. It is judged once the run has shown whether it was right:
#   correct  the run made no progress after it, and was detained
#   judged   correct ones, and those after which a loop progressed (false
#            stops)
#   waiting  neither yet: no progress since, and no detention
# The numbers at any threshold are those of the lowest level at or above it.
# Answers taken under on are left out: one that acted stopped its run, so
# nothing after it could show whether it was right.
db_decider_calibration() {
  db_sql <<'SQL'
WITH a AS (
  SELECT coalesce(d.url, '') AS url, coalesce(d.model, '') AS model, d.run_id, c.loop, d.confidence,
         EXISTS (SELECT 1 FROM runs l
                  WHERE l.run_id = d.run_id AND l.loop > c.loop AND l.progressed
                    AND l.kind IN ('continue', 'retry', 'fix-review')) AS progressed_after,
         EXISTS (SELECT 1 FROM lessons ls WHERE ls.run_id = d.run_id) AS detained
    FROM decisions d JOIN runs c ON c.id = d.call_id
   WHERE d.kind = 'stuck' AND d.answer = 'yes' AND d.mode = 'shadow'
     AND d.run_id IS NOT NULL AND d.confidence IS NOT NULL
), providers AS (
  SELECT coalesce(url, '') AS url, coalesce(model, '') AS model, max(created_at) AS last
    FROM decisions WHERE answer IS NOT NULL GROUP BY 1, 2
), levels AS (
  SELECT DISTINCT url, model, confidence AS t FROM a
), firsts AS (
  SELECT DISTINCT ON (v.url, v.model, v.t, a.run_id) v.url, v.model, v.t, a.progressed_after, a.detained
    FROM levels v JOIN a ON a.url = v.url AND a.model = v.model AND a.confidence >= v.t
   ORDER BY v.url, v.model, v.t, a.run_id, a.loop
), stats AS (
  SELECT url, model, t,
         count(*) FILTER (WHERE progressed_after OR detained) AS judged,
         count(*) FILTER (WHERE detained AND NOT progressed_after) AS correct,
         count(*) FILTER (WHERE NOT progressed_after AND NOT detained) AS waiting
    FROM firsts GROUP BY url, model, t
)
SELECT coalesce(json_agg(json_build_object(
         'url', p.url, 'model', p.model,
         'last', to_char(p.last AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'levels', (SELECT coalesce(json_agg(json_build_object(
                             't', s.t::float8, 'judged', s.judged, 'correct', s.correct, 'waiting', s.waiting)
                           ORDER BY s.t), '[]')
                      FROM stats s WHERE s.url = p.url AND s.model = p.model))
         ORDER BY p.last DESC, p.url, p.model), '[]')
  FROM providers p;
SQL
}

# db_lessons_to_embed LIMIT: prints, as a JSON array, up to LIMIT resolved
# lessons with no embedding, each with its id and the text to embed: its
# failure and its fix. Prints [] on a database with no embedding column.
db_lessons_to_embed() {
  db_sql -v size="$1" <<'SQL'
SELECT EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = 'lessons'::regclass AND attname = 'embedding' AND NOT attisdropped)
       AS has_embedding \gset
\if :has_embedding
SELECT coalesce(json_agg(json_build_object('id', id, 'text', text) ORDER BY id), '[]')
  FROM (SELECT id, left(coalesce(nullif(first_error, ''), signature), 1500)
                   || coalesce(E'\n' || lesson, '') AS text
          FROM lessons
         WHERE resolution IS NOT NULL AND embedding IS NULL
         ORDER BY id LIMIT :'size'::int) t;
\else
SELECT '[]';
\endif
SQL
}

# db_set_embeddings PAIRS: writes lesson embeddings. PAIRS is a JSON array
# of {id, embedding}, the embedding in pgvector's text form.
db_set_embeddings() {
  db_sql -v pairs="$1" <<'SQL'
UPDATE lessons l SET embedding = p.embedding::vector
  FROM json_to_recordset(:'pairs'::json) AS p(id bigint, embedding text)
 WHERE l.id = p.id;
SQL
}

# db_ticket_summary TICKET VAR [FALLBACK]: fills the associative array VAR
# with the ticket's loops, total cost, human interventions (fixes) and
# where it stands (state). Each is FALLBACK, by default "?", when the
# database cannot be read. The state is the latest event (submitted,
# detention, spec_blocked or ready) when no call came after it; otherwise
# ready when the last call was a passing review, stopped when it was
# anything else (the run was stopped, or failed before an outcome), and new
# when there was no call. Lesson distillation at office hours does not
# count as a call here: it follows the detention it resolves.
db_ticket_summary() {
  local -n __summary=$2
  local loops="${3:-?}" cost="${3:-?}" fixes="${3:-?}" state="${3:-?}" row
  if row="$(db_sql -F ' ' -v repo="${| repo_name; }" -v ticket="$1" 2>/dev/null <<'SQL'
SELECT count(*) FILTER (WHERE kind IN ('continue', 'retry', 'fix-review')), coalesce(sum(cost_usd), 0),
       (SELECT count(*) FROM lessons
         WHERE repo = :'repo' AND ticket = :'ticket' AND resolution IS NOT NULL),
       coalesce(
         (SELECT ev.kind FROM events ev
           WHERE ev.repo = :'repo' AND ev.ticket = :'ticket'
             AND ev.created_at >= coalesce(max(r.created_at) FILTER (WHERE r.kind <> 'distill'), '-infinity')
           ORDER BY ev.id DESC LIMIT 1),
         (SELECT CASE WHEN last.kind = 'review' AND last.agent_status = 'pass' THEN 'ready' ELSE 'stopped' END
            FROM runs last
           WHERE last.repo = :'repo' AND last.ticket = :'ticket'
             AND last.kind <> 'distill'
           ORDER BY last.id DESC LIMIT 1),
         'new')
  FROM runs r WHERE repo = :'repo' AND ticket = :'ticket';
SQL
)" && [[ -n $row ]]; then
    read -r loops cost fixes state <<<"$row"
  fi
  __summary=(["loops"]="$loops" ["cost"]="$cost" ["fixes"]="$fixes" ["state"]="${state:-${3:-?}}")
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
