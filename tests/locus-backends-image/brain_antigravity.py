#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Antigravity's brain driver runs beside its program in a kept folder of the backends image.

Driven only by requests signed as CYFR signs them (harness.py), as the
holder (`Opus.Brain`) drives it: an owner whose brain row is
`cyfr-antigravity` (the image's cyfr-acp, under Antigravity's name)
followed by the program's command, kept. The program is fake-acp.mjs, a
stand-in for `agy acp` speaking the lines agy 1.5.16 was probed writing,
which keeps its sessions in the folder as agy does and starts the
image's `cyfr-stub --socket` for CYFR's tools as agy starts a stdio
server. Every line the driver writes is read against the wire's vectors
(tests/fixtures/brain_wire.json): its message is one of the events, with
exactly its members.

- A run session's first line is the driver's `hello`, naming the wire's
  version and a boot of its own; `models` with no program running makes a
  listing session of the driver's own, leaves no process of it and no file
  of that session, and lists each model with the efforts the program has a
  variant of, the one access the driver honours, full access with no
  approvals, and that the program is signed in.
- A start makes a session with CYFR's server and the start's instructions
  in agy's own place for them, its model and effort set as the session's
  config options, and `started` names the new session once the stub has
  listed the start's tools; a work writes nothing; a post is a prompt,
  streamed as `text` and said whole, the program's own tool shown by name
  only, its usage the prompt's under the session's model, `partial`, and
  its `idle` naming the post, every event naming the post's work.
- A post while the prompt runs is a second prompt, which steers the turn:
  it is `accepted` once the earlier prompt has answered, and the turn's
  `idle` names both posts.
- An ask of CYFR's tool reaches the driver through the stub and the
  session's socket, is passed up with its arguments, held, and answered by
  an `answer`, which reaches the program as the call's result. A post while
  the ask is held is `later`, and written once the holder writes it again
  after the turn's `idle`.
- A second run session of the same home at once, in a space of its own,
  binds a socket of its own: each session's asks are its own and each is
  answered in its own session, and a process of a third space reaches
  neither socket.
- A new process, started resuming the session, holds it: the session's
  history, the start's tools and instructions, and `held` naming none; a
  resume the program answers by loading is the same, and nothing of the
  load's replay reaches the wire.
- A resume of a session the folder does not hold is `gone`, and a fresh
  start runs in the same driver.
- `forget` removes that session's files, and leaves another session's,
  the index every session shares and the sign-in; the running session is
  not forgotten.
- Every command line the vectors refuse (their `refuse` lines from the
  holder) ends the driver, its one line its `ending`, `broken`; a start
  naming an access the driver does not list, fresh or resuming, ends it
  with `unfit`, and one naming the program's own tools with `broken`.
- Nothing of the program's standard error, its folder, its tier or its
  sign-in reaches a line of the driver's.
- On a terminal, the driver runs the program's command unchanged: the
  program's own words, not the wire, are what the terminal shows.
- The image holds cyfr-antigravity as cyfr-acp under its name, and cyfr-fetch,
  which refuses a command line it does not read with status 2.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/brain_antigravity.py IMAGE
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

OWNER = owner_of("brain-antigravity")
HOME = "mcp_brain-antigravity"
FAKE = "fake-acp.mjs"
PROGRAM = {"name": "brain", "command": f"cyfr-antigravity node /probe/{FAKE}", "env": {}, "home": "kept"}
# The same program, answering every resume as agy answers one it cannot
# read, so the driver loads the session.
LOADING = {**PROGRAM, "name": "brain-loading", "env": {"FAKE_RESUME_FAILS": "1"}}
CANARIES = ("FAKE-STDERR-CANARY", "FAKE-FOLDER-CANARY", "FAKE-SIGNIN-CANARY", "FAKE-TIER-CANARY", "oauth_creds")
FILES = {
    "name": "files",
    "description": "Read the athanor's files",
    "parameters": {"type": "object", "properties": {"action": {"type": "string"}, "path": {"type": "string"}},
                   "required": ["action", "path"]},
}
SYSTEM = "You are a crew member of this athanor."
WORK = "trn_brain_1"
CLI = ".gemini/antigravity-cli"
# The program's index of every session, by the names fake-acp.mjs keeps it
# under, as Antigravity does.
SHARED = (f"{CLI}/*_summaries.db", f"{CLI}/*_summaries_proto.pb")
SIGNIN = ".gemini/oauth_creds.json"
LISTED = [("gemini-4-neon", ["low", "medium", "high", "xhigh"]), ("gemini-3.8-flash", ["low", "medium", "high"]),
          ("gpt-oss-120b-medium", [])]
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


