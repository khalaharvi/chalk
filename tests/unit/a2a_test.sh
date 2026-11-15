#!/usr/bin/env bash
# lib/a2a.sh and share/a2a/chalk-a2a.py: the real A2A server, started by
# `chalk a2a up`, driving the real chalk against the fake docker, claude
# and glab. A caller hands it tickets over JSON-RPC, watches them, answers
# a detention and a refused spec, and cancels a run. Skipped where there
# is no python3 or no curl of the system's own; tests/fakes/curl reaches
# no network.
set -euo pipefail
# shellcheck source=tests/unit/testlib.sh
. "$(dirname "$0")/testlib.sh"

if ! command -v python3 >/dev/null 2>&1 || [ ! -x /usr/bin/curl ] ||
   ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
  echo "ok   a2a: skipped, needs python3 3.9 or newer and /usr/bin/curl"
  exit 0
fi

export FAKE_STATE="$tmp/fake" XDG_STATE_HOME="$tmp/state" HOME="$tmp/home" ANTHROPIC_API_KEY=test-key
mkdir -p "$FAKE_STATE" "$HOME" "$tmp/bin"
# `uv run --script FILE ARGS` as the python3 here would run it: the server
# has no dependencies.
cat > "$tmp/bin/uv" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "run --script" ] || exit 1
shift 2
exec python3 "$@"
STUB
chmod +x "$tmp/bin/uv"
export PATH="$CHALK_HOME/tests/fakes:$tmp/bin:$CHALK_HOME/bin:$PATH"
CHALK_A2A_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
export CHALK_A2A_PORT CHALK_A2A_POLL=0.2
url="http://127.0.0.1:$CHALK_A2A_PORT"

git init -q --bare "$tmp/origin.git"
git init -q -b main "$tmp/demo"
cd "$tmp/demo"
git remote add origin "$tmp/origin.git"
chalk init > /dev/null
sed -i.bak 's/^CHALK_TEST_CMD=.*/CHALK_TEST_CMD=test ! -e BROKEN/' .chalk/config && rm .chalk/config.bak
git add -A && git commit -q -m init
trap 'chalk a2a down >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

# rpc METHOD PARAMS: a JSON-RPC call as an A2A 1.0 client makes it; prints
# the answer.
rpc() {
  /usr/bin/curl -s --max-time 120 -H "Authorization: Bearer $token" -H "A2A-Version: 1.0" \
    -H "Content-Type: application/json" \
    -d "$(jq -cn --arg method "$1" --argjson params "$2" '{jsonrpc: "2.0", id: 7, method: $method, params: $params}')" "$url/"
}
# send TICKET SPEC [EXTRA]: SendMessage for a new task; EXTRA is merged
# into the params.
send() {
  rpc SendMessage "$(jq -cn --arg ticket "$1" --arg spec "$2" --argjson extra "${3:-{\}}" \
    '{message: {messageId: ("m-" + $ticket), role: "ROLE_USER",
                parts: [{data: {ticket: $ticket, title: "Over A2A", spec: $spec}}]}} * $extra')"
}
# until_state ID STATE: polls GetTask until the task is in STATE.
until_state() {
  local seen=""
  for _ in $(seq 1 150); do
    seen="$(rpc GetTask "{\"id\": \"$1\"}" | jq -r '.result.status.state')"
    [ "$seen" = "$2" ] && return 0
    sleep 0.2
  done
  echo "task $1 is $seen, not $2" >&2
  return 1
}
# restart [VAR=VALUE...]: the server again, with the fakes told to behave
# as given. Tasks are files, so they are still there.
restart() {
  chalk a2a down > /dev/null
  env "$@" chalk a2a up > "$tmp/up.log" 2>&1 || { cat "$tmp/up.log"; fail "chalk a2a up"; }
}
code() { jq -r '.error.code' <<<"$1"; }
# lacks TEXT HAYSTACK: HAYSTACK does not contain TEXT.
lacks() { ! grep -qF -- "$1" <<<"$2"; }
spec=$'# Over A2A\n\n## Checkpoints\n- [ ] First thing\n- [ ] Second thing\n'

