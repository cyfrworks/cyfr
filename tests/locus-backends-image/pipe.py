#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends image runs a program over its session's lines, as a brain's driver is run.

Driven only by requests signed as CYFR signs them (harness.py): an owner
whose one program is `cat`, kept, as a driven row of CYFR's runs it, in the
row's kept home:

- An open in mode `run` starts the row's command with the opener's argv
  appended (`cat -`), in the row's kept home as its HOME, under the
  home's own uid (the kept range, never a pool uid), and answers
  `resumed: false`; a second open of the same lifetime answers the same
  session, `resumed: true`, and once its process ended is refused
  `lifetime_over`.
- Lines sent come back numbered in order; a recv naming the same `after`
  answers the same lines again (a lost answer is replayed), and one naming
  the last line waits its `max_wait_ms` and answers none.
- A session with no line sent or read within the owner's idle period is
  retired: its process gone, no process of the home's uid left, the
  session answering `running: false`; the next open of the key answers
  `resumed: false` with a new session, and a new process sees the argv
  again.
- A reader that falls behind loses the oldest lines, never the newest:
  past `max_buffer_bytes` the buffer drops lines and a recv from the start
  names how many in `dropped`, its first line numbered just past them and
  its last the newest line the program wrote.
- Retiring the home (its program row's deletion, through CYFR) ends
  the session's process and removes the home's folder; the session answers
  `running: false`.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/pipe.py IMAGE
"""

import os
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    BOUNDS, KEPT_FIRST, KEPT_LAST, POOL_FIRST, POOL_LAST, STATUSES, VERSION, Stack, eventually,
    expect, home_of, owner_of, require_docker,
)
import imagesuite  # noqa: E402

OWNER = owner_of("pipe")
HOME = "mcp_pipe-cat"
KEY = "chat-1"
ARGV = ["-"]
IDLE_MS = 5_000
# The row's command: `cat`, after a first line naming its HOME, which a
# process of the home's own uid keeps from every other reader. The service
# appends the opener's argv (`"$@"`), so `cat -` is what runs.
COMMAND = 'echo "home=$HOME"; exec cat'
PROGRAM = {"name": "cat", "command": COMMAND, "env": {}, "home": "kept"}
# Lines the drop case writes: each well under a line's bound, together well
# past the buffer's.
DROP_LINE_BYTES = 60_000
DROP_LINES = (BOUNDS["max_buffer_bytes"] // DROP_LINE_BYTES) * 5 // 4
DROP_BATCH = 16
MARKER = "end-of-drop"


def cat_processes(stack):
    """The service's `cat -` processes: what the row's command with the opener's argv runs."""
    return [p for p in stack.processes() if p["cmd"] == "cat " + " ".join(ARGV)]


def one_cat(stack, what):
    found = eventually(lambda: (lambda cats: cats if len(cats) == 1 else None)(cat_processes(stack)), what)
    return found[0]


def kept_uid(process):
    """Whether `process` runs under a uid of the kept range, never a pool uid."""
    uid = process["uids"][0]
    return KEPT_FIRST <= uid <= KEPT_LAST and not POOL_FIRST <= uid <= POOL_LAST


def home_line(home_id):
    """The first line the row's command writes, in `home_id`'s kept home on its owner's disk."""
    return f"home={home_of(OWNER, home_id)}"


def read_until(c, session, after, done, timeout_s=30):
    """Every line past `after` until `done(lines)`: the session's lines, as dicts, oldest first."""
    lines = []
    deadline = time.monotonic() + timeout_s
    while not done(lines):
        status, answer = c.recv(OWNER, session, after, 2_000)
        if status != 200 or not answer["running"]:
            sys.exit(f"FAIL: a recv of {session} answers no running session: {status} {answer}")
        lines += answer["lines"]
        if answer["lines"]:
            after = answer["lines"][-1]["seq"]
        if time.monotonic() > deadline:
            sys.exit(f"FAIL: timed out reading {session}: {[x['text'][:40] for x in lines]}")
    return lines


def home_gone(stack, home):
    probe_home = f"test -e {home} && echo present || echo absent"
    return imagesuite.read_word(stack.exec(probe_home), ("present", "absent"), f"the probe of {home}") == "absent"


def scripted_controller(image):
    stack = Stack("locus-backends-pipe", image)
    try:
        stack.up()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the service is greeted")
        status, synced, _ = c.sync(OWNER, [PROGRAM], idle_ms=IDLE_MS)
        expect(status == 200 and synced["programs"] == [{"name": "cat", "status": "idle"}],
               "an owner of one kept pipe program is synced and starts nothing", synced)
        pool = c.hello()[1]["pool"]

        # ————— open and attach —————
        status, opened = c.open(OWNER, "cat", key=KEY, argv=ARGV, home_id=HOME)
        expect(status == 200 and opened == {"version": VERSION, "status": "running", "session": opened.get("session"),
                                            "resumed": False},
               "an open in mode run starts the program for its key", opened)
        session = opened["session"]
        cat = one_cat(stack, "the row's command to run with the opener's argv")
        (first,) = read_until(c, session, 0, lambda got: len(got) >= 1)
        expect(first["text"] == home_line(HOME) and kept_uid(cat),
               "the program runs in the row's kept home as its HOME, under the home's uid", [first, cat])
        expect(c.hello()[1]["pool"]["free"] == pool["free"], "a kept session takes no uid of the pool")
        lifetime = c.lifetime(session)
        status, again = c.open(OWNER, "cat", key=KEY, argv=ARGV, home_id=HOME, lifetime=lifetime)
        expect(status == 200 and again["resumed"] is True and again["session"] == session,
               "a second open of the same lifetime answers its running session", again)

        # ————— lines in, numbered lines out —————
        sent = ["one", "two", "three"]
        expect(c.send(OWNER, session, sent) == (200, {"version": VERSION, "status": "running"}),
               "lines are sent to the running session")
        lines = read_until(c, session, first["seq"], lambda got: len(got) >= len(sent))
        seqs = [x["seq"] for x in lines]
        expect([x["text"] for x in lines] == sent and seqs == list(range(first["seq"] + 1, first["seq"] + 1 + len(sent))),
               "the program's lines come back in order, numbered one after another", lines)
        status, replay = c.recv(OWNER, session, first["seq"], 0)
        expect(status == 200 and replay["lines"] == lines and replay["dropped"] == 0,
               "a recv naming the same after answers the same lines again", replay)
        started = time.monotonic()
        status, waited = c.recv(OWNER, session, seqs[-1], 1_500)
        expect(status == 200 and waited["lines"] == [] and waited["running"] is True
               and time.monotonic() - started >= 1.4,
               "a recv naming the last line waits its max_wait_ms and answers none", waited)

        # ————— retirement and the next open —————
        uid, pid = cat["uids"][0], cat["pid"]
        idle = eventually(lambda: (lambda p: p if p["sessions"] == 0 else None)(c.program(OWNER, "cat")),
                          "the session to be retired idle", timeout_s=IDLE_MS / 1000 + 20)
        expect(idle["restarts"] == 0, "an idle end is no crash", idle)
        eventually(lambda: not stack.under_uid(uid), f"no process of the home's uid {uid} once retired")
        status, ended = c.recv(OWNER, session, seqs[-1], 0)
        expect(status == 200 and ended["running"] is False and ended["lines"] == [],
               "the retired session answers running: false", ended)
        status, over = c.open(OWNER, "cat", key=KEY, argv=ARGV, home_id=HOME, lifetime=lifetime)
        expect((status, over) == (STATUSES["lifetime_over"], {"version": VERSION, "error": "lifetime_over"}),
               "an open of the ended process's lifetime is refused", over)
        status, reopened = c.open(OWNER, "cat", key=KEY, argv=ARGV, home_id=HOME)
        expect(status == 200 and reopened["resumed"] is False and reopened["session"] != session,
               "the next open of the key starts the program again: resumed false, a new session", reopened)
        session = reopened["session"]
        woken = one_cat(stack, "the program to run again")
        expect(c.send(OWNER, session, ["again"])[0] == 200, "a line is sent to the new session")
        home, echoed = read_until(c, session, 0, lambda got: len(got) >= 2)
        expect(woken["pid"] != pid and woken["uids"][0] == uid and home["text"] == home_line(HOME),
               "a new process, with the opener's argv, in the same home under the same uid", [pid, woken, home])
        expect(echoed["text"] == "again", "the new process echoes it", echoed)
        after = echoed["seq"]

        # ————— a reader that falls behind —————
        written = [f"{index:05d}-" + "x" * DROP_LINE_BYTES for index in range(DROP_LINES)] + [MARKER]
        statuses = {c.send(OWNER, session, written[at:at + DROP_BATCH])[0]
                    for at in range(0, len(written), DROP_BATCH)}
        expect(statuses == {200}, f"{len(written)} lines are sent unread, past the buffer's bound", statuses)

        def drained():
            status, answer = c.recv(OWNER, session, after, 2_000)
            if status != 200:
                sys.exit(f"FAIL: a recv past the buffer's bound is refused: {status} {answer}")
            return answer if answer["lines"] and answer["lines"][-1]["text"] == MARKER else None

        kept = eventually(drained, "the program to have echoed every line", timeout_s=60)
        texts = [x["text"] for x in kept["lines"]]
        held = sum(len(t) + BOUNDS["line_charge_bytes"] for t in texts)
        expect(kept["dropped"] > 0 and kept["lines"][0]["seq"] == after + 1 + kept["dropped"],
               "past the buffer's bound the oldest lines are dropped, counted, and the first kept line numbered "
               "just past them", [kept["dropped"], kept["lines"][0]["seq"], after])
        expect(texts == written[len(written) - len(texts):] and held <= BOUNDS["max_buffer_bytes"],
               "the lines kept are the newest, within the buffer's bound",
               [len(texts), held, texts[0][:12]])
        seqs = [x["seq"] for x in kept["lines"]]
        expect(seqs == list(range(seqs[0], seqs[0] + len(seqs))), "the kept lines are numbered one after another")

        # ————— the home retired with its row —————
        status, retired, _ = c.home(OWNER["athanor"], HOME, "retire")
        expect((status, retired) == (200, {"version": VERSION, "home_id": HOME, "state": "absent"}),
               "a retire answers the home absent", retired)
        eventually(lambda: not stack.under_uid(uid), f"every process of uid {uid} to end with its home")
        expect(not cat_processes(stack), "the session's process is gone")
        expect(home_gone(stack, home_of(OWNER, HOME)), "the retired home's folder is gone")
        status, answer = c.recv(OWNER, session, seqs[-1], 0)
        expect(status == 200 and answer["running"] is False, "the session answers running: false", answer)
    finally:
        stack.down()


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: pipe.py IMAGE")
    require_docker()
    scripted_controller(sys.argv[1])


if __name__ == "__main__":
    main()
