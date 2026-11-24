#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Claude Code's brain driver runs beside its harness in a kept folder of the backends image.

Driven only by requests signed as CYFR signs them (harness.py), as the
holder (`Opus.Brain`) drives it: an owner whose one program is a brain row,
`cyfr-claude-code` followed by the harness's command, kept. The harness is
fake-claude.mjs, a stand-in for Claude Code speaking the event shapes the
harness was proved to speak, which starts the image's `cyfr-stub` for
CYFR's tools as the harness starts an MCP server. Every line the driver
writes is read against the wire's vectors (tests/fixtures/brain_wire.json):
its message is one of the events, with exactly its members.

- A run session's first line is the driver's `hello`, naming the wire's
  version and a boot of its own; `models` with no harness running starts one
  for the listing alone and leaves no process of it, and lists the one
  access the driver honours, Default mode, and each model with its own
  efforts.
- A start naming Default mode, or no access, runs the harness in its default
  permission mode, its own tools allowed, seen as the harness's whole command
  line and the driver's whole answers. A start naming an access the driver
  does not list ends the driver before anything runs, with no line written.
- A start runs the harness with the start's configuration as its flags,
  and `started` names the new session; a work sets CYFR's tools on the stub;
  a post is a turn, streamed as `text` and said whole, its usage each
  model's, a side request's included and the main requests' counted once,
  and its `idle` naming the post, every event naming the post's work.
- An ask of CYFR's tool is passed up with its arguments, held, and answered
  by an `answer`, which reaches the harness through `cyfr-stub` as the
  tool's result.
- The MCP servers the person set up in the program itself (its folder's
  `.claude.json`) stay beside CYFR's: their tools are listed beside CYFR's,
  a call of one runs in their server with the model's own input and is
  shown as the program's own tool, never asked of CYFR; one named `cyfr`
  keeps its name, and CYFR's server takes another.
- A new process, started resuming the session, holds it: its reply names
  the same session and the new flags; and `held` names the post its
  transcript holds and not one it never had.
- A resume of a session the folder does not hold is `gone`, and a fresh
  start runs in the same driver.
- `forget` removes that session's transcript, and leaves another session's
  and the sign-in.
- Every command line the vectors refuse (their `refuse` lines from the
  holder) ends the driver with no line written.
- Nothing of the harness's standard error, its folder or its sign-in reaches
  a line of the driver's.
- On a terminal, the driver runs the harness's command unchanged: the
  harness's own words, not the wire, are what the terminal shows.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/brain_claude_code.py IMAGE
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

OWNER = owner_of("brain-claude-code")
HOME = "mcp_brain-claude-code"
FAKE = "fake-claude.mjs"
PROGRAM = {"name": "brain", "command": f"cyfr-claude-code node /probe/{FAKE}", "env": {}, "home": "kept"}
CANARIES = ("FAKE-STDERR-CANARY", "FAKE-FOLDER-CANARY", "FAKE-SIGNIN-CANARY")
FILES = {
    "name": "files",
    "description": "Read the athanor's files",
    "parameters": {"type": "object", "properties": {"action": {"type": "string"}, "path": {"type": "string"}},
                   "required": ["action", "path"]},
}
SYSTEM = "You are a crew member of this athanor."
WORK = "trn_brain_1"
LISTED = [("default", ["low", "medium", "high"]), ("fake-opus", ["low", "medium", "high", "max"]), ("fake-haiku", [])]
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
    """Whether the brain row's folder holds `path`, as a probe program run in the same kept home, under
    the same uid, finds it: no other uid, root's in the container among them, reads inside a home."""
    client = c.mcp(OWNER, "probe", key="folder", home_id=HOME)
    status, answer = client.call("run", {"argv": ["/bin/sh", "-c", f'test -e "$HOME/{path}" && echo present || echo absent']})
    result = (answer or {}).get("result") or {}
    expect(status == 200 and not result.get("isError") and "content" in result, f"the probe of {path} runs", answer)
    word = json.loads(result["content"][0]["text"])["stdout"].strip()
    expect(word in ("present", "absent"), f"the probe of {path} answers", word)
    return word == "present"


