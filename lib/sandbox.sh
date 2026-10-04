# The sandbox: one throwaway container per run. The repository is cloned into
# a tmpfs RAM disk inside it, the agent and the tests run only there, and the
# only thing that leaves is a git bundle of new commits. The container holds
# no GitLab credentials and mounts the host repository read-only.

# Any one of these lets the agent call Claude.
declare -ga CHALK_AUTH_VARS=(ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN)

agent_auth_present() {
  local var
  for var in "${CHALK_AUTH_VARS[@]}"; do
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

# sandbox_name TICKET: a container name, with anything docker rejects as "-".
sandbox_name() {
  local name
  name="chalk-sandbox-$(repo_name)-$1"
  printf '%s\n' "${name//[^a-zA-Z0-9_.-]/-}"
}

# sandbox_otel_args VAR TICKET: fills the array VAR with the docker flags
# that make Claude Code export OpenTelemetry to CHALK_OTEL_ENDPOINT, tagged
# with the repository and ticket. A collector on this machine is reached
# through host.docker.internal.
sandbox_otel_args() {
  local -n __args=$1
  local ticket="$2" loopback='//@(localhost|127.0.0.1)' endpoint repo signal
  __args=()
  [ -n "$CHALK_OTEL_ENDPOINT" ] || return 0
  endpoint="${CHALK_OTEL_ENDPOINT/$loopback///host.docker.internal}"
  repo="$(repo_name)"
  __args=(
    --add-host host.docker.internal:host-gateway
    -e CLAUDE_CODE_ENABLE_TELEMETRY=1
    -e "OTEL_EXPORTER_OTLP_ENDPOINT=$endpoint"
    -e "OTEL_EXPORTER_OTLP_PROTOCOL=$CHALK_OTEL_PROTOCOL"
    -e "OTEL_RESOURCE_ATTRIBUTES=chalk.repo=${repo//[^a-zA-Z0-9_.-]/_},chalk.ticket=$ticket"
  )
  for signal in metrics logs traces; do
    case ",$CHALK_OTEL_SIGNALS," in
      *",$signal,"*) __args+=(-e "OTEL_${signal@U}_EXPORTER=otlp") ;;
    esac
  done
  case ",$CHALK_OTEL_SIGNALS," in
    *",traces,"*) __args+=(-e CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1) ;;
  esac
  if [ -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ]; then __args+=(-e OTEL_EXPORTER_OTLP_HEADERS); fi
}

# sandbox_start NAME TICKET IO_DIR
sandbox_start() {
  local name="$1" ticket="$2" io_dir="$3" var
  local -a env_args=(-e HOME=/home/chalk) otel_args
  for var in "${CHALK_AUTH_VARS[@]}" ANTHROPIC_BASE_URL; do
    # `-e VAR` without a value passes it through without exposing it in `ps`.
    if [ -n "${!var:-}" ]; then env_args+=(-e "$var"); fi
  done

  sandbox_otel_args otel_args "$ticket"

  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" \
    --label "chalk.repo=$(repo_name)" --label "chalk.ticket=$ticket" \
    --user "$(id -u):$(id -g)" \
    --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs "/work:rw,exec,mode=1777,size=$CHALK_TMPFS_SIZE" \
    --tmpfs "/home/chalk:rw,exec,mode=1777,size=1g" \
    -v "$(git_common_dir):/src.git:ro" \
    -v "$io_dir:/chalk" \
    "${env_args[@]}" "${otel_args[@]}" \
    "$CHALK_IMAGE" sleep infinity >/dev/null
}

sandbox_stop() {
  docker rm -f "$1" >/dev/null 2>&1 || true
}

# sandbox_sh NAME COMMAND [ARGS...]: runs a bash command line in the cloned repo.
sandbox_sh() {
  local name="$1" command="$2"
  shift 2
  docker exec -w /work/repo "$name" bash -c "$command" chalk "$@"
}

# sandbox_script NAME SCRIPT [ARGS...]: runs share/sandbox/scripts/SCRIPT.sh
# in the container. The scripts are written for the sandbox's bash, not ours.
sandbox_script() {
  local name="$1" script="$CHALK_HOME/share/sandbox/scripts/$2.sh"
  shift 2
  docker exec -w /work "$name" bash -c "$(<"$script")" chalk "$@"
}

sandbox_clone() {
  local name="$1" branch="$2" author email
  author="$(git config user.name || echo 'Chalk Agent')"
  email="$(git config user.email || echo 'chalk@localhost')"
  sandbox_script "$name" clone "$branch" "$author" "$email"
}

# sandbox_commit NAME MESSAGE [--allow-empty]
sandbox_commit() {
  sandbox_script "$1" commit "$2" "${3:-}"
}

sandbox_reset() {
  sandbox_script "$1" reset
}

# sandbox_export NAME BASE
sandbox_export() {
  sandbox_script "$1" export "$2"
}

cmd_sandbox() {
  need docker
  case "${1:-}" in
    build) sandbox_build ;;
    *)     die "usage: chalk sandbox build" ;;
  esac
}
