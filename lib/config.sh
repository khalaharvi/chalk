# Configuration. Precedence: environment, then .chalk/config, then defaults.
# The config file is parsed as plain KEY=value lines and is never executed.

CHALK_DEFAULT_IMAGE="chalk-sandbox:local"

# Settings a repository may put in .chalk/config, with their defaults.
declare -gA CHALK_CONFIG_DEFAULTS=(
  [CHALK_BASE_BRANCH]=main
  [CHALK_FORGE]=auto
  [CHALK_IMAGE]="$CHALK_DEFAULT_IMAGE"
  [CHALK_SETUP_CMD]=""
  [CHALK_TEST_CMD]=""
  [CHALK_RUBRIC_TIMEOUT]=900
  [CHALK_BUDGET_USD]=1.00
  [CHALK_MAX_LOOPS]=20
  [CHALK_MAX_RETRIES]=2
  [CHALK_MAX_PARALLEL]=4
  [CHALK_TMPFS_SIZE]=4g
  [CHALK_MODEL]=""
  [CHALK_TEXTBOOK]=.chalk/textbook.md
  [CHALK_AUTO_MR]=true
  [CHALK_MEMORY]=builtin
  [CHALK_MEMORY_BANK]=chalk
  [CHALK_MEMORY_TOKENS]=800
  [CHALK_SPEC_CHECK]=true
  [CHALK_REVIEW]=true
  [CHALK_REVIEW_ROUNDS]=1
  [CHALK_REVIEW_MODEL]=""
  [CHALK_CHEAP_MODEL]=haiku
  [CHALK_DISTILL]=true
  [CHALK_PERMISSION_MODE]=auto
  [CHALK_FP_RULES]=shadow
  [CHALK_TEST_REPORT]=""
)

# Machine-level settings: environment only, never read from the repository.
declare -gA CHALK_ENV_DEFAULTS=(
  [CHALK_MEMORY_URL]=http://127.0.0.1:18888
  [CHALK_MEMORY_IMAGE]=ghcr.io/vectorize-io/hindsight:latest
  # OpenTelemetry export from the agents; off unless an endpoint is set.
  [CHALK_OTEL_ENDPOINT]=""
  [CHALK_OTEL_PROTOCOL]=grpc
  [CHALK_OTEL_SIGNALS]=traces
)

# load_config ROOT: sets every CHALK_* setting for the repository at ROOT.
load_config() {
  local file="$1/.chalk/config" line key
  if [[ -f $file ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -z $line || $line == \#* ]] && continue
      key="${line%%=*}"
      if [[ ! $key =~ ^[A-Z][A-Z0-9_]*$ || ! -v CHALK_CONFIG_DEFAULTS[$key] ]]; then
        warn "ignoring unknown key in .chalk/config: $key"
        continue
      fi
      # The environment wins over the file, even when it sets an empty value.
      [[ -v $key ]] || printf -v "$key" '%s' "${line#*=}"
    done < "$file"
  fi

  # A setting that is unset or empty takes its default.
  for key in "${!CHALK_CONFIG_DEFAULTS[@]}"; do
    [[ -n ${!key-} ]] || printf -v "$key" '%s' "${CHALK_CONFIG_DEFAULTS[$key]}"
  done
  for key in "${!CHALK_ENV_DEFAULTS[@]}"; do
    [[ -n ${!key-} ]] || printf -v "$key" '%s' "${CHALK_ENV_DEFAULTS[$key]}"
  done

  case "$CHALK_PERMISSION_MODE" in
    auto|bypass) ;;
    *) die "CHALK_PERMISSION_MODE must be 'auto' or 'bypass' (got '$CHALK_PERMISSION_MODE')" ;;
  esac
  case "$CHALK_PERMISSION_MODE:$CHALK_MODEL" in
    auto:*haiku*) die "auto mode does not support Haiku; choose another CHALK_MODEL" ;;
  esac
  case "$CHALK_FORGE" in
    auto|github|gitlab) ;;
    *) die "CHALK_FORGE must be 'auto', 'github' or 'gitlab' (got '$CHALK_FORGE')" ;;
  esac
  case "$CHALK_MEMORY" in
    builtin|hindsight) ;;
    *) die "CHALK_MEMORY must be 'builtin' or 'hindsight' (got '$CHALK_MEMORY')" ;;
  esac
  case "$CHALK_FP_RULES" in
    off|shadow|on) ;;
    *) die "CHALK_FP_RULES must be 'off', 'shadow' or 'on' (got '$CHALK_FP_RULES')" ;;
  esac
}
