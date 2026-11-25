#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A pooled uid of the backends image hands nothing to its next holder.

Run as docker-compose.yml's locus-backends service with a pool of one uid,
and driven only by requests signed as CYFR signs them (harness.py):

- Outside its home a program's process writes only its space's own /tmp,
  /var/tmp, /dev/shm and /run, which end with the space: the homes' root
  is read-only there and holds its own home alone, and neither the kept
  homes' root, the release's run directory nor the container's mqueue
  mount is in its space.
- The System V shared memory, semaphore set and message queue and the
  POSIX message queue it opens by name (tests/fixtures/residue-canary.go)
  are its space's own: the space has an IPC namespace of its own, the
  container's holds none of them, and the namespace, every object in it,
  is gone with the space's last process.
- Nothing of the space outlives it but its home, which is gone, with every
  process of its uid, once its owner is released, before a second owner
  runs under the same uid, who finds nothing the first left; and the
  keeper logs no quarantine.
- cyfr-locus refuses to start where a pooled uid could write a shared
  location: a writable root, a shared /tmp, Docker's default /dev/shm.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/residue.py IMAGE
"""

import json
import os
import re
import shutil
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    HOME_ROOT, KEPT_FIRST, KEPT_LAST, KEPT_ROOT, POOL_FIRST, PROBE, RELEASE, RELEASE_BIN, ROLE,
    RUN_DIR, Stack, build_canary, eventually, expect, owner_of, probe, require_docker, run,
)
import imagesuite  # noqa: E402
from imagesuite import read_listing, read_output, run_name  # noqa: E402

UID = POOL_FIRST
TAG = "locus-backends-residue"
SHARED = [f"/tmp/{TAG}", f"/var/tmp/{TAG}", f"/dev/shm/{TAG}", f"/run/{TAG}", f"{RUN_DIR}/{TAG}"]
LEFT = [f"{HOME_ROOT}/{TAG}", f"{HOME_ROOT}/{TAG}-tree/", f"{KEPT_ROOT}/{TAG}"]
IPC = ["shm", "sem", "msg", "mqueue"]
# A queue made by its path in the container's mqueue mount, not by mq_open.
MOUNT_QUEUE = f"/dev/mqueue/{TAG}-mount"


def held_by_uid(stack):
    """What the kernel holds for the uid, read as root inside the container: its rows, or none.

    Each read exits 3 when it fails, and the answer is the word `absent` only
    from a command that exits 0 (read_listing).
    """
    script = f"""
      home="$(find {HOME_ROOT} {KEPT_ROOT} /dev/mqueue -mindepth 1 -maxdepth 1 -user {UID})" || exit 3
      ipc="$(for t in shm sem msg; do
          awk -v u={UID} 'NR == 1 {{ for (i = 1; i <= NF; i++) h[i] = $i; next }}
            {{ for (i = 1; i <= NF; i++) if ((h[i] == "uid" || h[i] == "cuid") && $i == u) {{ print FILENAME ": " $2; next }} }}' \\
            /proc/sysvipc/$t || exit 3
        done)" || exit 3
      if [ -n "$home$ipc" ]; then
        echo present
        printf '%s\\n' "$home" "$ipc" | sed '/^$/d'
      else
        echo absent
      fi"""
    return read_listing(stack.exec(script), f"what the kernel holds for uid {UID}")


def ipc_namespace(stack, pid):
    """The IPC namespace of `pid`, `ipc:[inode]`, read by the observer from a command that exits 0."""
    return read_output(stack.observe(f"readlink /proc/{pid}/ns/ipc"), f"the IPC namespace of pid {pid}").strip()


def namespace_holders(stack, namespace):
    """Every process of the container whose IPC namespace is `namespace` or that holds a descriptor of it, read by
    the observer; a namespace no process holds is freed by the kernel with every object in it."""
    script = f"""
      for d in /proc/[0-9]*; do
        for l in "$d/ns/ipc" "$d"/fd/*; do
          [ "$(readlink "$l" 2>/dev/null)" = '{namespace}' ] && echo "${{d#/proc/}}"
        done
      done | sort -u"""
    return read_output(stack.observe(script), f"the holders of {namespace}").split()


def sync_probe(c, owner):
    status, answer, _ = c.sync(owner, [probe()])
    expect(status == 200, f"{owner['athanor']} is synced", answer)
    c.running(owner)
    report = c.report(owner)
    expect([(p["status"], p["sessions"]) for p in report["programs"]] == [("idle", 0)],
           f"{owner['athanor']}'s program is defined and nothing of it runs yet", report)
    who = c.tool(owner, "probe__whoami")
    expect(c.program(owner)["status"] == "running", f"{owner['athanor']}'s first call started its program")
    return who


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
            f"/tmp/{TAG}": "ok", f"/var/tmp/{TAG}": "ok", f"/dev/shm/{TAG}": "ok", f"/run/{TAG}": "ok",
            f"{RUN_DIR}/{TAG}": "ENOENT", f"{HOME_ROOT}/{TAG}": "EROFS", f"{HOME_ROOT}/{TAG}-tree/": "EROFS",
            f"{KEPT_ROOT}/{TAG}": "ENOENT",
        }, "outside its home a program writes only its space's own /tmp, /var/tmp, /dev/shm and /run", planted)
        for kind in IPC:
            expect(planted[kind] == "ok", f"the backend leaves a {kind} object", planted)
        mounted = c.tool(owner_of("first"), "probe__run", {"argv": ["touch", MOUNT_QUEUE]})
        expect(mounted["status"] != 0, "the container's mqueue mount is not in the backend's space", mounted)

        # The objects are its space's: the backend finds them, in an IPC
        # namespace that is not the container's, and the container's own
        # namespace holds none of them.
        found = canary(c, owner_of("first"), "probe")
        for kind in IPC:
            expect(found[kind] == "present", f"the backend finds its {kind} object in its space", found)
        leader = [p for p in stack.under_uid(UID) if p["cmd"].strip() == PROBE]
        expect(len(leader) == 1, "the first owner's program runs, as the container numbers it", leader)
        space = ipc_namespace(stack, leader[0]["pid"])
        expect(space and space != ipc_namespace(stack, 1), "the backend's space has an IPC namespace of its own", space)
        held = held_by_uid(stack)
        expect(not any(line.startswith("/proc/sysvipc/") for line in held) and f"/dev/mqueue/{TAG}" not in held,
               "the container's own namespace holds none of the space's IPC objects", held)
        expect(held == [first["home"]], "outside its space the kernel holds for the uid its home alone", held)

        status, _answer, _ = c.release([owner_of("first")])
        expect(status == 200, "the first owner is released")
        eventually(lambda: not stack.under_uid(UID), f"no process of uid {UID}")
        expect(namespace_holders(stack, space) == [],
               "no process holds the space's IPC namespace: it is gone with every object in it",
               namespace_holders(stack, space))
        eventually(lambda: not held_by_uid(stack), f"nothing held by uid {UID}")

        second = sync_probe(c, owner_of("second"))
        expect(second["uid"] == UID, "the second owner runs under the released uid", second)
        probed = canary(c, owner_of("second"), "probe")
        expect(probed["uid"] == UID and probed["files"] == {
            f"/tmp/{TAG}": "absent", f"/var/tmp/{TAG}": "absent", f"/dev/shm/{TAG}": "absent", f"/run/{TAG}": "absent",
            f"{RUN_DIR}/{TAG}": "absent", f"{HOME_ROOT}/{TAG}": "absent", f"{HOME_ROOT}/{TAG}-tree/": "absent",
            f"{KEPT_ROOT}/{TAG}": "absent",
        }, "nothing the first owner left reaches the second", probed)
        for kind in IPC:
            expect(probed[kind] == "absent", f"no {kind} object reaches the second owner", probed)
        queue = c.tool(owner_of("second"), "probe__run", {"argv": ["test", "-e", MOUNT_QUEUE]})
        expect(queue["status"] == 1, "no queue of the container's mount reaches the second owner", queue)
        expect(held_by_uid(stack) == [second["home"]], "the uid holds the second owner's home and nothing else",
               held_by_uid(stack))
        logs = stack.logs()
        expect(not re.search(r"quarantined|outlived retirement|could not be removed", logs),
               "cyfr-locus retired the uid cleanly", logs[-3000:])

        settings = ["--rm", "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "KILL",
                    "--security-opt", "no-new-privileges:true", "-e", f"LOCUS_BACKENDS_KEY={stack.key.hex()}",
                    *imagesuite.role_mounts(RELEASE, ROLE),
                    "--entrypoint", "cyfr-locus"]
        command = ["serve", "--role", imagesuite.role_spec(ROLE), "--pool", f"{ROLE['pool']}:{UID}-{UID}:{ROLE['reach']}",
                   "--home-root", RELEASE["home_root"], "--kept-homes", f"{KEPT_ROOT}:{KEPT_FIRST}-{KEPT_LAST}",
                   "--guard", imagesuite.Guard.CONTROL, "--", RELEASE_BIN, "start"]
        for n, (flags, refusal) in enumerate([
            (["--ipc", "none"], r"the root filesystem is writable"),
            (["--read-only", "--ipc", "none", "--tmpfs", "/tmp:mode=1777"], r"mount /tmp .* is writable by pooled uids"),
            (["--read-only"], r"mount /dev/shm .* is writable by pooled uids"),
        ]):
            result = run("docker", "run", *run_name(f"{stack.project}-refusal-{n}"), *settings, *flags, image, *command,
                         check=False)
            expect(result.returncode == 78 and re.search(refusal, result.stderr),
                   f"cyfr-locus refuses to start with {' '.join(flags)}", result.stderr[-2000:])
    finally:
        stack.down()
        shutil.rmtree(canary_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
