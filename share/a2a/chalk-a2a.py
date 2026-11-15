#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""chalk-a2a: an Agent2Agent (A2A) 1.0 front end to one repository's Chalk.

`chalk a2a up` starts it with `uv run --script`. It lets another agent
operate the harness: hand it a ticket and a spec, watch the run, answer a
detention, cancel. It is a thin wrapper: everything it does, it does by
running the same `chalk` and `git` commands a person would, and everything
it knows about a run comes from `chalk status --json`.

It listens on 127.0.0.1 only, and every call but the Agent Card needs the
bearer token in --token-file.

    GET  /.well-known/agent-card.json   the Agent Card (public)
    GET  /health                        {"status": "ok", ...} (public)
    POST /                              JSON-RPC 2.0, A2A-Version: 1.0

Methods: SendMessage, GetTask, ListTasks, CancelTask. Streaming, push
notifications and the extended card are not offered, and say so.

A task is one ticket's journey to a pull or merge request:

    SendMessage, no taskId    data part {"ticket", "title"?, "spec"?}, or a
                              text part that starts with the ticket key.
                              Creates the worktree, commits the spec and
                              starts the run.
    TASK_STATE_WORKING        a run is alive
    TASK_STATE_COMPLETED      the request is open (or ready to submit)
    TASK_STATE_INPUT_REQUIRED the run was detained, or the spec was refused.
                              The status message says why and what to do.
    SendMessage, with taskId  the answer: its text is the office-hours
                              note; a data part may carry {"patch"} (a
                              unified diff, applied and committed on the
                              detention branch) or {"spec"} (a new spec).
    TASK_STATE_FAILED         nothing could be attempted, or Chalk failed
    CancelTask                stops the run; its work stays parked

    chalk-a2a.py --port 8473 --repo DIR --state DIR --token-file FILE
                 --bash BASH --chalk BIN [--pidfile FILE]
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PROTOCOL_VERSION = "1.0"
TICKET = re.compile(r"^[A-Z][A-Z0-9]+-[0-9]+$")
TERMINAL = {"TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED", "TASK_STATE_REJECTED"}
STATES = TERMINAL | {"TASK_STATE_SUBMITTED", "TASK_STATE_WORKING", "TASK_STATE_INPUT_REQUIRED", "TASK_STATE_AUTH_REQUIRED"}

# JSON-RPC and A2A error codes, with the reason A2A puts in error.data.
ERRORS = {
    "parse": (-32700, "JSON_PARSE_ERROR"),
    "request": (-32600, "INVALID_REQUEST"),
    "method": (-32601, "METHOD_NOT_FOUND"),
    "params": (-32602, "INVALID_PARAMS"),
    "internal": (-32603, "INTERNAL_ERROR"),
    "task_not_found": (-32001, "TASK_NOT_FOUND"),
    "not_cancelable": (-32002, "TASK_NOT_CANCELABLE"),
    "no_push": (-32003, "PUSH_NOTIFICATION_NOT_SUPPORTED"),
    "unsupported": (-32004, "UNSUPPORTED_OPERATION"),
    "version": (-32009, "VERSION_NOT_SUPPORTED"),
}
UNSUPPORTED = {"SendStreamingMessage", "SubscribeToTask", "GetExtendedAgentCard"}
PUSH = {
    "CreateTaskPushNotificationConfig",
    "GetTaskPushNotificationConfig",
    "ListTaskPushNotificationConfigs",
    "DeleteTaskPushNotificationConfig",
}


