#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A kept home of the backends image is its program's own disk, under a uid of its own.

Run as docker-compose.yml's locus-backends service, its kept homes on the
shipped `homes` volume under the keeper's `--kept-homes`, and driven only by
requests signed as CYFR signs them (harness.py):

- A kept program's process runs with its home, one folder per login entry
  under the kept homes' root, 0700, as its HOME, under a uid of the home's
  own: in the kept range, never a pool uid, and no uid of the pool is taken
  while only kept sessions run. Two homes never share a uid.
- Two sessions of one entry share its home and its uid, each a process of
  its own, and closing one leaves the other running.
- A kept home survives retirement: what one session wrote is there for the
  next, once every process of its uid is gone.
- No pooled uid and not the release's user (`locus`, which lists the root)
  can read a home.
- A home past its row's `home_max_bytes` has its sessions ended within the
  measuring period, is reported over its cap, and refuses an open
  `home_over_cap` until a reset, which leaves it empty under its uid.
- Retiring a home (its login entry deleted) ends its sessions and every
  process of its uid and removes its folder.
- A sign-in runs the program's login command on a pseudo-terminal in its
  kept home: its prompt arrives as a line before any newline, the person's
  input line reaches it, and the session ends with the command; a program
  with no login command refuses a sign-in.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/kept_home.py IMAGE
"""

import json
import os
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    KEPT_FIRST, KEPT_LAST, KEPT_ROOT, POOL_FIRST, POOL_LAST, RELEASE_USER, STATUSES, VERSION, Stack, eventually,
    expect, owner_of, probe, require_docker,
)
import imagesuite  # noqa: E402

OWNER, NEIGHBOUR = owner_of("kept"), owner_of("neighbour")
SHARED, CAPPED, SIGNED, RETIRED = (f"vlt_kept-{name}" for name in ("shared", "capped", "signed", "retired"))
CAP = 8 * 1024 * 1024
# What the measure may let through past the cap: what ten seconds write.
MEASURE_S = 10
LOGIN = "printf 'Paste code: '; read code; echo \"signed in with $code\""
PROGRAMS = [
    probe(home="kept"),
    probe("capped", home="kept", home_max_bytes=CAP),
    probe("signin", home="kept", login_command=LOGIN),
]


def refusal(code):
    return STATUSES[code], {"version": VERSION, "error": code}


def home_gone(stack, home):
    """Whether `home` is gone, from the word a root shell prints after a stat it can make in the kept root."""
    probe_home = f"test -e {home} && echo present || echo absent"
    return imagesuite.read_word(stack.exec(probe_home), ("present", "absent"), f"the probe of {home}") == "absent"


def sh(c, owner, script, program="probe", key="mcp", home_id=None):
    """`script` run by `sh -c` in the program's session of `key`: its answer."""
    client = c.mcp(owner, program, key=key, home_id=home_id)
    status, answer = client.call("run", {"argv": ["/bin/sh", "-c", script]})
    result = (answer or {}).get("result") or {}
    if status != 200 or result.get("isError") or "content" not in result:
        sys.exit(f"FAIL: {script}: {status} {answer}")
    return json.loads(result["content"][0]["text"])


