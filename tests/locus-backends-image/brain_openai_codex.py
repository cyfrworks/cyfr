#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""OpenAI Codex's brain driver runs beside its harness in a kept folder of the backends image.

Driven only by requests signed as CYFR signs them (harness.py), as the
holder (`Opus.Brain`) drives it: an owner whose one program is a brain row,
`cyfr-codex` followed by the harness's command, kept. The harness is
fake-openai-codex.mjs, a stand-in for Codex's app-server speaking the lines
the app-server was proved to speak, which keeps its threads in the folder
as Codex does. Every line the driver writes is read against the wire's
vectors (tests/fixtures/brain_wire.json): its message is one of the events,
with exactly its members.

- A run session's first line is the driver's `hello`, naming the wire's
  version and a boot of its own; `models` with no harness running starts an
  app-server for the listing alone and leaves no process of it.
- A start runs the app-server and starts a thread with the start's tools as
  its dynamic tools, its system prompt as developer instructions, its model,
  and Codex's own sandbox and asking off, and `started` names the new
  thread; a work writes nothing; a post is a turn, streamed as `text` and
  said whole, the start's effort its own, its own command shown by name
  only and its patch approval allowed, its usage the thread's total, and
  its `idle` naming the post, every event naming the post's work.
- A read-only start starts and resumes the thread in Codex's read-only
  sandbox, asking nothing, and every approval, permission and elicitation
  is declined; one with no read_only runs as before, each allowed: both
  seen as the thread's whole params and the driver's whole answers.
- A post while the turn works is added to it (`turn/steer`), and the turn's
  `idle` names both posts.
- An ask of CYFR's tool is passed up with its arguments, held, and answered
  by an `answer`, which reaches Codex as the call's result.
- A new process, started resuming the thread, holds it, and `held` names
  the post its rollout holds and not one it never had.
- A resume of a thread the folder does not hold is `gone`, and a fresh
  start runs in the same driver.
- `forget` removes that thread's rollout and the shell snapshot Codex
  leaves, and leaves another thread's and the sign-in; the running thread
  is not forgotten.
- Every command line the vectors refuse (their `refuse` lines from the
  holder) ends the driver with no line written.
- Nothing of the harness's standard error, its folder, its sign-in or its
  account reaches a line of the driver's.
- On a terminal, the driver runs the harness's command unchanged: the
  harness's own words, not the wire, are what the terminal shows.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/brain_openai_codex.py IMAGE