# The person's own servers, in the folder's `.claude.json` as Claude Code
# keeps them: the probe program, once under a name of its own and once under
# CYFR's server's name.
THEIRS = {"mcpServers": {name: {"type": "stdio", "command": "node", "args": ["/probe/probe-backend.mjs"],
                                "env": {"THEIR_SERVER": f"their {name}"}} for name in ("mine", "cyfr")}}


def plant(c, path, text):
    """Writes `text` to `path` in the brain row's folder, as the person would in the program's own terminal."""
    client = c.mcp(OWNER, "probe", key="plant", home_id=HOME)
    status, answer = client.call("run", {"argv": ["/bin/sh", "-c", 'printf %s "$1" > "$HOME/$2"', "sh", text, path]})
    result = (answer or {}).get("result") or {}
    expect(status == 200 and not result.get("isError") and json.loads(result["content"][0]["text"])["status"] == 0,
           f"{path} is written in the folder", answer)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: brain_claude_code.py IMAGE")
    require_docker()
    stack = Stack("locus-backends-brain-claude-code", sys.argv[1])
    seen = []
    try:
        stack.up()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the backends service is greeted")
        status, synced, _ = c.sync(OWNER, [PROGRAM, probe(home="kept")])
        expect(status == 200, "an owner of the brain row, kept, is synced", synced)
        plant(c, ".claude.json", json.dumps(THEIRS))

        # ————— hello, and a listing with no harness running —————
        d = Driver(c, "brain-one")
        hello = d.expect("hello", "the driver's first line is its hello")
        expect(hello["v"] == VECTORS["version"] and hello["driver"] == "cyfr-claude-code" and len(hello["boot"]) == 32,
               "hello names the wire's version, the driver and a boot of its own", hello)
        d.send({"t": "models", "id": "mdl_1"})
        listed = d.expect("models", "models with no harness running is listed from a harness of its own")
        expect([(m["id"], m["efforts"]) for m in listed["models"]] == LISTED
               and "account" not in listed
               and listed["access"] == [{"id": "default", "name": "Default mode"}],
               "the listing is the harness's, each model with the efforts it takes, the driver's one access, and "
               "nothing of an account the harness does not name", listed)
        eventually(lambda: not harnesses(stack), "the listing's harness to end")

        # ————— a start, a work and a post —————
        d.send({"t": "start", "gen": 4, "config": {"model": "fake-haiku", "effort": "high", "harness_tools": ["Bash", "Read"]},
                "system": SYSTEM})
        started = d.expect("started", "a fresh start answers started")
        session = started["session"]
        expect(started["fresh"] is True and started["held"] == [] and len(session) == 36, "a new session holding nothing",
               started)
        d.send({"t": "work", "id": "stp_work_1", "work": WORK, "tools": [FILES]})
        expect(d.expect("accepted", "the work's tools are set on the stub")["id"] == "stp_work_1", "by the work's id")
        d.send({"t": "post", "id": "stp_post_1", "work": WORK, "content": [{"type": "text", "text": "say hello"}]})
        turn = d.until("idle")
        expect(turn[0] == {"t": "accepted", "id": "stp_post_1"}, "the post is accepted first", turn[0])
        streamed = "".join(e["delta"] for e in turn if e["t"] == "text")
        said = [e["text"] for e in turn if e["t"] == "said"]
        expect(said and streamed == said[0] and f"session {session}, model fake-haiku, effort high, tools Bash,Read" in said[0]
               and "Bash allowed" in said[0] and f'prompt "{SYSTEM}"' in said[0],
               "the reply streams and is said whole, the start's flags and prompt the harness's own, its own tool allowed",
               said)
        usage = [e for e in turn if e["t"] == "usage"]
        expect(len(usage) == 1 and usage[0]["accounting"] == "complete"
               and {m["model"]: (m["counts"]["input_tokens"], m["counts"]["cache_read_tokens"]) for m in usage[0]["models"]}
               == {"fake-haiku": (12, 5), "fake-side": (30, 0)},
               "the result's usage is each model's, the side request's included and the main requests' counted once",
               usage)
        expect(turn[-1]["answered"] == ["stp_post_1"] and turn[-1]["stop"] == "end_turn",
               "idle names the post the result answered", turn[-1])
        expect(all(e.get("work") == WORK and e.get("gen") == 4 for e in turn[1:]),
               "every event of the turn names the post's work and the start's gen", turn)

        # ————— an ask of CYFR's tool, answered through the stub —————
        d.send({"t": "post", "id": "stp_post_2", "work": WORK, "content": [{"type": "text", "text": "read notes"}]})
        asked = [e for e in d.until("ask") if e["t"] == "ask"][0]
        expect(asked["name"] == "files" and asked["arguments"] == {"action": "read", "path": "notes.txt"},
               "an ask names CYFR's tool as CYFR names it, with its arguments", asked)
        d.send({"t": "answer", "id": "stp_answer_1", "ask": asked["ask"], "content": "three lines", "is_error": False})
        answered = d.until("idle")
        said = [e["text"] for e in answered if e["t"] == "said"]
        expect(answered[0] == {"t": "accepted", "id": "stp_answer_1"} and "The file says: three lines" in said,
               "the answer reaches the harness through cyfr-stub as the tool's result", answered)

        # ————— the person's own servers stay beside CYFR's —————
        d.send({"t": "post", "id": "stp_post_theirs", "work": WORK, "content": [{"type": "text", "text": "theirs"}]})
        turn = d.until("idle")
        expect(not any(e["t"] == "ask" for e in turn), "a call of a server of the person's own is never asked of CYFR", turn)
        said = [e["text"] for e in turn if e["t"] == "said"]
        expect(said == ["Tools: mcp__cyfr-2__files, mcp__cyfr__echo_env, mcp__mine__echo_env. "
                        'mcp__cyfr__echo_env given {"name":"THEIR_SERVER"} answered their cyfr; '
                        'mcp__mine__echo_env given {"name":"THEIR_SERVER"} answered their mine.'],
               "their tools are listed beside CYFR's, one named cyfr keeps its name, and each call runs in their server "
               "with the model's own input", said)
        own = [(e["name"], e["phase"]) for e in turn if e["t"] == "own"]
        expect(own == [("mcp__cyfr__echo_env", "start"), ("mcp__cyfr__echo_env", "end"),
                       ("mcp__mine__echo_env", "start"), ("mcp__mine__echo_env", "end")],
               "each call of theirs is shown as the program's own tool by name", own)
        seen += d.lines
        d.close()
        eventually(lambda: not harnesses(stack), "the closed session's harness to end")

        # ————— a new process resumes the session, with other flags —————
        d = Driver(c, "brain-two")
        d.expect("hello", "a new process says hello")
        d.send({"t": "start", "gen": 4, "session": session, "config": {"model": "fake-opus"}, "system": SYSTEM,
                "pending": ["stp_post_1", "stp_never"]})
        resumed = d.expect("started", "a resume answers started")
        expect(resumed == {"t": "started", "session": session, "fresh": False, "held": ["stp_post_1"]},
               "the resumed session is the same, and held names the post its transcript holds", resumed)
        d.send({"t": "work", "id": "stp_work_2", "work": "trn_brain_2", "tools": []})
        d.expect("accepted", "the resumed session's work is accepted")
        d.send({"t": "post", "id": "stp_post_3", "work": "trn_brain_2", "content": [{"type": "text", "text": "say hello"}]})
        said = [e["text"] for e in d.until("idle") if e["t"] == "said"]
        expect(said and f"session {session}, model fake-opus" in said[0], "the new process runs the new flags", said)

        # ————— a start naming an access the driver does not list runs nothing —————
        d.close()
        r = Driver(c, "brain-unlisted-access")
        r.expect("hello", "a driver to refuse an unlisted access")
        status, answer = c.send(OWNER, r.session, [json.dumps({"t": "start", "gen": 7, "config": {"model": "fake-haiku", "access": "bypassPermissions"}})])
        expect(status == 200, "the start is written", answer)
        lines, _after, running = c.lines_until(OWNER, r.session, lambda got: got, r.after, timeout_s=TIMEOUT_S)
        expect(not running and lines == [], "a start naming an access the driver does not list ends it and writes nothing", lines)
        r.close()

        # ————— a start in Default mode, named or not, whole —————
        base = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        inputs = [{"file_path": "made.txt", "content": "x"}, {"command": "touch made.txt"}]
        allowed = [{"type": "control_response", "response": {"subtype": "success", "request_id": f"ask-{i}",
                    "response": {"behavior": "allow", "updatedInput": inputs[i - 1]}}} for i in (1, 2)]
        for key, config in (("brain-access-absent", {"model": "fake-haiku"}),
                            ("brain-access-default", {"model": "fake-haiku", "access": "default"})):
            m = Driver(c, key)
            m.expect("hello", f"{key}: the driver says hello")
            m.send({"t": "start", "gen": 7, "config": config})
            fresh = m.expect("started", f"{key}: a fresh start answers started")["session"]
            m.send({"t": "work", "id": "stp_work_modes", "work": "trn_brain_modes", "tools": []})
            m.expect("accepted", f"{key}: its work is accepted")
            m.send({"t": "post", "id": "stp_post_modes", "work": "trn_brain_modes",
                    "content": [{"type": "text", "text": "modes"}]})
            turn = m.until("idle")
            expect(not any(e["t"] == "ask" for e in turn), f"{key}: the harness's own tools are never asked of CYFR", turn)
            got = json.loads([e["text"] for e in turn if e["t"] == "said"][0])
            expect(got["argv"] == base + ["--session-id", fresh, "--model", "fake-haiku", "--permission-mode", "default"],
                   f"{key}: the harness starts with exactly the start's command line, in its default permission mode",
                   got["argv"])
            expect(got["answers"] == allowed, f"{key}: the driver allows the harness's own Write and Bash exactly",
                   got["answers"])
            seen += m.lines
            m.close()

        # ————— a session the folder does not hold —————
        d = Driver(c, "brain-three")
        d.expect("hello", "another process says hello")
        d.send({"t": "start", "gen": 5, "session": str(uuid.uuid4()), "config": {}})
        d.expect("gone", "a resume of a session the folder does not hold is gone")
        d.send({"t": "start", "gen": 6, "config": {}})
        other = d.expect("started", "a fresh start runs after gone")["session"]
        d.send({"t": "work", "id": "stp_work_3", "work": "trn_brain_3", "tools": []})
        d.expect("accepted", "its work is accepted")
        d.send({"t": "post", "id": "stp_post_4", "work": "trn_brain_3", "content": [{"type": "text", "text": "say hello"}]})
        d.until("idle")

        # ————— forget —————
        transcript = f".claude/projects/-fake/{session}.jsonl"
        expect(home_has(c, transcript) and home_has(c, f".claude/projects/-fake/{other}.jsonl")
               and home_has(c, ".claude/.credentials.json"),
               "both sessions' transcripts and the sign-in are in the folder (a positive control)")
        d.send({"t": "forget", "id": "obx_1", "session": session})
        expect(d.expect("forgot", "forget is answered") == {"t": "forgot", "id": "obx_1", "session": session},
               "by its id and the session")
        expect(not home_has(c, transcript), "the forgotten session's transcript is gone from the folder")
        expect(home_has(c, f".claude/projects/-fake/{other}.jsonl") and home_has(c, ".claude/.credentials.json"),
               "another session's transcript and the sign-in stay")
        d.send({"t": "forget", "id": "obx_2", "session": other})
        expect(d.expect("refused", "the running session is not forgotten")["id"] == "obx_2", "by its id")
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

        # ————— nothing of stderr, the folder or the sign-in —————
        expect(home_has(c, "canary.txt"), "the harness kept its folder's canary (a positive control)")
        for canary in CANARIES:
            expect(not any(canary in line for line in seen), f"no line of the driver's carries {canary}")

        # ————— on a terminal the harness runs unchanged —————
        status, opened = c.open(OWNER, PROGRAM["name"], key="brain-terminal", mode="terminal", argv=[], home_id=HOME,
                                rows=24, cols=80)
        expect(status == 200, "a terminal of the brain row opens", opened)
        read, _after, _running = c.output_until(OWNER, opened["session"], lambda got: b"fake-claude: missing" in got)
        expect(b"fake-claude: missing" in read and b'"t":"hello"' not in read,
               "the terminal shows the harness's own words, not the wire: it ran unchanged", read[-400:])
        print("PASS: Claude Code's brain driver runs beside its harness in a kept folder")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