def whoami(c, owner, program="probe", key="mcp", home_id=None):
    status, answer = c.mcp(owner, program, key=key, home_id=home_id).call("whoami", {})
    result = (answer or {}).get("result") or {}
    if status != 200 or result.get("isError") or "content" not in result:
        sys.exit(f"FAIL: whoami of {program} {key}: {status} {answer}")
    return json.loads(result["content"][0]["text"])


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: kept_home.py IMAGE")
    require_docker()
    stack = Stack("locus-backends-kept-home", sys.argv[1])
    try:
        stack.up()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the service is greeted")
        status, answer, _ = c.sync(OWNER, PROGRAMS)
        expect(status == 200, "an owner of three kept programs is synced", answer)
        status, answer, _ = c.sync(NEIGHBOUR, [probe()])
        expect(status == 200, "a neighbour with a scratch program is synced", answer)
        pool = c.hello()[1]["pool"]

        # ————— a home of its own, under a uid of its own —————
        a = whoami(c, OWNER, key="a", home_id=SHARED)
        expect(a["home"] == f"{KEPT_ROOT}/{SHARED}" and a["home_mode"] == "700" and a["cwd"] == a["home"]
               and a["tmpdir"] == f"{a['home']}/tmp", "a kept program runs in its entry's home, 0700, as HOME", a)
        expect(KEPT_FIRST <= a["uid"] <= KEPT_LAST and not POOL_FIRST <= a["uid"] <= POOL_LAST
               and a["gid"] == a["uid"], "it runs under a uid of the kept range, never a pool uid", a)
        expect(c.hello()[1]["pool"]["free"] == pool["free"], "a kept session takes no uid of the pool")
        sh(c, OWNER, 'echo kept-value > "$HOME/kept.txt"', key="a", home_id=SHARED)

        b = whoami(c, OWNER, key="b", home_id=SHARED)
        expect(b["uid"] == a["uid"] and b["home"] == a["home"] and b["pid"] != a["pid"],
               "a second session of the entry shares its home and uid in a process of its own", [a, b])
        seen = sh(c, OWNER, 'cat "$HOME/kept.txt"', key="b", home_id=SHARED)
        expect(seen["stdout"] == "kept-value\n", "the second session sees what the first wrote", seen)
        expect(c.program(OWNER, "probe")["sessions"] == 2, "the program runs two sessions")

        status, closed = c.close(OWNER, c.mcp(OWNER, "probe", key="a", home_id=SHARED).session)
        expect((status, closed) == (200, {"version": VERSION, "status": "closed"}), "a session is closed", closed)
        eventually(lambda: not any(p["pid"] == a["pid"] for p in stack.processes()), "the closed session's process to end")
        expect(whoami(c, OWNER, key="b", home_id=SHARED)["pid"] == b["pid"],
               "closing one session leaves the other running under the shared uid")
        c.close(OWNER, c.mcp(OWNER, "probe", key="b", home_id=SHARED).session)
        eventually(lambda: not stack.under_uid(a["uid"]), f"no process of uid {a['uid']} once both are closed")
        expect(not home_gone(stack, a["home"]), "the home is still there with no process of its uid")

        again = whoami(c, OWNER, key="a", home_id=SHARED)
        kept = sh(c, OWNER, 'cat "$HOME/kept.txt"', key="a", home_id=SHARED)
        expect(again["uid"] == a["uid"] and again["pid"] != a["pid"] and kept["stdout"] == "kept-value\n"
               and c.mcp(OWNER, "probe", key="a", home_id=SHARED).resumed is False,
               "a kept home survives retirement: the next session finds what the last wrote, under the same uid",
               [again, kept])

        # ————— nobody else reads it —————
        for path in [a["home"], f"{a['home']}/kept.txt", KEPT_ROOT]:
            status, answer = c.call(NEIGHBOUR, "probe__read_path", {"path": path})
            text = answer["result"]["content"][0]["text"]
            expect('"ok":false' in text and "EACCES" in text, f"a pooled uid cannot read {path}", text)
        read = stack.exec(f"cat {a['home']}/kept.txt", user=RELEASE_USER)
        expect(read.returncode != 0 and "Permission denied" in read.stderr,
               f"the release's user, {RELEASE_USER}, cannot read a home", [read.returncode, read.stdout, read.stderr])
        listed = stack.exec(f"ls {KEPT_ROOT}", user=RELEASE_USER)
        expect(listed.returncode == 0 and SHARED in listed.stdout.split(),
               f"{RELEASE_USER} lists the kept homes' root, which it owns", listed.stdout + listed.stderr)

        # ————— the disk bound —————
        capped = whoami(c, OWNER, "capped", home_id=CAPPED)
        expect(capped["uid"] != a["uid"] and KEPT_FIRST <= capped["uid"] <= KEPT_LAST,
               "another entry's home has a uid of its own", [a["uid"], capped["uid"]])
        wrote = sh(c, OWNER, f'head -c {CAP * 4} /dev/zero > "$HOME/big"; sync; echo written', program="capped",
                   home_id=CAPPED)
        expect(wrote["stdout"] == "written\n", "a session writes past its home's cap", wrote)
        started = time.monotonic()
        over = eventually(lambda: (lambda p: p if p["over_cap"] and p["sessions"] == 0 else None)(
            c.program(OWNER, "capped")), "the home's sessions to be ended at its cap", timeout_s=MEASURE_S + 20)
        expect(over["home_bytes"] >= CAP, "the status reports the home's measured bytes past its cap", over)
        eventually(lambda: not stack.under_uid(capped["uid"]), f"no process of uid {capped['uid']} past the cap")
        expect(time.monotonic() - started <= MEASURE_S + 10, "the cap is enforced within the measuring period")
        status, answer = c.open(OWNER, "capped", key="mcp", home_id=CAPPED)
        expect((status, answer) == refusal("home_over_cap"), "a home over its cap refuses an open", answer)
        status, answer = c.open(OWNER, "capped", key="other", home_id=CAPPED)
        expect((status, answer) == refusal("home_over_cap"), "and refuses it for every key", answer)

        status, reset, _ = c.home(OWNER["athanor"], CAPPED, "reset")
        expect((status, reset) == (200, {"version": VERSION, "home_id": CAPPED, "state": "empty"}),
               "a reset answers the home empty", reset)
        expect(not c.program(OWNER, "capped")["over_cap"], "a reset home is no longer over its cap")
        after = whoami(c, OWNER, "capped", home_id=CAPPED)
        listing = sh(c, OWNER, 'ls -A "$HOME"', program="capped", home_id=CAPPED)
        expect(after["uid"] == capped["uid"] and "big" not in listing["stdout"].split(),
               "after a reset the home opens again, empty of what it held, under the same uid", [after, listing])

        # ————— sign-in on a pseudo-terminal —————
        status, opened = c.open(OWNER, "probe", key="person", mode="sign_in", home_id=SHARED)
        expect((status, opened) == refusal("bad_request"), "a program with no login command refuses a sign-in", opened)
        status, opened = c.open(OWNER, "signin", key="person", mode="sign_in", home_id=SIGNED)
        expect(status == 200 and opened["pty"] is True and opened["resumed"] is False,
               "a sign-in opens on a pseudo-terminal", opened)
        session = opened["session"]
        lines, after_seq, running = c.lines_until(OWNER, session, lambda lines: any("Paste code:" in x for x in lines))
        expect(running and any("Paste code:" in x for x in lines),
               "the login command's prompt arrives as a line before any newline", lines)
        expect(c.send(OWNER, session, ["abc123"]) == (200, {"version": VERSION, "status": "running"}),
               "the person's input line is sent")
        lines, after_seq, running = c.lines_until(OWNER, session,
                                                  lambda lines: any("signed in with abc123" in x for x in lines),
                                                  after=after_seq)
        expect(any("signed in with abc123" in x for x in lines), "the input line reaches the login command", lines)
        ended = eventually(lambda: (lambda r: r if r[0] == 200 and not r[1]["running"] else None)(
            c.recv(OWNER, session, after_seq, 1_000)), "the sign-in session to end with its command")
        expect(ended[1]["lines"] == [] or all("signed in" not in x["text"] for x in ended[1]["lines"]),
               "nothing is read twice past its after", ended)

        # ————— retirement with the entry —————
        retiring = whoami(c, OWNER, key="r", home_id=RETIRED)
        sh(c, OWNER, 'echo gone > "$HOME/file"; (trap "" TERM; exec sleep 100000) >/dev/null 2>&1 &', key="r",
           home_id=RETIRED)
        client = c.mcp(OWNER, "probe", key="r", home_id=RETIRED)
        status, retired, _ = c.home(OWNER["athanor"], RETIRED, "retire")
        expect((status, retired) == (200, {"version": VERSION, "home_id": RETIRED, "state": "absent"}),
               "a retire answers the home absent", retired)
        eventually(lambda: not stack.under_uid(retiring["uid"]),
                   f"every process of uid {retiring['uid']} to end, a detached one included")
        expect(home_gone(stack, retiring["home"]), "the retired home's folder is gone")
        status, answer = c.recv(OWNER, client.session, client.after, 0)
        expect(status == 200 and answer["running"] is False, "the retired home's session answers running: false",
               answer)
        expect(not home_gone(stack, a["home"]), "retiring one entry's home leaves another's")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