class A2AError(Exception):
    def __init__(self, kind: str, message: str, **metadata: str):
        super().__init__(message)
        self.kind, self.message, self.metadata = kind, message, metadata

    def body(self) -> dict:
        code, reason = ERRORS[self.kind]
        info = {
            "@type": "type.googleapis.com/google.rpc.ErrorInfo",
            "reason": reason,
            "domain": "a2a-protocol.org",
            "metadata": self.metadata,
        }
        return {"code": code, "message": self.message, "data": [info]}


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Chalk:
    """One repository's harness, through its command line."""

    def __init__(self, bash: str, chalk: str, repo: Path, poll: float):
        self.command = [bash, chalk]
        self.repo = repo
        self.poll = poll

    def worktree(self, ticket: str) -> Path:
        return Path(f"{self.repo}.worktrees") / ticket

    def run(self, args: list[str], cwd: Path) -> subprocess.CompletedProcess:
        return subprocess.run(self.command + args, cwd=cwd, capture_output=True, text=True)

    def git(self, args: list[str], cwd: Path, stdin: str | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, input=stdin)

    def status(self, ticket: str) -> dict | None:
        """The ticket's object from `chalk status TICKET --json`, if it has a run."""
        done = self.run(["status", ticket, "--json"], self.repo)
        if done.returncode != 0:
            raise A2AError("internal", f"chalk status failed: {done.stderr.strip()[-400:]}")
        rows = json.loads(done.stdout or "[]")
        return rows[0] if rows else None

    def record(self, done: subprocess.CompletedProcess) -> dict:
        """The one line of JSON a `--json` command prints, or a stand-in for it."""
        line = done.stdout.strip().splitlines()[-1] if done.stdout.strip() else ""
        try:
            record = json.loads(line)
            if isinstance(record, dict):
                return record
        except ValueError:
            pass
        reason = done.stderr.strip().splitlines()[-1] if done.stderr.strip() else "chalk gave no reason"
        return {"outcome": "failed", "exit_code": done.returncode, "reason": reason}

    def commit(self, cwd: Path, message: str) -> None:
        self.git(["add", "-A"], cwd)
        if self.git(["diff", "--cached", "--quiet"], cwd).returncode != 0:
            done = self.git(["commit", "-q", "-m", message], cwd)
            if done.returncode != 0:
                raise A2AError("internal", f"git could not commit: {done.stderr.strip()[-400:]}")

    def clean(self, cwd: Path) -> bool:
        return self.git(["status", "--porcelain"], cwd).stdout.strip() == ""