"""

import json
import os
import sys
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import ROOT, Stack, eventually, expect, owner_of, probe, require_docker  # noqa: E402

with open(os.path.join(ROOT, "tests", "fixtures", "brain_wire.json"), encoding="utf-8") as _vectors:
    VECTORS = json.load(_vectors)
EVENTS = VECTORS["events"]

OWNER = owner_of("brain-openai-codex")
HOME = "mcp_brain-openai-codex"
FAKE = "fake-openai-codex.mjs"
PROGRAM = {"name": "brain", "command": f"cyfr-codex node /probe/{FAKE}", "env": {}, "home": "kept"}
CANARIES = ("FAKE-STDERR-CANARY", "FAKE-FOLDER-CANARY", "FAKE-ACCOUNT-CANARY", "auth.json")
FILES = {
    "name": "files",
    "description": "Read the athanor's files",
    "parameters": {"type": "object", "properties": {"action": {"type": "string"}, "path": {"type": "string"}},
                   "required": ["action", "path"]},
}
SYSTEM = "You are a crew member of this athanor."
WORK = "trn_brain_1"
TIMEOUT_S = 60


class Driver:
    """One run session of the driver, spoken to as the holder speaks to it."""

    def __init__(self, c, key):
        self.c = c
        status, opened = c.open(OWNER, PROGRAM["name"], key=key, argv=[], home_id=HOME)
        expect(status == 200 and opened["resumed"] is False, "a run session of the brain row opens fresh", opened)
        self.session = opened["session"]
        self.after = 0
        self.pending = []
        self.lines = []

    def send(self, command):
        status, answer = self.c.send(OWNER, self.session, [json.dumps(command)])
        expect(status == 200 and answer["status"] == "running", f"the driver takes {command['t']}", answer)

    def event(self):
        while not self.pending:
            lines, self.after, running = self.c.lines_until(OWNER, self.session, lambda got: got, self.after,
                                                            timeout_s=TIMEOUT_S)
            expect(running or lines, "the driver still runs", self.session)
            for line in lines:
                self.lines.append(line)
                event = json.loads(line)
                spec = EVENTS.get(event.get("t"))
                expect(spec is not None and set(spec["fields"]) <= set(event)
                       and set(event) <= set(spec["fields"]) | set(spec["optional"]),
                       "every line the driver writes is an event of the wire, with exactly its members", line)
                self.pending.append(event)
        return self.pending.pop(0)

    def expect(self, t, what):
        event = self.event()
        expect(event["t"] == t, what, event)
        return event

    def until(self, t):
        got = []
        while True:
            got.append(self.event())
            if got[-1]["t"] == t:
                return got

    def close(self):
        self.c.close(OWNER, self.session)


def harnesses(stack):
    return [p for p in stack.processes() if p["cmd"].startswith(f"node /probe/{FAKE}")]


def home_has(c, path):
    """Whether the brain row's folder holds `path` (a shell pattern), as a probe program run in the same
    kept home, under the same uid, finds it."""
    client = c.mcp(OWNER, "probe", key="folder", home_id=HOME)
    status, answer = client.call("run", {"argv": ["/bin/sh", "-c", f'for f in "$HOME"/{path}; do test -e "$f" && echo present && exit; done; echo absent']})
    result = (answer or {}).get("result") or {}
    expect(status == 200 and not result.get("isError") and "content" in result, f"the probe of {path} runs", answer)
    word = json.loads(result["content"][0]["text"])["stdout"].strip()
    expect(word in ("present", "absent"), f"the probe of {path} answers", word)
    return word == "present"


def rollout(thread):
    return f".codex/sessions/2026/11/18/rollout-*-{thread}.jsonl"


def snapshot(thread):
    return f".codex/shell_snapshots/{thread}.*"


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: brain_openai_codex.py IMAGE")
    require_docker()
    stack = Stack("locus-backends-brain-openai-codex", sys.argv[1])
    seen = []
    try:
        stack.up()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the backends service is greeted")
        status, synced, _ = c.sync(OWNER, [PROGRAM, probe(home="kept")])
        expect(status == 200, "an owner of the brain row, kept, is synced", synced)

        # ————— hello, and a listing with no harness running —————
        d = Driver(c, "brain-one")
        hello = d.expect("hello", "the driver's first line is its hello")
        expect(hello["v"] == VECTORS["version"] and hello["driver"] == "cyfr-codex" and len(hello["boot"]) == 32,
               "hello names the wire's version, the driver and a boot of its own", hello)
        d.send({"t": "models", "id": "mdl_1"})
        listed = d.expect("models", "models with no harness running is listed from an app-server of its own")
        expect([m["id"] for m in listed["models"]] == ["fake-sol", "fake-mini"]
               and listed["efforts"] == ["low", "high", "medium", "xhigh"],
               "the listing is Codex's, with the efforts any model takes", listed)
        eventually(lambda: not harnesses(stack), "the listing's app-server to end")

        # ————— a start, a work and a post —————
        d.send({"t": "start", "gen": 4, "config": {"model": "fake-mini", "effort": "xhigh"}, "system": SYSTEM,
                "tools": [FILES]})
        started = d.expect("started", "a fresh start answers started")
        thread = started["session"]
        expect(started["fresh"] is True and started["held"] == [] and len(thread) == 36, "a new thread holding nothing",
               started)
        d.send({"t": "work", "id": "stp_work_1", "work": WORK, "tools": [FILES]})
        expect(d.expect("accepted", "the work is accepted, writing nothing")["id"] == "stp_work_1", "by the work's id")
        d.send({"t": "post", "id": "stp_post_1", "work": WORK, "content": [{"type": "text", "text": "say hello"}]})
        turn = d.until("idle")
        expect(turn[0] == {"t": "accepted", "id": "stp_post_1"}, "the post is accepted first, once Codex took it", turn[0])
        streamed = "".join(e["delta"] for e in turn if e["t"] == "text")
        said = [e["text"] for e in turn if e["t"] == "said"]
        expect(said and streamed == said[0]
               and f"thread {thread}, model fake-mini, effort xhigh, tools files, policy never/danger-full-access, patch accept" in said[0]
               and f'instructions "{SYSTEM}"' in said[0],
               "the reply streams and is said whole; the thread runs the start's tools, model and prompt in the box's "
               "policy, the effort per turn, and its patch approval is allowed", said)
        expect([(e["name"], e["phase"]) for e in turn if e["t"] == "own"]
               == [("commandExecution", "start"), ("commandExecution", "end")],
               "Codex's own command is shown by name only", turn)
        usage = [e for e in turn if e["t"] == "usage"]
        expect(len(usage) == 2 and all(u["total"] == thread and u["accounting"] == "complete" for u in usage)
               and usage[-1]["models"][0]["model"] == "fake-mini"
               and usage[-1]["models"][0]["counts"]["input_tokens"] == 12
               and usage[-1]["models"][0]["counts"]["cache_read_tokens"] == 5
               and usage[-1]["models"][0]["counts"]["cache_write_tokens"] == 2,
               "each total Codex sends is the thread's, under the thread's model, its counts by the wire's names", usage)
        expect(turn[-1]["answered"] == ["stp_post_1"] and turn[-1]["stop"] == "end_turn",
               "idle names the post Codex named in the turn", turn[-1])
        expect(all(e.get("work") == WORK and e.get("gen") == 4 for e in turn[1:]),
               "every event of the turn names the post's work and the start's gen", turn)

        # ————— a post while the turn works is added to it —————
        d.send({"t": "post", "id": "stp_post_2", "work": WORK, "content": [{"type": "text", "text": "slow one"}]})
        expect(d.expect("accepted", "the slow post is accepted")["id"] == "stp_post_2", "by its id")
        expect(d.expect("text", "its turn streams a first part")["delta"] == "Starting", "the first part")
        d.send({"t": "post", "id": "stp_post_3", "work": WORK, "content": [{"type": "text", "text": "the steer"}]})
        steered = d.until("idle")
        expect(steered[0] == {"t": "accepted", "id": "stp_post_3"}
               and "Read the steer: the steer" in [e["text"] for e in steered if e["t"] == "said"]
               and steered[-1]["answered"] == ["stp_post_2", "stp_post_3"],
               "the post is steered into the turn, and the turn's idle names both posts", steered)

        # ————— an ask of CYFR's tool, answered by its request's id —————
        d.send({"t": "post", "id": "stp_post_4", "work": WORK, "content": [{"type": "text", "text": "read notes"}]})
        asked = [e for e in d.until("ask") if e["t"] == "ask"][0]
        expect(asked["name"] == "files" and asked["arguments"] == {"action": "read", "path": "notes.txt"}
               and asked["ask"].startswith("call_"),
               "an ask names CYFR's tool as CYFR names it, Codex's call id and its arguments", asked)
        d.send({"t": "answer", "id": "stp_answer_1", "ask": asked["ask"], "content": "three lines", "is_error": False})
        answered = d.until("idle")
        said = [e["text"] for e in answered if e["t"] == "said"]
        expect(answered[0] == {"t": "accepted", "id": "stp_answer_1"} and "The file says: three lines" in said,
               "the answer reaches Codex as the call's result", answered)
        seen += d.lines
        d.close()
        eventually(lambda: not harnesses(stack), "the closed session's app-server to end")

        # ————— a new process resumes the thread —————
        d = Driver(c, "brain-two")
        d.expect("hello", "a new process says hello")
        d.send({"t": "start", "gen": 4, "session": thread, "config": {"model": "fake-sol"}, "system": SYSTEM,
                "pending": ["stp_post_1", "stp_never"]})
        resumed = d.expect("started", "a resume answers started")
        expect(resumed == {"t": "started", "session": thread, "fresh": False, "held": ["stp_post_1"]},
               "the resumed thread is the same, and held names the post its rollout holds", resumed)
        d.send({"t": "work", "id": "stp_work_2", "work": "trn_brain_2", "tools": []})
        d.expect("accepted", "the resumed thread's work is accepted")
        d.send({"t": "post", "id": "stp_post_5", "work": "trn_brain_2", "content": [{"type": "text", "text": "say hello"}]})
        said = [e["text"] for e in d.until("idle") if e["t"] == "said"]
        expect(said and f"thread {thread}, model fake-sol" in said[0] and "tools files" in said[0],
               "the new process runs the thread with the new model and the tools it started with", said)

        # ————— the two modes, each a fresh start of its own, read-only resumed too —————
        seen += d.lines
        d.close()
        tool = {"type": "function", "name": FILES["name"], "description": FILES["description"], "inputSchema": FILES["parameters"]}
        network = {"network": {"enabled": True}}
        denial = {"denied": {"rejection": "This crew member is read-only."}}
        results = {
            "danger-full-access": [{"decision": "accept"}, {"decision": "accept"}, {"decision": "approved"}, {"decision": "approved"},
                                   {"permissions": network, "scope": "turn"}, {"action": "accept", "content": None}],
            "read-only": [{"decision": "decline"}, {"decision": "decline"}, {"decision": denial}, {"decision": denial},
                          {"permissions": {}, "scope": "turn"}, {"action": "decline"}],
        }
        read_only_thread = None
        for key, config, sandbox in (
            ("brain-auto", {"model": "fake-sol"}, "danger-full-access"),
            ("brain-read-only", {"model": "fake-sol", "read_only": True}, "read-only"),
            ("brain-read-only-resumed", {"model": "fake-sol", "read_only": True}, "read-only"),
        ):
            m = Driver(c, key)
            m.expect("hello", f"{key}: the driver says hello")
            start = {"t": "start", "gen": 7, "config": config, "system": SYSTEM, "tools": [FILES]}
            if key == "brain-read-only-resumed":
                start["session"] = read_only_thread
            m.send(start)
            started_modes = m.expect("started", f"{key}: the start answers started")
            if key == "brain-read-only":
                read_only_thread = started_modes["session"]
            m.send({"t": "work", "id": "stp_work_modes", "work": "trn_brain_modes", "tools": []})
            m.expect("accepted", f"{key}: its work is accepted")
            m.send({"t": "post", "id": "stp_post_modes", "work": "trn_brain_modes",
                    "content": [{"type": "text", "text": "modes"}]})
            turn = m.until("idle")
            expect(not any(e["t"] == "ask" for e in turn), f"{key}: Codex's approvals are never asked of CYFR", turn)
            got = json.loads([e["text"] for e in turn if e["t"] == "said"][0])
            wanted = ({"threadId": read_only_thread, "approvalPolicy": "never", "sandbox": sandbox, "excludeTurns": True,
                       "developerInstructions": SYSTEM, "model": "fake-sol"}
                      if key == "brain-read-only-resumed" else
                      {"approvalPolicy": "never", "sandbox": sandbox, "dynamicTools": [tool], "developerInstructions": SYSTEM,
                       "model": "fake-sol"})
            expect(got["params"] == wanted, f"{key}: the thread runs with exactly the start's params", got["params"])
            expect(got["answers"] == [{"id": i, "result": r} for i, r in enumerate(results[sandbox])],
                   f"{key}: the driver answers every approval, permission and elicitation exactly", got["answers"])
            seen += m.lines
            m.close()

        # ————— a thread the folder does not hold —————
        d = Driver(c, "brain-three")
        d.expect("hello", "another process says hello")
        d.send({"t": "start", "gen": 5, "session": str(uuid.uuid4()), "config": {}})
        d.expect("gone", "a resume of a thread the folder does not hold is gone")
        d.send({"t": "start", "gen": 6, "config": {}, "tools": [FILES]})
        other = d.expect("started", "a fresh start runs after gone")["session"]
        d.send({"t": "work", "id": "stp_work_3", "work": "trn_brain_3", "tools": []})
        d.expect("accepted", "its work is accepted")
        d.send({"t": "post", "id": "stp_post_6", "work": "trn_brain_3", "content": [{"type": "text", "text": "say hello"}]})
        d.until("idle")

        # ————— forget —————
        expect(home_has(c, rollout(thread)) and home_has(c, snapshot(thread)) and home_has(c, rollout(other))
               and home_has(c, ".codex/auth.json"),
               "both threads' rollouts, the first's snapshot and the sign-in are in the folder (a positive control)")
        d.send({"t": "forget", "id": "obx_1", "session": thread})
        expect(d.expect("forgot", "forget is answered") == {"t": "forgot", "id": "obx_1", "session": thread},
               "by its id and the thread")
        expect(not home_has(c, rollout(thread)) and not home_has(c, snapshot(thread)),
               "the forgotten thread's rollout and its snapshot are gone from the folder")
        expect(home_has(c, rollout(other)) and home_has(c, snapshot(other)) and home_has(c, ".codex/auth.json"),
               "another thread and the sign-in stay")
        d.send({"t": "forget", "id": "obx_2", "session": other})
        expect(d.expect("refused", "the running thread is not forgotten")["id"] == "obx_2", "by its id")
        seen += d.lines
        d.close()

        # ————— a command the wire refuses ends the driver —————
        for i, refused in enumerate(r for r in VECTORS["refuse"] if r["from"] == "holder"):
            r = Driver(c, f"brain-refused-{i}")
            r.expect("hello", "a driver to refuse a command")
            status, answer = c.send(OWNER, r.session, [refused["line"]])
            expect(status == 200, f"the line is written: {refused['name']}", answer)
            lines, _after, running = c.lines_until(OWNER, r.session, lambda got: got, r.after, timeout_s=TIMEOUT_S)
            expect(not running and lines == [], f"the driver ends on it and writes nothing: {refused['name']}", lines)
            r.close()

        # ————— nothing of stderr, the folder, the sign-in or the account —————
        expect(home_has(c, ".codex/auth.json") and home_has(c, snapshot(other)),
               "the harness kept its folder's canaries, in its sign-in and its snapshot (a positive control)")
        for canary in CANARIES:
            expect(not any(canary in line for line in seen), f"no line of the driver's carries {canary}")

        # ————— on a terminal the harness runs unchanged —————
        status, opened = c.open(OWNER, PROGRAM["name"], key="brain-terminal", mode="terminal", argv=[], home_id=HOME,
                                rows=24, cols=80)
        expect(status == 200, "a terminal of the brain row opens", opened)
        read, _after, _running = c.output_until(OWNER, opened["session"], lambda got: b"not app-server" in got)
        expect(b"not app-server" in read and b'"t":"hello"' not in read,
               "the terminal shows the harness's own words, not the wire: it ran unchanged", read[-400:])
        print("PASS: OpenAI Codex's brain driver runs beside its harness in a kept folder")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
