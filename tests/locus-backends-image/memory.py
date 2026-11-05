#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Every program's process in the backends image is held to its memory bound, alone.

Run as docker-compose.yml's locus-backends service with the service's own
bound (LOCUS_BACKENDS_MEMORY_BYTES) set low, and driven only by requests
signed as CYFR signs them (harness.py):

- Every session's process runs in a cgroup of its own whose memory.max is
  the bound, inside the container's own limit; a program whose row names
  its own `memory_bytes` is bounded at that instead.
- A process that holds less than its bound answers.
- A process that reaches past its bound is ended there by the kernel: its
  session ends before it answers, its status counts the crash and names
  the kill, and the next call starts the program again under a new
  process, initialized afresh; nothing of its uid outlives the kill but
  what the new start started.
- Its sibling, another owner's program, runs on untouched, and the service
  answers throughout.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/memory.py IMAGE
"""

import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    Stack, eventually, expect, owner_of, probe, require_docker, wait_healthy,
)
import imagesuite  # noqa: E402

BOUND = 128 * 1024 * 1024
# A row's own bound, which the service passes to the keeper in place of its own.
ROW_BOUND = 96 * 1024 * 1024
HOG, SIBLING, OWN = owner_of("hog"), owner_of("sibling"), owner_of("own")


def cgroup_limit(stack, pid):
    """The memory.max of the cgroup `pid` runs in, and that cgroup's path, read as root in the container."""
    path = imagesuite.read_output(stack.exec(f"sed -n 's/^0:://p' /proc/{pid}/cgroup"), f"the cgroup of pid {pid}").strip()
    limit = imagesuite.read_output(stack.exec(f"cat /sys/fs/cgroup{path}/memory.max"), f"memory.max of the cgroup {path}").strip()
    return path, limit


def container_limit(stack):
    """The container's own memory.max, which every backend's bound must sit inside."""
    return imagesuite.read_output(stack.exec("cat /sys/fs/cgroup/memory.max"), "the container's memory.max").strip()


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: memory.py IMAGE")
    require_docker()
    stack = Stack("locus-backends-memory", sys.argv[1])
    try:
        stack.up(memory_bytes=BOUND)
        c = stack.controller()
        expect(c.hello()[0] == 200, "the service is greeted")
        for owner in [HOG, SIBLING]:
            status, answer, _ = c.sync(owner, [probe()])
            expect(status == 200, f"{owner['athanor']} is synced", answer)
            c.running(owner)

        hog, sibling = c.tool(HOG, "probe__whoami"), c.tool(SIBLING, "probe__whoami")
        container = container_limit(stack)
        for name, who in [("hog", hog), ("sibling", sibling)]:
            path, limit = cgroup_limit(stack, who["pid"])
            expect(path not in ("", "/") and limit == str(BOUND),
                   f"the {name} backend runs in a cgroup of its own bounded at {BOUND} bytes", [path, limit])
        expect(container.isdigit() and int(container) > BOUND,
               "the bound sits inside the container's own limit", container)

        held = c.tool(HOG, "probe__hog", {"bytes": BOUND // 4})
        expect(held == {"held": BOUND // 4}, "a backend below its bound answers", held)

        client = c.mcp(HOG, "probe")
        status, answer = c.call(HOG, "probe__hog", {"bytes": BOUND * 2})
        expect(status == 200 and answer.get("ended") == "before_answer",
               "a call past the bound ends the session before the program answers", answer)
        eventually(lambda: not any(p["pid"] == hog["pid"] for p in stack.processes()),
                   "the kernel to end the process at its bound")

        crashed = eventually(lambda: (lambda p: p if p["restarts"] >= 1 and p["sessions"] == 0 else None)(
            c.program(HOG)), "the kill to be reported")
        expect(crashed["status"] == "idle" and "SIGKILL" in (crashed.get("error") or ""),
               "the program's status counts the crash, names the kill and runs nothing", crashed)
        initialized = client.initializations
        again = c.tool(HOG, "probe__whoami")
        expect(again["pid"] != hog["pid"] and client.initializations == initialized + 1 and client.resumed is False,
               "the next call starts the program again under a new process, initialized afresh", again)
        expect(c.program(HOG)["status"] == "running", "the program runs again")
        expect(cgroup_limit(stack, again["pid"])[1] == str(BOUND), "the restarted process is bounded again")
        leftover = [p for p in stack.under_uid(hog["uid"]) if hog["uid"] != again["uid"] or p["pid"] == hog["pid"]]
        expect(not leftover, "nothing of the killed process's uid outlives it but what the restart started", leftover)

        expect(c.tool(SIBLING, "probe__whoami")["pid"] == sibling["pid"], "the sibling runs on untouched")

        status, answer, _ = c.sync(OWN, [probe(memory_bytes=ROW_BOUND)])
        expect(status == 200, "a program whose row names its own bound is synced", answer)
        own = c.tool(OWN, "probe__whoami")
        expect(cgroup_limit(stack, own["pid"])[1] == str(ROW_BOUND),
               f"a row's own bound, {ROW_BOUND} bytes, bounds its process in place of the service's", own)
        wait_healthy(stack.base)
        expect(c.renew([{**HOG}, {**SIBLING}, {**OWN}])[0] == 200, "the service answers throughout")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
