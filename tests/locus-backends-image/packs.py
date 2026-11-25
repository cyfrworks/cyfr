#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A person's packs are a read-only folder of their sessions' space, the keeper's one copy.

Run as docker-compose.yml's locus-backends service, its kept homes on the
shipped `homes` volume under the keeper's `--kept-homes`, under the shipped
AppArmor profile, and driven only by requests signed as CYFR signs them
(harness.py), as Opus starts a program that loads packs
(`Opus.Programs.Session`):

- An empty home: a first start's `packs_hold` is answered `missing`, its
  `packs_put`s are taken, the last `held`, and its one open, naming the
  digest, runs in that very lifetime: the hold and the put spent nothing of
  it.
- The warm path: a second start's hold is answered `held` and puts
  nothing; the generation's folder is the one the first put wrote.
- The folder: a session's /run/cyfr/scrolls holds the packs as written,
  byte for byte, each file read only and the executable one runnable; a
  write, a new folder and a rename there fail; its mount is read only.
- Another person: their hold of the same digest is `missing`, an open
  naming it without a put of their own is refused, and their session sees
  no /run/cyfr/scrolls; with a generation of their own their session
  binds theirs alone, and this person's digest is still missing to them
  and refused; a row that loads no packs is refused a hold and
  its session sees none.
- A kept root that cannot take the packs' folder (a file in its place)
  leaves the keeper starting and serving a program that loads no packs: a
  hold there finds nothing, and a put is refused `unavailable`, the keeper
  saying why. Once the place is free, the first put makes the folder.
- The keeper holds the copy outside every home, the keeper's own, mode
  0555 for its folders: a pooled uid's space and the backends role's user
  reach none of it.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/packs.py IMAGE
"""

import hashlib
import io
import json
import os
import sys
import tarfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    KEPT_ROOT, RELEASE_USER, STATUSES, VERSION, Stack, expect, new_lifetime, owner_of, probe, require_docker,
)
from imagesuite import read_output, run  # noqa: E402

OWNER, OTHER = owner_of("packs"), owner_of("other")
HOME, OTHER_HOME, PLAIN_HOME = "mcp_packs-home", "mcp_other-home", "mcp_packs-plain"
FILES = {
    "pstack/skills/poteto-mode/SKILL.md": (b"---\nname: poteto-mode\n---\n# poteto\n", False),
    "pstack/skills/poteto-mode/scripts/hello": (b"#!/bin/sh\necho hello from a pack\n", True),
    "taste/skills/taste/SKILL.md": (b"# taste\n" + b"x" * (700 * 1024), False),
}
# The other person's own packs: the same paths, other bytes.
OTHER_FILES = {
    "pstack/skills/poteto-mode/SKILL.md": (b"---\nname: poteto-mode\n---\n# the other person's\n", False),
}
PROGRAMS = [probe(home="kept", packs=True), probe("plain", home="kept")]


def digest_of(files):
    """A set digest as the control plane names one: here, any digest of the files."""
    return "sha256:" + hashlib.sha256(json.dumps(sorted((p, d.hex()) for p, (d, _x) in files.items())).encode()).hexdigest()


def stream_of(files):
    """The generation's stream: the manifest first, then each file, as Compendium writes it."""
    lines = [{"path": path, "size": len(data), "sha256": "sha256:" + hashlib.sha256(data).hexdigest(),
              "executable": executable} for path, (data, executable) in sorted(files.items())]
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        def add(name, data, mode):
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(data), mode
            tar.addfile(info, io.BytesIO(data))
        add(".cyfr-packs.json", json.dumps({"files": lines}).encode(), 0o644)
        for path, (data, executable) in sorted(files.items()):
            add(path, data, 0o755 if executable else 0o644)
    return out.getvalue()


def refusal(code):
    return STATUSES[code], {"version": VERSION, "error": code}


def run_in(client, script):
    """`script` run by `sh -c` in the client's session: its result."""
    status, answer = client.call("run", {"argv": ["/bin/sh", "-c", script]})
    result = (answer or {}).get("result") or {}
    if status != 200 or result.get("isError") or "content" not in result:
        sys.exit(f"FAIL: {script}: {status} {answer}")
    return json.loads(result["content"][0]["text"])


