#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The OpenAI Codex catalyst drives Codex's app-server over its program's pipe, in a kept folder of the backends image.

Two services of the image under test, each as docker-compose.yml runs it:
locus-runtime runs the shipped catalyst
(seed/components/catalysts/local/openai-codex/0.1.0/catalyst.wasm) under a
scripted control plane (tests/locus-runtime-image/control_plane.py), and
locus-backends runs the `openai-codex` program, driven by requests signed as CYFR
signs them (harness.py). The control plane plays CYFR's host for the
catalyst's pipe as `Opus.Host.Pipe` does: each `pipe_open` names the
`openai-codex` need and is opened on the program in one login entry's kept folder
under a key of the catalyst's own; `pipe_send`, `pipe_recv` and
`pipe_close` go to the session it opened. The program's command runs
fake-openai-codex.mjs, a stand-in for Codex speaking the app-server lines Codex
0.167.0 was driven to write, keeping its threads in the kept folder.

- `describe` starts the program in a session of its own, reads its
  `model/list` into the `model` and `effort` options, and closes that
  session: no process of it is left.
- A chat round trip: the first message opens a session with the argument
  `app-server`, starts a thread with the request's tools as dynamic tools,
  its system prompt as developer instructions and Codex's own sandbox and
  asking off, and a turn with the request's model and effort; Codex's own
  command is shown as a `tool_call.start`/`end` pair by name only and its
  patch approval allowed; the reply streams as `text.delta` and answers
  `end_turn` with usage and the session, `<key>.<thread>` with the
  thread's usage so far, which each next chat carries back as AQUA does.
- A held call: a message that makes Codex call one of CYFR's tools answers
  a `tool_call` named as the request named the tool, carrying Codex's
  request and turn, and leaves the call held in the running program; the
  next chat, carrying the `tool_result`, attaches and sends only the
  call's answer, which Codex's reply quotes; its usage is the one model
  call's, though Codex sent the thread's total twice.
- An interruption: when the read after the next call's answer is answered
  unavailable, the chat answers provider_error (which the loop does not
  retry) saying the session was interrupted and carrying the session,
  closes the session with its program and sends nothing more; the next
  message, naming the session the refusal carried, resumes the thread
  from the kept folder (`thread/resume`), sending no answer again, and
  counts the interrupted run's model call with its own.
- Resume after retirement: once the session's program is retired idle, the
  next chat naming the session starts the program again and resumes the
  thread, which the kept folder holds.
- A refused sign-in: once Codex's sign-in is gone from its folder, the
  next program started is refused `authentication` before anything reaches
  a thread, and is closed.
- A pipe refusal answers the contract's refusal type; and nothing Codex
  writes to its stderr or its folder, nor any command it ran, reaches any
  answer or event.