class Tasks:
    """Tasks, one JSON file each, so that they outlive the server."""

    def __init__(self, directory: Path, chalk: Chalk):
        self.directory = directory
        self.chalk = chalk
        self.lock = threading.Lock()
        directory.mkdir(parents=True, exist_ok=True)

    def path(self, task_id: str) -> Path:
        return self.directory / f"{task_id}.json"

    def load(self, task_id: object) -> dict:
        if not isinstance(task_id, str) or not re.fullmatch(r"[0-9a-f-]{36}", task_id) or not self.path(task_id).is_file():
            raise A2AError("task_not_found", f"no task {task_id!r}", taskId=str(task_id))
        return json.loads(self.path(task_id).read_text(encoding="utf-8"))

    def save(self, task: dict) -> None:
        temporary = self.path(task["id"]).with_suffix(".tmp")
        temporary.write_text(json.dumps(task), encoding="utf-8")
        os.replace(temporary, self.path(task["id"]))

    def all(self) -> list[dict]:
        return [json.loads(file.read_text(encoding="utf-8")) for file in self.directory.glob("*.json")]

    # ------------------------------------------------------------ what a task looks like

    def view(self, task: dict) -> dict:
        """The A2A Task for a stored task, from what Chalk says about its ticket now.

        A task seen in a terminal state is frozen there: a later run of the
        same ticket belongs to a later task.
        """
        if "final" in task:
            return task["final"]
        ticket = task["ticket"]
        outcome = None
        if task.get("canceled"):
            state, text, stamp = "TASK_STATE_CANCELED", task["canceled"], task["updated"]
        elif task.get("pending"):
            state, text, stamp = "TASK_STATE_WORKING", task["pending"], task["updated"]
        else:
            row = self.chalk.status(ticket)
            # A start that Chalk refused left no run, only what it said.
            outcome = task.get("refused") or (row or {}).get("outcome")
            if row and row.get("running"):
                state, text, stamp = "TASK_STATE_WORKING", f"a run of {ticket} is under way (pid {row.get('pid')})", task["updated"]
            elif not outcome:
                state, stamp = "TASK_STATE_FAILED", task["updated"]
                text = f"the run of {ticket} ended without a record of how; see: chalk logs {ticket}"
            else:
                state = {
                    "submitted": "TASK_STATE_COMPLETED",
                    "ready": "TASK_STATE_COMPLETED",
                    "detained": "TASK_STATE_INPUT_REQUIRED",
                    "stopped": "TASK_STATE_INPUT_REQUIRED",
                    "spec_blocked": "TASK_STATE_INPUT_REQUIRED",
                }.get(outcome.get("outcome"), "TASK_STATE_FAILED")
                stamp = outcome.get("ended_at") or task["updated"]
                text = self.describe(ticket, outcome, state)
        if task.get("note") and state == "TASK_STATE_INPUT_REQUIRED":
            text = f"{task['note']}\n\n{text}"

        parts: list[dict] = [{"text": text}]
        if outcome:
            parts.append({"data": outcome, "mediaType": "application/json"})
        seen = {
            "id": task["id"],
            "contextId": task["contextId"],
            "status": {
                "state": state,
                "timestamp": stamp,
                "message": {
                    "messageId": f"{task['id']}-{stamp}-{state}",
                    "role": "ROLE_AGENT",
                    "taskId": task["id"],
                    "contextId": task["contextId"],
                    "parts": parts,
                },
            },
            "artifacts": [],
            "history": task["history"],
            "metadata": {"chalk": {"ticket": ticket, "outcome": (outcome or {}).get("outcome")}},
        }
        if state == "TASK_STATE_COMPLETED":
            where = outcome.get("request_url") or f"branch {outcome.get('branch')}"
            seen["artifacts"] = [
                {
                    "artifactId": f"{task['id']}-request",
                    "name": "pull or merge request",
                    "description": "The finished work, for a person to review.",
                    "parts": [{"text": where}, {"data": outcome, "mediaType": "application/json"}],
                }
            ]
        if state in TERMINAL:
            with self.lock:
                task["final"] = seen
                self.save(task)
        return seen

    @staticmethod
    def describe(ticket: str, outcome: dict, state: str) -> str:
        lines = [f"{ticket}: {outcome.get('reason') or outcome.get('outcome')}"]
        if outcome.get("detail"):
            lines.append(str(outcome["detail"]))
        if outcome.get("next"):
            lines.append(f"next: {outcome['next']}")
        if state == "TASK_STATE_INPUT_REQUIRED":
            if outcome.get("outcome") == "spec_blocked":
                lines.append('To go on, send a message to this task with a data part {"spec": "<the rewritten spec>"}.')
            else:
                lines.append(
                    f"The unfinished work is on branch {outcome.get('detention_branch')}. To go on, send a message to "
                    'this task: its text is recorded as the office-hours note, and a data part may carry {"patch": '
                    '"<a unified diff to apply there>"} or {"spec": "<a new spec>"}.'
                )
        return "\n".join(lines)

    def wait(self, task: dict) -> dict:
        """Blocks until the task is in a terminal or interrupted state."""
        while True:
            seen = self.view(self.load(task["id"]))
            if seen["status"]["state"] not in ("TASK_STATE_WORKING", "TASK_STATE_SUBMITTED"):
                return seen
            time.sleep(self.chalk.poll)

    # ------------------------------------------------------------ what a message does

    def start(self, message: dict, wanted: dict) -> dict:
        """A message with no taskId: a new task for the ticket it names."""
        ticket, chalk = wanted.get("ticket"), self.chalk
        if not isinstance(ticket, str) or not TICKET.match(ticket):
            raise A2AError(
                "params",
                'a new task needs a ticket key such as API-7: send a data part {"ticket": "API-7", "title": "...", '
                '"spec": "<markdown with a checkpoint list>"}, or a text part that starts with the key',
            )
        with self.lock:
            for other in self.all():
                if other["ticket"] == ticket and "final" not in other and not other.get("canceled"):
                    raise A2AError("params", f"{ticket} already has task {other['id']}; send to that task, or cancel it", taskId=other["id"])
            worktree = chalk.worktree(ticket)
            spec = wanted.get("spec")
            if not worktree.is_dir():
                if not isinstance(spec, str) or "- [ ]" not in spec:
                    raise A2AError("params", f'{ticket} is new, so the message must carry its spec: a data part {{"spec": "..."}} with a "- [ ]" checkpoint list')
                made = chalk.run(["new", ticket, *str(wanted.get("title") or "").split()], chalk.repo)
                if made.returncode != 0:
                    raise A2AError("internal", f"chalk new {ticket} failed: {made.stderr.strip()[-400:]}")
            if isinstance(spec, str) and spec.strip():
                (worktree / "specs").mkdir(exist_ok=True)
                (worktree / "specs" / f"{ticket}.md").write_text(spec.rstrip("\n") + "\n", encoding="utf-8")
            chalk.commit(worktree, f"chalk({ticket}): spec")
            task = {
                "id": str(uuid.uuid4()),
                "contextId": message.get("contextId") or str(uuid.uuid4()),
                "ticket": ticket,
                "created": now(),
                "updated": now(),
                "history": [],
            }
            self.remember(task, message)
            record = chalk.record(chalk.run(["run", "--detach", "--json"], worktree))
            if record.get("outcome") != "started":
                task["refused"] = record
            self.save(task)
        return task

    def answer(self, task: dict, message: dict, wanted: dict, note: str) -> None:
        """A message to a task that asked for input: office hours, or a new spec."""
        chalk, ticket = self.chalk, task["ticket"]
        state = self.view(task)["status"]["state"]
        if state in TERMINAL:
            raise A2AError("unsupported", f"task {task['id']} has ended ({state}); start a new task", taskId=task["id"])
        if state != "TASK_STATE_INPUT_REQUIRED":
            raise A2AError("unsupported", f"the run of {ticket} is under way and takes no messages; wait for it, or cancel the task", taskId=task["id"])
        outcome = (chalk.status(ticket) or {}).get("outcome") or {}
        worktree = chalk.worktree(ticket)
        if not chalk.clean(worktree):
            raise A2AError("internal", f"{worktree} has uncommitted changes; commit or discard them first")
        spec, patch = wanted.get("spec"), wanted.get("patch")
        if outcome.get("outcome") == "spec_blocked":
            if not isinstance(spec, str) or "- [ ]" not in spec:
                raise A2AError("params", 'the spec was refused, so the answer must carry a rewritten one: a data part {"spec": "..."}')
            command = ["run", "--detach", "--json"]
        else:
            if not note.strip():
                raise A2AError("params", "the answer to a detention needs a text part: what was wrong and how it was fixed, kept as the office-hours note")
            branch = outcome.get("detention_branch")
            if not branch:
                # Stopped before any loop: nothing is parked, so there is
                # nothing to hold office hours over. The run starts again.
                command = ["run", "--detach", "--json"]
            elif chalk.git(["switch", "-q", branch], worktree).returncode != 0:
                raise A2AError("internal", f"the detention branch of {ticket} ({branch}) could not be checked out")
            else:
                command = ["office-hours", "-m", note, "--detach", "--json"]
            if branch and isinstance(patch, str) and patch.strip():
                applied = chalk.git(["apply", "--index", "--whitespace=nowarn", "-"], worktree, stdin=patch if patch.endswith("\n") else patch + "\n")
                if applied.returncode != 0:
                    chalk.git(["reset", "-q", "--hard"], worktree)
                    raise A2AError("params", f"the patch does not apply to {branch}: {applied.stderr.strip()[-400:]}")
        if isinstance(spec, str) and spec.strip():
            (worktree / "specs" / f"{ticket}.md").write_text(spec.rstrip("\n") + "\n", encoding="utf-8")
        chalk.commit(worktree, f"chalk({ticket}): answer to the harness, over A2A")

        with self.lock:
            self.remember(task, message)
            task["pending"] = f"resuming {ticket}: recording the answer and starting the run"
            task.pop("note", None)
            self.save(task)

        # Office hours distils the note into a lesson with an agent call
        # before the run starts, so it goes on behind the reply.
        def resume() -> None:
            record = chalk.record(chalk.run(command, worktree))
            with self.lock:
                current = self.load(task["id"])
                current.pop("pending", None)
                current["updated"] = now()
                if record.get("outcome") not in ("started", "submitted", "ready"):
                    current["note"] = f"The answer could not be acted on: {record.get('reason') or record.get('outcome')}"
                self.save(current)

        threading.Thread(target=resume, daemon=True).start()

    def remember(self, task: dict, message: dict) -> None:
        kept = dict(message)
        kept.update(taskId=task["id"], contextId=task["contextId"], role="ROLE_USER")
        task["history"].append(kept)
        task["updated"] = now()

    def cancel(self, task: dict) -> dict:
        seen = self.view(task)
        state = seen["status"]["state"]
        if state in TERMINAL:
            raise A2AError("not_cancelable", f"task {task['id']} has already ended ({state})", taskId=task["id"])
        ticket, parked = task["ticket"], ""
        if state == "TASK_STATE_WORKING" and not task.get("pending"):
            stopped = self.chalk.run(["stop", ticket], self.chalk.repo)
            if stopped.returncode not in (0, 4):
                raise A2AError("internal", f"chalk stop {ticket} failed: {stopped.stderr.strip()[-400:]}")
        outcome = (self.chalk.status(ticket) or {}).get("outcome") or {}
        if outcome.get("detention_branch"):
            parked = f" Its unfinished work is on branch {outcome['detention_branch']}."
        with self.lock:
            task = self.load(task["id"])
            task["canceled"] = f"{ticket}: canceled over A2A.{parked}"
            task["updated"] = now()
            self.save(task)
        return self.view(task)


