# One-time setup: environment checks and per-repository scaffolding.

DOCTOR_FAILED=0

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

  case "${| forge_kind; }" in
    github) init_copy chalk.github-workflow.yml .github/workflows/chalk.yml ;;
    gitlab) init_gitlab_ci ;;
  esac

  info "next: set CHALK_TEST_CMD in .chalk/config, review .chalk/textbook.md, commit, then 'chalk doctor'"
}