def started(c, owner, key, home_id, digest, program="probe", files=FILES):
    """A start as Opus makes one: a lifetime of its own held, put on `missing`, then the one open naming it.

    Answers the hold's state, every put's answer, and the session's client.
    """
    lifetime = new_lifetime(c.boot)
    status, held = c.packs_hold(owner, program, lifetime, digest, key=key, home_id=home_id)
    expect(status == 200, f"a hold of {owner['athanor']} is answered", held)
    puts = []
    if held["state"] == "missing":
        puts = c.packs_put(owner, program, lifetime, digest, stream_of(files), key=key, home_id=home_id)
    client = c.mcp(owner, program, key=key, home_id=home_id)
    client.opening = {"lifetime": lifetime, "packs": digest}
    return held["state"], puts, client


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: packs.py IMAGE")
    require_docker()
    stack = Stack("locus-backends-packs", sys.argv[1])
    try:
        stack.up()

        # ————— a kept root that cannot take the packs' folder —————
        # A file where the folder would be, as a kept root that cannot take
        # it: the keeper still starts, a program that loads no packs runs, a
        # hold finds nothing and a put is refused, saying why.
        blocker = f"{KEPT_ROOT}/.packs"
        expect(stack.exec(f"touch {blocker}").returncode == 0, "a file takes the packs' folder's place")
        run("docker", "restart", stack.container)
        stack.published()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the keeper starts with a kept root that cannot take the packs' folder")
        status, answer, _ = c.sync(OWNER, PROGRAMS)
        expect(status == 200, "a program that loads packs and one that loads none are synced", answer)
        plain = c.mcp(OWNER, "plain", key="early", home_id=PLAIN_HOME)
        ran = run_in(plain, "echo served")
        expect(ran["stdout"] == "served\n", "a program that loads no packs is served", ran)
        lifetime = new_lifetime(c.boot)
        digest = digest_of(FILES)
        status, held = c.packs_hold(OWNER, "probe", lifetime, digest, key="early", home_id=HOME)
        expect((status, held.get("state")) == (200, "missing"), "a hold there finds nothing", held)
        puts = c.packs_put(OWNER, "probe", lifetime, digest, stream_of(FILES), key="early", home_id=HOME)
        expect(puts[-1] == refusal("unavailable") and len(puts) == 1,
               "the put is refused unavailable at its first part", puts)
        expect("the packs' folder cannot be made" in stack.logs(), "the keeper says why it refused the put")
        expect(stack.exec(f"rm {blocker}").returncode == 0, "the file is taken away")
        for owner in (OTHER,):
            status, answer, _ = c.sync(owner, PROGRAMS)
            expect(status == 200, f"{owner['athanor']}'s programs are synced, one loading packs", answer)
        person = hashlib.sha256(OWNER["athanor"].encode()).hexdigest()
        generation = f"{KEPT_ROOT}/.packs/{person}/{digest[7:]}"

        # ————— an empty home: missing, put, one open in that lifetime —————
        state, puts, first = started(c, OWNER, "a", HOME, digest)
        expect(state == "missing", "a first start finds its person's packs missing")
        expect(len(puts) >= 2 and all(s == 200 for s, _a in puts)
               and [a["state"] for _s, a in puts] == ["taken"] * (len(puts) - 1) + ["held"],
               "its put's parts are taken, the last held", puts)
        listing = run_in(first, "find /run/cyfr/scrolls -type f | sort; echo; "
                             "find /run/cyfr/scrolls -type f | sort | xargs sha256sum")
        expect(first.resumed is False, "the one open starts the program in the lifetime the hold and the put named")
        want = sorted(f"/run/cyfr/scrolls/{p}" for p in FILES)
        names, sums = listing["stdout"].split("\n\n", 1)
        expect(names.split() == want, "the session's folder holds the packs as written, no record among them", names)
        for path, (data, _x) in FILES.items():
            expect(f"{hashlib.sha256(data).hexdigest()}  /run/cyfr/scrolls/{path}" in sums,
                   f"{path} is the bytes put", sums)

        # ————— the folder is read only —————
        tried = run_in(first,
                       "/run/cyfr/scrolls/pstack/skills/poteto-mode/scripts/hello; "
                       "stat -c '%a %U' /run/cyfr/scrolls/pstack /run/cyfr/scrolls/pstack/skills/poteto-mode/SKILL.md "
                       "/run/cyfr/scrolls/pstack/skills/poteto-mode/scripts/hello; "
                       "touch /run/cyfr/scrolls/pstack/new 2>&1; echo rc=$?; "
                       "mkdir /run/cyfr/scrolls/pstack/skills/poteto-mode/scripts/node_modules 2>&1; echo rc=$?; "
                       "mv /run/cyfr/scrolls/taste /run/cyfr/scrolls/gone 2>&1; echo rc=$?; "
                       "sh -c 'echo x >> /run/cyfr/scrolls/taste/skills/taste/SKILL.md' 2>&1; echo rc=$?; "
                       "grep ' /run/cyfr/scrolls ' /proc/self/mountinfo")
        out = tried["stdout"]
        expect(out.startswith("hello from a pack\n"), "a pack's executable runs from the folder", out)
        expect("555 " in out and "444 " in out, "its folders are 0555 and its files 0444 or 0555", out)
        # An append meets the file's own 0444 first; the mount refuses the rest.
        expect(out.count("Read-only file system") == 3 and "Permission denied" in out and "rc=0" not in out,
               "a new file, a new folder and a rename fail read only, and an append is refused", out)
        mount = [line for line in out.splitlines() if " /run/cyfr/scrolls " in line]
        expect(len(mount) == 1 and " ro," in mount[0], "the folder is a read-only mount of the space", mount)

        # ————— the warm path: held, nothing put, the same copy —————
        stamp = f"stat -c '%i %Y' {generation}"
        before = read_output(stack.exec(stamp), "the copy's inode and time")
        state, puts, second = started(c, OWNER, "b", HOME, digest)
        expect(state == "held" and puts == [], "a second start is held and puts nothing")
        again = run_in(second, "cat /run/cyfr/scrolls/pstack/skills/poteto-mode/SKILL.md")
        expect(again["stdout"] == FILES["pstack/skills/poteto-mode/SKILL.md"][0].decode(),
               "the second session reads the same packs", again)
        expect(read_output(stack.exec(stamp), "the copy's inode and time again") == before and before,
               "the warm start moved no file of the copy", before)

        # ————— another person, and a row that loads none —————
        lifetime = new_lifetime(c.boot)
        status, held = c.packs_hold(OTHER, "probe", lifetime, digest, key="a", home_id=OTHER_HOME)
        expect((status, held.get("state")) == (200, "missing"),
               "another person's hold of the same digest finds nothing of theirs", held)
        status, answer = c.open(OTHER, "probe", key="a", home_id=OTHER_HOME, lifetime=lifetime, packs=digest)
        expect(status != 200, "another person's open naming a generation they never put is refused", answer)
        theirs = c.mcp(OTHER, "probe", key="b", home_id=OTHER_HOME)
        seen = run_in(theirs, "ls /run/cyfr/scrolls 2>&1; ls " + KEPT_ROOT + " 2>&1; echo done")
        expect("pstack" not in seen["stdout"] and "No such file or directory" in seen["stdout"],
               "another person's session sees no packs and no kept root", seen)
        # With a generation of their own, the other person binds theirs and
        # never this person's: not by this person's digest, which they hold
        # none of, nor beside their own.
        other_digest = digest_of(OTHER_FILES)
        state, _puts, own = started(c, OTHER, "c", OTHER_HOME, other_digest, files=OTHER_FILES)
        expect(state == "missing", "the other person's first start puts their own packs")
        seen = run_in(own, "cat /run/cyfr/scrolls/pstack/skills/poteto-mode/SKILL.md; ls /run/cyfr/scrolls")
        expect(seen["stdout"] == OTHER_FILES["pstack/skills/poteto-mode/SKILL.md"][0].decode() + "pstack\n",
               "the other person's session holds their own packs alone", seen)
        lifetime = new_lifetime(c.boot)
        status, held = c.packs_hold(OTHER, "probe", lifetime, digest, key="d", home_id=OTHER_HOME)
        expect((status, held.get("state")) == (200, "missing"),
               "holding a generation of their own, the other person finds nothing of this person's digest", held)
        status, answer = c.open(OTHER, "probe", key="d", home_id=OTHER_HOME, lifetime=lifetime, packs=digest)
        expect(status != 200, "the other person's open naming this person's digest is refused", answer)
        mine = run_in(second, "cat /run/cyfr/scrolls/pstack/skills/poteto-mode/SKILL.md")
        expect(mine["stdout"] == FILES["pstack/skills/poteto-mode/SKILL.md"][0].decode(),
               "this person's session still reads their own packs", mine)

        lifetime = new_lifetime(c.boot)
        status, answer = c.packs_hold(OWNER, "plain", lifetime, digest, key="p", home_id=PLAIN_HOME)
        expect((status, answer) == refusal("bad_request"), "a row that loads no packs is refused a hold", answer)
        plain = c.mcp(OWNER, "plain", key="p", home_id=PLAIN_HOME)
        seen = run_in(plain, "ls /run/cyfr/scrolls 2>&1; echo done")
        expect("No such file or directory" in seen["stdout"], "a row that loads no packs sees no folder", seen)

        # ————— the copy is the keeper's alone —————
        owned = read_output(stack.exec(f"stat -c '%a %u' {KEPT_ROOT}/.packs {KEPT_ROOT}/.packs/{person} {generation}"),
                            "the copy's modes and owners").split()
        expect(owned == ["711", "0", "711", "0", "555", "0"],
               "the store, the person's folder and the generation are root's, 0711 and 0555", owned)
        listed = stack.exec(f"ls {KEPT_ROOT}/.packs", user=RELEASE_USER)
        expect(listed.returncode != 0 and "Permission denied" in listed.stderr,
               f"{RELEASE_USER} cannot list the people's packs", [listed.returncode, listed.stderr])
        print("ok: a person's packs are a read-only folder of their sessions' space, written once, the keeper's own")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