def wanted_from(message: dict) -> tuple[dict, str]:
    """What a message asks for: its data parts merged, and its text."""
    wanted: dict = {}
    texts: list[str] = []
    for part in message.get("parts") or []:
        if not isinstance(part, dict):
            raise A2AError("params", "every part must be an object")
        if isinstance(part.get("data"), dict):
            wanted.update(part["data"])
        elif isinstance(part.get("text"), str):
            texts.append(part["text"])
        else:
            raise A2AError("params", 'only text parts and data parts that hold an object are understood')
    text = "\n".join(texts)
    if "ticket" not in wanted:
        first = text.split(None, 1)
        key = first[0].rstrip(":") if first else ""
        if TICKET.match(key):
            wanted["ticket"] = key
            rest = first[1] if len(first) > 1 else ""
            if "- [ ]" in rest and "spec" not in wanted:
                wanted["spec"] = rest if rest.lstrip().startswith("#") else f"# {key}\n\n{rest}"
            elif rest and "title" not in wanted:
                wanted["title"] = rest.splitlines()[0][:80]
    return wanted, text


def trimmed(task: dict, history_length: object, artifacts: bool = True) -> dict:
    """A Task as a caller asked for it: history capped, artifacts optional."""
    out = dict(task)
    if history_length is not None:
        if not isinstance(history_length, int) or isinstance(history_length, bool) or history_length < 0:
            raise A2AError("params", "historyLength must be a whole number, zero or more")
        if history_length == 0:
            out.pop("history", None)
        else:
            out["history"] = task["history"][-history_length:]
    if not artifacts:
        out.pop("artifacts", None)
    return out


