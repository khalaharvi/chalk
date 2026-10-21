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
# Writes the raw CLI result to IO_DIR/NAME.json, what it printed on stderr
# to NAME.err and its exit status to NAME.exit; agent_failure reads them.
# A call with no answer after CHALK_AGENT_TIMEOUT seconds is stopped
# (exit 124). ACCESS is one of:
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
  local status=0
  docker exec -i -w /work/repo "$sandbox" timeout "$CHALK_AGENT_TIMEOUT" claude "${args[@]}" \
    > "$io/$name.json" 2> "$io/$name.err" || status=$?
  printf '%s\n' "$status" > "$io/$name.exit"
  return "$status"
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

# What the CLI's messages say, in lower case, for agent_failure.
AGENT_NO_CLI='*@(executable file not found|claude: not found|claude: command not found)*'
AGENT_AUTH_TEXT='*@(invalid api key|authentication|oauth token)*'
AGENT_TLS_TEXT='*@(self-signed certificate|self_signed_cert|unable to verify the first certificate|unable to get local issuer certificate|certificate has expired)*'
AGENT_NETWORK_TEXT='*@(unable to connect|econnrefused|econnreset|enotfound|etimedout|eai_again)*'

# agent_failure IO_DIR NAME -> REPLY: why the call NAME (see agent_call)
# failed, as "CLASS: detail", or empty when it did not. The detail is the
# CLI's own message where it gave one. CLASS is one of
#   timeout      no answer within CHALK_AGENT_TIMEOUT
#   cli_missing  the claude CLI could not be started in the sandbox
#   tls          the sandbox does not trust the API's certificate, as behind
#                a proxy that re-signs HTTPS (see CHALK_EXTRA_CA_CERTS)
#   network      the API could not be reached
#   auth         the credentials were refused (HTTP 401 or 403)
#   rate_limit   the API asked to slow down (HTTP 429)
#   usage_limit  the Claude plan's usage limit was reached
#   overloaded   the API was overloaded (HTTP 529) or unavailable (503)
#   server       another server error (HTTP 5xx)
#   budget       the call reached --max-budget-usd (CHALK_BUDGET_USD)
#   max_turns    the call ran out of turns
#   error        any other error the CLI reported
#   crash        the CLI exited without a readable answer
# Claude Code reports an API error with is_error true, subtype "success",
# terminal_reason "api_error" and the HTTP status in api_error_status, and
# prints nothing on stderr (2.1.x), so the subtype alone says nothing.
# shellcheck disable=SC2053 # the AGENT_* patterns are meant as patterns
agent_failure() {
  local io="$1" name="$2" status="" http="" subtype="" message="" err="" text
  local -a row=()
  REPLY=""
  if [[ -f $io/$name.exit ]]; then read -r status < "$io/$name.exit" || true; fi
  [[ $status =~ ^[0-9]+$ ]] || status=0
  mapfile -t row < <(jq -r 'select(.is_error == true) | (.api_error_status // "" | tostring),
      (.subtype // ""), ((((.result // "") | tostring | split("\n") | .[0]) // "")
      | if length > 300 then .[0:300] + "…" else . end)' \
    "$io/$name.json" 2>/dev/null || true)
  http="${row[0]-}" subtype="${row[1]-}" message="${row[2]-}"
  if [[ -s $io/$name.err ]]; then
    err="$(grep -v '^[[:space:]]*$' "$io/$name.err" 2>/dev/null | tail -n 1 | cut -c1-300 || true)"
  fi
  text="${message@L}"
  if (( status == 124 )); then
    REPLY="timeout: no answer within ${CHALK_AGENT_TIMEOUT:-?}s (CHALK_AGENT_TIMEOUT)"
  elif (( status >= 125 && status <= 127 )) || [[ ${err@L} == $AGENT_NO_CLI ]]; then
    REPLY="cli_missing: ${err:-exit $status}"
  elif (( ${#row[@]} )); then
    if [[ $text == $AGENT_TLS_TEXT ]]; then REPLY="tls"
    elif [[ $text == $AGENT_NETWORK_TEXT ]]; then REPLY="network"
    elif [[ $http == @(401|403) || $text == $AGENT_AUTH_TEXT ]]; then REPLY="auth"
    elif [[ $http == 429 ]]; then REPLY="rate_limit"
    elif [[ $text == *"usage limit"* ]]; then REPLY="usage_limit"
    elif [[ $http == @(503|529) || $text == *overloaded* ]]; then REPLY="overloaded"
    elif [[ $http == 5[0-9][0-9] ]]; then REPLY="server"
    elif [[ $subtype == *budget* ]]; then REPLY="budget"
    elif [[ $subtype == error_max_turns ]]; then REPLY="max_turns"
    else REPLY="error"
    fi
    REPLY+=": ${message:-${subtype:-the CLI gave no message}}${http:+ (HTTP $http)}"
  elif (( status != 0 )) || ! jq -e 'type == "object"' "$io/$name.json" >/dev/null 2>&1; then
    REPLY="crash: ${err:-exit $status, and no answer}"
  fi
}

# agent_failure_class FAILURE -> REPLY: the CLASS of an agent_failure.
agent_failure_class() {
  REPLY="${1%%:*}"
}

# agent_failure_retryable CLASS: true when a retry of the same call can
# succeed. An untrusted certificate, refused credentials, a CLI that cannot
# start and a used-up plan fail the same way every time, so a run stops at
# once instead.
agent_failure_retryable() {
  [[ $1 != @(tls|auth|cli_missing|usage_limit) ]]
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
