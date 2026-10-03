#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends image refuses every request it cannot attribute, over the wire, before any state changes.

Run as docker-compose.yml's locus-backends service with a pool of three
uids, and driven only by requests signed as CYFR signs them (harness.py):

- A forged MAC and a timestamp outside the window are refused on both
  routes (`unauthorized`), answered before a large body is sent.
- A control message at or below the high-water mark is `stale_control`.
- An invoke at a stale epoch is `stale_epoch`, at a future one
  `epoch_ahead`, for an owner the service does not run `unknown_owner`.
- A nonce sent again is `replay`.
- A sync the uid pool cannot hold is `capacity` and spawns nothing, and a
  replacement that needs more than the pool frees starts nothing and
  leaves the owner it named as it ran.
- After `docker restart`, a captured invoke sent again, and a control
  message naming the old lifetime, are `stale_boot`.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/refusals.py IMAGE
"""

import os
import secrets
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    AUTH_HEADER, POOL_FIRST, ROUTES, STATUSES, WINDOW_MS, Controller, Stack, control_header, expect,
    now_ms, owner_of, probe, raw_head, require_docker, run,
)

POOL = [POOL_FIRST, POOL_FIRST + 1, POOL_FIRST + 2]
MAIN = owner_of("main", e=2)
UNAUTHORIZED_RPC = {"jsonrpc": "2.0", "id": None, "error": {"code": -33001, "message": "unauthorized"}}


def refusal(code):
    return STATUSES[code], {"version": 1, "error": code}


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: refusals.py IMAGE")
    require_docker()
    stack = Stack("locus-backends-refusals", sys.argv[1])
    try:
        stack.up(pool=f"{POOL[0]}-{POOL[-1]}")
        c = stack.controller()
        expect(c.hello()[0] == 200, "the service is greeted")
        secret = {"PROBE_SECRET": "refusal-secret-value"}
        status, answer, _ = c.sync(MAIN, [probe(env=secret)])
        expect(status == 200, "the main owner is synced", answer)
        c.running(MAIN)

        def pool_pids():
            return sorted(p["pid"] for p in stack.processes() if any(u in POOL for u in p["uids"]))

        # ————— unauthorized —————
        status, answer, _ = c.renew([MAIN], key=secrets.token_bytes(32))
        expect((status, answer) == (401, {"version": 1, "error": "unauthorized"}), "a forged control MAC is refused",
               answer)
        status, answer, _, _ = c.invoke(MAIN, "tools/list", key=secrets.token_bytes(32))
        expect((status, answer) == (401, UNAUTHORIZED_RPC), "a forged invoke MAC is refused", answer)

        signed = c.sign_invoke(MAIN, "tools/list")
        signed.body = signed.body.replace(b'"id":1', b'"id":2')
        status, answer, _, _ = c.resend(signed)
        expect((status, answer) == (401, UNAUTHORIZED_RPC), "a signature over another body does not carry to this one",
               answer)

        for ts in [now_ms() - WINDOW_MS - 1_000, now_ms() + WINDOW_MS + 1_000]:
            status, answer, _ = c.renew([MAIN], ts=ts)
            expect(status == 401, f"a control message at {ts - now_ms():+d} ms is refused", answer)
            status, answer, _, _ = c.invoke(MAIN, "tools/list", ts=ts)
            expect(status == 401, f"an invoke at {ts - now_ms():+d} ms is refused", answer)

        forged = {"generation": 1, "seq": 10_000, "cyfr_boot": c.cyfr_boot, "boot": c.boot, "ts": now_ms()}
        for route, header in [
            ("control", control_header(secrets.token_bytes(32), forged, b"{}")),
            ("mcp", c.sign_invoke(MAIN, "tools/list", key=secrets.token_bytes(32)).headers[AUTH_HEADER]),
        ]:
            expect(raw_head(stack.base, ROUTES[route], header, 28 * 1024 * 1024) == 401,
                   f"a {route} request refused by its header is answered before its body is sent")

        # ————— stale_control —————
        status, answer, _ = c.renew([MAIN])
        expect(status == 200 and answer["unknown"] == [], "a fresh renewal is applied", answer)
        seq = c.seq
        for options in [{"seq": seq}, {"seq": seq - 1}]:
            status, answer, _ = c.renew([MAIN], **options)
            expect((status, answer) == refusal("stale_control"), f"a renewal at {options} is stale_control", answer)
        expect(c.renew([MAIN])[0] == 200, "the next sequence is applied")

        # ————— owner versions —————
        for owner, code in [({**MAIN, "e": 1}, "stale_epoch"), ({**MAIN, "e": 3}, "epoch_ahead"),
                            ({**MAIN, "server": "mcp_none"}, "unknown_owner")]:
            status, answer, _, _ = c.invoke(owner, "tools/list")
            expect((status, answer) == refusal(code), f"an invoke at {owner} is {code}", answer)

        # ————— replay —————
        status, _answer, _, first = c.invoke(MAIN, "tools/call", {"name": "probe__whoami", "arguments": {}})
        expect(status == 200, "a signed call is answered")
        status, answer, _, _ = c.resend(first)
        expect((status, answer) == refusal("replay"), "the same nonce sent again is replay", answer)

        # ————— capacity —————
        fill = owner_of("fill")
        status, answer, _ = c.sync(fill, [probe("one"), probe("two")])
        expect(status == 200, "a second owner fills the pool", answer)
        c.running(fill)
        expect(c.hello()[1]["pool"]["free"] == 0, "the pool has no free uid")
        before = pool_pids()
        extra = owner_of("extra")
        status, answer, _ = c.sync(extra, [probe()])
        expect((status, answer) == refusal("capacity"), "a sync the pool cannot hold is capacity", answer)
        expect(pool_pids() == before, "a refused sync starts no process", [before, pool_pids()])
        expect(c.report(extra) is None, "a refused owner is not run")

        status, answer, _ = c.sync({**fill, "e": 2}, [probe("one"), probe("two"), probe("three"), probe("four")])
        expect((status, answer) == refusal("capacity"), "a replacement needing more than the pool frees is capacity",
               answer)
        expect(pool_pids() == before and c.report(fill)["e"] == 1,
               "a refused replacement starts nothing and leaves the owner it named as it ran", c.report(fill))

        # ————— stale_boot across a restart —————
        status, _answer, old_boot, captured = c.invoke(MAIN, "tools/call", {"name": "probe__whoami", "arguments": {}})
        expect(status == 200, "a call is captured")
        run("docker", "restart", stack.container)
        base = stack.published()
        status, answer, new_boot, _ = c.resend(captured, base)
        expect((status, answer) == refusal("stale_boot") and new_boot != old_boot,
               "a captured invoke sent again after the restart is stale_boot", answer)
        signed_at = int(captured.headers[AUTH_HEADER].split(" ts=")[1].split(" ")[0])
        expect(now_ms() - signed_at < WINDOW_MS, "the resend fell inside the window, so its refusal is the lifetime's")

        restarted = Controller(base, stack.key, cyfr_boot=c.cyfr_boot)
        status, answer, _ = restarted.renew([MAIN], boot=old_boot, seq=c.seq + 1)
        expect((status, answer) == refusal("stale_boot"), "a control message naming the old lifetime is stale_boot",
               answer)
    finally:
        stack.down()


if __name__ == "__main__":
    main()
