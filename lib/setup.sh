# One-time setup: environment checks and per-repository scaffolding.

DOCTOR_FAILED=0

# The documentation site, for links in messages.
CHALK_DOCS_URL="https://khalaharvi.github.io/chalk"

# doctor_check required|optional LABEL HINT COMMAND...
doctor_check() {
  local level="$1" label="$2" hint="$3"
  shift 3
  if "$@" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$label"
  elif [ "$level" = "required" ]; then
    printf '  FAIL  %s: %s\n' "$label" "$hint"
    DOCTOR_FAILED=1
  else
    printf '  --    %s: %s\n' "$label" "$hint"
  fi
}

doctor_repo_configured() {
  local root
  root="$(git rev-parse --show-toplevel)" && grep -q '^CHALK_TEST_CMD=.' "$root/.chalk/config"
}

doctor_db_current() {
  [[ ${| db_major; } == 17 ]]
}

# The host profile and the values Chalk derives from it. Informational:
# when a probe fails, Chalk uses its fixed defaults.
doctor_profile() {
  local locks=mkdir
  system_profile
  [[ ${SYS[has_flock]} != 1 ]] || locks=flock
  doctor_check optional "host: ${SYS[os]:-?}, ${SYS[cores]:-?} CPUs, ${SYS[ram_mb]:-?} MiB RAM, $locks locks" \
    "could not read the host's CPUs or memory" test -n "${SYS[cores]:-}" -a -n "${SYS[ram_mb]:-}"
  doctor_check optional "docker: ${SYS[docker_cpus]:-?} CPUs, ${SYS[docker_mem_mb]:-?} MiB" \
    "docker info gave no resources; Chalk uses its fixed defaults" \
    test -n "${SYS[docker_cpus]:-}" -a -n "${SYS[docker_mem_mb]:-}"
  doctor_check optional "fleet runs ${| fleet_parallel; } at once (CHALK_MAX_PARALLEL=$CHALK_MAX_PARALLEL)" "" true
  doctor_check optional "database wait ${| system_timeout 30 "$CHALK_DB_TIMEOUT"; }s (CHALK_DB_TIMEOUT=$CHALK_DB_TIMEOUT)" "" true
}

# Whether loops get auto mode on CHALK_MODEL. Without it Claude Code starts
# in manual mode with no error, and a headless loop has every edit refused.
# load_config has already refused Haiku, which auto mode does not support.
doctor_auto_mode() {
  local label="auto mode for ${CHALK_MODEL:-the default model}" mode
  if [[ $CHALK_PERMISSION_MODE != auto ]]; then
    doctor_check optional "auto mode not used (CHALK_PERMISSION_MODE=$CHALK_PERMISSION_MODE)" "" true
    return 0
  fi
  mode="${| agent_start_mode "$CHALK_MODEL"; }"
  # Claude Code calls manual mode "default".
  [[ $mode != default ]] || mode=manual
  case "$mode" in
    auto) doctor_check required "$label" "" true ;;
    "")   doctor_check optional "$label" \
            "could not verify; needs Docker running and the image built" false ;;
    *)    doctor_check required "$label" \
            "unavailable: loops would start in $mode mode and have every edit refused; choose another CHALK_MODEL, ask an administrator to allow auto mode, or set CHALK_PERMISSION_MODE=bypass" false ;;
  esac
}

# Whether the decider is calibrated (decider_calibration): the numbers it
# is judged by, and what CHALK_DECIDER=on does until it is.
doctor_decider_calibration() {
  local -A cal
  local note
  decider_calibration cal
  note="${| decider_calibration_note cal; }"
  case "${cal[status]}" in
    calibrated) doctor_check optional "decider calibration: $note" "" true ;;
    unknown)    doctor_check optional "decider calibration" \
                  "${note#*: }, so CHALK_DECIDER=on records in shadow mode only (start the database: chalk db up)" false ;;
    *)          doctor_check optional "decider calibration" \
                  "$note; until it is, CHALK_DECIDER=on records in shadow mode only" false ;;
  esac
}