# --- the command ---------------------------------------------------------
status=0
chalk a2a status > "$tmp/status.log" 2>&1 || status=$?
check "before it is started, chalk a2a status says stopped and exits 1" \
  sh -c "test $status -eq 1 && grep -q '^stopped' '$tmp/status.log'"
token="$(chalk a2a token)"
check "the token is 32 random bytes in hex, in a file only its owner can read" \
  sh -c "printf %s '$token' | grep -Eqx '[0-9a-f]{64}' && test \"\$(ls -l '$XDG_STATE_HOME/chalk/demo/a2a/token' | cut -c1-10)\" = '-rw-------'"
check "the token stays the same from one call to the next" test "$(chalk a2a token)" = "$token"
chalk a2a up > "$tmp/up.log" 2>&1 || { cat "$tmp/up.log"; fail "chalk a2a up"; }
check "chalk a2a up says where the server is and how callers sign in" \
  sh -c "grep -q 'A2A server for demo on $url/' '$tmp/up.log' && grep -q 'chalk a2a token' '$tmp/up.log'"
check "chalk a2a status says running" sh -c "chalk a2a status | grep -q '^running (pid [0-9]*) on $url/'"
check "a second chalk a2a up finds it running and starts no other" \
  sh -c "chalk a2a up | grep -q 'already running'"
status=0
chalk a2a sideways > /dev/null 2>&1 || status=$?
check "an unknown chalk a2a command is a usage error: 2" test "$status" -eq 2

# --- the Agent Card and the transport -----------------------------------
card="$(/usr/bin/curl -s "$url/.well-known/agent-card.json")"
check "the Agent Card is public and has every field A2A requires" \
  jq -e '(.name | test("demo")) and (.description | length > 0) and (.version | length > 0) and
    (.capabilities | type == "object") and (.defaultInputModes | length > 0) and (.defaultOutputModes | length > 0) and
    (.skills | length == 2) and all(.skills[]; .id and .name and .description and (.tags | length > 0))' <<<"$card"
check "the card declares one JSON-RPC interface, at this address, speaking A2A 1.0" \
  jq -e --arg url "$url/" '.supportedInterfaces == [{url: $url, protocolBinding: "JSONRPC", protocolVersion: "1.0"}]' <<<"$card"
check "the card declares what is not offered, and the bearer token it needs" \
  jq -e '.capabilities == {streaming: false, pushNotifications: false, extendedAgentCard: false} and
    .securitySchemes.bearer.httpAuthSecurityScheme.scheme == "Bearer" and
    .securityRequirements == [{schemes: {bearer: {list: []}}}]' <<<"$card"
check "the card does not give the token away" lacks "$token" "$card"
check "a call without the token is refused with 401 and a challenge" \
  sh -c "/usr/bin/curl -s -i -H 'A2A-Version: 1.0' -d '{}' '$url/' | tr -d '\r' > '$tmp/401.txt';
    grep -q '^HTTP/1.1 401' '$tmp/401.txt' && grep -qi '^WWW-Authenticate: Bearer' '$tmp/401.txt'"
check "a call with a wrong token is refused" \
  test "$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' -H 'A2A-Version: 1.0' -d '{}' "$url/")" = 401
check "a call without A2A-Version is taken for 0.3 and refused: VersionNotSupportedError" \
  test "$(/usr/bin/curl -s -H "Authorization: Bearer $token" -d '{"jsonrpc":"2.0","id":1,"method":"GetTask","params":{}}' "$url/" | jq -r '.error.code')" = -32009
check "a body that is not JSON: -32700" \
  test "$(/usr/bin/curl -s -H "Authorization: Bearer $token" -H 'A2A-Version: 1.0' -d 'nonsense' "$url/" | jq -r '.error.code')" = -32700
check "an unknown method: -32601" test "$(code "$(rpc Nonsense '{}')")" = -32601
check "streaming is not offered: UnsupportedOperationError" test "$(code "$(rpc SendStreamingMessage '{}')")" = -32004
check "push notifications are not offered: PushNotificationNotSupportedError" \
  test "$(code "$(rpc CreateTaskPushNotificationConfig '{}')")" = -32003