Prerequisites: harness.py's, the runtime image suites' (the control plane
on the default bridge's gateway), and the built catalyst. Usage:
tests/locus-backends-image/openai_codex.py IMAGE
"""

import hashlib
import json
import os
import secrets
import sys
import threading

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.append(os.path.join(HERE, "..", "locus-runtime-image"))

from harness import ROOT, Stack, eventually, expect, owner_of, require_docker  # noqa: E402
from control_plane import ZERO_AUTHORITY, ControlPlane  # noqa: E402
import stack as runtime  # noqa: E402

CATALYST = os.path.join(ROOT, "seed", "components", "catalysts", "local", "openai-codex", "0.1.0")
REF = "catalyst:local.openai-codex:0.1.0"
NEED = "openai-codex"
OWNER = owner_of("openai-codex")
HOME = "vlt_openai-codex"
FAKE = "fake-openai-codex.mjs"
PROGRAM = {"name": "openai-codex", "command": f"node /probe/{FAKE}", "env": {}, "home": "kept"}
# Short, so the retirement cases wait little; long enough that a chat
# following another at once finds its session running.
IDLE_MS = 15_000
RUN_TIMEOUT_MS = 120_000
ATHANOR = "ath_openai_codex"
CANARIES = ("FAKE-STDERR-CANARY", "FAKE-FOLDER-CANARY", "auth.json")
FILES = {
    "name": "files",
    "description": "Read the athanor's files",
    "parameters": {"type": "object", "properties": {"action": {"type": "string"}, "path": {"type": "string"}},
                   "required": ["action", "path"]},
}
SYSTEM = "You are a crew member of this athanor."


class Bridge:
    """CYFR's host for the catalyst's pipe, as `Opus.Host.Pipe` is: the need
    granted is `openai-codex`, bound to one login entry's kept home; a key is the
    catalyst's own, hashed with its node and need; a session is answered only
    to the attempt that opened it."""

    def __init__(self, controller):
        self.c = controller
        self.lock = threading.Lock()
        self.sessions = {}
        self.calls = []
        self.refuse_next_open = None
        # Armed, the first read after a call's answer is sent answers
        # unavailable, as a box that could not answer does.
        self.fail_read_after_answer = False
        self.failing = False

    def install(self, plane):
        plane.script("pipe_open", self.open)
        plane.script("pipe_send", self.send)
        plane.script("pipe_recv", self.recv)
        plane.script("pipe_close", self.close)

    @staticmethod
    def guest_error(kind, message):
        return {"error": "guest_error", "type": kind, "message": message}

    def held(self, entry, session):
        with self.lock:
            return self.sessions.get(session) == entry["execution_id"]

    def open(self, args, _caller, entry):
        self.calls.append(("open", args))
        if self.refuse_next_open:
            kind, self.refuse_next_open = self.refuse_next_open, None
            return self.guest_error(kind, "The login entry bound to openai-codex is revoked.")
        if args.get("need") != NEED:
            return {"error": "denied"}
        key = "pipe-" + hashlib.sha256(f"{REF}\0{NEED}\0{args['key']}".encode()).hexdigest()[:40]
        status, answer = self.c.open(OWNER, PROGRAM["name"], key=key, argv=args["argv"], home_id=HOME)
        if status != 200:
            return {"error": "unavailable"}
        with self.lock:
            self.sessions[answer["session"]] = entry["execution_id"]
        return {"ok": {"session": answer["session"], "resumed": answer["resumed"]}}

    def send(self, args, _caller, entry):
        self.calls.append(("send", args))
        if not self.held(entry, args["session"]):
            return {"error": "denied"}
        if self.fail_read_after_answer and any('"contentItems"' in line for line in args["lines"]):
            self.fail_read_after_answer, self.failing = False, True
        status, answer = self.c.send(OWNER, args["session"], args["lines"])
        if status == 200 and answer.get("status") == "running":
            return {"ok": True}
        return self.guest_error("ended", "The program has ended.")

    def recv(self, args, _caller, entry):
        if not self.held(entry, args["session"]):
            return {"error": "denied"}
        if self.failing:
            self.failing = False
            return {"error": "unavailable"}
        status, answer = self.c.recv(OWNER, args["session"], args["after"], args["max_wait_ms"])
        if status != 200:
            return {"error": "unavailable"}
        return {"ok": {"lines": answer["lines"], "dropped": answer["dropped"], "running": answer["running"]}}

    def close(self, args, _caller, entry):
        self.calls.append(("close", args))
        if not self.held(entry, args["session"]):
            return {"error": "denied"}
        self.c.close(OWNER, args["session"])
        return {"ok": True}

    def sent(self):
        """Every line the catalyst sent since the calls were cleared, parsed."""
        return [json.loads(line) for op, args in self.calls if op == "send" for line in args["lines"]]

    def methods(self):
        return [line.get("method", "answer") for line in self.sent()]


def run_catalyst(rt, plane, wasm, operation, params, what):
    """One run of the catalyst: its output, and the events it emitted."""
    attempt = plane.mint(rt.boot, "catalyst", REF, wasm, {"operation": operation, "params": params}, ATHANOR,
                         RUN_TIMEOUT_MS, authority=ZERO_AUTHORITY)
    expect(rt.start(attempt)[1] == {"v": 1, "ok": True}, f"{what}: the catalyst starts")
    closes = plane.wait_for(
        lambda: [r for r in plane.seen(None, attempt["execution_id"]) if r["op"] in ("complete", "fail") and "answered" in r],
        RUN_TIMEOUT_MS / 1000 + 30, f"the {what} run to close")
    expect(closes[0]["op"] == "complete", f"{what}: the catalyst answered and its run closed completed", closes[0])
    output = closes[0]["args"]["outcome"]["output"]
    if isinstance(output, str):
        output = json.loads(output)
    events = [json.loads(delta["event"]) for record in plane.seen("push_deltas", attempt["execution_id"])
              for delta in record["args"]["deltas"]]
    return output, events


def identity(session):
    """A session's key and thread, without the usage it carries."""
    return ".".join(session.split(".")[:2])


def text_of(events):
    return "".join(e["text"] for e in events if e.get("type") == "text.delta")


def fakes(backends):
    """Codex's processes: node running the fake, not the shell that started it."""
    return [p for p in backends.processes() if p["cmd"].startswith(f"node /probe/{FAKE}")]


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: openai_codex.py IMAGE")
    image = sys.argv[1]
    require_docker()
    with open(os.path.join(CATALYST, "catalyst.wasm"), "rb") as handle:
        wasm = handle.read()
    with open(os.path.join(CATALYST, "cyfr-manifest.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)
    need = manifest["needs"].get(NEED, {})
    expect(list(manifest["needs"]) == [NEED] and need.get("type") == "login" and need.get("program") == "openai-codex"
           and "model/chat@1" in manifest["contracts"],
           "the catalyst declares model/chat@1 and one need, a login for the program openai-codex", manifest["needs"])
    install = need.get("install", {})
    expect(install.get("command", "").startswith("npx -y @openai/codex@")
           and install.get("login_command") == install.get("command") + " login --device-auth",
           "the need suggests fetching Codex with npx and signing in by device auth", install)

    backends = Stack("locus-backends-openai-codex", image)
    plane = ControlPlane(secrets.token_bytes(32), runtime.SERVICE).serve()
    rt = runtime.Stack("cyfr-locus-runtime-openai-codex", image, plane)
    answers = []
    try:
        backends.up()
        c = backends.controller()
        expect(c.hello()[0] == 200, "the backends service is greeted")
        status, synced, _ = c.sync(OWNER, [PROGRAM], idle_ms=IDLE_MS)
        expect(status == 200, "an owner of the openai-codex program, kept, is synced", synced)
        bridge = Bridge(c)
        bridge.install(plane)
        rt.up()

        def retired():
            # The owner's lease (30 s) is shorter than this test, and opening
            # a session does not renew it: renew it as CYFR's host does while
            # the program idles out, or the service releases the owner.
            c.running(OWNER)
            return c.program(OWNER, PROGRAM["name"])["sessions"] == 0 and not fakes(backends)

        # ————— describe: Codex's listing —————
        described, events = run_catalyst(rt, plane, wasm, "describe", {"model": "fake-mini"}, "describe")
        answers.append((described, events))
        options = {o["name"]: o for o in described["data"]["options"]}
        expect(described["status"] == 200 and described["data"]["streaming"] is True
               and described["data"]["provider_tools"] == [] and described["data"]["context_window"] > 0,
               "describe answers the contract, streaming, with no provider tools and the model's window", described)
        expect(options["model"] == {"name": "model", "kind": "enum", "values": ["default", "fake-sol", "fake-mini"]}
               and options["effort"]["values"] == ["low", "high", "medium", "xhigh"],
               "the model and effort options are Codex's own listing", options)
        expect([op for op, _ in bridge.calls if op != "send"] == ["open", "close"]
               and bridge.methods() == ["initialize", "initialized", "model/list"],
               "describe lists the models in a session of its own and closes it", bridge.calls)
        eventually(lambda: not fakes(backends), "the listing's program to end with its session")
        modelled, _ = run_catalyst(rt, plane, wasm, "models", {}, "models")
        expect(modelled == {"status": 200, "data": {"models": [
            {"id": "default", "name": "Default (Fake Sol)"}, {"id": "fake-sol", "name": "Fake Sol"},
            {"id": "fake-mini", "name": "Fake Mini"}]}},
            "models answers the same listing, Codex's default first", modelled)

        # ————— a chat round trip —————
        bridge.calls.clear()
        hello = {"model": "default", "system": SYSTEM, "tools": [FILES],
                 "messages": [{"role": "user", "content": "say hello"}],
                 "options": {"model": "fake-mini", "effort": "high"}}
        output, events = run_catalyst(rt, plane, wasm, "chat", hello, "a first chat")
        answers.append((output, events))
        data = output["data"]
        session = data["session"]
        thread = session.split(".")[1]
        expect(bridge.calls[0][1]["argv"] == ["app-server"], "the program starts its app-server", bridge.calls[0])
        expect(bridge.methods() == ["initialize", "initialized", "account/read", "thread/start", "turn/start", "answer"],
               "a first chat signs in, starts a thread and a turn, and allows Codex's patch", bridge.methods())
        expect(output["status"] == 200 and data["stop_reason"] == "end_turn" and data["model"] == "fake-mini"
               and data["content"] == [{"type": "text", "text": f'Hello from the fake Codex: thread {thread}, model fake-mini, '
                                        'effort high, tools files, policy never/danger-full-access, patch accept, '
                                        f'instructions "{SYSTEM}".'}],
               "Codex ran the turn with the request's model, effort and tools, its own sandbox and asking off, "
               "its patch allowed and the system prompt as its instructions", output)
        expect(data["usage"] == {"input_tokens": 12, "output_tokens": len(data["content"][0]["text"]),
                                 "cache_read_tokens": 5, "cache_write_tokens": 2},
               "usage is the turn's model call's", data["usage"])
        expect(text_of(events) == data["content"][0]["text"], "the reply streamed as text deltas", events)
        shown = [e for e in events if e["type"].startswith("tool_call.")]
        expect(shown == [{"type": "tool_call.start", "index": 0, "id": "call_own_1", "name": "commandExecution"},
                         {"type": "tool_call.end", "index": 0}],
               "Codex's own command is shown as a start and end pair, by name only", shown)
        expect(events[-1] == {"type": "stop", "stop_reason": "end_turn"}, "the stream ends with its stop", events[-1])

        # ————— a held call, answered by the next chat —————
        bridge.calls.clear()
        history = [{"role": "user", "content": "say hello"}, {"role": "assistant", "content": data["content"]},
                   {"role": "user", "content": "read notes.txt"}]
        ask = {"model": "default", "session": session, "tools": [FILES], "messages": history}
        output, events = run_catalyst(rt, plane, wasm, "chat", ask, "a chat that calls a tool of CYFR's")
        answers.append((output, events))
        data = output["data"]
        call = data["content"][-1]
        expect(bridge.methods() == ["turn/start"] and data["stop_reason"] == "tool_call" and call["type"] == "tool_call"
               and call["name"] == "files" and call["arguments"] == {"action": "read", "path": "notes.txt"}
               and call["provider_data"]["request_id"] is not None and call["provider_data"]["turn_id"]
               and data["session"] == session and data["content"][0] == {"type": "text", "text": "Reading it."},
               "a call of CYFR's tool answers a tool_call named as the request names it, carrying Codex's request", data)
        expect(len(fakes(backends)) == 1, "the call stays held in the running program",
               [p["cmd"][:120] for p in backends.processes()])
        body = "line one of notes.txt " + secrets.token_hex(8)
        answered = {**ask, "messages": history + [
            {"role": "assistant", "content": data["content"]},
            {"role": "tool", "content": [{"type": "tool_result", "tool_call_id": call["id"], "name": "files", "content": body}]},
        ]}
        bridge.calls.clear()
        output, events = run_catalyst(rt, plane, wasm, "chat", answered, "the chat carrying the tool's result")
        answers.append((output, events))
        data = output["data"]
        sent = bridge.sent()
        expect(len([op for op, _ in bridge.calls if op == "open"]) == 1
               and sent == [{"id": call["provider_data"]["request_id"],
                             "result": {"contentItems": [{"type": "inputText", "text": body}], "success": True}}],
               "the next chat attaches to the running session and sends the call's answer alone", sent)
        expect(data["stop_reason"] == "end_turn" and data["content"] == [{"type": "text", "text": f"The file says: {body}"}],
               "Codex took CYFR's answer, which its reply quotes", data)
        expect(data["usage"]["input_tokens"] == 12 and identity(data["session"]) == identity(session),
               "the reply's one model call counts once, though Codex sent the thread's total twice", data)
        session = data["session"]
        ask = {**ask, "session": session}

        # ————— a pipe that fails after the answer interrupts the session —————
        output, events = run_catalyst(rt, plane, wasm, "chat", {**ask, "messages": history[:-1] + [
            {"role": "user", "content": "read notes.txt again"}]}, "a chat that calls the tool again")
        answers.append((output, events))
        again = output["data"]["content"][-1]
        expect(output["data"]["stop_reason"] == "tool_call", "Codex calls CYFR's tool again", output)
        bridge.calls.clear()
        bridge.fail_read_after_answer = True
        answered_again = {**ask, "messages": history + [
            {"role": "assistant", "content": output["data"]["content"]},
            {"role": "tool", "content": [{"type": "tool_result", "tool_call_id": again["id"], "name": "files", "content": body}]},
        ]}
        output, events = run_catalyst(rt, plane, wasm, "chat", answered_again, "a chat whose read after the answer fails")
        answers.append((output, events))
        expect(output["status"] == 502 and output["error"]["type"] == "provider_error"
               and "interrupted" in output["error"]["message"] and "next message" in output["error"]["message"],
               "a read the box could not answer after the answer answers provider_error, which the loop does not "
               "retry, saying the session was interrupted", output)
        expect(output["error"].get("session") == session,
               "the refusal carries the session with the total before the interrupted call, which the next "
               "message names as AQUA keeps it", output)
        expect([op for op, _ in bridge.calls if op == "close"] == ["close"] and bridge.methods() == ["answer"],
               "the session is closed, the answer sent once and nothing else", bridge.calls)
        eventually(lambda: not fakes(backends), "the interrupted session's program to end with it")
        bridge.calls.clear()
        resumed = {"model": "default", "session": output["error"]["session"],
                   "messages": [{"role": "user", "content": "what was my first message?"}]}
        output, events = run_catalyst(rt, plane, wasm, "chat", resumed, "the next message after the interruption")
        answers.append((output, events))
        sent = bridge.sent()
        resume = [line for line in sent if line.get("method") == "thread/resume"]
        expect(bridge.methods() == ["initialize", "initialized", "account/read", "thread/resume", "turn/start"]
               and resume[0]["params"]["threadId"] == thread
               and resume[0]["params"]["approvalPolicy"] == "never" and resume[0]["params"]["sandbox"] == "danger-full-access"
               and identity(output["data"]["session"]) == identity(session)
               and output["data"]["content"] == [{"type": "text", "text": "Your first message was: say hello"}],
               "the next message resumes the thread from the kept folder, and no answer is sent again", [sent, output])
        expect(output["data"]["usage"]["input_tokens"] == 24,
               "the run counts the interrupted run's model call with its own, from the total the last answer carried",
               output["data"]["usage"])
        session = output["data"]["session"]
        resumed = {**resumed, "session": session}

        # ————— resume after retirement —————
        eventually(retired,
                   "the idle session's program to be retired", timeout_s=IDLE_MS / 1000 + 30)
        bridge.calls.clear()
        output, events = run_catalyst(rt, plane, wasm, "chat", resumed, "a chat after the program retired")
        answers.append((output, events))
        expect("thread/resume" in bridge.methods() and "thread/start" not in bridge.methods()
               and output["data"]["content"] == [{"type": "text", "text": "Your first message was: say hello"}]
               and identity(output["data"]["session"]) == identity(session),
               "the program starts again and resumes the thread its kept folder holds", [bridge.methods(), output])
        resumed = {**resumed, "session": output["data"]["session"]}

        # ————— a refused sign-in —————
        output, events = run_catalyst(rt, plane, wasm, "chat", {**resumed, "messages": [
            {"role": "user", "content": "sign out"}]}, "a chat that removes Codex's sign-in")
        answers.append((output, events))
        eventually(retired,
                   "the signed-out program to be retired", timeout_s=IDLE_MS / 1000 + 30)
        bridge.calls.clear()
        output, events = run_catalyst(rt, plane, wasm, "chat", resumed, "a chat with no sign-in")
        answers.append((output, events))
        expect(output["status"] == 401 and output["error"]["type"] == "authentication"
               and "Programs page" in output["error"]["message"],
               "a program with no sign-in answers authentication, pointing at the Programs page", output)
        expect(bridge.methods() == ["initialize", "initialized", "account/read"]
               and [op for op, _ in bridge.calls if op == "close"] == ["close"],
               "nothing reached a thread, and the program was closed", bridge.calls)

        # ————— a refusal of the pipe —————
        bridge.refuse_next_open = "setup_required"
        output, events = run_catalyst(rt, plane, wasm, "chat", resumed, "a chat whose login entry was revoked")
        answers.append((output, events))
        expect(output["status"] == 403 and output["error"]["type"] == "secret_denied"
               and events[-1]["type"] == "error" and events[-1]["error"]["type"] == "secret_denied",
               "a pipe that answers setup_required answers the contract's secret_denied", [output, events[-1:]])

        text = json.dumps(answers)
        expect(not any(canary in text for canary in CANARIES),
               "nothing Codex wrote to its stderr or its folder, nor any command it ran, reached an answer or an event")
    finally:
        rt.down()
        backends.down()
        plane.stop()


if __name__ == "__main__":
    main()
