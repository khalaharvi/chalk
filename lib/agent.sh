# Calls to Claude inside a sandbox, and the prompts they use. Every call asks
# for a JSON answer in a fixed shape so the harness never has to parse prose.

# The prompts Chalk ships, as share/prompts/NAME.md.
declare -ga CHALK_PROMPTS=(system continue retry fix-review spec-check review distill breakdown)

# The JSON shape each kind of call must answer in.
declare -gA CHALK_SCHEMA=(
  [loop]='{"type":"object","required":["status","summary"],"properties":{"status":{"enum":["done","blocked"]},"checkpoint":{"type":"string"},"summary":{"type":"string"},"blocker":{"type":"string"}}}'
  [spec]='{"type":"object","required":["verdict","problems"],"properties":{"verdict":{"enum":["pass","fail"]},"problems":{"type":"array","items":{"type":"object","required":["checkpoint","problem"],"properties":{"checkpoint":{"type":"string"},"problem":{"type":"string"},"suggestion":{"type":"string"}}}}}}'
  [review]='{"type":"object","required":["verdict","summary","findings"],"properties":{"verdict":{"enum":["pass","fail"]},"summary":{"type":"string"},"findings":{"type":"array","items":{"type":"object","required":["severity","issue"],"properties":{"severity":{"enum":["blocker","minor"]},"file":{"type":"string"},"issue":{"type":"string"}}}}}}'
  [lesson]='{"type":"object","required":["lesson","scope"],"properties":{"lesson":{"type":"string"},"scope":{"enum":["general","repo","none"]}}}'
  [plan]='{"type":"object","required":["workstreams"],"properties":{"workstreams":{"type":"array","items":{"type":"object","required":["ticket","title","checkpoints"],"properties":{"ticket":{"type":"string"},"title":{"type":"string"},"context":{"type":"string"},"checkpoints":{"type":"array","items":{"type":"string"}}}}}}}'
)

# prompt_known NAME: true when NAME is one of CHALK_PROMPTS.
prompt_known() {
  local name
  for name in "${CHALK_PROMPTS[@]}"; do
    [[ $name == "$1" ]] && return 0
  done
  return 1
}

# prompt_file ROOT NAME -> REPLY: the prompt to use. A repository can
# override any shipped prompt by placing a file at .chalk/prompts/NAME.md.
prompt_file() {
  REPLY="$1/.chalk/prompts/$2.md"
  [[ -f $REPLY ]] || REPLY="$CHALK_HOME/share/prompts/$2.md"
}

# agent_write_system IO_DIR ROOT: the system prompt appended to every call is
# the harness rules followed by the repository's Textbook.
agent_write_system() {
  local io="$1" root="$2"
  cat "${| prompt_file "$root" system; }" > "$io/system.md"
  if [ -f "$root/$CHALK_TEXTBOOK" ]; then
    {
      printf '\n<engineering_rules>\n'
      cat "$root/$CHALK_TEXTBOOK"
      printf '</engineering_rules>\n'
    } >> "$io/system.md"
  fi
}

# Tools a read-only call (spec check, review, distillation) may use.
CHALK_READ_TOOLS=(Read Grep Glob "Bash(git diff *)" "Bash(git log *)" "Bash(git show *)" "Bash(git status *)")

# agent_call SANDBOX IO_DIR NAME MODEL SCHEMA ACCESS, with the prompt on stdin.
# Writes the raw CLI result to IO_DIR/NAME.json. ACCESS is one of:
#   write  the agent may edit and run commands, under CHALK_PERMISSION_MODE
#   read   only the tools in CHALK_READ_TOOLS; everything else is denied
agent_call() {
  local sandbox="$1" io="$2" name="$3" model="$4" schema="$5" access="$6"
  local args=(-p --output-format json --json-schema "$schema"
              --max-budget-usd "$CHALK_BUDGET_USD"
              --append-system-prompt-file /chalk/system.md)
  if [ -n "$model" ]; then args+=(--model "$model"); fi
  if [ "$access" = "read" ]; then
    args+=(--permission-mode dontAsk --allowedTools "${CHALK_READ_TOOLS[@]}")
  elif [ "$CHALK_PERMISSION_MODE" = "bypass" ]; then
    args+=(--dangerously-skip-permissions)
  else
    args+=(--permission-mode auto)
  fi
  docker exec -i -w /work/repo "$sandbox" claude "${args[@]}" \
    > "$io/$name.json" 2> "$io/$name.err"
}

# The Agent SDK's first request to the CLI. Claude Code answers it with the
# permission mode the session starts in, before any message is sent, so
# asking costs nothing.
CHALK_INIT_REQUEST='{"type":"control_request","request_id":"chalk-doctor","request":{"subtype":"initialize"}}'

