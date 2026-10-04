# Lesson recall. Two backends, chosen by CHALK_MEMORY:
#   builtin    text similarity over the lessons table (no extra services)
#   hindsight  a local Hindsight server: semantic, keyword, graph and
#              temporal recall over the same lessons
# Postgres stays the system of record for lessons either way; Hindsight is
# an index over them and can be rebuilt with `chalk memory sync`.
# Memory is best effort: a failure here never stops a run.

CHALK_MEMORY_CONTAINER="chalk-memory"
CHALK_MEMORY_VOLUME="chalk-memory-data"
CHALK_MEMORY_LOCAL_URL="http://127.0.0.1:18888"

memory_enabled() { [ "$CHALK_MEMORY" = "hindsight" ]; }

# True when Chalk owns the server, i.e. CHALK_MEMORY_URL was not pointed elsewhere.
memory_is_managed() { [ "$CHALK_MEMORY_URL" = "$CHALK_MEMORY_LOCAL_URL" ]; }

memory_healthy() { curl -fsS --max-time 3 "$CHALK_MEMORY_URL/health" >/dev/null 2>&1; }

# memory_post PATH TIMEOUT: POSTs JSON from stdin to the lessons bank.
memory_post() {
  curl -fsS --max-time "$2" -H 'content-type: application/json' --data-binary @- \
    "$CHALK_MEMORY_URL/v1/default/banks/$CHALK_MEMORY_BANK$1"
}

# Hindsight needs its own LLM credentials to extract facts from lessons.
# Explicit HINDSIGHT_API_LLM_* variables win; otherwise reuse the Anthropic key.
memory_start_container() {
  local provider="${HINDSIGHT_API_LLM_PROVIDER:-}" key="${HINDSIGHT_API_LLM_API_KEY:-}"
  if [ -z "$key" ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    provider="anthropic"
    key="$ANTHROPIC_API_KEY"
  fi
  if [ -z "$key" ]; then
    warn "Hindsight needs an LLM key: export ANTHROPIC_API_KEY, or HINDSIGHT_API_LLM_PROVIDER and HINDSIGHT_API_LLM_API_KEY"
    return 1
  fi

  local env_args=(-e HINDSIGHT_API_LLM_API_KEY -e "HINDSIGHT_API_WORKER_ID=$CHALK_MEMORY_CONTAINER")
  if [ -n "$provider" ]; then env_args+=(-e "HINDSIGHT_API_LLM_PROVIDER=$provider"); fi
  if [ -n "${HINDSIGHT_API_LLM_MODEL:-}" ]; then env_args+=(-e HINDSIGHT_API_LLM_MODEL); fi
  if [ -n "${HINDSIGHT_API_LLM_BASE_URL:-}" ]; then env_args+=(-e HINDSIGHT_API_LLM_BASE_URL); fi

  # Published on loopback only: the API has no authentication of its own.
  HINDSIGHT_API_LLM_API_KEY="$key" docker run -d --name "$CHALK_MEMORY_CONTAINER" \
    --restart unless-stopped --shm-size=1g \
    -p "127.0.0.1:${CHALK_MEMORY_LOCAL_URL##*:}:8888" \
    -v "$CHALK_MEMORY_VOLUME:/home/hindsight/.pg0" \
    "${env_args[@]}" \
    "$CHALK_MEMORY_IMAGE" >/dev/null
}

# Starts the local server if needed. Returns non-zero, without exiting, when
# memory is unavailable so callers can carry on without it.
memory_up() {
  memory_enabled || return 0
  need curl
  memory_healthy && return 0
  if ! memory_is_managed; then
    warn "memory server at $CHALK_MEMORY_URL is not reachable"
    return 1
  fi

  if [ "$(docker inspect -f '{{.State.Running}}' "$CHALK_MEMORY_CONTAINER" 2>/dev/null)" != "true" ]; then
    if docker inspect "$CHALK_MEMORY_CONTAINER" >/dev/null 2>&1; then
      docker start "$CHALK_MEMORY_CONTAINER" >/dev/null
    else
      info "starting local Hindsight memory (first start downloads the image and models)"
      memory_start_container || return 1
    fi
  fi

  local attempt=0
  until memory_healthy; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 90 ]; then
      warn "memory server did not become ready; see: docker logs $CHALK_MEMORY_CONTAINER"
      return 1
    fi
    sleep 2
  done
}

# Prints lessons relevant to the query as a markdown list. Never fails.
memory_recall() {
  local query="$1"
  if ! memory_enabled; then
    db_similar_lessons "$query" 2>/dev/null || true
    return 0
  fi
  jq -n --arg query "${query:0:1500}" --argjson tokens "$CHALK_MEMORY_TOKENS" \
      '{query: $query, max_tokens: $tokens, budget: "low"}' |
    memory_post /memories/recall 30 2>/dev/null |
    jq -r '.results[]? | "- " + .text' 2>/dev/null || true
}

# Sends resolved lessons that Hindsight has not seen yet. Returns non-zero
# if any could not be stored; they stay queued for the next sync.
memory_sync() {
  memory_enabled || return 0
  local row id failed=0
  local -a rows
  mapfile -t rows < <(db_unsynced_lessons)
  for row in "${rows[@]}"; do
    [ -n "$row" ] || continue
    id="$(jq -r '.id' <<<"$row")"
    if jq '{items: [{
              content: ("Failure seen by a coding agent:\n" + .signature
                        + "\n\nHow an engineer resolved it:\n" + .resolution
                        + (if .lesson then "\n\nLesson:\n" + .lesson else "" end)),
              context: "Lesson from Chalk office hours",
              document_id: ("chalk-lesson-" + (.id | tostring)),
              metadata: {repo: .repo, ticket: .ticket}
            }]}' <<<"$row" | memory_post /memories 180 >/dev/null 2>&1; then
      db_mark_lesson_synced "$id"
    else
      failed=1
    fi
  done
  return "$failed"
}

cmd_memory() {
  need docker
  load_config "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  memory_enabled || die "memory backend is 'builtin'; set CHALK_MEMORY=hindsight in .chalk/config to use Hindsight"
  case "${1:-}" in
    up)   memory_up || die "memory could not be started"
          info "memory is up at $CHALK_MEMORY_URL (bank: $CHALK_MEMORY_BANK)" ;;
    down) docker stop "$CHALK_MEMORY_CONTAINER" >/dev/null
          info "memory stopped (data kept in volume $CHALK_MEMORY_VOLUME)" ;;
    sync) db_up
          memory_up || die "memory could not be started"
          memory_sync || die "some lessons could not be stored; check: docker logs $CHALK_MEMORY_CONTAINER"
          info "lessons are in sync" ;;
    *)    die "usage: chalk memory up|down|sync" ;;
  esac
}
