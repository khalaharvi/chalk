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
  [CHALK_MAX_PARALLEL]=auto
  [CHALK_SANDBOX_MEM_MB]=2048
  [CHALK_TMPFS_SIZE]=4g
  [CHALK_MODEL]=""
  [CHALK_TEXTBOOK]=.chalk/textbook.md
  [CHALK_AUTO_MR]=true
  # Kept so that older configs still load; builtin is the only recall.
  [CHALK_MEMORY]=builtin
  [CHALK_SPEC_CHECK]=true
  [CHALK_REVIEW]=true
  [CHALK_REVIEW_ROUNDS]=1
  [CHALK_REVIEW_MODEL]=""
  [CHALK_CHEAP_MODEL]=haiku
  [CHALK_DISTILL]=true
  [CHALK_PERMISSION_MODE]=auto
  [CHALK_FP_RULES]=shadow
  [CHALK_FP_FEEDBACK]=false
  [CHALK_TEST_REPORT]=""
)

# Machine-level settings: environment only, never read from the repository.
declare -gA CHALK_ENV_DEFAULTS=(
  # OpenTelemetry export from the agents; off unless an endpoint is set.
  [CHALK_OTEL_ENDPOINT]=""
  [CHALK_OTEL_PROTOCOL]=grpc
  [CHALK_OTEL_SIGNALS]=traces
  # Seconds to wait for the database; auto adapts to the machine.
  [CHALK_DB_TIMEOUT]=auto
)

# Settings of the Hindsight lesson memory, which was removed. They are
# accepted from .chalk/config or the environment and ignored, with a warning.
declare -gA CHALK_REMOVED_KEYS=(
  [CHALK_MEMORY_URL]=1
  [CHALK_MEMORY_BANK]=1
  [CHALK_MEMORY_TOKENS]=1
  [CHALK_MEMORY_IMAGE]=1
)
# Set once the warning about them has been given, so it is given once.
CHALK_REMOVED_WARNED=""

# load_config ROOT: sets every CHALK_* setting for the repository at ROOT.
load_config() {
  local file="$1/.chalk/config" line key
  local -a removed=()
  for key in "${!CHALK_REMOVED_KEYS[@]}"; do
    if [[ -n ${!key-} ]]; then removed+=("$key"); fi
  done
  if [[ -f $file ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -z $line || $line == \#* ]] && continue
      key="${line%%=*}"
      if [[ $key =~ ^[A-Z][A-Z0-9_]*$ && -v CHALK_REMOVED_KEYS[$key] ]]; then
        [[ " ${removed[*]} " == *" $key "* ]] || removed+=("$key")
        continue
      fi
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
    builtin) ;;
    hindsight) removed=("CHALK_MEMORY=hindsight" "${removed[@]}")
               CHALK_MEMORY=builtin ;;
    *) die "CHALK_MEMORY must be 'builtin' (got '$CHALK_MEMORY')" ;;
  esac
  if (( ${#removed[@]} )) && [[ -z $CHALK_REMOVED_WARNED ]]; then
    CHALK_REMOVED_WARNED=1
    warn "ignoring ${removed[*]}: Hindsight lesson memory was removed." \
      "Lessons are now recalled from the chalk-db lessons table (same failure first, then similar errors)," \
      "with nothing extra to run. Delete these settings; 'chalk memory' says how to remove the old container."
  fi
  case "$CHALK_FP_FEEDBACK" in
    true|false) ;;
    *) die "CHALK_FP_FEEDBACK must be 'true' or 'false' (got '$CHALK_FP_FEEDBACK')" ;;
  esac
  case "$CHALK_FP_RULES" in
    off|shadow|on) ;;
    *) die "CHALK_FP_RULES must be 'off', 'shadow' or 'on' (got '$CHALK_FP_RULES')" ;;
  esac
  [[ $CHALK_MAX_PARALLEL == auto || $CHALK_MAX_PARALLEL =~ ^[1-9][0-9]*$ ]] ||
    die "CHALK_MAX_PARALLEL must be 'auto' or a positive whole number (got '$CHALK_MAX_PARALLEL')"
  [[ $CHALK_SANDBOX_MEM_MB =~ ^[1-9][0-9]*$ ]] ||
    die "CHALK_SANDBOX_MEM_MB must be a positive whole number of MiB (got '$CHALK_SANDBOX_MEM_MB')"
  [[ $CHALK_DB_TIMEOUT == auto || $CHALK_DB_TIMEOUT =~ ^[1-9][0-9]*$ ]] ||
    die "CHALK_DB_TIMEOUT must be 'auto' or a positive number of seconds (got '$CHALK_DB_TIMEOUT')"
}
