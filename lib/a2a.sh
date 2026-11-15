# The A2A server: an Agent2Agent 1.0 front end to this repository's Chalk
# (share/a2a/chalk-a2a.py), so that another agent can hand it a ticket,
# watch the run, answer a detention and cancel. It runs the same commands
# a person would and reads what they report (docs/reference/
# json-output.md); nothing here knows how a run works.
#
# It is optional, started only by `chalk a2a up`, with `uv run --script`.
# It listens on 127.0.0.1 and asks every caller for a bearer token: a
# caller that holds it can start runs, which spend money and execute code
# in sandboxes, and can commit a patch to a detained run's branch.
#
# Functions marked `-> REPLY` are value functions (docs/bash-style.md).

# Seconds `chalk a2a up` waits for the server to listen. The first start
# may have uv fetch a Python.
A2A_START_TIMEOUT=60

# a2a_dir -> REPLY: where this repository's server keeps its pid, log,
# token and tasks.
a2a_dir() {
  state_dir
  REPLY="$REPLY/a2a"
}

# a2a_pid -> REPLY: the server's pid when it is alive; empty otherwise.
a2a_pid() {
  local pid=""
  REPLY=""
  { read -r pid < "${| a2a_dir; }/pid"; } 2>/dev/null || true
  if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then REPLY="$pid"; fi
}

# a2a_listening PORT: true when something accepts connections on PORT of
# this machine.
a2a_listening() {
  (exec 3<> "/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# a2a_token -> REPLY: the bearer token callers must send, made on first
# use: 32 random bytes in hex, in a file only its owner can read.
a2a_token() {
  local dir file
  dir="${| a2a_dir; }"
  file="$dir/token"
  REPLY=""
  if [[ ! -s $file ]]; then
    mkdir -p "$dir"
    (umask 077 && od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$file") || true
  fi
  if [[ -s $file ]]; then read -r REPLY < "$file" || true; fi
}

# a2a_url -> REPLY: where the server listens.
a2a_url() {
  REPLY="http://127.0.0.1:$CHALK_A2A_PORT/"
}

a2a_up() {
  local dir pid waited=0 root
  need git jq
  need uv
  root="${| main_root; }"
  dir="${| a2a_dir; }"
  pid="${| a2a_pid; }"
  if [[ -n $pid ]]; then
    info "the A2A server for ${| repo_name; } is already running (pid $pid) on ${| a2a_url; }"
    return 0
  fi
  ! a2a_listening "$CHALK_A2A_PORT" ||
    die_unready "port $CHALK_A2A_PORT is in use, perhaps by another repository's A2A server; set CHALK_A2A_PORT to a free one"
  [[ -n ${| a2a_token; } ]] || die "could not create the token in $dir/token"
  agent_auth_present ||
    warn "no agent credentials are exported (${CHALK_AUTH_VARS[*]}); runs started over A2A will be refused until the server is restarted with one"

  rm -f "$dir/pid"
  # From the main checkout, with this shell's environment: the runs it
  # starts get their credentials and settings from here.
  (cd "$root" && jobs_detach "$dir/server.log" uv run --script "$CHALK_HOME/share/a2a/chalk-a2a.py" \
    --port "$CHALK_A2A_PORT" --repo "$root" --state "$dir" --token-file "$dir/token" \
    --bash "$BASH" --chalk "$CHALK_HOME/bin/chalk" --chalk-version "$CHALK_VERSION" --pidfile "$dir/pid")
  until [[ -n ${| a2a_pid; } ]] && a2a_listening "$CHALK_A2A_PORT"; do
    if (( waited >= A2A_START_TIMEOUT * 5 )); then
      a2a_stop
      die "the A2A server did not start in ${A2A_START_TIMEOUT}s; its log ends: $(tail -n 3 "$dir/server.log" 2>/dev/null | paste -sd ' ' -)"
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  info "A2A server for ${| repo_name; } on ${| a2a_url; } (pid ${| a2a_pid; })"
  info "  Agent Card: ${| a2a_url; }.well-known/agent-card.json"
  info "  callers send the header A2A-Version: 1.0 and the bearer token that 'chalk a2a token' prints"
  info "  stop it with: chalk a2a down"
}

# a2a_stop: stops this repository's server, if it runs.
a2a_stop() {
  local pid tries
  pid="${| a2a_pid; }"
  if [[ -n $pid ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    for tries in {1..50}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "${| a2a_dir; }/pid"
}

a2a_status() {
  local pid dir count=0 file
  dir="${| a2a_dir; }"
  pid="${| a2a_pid; }"
  for file in "$dir"/tasks/*.json; do count=$((count + 1)); done
  if [[ -n $pid ]]; then
    info "running (pid $pid) on ${| a2a_url; }, $count task(s) on record; log: $dir/server.log"
  else
    info "stopped, $count task(s) on record; start it with: chalk a2a up"
    return 1
  fi
}

cmd_a2a() {
  local command="${1:-}"
  case "$command" in
    up|down|status|token) ;;
    *) die_usage "usage: chalk a2a up|down|status|token" ;;
  esac
  need git
  load_config "${| main_root; }"
  case "$command" in
    up)     a2a_up ;;
    down)   a2a_stop
            info "the A2A server for ${| repo_name; } is stopped" ;;
    status) a2a_status ;;
    token)  [[ -n ${| a2a_token; } ]] || die "could not create the token in ${| a2a_dir; }/token"
            printf '%s\n' "${| a2a_token; }" ;;
  esac
}