answer="$(rpc GetTask '{"id": "00000000-0000-4000-8000-000000000000"}')"
check "an unknown task: TaskNotFoundError, with A2A's error details" \
  jq -e '.error.code == -32001 and .error.data[0]["@type"] == "type.googleapis.com/google.rpc.ErrorInfo" and
    .error.data[0].reason == "TASK_NOT_FOUND" and .error.data[0].domain == "a2a-protocol.org"' <<<"$answer"
check "a task id that is no id at all is not found either, and reads no file" \
  test "$(code "$(rpc GetTask '{"id": "../../token"}')")" = -32001
check "a new ticket without a spec is refused before anything is created" \
  test "$(code "$(rpc SendMessage '{"message": {"messageId": "m", "parts": [{"text": "AA-9 no spec here"}]}}')")" = -32602
check "the refused ticket got no worktree" test ! -e "$tmp/demo.worktrees/AA-9"

# --- a ticket, start to finish --------------------------------------------
answer="$(send AA-1 "$spec")"
check "SendMessage waits, by default, until the run has ended: the task comes back completed" \
  jq -e '.result.task.status.state == "TASK_STATE_COMPLETED" and (.result.task.id | length) == 36 and
    (.result.task.contextId | length) == 36' <<<"$answer"
check "the request really was opened, by the same chalk run a person would start" \
  sh -c "git -C '$tmp/origin.git' rev-parse -q --verify chalk/AA-1 >/dev/null && grep -q 'mr create.*chalk/AA-1' '$FAKE_STATE/glab.log'"
check "the spec the caller sent is the one that was run, with its checkpoints ticked" \
  sh -c "git -C '$tmp/demo' show chalk/AA-1:specs/AA-1.md | grep -c -e '- \[x\]' | grep -qx 2"
check "the completed task carries an artifact with the outcome record" \
  jq -e '.result.task.artifacts[0].parts[1].data.outcome == "submitted" and .result.task.artifacts[0].artifactId and
    .result.task.metadata.chalk == {ticket: "AA-1", outcome: "submitted"}' <<<"$answer"
check "the status message is from the agent, and the history holds what the user sent" \
  jq -e '.result.task.status.message.role == "ROLE_AGENT" and (.result.task.status.message.parts[0].text | test("AA-1")) and
    (.result.task.history | length) == 1 and .result.task.history[0].role == "ROLE_USER" and
    .result.task.history[0].taskId == .result.task.id' <<<"$answer"
first="$(jq -r '.result.task.id' <<<"$answer")"
check "GetTask with historyLength 0 leaves the history out" \
  jq -e '.result.status.state == "TASK_STATE_COMPLETED" and (.result | has("history") | not)' <<<"$(rpc GetTask "{\"id\": \"$first\", \"historyLength\": 0}")"
check "a message to a task that has ended: UnsupportedOperationError" \
  test "$(code "$(rpc SendMessage "{\"message\": {\"messageId\": \"late\", \"taskId\": \"$first\", \"parts\": [{\"text\": \"more\"}]}}")")" = -32004
check "cancelling a task that has ended: TaskNotCancelableError" test "$(code "$(rpc CancelTask "{\"id\": \"$first\"}")")" = -32002

# --- a detention, answered by the caller ---------------------------------
restart FAKE_CLAUDE_MODE=blocked
answer="$(send AA-2 "$spec" '{"configuration": {"returnImmediately": true}}')"
second="$(jq -r '.result.task.id' <<<"$answer")"
check "with returnImmediately, SendMessage answers while the run is under way" \
  jq -e '.result.task.status.state == "TASK_STATE_WORKING" or .result.task.status.state == "TASK_STATE_INPUT_REQUIRED"' <<<"$answer"
check "a second task for a ticket that has one under way is refused, naming the first" \
  jq -e --arg id "$second" '.error.code == -32602 and .error.data[0].metadata.taskId == $id' <<<"$(send AA-2 "$spec")"
until_state "$second" TASK_STATE_INPUT_REQUIRED || fail "the detained task never asked for input"
answer="$(rpc GetTask "{\"id\": \"$second\"}")"
check "a detained run is a task that needs input: the agent's own blocker and the next step" \
  jq -e '.result.status.state == "TASK_STATE_INPUT_REQUIRED" and
    (.result.status.message.parts[0].text | test("needs the staging API key") and test("next: provide what the agent asked for")
      and test("send a message to this task")) and
    .result.status.message.parts[1].data.outcome == "detained" and
    (.result.status.message.parts[1].data.detention_branch | startswith("detention/AA-2-"))' <<<"$answer"
