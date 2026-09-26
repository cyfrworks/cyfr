#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends image runs a stdio backend end to end, as docker-compose.yml's locus-backends service.

Driven only by requests signed as CYFR signs them (harness.py):

- `hello` learns the service's lifetime and pool, and `reconcile` of
  nothing keeps nothing.
- A synced owner's probe backend starts, the owner is reported running,
  and its tools are listed as `<backend>__<tool>`, every result naming the
  service (`cyfr-locus`) in its `_meta`.
- The backend's sealed credential reaches its environment and never leaves
  the service: a result, a tool's error, a command's output, the stderr tail
  a status reports and the service's own log carry `[REDACTED]` where it
  was; a literal variable is not masked.
- A backend no call used within the owner's idle period is retired: its
  process and uid gone, its tools still listed, reported `idle`; the next
  call wakes it under a new process, and it is ready again.
- A released owner runs nothing, and an invoke for it is `unknown_owner`.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/e2e.py IMAGE
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    POOL_FIRST, POOL_LAST, STATUSES, Stack, eventually, expect, owner_of, probe, require_docker,
)

SECRET = "e2e-backend-secret-0123456789"
LITERAL = "debug-literal-kept"
IDLE_MS = 3_000
OWNER = owner_of("e2e")


def text_of(answer):
    return json.dumps(answer)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: e2e.py IMAGE")
    require_docker()
    stack = Stack("locus-backends-e2e", sys.argv[1])
    try:
        stack.up()
        c = stack.controller()

        status, hello, boot = c.hello()
        expect(status == 200 and hello["boot"] == boot and hello["pool"] == {"size": POOL_LAST - POOL_FIRST + 1,
                                                                            "free": POOL_LAST - POOL_FIRST + 1},
               "hello names the service's lifetime and its whole pool free", hello)
        status, reconciled, _ = c.reconcile([])
        expect(status == 200 and reconciled["released"] == [], "a reconcile of nothing keeps nothing", reconciled)

        env = {"PROBE_SECRET": SECRET, "LOG_LEVEL": LITERAL}
        status, synced, _ = c.sync(OWNER, [probe(env=env)], idle_ms=IDLE_MS)
        expect(status == 200 and synced["backends"][0]["name"] == "probe",
               "a sync of one probe backend is admitted at once", synced)
        c.running(OWNER)
        report = c.report(OWNER)
        expect(report["backends"][0]["status"] == "ready" and report["e"] == OWNER["e"],
               "the owner runs at its version, its backend ready", report)

        status, listed, _, _ = c.invoke(OWNER, "tools/list")
        names = sorted(tool["name"] for tool in listed["result"]["tools"])
        expect(status == 200 and "probe__whoami" in names and "probe__echo_env" in names,
               "the backend's tools are listed as <backend>__<tool>", names)
        server = listed["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]
        expect(server["name"] == "cyfr-locus", "every result names the service", server)

        who = c.tool(OWNER, "probe__whoami")
        environ = stack.exec(f"tr '\\0' '\\n' < /proc/{who['pid']}/environ", user=str(who["uid"])).stdout
        expect(f"PROBE_SECRET={SECRET}" in environ, "the sealed credential reaches the backend's environment")

        # Every way out of the service masks it.
        echoed = c.tool(OWNER, "probe__echo_env", {"name": "PROBE_SECRET", "stderr": True})
        expect(echoed == {"value": "[REDACTED]"}, "a result carries the credential masked", echoed)
        literal = c.tool(OWNER, "probe__echo_env", {"name": "LOG_LEVEL"})
        expect(literal == {"value": LITERAL}, "a literal variable is not masked", literal)

        status, failed = c.call(OWNER, "probe__fail", {"name": "PROBE_SECRET"})
        expect(status == 200 and SECRET not in text_of(failed) and "[REDACTED]" in text_of(failed),
               "a tool's error carries the credential masked", failed)

        ran = c.tool(OWNER, "probe__run", {"argv": ["/bin/sh", "-c",
                                                    'echo "$PROBE_SECRET"; echo "Bearer $PROBE_SECRET" >&2']})
        expect(SECRET not in text_of(ran) and ran["stdout"].strip() == "[REDACTED]"
               and ran["stderr"].strip() == "Bearer [REDACTED]",
               "a command's output carries the credential masked, whole and after a scheme", ran)

        report = eventually(lambda: (lambda r: r if "[REDACTED]" in r["backends"][0]["stderr_tail"] else None)(
            c.report(OWNER)), "the stderr tail to hold the masked credential")
        expect(SECRET not in text_of(report), "a status's stderr tail carries the credential masked",
               report["backends"][0]["stderr_tail"][-400:])

        # Idle: no call for the idle period retires the process and keeps the tools.
        uid, pid = who["uid"], who["pid"]
        idle = eventually(lambda: (lambda r: r if r["backends"][0]["status"] == "idle" else None)(c.report(OWNER)),
                          "the backend to be retired idle", timeout_s=IDLE_MS / 1000 + 20)
        expect(idle["backends"][0]["tools"] > 0, "an idle backend keeps its tools", idle)
        eventually(lambda: not stack.under_uid(uid), f"no process of uid {uid} once idle")
        status, listed, _, _ = c.invoke(OWNER, "tools/list")
        expect(status == 200 and "probe__whoami" in [t["name"] for t in listed["result"]["tools"]],
               "an idle backend's tools stay listed", listed)

        woken = c.tool(OWNER, "probe__whoami")
        expect(woken["pid"] != pid and POOL_FIRST <= woken["uid"] <= POOL_LAST,
               "the next call wakes the backend under a new process", woken)
        report = c.report(OWNER)
        expect(report["backends"][0]["status"] == "ready", "a woken backend is ready", report)

        status, released, _ = c.release([OWNER])
        expect(status == 200 and [(o["server"], o["e"]) for o in released["released"]] == [(OWNER["server"],
                                                                                          OWNER["e"])],
               "a release names the version it released", released)
        eventually(lambda: not stack.pool_processes(), "no pooled process once released")
        status, refused, _, _ = c.invoke(OWNER, "tools/list")
        expect(status == STATUSES["unknown_owner"] and refused == {"version": 1, "error": "unknown_owner"},
               "an invoke for a released owner is unknown_owner", refused)

        time.sleep(1)
        expect(SECRET not in stack.logs(), "the credential never reaches the service's log")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