# The decider, all optional: uv, the service, the models and the revisions
# `chalk decider up` resolved, its measured time per decision, and whether
# a run may start it.
doctor_decider() {
  local -A got
  local slow free
  doctor_check optional "uv" "needed only for the local decider: brew install uv" command -v uv
  if [[ $CHALK_DECIDER == off ]]; then
    doctor_check optional "decider off (CHALK_DECIDER=off)" "" true
    return 0
  fi
  # Another machine gets nothing, not even a health check, until acknowledged.
  local -a unacked=()
  decider_unacknowledged unacked
  if (( ${#unacked[@]} )); then
    doctor_check optional "decider (CHALK_DECIDER=$CHALK_DECIDER)" \
      "runs go on with it off: ${| decider_untrusted_hint "${unacked[@]}"; }" false
  fi
  if ! decider_loopback "$CHALK_DECIDER_URL" || ! decider_loopback "$CHALK_EMBED_URL"; then
    info "        a decider or chalk-embed on another machine receives exactly this:"
    decider_disclosure "        " "$CHALK_DECIDER_URL" "$CHALK_EMBED_URL"
  fi
  (( ! ${#unacked[@]} )) || return 0
  if ! decider_local; then
    doctor_check optional "decider at $CHALK_DECIDER_URL (CHALK_DECIDER=$CHALK_DECIDER)" \
      "not answering GET /health, nor a question without it; runs go on without it" \
      decider_healthy "$CHALK_DECIDER_URL" CHALK_DECIDER_TOKEN
    doctor_decider_calibration
    return 0
  fi
  decider_info got
  if [[ -z ${got[decider_model]-} ]]; then
    doctor_check optional "local decider (CHALK_DECIDER=$CHALK_DECIDER)" \
      "not installed, so nothing is asked; run: chalk decider up" false
    return 0
  fi
  doctor_check optional "decider model ${got[decider_model]} on ${got[device]-?}" "" true
  if [[ -n ${got[serve_device]-} ]]; then
    doctor_check optional "decider device: ${| decider_device_note; }" "" true
  fi
  doctor_check optional "decider base model ${got[base_model]-?}" "" true
  doctor_check optional "embedding model ${got[embed_model]-?}" "" true
  doctor_check optional "local decider running" "stopped; the next run starts it, or: chalk decider up" \
    decider_healthy "$DECIDER_LOCAL_URL"
  slow="${| decider_slow; }"
  if [[ -n $slow ]]; then
    doctor_check optional "decider takes $slow ms per decision" \
      "over $DECIDER_SLOW_MS ms on this machine, so it records in shadow mode only: CHALK_DECIDER=on acts as shadow" false
  else
    doctor_check optional "decider takes ${got[bench_ms]:-?} ms per decision (measured by chalk decider up)" "" true
  fi
  doctor_decider_calibration
  free="${| decider_headroom; }"
  if [[ $CHALK_DECIDER != on && -n $free ]] && (( free < DECIDER_HEADROOM_MB )); then
    doctor_check optional "memory beside Docker for the decider: $free MiB" \
      "runs start it only with $DECIDER_HEADROOM_MB MiB free; set CHALK_DECIDER=on to start it anyway" false
  fi
}

cmd_doctor() {
  load_config "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  info "chalk $CHALK_VERSION"
  doctor_check required "bash $BASH_VERSION ($BASH)" "install bash 5.3 or newer" bash_at_least 5 3
  doctor_check required "git"               "install git"                         command -v git
  doctor_check required "jq"                "brew install jq"                     command -v jq
  doctor_check required "openssl"           "install openssl"                     command -v openssl
  doctor_check required "docker CLI"        "install Docker Desktop, OrbStack or Colima" command -v docker
  doctor_check required "docker daemon"     "start your Docker runtime"           docker info
  local forge cli
  forge="${| forge_kind; }"
  cli="${CHALK_FORGE_CLI[$forge]}"
  doctor_check required "$cli ($forge)"     "${CHALK_FORGE_INSTALL[$forge]}"      command -v "$cli"
  doctor_check required "$cli signed in"    "run: $cli auth login"                forge_signed_in
  doctor_check required "agent credentials" "export one of: ${CHALK_AUTH_VARS[*]}"     agent_auth_present
  doctor_check optional "claude on host"    "only needed for 'chalk fleet' planning" command -v claude
  doctor_check optional "telemetry database" "starts on first run, or: chalk db up" db_running
  if db_exists; then
    doctor_check optional "database on Postgres ${| db_major; } (${| db_volumes; })" \
      "run: chalk db upgrade (semantic recall is off until then)" doctor_db_current
  fi
  doctor_profile
  doctor_check optional "sandbox image"     "built on first run, or: chalk sandbox build" docker image inspect "$CHALK_IMAGE"
  doctor_check optional "sandbox bash ${CHALK_SANDBOX_BASH_MIN[0]}.${CHALK_SANDBOX_BASH_MIN[1]}+" \
    "could not confirm; needs Docker running and the image built" sandbox_image_bash_ok
  doctor_auto_mode
  doctor_decider
  doctor_check optional "repo configured"   "run 'chalk init' and set CHALK_TEST_CMD" doctor_repo_configured
  [ "$DOCTOR_FAILED" -eq 0 ] || die "fix the FAIL items above"
}

# Copies a template unless the destination already exists.
init_copy() {
  local template="$CHALK_HOME/share/templates/$1" dest="$2"
  if [ -e "$dest" ]; then
    info "  kept     $dest"
  else
    mkdir -p "$(dirname "$dest")"
    cp "$template" "$dest"
    info "  created  $dest"
  fi
}

init_gitlab_ci() {
  init_copy chalk.gitlab-ci.yml .gitlab/chalk.gitlab-ci.yml
  if [ ! -e .gitlab-ci.yml ]; then
    printf 'include:\n  - local: .gitlab/chalk.gitlab-ci.yml\n' > .gitlab-ci.yml
    info "  created  .gitlab-ci.yml"
  elif ! grep -q 'chalk.gitlab-ci.yml' .gitlab-ci.yml; then
    info "  action   add to .gitlab-ci.yml:"
    info "             include:"
    info "               - local: .gitlab/chalk.gitlab-ci.yml"
  fi
}

cmd_init() {
  need git
  local root
  root="${| repo_root; }"
  cd "$root" || die "cannot enter $root"

  init_copy config               .chalk/config
  init_copy textbook.md          .chalk/textbook.md
  mkdir -p specs
  [ -e specs/.gitkeep ] || : > specs/.gitkeep

  if ! grep -q 'Chalk agent rules' CLAUDE.md 2>/dev/null; then
    cat "$CHALK_HOME/share/templates/CLAUDE.section.md" >> CLAUDE.md
    info "  updated  CLAUDE.md"
  fi

  local forge
  forge="${| forge_kind; }"
  case "$forge" in
    github) init_copy chalk.github-workflow.yml .github/workflows/chalk.yml ;;
    gitlab) init_gitlab_ci ;;
  esac

  init_ci_image_hint "$forge"
}

# init_ci_image_hint FORGE: the closing message. The CI rubric runs in
# CHALK_CI_IMAGE, node:22 unless set, so a repository on another stack
# fails it until that is set; said as an action when CHALK_IMAGE already
# shows the stack is not the default.
init_ci_image_hint() {
  local where image
  local next="next: set CHALK_TEST_CMD in .chalk/config, review .chalk/textbook.md, commit, then 'chalk doctor'"
  case "$1" in
    github) where="the repository variable CHALK_CI_IMAGE" ;;
    *)      where="CHALK_CI_IMAGE in .gitlab/chalk.gitlab-ci.yml" ;;
  esac
  image="${CHALK_IMAGE:-$(sed -n 's/^CHALK_IMAGE=//p' .chalk/config 2>/dev/null | head -n 1)}"
  if [[ -n $image && $image != "$CHALK_DEFAULT_IMAGE" ]]; then
    info "  action   CHALK_IMAGE is $image: set $where to a registry image" \
      "with the same toolchain and bash, or the CI rubric runs in node:22"
    info "$next"
  else
    info "$next"
    info "      not Node 22? set CHALK_IMAGE to a sandbox image with your toolchain, and $where" \
      "to a registry image with it: $CHALK_DOCS_URL/guide/configuring/your-stack/"
  fi
}
