# The sandbox: one throwaway container per run. The repository is cloned into
# a tmpfs RAM disk inside it, the agent and the tests run only there, and the
# only thing that leaves is a git bundle of new commits. The container holds
# no GitLab credentials and mounts the host repository read-only.

CHALK_AUTH_VARS="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN"

agent_auth_present() {
  local var
  for var in $CHALK_AUTH_VARS; do
    [ -z "${!var:-}" ] || return 0
  done
  return 1
}

sandbox_build() {
  docker build -t "$CHALK_DEFAULT_IMAGE" "$CHALK_HOME/share/sandbox"
}

sandbox_ensure_image() {
  if docker image inspect "$CHALK_IMAGE" >/dev/null 2>&1; then
    return 0
  fi
  [ "$CHALK_IMAGE" = "$CHALK_DEFAULT_IMAGE" ] ||
    die "sandbox image '$CHALK_IMAGE' not found locally; pull or build it first"
  info "building default sandbox image (first run only)"
  sandbox_build
}

sandbox_name() {
  printf 'chalk-sandbox-%s-%s' "$(repo_name)" "$1" | tr -c 'a-zA-Z0-9_.-' '-'
}

# Fills SANDBOX_OTEL_ARGS with the docker flags that make Claude Code export
# OpenTelemetry to CHALK_OTEL_ENDPOINT, tagged with the repository and ticket.
# A collector on this machine is reached through host.docker.internal.
sandbox_otel_args() {
  SANDBOX_OTEL_ARGS=()
  [ -n "$CHALK_OTEL_ENDPOINT" ] || return 0
  local endpoint signal
  endpoint="$(printf '%s' "$CHALK_OTEL_ENDPOINT" | sed -E 's#//(localhost|127\.0\.0\.1)#//host.docker.internal#')"
  SANDBOX_OTEL_ARGS=(
    --add-host host.docker.internal:host-gateway
    -e CLAUDE_CODE_ENABLE_TELEMETRY=1
    -e "OTEL_EXPORTER_OTLP_ENDPOINT=$endpoint"
    -e "OTEL_EXPORTER_OTLP_PROTOCOL=$CHALK_OTEL_PROTOCOL"
    -e "OTEL_RESOURCE_ATTRIBUTES=chalk.repo=$(printf '%s' "$(repo_name)" | tr -c 'a-zA-Z0-9_.-' '_'),chalk.ticket=$1"
  )
  for signal in metrics logs traces; do
    case ",$CHALK_OTEL_SIGNALS," in
      *",$signal,"*) SANDBOX_OTEL_ARGS+=(-e "OTEL_$(printf '%s' "$signal" | tr '[:lower:]' '[:upper:]')_EXPORTER=otlp") ;;
    esac
  done
  case ",$CHALK_OTEL_SIGNALS," in
    *",traces,"*) SANDBOX_OTEL_ARGS+=(-e CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1) ;;
  esac
  if [ -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ]; then SANDBOX_OTEL_ARGS+=(-e OTEL_EXPORTER_OTLP_HEADERS); fi
}

# sandbox_start NAME TICKET IO_DIR
sandbox_start() {
  local name="$1" ticket="$2" io_dir="$3" var
  local env_args=(-e HOME=/home/chalk)
  for var in $CHALK_AUTH_VARS ANTHROPIC_BASE_URL; do
    # `-e VAR` without a value passes it through without exposing it in `ps`.
    if [ -n "${!var:-}" ]; then env_args+=(-e "$var"); fi
  done

  sandbox_otel_args "$ticket"

  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" \
    --label "chalk.repo=$(repo_name)" --label "chalk.ticket=$ticket" \
    --user "$(id -u):$(id -g)" \
    --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs "/work:rw,exec,mode=1777,size=$CHALK_TMPFS_SIZE" \
    --tmpfs "/home/chalk:rw,exec,mode=1777,size=1g" \
    -v "$(git_common_dir):/src.git:ro" \
    -v "$io_dir:/chalk" \
    "${env_args[@]}" ${SANDBOX_OTEL_ARGS[@]+"${SANDBOX_OTEL_ARGS[@]}"} \
    "$CHALK_IMAGE" sleep infinity >/dev/null
}

sandbox_stop() {
  docker rm -f "$1" >/dev/null 2>&1 || true
}

# sandbox_sh NAME SCRIPT [ARGS...]: runs a bash script in the cloned repo.
sandbox_sh() {
  local name="$1" script="$2"
  shift 2
  docker exec -w /work/repo "$name" bash -c "$script" chalk "$@"
}

# Clones the branch into the RAM disk, borrowing objects from the read-only
# host store so nothing is copied.
sandbox_clone() {
  local name="$1" branch="$2" author email
  author="$(git config user.name || echo 'Chalk Agent')"
  email="$(git config user.email || echo 'chalk@localhost')"
  docker exec "$name" bash -c '
    set -e
    git config --global --add safe.directory "*"
    git config --global user.name "$2"
    git config --global user.email "$3"
    git clone -q --shared --branch "$1" /src.git /work/repo
  ' chalk "$branch" "$author" "$email"
}

# sandbox_commit NAME MESSAGE [--allow-empty]
sandbox_commit() {
  sandbox_sh "$1" '
    set -e
    git add -A
    if [ -n "$2" ] || ! git diff --cached --quiet; then
      git commit -q $2 -m "$1"
    fi
  ' "$2" "${3:-}"
}

# Discards anything a read-only call (spec check, review) left in the tree.
sandbox_reset() {
  sandbox_sh "$1" 'git reset -q --hard && git clean -fdq'
}

# Writes commits made since BASE to /chalk/out.bundle, or removes the file
# when there are none.
sandbox_export() {
  sandbox_sh "$1" '
    set -e
    rm -f /chalk/out.bundle
    if [ "$(git rev-parse HEAD)" != "$1" ]; then
      git bundle create /chalk/out.bundle "$1..HEAD" >/dev/null 2>&1
    fi
  ' "$2"
}

cmd_sandbox() {
  need docker
  case "${1:-}" in
    build) sandbox_build ;;
    *)     die "usage: chalk sandbox build" ;;
  esac
}