class Server:
    def __init__(self, tasks: Tasks, token: str, card: dict):
        self.tasks, self.token, self.card = tasks, token, card

    def call(self, method: str, params: object) -> dict:
        if method in UNSUPPORTED:
            raise A2AError("unsupported", f"{method} is not offered: this agent declares no streaming and no extended card")
        if method in PUSH:
            raise A2AError("no_push", "this agent sends no push notifications; poll with GetTask")
        if method not in ("SendMessage", "GetTask", "ListTasks", "CancelTask"):
            raise A2AError("method", f"no method {method!r}")
        if not isinstance(params, dict):
            raise A2AError("params", "params must be an object")
        return getattr(self, method)(params)

    def SendMessage(self, params: dict) -> dict:  # noqa: N802 (the method's name on the wire)
        message = params.get("message")
        if not isinstance(message, dict) or not isinstance(message.get("messageId"), str) or not message.get("parts"):
            raise A2AError("params", "message needs a messageId and at least one part")
        if message.get("role") not in (None, "ROLE_USER"):
            raise A2AError("params", "a message sent to the agent has role ROLE_USER")
        configuration = params.get("configuration") or {}
        if not isinstance(configuration, dict):
            raise A2AError("params", "configuration must be an object")
        if configuration.get("taskPushNotificationConfig"):
            raise A2AError("no_push", "this agent sends no push notifications; poll with GetTask")
        wanted, text = wanted_from(message)
        tasks = self.tasks
        if message.get("taskId"):
            task = tasks.load(message["taskId"])
            if message.get("contextId") and message["contextId"] != task["contextId"]:
                raise A2AError("params", f"contextId does not match task {task['id']}")
            tasks.answer(task, message, wanted, text)
        else:
            task = tasks.start(message, wanted)
        seen = tasks.view(tasks.load(task["id"])) if configuration.get("returnImmediately") else tasks.wait(task)
        return {"task": trimmed(seen, configuration.get("historyLength"))}

    def GetTask(self, params: dict) -> dict:  # noqa: N802
        return trimmed(self.tasks.view(self.tasks.load(params.get("id"))), params.get("historyLength"))

    def CancelTask(self, params: dict) -> dict:  # noqa: N802
        return self.tasks.cancel(self.tasks.load(params.get("id")))

    def ListTasks(self, params: dict) -> dict:  # noqa: N802
        size = params.get("pageSize", 50)
        if not isinstance(size, int) or isinstance(size, bool) or not 1 <= size <= 100:
            raise A2AError("params", "pageSize must be from 1 to 100")
        token = params.get("pageToken") or "0"
        if not isinstance(token, str) or not token.isdigit():
            raise A2AError("params", "pageToken is not one this agent gave")
        if params.get("status") not in (None, "TASK_STATE_UNSPECIFIED") and params["status"] not in STATES:
            raise A2AError("params", f"status must be a TaskState, such as TASK_STATE_WORKING (got {params['status']!r})")
        seen = [self.tasks.view(task) for task in self.tasks.all()]
        if params.get("contextId"):
            seen = [task for task in seen if task["contextId"] == params["contextId"]]
        if params.get("status") in STATES:
            seen = [task for task in seen if task["status"]["state"] == params["status"]]
        if params.get("statusTimestampAfter"):
            seen = [task for task in seen if task["status"]["timestamp"] >= str(params["statusTimestampAfter"])]
        seen.sort(key=lambda task: (task["status"]["timestamp"], task["id"]), reverse=True)
        start = int(token)
        page = seen[start : start + size]
        return {
            "tasks": [trimmed(task, params.get("historyLength"), bool(params.get("includeArtifacts"))) for task in page],
            "nextPageToken": str(start + size) if start + size < len(seen) else "",
            "pageSize": size,
            "totalSize": len(seen),
        }


