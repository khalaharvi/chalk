# Calls to Claude inside a sandbox, and the prompts they use. Every call asks
# for a JSON answer in a fixed shape so the harness never has to parse prose.

# The prompts Chalk ships, as share/prompts/NAME.md.
declare -ga CHALK_PROMPTS=(system continue retry fix-review spec-check review distill breakdown)

# The JSON shape each kind of call must answer in.
declare -gA CHALK_SCHEMA=(
  [loop]='{"type":"object","required":["status","summary"],"properties":{"status":{"enum":["done","blocked"]},"checkpoint":{"type":"string"},"summary":{"type":"string"},"blocker":{"type":"string"}}}'
  [spec]='{"type":"object","required":["verdict","problems"],"properties":{"verdict":{"enum":["pass","fail"]},"problems":{"type":"array","items":{"type":"object","required":["checkpoint","problem"],"properties":{"checkpoint":{"type":"string"},"problem":{"type":"string"},"suggestion":{"type":"string"}}}}}}'
  [review]='{"type":"object","required":["verdict","summary","findings"],"properties":{"verdict":{"enum":["pass","fail"]},"summary":{"type":"string"},"findings":{"type":"array","items":{"type":"object","required":["severity","issue"],"properties":{"severity":{"enum":["blocker","minor"]},"file":{"type":"string"},"issue":{"type":"string"}}}}}}'
  [lesson]='{"type":"object","required":["lesson"],"properties":{"lesson":{"type":"string"}}}'
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

# prompt_file ROOT NAME: a repository can override any shipped prompt by
# placing a file at .chalk/prompts/NAME.md.
prompt_file() {
  if [ -f "$1/.chalk/prompts/$2.md" ]; then
    printf '%s\n' "$1/.chalk/prompts/$2.md"
  else
    printf '%s\n' "$CHALK_HOME/share/prompts/$2.md"
  fi
}

# agent_write_system IO_DIR ROOT: the system prompt appended to every call is
# the harness rules followed by the repository's Textbook.
agent_write_system() {
  local io="$1" root="$2"
  cat "$(prompt_file "$root" system)" > "$io/system.md"
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

# agent_field FILE JQ_FILTER: reads from the structured answer; prints nothing
# when the answer is missing or malformed.
agent_field() {
  jq -r "(.structured_output // empty) | $2" "$1" 2>/dev/null || true
}

agent_cost() {
  local cost
  cost="$(jq -r '.total_cost_usd // 0' "$1" 2>/dev/null || echo 0)"
  case "$cost" in ''|*[!0-9.]*) cost=0 ;; esac
  printf '%s\n' "$cost"
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
  root="$(repo_root)"
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
