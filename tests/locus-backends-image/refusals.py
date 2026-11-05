#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends image refuses every request it cannot attribute, over the wire, before any state changes.

Run as docker-compose.yml's locus-backends service with a pool of three
uids, and driven only by requests signed as CYFR signs them (harness.py):

- The health probe answers version 2 alone; a control or session body at
  version 1 is refused `version`.
- A forged MAC and a timestamp outside the window are refused on both
  routes (`unauthorized`), answered before a large body is sent; a session
  message signed over another body, or under another owner's key, is
  refused the same; a session body naming another epoch than its
  signature is `bad_request`.
- A control message at or below the high-water mark is `stale_control`.
- A session message at a stale epoch is `stale_epoch`, at a future one
  `epoch_ahead`, for an owner the service does not run `unknown_owner`,
  for a program its owner does not define `unknown_program`, for a session
  it does not hold `unknown_session`.
- A nonce sent again is `replay`.
- A sync starts nothing; an open the uid pool cannot hold is `capacity`
  and spawns nothing.
- After `docker restart`, a captured session message sent again, and a
  control message naming the old lifetime, are `stale_boot`.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/refusals.py IMAGE
"""

import os
import secrets
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    AUTH_HEADER, POOL_FIRST, ROUTES, STATUSES, VERSION, WINDOW_MS, Controller, Stack, control_header, eventually, expect,
    health, now_ms, owner_key, owner_of, probe, raw_head, require_docker, run,
)

POOL = [POOL_FIRST, POOL_FIRST + 1, POOL_FIRST + 2]
MAIN = owner_of("main", e=2)
OPEN = {"type": "open", "program": "probe", "key": "k", "mode": "run", "argv": []}


def refusal(code):
    return STATUSES[code], {"version": VERSION, "error": code}


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

        expect(pool_pids() == [], "a sync starts no process")

        # ————— the version —————
        status, answer = health(stack.base)
        expect(status == 200 and answer["version"] == VERSION, "the health probe answers version 2", answer)
        status, answer = health(stack.base, version=1)
        expect((status, answer) == refusal("version"), "a version-1 health probe is refused version", answer)
        status, answer, _ = c.renew([MAIN], version=1)
        expect((status, answer) == refusal("version"), "a version-1 control body is refused version", answer)
        status, answer, _, _ = c.session(MAIN, OPEN, version=1)
        expect((status, answer) == refusal("version"), "a version-1 session body is refused version", answer)

        # ————— unauthorized —————
        status, answer, _ = c.renew([MAIN], key=secrets.token_bytes(32))
        expect((status, answer) == refusal("unauthorized"), "a forged control MAC is refused", answer)
        status, answer, _, _ = c.session(MAIN, OPEN, key=secrets.token_bytes(32))
        expect((status, answer) == refusal("unauthorized"), "a forged session MAC is refused", answer)
        other = owner_of("other", e=2)
        status, answer, _, _ = c.session(MAIN, OPEN, key=owner_key(stack.key, other["athanor"], other["server"], 1, 2))
        expect((status, answer) == refusal("unauthorized"), "another owner's key reaches nothing of this owner's",
               answer)

        signed = c.sign_session(MAIN, OPEN)
        signed.body = signed.body.replace(b'"key":"k"', b'"key":"j"')
        status, answer, _, _ = c.resend(signed)
        expect((status, answer) == refusal("unauthorized"), "a signature over another body does not carry to this one",
               answer)

        for ts in [now_ms() - WINDOW_MS - 1_000, now_ms() + WINDOW_MS + 1_000]:
            status, answer, _ = c.renew([MAIN], ts=ts)
            expect(status == 401, f"a control message at {ts - now_ms():+d} ms is refused", answer)
            status, answer, _, _ = c.session(MAIN, OPEN, ts=ts)
            expect(status == 401, f"a session message at {ts - now_ms():+d} ms is refused", answer)

        forged = {"generation": 1, "seq": 10_000, "cyfr_boot": c.cyfr_boot, "boot": c.boot, "ts": now_ms()}
        for route, header in [
            ("control", control_header(secrets.token_bytes(32), forged, b"{}")),
            ("session", c.sign_session(MAIN, OPEN, key=secrets.token_bytes(32)).headers[AUTH_HEADER]),
        ]:
            expect(raw_head(stack.base, ROUTES[route], header, 28 * 1024 * 1024) == 401,
                   f"a {route} request refused by its header is answered before its body is sent")

        status, answer, _, _ = c.session({**MAIN, "e": 3}, OPEN, header_owner=MAIN)
        expect((status, answer) == refusal("bad_request"), "a session body naming another epoch than its signature "
               "is bad_request", answer)
        expect(pool_pids() == [], "no refused message started a process")

        # ————— stale_control —————
        status, answer, _ = c.renew([MAIN])
        expect(status == 200 and answer["unknown"] == [], "a fresh renewal is applied", answer)
        seq = c.seq
        for options in [{"seq": seq}, {"seq": seq - 1}]:
            status, answer, _ = c.renew([MAIN], **options)
            expect((status, answer) == refusal("stale_control"), f"a renewal at {options} is stale_control", answer)
        expect(c.renew([MAIN])[0] == 200, "the next sequence is applied")

        # ————— owner versions, programs and sessions —————
        for owner, code in [({**MAIN, "e": 1}, "stale_epoch"), ({**MAIN, "e": 3}, "epoch_ahead"),
                            ({**MAIN, "server": "mcp_none"}, "unknown_owner")]:
            status, answer, _, _ = c.session(owner, OPEN)
            expect((status, answer) == refusal(code), f"an open at {owner} is {code}", answer)
        status, answer = c.open(MAIN, "nothing")
        expect((status, answer) == refusal("unknown_program"), "an open of a program the owner does not define is "
               "unknown_program", answer)
        status, answer = c.recv(MAIN, "ss_" + "0" * 32, 0, 0)
        expect((status, answer) == refusal("unknown_session"), "a recv of a session the owner does not hold is "
               "unknown_session", answer)
        expect(pool_pids() == [], "no refused open started a process")

        # ————— replay —————
        status, answer, _, first = c.session(MAIN, OPEN)
        expect(status == 200 and answer["resumed"] is False, "a signed open is answered", answer)
        status, answer, _, _ = c.resend(first)
        expect((status, answer) == refusal("replay"), "the same nonce sent again is replay", answer)

        # ————— capacity —————
        fill = owner_of("fill")
        status, answer, _ = c.sync(fill, [probe("one"), probe("two")])
        expect(status == 200, "a second owner is synced", answer)
        for program in ["one", "two"]:
            status, answer = c.open(fill, program)
            expect(status == 200, f"its program {program} is opened", answer)
        expect(c.hello()[1]["pool"]["free"] == 0, "the pool has no free uid")
        before = pool_pids()
        extra = owner_of("extra")
        status, answer, _ = c.sync(extra, [probe()])
        expect(status == 200 and pool_pids() == before, "a sync while the pool is full is admitted and starts nothing",
               answer)
        status, answer = c.open(extra, "probe")
        expect((status, answer) == refusal("capacity"), "an open the pool cannot hold is capacity", answer)
        status, answer = c.open(fill, "one", key="another")
        expect((status, answer) == refusal("capacity"), "a second session the pool cannot hold is capacity", answer)
        expect(pool_pids() == before and c.program(extra)["sessions"] == 0,
               "a refused open starts no process", [before, pool_pids()])

        # ————— stale_boot across a restart —————
        expect(c.release([fill])[0] == 200, "the second owner is released")
        eventually(lambda: c.hello()[1]["pool"]["free"] == 1, "its uids to return to the pool")
        status, answer, old_boot, captured = c.session(MAIN, {**OPEN, "key": "captured"})
        expect(status == 200, "an open is captured", answer)
        run("docker", "restart", stack.container)
        base = stack.published()
        status, answer, new_boot, _ = c.resend(captured, base)
        expect((status, answer) == refusal("stale_boot") and new_boot != old_boot,
               "a captured session message sent again after the restart is stale_boot", answer)
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