def handler_for(server: Server):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "chalk-a2a"

        def log_message(self, form: str, *args: object) -> None:
            sys.stderr.write(f"{now()} {self.address_string()} {form % args}\n")

        def reply(self, status: int, body: dict, headers: dict | None = None) -> None:
            raw = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self) -> None:  # noqa: N802 (http.server's name)
            if self.path == "/.well-known/agent-card.json":
                self.reply(200, server.card)
            elif self.path == "/health":
                self.reply(200, {"status": "ok", "protocolVersion": PROTOCOL_VERSION, "name": server.card["name"]})
            else:
                self.reply(404, {"error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            given = self.headers.get("Authorization") or ""
            if not given.startswith("Bearer ") or not hmac.compare_digest(given[7:].strip().encode(), server.token.encode()):
                self.reply(401, {"error": "a bearer token is required: chalk a2a token"}, {"WWW-Authenticate": 'Bearer realm="chalk-a2a"'})
                return
            request_id = None
            try:
                try:
                    request = json.loads(raw.decode("utf-8"))
                except ValueError as error:
                    raise A2AError("parse", f"the body is not JSON: {error}") from None
                if not isinstance(request, dict) or request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
                    raise A2AError("request", "the body must be one JSON-RPC 2.0 request object")
                request_id = request.get("id")
                # An absent version means 0.3 to A2A, which this agent does not speak.
                version = (self.headers.get("A2A-Version") or "0.3").strip()
                if ".".join(version.split(".")[:2]) != PROTOCOL_VERSION:
                    raise A2AError("version", f"this agent speaks A2A {PROTOCOL_VERSION}; send the header A2A-Version: {PROTOCOL_VERSION} (got {version})", supported=PROTOCOL_VERSION)
                result = server.call(request["method"], request.get("params", {}))
                self.reply(200, {"jsonrpc": "2.0", "id": request_id, "result": result})
            except A2AError as error:
                self.reply(200, {"jsonrpc": "2.0", "id": request_id, "error": error.body()})
            except Exception as error:  # a bug here must not take the connection down without an answer
                sys.stderr.write(f"{now()} internal error: {error!r}\n")
                self.reply(200, {"jsonrpc": "2.0", "id": request_id, "error": A2AError("internal", f"chalk-a2a failed: {error}").body()})

    return Handler


def agent_card(repo: Path, port: int, version: str) -> dict:
    return {
        "name": f"Chalk harness ({repo.name})",
        "description": (
            f"Takes a ticket and its spec for the repository {repo.name}, has coding agents implement it one "
            "checkpoint at a time in a sandbox, runs the repository's own tests after every step, has the result "
            "reviewed, and opens a pull or merge request. A run that cannot make progress stops and asks for input."
        ),
        "version": version,
        "supportedInterfaces": [{"url": f"http://127.0.0.1:{port}/", "protocolBinding": "JSONRPC", "protocolVersion": PROTOCOL_VERSION}],
        "capabilities": {"streaming": False, "pushNotifications": False, "extendedAgentCard": False},
        "defaultInputModes": ["text/plain", "application/json"],
        "defaultOutputModes": ["text/plain", "application/json"],
        "securitySchemes": {"bearer": {"httpAuthSecurityScheme": {"scheme": "Bearer", "description": "The token that `chalk a2a token` prints."}}},
        "securityRequirements": [{"schemes": {"bearer": {"list": []}}}],
        "skills": [
            {
                "id": "run-ticket",
                "name": "Run a ticket to a reviewed request",
                "description": (
                    'Send a data part {"ticket": "API-7", "title": "...", "spec": "<markdown>"}. The spec is a short '
                    'context and a "## Checkpoints" list of "- [ ]" items, each small and provable by a test. The task '
                    "is working while the run is alive and completed when the request is open; its artifact holds the "
                    "request's address, the loops and the cost."
                ),
                "tags": ["coding", "pull-request", "tests", "sandbox"],
                "examples": ['{"ticket": "API-7", "title": "Add rate limiting", "spec": "# API-7: Add rate limiting\\n\\n## Checkpoints\\n- [ ] Token bucket with unit tests"}'],
                "inputModes": ["application/json", "text/plain"],
                "outputModes": ["application/json", "text/plain"],
            },
            {
                "id": "answer-detention",
                "name": "Unblock a run that asked for input",
                "description": (
                    "When a task is input-required, its status message says why the run stopped and what it needs. "
                    "Answer by sending a message to the same task: the text is recorded as the office-hours note and "
                    'becomes a lesson for later runs; a data part may carry {"patch": "<unified diff>"} to apply to '
                    'the parked work, or {"spec": "<markdown>"} to replace the spec. The run then resumes.'
                ),
                "tags": ["coding", "unblock", "human-in-the-loop"],
                "inputModes": ["text/plain", "application/json"],
                "outputModes": ["application/json", "text/plain"],
            },
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--port", type=int, default=8473)
    parser.add_argument("--repo", type=Path, required=True, help="the repository's main checkout")
    parser.add_argument("--state", type=Path, required=True, help="where tasks are kept")
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--bash", required=True, help="the bash that runs chalk")
    parser.add_argument("--chalk", required=True, help="bin/chalk")
    parser.add_argument("--chalk-version", default="0")
    parser.add_argument("--pidfile", type=Path)
    args = parser.parse_args()

    token = args.token_file.read_text(encoding="utf-8").strip()
    if len(token) < 16:
        sys.exit(f"chalk-a2a: {args.token_file} holds no token")
    chalk = Chalk(args.bash, args.chalk, args.repo.resolve(), float(os.environ.get("CHALK_A2A_POLL", "2")))
    server = Server(Tasks(args.state / "tasks", chalk), token, agent_card(chalk.repo, args.port, args.chalk_version))
    # The loopback address only: the token is the one thing between a caller
    # and code that runs on this machine.
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), handler_for(server))
    httpd.daemon_threads = True
    if args.pidfile:
        args.pidfile.write_text(f"{os.getpid()}\n", encoding="utf-8")
    sys.stderr.write(f"{now()} chalk-a2a for {chalk.repo} on http://127.0.0.1:{args.port}/\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
