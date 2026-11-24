#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A kept home of the backends image is its program's own disk, under a uid of its own.

Run as docker-compose.yml's locus-backends service, its kept homes on the
shipped `homes` volume under the keeper's `--kept-homes`, and driven only by
requests signed as CYFR signs them (harness.py):

- A kept program's process runs with its home, one folder per program row
  under the kept homes' root, 0700, as its HOME, under a uid of the home's
  own: in the kept range, never a pool uid, and no uid of the pool is taken
  while only kept sessions run. Two homes never share a uid.
- Two sessions of one row share its home and its uid, each a process of
  its own, and closing one leaves the other running.
- A kept home survives retirement: what one session wrote is there for the
  next, once every process of its uid is gone.
- No pooled uid and not the release's user (`locus`, which lists the root)
  can read a home.
- Two rows of one program, as Aqua's two browsers are, run in two homes
  under two uids: the cookies and storage one keeps in its profile the
  other neither reads, lists nor writes.
- A home past its row's `home_max_bytes` has its sessions ended within the
  measuring period, is reported over its cap, and refuses an open
  `home_over_cap` until a reset, which leaves it empty under its uid.
- Retiring a home (its program row deleted) ends its sessions and every
  process of its uid and removes its folder.
- A terminal runs the program's command with the open's argv (a sign-in's
  words, `login`) on a pseudo-terminal of the open's size in its kept home,
  told the wire's terminal type in `TERM`: a run message to it is refused,
  its prompt arrives before any newline, a
  resize reaches the process, the person's typed line (ending in a carriage
  return) reaches the command, and the session ends with it.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/kept_home.py IMAGE