# agent_start_mode MODEL -> REPLY: the permission mode a loop on MODEL (empty
# for the default) starts in when it asks for auto mode, asked of the claude
# CLI in the sandbox image with the agent's credentials. "auto" when auto
# mode is available; Claude Code falls back to "default" (manual) without an
# error when it is not. Empty when the CLI could not be asked or did not say.
agent_start_mode() {
  local -a auth args=(-p --input-format stream-json --output-format stream-json --verbose
                      --no-session-persistence --permission-mode auto)
  if [ -n "$1" ]; then args+=(--model "$1"); fi
  sandbox_auth_args auth
  REPLY="$(printf '%s\n' "$CHALK_INIT_REQUEST" |
    docker run --rm -i --user "$(id -u):$(id -g)" -e HOME=/tmp "${auth[@]}" \
      --entrypoint timeout "$CHALK_IMAGE" 60 claude "${args[@]}" 2>/dev/null |
    jq -rR 'fromjson? | select(.type? == "control_response")
            | .response.response.current_permission_mode // empty' 2>/dev/null)" || REPLY=""
  [[ $REPLY =~ ^[a-zA-Z]+$ ]] || REPLY=""
}

# agent_field FILE JQ_FILTER: reads from the structured answer; prints nothing
# when the answer is missing or malformed.
agent_field() {
  jq -r "(.structured_output // empty) | $2" "$1" 2>/dev/null || true
}

# agent_cost FILE: a call's cost in USD to four places, like cost_usd in the
# database; 0.0000 when the result is unreadable. Rounding hides float noise
# such as 0.13829080000000002, and jq writes tiny costs as e.g. 1.2e-05.
agent_cost() {
  local cost re='^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
  cost="$(jq -r '.total_cost_usd // 0' "$1" 2>/dev/null || echo 0)"
  [[ $cost =~ $re ]] || cost=0
  LC_ALL=C printf '%.4f\n' "$cost"
}

# agent_usd AMOUNT -> REPLY: AMOUNT, a cost in USD, as people read it:
# dollars and cents ($0.38), or <$0.01 for a cost that rounds to no cents.
# The database and the report card keep four places; logs and requests
# show this. A value that is not a cost comes back as $VALUE.
agent_usd() {
  local re='^[0-9]+(\.[0-9]+)?$'
  REPLY="\$$1"
  if [[ $1 =~ $re ]]; then
    LC_ALL=C printf -v REPLY '$%.2f' "$1"
    if [[ $REPLY == '$0.00' && $1 == *[1-9]* ]]; then REPLY='<$0.01'; fi
  fi
}

# agent_model FILE: the model that did most of a call's work (highest cost in
# the CLI's modelUsage), or nothing when the result does not say.
agent_model() {
  jq -r '.modelUsage // {} | to_entries | max_by(.value.costUSD // 0) | .key // empty' "$1" 2>/dev/null || true
}

# agent_usage FILE VAR: fills the associative array VAR with a call's token
# counts, turns and permission denials, each 0 when the result is unreadable.
agent_usage() {
  local -n __usage=$2
  local -a values
  mapfile -t values < <(jq -r '.usage.input_tokens, .usage.output_tokens,
      .usage.cache_read_input_tokens, .usage.cache_creation_input_tokens,
      .num_turns, (.permission_denials | length?) | . // 0' "$1" 2>/dev/null || true)
  __usage=(
    ["input"]="${values[0]:-0}"       ["output"]="${values[1]:-0}"
    ["cache_read"]="${values[2]:-0}"  ["cache_write"]="${values[3]:-0}"
    ["turns"]="${values[4]:-0}"       ["denials"]="${values[5]:-0}"
  )
}

# Prints the CLI's error subtype if the call ended in an error, else nothing.
agent_error() {
  jq -r 'select(.is_error == true) | .subtype // "error"' "$1" 2>/dev/null || true
}

cmd_prompts() {
  need git
  local root name
  root="${| repo_root; }"
  case "${1:-list}" in
    list)
      for name in "${CHALK_PROMPTS[@]}"; do
        if [ -f "$root/.chalk/prompts/$name.md" ]; then
          printf '%-12s overridden  .chalk/prompts/%s.md\n' "$name" "$name"
        else
          printf '%-12s default\n' "$name"
        fi
      done ;;
    eject)
      name="${2:-}"
      prompt_known "$name" || die "usage: chalk prompts eject NAME   (one of: ${CHALK_PROMPTS[*]})"
      [ ! -e "$root/.chalk/prompts/$name.md" ] || die ".chalk/prompts/$name.md already exists"
      mkdir -p "$root/.chalk/prompts"
      cp "$CHALK_HOME/share/prompts/$name.md" "$root/.chalk/prompts/$name.md"
      info "created .chalk/prompts/$name.md; edit and commit it to change this prompt for the repository" ;;
    *) die "usage: chalk prompts [list | eject NAME]" ;;
  esac
}