check "the answer to a detention needs a note" \
  test "$(code "$(rpc SendMessage "{\"message\": {\"messageId\": \"a\", \"taskId\": \"$second\", \"parts\": [{\"data\": {\"patch\": \"\"}}]}}")")" = -32602
check "a message whose contextId is another's is refused" \
  test "$(code "$(rpc SendMessage "{\"message\": {\"messageId\": \"a\", \"taskId\": \"$second\", \"contextId\": \"other\", \"parts\": [{\"text\": \"x\"}]}}")")" = -32602
check "a patch that does not apply is refused" \
  test "$(code "$(rpc SendMessage "{\"message\": {\"messageId\": \"p\", \"taskId\": \"$second\", \"parts\": [{\"text\": \"a note\"}, {\"data\": {\"patch\": \"not a diff\"}}]}}")")" = -32602
check "a refused patch leaves the parked work as it was" test -z "$(git -C "$tmp/demo.worktrees/AA-2" status --porcelain)"
listed="$(rpc ListTasks '{}')"
check "ListTasks lists both tasks, newest status first, with every field of the response" \
  jq -e --arg first "$first" --arg second "$second" '.result.totalSize == 2 and .result.pageSize == 50 and .result.nextPageToken == "" and
    ([.result.tasks[].id] | sort) == ([$first, $second] | sort) and
    (.result.tasks[0].status.timestamp >= .result.tasks[1].status.timestamp) and
    all(.result.tasks[]; has("artifacts") | not)' <<<"$listed"
check "ListTasks filters by state" \
  jq -e --arg second "$second" '.result.totalSize == 1 and .result.tasks[0].id == $second' \
    <<<"$(rpc ListTasks '{"status": "TASK_STATE_INPUT_REQUIRED"}')"
check "ListTasks pages: one at a time, with a token for the next, and artifacts when asked" \
  jq -e '(.result.tasks | length) == 1 and .result.nextPageToken == "1" and (.result.tasks[0] | has("artifacts"))' \
    <<<"$(rpc ListTasks '{"pageSize": 1, "includeArtifacts": true}')"
check "the token for the next page gives the rest, and no further token" \
  jq -e '(.result.tasks | length) == 1 and .result.nextPageToken == ""' <<<"$(rpc ListTasks '{"pageSize": 1, "pageToken": "1"}')"
check "ListTasks refuses a page size out of range" test "$(code "$(rpc ListTasks '{"pageSize": 1000}')")" = -32602

restart
check "after the server is restarted, the task is still there and still asks for input" \
  until_state "$second" TASK_STATE_INPUT_REQUIRED
patch=$'diff --git a/fix.txt b/fix.txt\nnew file mode 100644\n--- /dev/null\n+++ b/fix.txt\n@@ -0,0 +1 @@\n+the key, mocked\n'
answer="$(rpc SendMessage "$(jq -cn --arg id "$second" --arg patch "$patch" '{message: {messageId: "answer-1", taskId: $id,
  parts: [{text: "The staging key cannot be used in tests; mock the client instead."}, {data: {patch: $patch}}]}}')")"
check "an answer with a note and a patch resumes the run, and the task completes" \
  jq -e '.result.task.status.state == "TASK_STATE_COMPLETED" and (.result.task.history | length) == 2' <<<"$answer"
check "the caller's patch was committed to the parked work, and is in what was pushed" \
  sh -c "git -C '$tmp/origin.git' for-each-ref --format='%(refname)' 'refs/heads/tutoring/AA-2-*' | head -n 1 |
    xargs -I{} git -C '$tmp/origin.git' show {}:fix.txt | grep -qx 'the key, mocked'"
check "the caller's note was recorded as the office-hours note" \
  grep -q 'The staging key cannot be used in tests; mock the client instead.' "$FAKE_STATE/db.log"