def home_has(c, path):
    """Whether the brain row's folder holds `path` (a shell pattern)."""
    word = probe_run(c, "folder", f'for f in "$HOME"/{path}; do test -e "$f" && echo present && exit; done; echo absent').strip()
    expect(word in ("present", "absent"), f"the probe of {path} answers", word)
    return word == "present"


def session_files(session):
    return (f"{CLI}/brain/{session}", f"{CLI}/*/{session}.db", f"{CLI}/annotations/{session}.pbtxt")


def fresh_turn(d, work, post, words):
    """A work and a post of `words` in the session `d` runs: the post's turn, to its idle."""
    d.send({"t": "work", "id": f"stp_work_{post}", "work": work, "tools": [FILES]})
    d.expect("accepted", f"the work before {post} is accepted, writing nothing")
    d.send({"t": "post", "id": post, "work": work, "content": [{"type": "text", "text": words}]})
    return d.until("idle")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: brain_antigravity.py IMAGE")
    require_docker()
    stack = Stack("locus-backends-brain-antigravity", sys.argv[1])
    seen = []
    try:
        stack.up()
        linked = stack.exec('cmp /opt/cyfr/bin/cyfr-acp /opt/cyfr/bin/cyfr-antigravity && echo same')
        expect(linked.stdout.strip() == "same", "the image holds cyfr-antigravity as cyfr-acp under Antigravity's name",
               linked.stdout + linked.stderr)
        fetch = stack.exec('/opt/cyfr/bin/cyfr-fetch agy; echo "status=$?"')
        expect(fetch.stdout.strip() == "status=2" and "usage: cyfr-fetch NAME VERSION" in fetch.stderr,
               "the image holds cyfr-fetch, which refuses a command line it does not read with status 2",
               fetch.stdout + fetch.stderr)
        c = stack.controller()
        expect(c.hello()[0] == 200, "the backends service is greeted")
        status, synced, _ = c.sync(OWNER, [PROGRAM, LOADING, probe(home="kept")])
        expect(status == 200, "an owner of the brain rows, kept, is synced", synced)

        # ————— hello, and a listing with no program running —————
        d = Driver(c, "brain-one")
        hello = d.expect("hello", "the driver's first line is its hello")
        expect(hello["v"] == VECTORS["version"] and hello["driver"] == "cyfr-antigravity" and len(hello["boot"]) == 32,
               "hello names the wire's version, the driver and a boot of its own", hello)
        d.send({"t": "models", "id": "mdl_1"})
        listed = d.expect("models", "models with no program running is listed from a session of the driver's own")
        expect([(m["id"], m["efforts"]) for m in listed["models"]] == LISTED
               and listed["models"][0]["name"] == "Gemini 4 Neon"
               and listed["account"] == "signed_in"
               and listed["access"] == [{"id": "full-access", "name": "Full access, no approvals"}],
               "the listing is the session's models, each with the efforts it has a variant of, the driver's one "
               "access and the sign-in", listed)
        eventually(lambda: not harnesses(stack), "the listing's program to end")
        expect(home_has(c, SHARED[0]) and not home_has(c, f"{CLI}/*/*.db")
               and not home_has(c, f"{CLI}/brain/*") and not home_has(c, f"{CLI}/annotations/*"),
               "the listing's session is gone from the folder, and the index the program keeps of it stays")

        # ————— a start, a work and a post —————
        d.send({"t": "start", "gen": 4, "config": {"model": "gemini-3.8-flash", "effort": "medium", "access": "full-access"},
                "system": SYSTEM, "tools": [FILES]})
        started = d.expect("started", "a fresh start answers started")
        first = started["session"]
        expect(started == {"t": "started", "session": first, "fresh": True, "held": [], "account": "signed_in"}
               and len(first) == 36, "a new session holding nothing, signed in", started)
        turn = fresh_turn(d, WORK, "stp_post_1", "say hello")
        expect(turn[0] == {"t": "accepted", "id": "stp_post_1"}, "the post is accepted first", turn[0])
        streamed = "".join(e["delta"] for e in turn if e["t"] == "text")
        said = [e["text"] for e in turn if e["t"] == "said"]
        expect(said and streamed == said[0]
               and f"session {first}, opened by new, model gemini-3.8-flash, effort medium, mode default, tools mcp_cyfr_files, "
                   f'blocks 1, earlier 0, instructions "{SYSTEM}"' in said[0],
               "the reply streams and is said whole; the session runs the start's model and effort, the default "
               "mode, CYFR's tools through its server, and the instructions in agy's own place, not the prompt",
               said)
        expect([(e["name"], e["phase"]) for e in turn if e["t"] == "own"] == [("read", "start"), ("read", "end")],
               "the program's own tool is shown by name only", turn)
        usage = [e for e in turn if e["t"] == "usage"]
        expect(len(usage) == 1 and usage[0]["accounting"] == "partial" and "result" in usage[0]
               and "total" not in usage[0]
               and usage[0]["models"] == [{"model": "gemini-3.8-flash",
                                           "counts": {"input_tokens": 12, "output_tokens": len(said[0]) + 1,
                                                      "cache_read_tokens": 5, "cache_write_tokens": 2}}],
               "the prompt's usage is under the session's model, by the wire's names, partial", usage)
        expect(turn[-1]["answered"] == ["stp_post_1"] and turn[-1]["stop"] == "end_turn",
               "idle names the post its prompt carried", turn[-1])
        expect(all(e.get("work") == WORK and e.get("gen") == 4 for e in turn[1:]),
               "every event of the turn names the post's work and the start's gen", turn)

        # ————— a post while the prompt runs steers the turn —————
        d.send({"t": "post", "id": "stp_post_2", "work": WORK, "content": [{"type": "text", "text": "slow one"}]})
        expect(d.expect("accepted", "the slow post is accepted")["id"] == "stp_post_2", "by its id")
        expect(d.expect("text", "its turn streams a first part")["delta"] == "Starting", "the first part")
        d.send({"t": "post", "id": "stp_post_3", "work": WORK, "content": [{"type": "text", "text": "the steer"}]})
        steered = d.until("idle")
        expect(steered[0] == {"t": "accepted", "id": "stp_post_3"}
               and [e["text"] for e in steered if e["t"] == "said"] == ["Starting Read the steer: the steer"]
               and len([e for e in steered if e["t"] == "usage"]) == 1
               and steered[-1]["answered"] == ["stp_post_2", "stp_post_3"],
               "the steer is accepted once the earlier prompt answered, the turn reads it, and its idle names both "
               "posts", steered)

        # ————— an ask of CYFR's tool through the socket, and a post while it is held —————
        d.send({"t": "post", "id": "stp_post_4", "work": WORK, "content": [{"type": "text", "text": "read notes"}]})
        asked = [e for e in d.until("ask") if e["t"] == "ask"][0]
        expect(asked["name"] == "files" and asked["arguments"] == {"action": "read", "path": "notes.txt"}
               and asked["work"] == WORK and len(asked["ask"]) == 36,
               "an ask names CYFR's tool as CYFR names it, with the arguments the program called it with", asked)
        d.send({"t": "post", "id": "stp_post_5", "work": WORK, "content": [{"type": "text", "text": "say hello"}]})
        expect(d.event() == {"t": "later", "id": "stp_post_5"}, "a post while the ask is held is later")
        d.send({"t": "answer", "id": "stp_answer_1", "ask": asked["ask"], "content": "three lines", "is_error": False})
        answered = d.until("idle")
        expect(answered[0] == {"t": "accepted", "id": "stp_answer_1"}
               and [e["text"] for e in answered if e["t"] == "said"] == ["The file says: three lines"]
               and answered[-1]["answered"] == ["stp_post_4"]
               and not [e for e in answered if e["t"] == "own"],
               "the answer reaches the program as the call's result, CYFR's call is no own tool, and the later "
               "post was not written", answered)
        d.send({"t": "post", "id": "stp_post_5", "work": WORK, "content": [{"type": "text", "text": "say hello"}]})
        later = d.until("idle")
        expect(later[0] == {"t": "accepted", "id": "stp_post_5"} and later[-1]["answered"] == ["stp_post_5"]
               and "earlier 4," in [e["text"] for e in later if e["t"] == "said"][0],
               "the later post, written again after the idle, is the session's next prompt", later)

        # ————— a second session of the same home at once —————
        b = Driver(c, "brain-beside")
        b.expect("hello", "a second run session of the same home says hello")
        b.send({"t": "start", "gen": 4, "config": {}, "system": SYSTEM, "tools": [FILES]})
        beside = b.expect("started", "a second session starts while the first runs, its socket bound in its own space")
        second = beside["session"]
        expect(beside["fresh"] is True and second != first, "a session of its own", beside)
        b.send({"t": "work", "id": "stp_work_b", "work": "trn_brain_b", "tools": [FILES]})
        b.expect("accepted", "the second session's work is accepted")
        reached = probe_run(c, "reach", r"""printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' """
                            r"""'{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | /opt/cyfr/bin/cyfr-stub --socket cyfr-tools""")
        listing = [m for m in map(json.loads, reached.splitlines()) if m.get("id") == 2]
        expect(len(listing) == 1 and "result" not in listing[0]
               and "CYFR's tools are not reachable" in listing[0]["error"]["message"],
               "a process of a third space of the same home and uid reaches neither session's socket", reached)
        d.send({"t": "post", "id": "stp_post_6", "work": WORK, "content": [{"type": "text", "text": "read notes"}]})
        b.send({"t": "post", "id": "stp_post_b1", "work": "trn_brain_b", "content": [{"type": "text", "text": "read notes"}]})
        first_ask = [e for e in d.until("ask") if e["t"] == "ask"][0]
        second_ask = [e for e in b.until("ask") if e["t"] == "ask"][0]
        expect(first_ask["ask"] != second_ask["ask"] and first_ask["work"] == WORK and second_ask["work"] == "trn_brain_b",
               "both sessions hold an ask at once, each on its own wire", (first_ask, second_ask))
        b.send({"t": "answer", "id": "stp_answer_b", "ask": second_ask["ask"], "content": "the second's", "is_error": False})
        said_b = [e["text"] for e in b.until("idle") if e["t"] == "said"]
        d.send({"t": "answer", "id": "stp_answer_2", "ask": first_ask["ask"], "content": "the first's", "is_error": False})
        said_a = [e["text"] for e in d.until("idle") if e["t"] == "said"]
        expect(said_b == ["The file says: the second's"] and said_a == ["The file says: the first's"],
               "each session's call is answered by its own session's answer", (said_a, said_b))
        for driver in (d, b):
            seen += driver.lines
            driver.close()
        eventually(lambda: not harnesses(stack), "the closed sessions' programs to end")

        # ————— a new process resumes the session —————
        d = Driver(c, "brain-two")
        d.expect("hello", "a new process says hello")
        d.send({"t": "start", "gen": 5, "session": first, "config": {"model": "gemini-4-neon"}, "system": SYSTEM,
                "tools": [FILES], "pending": ["stp_post_1", "stp_never"]})
        resumed = d.expect("started", "a resume answers started")
        expect(resumed == {"t": "started", "session": first, "fresh": False, "held": [], "account": "signed_in"},
               "the resumed session is the same, and held names none, since agy returns no prompt's id", resumed)
        said = [e["text"] for e in fresh_turn(d, "trn_brain_2", "stp_post_7", "say hello") if e["t"] == "said"]
        expect(said and f"session {first}, opened by resume, model gemini-4-neon, effort high, mode default, tools mcp_cyfr_files, "
                        f'blocks 1, earlier 6, instructions "{SYSTEM}"' in said[0],
               "the new process holds the session's history, with the new model, the start's tools and instructions",
               said)
        seen += d.lines
        d.close()

        # ————— a resume the program answers by loading —————
        d = Driver(c, "brain-loaded", LOADING)
        d.expect("hello", "a process of the loading row says hello")
        d.send({"t": "start", "gen": 6, "session": first, "config": {}, "system": SYSTEM, "tools": [FILES]})
        loaded = d.expect("started", "a resume agy answers by loading answers started")
        expect(loaded == {"t": "started", "session": first, "fresh": False, "held": [], "account": "signed_in"},
               "the loaded session is the same, holding none", loaded)
        turn = fresh_turn(d, "trn_brain_3", "stp_post_8", "say hello")
        said = [e["text"] for e in turn if e["t"] == "said"]
        expect(turn[0] == {"t": "accepted", "id": "stp_post_8"} and len(said) == 1 and f"session {first}, opened by load," in said[0] and "earlier 7," in said[0]
               and "".join(e["delta"] for e in turn if e["t"] == "text") == said[0],
               "the load's replay never reaches the wire: the next turn shows its own reply alone", turn)
        seen += d.lines
        d.close()

        # ————— a session the folder does not hold —————
        d = Driver(c, "brain-three")
        d.expect("hello", "another process says hello")
        d.send({"t": "start", "gen": 7, "session": str(uuid.uuid4()), "config": {}})
        d.expect("gone", "a resume of a session the folder does not hold is gone")
        d.send({"t": "start", "gen": 8, "config": {}, "tools": [FILES]})
        third = d.expect("started", "a fresh start runs after gone")["session"]
        fresh_turn(d, "trn_brain_4", "stp_post_9", "say hello")

        # ————— forget —————
        expect(all(home_has(c, f) for f in session_files(first) + session_files(second) + SHARED + (SIGNIN,)),
               "both sessions' files, the shared index and the sign-in are in the folder (a positive control)")
        d.send({"t": "forget", "id": "obx_1", "session": first})
        expect(d.expect("forgot", "forget is answered") == {"t": "forgot", "id": "obx_1", "session": first},
               "by its id and the session")
        expect(not any(home_has(c, f) for f in session_files(first)), "the forgotten session's files are gone")
        expect(all(home_has(c, f) for f in session_files(second) + SHARED + (SIGNIN,)),
               "another session's files, the index every session shares and the sign-in stay")
        d.send({"t": "forget", "id": "obx_2", "session": third})
        expect(d.expect("refused", "the running session is not forgotten")["id"] == "obx_2", "by its id")
        expect(home_has(c, session_files(third)[1]), "the running session's files stay")
        seen += d.lines
        d.close()

        # ————— a command the wire refuses ends the driver —————
        for i, refused in enumerate(r for r in VECTORS["refuse"] if r["from"] == "holder"):
            r = Driver(c, f"brain-refused-{i}")
            r.expect("hello", "a driver to refuse a command")
            status, answer = c.send(OWNER, r.session, [refused["line"]])
            expect(status == 200, f"the line is written: {refused['name']}", answer)
            lines, _after, running = c.lines_until(OWNER, r.session, lambda got: False, r.after, timeout_s=TIMEOUT_S)
            expect(not running and lines == [ending("broken")], f"the driver ends on it and writes only its ending, broken: {refused['name']}", lines)
            r.close()
        for key, start in (("brain-unlisted-access", {"t": "start", "gen": 9, "config": {"access": "default"}, "tools": [FILES]}),
                           ("brain-unlisted-access-resumed", {"t": "start", "gen": 9, "session": second, "config": {"access": "auto"}}),
                           ("brain-own-tools", {"t": "start", "gen": 9, "config": {"harness_tools": ["read_file"]}})):
            r = Driver(c, key)
            r.expect("hello", f"{key}: a driver to refuse a start it cannot honour")
            status, answer = c.send(OWNER, r.session, [json.dumps(start)])
            expect(status == 200, f"{key}: the start is written", answer)
            lines, _after, running = c.lines_until(OWNER, r.session, lambda got: False, r.after, timeout_s=TIMEOUT_S)
            why = "broken" if key == "brain-own-tools" else "unfit"
            expect(not running and lines == [ending(why)], f"{key}: the start ends the driver and writes only its ending, {why}", lines)
            r.close()
        eventually(lambda: not harnesses(stack), "no program to run for a refused start")

        # ————— nothing of stderr, the folder, the tier or the sign-in —————
        expect(home_has(c, "notes.md") and home_has(c, SIGNIN),
               "the program kept its folder's canary and its sign-in (a positive control)")
        for canary in CANARIES:
            expect(not any(canary in line for line in seen), f"no line of the driver's carries {canary}")

        # ————— on a terminal the program runs unchanged —————
        status, opened = c.open(OWNER, PROGRAM["name"], key="brain-terminal", mode="terminal", argv=[], home_id=HOME,
                                rows=24, cols=80)
        expect(status == 200, "a terminal of the brain row opens", opened)
        read, _after, _running = c.output_until(OWNER, opened["session"], lambda got: b"not acp" in got)
        expect(b"not acp" in read and b'"t":"hello"' not in read,
               "the terminal shows the program's own words, not the wire: it ran unchanged", read[-400:])
        print("PASS: Antigravity's brain driver runs beside its program in a kept folder")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
