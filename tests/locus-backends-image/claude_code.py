#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The Claude Code catalyst drives a harness over its program's pipe, in a kept folder of the backends image.

Two services of the image under test, each as docker-compose.yml runs it:
locus-runtime runs the shipped catalyst
(seed/components/catalysts/local/claude-code/0.1.0/catalyst.wasm) under a
scripted control plane (tests/locus-runtime-image/control_plane.py), and
locus-backends runs the `claude` program, driven by requests signed as
CYFR signs them (harness.py). The control plane plays CYFR's host for the
catalyst's pipe as `Opus.Host.Pipe` does: each `pipe_open` names the
`claude` need and is opened on the program in one login entry's kept
folder under a key of the catalyst's own; `pipe_send`, `pipe_recv` and
`pipe_close` go to the session it opened. The program's command runs
fake-claude.mjs, a stand-in for Claude Code speaking the event shapes the
harness was proved to speak, which starts the image's `cyfr-stub` for
CYFR's tools as the harness starts an MCP server.

- `describe` starts the harness in a session of its own, reads the model
  listing its `initialize` answers into the `model` and `effort` options
  beside the `permission_mode` and `tools` options the harness cannot list,
  and closes that session: no process of it is left.
- A chat round trip: the first message opens a new session (`--session-id`)
  with the request's options as flags, carries the system prompt on
  `initialize`, sets the request's tools on the stub; the harness's own
  `Bash` ask is allowed and shown as a `tool_call.start`/`end` pair by name;
  the reply streams as `text.delta` and answers `end_turn` with usage and
  the session.
- Changed options: a chat on the running session with other tools and
  another model closes its program and starts it again resuming the same
  session with the new flags, which the harness's reply names.
- A held ask: a message that makes the harness call one of CYFR's tools
  answers a `tool_call` named as the request named the tool, carrying the
  ask's id, and leaves the ask pending in the running session; the next
  chat, carrying the `tool_result`, attaches to that session and sends only
  the ask's allow, with the result in its input, and the harness's call
  through `cyfr-stub` returns that result, which its reply quotes.
- Resume after retirement: once the session's program is retired idle, the
  next chat naming the session starts the harness again with `--resume`,
  which finds the session in the kept folder.
- A pipe refusal answers the contract's refusal type; and nothing the
  harness writes to its stderr or its folder reaches any answer or event.

