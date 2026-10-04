# Configuration. Precedence: environment, then .chalk/config, then defaults.
# The config file is parsed as plain KEY=value lines and is never executed.

CHALK_CONFIG_KEYS=" CHALK_BASE_BRANCH CHALK_IMAGE CHALK_SETUP_CMD CHALK_TEST_CMD \
CHALK_RUBRIC_TIMEOUT CHALK_BUDGET_USD CHALK_MAX_LOOPS CHALK_MAX_RETRIES \
CHALK_MAX_PARALLEL CHALK_TMPFS_SIZE CHALK_MODEL CHALK_TEXTBOOK CHALK_AUTO_MR \
CHALK_MEMORY CHALK_MEMORY_BANK CHALK_MEMORY_TOKENS \
CHALK_SPEC_CHECK CHALK_REVIEW CHALK_REVIEW_ROUNDS CHALK_REVIEW_MODEL \
CHALK_CHEAP_MODEL CHALK_DISTILL CHALK_PERMISSION_MODE "

CHALK_DEFAULT_IMAGE="chalk-sandbox:local"

load_config() {
  local file="$1/.chalk/config" line key value
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      key="${line%%=*}"
      value="${line#*=}"
      case "$CHALK_CONFIG_KEYS" in
        *" $key "*) ;;
        *) warn "ignoring unknown key in .chalk/config: $key"; continue ;;
      esac
      # Environment wins over the file.
      [ -n "${!key+set}" ] || printf -v "$key" '%s' "$value"
    done < "$file"
  fi

  : "${CHALK_BASE_BRANCH:=main}"
  : "${CHALK_IMAGE:=$CHALK_DEFAULT_IMAGE}"
  : "${CHALK_SETUP_CMD:=}"
  : "${CHALK_TEST_CMD:=}"
  : "${CHALK_RUBRIC_TIMEOUT:=900}"
  : "${CHALK_BUDGET_USD:=1.00}"
  : "${CHALK_MAX_LOOPS:=20}"
  : "${CHALK_MAX_RETRIES:=2}"
  : "${CHALK_MAX_PARALLEL:=4}"
  : "${CHALK_TMPFS_SIZE:=4g}"
  : "${CHALK_MODEL:=}"
  : "${CHALK_TEXTBOOK:=.chalk/textbook.md}"
  : "${CHALK_AUTO_MR:=true}"
  : "${CHALK_MEMORY:=builtin}"
  : "${CHALK_MEMORY_BANK:=chalk}"
  : "${CHALK_MEMORY_TOKENS:=800}"
  : "${CHALK_SPEC_CHECK:=true}"
  : "${CHALK_REVIEW:=true}"
  : "${CHALK_REVIEW_ROUNDS:=1}"
  : "${CHALK_REVIEW_MODEL:=}"
  : "${CHALK_CHEAP_MODEL:=haiku}"
  : "${CHALK_DISTILL:=true}"
  : "${CHALK_PERMISSION_MODE:=auto}"

  # Machine-level settings: environment only, never read from the repository.
  : "${CHALK_MEMORY_URL:=http://127.0.0.1:18888}"
  : "${CHALK_MEMORY_IMAGE:=ghcr.io/vectorize-io/hindsight:latest}"
  # OpenTelemetry export from the agents; off unless an endpoint is set.
  : "${CHALK_OTEL_ENDPOINT:=}"
  : "${CHALK_OTEL_PROTOCOL:=grpc}"
  : "${CHALK_OTEL_SIGNALS:=traces}"

  case "$CHALK_PERMISSION_MODE" in
    auto|bypass) ;;
    *) die "CHALK_PERMISSION_MODE must be 'auto' or 'bypass' (got '$CHALK_PERMISSION_MODE')" ;;
  esac
  case "$CHALK_PERMISSION_MODE:$CHALK_MODEL" in
    auto:*haiku*) die "auto mode does not support Haiku; choose another CHALK_MODEL" ;;
  esac
  case "$CHALK_MEMORY" in
    builtin|hindsight) ;;
    *) die "CHALK_MEMORY must be 'builtin' or 'hindsight' (got '$CHALK_MEMORY')" ;;
  esac
}
