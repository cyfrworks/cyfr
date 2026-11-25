#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Cursor's brain driver runs beside its program in a kept folder of the backends image.

Driven only by requests signed as CYFR signs them (harness.py), as the
holder (`Opus.Brain`) drives it: an owner whose brain row is
`cyfr-cursor` (the image's cyfr-acp, under Cursor's name) followed by the
program's command, kept. The program is fake-cursor.mjs, a stand-in for
`agent acp` speaking the lines Cursor 2026.11.22-e9042b2 was probed
writing, which keeps each session as a folder of its own in the folder,
`.cursor/acp-sessions/<id>/`, as Cursor does, and starts the image's
`cyfr-stub --socket` for CYFR's tools as Cursor starts a stdio server,
listing its tools at the session's first prompt. Every line the driver
writes is read against the wire's vectors (tests/fixtures/brain_wire.json):
its message is one of the events, with exactly its members.

- A run session's first line is the driver's `hello`; `models` with no
  program running makes a listing session of the driver's own, removes
  its folder, leaves no process, and lists each of the program's model
  values whole, with no efforts, the one access the driver honours and
  that the program is signed in.
- A start makes a UUID session with CYFR's server, named `cyfr-2` since
  the program lists a server of the person's own named `cyfr`, its model
  set as the session's config option, and answers `started` before any
  listing; the session's first prompt leads with the start's
  instructions, and its tools are listed then; a post streams as `text`
  and is said whole, the program's own tool shown by its kind, its usage
  `unavailable`, and its `idle` naming the post.
- A turn whose whole output is Cursor's failure chunk ends with an
  `error` of the provider's type in CYFR's words, its text never shown.
- A post while the prompt runs is `later`, and written once the holder
  writes it again after the turn's `idle`.
- CYFR's tool, called as Cursor calls a server's tool, reaches the driver
  through the stub and the session's socket: the call is an ask with its
  arguments, held, no call of the program's own, and its `answer` reaches
  the program as the call's result.
- A second run session of the same home at once binds a socket of its
  own: each session's ask is answered in its own session.
- A new process, started resuming the session, loads it with no listing
  of the person's servers, CYFR's server under the name the session was
  made with: the session's history, the start's tools, and `held` naming
  none.
- A resume of a session the folder lacks, or of an id of another form,
  is `gone`, and a fresh start runs in the same driver.
- `forget` removes that session's folder and the driver's records of it,
  confirmed by the program's load, and leaves another session and the
  sign-in; the running session is not forgotten.
- A start naming an access the driver does not list ends the driver, its one
  line its `ending`, `unfit`; one naming the program's own tools, `broken`.
- Nothing of the program's standard error, its folder or its sign-in
  reaches a line of the driver's.
