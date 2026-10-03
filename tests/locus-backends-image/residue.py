#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A pooled uid of the backends image hands nothing to its next holder.

Run as docker-compose.yml's locus-backends service with a pool of one uid,
and driven only by requests signed as CYFR signs them (harness.py):

- Outside its home a backend can write only into the home root, which it
  cannot list: /tmp, /var/tmp and /run are read-only, /dev/shm is absent and
  /run/locus is the release's.
- What it does leave (tests/fixtures/residue-canary.go) — an entry in the
  home root, a directory tree it made unwritable, System V shared memory, a
  semaphore set, a message queue and a POSIX message queue — is gone, with
  every process of its uid, once its owner is released, before a second
  owner runs under the same uid; and the keeper logs no quarantine.
- cyfr-keeper refuses to start where a pooled uid could write a shared
  location: a writable root, a shared /tmp, Docker's default /dev/shm.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/residue.py IMAGE
"""

import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    HOME_ROOT, POOL_FIRST, RELEASE_USER, RUN_DIR, Stack, build_canary, eventually, expect, owner_of, probe,
    require_docker, run,
)

UID = POOL_FIRST
TAG = "locus-backends-residue"
SHARED = [f"/tmp/{TAG}", f"/var/tmp/{TAG}", f"/dev/shm/{TAG}", f"/run/{TAG}", f"{RUN_DIR}/{TAG}"]
LEFT = [f"{HOME_ROOT}/{TAG}", f"{HOME_ROOT}/{TAG}-tree/"]
IPC = ["shm", "sem", "msg", "mqueue"]


def held_by_uid(stack):
    """What the kernel holds for the uid, read as root inside the container."""
    script = f"""
      find {HOME_ROOT} /dev/mqueue -mindepth 1 -maxdepth 1 -user {UID} 2>/dev/null
      for t in shm sem msg; do
        awk -v u={UID} 'NR == 1 {{ for (i = 1; i <= NF; i++) h[i] = $i; next }}
          {{ for (i = 1; i <= NF; i++) if ((h[i] == "uid" || h[i] == "cuid") && $i == u) {{ print FILENAME ": " $2; next }} }}' \\
          /proc/sysvipc/$t
      done"""
    return [line for line in stack.exec(script).stdout.splitlines() if line]


def sync_probe(c, owner):
    status, answer, _ = c.sync(owner, [probe()])
    expect(status == 200, f"{owner['athanor']} is synced", answer)
    c.running(owner)
    report = c.report(owner)
    expect([b["status"] for b in report["backends"]] == ["ready"], f"{owner['athanor']}'s backend is ready", report)
    return c.tool(owner, "probe__whoami")


def canary(c, owner, verb):
    answer = c.tool(owner, "probe__run", {"argv": ["/canary/canary", verb, TAG, *SHARED, *LEFT]})
    expect(answer["status"] == 0, f"the canary's {verb} ran", answer)
    return json.loads(answer["stdout"])


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: residue.py IMAGE")
    image = sys.argv[1]
    require_docker()
    canary_dir = build_canary()
    stack = Stack("locus-backends-residue", image, canary_dir)
    try:
        stack.up(pool=f"{UID}-{UID}")
        c = stack.controller()
        expect(c.hello()[0] == 200 and c.reconcile([])[0] == 200, "the service is greeted and reconciled")

        first = sync_probe(c, owner_of("first"))
        expect(first["uid"] == UID, "the first owner runs under the pool's one uid", first)
        planted = canary(c, owner_of("first"), "plant")
        expect(planted["uid"] == UID and planted["files"] == {
            f"/tmp/{TAG}": "EROFS", f"/var/tmp/{TAG}": "EROFS", f"/dev/shm/{TAG}": "ENOENT", f"/run/{TAG}": "EROFS",
            f"{RUN_DIR}/{TAG}": "EACCES", f"{HOME_ROOT}/{TAG}": "ok", f"{HOME_ROOT}/{TAG}-tree/": "ok",
        }, "outside its home a backend writes only into the home root", planted)
        for kind in IPC:
            expect(planted[kind] == "ok", f"the backend leaves a {kind} object", planted)

        held = held_by_uid(stack)
        expect(f"{HOME_ROOT}/{TAG}" in held and f"{HOME_ROOT}/{TAG}-tree" in held and f"/dev/mqueue/{TAG}" in held
               and all(any(line.startswith(f"/proc/sysvipc/{t}:") for line in held) for t in ["shm", "sem", "msg"]),
               "the kernel holds all of it for the uid", held)

        status, _answer, _ = c.release([owner_of("first")])
        expect(status == 200, "the first owner is released")
        eventually(lambda: not stack.under_uid(UID), f"no process of uid {UID}")
        eventually(lambda: not held_by_uid(stack), f"nothing held by uid {UID}")

        second = sync_probe(c, owner_of("second"))
        expect(second["uid"] == UID, "the second owner runs under the released uid", second)
        probed = canary(c, owner_of("second"), "probe")
        expect(probed["uid"] == UID and probed["files"] == {
            f"/tmp/{TAG}": "absent", f"/var/tmp/{TAG}": "absent", f"/dev/shm/{TAG}": "absent", f"/run/{TAG}": "absent",
            f"{RUN_DIR}/{TAG}": "denied", f"{HOME_ROOT}/{TAG}": "absent", f"{HOME_ROOT}/{TAG}-tree/": "absent",
        }, "nothing the first owner left reaches the second", probed)
        for kind in IPC:
            expect(probed[kind] == "absent", f"no {kind} object reaches the second owner", probed)
        expect(held_by_uid(stack) == [second["home"]], "the uid holds the second owner's home and nothing else",
               held_by_uid(stack))
        logs = stack.logs()
        expect(not re.search(r"quarantined|outlived retirement|could not be removed", logs),
               "cyfr-keeper retired the uid cleanly", logs[-3000:])

        settings = ["--rm", "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "KILL",
                    "--security-opt", "no-new-privileges:true", "-e", f"LOCUS_BACKENDS_KEY={stack.key.hex()}",
                    "--tmpfs", f"{HOME_ROOT}:mode=1733", "--tmpfs", f"{RUN_DIR}:uid=10001,gid=10001,mode=0700",
                    "--entrypoint", "cyfr-keeper"]
        command = ["serve", "--pool", f"backends:{UID}-{UID}", "--home-root", HOME_ROOT, "--client-user",
                   RELEASE_USER, "--", "/app/bin/locus", "start"]
        for flags, refusal in [
            (["--ipc", "none"], r"the root filesystem is writable"),
            (["--read-only", "--ipc", "none", "--tmpfs", "/tmp:mode=1777"], r"mount /tmp .* is writable by pooled uids"),
            (["--read-only"], r"mount /dev/shm .* is writable by pooled uids"),
        ]:
            result = run("docker", "run", *settings, *flags, image, *command, check=False)
            expect(result.returncode == 78 and re.search(refusal, result.stderr),
                   f"cyfr-keeper refuses to start with {' '.join(flags)}", result.stderr[-2000:])
    finally:
        stack.down()
        shutil.rmtree(canary_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