Prerequisites: harness.py's, the runtime image suites' (the control plane
on the default bridge's gateway), and the built catalyst. Usage:
tests/locus-backends-image/claude_code.py IMAGE
"""

import hashlib
import json
import os
import secrets
import sys
import threading
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.append(os.path.join(HERE, "..", "locus-runtime-image"))

from harness import ROOT, Stack, eventually, expect, owner_of, require_docker  # noqa: E402
from control_plane import ZERO_AUTHORITY, ControlPlane  # noqa: E402
import stack as runtime  # noqa: E402

CATALYST = os.path.join(ROOT, "seed", "components", "catalysts", "local", "claude-code", "0.1.0")
REF = "catalyst:local.claude-code:0.1.0"
NEED = "claude"
OWNER = owner_of("claude-code")
HOME = "vlt_claude-code"
FAKE = "fake-claude.mjs"
PROGRAM = {"name": "claude", "command": f"node /probe/{FAKE}", "env": {}, "home": "kept"}
# Short, so the retirement case waits little; long enough that a chat
# following another at once finds its session running.
IDLE_MS = 15_000
RUN_TIMEOUT_MS = 120_000
ATHANOR = "ath_claude_code"
CANARIES = ("FAKE-STDERR-CANARY", "FAKE-FOLDER-CANARY")
FILES = {
    "name": "files",
    "description": "Read the athanor's files",
    "parameters": {"type": "object", "properties": {"action": {"type": "string"}, "path": {"type": "string"}},
                   "required": ["action", "path"]},
}
SYSTEM = "You are a crew member of this athanor."


class Bridge:
    """CYFR's host for the catalyst's pipe, as `Opus.Host.Pipe` is: the need
    granted is `claude`, bound to one login entry's kept home; a key is the
    catalyst's own, hashed with its node and need; a session is answered only
    to the attempt that opened it."""

    def __init__(self, controller):
        self.c = controller
        self.lock = threading.Lock()
        self.sessions = {}
        self.calls = []
        self.refuse_next_open = None

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
            return self.guest_error(kind, "The login entry bound to claude is revoked.")
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
        status, answer = self.c.send(OWNER, args["session"], args["lines"])
        if status == 200 and answer.get("status") == "running":
            return {"ok": True}
        return self.guest_error("ended", "The program has ended.")

    def recv(self, args, _caller, entry):
        if not self.held(entry, args["session"]):
            return {"error": "denied"}
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


def text_of(events):
    return "".join(e["text"] for e in events if e.get("type") == "text.delta")


def fakes(backends):
    """The harness's processes: node running the fake, not the shell that started it."""
    return [p for p in backends.processes() if p["cmd"].startswith(f"node /probe/{FAKE}")]


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: claude_code.py IMAGE")
    image = sys.argv[1]
    require_docker()
    with open(os.path.join(CATALYST, "catalyst.wasm"), "rb") as handle:
        wasm = handle.read()
    with open(os.path.join(CATALYST, "cyfr-manifest.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)
    expect(manifest["needs"] == {NEED: {**manifest["needs"][NEED], "type": "login", "program": "claude"}}
           and "model/chat@1" in manifest["contracts"],
           "the catalyst declares model/chat@1 and one need, a login for the program claude", manifest["needs"])

    backends = Stack("locus-backends-claude-code", image)
    plane = ControlPlane(secrets.token_bytes(32), runtime.SERVICE).serve()
    rt = runtime.Stack("cyfr-locus-runtime-claude-code", image, plane)
    answers = []
    try:
        backends.up()
        c = backends.controller()
        expect(c.hello()[0] == 200, "the backends service is greeted")
        status, synced, _ = c.sync(OWNER, [PROGRAM], idle_ms=IDLE_MS)
        expect(status == 200, "an owner of the claude program, kept, is synced", synced)
        bridge = Bridge(c)
        bridge.install(plane)
        rt.up()

        # ————— describe: the harness's listing —————
        described, events = run_catalyst(rt, plane, wasm, "describe", {"model": "fake-opus"}, "describe")
        answers.append((described, events))
        options = {o["name"]: o for o in described["data"]["options"]}
        expect(described["status"] == 200 and described["data"]["streaming"] is True
               and described["data"]["provider_tools"] == [] and described["data"]["context_window"] > 0,
               "describe answers the contract, streaming, with no provider tools and the model's window", described)
        expect(options["model"] == {"name": "model", "kind": "enum", "values": ["default", "fake-opus", "fake-haiku"]}
               and options["effort"]["values"] == ["low", "medium", "high", "max"],
               "the model and effort options are the harness's own listing", options)
        expect(options["permission_mode"]["values"] == ["default", "acceptEdits", "plan"]
               and options["tools"]["kind"] == "string",
               "the permission mode and the harness's own tools stand beside them", options)
        expect([op for op, _ in bridge.calls] == ["open", "send", "close"], "describe closes its own session",
               bridge.calls)
        eventually(lambda: not fakes(backends), "the listing's harness to end with its session")
        modelled, _ = run_catalyst(rt, plane, wasm, "models", {}, "models")
        expect(modelled == {"status": 200, "data": {"models": [
            {"id": "default", "name": "Default (recommended)"}, {"id": "fake-opus", "name": "Fake Opus"},
            {"id": "fake-haiku", "name": "Fake Haiku"}]}},
            "models answers the same listing", modelled)

        # ————— a chat round trip, with options from describe —————
        bridge.calls.clear()
        hello = {"model": "claude-fake-opus-1", "system": SYSTEM, "tools": [FILES],
                 "messages": [{"role": "user", "content": "say hello"}],
                 "options": {"model": "fake-haiku", "effort": "high", "tools": "Bash,Read"}}
        output, events = run_catalyst(rt, plane, wasm, "chat", hello, "a first chat")
        answers.append((output, events))
        data = output["data"]
        session = data["session"]
        harness_id = session.split(".")[0]
        argv = bridge.calls[0][1]["argv"]
        expect(argv[argv.index("--session-id") + 1] == harness_id and "--resume" not in argv
               and argv[argv.index("--model") + 1] == "fake-haiku" and argv[argv.index("--effort") + 1] == "high"
               and argv[argv.index("--tools") + 1] == "Bash,Read",
               "a first chat opens a new session under the id it answers, with the request's options as flags", argv)
        expect(output["status"] == 200 and data["stop_reason"] == "end_turn" and data["model"] == "fake-haiku"
               and data["content"] == [{"type": "text", "text": f'Hello from the fake harness: session {harness_id}, '
                                        'model fake-haiku, effort high, tools Bash,Read, Bash allowed, '
                                        f'prompt "{SYSTEM}".'}],
               "the harness answers end_turn, its own Bash allowed and the system prompt appended to its own", output)
        expect(data["usage"] == {"input_tokens": 12, "output_tokens": len(data["content"][0]["text"]),
                                 "cache_read_tokens": 5, "cache_write_tokens": 2},
               "usage is the turn's result's", data["usage"])
        expect(text_of(events) == data["content"][0]["text"], "the reply streamed as text deltas", events)
        shown = [e for e in events if e["type"].startswith("tool_call.")]
        expect(shown == [{"type": "tool_call.start", "index": 0, "id": "toolu_fake_1", "name": "Bash"},
                         {"type": "tool_call.end", "index": 0}],
               "the harness's own ask is shown as a start and end pair, by name only", shown)
        expect(events[-1] == {"type": "stop", "stop_reason": "end_turn"}, "the stream ends with its stop", events[-1])

        # ————— changed options: the session restarts with them —————
        bridge.calls.clear()
        changed = {"model": "fake-opus", "system": SYSTEM, "session": session, "tools": [FILES],
                   "messages": [{"role": "user", "content": "say hello again"}], "options": {"tools": ""}}
        output, events = run_catalyst(rt, plane, wasm, "chat", changed, "a chat with changed tools and model")
        answers.append((output, events))
        data = output["data"]
        ops = [op for op, _ in bridge.calls if op in ("open", "close")]
        argv = [args for op, args in bridge.calls if op == "open"][-1]["argv"]
        expect(ops == ["open", "close", "open"] and argv[argv.index("--resume") + 1] == harness_id
               and argv[argv.index("--model") + 1] == "fake-opus" and argv[argv.index("--tools") + 1] == ""
               and "--effort" not in argv,
               "changed options close the running harness and start it again resuming its session with the new flags",
               [ops, argv])
        expect(data["content"][0]["text"].startswith(f"Hello from the fake harness: session {harness_id}, "
                                                     "model fake-opus, effort unset, tools , ")
               and data["session"].split(".")[0] == harness_id and data["session"] != session,
               "the harness ran the turn with the new tools and model in the same session", data)
        session = data["session"]

        # ————— a held ask, answered by the next chat —————
        bridge.calls.clear()
        history = [{"role": "user", "content": "say hello again"}, {"role": "assistant", "content": data["content"]},
                   {"role": "user", "content": "read notes.txt"}]
        ask = {"model": "fake-opus", "session": session, "tools": [FILES], "messages": history, "options": {"tools": ""}}
        output, events = run_catalyst(rt, plane, wasm, "chat", ask, "a chat that calls a tool of CYFR's")
        answers.append((output, events))
        data = output["data"]
        call = data["content"][-1]
        expect(bridge.calls[0][0] == "open" and data["stop_reason"] == "tool_call" and call["type"] == "tool_call"
               and call["name"] == "files" and call["arguments"] == {"action": "read", "path": "notes.txt"}
               and call["provider_data"]["request_id"] and data["session"] == session,
               "a call of CYFR's tool answers a tool_call named as the request names it, carrying the ask", data)
        expect(len(fakes(backends)) == 1, "the ask stays pending in the running harness",
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
        opened = [args for op, args in bridge.calls if op == "open"]
        sent = [json.loads(line) for op, args in bridge.calls if op == "send" for line in args["lines"]]
        allow = [line for line in sent if line.get("type") == "control_response"]
        expect(len(opened) == 1 and sent == allow,
               "the next chat attaches to the running session and sends the ask's answer alone: no initialize, no "
               "new tools", sent)
        expect(len(allow) == 1 and allow[0]["response"]["request_id"] == call["provider_data"]["request_id"]
               and allow[0]["response"]["response"] == {"behavior": "allow", "updatedInput": {
                   "action": "read", "path": "notes.txt", "result": body}},
               "the ask is allowed with CYFR's result in its input", allow)
        expect(data["stop_reason"] == "end_turn" and data["content"] == [{"type": "text", "text": f"The file says: {body}"}],
               "the harness's call through cyfr-stub returned the result, which its reply quotes", data)

        # ————— resume after retirement —————
        eventually(lambda: c.program(OWNER, PROGRAM["name"])["sessions"] == 0 and not fakes(backends),
                   "the idle session's program to be retired", timeout_s=IDLE_MS / 1000 + 30)
        bridge.calls.clear()
        later = {"model": "fake-opus", "session": session, "options": {"tools": ""},
                 "messages": [{"role": "user", "content": "what was my first message?"}]}
        output, events = run_catalyst(rt, plane, wasm, "chat", later, "a chat after the program retired")
        answers.append((output, events))
        argv = bridge.calls[0][1]["argv"]
        expect(argv[argv.index("--resume") + 1] == harness_id and "--session-id" not in argv,
               "the next chat starts the harness again resuming its session", argv)
        expect(output["data"]["content"] == [{"type": "text", "text": "Your first message was: say hello"}]
               and output["data"]["session"] == session,
               "the resumed harness finds the session in its kept folder", output)

        # ————— a refusal of the pipe —————
        bridge.refuse_next_open = "setup_required"
        output, events = run_catalyst(rt, plane, wasm, "chat", later, "a chat whose login entry was revoked")
        answers.append((output, events))
        expect(output["status"] == 403 and output["error"]["type"] == "secret_denied"
               and events[-1]["type"] == "error" and events[-1]["error"]["type"] == "secret_denied",
               "a pipe that answers setup_required answers the contract's secret_denied", [output, events[-1:]])

        text = json.dumps(answers)
        expect(not any(canary in text for canary in CANARIES),
               "nothing the harness wrote to its stderr or its folder reached an answer or an event")
    finally:
        rt.down()
        backends.down()
        plane.stop()


if __name__ == "__main__":
    main()