"""

import json
import os
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    KEPT_FIRST, KEPT_LAST, KEPT_ROOT, POOL_FIRST, POOL_LAST, RELEASE_USER, STATUSES, VERSION, WIRE, Stack,
    eventually, expect, owner_of, probe, require_docker, unb64,
)
import imagesuite  # noqa: E402

OWNER, NEIGHBOUR = owner_of("kept"), owner_of("neighbour")
SHARED, CAPPED, SIGNED, RETIRED = (f"mcp_kept-{name}" for name in ("shared", "capped", "signed", "retired"))
# Two rows of one program, each a home: the person's browser and the one kept apart.
BROWSER, APART = (f"mcp_kept-{name}" for name in ("browser", "apart"))
# A profile as Chrome keeps one: its cookies and its storage, in the home's folder.
PROFILE = ('mkdir -p "$HOME/profile/Default/Local Storage" && echo {name}-cookie > "$HOME/profile/Default/Cookies" '
           '&& echo {name}-store > "$HOME/profile/Default/Local Storage/leveldb" && echo done')
CAP = 8 * 1024 * 1024
# What the measure may let through past the cap: what ten seconds write.
MEASURE_S = 10
# A program whose command signs in when its arguments are the sign-in's
# words: it prints its terminal's type and size, prompts, reads the code
# typed, and prints the size again, which a resize while it waits has changed.
SIGN_IN_ARGV = ["login"]
SIGN_IN = ("sh -c 'test \"$*\" = login || exit 64; echo \"term=$TERM\"; stty size; printf \"Paste code: \"; "
           "read code; echo \"signed in with $code\"; stty size' sh")
TERMINAL_TYPE = WIRE["terminal_type"].encode()
PROGRAMS = [
    probe(home="kept"),
    probe("capped", home="kept", home_max_bytes=CAP),
    {"name": "signin", "command": SIGN_IN, "env": {}, "home": "kept"},
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
               and a["tmpdir"] == "/tmp", "a kept program runs in its row's home, 0700, as HOME, its TMPDIR its space's own", a)
        expect(KEPT_FIRST <= a["uid"] <= KEPT_LAST and not POOL_FIRST <= a["uid"] <= POOL_LAST
               and a["gid"] == a["uid"], "it runs under a uid of the kept range, never a pool uid", a)
        expect(c.hello()[1]["pool"]["free"] == pool["free"], "a kept session takes no uid of the pool")
        sh(c, OWNER, 'echo kept-value > "$HOME/kept.txt"', key="a", home_id=SHARED)

        b = whoami(c, OWNER, key="b", home_id=SHARED)
        expect(b["uid"] == a["uid"] and b["home"] == a["home"] and b["pidns"] != a["pidns"],
               "a second session of the entry shares its home and uid in a space of its own", [a, b])
        first = stack.outside(a)
        seen = sh(c, OWNER, 'cat "$HOME/kept.txt"', key="b", home_id=SHARED)
        expect(seen["stdout"] == "kept-value\n", "the second session sees what the first wrote", seen)
        expect(c.program(OWNER, "probe")["sessions"] == 2, "the program runs two sessions")

        status, closed = c.close(OWNER, c.mcp(OWNER, "probe", key="a", home_id=SHARED).session)
        expect((status, closed) == (200, {"version": VERSION, "status": "closed"}), "a session is closed", closed)
        eventually(lambda: not any(p["pid"] == first["pid"] for p in stack.processes()), "the closed session's process to end")
        expect(whoami(c, OWNER, key="b", home_id=SHARED)["pid"] == b["pid"],
               "closing one session leaves the other running under the shared uid")
        c.close(OWNER, c.mcp(OWNER, "probe", key="b", home_id=SHARED).session)
        eventually(lambda: not stack.under_uid(a["uid"]), f"no process of uid {a['uid']} once both are closed")
        expect(not home_gone(stack, a["home"]), "the home is still there with no process of its uid")

        again = whoami(c, OWNER, key="a", home_id=SHARED)
        kept = sh(c, OWNER, 'cat "$HOME/kept.txt"', key="a", home_id=SHARED)
        # A pid namespace's number may be the ended one's again: the
        # container's numbering tells the two processes apart.
        later = stack.outside(again)
        expect(again["uid"] == a["uid"] and later and later["pid"] != first["pid"] and kept["stdout"] == "kept-value\n"
               and c.mcp(OWNER, "probe", key="a", home_id=SHARED).resumed is False,
               "a kept home survives retirement: the next session finds what the last wrote, under the same uid",
               [again, kept])

        # ————— nobody else reads it —————
        for path in [a["home"], f"{a['home']}/kept.txt", KEPT_ROOT]:
            status, answer = c.call(NEIGHBOUR, "probe__read_path", {"path": path})
            text = answer["result"]["content"][0]["text"]
            # A pooled program's space holds no kept homes' root at all.
            expect('"ok":false' in text and "ENOENT" in text, f"a pooled uid finds no {path} in its space", text)
        read = stack.exec(f"cat {a['home']}/kept.txt", user=RELEASE_USER)
        expect(read.returncode != 0 and "Permission denied" in read.stderr,
               f"the release's user, {RELEASE_USER}, cannot read a home", [read.returncode, read.stdout, read.stderr])
        listed = stack.exec(f"ls {KEPT_ROOT}", user=RELEASE_USER)
        expect(listed.returncode == 0 and SHARED in listed.stdout.split(),
               f"{RELEASE_USER} lists the kept homes' root, which it owns", listed.stdout + listed.stderr)

        # ————— two rows of one program: nothing crosses their homes —————
        own = whoami(c, OWNER, key="own", home_id=BROWSER)
        apart = whoami(c, OWNER, key="apart", home_id=APART)
        expect(own["uid"] != apart["uid"] and own["home"] != apart["home"]
               and {own["home_mode"], apart["home_mode"]} == {"700"},
               "two rows of one program run in two homes, 0700, under two uids", [own, apart])
        for key, home in [("own", BROWSER), ("apart", APART)]:
            wrote = sh(c, OWNER, PROFILE.format(name=key), key=key, home_id=home)
            expect(wrote["stdout"] == "done\n", f"the {key} row keeps a profile in its home", wrote)
        for key, home, other in [("own", BROWSER, apart["home"]), ("apart", APART, own["home"])]:
            crossed = sh(c, OWNER,
                         f'cat "{other}/profile/Default/Cookies" 2>&1; echo "rc=$?"; '
                         f'cat "{other}/profile/Default/Local Storage/leveldb" 2>&1; echo "rc=$?"; '
                         f'ls "{other}" 2>&1; echo "rc=$?"; touch "{other}/profile/Default/Cookies" 2>&1; echo "rc=$?"',
                         key=key, home_id=home)
            out = crossed["stdout"]
            expect(out.count("Permission denied") == 4 and "rc=0" not in out and "-cookie" not in out
                   and "-store" not in out,
                   f"the {key} row neither reads, lists nor writes the other's cookies and storage", out)
        mine = sh(c, OWNER, 'cat "$HOME/profile/Default/Cookies"', key="apart", home_id=APART)
        expect(mine["stdout"] == "apart-cookie\n", "each row reads its own profile", mine)
        for key, home in [("own", BROWSER), ("apart", APART)]:
            c.close(OWNER, c.mcp(OWNER, "probe", key=key, home_id=home).session)

        # ————— the disk bound —————
        capped = whoami(c, OWNER, "capped", home_id=CAPPED)
        expect(capped["uid"] != a["uid"] and KEPT_FIRST <= capped["uid"] <= KEPT_LAST,
               "another row's home has a uid of its own", [a["uid"], capped["uid"]])
        # The keeper measures every MEASURE_S and ends an over-cap home's sessions, so the write past the cap either
        # answers first or, on a slower machine, has its session ended at the cap while it writes. Either way what
        # follows holds: the home is over its cap, its sessions are ended, opens are refused until a reset.
        writer = c.mcp(OWNER, "capped", home_id=CAPPED)
        status, wrote = writer.call("run", {"argv": ["/bin/sh", "-c",
                                                     f'head -c {CAP * 4} /dev/zero > "$HOME/big"; sync; echo written']})
        result = (wrote or {}).get("result") or {}
        answered = (status == 200 and not result.get("isError") and "content" in result
                    and json.loads(result["content"][0]["text"])["stdout"] == "written\n")
        ended = status == 200 and (wrote or {}).get("ended") == "before_answer"
        expect(answered or ended, "a session writes past its home's cap, answering or ended at the cap mid-write",
               [status, wrote])
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

        # ————— a sign-in on a pseudo-terminal —————
        status, opened = c.open(OWNER, "signin", key="person", mode="terminal", argv=SIGN_IN_ARGV, rows=24, cols=80,
                                home_id=SIGNED)
        expect(status == 200 and opened == {"version": VERSION, "status": "running", "session": opened.get("session"),
                                            "resumed": False},
               "a terminal opens the program's command with the sign-in's argv", opened)
        session = opened["session"]
        status, refused = c.send(OWNER, session, ["abc123"])
        expect((status, refused) == refusal("bad_request"), "a run message to a terminal session is refused", refused)
        read, after_seq, running = c.output_until(OWNER, session, lambda read: b"Paste code: " in read)
        expect(running and b"24 80\r\nPaste code: " in read,
               "the command runs on a terminal of the open's size, its prompt arriving before any newline", read)
        expect(b"term=" + TERMINAL_TYPE + b"\r\n" in read, "the command is told the wire's terminal type", read)
        expect(c.resize(OWNER, session, 30, 100) == (200, {"version": VERSION, "status": "running"}),
               "the terminal is resized")
        expect(c.input(OWNER, session, b"abc123\r") == (200, {"version": VERSION, "status": "running"}),
               "the person types the code, a line ending with a carriage return")
        signed = b"signed in with abc123\r\n30 100\r\n"
        read, after_seq, running = c.output_until(OWNER, session, lambda read: signed in read, after=after_seq)
        expect(signed in read, "the typed line reaches the command, which sees the terminal's new size", read)
        ended = eventually(lambda: (lambda r: r if r[0] == 200 and not r[1]["running"] else None)(
            c.output(OWNER, session, after_seq, 1_000)), "the sign-in session to end with its command")
        expect(ended[1].get("exit_code") == 0
               and all(b"signed in" not in unb64(chunk["bytes"]) for chunk in ended[1]["chunks"]),
               "the session ends with its command's exit, and nothing is read twice past its after", ended)

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
        expect(not home_gone(stack, a["home"]), "retiring one row's home leaves another's")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
