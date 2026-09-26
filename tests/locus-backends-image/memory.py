#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Every backend of the backends image is held to LOCUS_BACKENDS_MEMORY_BYTES, alone.

Run as docker-compose.yml's locus-backends service with the per-backend
bound set low, and driven only by requests signed as CYFR signs them
(harness.py):

- Every backend's process runs in a cgroup of its own whose memory.max is
  the bound, inside the container's own limit.
- A backend that holds less than its bound answers.
- A backend that reaches past its bound is ended there by the kernel: its
  call fails as the backend's error, its status reports the kill, it
  restarts ready under a new process, and nothing of its uid outlives the
  kill but what the restart started.
- Its sibling, another owner's backend, runs on untouched, and the service
  answers throughout.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/memory.py IMAGE
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    Stack, eventually, expect, owner_of, probe, require_docker, wait_healthy,
)

BOUND = 128 * 1024 * 1024
HOG, SIBLING = owner_of("hog"), owner_of("sibling")


def cgroup_limit(stack, pid):
    """The memory.max of the cgroup `pid` runs in, and that cgroup's path, read as root in the container."""
    path = stack.exec(f"sed -n 's/^0:://p' /proc/{pid}/cgroup").stdout.strip()
    limit = stack.exec(f"cat /sys/fs/cgroup{path}/memory.max").stdout.strip()
    return path, limit


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
        container = stack.exec("cat /sys/fs/cgroup/memory.max").stdout.strip()
        for name, who in [("hog", hog), ("sibling", sibling)]:
            path, limit = cgroup_limit(stack, who["pid"])
            expect(path not in ("", "/") and limit == str(BOUND),
                   f"the {name} backend runs in a cgroup of its own bounded at {BOUND} bytes", [path, limit])
        expect(container.isdigit() and int(container) > BOUND,
               "the bound sits inside the container's own limit", container)

        held = c.tool(HOG, "probe__hog", {"bytes": BOUND // 4})
        expect(held == {"held": BOUND // 4}, "a backend below its bound answers", held)

        status, answer = c.call(HOG, "probe__hog", {"bytes": BOUND * 2})
        result = (answer or {}).get("result") or {}
        text = "".join(part.get("text", "") for part in result.get("content", []))
        expect(status == 200 and result.get("isError") and "SIGKILL" in text,
               "a call past the bound fails as the backend's error, naming the kill", answer)
        eventually(lambda: not any(p["pid"] == hog["pid"] for p in stack.processes()),
                   "the kernel to end the backend at its bound")

        # The kill is counted as a restart; the crash's reason is reported
        # until the restarted process is ready, which the failed call
        # already carried, so the count is what is waited for here.
        report = eventually(lambda: (lambda b: b if b["restarts"] >= 1 else None)(
            c.report(HOG)["backends"][0]), "the kill to be reported")
        restarted = eventually(lambda: (lambda b: b if b["status"] == "ready" else None)(c.report(HOG)["backends"][0]),
                               "the backend to restart ready", timeout_s=30)
        again = c.tool(HOG, "probe__whoami")
        expect(again["pid"] != hog["pid"] and restarted["restarts"] >= 1,
               "the backend restarts ready under a new process", [restarted, again])
        expect(cgroup_limit(stack, again["pid"])[1] == str(BOUND), "the restarted backend is bounded again")
        leftover = [p for p in stack.under_uid(hog["uid"]) if hog["uid"] != again["uid"] or p["pid"] == hog["pid"]]
        expect(not leftover, "nothing of the killed process's uid outlives it but what the restart started", leftover)

        expect(c.tool(SIBLING, "probe__whoami")["pid"] == sibling["pid"], "the sibling runs on untouched")
        wait_healthy(stack.base)
        expect(c.renew([{**HOG}, {**SIBLING}])[0] == 200, "the service answers throughout")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
