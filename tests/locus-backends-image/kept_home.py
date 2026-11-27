#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A person's kept programs share one disk of the backends image, under one uid of theirs.

Run as docker-compose.yml's locus-backends service, its kept homes on the
shipped `homes` volume under the keeper's `--kept-homes`, and driven only by
requests signed as CYFR signs them (harness.py):

- A person, an athanor, has one disk under the kept homes' root, named by
  the SHA-256 of their athanor's id, under one uid of the kept range, never
  a pool uid: a kept program's process runs with its row's home on it,
  0700, as its HOME, and no uid of the pool is taken while only kept
  sessions run. Two people's disks never share a uid.
- Two sessions of one row share its home and its uid, each a process of
  its own, and closing one leaves the other running.
- A kept home survives retirement: what one session wrote is there for the
  next, once every process of its uid is gone.
- No pooled uid and not the backends role's user can read a home, and the
  role's user cannot list the kept homes' root: the keeper alone does, and
  no role is of the root's group.
- A tool one of the person's programs installs in /work, on npm's prefix,
  is on the PATH of their others and of no one else's: another person's
  program has a /work of its own, empty of it, under another uid, and finds
  neither the person's home nor their disk.
- No session reaches the kept homes' root: on what the kernel holds (the
  session's own mount table), the kept volume is in its space only as its
  own home, at that home's path, and its disk's work folder, at /work;
  under the root it sees the path to its home alone, and no record.
- Two rows of one program, as Aqua's two browsers are, run in two homes
  of the person's one disk under its one uid: the cookies and storage one
  keeps in its profile the other neither reads, lists nor writes.
- A home past its row's `home_max_bytes` has its sessions ended within the
  measuring period, is reported over its cap, and refuses an open
  `home_over_cap` until a reset, which leaves it empty under its uid.
- Retiring a home (its program row deleted) ends that program's sessions,
  a detached process of theirs included, and removes its folder, while the
  person's other program runs on, with its home, /work and the uid.
- A disk whose every row is retired keeps its /work and its uid through
  the sweeps and a restart: the person's next program finds the tool they
  installed, under the same uid.
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
    KEPT_FIRST, KEPT_LAST, KEPT_ROOT, POOL_FIRST, POOL_LAST, RELEASE_USER, STATUSES, VERSION, WIRE, Stack, disk_of,
    eventually, expect, home_of, owner_of, probe, require_docker, run, unb64,
)
import imagesuite  # noqa: E402

OWNER, NEIGHBOUR = owner_of("kept"), owner_of("neighbour")
SHARED, CAPPED, SIGNED, RETIRED, BACK = (f"mcp_kept-{name}" for name in ("shared", "capped", "signed", "retired", "back"))
# The neighbour's own kept program, a home on their disk.
THEIRS = "mcp_kept-theirs"
# A tool the person installs for every program of theirs, where npm puts one.
TOOL = ('mkdir -p "$NPM_CONFIG_PREFIX/bin" && printf "#!/bin/sh\\necho shared-tool\\n" > "$XDG_BIN_HOME/their-tool" '
        '&& chmod 0755 "$XDG_BIN_HOME/their-tool" && echo "$NPM_CONFIG_PREFIX $XDG_BIN_HOME"')
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


def kept_mounts(c, owner, program, key, home_id, home):
    """The session's mounts of the kept volume, from its own /proc/self/mountinfo: (root, mount point) of each mount
    on the device its home is on, and every mount point under the kept homes' root."""
    table = sh(c, owner, "cat /proc/self/mountinfo", program=program, key=key, home_id=home_id)["stdout"]
    rows = [line.split(" ") for line in table.splitlines()]
    device = next(r[2] for r in rows if r[4] == home)
    volume = sorted((r[3], r[4]) for r in rows if r[2] == device and (r[4] == home or r[4] == "/work"
                                                                      or r[4].startswith(KEPT_ROOT)))
    under = sorted(r[4] for r in rows if r[4] == KEPT_ROOT or r[4].startswith(KEPT_ROOT + "/"))
    roots = [r[3] for r in rows if r[2] == device]
    return volume, under, roots


def refusal(code):
    return STATUSES[code], {"version": VERSION, "error": code}