- On a terminal, the driver runs the program's command unchanged.
- The image holds cyfr-cursor as cyfr-acp under its name.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/brain_cursor.py IMAGE
"""

import json
import os
import sys
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import ROOT, Stack, ending, eventually, expect, owner_of, probe, require_docker  # noqa: E402

with open(os.path.join(ROOT, "tests", "fixtures", "brain_wire.json"), encoding="utf-8") as _vectors:
    VECTORS = json.load(_vectors)
EVENTS = VECTORS["events"]

OWNER = owner_of("brain-cursor")
HOME = "mcp_brain-cursor"
FAKE = "fake-cursor.mjs"
PROGRAM = {"name": "brain", "command": f"cyfr-cursor node /probe/{FAKE}", "env": {}, "home": "kept"}
# The person's own server `cyfr`, as fake-cursor.mjs lists it, so CYFR's
# takes the next name.
RELAY = "cyfr-2"
PREAMBLE = "Your current instructions, in place of any given earlier in this session:\n"
CANARIES = ("FAKE-STDERR-CANARY", "FAKE-FOLDER-CANARY", "FAKE-SIGNIN-CANARY", "getaddrinfo")
FILES = {
    "name": "files",
    "description": "Read the athanor's files",
    "parameters": {"type": "object", "properties": {"action": {"type": "string"}, "path": {"type": "string"}},
                   "required": ["action", "path"]},
}
SYSTEM = "You are a crew member of this athanor."
WORK = "trn_brain_1"
MODEL = "claude-opus-5-5[context=300k,effort=medium,fast=false]"
LISTED = [("default[]", "Auto", []), (MODEL, "claude-opus-5-5", [])]
TIMEOUT_S = 60


class Driver:
    """One run session of the driver, spoken to as the holder speaks to it."""

    def __init__(self, c, key, program=PROGRAM):
        self.c = c
        status, opened = c.open(OWNER, program["name"], key=key, argv=[], home_id=HOME)
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


def probe_run(c, key, script):
    """`script`'s standard output, as a probe program run in the same kept home, under the same uid, in a space
    of its own, prints it."""
    client = c.mcp(OWNER, "probe", key=key, home_id=HOME)
    status, answer = client.call("run", {"argv": ["/bin/sh", "-c", script]})
    result = (answer or {}).get("result") or {}
    expect(status == 200 and not result.get("isError") and "content" in result, f"the probe runs: {script}", answer)
    return json.loads(result["content"][0]["text"])["stdout"]


def folder(c):
    """The sessions' folders, the listings counted, and whether the sign-in and each record stand, as a probe
    reads them in the home."""
    return json.loads(probe_run(c, "folder", 'printf \'{"sessions":["%s"],"listings":%s,"signin":%s,"records":["%s"]}\' '
                                '"$(ls "$HOME/.cursor/acp-sessions" | paste -sd, - | sed \'s/,/","/g\')" '
                                '"$(cat "$HOME/.cursor/listings" 2>/dev/null | wc -l)" '
                                '"$(test -f "$HOME/.config/cursor/auth.json" && echo true || echo false)" '
                                '"$(ls "$HOME/.cache/cyfr-acp/servers" 2>/dev/null | paste -sd, - | sed \'s/,/","/g\')"'))


def fresh_turn(d, work, post, words):
    """A work and a post of `words` in the session `d` runs: the post's turn, to its idle."""
    d.send({"t": "work", "id": f"stp_work_{post}", "work": work, "tools": [FILES]})
    d.expect("accepted", f"the work before {post} is accepted, writing nothing")
    d.send({"t": "post", "id": post, "work": work, "content": [{"type": "text", "text": words}]})
    return d.until("idle")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: brain_cursor.py IMAGE")
    require_docker()
    stack = Stack("locus-backends-brain-cursor", sys.argv[1])
    seen = []
    try:
        stack.up()
        linked = stack.exec('cmp /opt/cyfr/bin/cyfr-acp /opt/cyfr/bin/cyfr-cursor && echo same')
        expect(linked.stdout.strip() == "same", "the image holds cyfr-cursor as cyfr-acp under Cursor's name",
               linked.stdout + linked.stderr)
        c = stack.controller()
        expect(c.hello()[0] == 200, "the backends service is greeted")
        status, synced, _ = c.sync(OWNER, [PROGRAM, probe(home="kept")])
        expect(status == 200, "an owner of the brain row, kept, is synced", synced)

        # ————— hello, and a listing with no program running —————
        d = Driver(c, "brain-one")
        hello = d.expect("hello", "the driver's first line is its hello")
        expect(hello["v"] == VECTORS["version"] and hello["driver"] == "cyfr-cursor" and len(hello["boot"]) == 32,
               "hello names the wire's version, the driver and a boot of its own", hello)
        d.send({"t": "models", "id": "mdl_1"})
        listed = d.expect("models", "models with no program running is listed from a session of the driver's own")
        expect([(m["id"], m["name"], m["efforts"]) for m in listed["models"]] == LISTED
               and listed["account"] == "signed_in"
               and listed["access"] == [{"id": "full-access", "name": "Full access, no approvals"}],
               "each model value whole with no efforts, the driver's one access and the sign-in", listed)
        eventually(lambda: not harnesses(stack), "the listing's programs to end")
        expect(folder(c)["sessions"] == [""], "the listing's session folder is removed", folder(c))

        # ————— a start's scroll, which the program keeps no folder of its own for, then a start —————
        d.send({"t": "scroll", "id": "stp_start_1:scroll:0", "name": "research", "description": "How it researches",
                "body": "Search the notes first.\n"})
        expect(d.expect("yielded", "a scroll is yielded") == {"t": "yielded", "id": "stp_start_1:scroll:0"},
               "every scroll keeps the model's harness's way, placed nowhere")

        # ————— a start, a work and a post —————
        d.send({"t": "start", "gen": 4, "config": {"model": MODEL, "access": "full-access"}, "system": SYSTEM, "tools": [FILES]})
        started = d.expect("started", "a fresh start answers started, before any listing")
        first = started["session"]
        expect(started == {"t": "started", "session": first, "fresh": True, "held": [], "account": "signed_in"}
               and uuid.UUID(first), "a new UUID session, holding nothing, signed in", started)
        turn = fresh_turn(d, WORK, "stp_post_1", "say hello")
        expect(turn[0] == {"t": "accepted", "id": "stp_post_1"}, "the post is accepted first", turn[0])
        streamed = "".join(e["delta"] for e in turn if e["t"] == "text")
        said = [e["text"] for e in turn if e["t"] == "said"]
        expect(said and streamed == said[0]
               and f"session {first}, opened by new, model {MODEL}, mode agent, tools {RELAY}:files, "
                   f"earlier 0, texts {json.dumps([PREAMBLE + SYSTEM, 'say hello'], separators=(',', ':'))}." in said[0],
               "the reply streams and is said whole; the session runs the start's model in agent mode, CYFR's tools "
               "through its server under a name the person's own server does not have, listed at the first prompt, "
               "and the prompt leads with the instructions whole, then the job", said)
        expect([(e["name"], e["phase"]) for e in turn if e["t"] == "own"] == [("read", "start"), ("read", "end")],
               "the program's own tool is shown by its kind", turn)
        usage = [e for e in turn if e["t"] == "usage"]
        expect(len(usage) == 1 and usage[0]["accounting"] == "unavailable" and "models" not in usage[0],
               "Cursor reports no usage: unavailable", usage)
        expect(turn[-1]["answered"] == ["stp_post_1"] and turn[-1]["stop"] == "end_turn",
               "idle names the post its prompt carried", turn[-1])
        expect(folder(c)["listings"] == 1, "the person's servers were listed once, when the session was made", folder(c))

        # ————— a failed turn —————
        failed = fresh_turn(d, WORK, "stp_post_fail", "fail")
        errors = [e for e in failed if e["t"] == "error"]
        expect(len(errors) == 1 and errors[0]["type"] == "provider_error"
               and errors[0]["message"] == "Cursor could not reach its service; ask again once the network is back."
               and not [e for e in failed if e["t"] in ("text", "said")] and failed[-1]["stop"] == "error",
               "a turn whose whole output is Cursor's failure is an error in CYFR's words, its text never shown", failed)

        # ————— a post while the prompt runs is later —————
        d.send({"t": "post", "id": "stp_post_2", "work": WORK, "content": [{"type": "text", "text": "slow one"}]})
        expect(d.expect("accepted", "the slow post is accepted")["id"] == "stp_post_2", "by its id")
        expect(d.expect("text", "its turn streams a first part")["delta"] == "Starting", "the first part")
        d.send({"t": "post", "id": "stp_post_3", "work": WORK, "content": [{"type": "text", "text": "the steer"}]})
        expect(d.event() == {"t": "later", "id": "stp_post_3"}, "a post mid-turn is later: Cursor's own would cancel the turn")
        slow = d.until("idle")
        expect([e["text"] for e in slow if e["t"] == "said"] == ["Starting and done."] and slow[-1]["answered"] == ["stp_post_2"],
               "the running turn goes on to its end, uncancelled", slow)
        d.send({"t": "post", "id": "stp_post_3", "work": WORK, "content": [{"type": "text", "text": "say hello"}]})
        later = d.until("idle")
        expect(later[0] == {"t": "accepted", "id": "stp_post_3"} and 'texts ["say hello"].' in [e["text"] for e in later if e["t"] == "said"][0],
               "the later post, written again after the idle, is the next prompt, its instructions not handed again", later)

        # ————— CYFR's call, as Cursor makes it —————
        d.send({"t": "post", "id": "stp_post_4", "work": WORK, "content": [{"type": "text", "text": "read notes"}]})
        before = d.until("ask")
        asked = before[-1]
        expect(not [e for e in before if e["t"] == "own"]
               and asked["name"] == "files" and asked["arguments"] == {"action": "read", "path": "notes.txt"}
               and asked["work"] == WORK and len(asked["ask"]) == 36,
               "CYFR's call is an ask with the arguments it was called with, and no call of the program's own", before)
        d.send({"t": "answer", "id": "stp_answer_1", "ask": asked["ask"], "content": "three lines", "is_error": False})
        answered = d.until("idle")
        expect(answered[0] == {"t": "accepted", "id": "stp_answer_1"}
               and [e["text"] for e in answered if e["t"] == "said"] == ["The file says: three lines"]
               and not [e for e in answered if e["t"] == "own"] and answered[-1]["answered"] == ["stp_post_4"],
               "the answer reaches the program as the call's result", answered)

        # ————— a second session of the same home at once —————
        b = Driver(c, "brain-beside")
        b.expect("hello", "a second run session of the same home says hello")
        b.send({"t": "start", "gen": 4, "config": {}, "system": SYSTEM, "tools": [FILES]})
        second = b.expect("started", "a second session starts while the first runs, its socket bound in its own space")["session"]
        expect(second != first, "a session of its own", second)
        b.send({"t": "work", "id": "stp_work_b", "work": "trn_brain_b", "tools": [FILES]})
        b.expect("accepted", "the second session's work is accepted")
        d.send({"t": "post", "id": "stp_post_6", "work": WORK, "content": [{"type": "text", "text": "read notes"}]})
        b.send({"t": "post", "id": "stp_post_b1", "work": "trn_brain_b", "content": [{"type": "text", "text": "read notes"}]})
        first_ask = [e for e in d.until("ask") if e["t"] == "ask"][0]
        second_ask = [e for e in b.until("ask") if e["t"] == "ask"][0]
        b.send({"t": "answer", "id": "stp_answer_b", "ask": second_ask["ask"], "content": "the second's", "is_error": False})
        said_b = [e["text"] for e in b.until("idle") if e["t"] == "said"]
        d.send({"t": "answer", "id": "stp_answer_2", "ask": first_ask["ask"], "content": "the first's", "is_error": False})
        said_a = [e["text"] for e in d.until("idle") if e["t"] == "said"]
        expect(said_b == ["The file says: the second's"] and said_a == ["The file says: the first's"],
               "each session's call is answered by its own session's answer", (said_a, said_b))
        for driver in (d, b):
            seen += driver.lines
            driver.close()
        eventually(lambda: not harnesses(stack), "the closed sessions' programs to end, though their input's end does not end them")

        # ————— a new process goes on with the session —————
        d = Driver(c, "brain-two")
        d.expect("hello", "a new process says hello")
        d.send({"t": "start", "gen": 5, "session": first, "config": {}, "system": SYSTEM,
                "tools": [FILES], "pending": ["stp_post_1", "stp_never"]})
        resumed = d.expect("started", "a resume answers started")
        expect(resumed == {"t": "started", "session": first, "fresh": False, "held": [], "account": "signed_in"},
               "the session goes on by its load, and held names none", resumed)
        said = [e["text"] for e in fresh_turn(d, "trn_brain_2", "stp_post_7", "say hello") if e["t"] == "said"]
        expect(said and f"session {first}, opened by load, model default[], mode agent, tools {RELAY}:files, "
                        'earlier 6, texts ["say hello"].' in said[0],
               "the new process holds the session's history and the start's tools under the server's kept name, "
               "the replay never shown and the instructions not handed again", said)
        expect(folder(c)["listings"] == 2, "only the second session made was listed for: the load took the kept name", folder(c))

        # ————— sessions the folder does not hold —————
        seen += d.lines
        d.close()
        for key, session in (("brain-gone", str(uuid.uuid4())), ("brain-gone-form", "ses_" + "0" * 26)):
            d = Driver(c, key)
            d.expect("hello", f"{key}: another process says hello")
            d.send({"t": "start", "gen": 7, "session": session, "config": {}})
            d.expect("gone", f"{key}: a resume of a session the folder does not hold is gone")
            seen += d.lines
            d.close()
        d = Driver(c, "brain-three")
        d.expect("hello", "another process says hello")
        d.send({"t": "start", "gen": 8, "config": {}, "tools": [FILES]})
        third = d.expect("started", "a fresh start runs")["session"]
        fresh_turn(d, "trn_brain_4", "stp_post_9", "say hello")

        # ————— forget —————
        before = folder(c)
        expect({first, second, third} <= set(before["sessions"]) and first in before["records"],
               "every session is a folder of the program's, and the driver keeps its server's name (a positive control)", before)
        d.send({"t": "forget", "id": "obx_1", "session": first})
        expect(d.expect("forgot", "forget is answered") == {"t": "forgot", "id": "obx_1", "session": first},
               "by its id and the session")
        after = folder(c)
        expect(first not in after["sessions"] and {second, third} <= set(after["sessions"]) and after["signin"]
               and first not in after["records"],
               "the forgotten session's folder and records are gone, and another session and the sign-in stay", after)
        d.send({"t": "forget", "id": "obx_2", "session": third})
        expect(d.expect("refused", "the running session is not forgotten")["id"] == "obx_2", "by its id")
        expect(third in folder(c)["sessions"], "the running session stays")
        seen += d.lines
        d.close()

        # ————— a start the driver cannot honour ends it —————
        for key, start in (("brain-unlisted-access", {"t": "start", "gen": 9, "config": {"access": "default"}, "tools": [FILES]}),
                           ("brain-own-tools", {"t": "start", "gen": 9, "config": {"harness_tools": ["read"]}})):
            r = Driver(c, key)
            r.expect("hello", f"{key}: a driver to refuse a start it cannot honour")
            status, answer = c.send(OWNER, r.session, [json.dumps(start)])
            expect(status == 200, f"{key}: the start is written", answer)
            lines, _after, running = c.lines_until(OWNER, r.session, lambda got: False, r.after, timeout_s=TIMEOUT_S)
            why = "broken" if key == "brain-own-tools" else "unfit"
            expect(not running and lines == [ending(why)], f"{key}: the start ends the driver and writes only its ending, {why}", lines)
            r.close()
        eventually(lambda: not harnesses(stack), "no program to run for a refused start")

        # ————— nothing of stderr, the folder or the sign-in —————
        for canary in CANARIES:
            expect(not any(canary in line for line in seen), f"no line of the driver's carries {canary}")

        # ————— on a terminal the program runs unchanged —————
        status, opened = c.open(OWNER, PROGRAM["name"], key="brain-terminal", mode="terminal", argv=[], home_id=HOME,
                                rows=24, cols=80)
        expect(status == 200, "a terminal of the brain row opens", opened)
        read, _after, _running = c.output_until(OWNER, opened["session"], lambda got: b"not acp" in got)
        expect(b"not acp" in read and b'"t":"hello"' not in read,
               "the terminal shows the program's own words, not the wire: it ran unchanged", read[-400:])
        print("PASS: Cursor's brain driver runs beside its program in a kept folder")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