# --- a refused spec, rewritten by the caller --------------------------------
restart FAKE_SPEC=fail
answer="$(send AA-3 "$spec")"
third="$(jq -r '.result.task.id' <<<"$answer")"
check "a spec the spec check refuses is a task that needs input: its objections, and what to send" \
  jq -e '.result.task.status.state == "TASK_STATE_INPUT_REQUIRED" and
    (.result.task.status.message.parts[0].text | test("not testable") and test("rewritten spec")) and
    .result.task.status.message.parts[1].data.outcome == "spec_blocked"' <<<"$answer"
check "the answer to a refused spec must carry a spec" \
  test "$(code "$(rpc SendMessage "{\"message\": {\"messageId\": \"a\", \"taskId\": \"$third\", \"parts\": [{\"text\": \"try again\"}]}}")")" = -32602
restart
better=$'# Over A2A\n\n## Checkpoints\n- [ ] One thing, with a test\n'
answer="$(rpc SendMessage "$(jq -cn --arg id "$third" --arg spec "$better" \
  '{message: {messageId: "answer-2", taskId: $id, parts: [{data: {spec: $spec}}]}}')")"
check "a rewritten spec starts the run again, and the task completes" \
  jq -e '.result.task.status.state == "TASK_STATE_COMPLETED"' <<<"$answer"
check "the rewritten spec is the one on the branch" \
  sh -c "git -C '$tmp/demo' show chalk/AA-3:specs/AA-3.md | grep -q 'One thing, with a test'"

# --- a text message, and a cancelled run --------------------------------
restart FAKE_CLAUDE_MODE=slow
rm -f "$FAKE_STATE/slow-started"
answer="$(rpc SendMessage "$(jq -cn '{message: {messageId: "text-1", parts: [{text: "AA-4: By text\n\n## Checkpoints\n- [ ] Only thing\n"}]},
  configuration: {returnImmediately: true}}')")"
fourth="$(jq -r '.result.task.id' <<<"$answer")"
check "a text part that starts with the ticket key and holds a checkpoint list starts a task too" \
  jq -e '.result.task.status.state == "TASK_STATE_WORKING"' <<<"$answer"
check "the text's checkpoint list became the ticket's spec" \
  grep -q -e '- \[ \] Only thing' "$tmp/demo.worktrees/AA-4/specs/AA-4.md"
check "a message to a task whose run is under way: UnsupportedOperationError" \
  test "$(code "$(rpc SendMessage "{\"message\": {\"messageId\": \"mid\", \"taskId\": \"$fourth\", \"parts\": [{\"text\": \"hurry\"}]}}")")" = -32004
for _ in $(seq 1 100); do [ -e "$FAKE_STATE/slow-started" ] && break; sleep 0.2; done
read -r pid < "$XDG_STATE_HOME/chalk/demo/runs/AA-4/pid"
answer="$(rpc CancelTask "{\"id\": \"$fourth\"}")"
check "CancelTask returns the task, canceled" jq -e '.result.status.state == "TASK_STATE_CANCELED"' <<<"$answer"
check "CancelTask returned only once the run had ended" sh -c "! kill -0 $pid 2>/dev/null"
parked="$(jq -r '.result.status.message.parts[0].text' <<<"$answer" | grep -o 'detention/AA-4-[0-9-]*' || true)"
check "a canceled task says where the unfinished work is, and the branch exists" \
  git -C "$tmp/demo" show-ref -q --verify "refs/heads/$parked"
check "a canceled task stays canceled" until_state "$fourth" TASK_STATE_CANCELED
check "cancelling it again: TaskNotCancelableError" test "$(code "$(rpc CancelTask "{\"id\": \"$fourth\"}")")" = -32002

# --- stopping the server --------------------------------------------------
chalk a2a down > "$tmp/down.log"
check "chalk a2a down stops the server and frees the port" \
  sh -c "grep -q 'is stopped' '$tmp/down.log' && ! /usr/bin/curl -s -o /dev/null --max-time 2 '$url/health'"
check "the tasks are kept on disk for the next start" \
  test "$(find "$XDG_STATE_HOME/chalk/demo/a2a/tasks" -name '*.json' | wc -l)" -eq 4
status=0
CHALK_A2A_PORT=notaport chalk a2a status > /dev/null 2>&1 || status=$?
check "a CHALK_A2A_PORT that is no port is refused: 4" test "$status" -eq 4