def home_gone(stack, home):
    """Whether `home` is gone, from the word the observer prints: a home is inside its person's disk, 0700, which no
    process of the container but its uid's searches."""
    probe_home = f"test -e {home} && echo present || echo absent"
    return imagesuite.read_word(stack.observe(probe_home), ("present", "absent"), f"the probe of {home}") == "absent"


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
        status, answer, _ = c.sync(NEIGHBOUR, [probe(), probe("kept", home="kept")])
        expect(status == 200, "a neighbour with a scratch program and a kept one is synced", answer)
        pool = c.hello()[1]["pool"]

        # ————— a home of its own, on the person's disk, under its uid —————
        a = whoami(c, OWNER, key="a", home_id=SHARED)
        expect(a["home"] == home_of(OWNER, SHARED) and a["home_mode"] == "700" and a["cwd"] == a["home"]
               and a["tmpdir"] == "/tmp",
               "a kept program runs in its row's home on its person's disk, 0700, as HOME, its TMPDIR its space's own", a)
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
               f"the role's user, {RELEASE_USER}, cannot read a home", [read.returncode, read.stdout, read.stderr])
        listed = stack.exec(f"ls {KEPT_ROOT}", user=RELEASE_USER)
        expect(listed.returncode != 0 and "Permission denied" in listed.stderr,
               f"{RELEASE_USER} cannot list the kept homes' root, whose group it is not of",
               listed.stdout + listed.stderr)

        # ————— the person's tools, in /work, are theirs alone —————
        installed = sh(c, OWNER, TOOL, key="a", home_id=SHARED)
        expect(installed["stdout"] == "/work/.local /work/.local/bin\n",
               "npm's prefix and XDG_BIN_HOME are the person's /work, where a tool is installed", installed)
        used = sh(c, OWNER, 'their-tool; command -v their-tool; echo "$PATH"', key="own", home_id=BROWSER)
        expect(used["stdout"].startswith("shared-tool\n/work/.local/bin/their-tool\n/opt/cyfr/bin:")
               and f":{home_of(OWNER, BROWSER)}/.local/bin:/work/.local/bin:" in used["stdout"],
               "the person's other program finds the tool on its PATH, after its own home's", used)
        theirs = whoami(c, NEIGHBOUR, "kept", key="t", home_id=THEIRS)
        expect(theirs["uid"] != a["uid"] and KEPT_FIRST <= theirs["uid"] <= KEPT_LAST
               and theirs["home"] == home_of(NEIGHBOUR, THEIRS),
               "another person's kept program runs on a disk of their own, under another uid", [a, theirs])
        apart_from = sh(c, NEIGHBOUR, f'command -v their-tool || echo none; ls -A /work | wc -l; '
                                      f'for p in "{a["home"]}/kept.txt" "{disk_of(OWNER)}/work" "{KEPT_ROOT}/.disks"; do '
                                      f'cat "$p" >/dev/null 2>&1 || ls "$p" >/dev/null 2>&1 && echo "reached $p" || echo "no $p"; done',
                        program="kept", key="t", home_id=THEIRS)
        expect(apart_from["stdout"] == f"none\n0\nno {a['home']}/kept.txt\nno {disk_of(OWNER)}/work\nno {KEPT_ROOT}/.disks\n",
               "another person's program has no tool of the person's, an empty /work, and reaches neither the "
               "person's sign-in, their /work nor the disks' records", apart_from)

        # ————— no session reaches the kept homes' root, on the kernel's own table —————
        for owner, program, key, row, who in [(OWNER, "probe", "a", SHARED, a), (NEIGHBOUR, "kept", "t", THEIRS, theirs)]:
            volume, under, roots = kept_mounts(c, owner, program, key, row, who["home"])
            person = disk_of(owner).rsplit("/", 1)[1]
            expect([m for _r, m in volume] == sorted([who["home"], "/work"])
                   and all(r.endswith(f"/{person}/programs/{row}") for r, m in volume if m == who["home"])
                   and all(r.endswith(f"/{person}/work") for r, m in volume if m == "/work")
                   and under == [who["home"]],
                   f"{owner['athanor']}'s session holds the kept volume as its own home and its disk's /work alone",
                   [volume, under])
            expect(not any("/.disks" in r or ("/programs/" in r and not r.endswith(f"/programs/{row}")) for r in roots),
                   f"{owner['athanor']}'s session holds no record, no other home and no other disk of the volume", roots)
            seen = sh(c, owner, f'ls -A {KEPT_ROOT}; ls -A {disk_of(owner)}; ls -A {disk_of(owner)}/programs',
                      program=program, key=key, home_id=row)
            expect(seen["stdout"] == f"{person}\nprograms\n{row}\n",
                   f"under the root {owner['athanor']}'s session sees the path to its own home alone", seen)
        owned = stack.observe(f'stat -c "%u %a" {disk_of(OWNER)} {disk_of(OWNER)}/work {KEPT_ROOT}/.disks; '
                              f'stat -c "%u %a" {KEPT_ROOT}/.disks/{disk_of(OWNER).rsplit("/", 1)[1]}.json')
        expect(owned.stdout == f"{a['uid']} 700\n{a['uid']} 700\n0 700\n0 600\n",
               "the disk and its work folder are the person's uid's, 0700; the records' folder and the person's "
               "record are the keeper's alone", owned.stdout + owned.stderr)

        # ————— two rows of one program: nothing crosses their homes —————
        own = whoami(c, OWNER, key="own", home_id=BROWSER)
        apart = whoami(c, OWNER, key="apart", home_id=APART)
        expect(own["uid"] == apart["uid"] == a["uid"] and own["home"] != apart["home"]
               and {own["home_mode"], apart["home_mode"]} == {"700"},
               "two rows of one program run in two homes, 0700, of the person's disk, under its one uid", [own, apart])
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
            # Another row's home is not in a row's space at all.
            expect(out.count("No such file or directory") == 4 and "rc=0" not in out and "-cookie" not in out
                   and "-store" not in out,
                   f"the {key} row neither reads, lists nor writes the other's cookies and storage", out)
        mine = sh(c, OWNER, 'cat "$HOME/profile/Default/Cookies"', key="apart", home_id=APART)
        expect(mine["stdout"] == "apart-cookie\n", "each row reads its own profile", mine)
        for key, home in [("own", BROWSER), ("apart", APART)]:
            c.close(OWNER, c.mcp(OWNER, "probe", key=key, home_id=home).session)

        # ————— the disk bound —————
        capped = whoami(c, OWNER, "capped", home_id=CAPPED)
        capped_process = stack.outside(capped)
        expect(capped["uid"] == a["uid"] and capped["home"] == home_of(OWNER, CAPPED),
               "another program's home is on the person's disk, under its uid", [a["uid"], capped["uid"]])
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
        eventually(lambda: not any(p["pid"] == capped_process["pid"] for p in stack.processes()),
                   "the capped session's process to end past the cap")
        expect(whoami(c, OWNER, key="a", home_id=SHARED)["pid"] == again["pid"],
               "ending the capped home's sessions leaves the person's other program running under the uid")
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
        expect(retiring["uid"] == a["uid"], "the retired row's home is on the person's disk too", retiring)
        sh(c, OWNER, 'echo gone > "$HOME/file"; (trap "" TERM; exec sleep 100000) >/dev/null 2>&1 &', key="r",
           home_id=RETIRED)
        expect(any("sleep 100000" in p["cmd"] for p in stack.under_uid(a["uid"])), "the row's detached process runs")
        client = c.mcp(OWNER, "probe", key="r", home_id=RETIRED)
        status, retired, _ = c.home(OWNER["athanor"], RETIRED, "retire")
        expect((status, retired) == (200, {"version": VERSION, "home_id": RETIRED, "state": "absent"}),
               "a retire answers the home absent", retired)
        eventually(lambda: not any("sleep 100000" in p["cmd"] for p in stack.processes()),
                   "the retired program's processes to end, a detached one included")
        expect(home_gone(stack, retiring["home"]), "the retired home's folder is gone")
        status, answer = c.recv(OWNER, client.session, client.after, 0)
        expect(status == 200 and answer["running"] is False, "the retired home's session answers running: false",
               answer)
        survivor = whoami(c, OWNER, key="a", home_id=SHARED)
        kept = sh(c, OWNER, 'cat "$HOME/kept.txt"; their-tool', key="a", home_id=SHARED)
        expect(survivor["pid"] == again["pid"] and survivor["uid"] == a["uid"] and not home_gone(stack, a["home"])
               and kept["stdout"] == "kept-value\nshared-tool\n",
               "retiring one row's home leaves the person's other program running, with its home, /work and the uid",
               [survivor, kept])

        # ————— a disk with no row keeps /work and its uid through the sweeps and a restart —————
        for row in [SHARED, BROWSER, APART, CAPPED, SIGNED]:
            status, retired, _ = c.home(OWNER["athanor"], row, "retire")
            expect((status, retired["state"]) == (200, "absent"), f"{row}'s home is retired", retired)
        eventually(lambda: not stack.under_uid(a["uid"]), f"no process of uid {a['uid']} once every row is retired")
        expect(stack.observe(f"test -d {disk_of(OWNER)}/work && ls -A {disk_of(OWNER)}/programs | wc -l").stdout
               == "0\n", "the disk holds no home and keeps its work folder")
        # The service's sweep runs every second and the keeper's sweeper with it: a few of them pass.
        time.sleep(3)  # sleep-ok: the sweeps tick each second, and nothing observable says one has passed
        run("docker", "restart", stack.container)
        stack.published()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the service is greeted after its restart")
        status, answer, _ = c.sync(OWNER, PROGRAMS)
        expect(status == 200, "the owner is synced again", answer)
        back = whoami(c, OWNER, key="back", home_id=BACK)
        tool = sh(c, OWNER, "their-tool", key="back", home_id=BACK)
        expect(back["uid"] == a["uid"] and back["home"] == home_of(OWNER, BACK) and tool["stdout"] == "shared-tool\n",
               "the person's next program, after the sweeps and a restart, is on their disk under the same uid and "
               "finds the tool they installed", [back, tool])
    finally:
        stack.down()


if __name__ == "__main__":
    main()
