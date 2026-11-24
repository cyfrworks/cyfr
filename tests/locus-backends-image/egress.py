#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A program of the backends image reaches the hosts its row names, and no other public host, through its session's own route.

Run as docker-compose.yml's locus-backends service behind its guard, the
keeper given the guard's control (`--guard`), and driven only by requests
signed as CYFR signs them (harness.py):

- Every session runs in a space of its own whose one way out is the route
  the guard made for it before it started (a veth pair, sp<slot>, and the
  route's chain, CYFR_GUARD_R<slot>, recorded under /run/cyfr-guard/routes).
- A program whose row names `hosts` has a route holding it to the addresses
  those names resolved to as its session started: its chain passes each of
  them and refuses the rest, counted on that chain's rule. It reaches a
  listed host and is refused an unlisted public address at once; IPv6 has
  no route out of a space. The rules every space is held to stand for it
  (a metadata address is refused on them), and its names are answered by
  the guard on its own 127.0.0.11:53 (Docker's resolver's answer for the
  stack's own service name).
- A program whose row names no hosts has a route of the island's rule: it
  reaches the address the first is refused.
- A withdrawn route leaves no connection in the kernel's table, and a
  connection takes its route's mark only as it is made: a later route that
  takes the address and is allowed the same destination makes its own
  exchange on the same tuple, under its own mark alone.
- Two sessions of one kept folder have a route each, of their own start,
  and closing one leaves the other's as it was.
- An open whose hosts resolve to no address is refused `hosts_unresolved`
  and starts nothing.
- The guard's health check proves what the guard recorded, not a snapshot
  of what is installed: a route's rule or jump changed behind the guard's
  back fails it and restored passes it again.
- A route the guard cannot record refuses its session `guard_unavailable`
  and leaves every other route as it was.
- Retiring a program withdraws its route; losing the keeper, its
  connection with it, withdraws every route made over that connection, and
  the guard stays healthy.

The reaching steps need the public network and are skipped, each with its
reason, under CYFR_TEST_OFFLINE=1; every refusal holds without it.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/egress.py IMAGE
"""

import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    CONNECT_PROBE, KEPT_FIRST, KEPT_LAST, POOL_FIRST, POOL_LAST, REFUSED, SERVICE, STATUSES, VERSION, Stack,
    eventually, expect, owner_of, probe, require_docker, run,
)
from imagesuite import read_output  # noqa: E402

LISTED, OPEN, KEPT, NOWHERE, REUSE = (owner_of(name) for name in ("listed", "open", "kept", "nowhere", "reuse"))
KEPT_ENTRY = "vlt_egress-kept"
# A public host the listed programs name and reach, and a public address
# none of them names: an IP literal, so its refusal needs no resolver.
LISTED_HOST = "registry.npmjs.org"
UNLISTED = "1.1.1.1:443"
UNLISTED_V6 = "[2606:4700:4700::1111]:443"
METADATA = "169.254.169.254:80"
# A space has no IPv6 route: its IPv6 connection never leaves it.
UNROUTED = ("ENETUNREACH",)

# The space's own address on its route, its one IPv4 interface beside the
# loopback.
INNER = ("console.log(Object.values(require('os').networkInterfaces()).flat()"
         ".find((a) => a.family === 'IPv4' && !a.internal).address)")

# One DNS query (example.com, A) from a UDP socket bound to a chosen port,
# printing `reply=yes` once answered, `reply=no` after 3 s, or the code the
# send was refused with.
UDP_REUSE_PROBE = r"""
const dgram = require("dgram");
const [port, host, dport] = process.argv.slice(process.argv.indexOf("reuse") + 1);
const query = Buffer.from("123401000001000000000000076578616d706c6503636f6d0000010001", "hex");
const socket = dgram.createSocket({ type: "udp4", reuseAddr: true });
let done = false;
const finish = (line) => { if (!done) { done = true; console.log(line); try { socket.close(); } catch (e) {} } };
socket.on("error", (e) => finish("error=" + (e.code || String(e))));
socket.on("message", () => finish("reply=yes"));
socket.bind(Number(port), () => {
  socket.send(query, Number(dport), host, (e) => { if (e) finish("send=" + (e.code || String(e))); });
  setTimeout(() => finish("reply=no"), 3000);
});
"""
REUSE_PORT = "45000"


def fields(text):
    return dict(line.split("=", 1) for line in (text or "").splitlines() if "=" in line)


def run_in(c, owner, argv, program="probe", key="mcp", home_id=None):
    """`argv` run by the probe in `owner`'s session: the probe's answer."""
    status, answer = c.mcp(owner, program, key=key, home_id=home_id).call("run", {"argv": argv})
    result = (answer or {}).get("result") or {}
    expect(status == 200 and not result.get("isError") and "content" in result, f"{owner['athanor']} ran {argv[0]}",
           [status, answer])
    return json.loads(result["content"][0]["text"])


def uid_of(c, owner, program="probe", key="mcp", home_id=None):
    status, answer = c.mcp(owner, program, key=key, home_id=home_id).call("whoami", {})
    return json.loads(answer["result"]["content"][0]["text"])["uid"]


def connect(c, owner, targets, **session):
    probed = run_in(c, owner, ["node", "-e", CONNECT_PROBE, "targets", *targets], **session)
    expect(probed["status"] == 0, f"{owner['athanor']}'s connection probe ran to its end", probed)
    return fields(probed.get("stdout"))


def routes(stack):
    """The guard's record of every route it holds: its guard's end, sp<slot>, to the rules recorded for it."""
    listed = stack.guard_exec('for f in /run/cyfr-guard/routes/sp*; do [ -f "$f" ] && printf "== %s\\n" "${f##*/}" && cat "$f"; done; true')
    out, iface = {}, None
    for line in listed.stdout.splitlines():
        if line.startswith("== "):
            iface = line[3:]
            out[iface] = []
        elif iface:
            out[iface].append(line)
    return out


def route_of(stack, c, owner, **session):
    """`owner`'s session's route: (its guard's end, its slot, its recorded rules), found by the space's own address."""
    inner = run_in(c, owner, ["node", "-e", INNER], **session)["stdout"].strip()
    found = [(iface, rules) for iface, rules in routes(stack).items() if any(f"! -s {inner}/32 -j DROP" in r for r in rules)]
    expect(len(found) == 1, f"{owner['athanor']}'s session, at {inner}, has one route at the guard", [inner, routes(stack)])
    iface, rules = found[0]
    return iface, int(iface[2:]), rules


def chain_rose(before, after, chain, fragment):
    """The packets the rules of `chain` holding `fragment` counted between two readings."""
    prefix = f"-A {chain} "
    return sum(after.get(rule, 0) - before.get(rule, 0) for rule in after if rule.startswith(prefix) and fragment in rule)


def held_to_list(stack, c, owner, offline, **session):
    """`owner`'s session reaches its listed host and is refused an unlisted address, on its own route's chain."""
    iface, slot, rules = route_of(stack, c, owner, **session)
    chain, passes = f"CYFR_GUARD_R{slot}", f"CYFR_GUARD_P{slot}"
    listed = [r for r in rules if r.startswith(f"-A {chain} -d ") and r.endswith(f"-j {passes}")]
    expect(listed and f"-A {chain} -j REJECT --reject-with icmp-admin-prohibited" in rules
           and f"-A CYFR_GUARD_ROUTES -i {iface} -j {chain}" in rules,
           f"{owner['athanor']}'s route passes the addresses its hosts resolved to, and refuses the rest", rules)
    resolved = run_in(c, owner, ["getent", "hosts", SERVICE], **session)
    expect(resolved["status"] == 0 and SERVICE in resolved["stdout"],
           f"{owner['athanor']}'s names are answered on its own resolver, Docker's answer for {SERVICE}", resolved)
    before = stack.guard_counters()
    codes = connect(c, owner, [UNLISTED, METADATA, UNLISTED_V6] + ([] if offline else [f"{LISTED_HOST}:443"]), **session)
    after = stack.guard_counters()
    expect(codes.get(UNLISTED) in REFUSED and chain_rose(before, after, chain, "-j REJECT") >= 1,
           f"{owner['athanor']} is refused a public address its row does not name, on its route's chain", codes)
    expect(codes.get(METADATA) in REFUSED and chain_rose(before, after, "CYFR_GUARD_REFUSE", "-d 169.254.0.0/16") >= 1,
           f"{owner['athanor']} is refused a metadata address on the rules every space is held to", codes)
    expect(codes.get(UNLISTED_V6) in UNROUTED, f"{owner['athanor']}'s IPv6 connection has no route out of its space", codes)
    if offline:
        print(f"skip: {LISTED_HOST} is not reached from {owner['athanor']}: CYFR_TEST_OFFLINE=1 says this host has no "
              "public network", flush=True)
    else:
        expect(codes.get(f"{LISTED_HOST}:443") == "connected" and chain_rose(before, after, chain, f"-j {passes}") >= 1,
               f"{owner['athanor']} reaches {LISTED_HOST}, which its row names, through its route", codes)
    return iface, slot, rules


def connections_of(stack, inner):
    """The guard's connection-table entries whose original source is `inner`, from /proc/net/nf_conntrack, or None
    where the kernel keeps no such file."""
    listed = stack.guard_exec("cat /proc/net/nf_conntrack")
    if listed.returncode != 0:
        return None
    return [line for line in listed.stdout.splitlines() if re.search(rf"\bsrc={re.escape(inner)}\b", line.split("dst=")[0] + " ")]


def route_mark(rules, slot):
    """The connection mark route `slot` gives a new connection, as its pass chain sets it."""
    for rule in rules:
        found = re.search(rf"^-A CYFR_GUARD_P{slot} .*--ctstate NEW -j CONNMARK --set-xmark (0x[0-9a-f]+)/0xffffffff$", rule)
        if found:
            return int(found.group(1), 16)
    return None


def tuple_reuse(stack, c, open_slot, offline):
    """A withdrawn route leaves no connection in the kernel's table, and a connection takes its route's mark only as it
    is made: the open program's UDP exchange is gone with its route, and a session that takes the same slot, and so
    the same address, and is allowed the same destination, makes its own exchange on the same tuple under its own
    route's mark."""
    if offline:
        print("skip: a tracked UDP exchange to 1.1.1.1:53 needs the public network: CYFR_TEST_OFFLINE=1", flush=True)
        c.release([OPEN])
        return
    inner = run_in(c, OPEN, ["node", "-e", INNER])["stdout"].strip()
    first = run_in(c, OPEN, ["node", "-e", UDP_REUSE_PROBE, "reuse", REUSE_PORT, "1.1.1.1", "53"])
    expect(first["stdout"].strip() == "reply=yes",
           "the open program's query to 1.1.1.1:53 from its chosen port is answered", first)
    tracked = connections_of(stack, inner)
    if tracked is None:
        print("skip: the kernel keeps no /proc/net/nf_conntrack, so the connection table is not read here", flush=True)
    else:
        expect(tracked, f"the kernel tracks the open program's exchange from {inner}", tracked)
    status, _answer, _ = c.release([OPEN])
    expect(status == 200, "the open program's owner is released")
    eventually(lambda: f"sp{open_slot}" not in routes(stack), f"the open program's route, sp{open_slot}, to be withdrawn")
    if tracked is not None:
        left = connections_of(stack, inner)
        expect(left == [], f"the withdrawn route left no connection of {inner} in the kernel's table", left)
    status, answer, _ = c.sync(REUSE, [probe()])
    expect(status == 200, "a second open owner is synced", answer)
    _iface, slot, rules = route_of(stack, c, REUSE)
    expect(slot == open_slot, f"the second session took the withdrawn route's slot, {open_slot}, and its address", slot)
    mark = route_mark(rules, slot)
    expect(mark is not None, "the route marks a connection only as it is made, on its first packet", rules)
    second = run_in(c, REUSE, ["node", "-e", UDP_REUSE_PROBE, "reuse", REUSE_PORT, "1.1.1.1", "53"])
    expect(second["stdout"].strip() == "reply=yes", "the second session's exchange on the same tuple is answered", second)
    if tracked is not None:
        entries = connections_of(stack, inner)
        marks = {int(m) for line in entries for m in re.findall(r"\bmark=(\d+)", line)}
        expect(entries and marks == {mark}, f"every connection of {inner} now is the second route's, marked {mark}",
               {"entries": entries, "mark": mark})


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: egress.py IMAGE")
    require_docker()
    offline = os.environ.get("CYFR_TEST_OFFLINE") == "1"
    stack = Stack("locus-backends-egress", sys.argv[1])
    try:
        stack.up()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the service is greeted")
        for owner, programs in [(LISTED, [probe(hosts=[LISTED_HOST])]), (OPEN, [probe()]),
                                (KEPT, [probe(home="kept", hosts=[LISTED_HOST])]),
                                (NOWHERE, [probe(hosts=["nothing.invalid"])])]:
            status, answer, _ = c.sync(owner, programs)
            expect(status == 200, f"{owner['athanor']} is synced", answer)

        # ————— a listed program —————
        listed_uid = uid_of(c, LISTED)
        expect(POOL_FIRST <= listed_uid <= POOL_LAST, "the listed program runs under a pooled uid", listed_uid)
        listed_iface, listed_slot, _ = held_to_list(stack, c, LISTED, offline)

        # ————— a program whose row names no hosts —————
        open_iface, open_slot, open_rules = route_of(stack, c, OPEN)
        expect(open_iface != listed_iface and f"-A CYFR_GUARD_R{open_slot} -j CYFR_GUARD_P{open_slot}" in open_rules
               and not any(r.endswith("--reject-with icmp-admin-prohibited") and r.startswith(f"-A CYFR_GUARD_R{open_slot} -j REJECT")
                           for r in open_rules),
               "a program whose row names no hosts has a route of its own, of the island's rule", open_rules)
        codes = connect(c, OPEN, [METADATA] + ([] if offline else [UNLISTED]))
        expect(codes.get(METADATA) in REFUSED, "a program without hosts is refused a metadata address", codes)
        if offline:
            print(f"skip: {UNLISTED} is not reached from the unlisted program: CYFR_TEST_OFFLINE=1 says this host has "
                  "no public network", flush=True)
        else:
            expect(codes.get(UNLISTED) == "connected",
                   "the program without hosts reaches the public address the listed one is refused", codes)

        # ————— a tracked UDP exchange serves no later route —————
        tuple_reuse(stack, c, open_slot, offline)

        # ————— two sessions of a kept folder, a route each —————
        kept_uid = uid_of(c, KEPT, home_id=KEPT_ENTRY)
        expect(KEPT_FIRST <= kept_uid <= KEPT_LAST, "the kept program runs under a uid of the kept range", kept_uid)
        kept_iface, kept_slot, kept_rules = held_to_list(stack, c, KEPT, offline, home_id=KEPT_ENTRY)
        second_iface, _second_slot, _ = held_to_list(stack, c, KEPT, offline, key="second", home_id=KEPT_ENTRY)
        expect(second_iface != kept_iface and uid_of(c, KEPT, key="second", home_id=KEPT_ENTRY) == kept_uid,
               "a second session of the kept folder, under the same uid, has a route of its own", [kept_iface, second_iface])
        c.close(KEPT, c.mcp(KEPT, "probe", key="second", home_id=KEPT_ENTRY).session)
        eventually(lambda: second_iface not in routes(stack), "the closed session's route to be withdrawn")
        expect(routes(stack).get(kept_iface) == kept_rules, "the first session's route stands as it was made")
        held_to_list(stack, c, KEPT, offline, home_id=KEPT_ENTRY)

        # ————— a name that resolves to nothing —————
        status, answer = c.open(NOWHERE, "probe", key="k")
        expect((status, answer) == (STATUSES["hosts_unresolved"], {"version": VERSION, "error": "hosts_unresolved"}),
               "an open whose hosts resolve to no address is refused hosts_unresolved", [status, answer])
        expect(c.program(NOWHERE)["sessions"] == 0, "and nothing of it runs")

        # ————— the guard's check proves what it recorded —————
        expect(stack.guard_exec("cyfr-guard check").returncode == 0, "the guard is healthy with the routes in")
        chain = f"CYFR_GUARD_R{kept_slot}"
        removed = stack.guard_exec(f"iptables -D {chain} -j REJECT --reject-with icmp-admin-prohibited && cyfr-guard check")
        expect(removed.returncode != 0 and f"route {kept_iface} is not installed as the guard recorded it" in removed.stderr,
               "a route's rule changed behind the guard's back fails its health check", removed.stdout + removed.stderr)
        restored = stack.guard_exec(f"iptables -A {chain} -j REJECT --reject-with icmp-admin-prohibited && cyfr-guard check")
        expect(restored.returncode == 0, "the rule restored where it stood, the check passes again",
               restored.stdout + restored.stderr)
        unjumped = stack.guard_exec(f"iptables -D CYFR_GUARD_ROUTES -i {kept_iface} -j {chain} && cyfr-guard check")
        expect(unjumped.returncode != 0 and "jumps to routes are not the routes the guard recorded" in unjumped.stderr,
               "a route's jump removed behind the guard's back fails its health check", unjumped.stdout + unjumped.stderr)
        rejumped = stack.guard_exec(f"iptables -A CYFR_GUARD_ROUTES -i {kept_iface} -j {chain} && cyfr-guard check")
        expect(rejumped.returncode == 0, "the jump restored, the check passes again", rejumped.stdout + rejumped.stderr)

        # ————— a route the guard cannot record refuses its session alone —————
        held = {int(iface[2:]) for iface in routes(stack)}
        free = next(slot for slot in range(len(held) + 1) if slot not in held)
        blocked = stack.guard_exec(f"mkdir /run/cyfr-guard/routes/sp{free}.tmp")
        expect(blocked.returncode == 0, f"the next route's record, sp{free}, cannot be written: its temporary path is a folder",
               blocked.stderr)
        before = routes(stack)
        status, answer = c.open(KEPT, "probe", key="third", home_id=KEPT_ENTRY)
        expect((status, answer) == (STATUSES["guard_unavailable"], {"version": VERSION, "error": "guard_unavailable"}),
               "a session whose route the guard cannot record is refused guard_unavailable", [status, answer])
        expect(routes(stack) == before, "every other route stands as it was", [before, routes(stack)])
        held_to_list(stack, c, KEPT, offline, home_id=KEPT_ENTRY)
        restored = stack.guard_exec(f"rmdir /run/cyfr-guard/routes/sp{free}.tmp && cyfr-guard check")
        expect(restored.returncode == 0, "the record writable again, the guard is healthy", restored.stdout + restored.stderr)

        # ————— retirement withdraws; the keeper's loss withdraws every route —————
        status, _answer, _ = c.release([LISTED])
        expect(status == 200, "the listed program's owner is released")
        eventually(lambda: listed_iface not in routes(stack)
                   and stack.guard_exec(f"iptables -S CYFR_GUARD_R{listed_slot}").returncode != 0,
                   f"the listed program's route, {listed_iface}, to be withdrawn at its retirement")
        expect(routes(stack), "the kept session's route still stands", routes(stack))
        run("docker", "kill", stack.container)
        eventually(lambda: not routes(stack)
                   and not re.search(r"(?m)^sp\d+$", read_output(stack.guard_exec("ls /sys/class/net"), "the guard's links"))
                   and "-N CYFR_GUARD_R" not in read_output(stack.guard_exec("iptables -S"), "the guard's rules"),
                   "every route made over the lost keeper's connection, its pair, chain and record, to be withdrawn")
        expect(re.search(r"connection \d+ ended; its \d+ routes are withdrawn", stack.guard_logs()),
               "the guard says it withdrew the lost connection's routes", stack.guard_logs()[-2000:])
        expect(stack.guard_exec("cyfr-guard check").returncode == 0, "the guard stays healthy through the keeper's loss")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
