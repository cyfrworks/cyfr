#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A program of the backends image reaches the hosts its row names, and no other public host.

Run as docker-compose.yml's locus-backends service behind its guard, the
keeper given the guard's control (`--guard`), and driven only by requests
signed as CYFR signs them (harness.py):

- A program whose row names `hosts` runs under a uid the guard holds to the
  addresses those names resolved to as its process started: its uid's own
  chain at the guard returns each of them and refuses the rest, counted on
  that chain's rule. It reaches a listed host and is refused an unlisted
  public address at once, over IPv4 and IPv6 (an IPv6 address its keeper
  admitted passes its IPv6 chain, an unlisted one is refused there); the
  rules before the list stand for it as for every spawn (Docker's resolver
  answers it the stack's own service name; a metadata address is refused).
- A listed program that reuses another uid's UDP tuple (its local port,
  the address and the port the other asked) before the kernel forgets the
  other's exchange is refused on its own chain: a tracked connection
  serves no uid but by that uid's own rules.
- A second owner's program, whose row names no hosts, is unaffected: the
  guard holds no chain for its uid, and it reaches the address the first is
  refused, as today. A kept program's uid, outside the pool, is held to its
  row's hosts alike.
- An open whose hosts resolve to no address is refused `hosts_unresolved`
  and starts nothing.
- The guard's health check proves what the guard admitted, not a snapshot
  of what is installed: a uid's rule changed behind the guard's back fails
  it and restored passes it again, and a uid's chain removed behind its
  back still fails it after a legitimate change to another uid (an admit
  and a clear), until the guard admits the uid again.
- Retiring a listed program's process clears its uid at the guard; losing
  the keeper leaves every uid it admitted refused every public address.

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

LISTED, OPEN, KEPT, NOWHERE = (owner_of(name) for name in ("listed", "open", "kept", "nowhere"))
KEPT_ENTRY = "vlt_egress-kept"
# A public host the listed programs name and reach, and a public address
# none of them names: an IP literal, so its refusal needs no resolver.
LISTED_HOST = "registry.npmjs.org"
UNLISTED = "1.1.1.1:443"
UNLISTED_V6 = "[2606:4700:4700::1111]:443"
METADATA = "169.254.169.254:80"

# One DNS query (example.com, A) from a UDP socket bound to a chosen port,
# printing `reply=yes` once answered, `reply=no` after 3 s, or the code the
# send was refused with (`send=EPERM` for the guard's refusal).
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


def uid_chain(stack, uid, tool="iptables"):
    """The rules of uid's chain at the guard in one family (`iptables` or `ip6tables`), or None where it has none."""
    listed = stack.guard_exec(f"{tool} -S CYFR_GUARD_U{uid}")
    return listed.stdout.splitlines() if listed.returncode == 0 else None


def chain_rose(before, after, uid, fragment):
    """The packets the rules of uid's chain holding `fragment` counted between two readings."""
    prefix = f"-A CYFR_GUARD_U{uid} "
    return sum(after.get(rule, 0) - before.get(rule, 0) for rule in after if rule.startswith(prefix) and fragment in rule)


def held_to_list(stack, c, owner, uid, offline, **session):
    """`owner`'s program, of uid, reaches its listed host and is refused an unlisted address, on its own chain."""
    chain = uid_chain(stack, uid)
    returned = [rule for rule in chain or [] if rule.endswith("-j RETURN")]
    expect(chain is not None and returned and chain[-1] == f"-A CYFR_GUARD_U{uid} -j REJECT --reject-with icmp-admin-prohibited",
           f"the guard holds uid {uid} to the addresses its hosts resolved to, and refuses it the rest", chain)
    jump = stack.guard_exec(f"iptables -C CYFR_GUARD_HOSTS -m owner --uid-owner {uid} -j CYFR_GUARD_U{uid}")
    expect(jump.returncode == 0, f"the guard's list rule sends uid {uid} to its own chain", jump.stderr)

    # The stack's own service name, which Docker's resolver answers on the
    # island's network wherever the suite runs; a name outside the stack
    # resolves or not by the host's own search domains.
    resolved = run_in(c, owner, ["getent", "hosts", SERVICE], **session)
    expect(resolved["status"] == 0 and SERVICE in resolved["stdout"],
           f"uid {uid} still reaches Docker's resolver, which answers {SERVICE}", resolved)
    before = stack.guard_counters()
    codes = connect(c, owner, [UNLISTED, METADATA] + ([] if offline else [f"{LISTED_HOST}:443"]), **session)
    after = stack.guard_counters()
    expect(codes.get(UNLISTED) in REFUSED, f"uid {uid} is refused a public address its row does not name", codes)
    expect(chain_rose(before, after, uid, "-j REJECT") >= 1,
           f"the refusal counted on uid {uid}'s own chain", {k: v for k, v in after.items() if f"U{uid}" in k})
    expect(codes.get(METADATA) in REFUSED and any(
        after.get(rule, 0) > before.get(rule, 0) for rule in after if "-d 169.254.0.0/16 -j REJECT" in rule),
        f"uid {uid} is still refused a metadata address, on the guard's metadata rule", codes)
    if offline:
        print(f"skip: {LISTED_HOST}:443 is not reached from uid {uid}: CYFR_TEST_OFFLINE=1 says this host has no "
              "public network", flush=True)
    else:
        expect(codes.get(f"{LISTED_HOST}:443") == "connected", f"uid {uid} reaches {LISTED_HOST}, which its row names",
               codes)
        expect(chain_rose(before, after, uid, "-j RETURN") >= 1,
               f"uid {uid}'s connection to its listed host passed on its own chain", chain)

    # IPv6: an address the keeper admitted, read from the uid's own chain,
    # passes it; an unlisted one is refused there. A packet the chain passes
    # may still find no route beyond the host, so what proves it is the
    # chain's counter, not the connection.
    chain6 = uid_chain(stack, uid, "ip6tables") or []
    expect(chain6 and chain6[-1] == f"-A CYFR_GUARD_U{uid} -j REJECT --reject-with icmp6-adm-prohibited",
           f"the guard holds uid {uid}'s IPv6 to its list too", chain6)
    admitted6 = [m.group(1) for rule in chain6 for m in [re.search(r"-d (\S+)/128 -j RETURN", rule)] if m]
    targets6 = [UNLISTED_V6] + ([f"[{admitted6[0]}]:443"] if admitted6 else [])
    before = stack.guard_counters()
    codes = connect(c, owner, targets6, **session)
    after = stack.guard_counters()
    expect(codes.get(UNLISTED_V6) in REFUSED and chain_rose(before, after, uid, "icmp6-adm-prohibited") >= 1,
           f"uid {uid} is refused a public IPv6 address its row does not name, on its own IPv6 chain", codes)
    if admitted6:
        expect(codes.get(f"[{admitted6[0]}]:443") not in REFUSED
               and chain_rose(before, after, uid, f"-d {admitted6[0]}/128 -j RETURN") >= 1,
               f"uid {uid}'s connection to an IPv6 address of its listed host passed on its own IPv6 chain",
               {"codes": codes, "chain": chain6})
    else:
        print(f"skip: no IPv6 address of {LISTED_HOST} for uid {uid}: its keeper resolved none at the spawn",
              flush=True)
    return chain


def tuple_reuse(stack, c, listed_uid, offline):
    """The unlisted program asks 1.1.1.1:53 from UDP port REUSE_PORT; the listed one, reusing that tuple, is refused."""
    if offline:
        print("skip: the UDP tuple's reuse is not shown: CYFR_TEST_OFFLINE=1 says no public resolver answers here, "
              "and the kernel tracks an exchange only once it is answered", flush=True)
        return
    argv = ["node", "-e", UDP_REUSE_PROBE, "reuse", REUSE_PORT, "1.1.1.1", "53"]
    first = run_in(c, OPEN, argv)
    expect(first["stdout"].strip() == "reply=yes",
           f"the program without hosts asks 1.1.1.1:53 from its UDP port {REUSE_PORT} and is answered", first)
    before = stack.guard_counters()
    second = run_in(c, LISTED, argv)
    after = stack.guard_counters()
    expect(second["stdout"].strip() == "send=EPERM",
           "the listed program, reusing that tuple while the kernel still tracks the exchange, is refused", second)
    expect(chain_rose(before, after, listed_uid, "-j REJECT") >= 1,
           f"the refusal counted on uid {listed_uid}'s own chain", {k: v for k, v in after.items() if f"U{listed_uid}" in k})


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
        chain = held_to_list(stack, c, LISTED, listed_uid, offline)

        # ————— a second uid, its row naming no hosts —————
        open_uid = uid_of(c, OPEN)
        expect(open_uid != listed_uid and uid_chain(stack, open_uid) is None,
               "a program whose row names no hosts has no chain at the guard", [open_uid, uid_chain(stack, open_uid)])
        codes = connect(c, OPEN, [METADATA] + ([] if offline else [UNLISTED]))
        expect(codes.get(METADATA) in REFUSED, "a program without hosts is refused a metadata address, as today", codes)
        if offline:
            print(f"skip: {UNLISTED} is not reached from the unlisted program: CYFR_TEST_OFFLINE=1 says this host has "
                  "no public network", flush=True)
        else:
            expect(codes.get(UNLISTED) == "connected",
                   "the program without hosts reaches the public address the listed one is refused", codes)

        # ————— a tracked UDP exchange serves no other uid —————
        tuple_reuse(stack, c, listed_uid, offline)

        # ————— a kept program, outside the pool —————
        kept_uid = uid_of(c, KEPT, home_id=KEPT_ENTRY)
        expect(KEPT_FIRST <= kept_uid <= KEPT_LAST, "the kept program runs under a uid of the kept range", kept_uid)
        held_to_list(stack, c, KEPT, kept_uid, offline, home_id=KEPT_ENTRY)

        # ————— a name that resolves to nothing —————
        status, answer = c.open(NOWHERE, "probe", key="k")
        expect((status, answer) == (STATUSES["hosts_unresolved"], {"version": VERSION, "error": "hosts_unresolved"}),
               "an open whose hosts resolve to no address is refused hosts_unresolved", [status, answer])
        expect(c.program(NOWHERE)["sessions"] == 0, "and nothing of it runs")

        # ————— the guard's check proves what it admitted —————
        expect(stack.guard_exec("cyfr-guard check").returncode == 0, "the guard is healthy with the uids' rules in")

        # A legitimate change after a uid's chain was removed behind the
        # guard's back records nothing of that removal: the kept uid's jump
        # and chains go, then the guard admits and clears a spare pool uid
        # no program runs under, and the check still fails.
        spare = POOL_LAST
        kept_addresses = [m.group(1) for tool in ("iptables", "ip6tables") for rule in uid_chain(stack, kept_uid, tool) or []
                          for m in [re.search(r"-d (\S+)/\d+ -j RETURN", rule)] if m]
        expect(kept_addresses, f"uid {kept_uid}'s chains return the addresses its keeper admitted", kept_addresses)
        tampered = stack.guard_exec(" && ".join(
            f"{tool} -D CYFR_GUARD_HOSTS -m owner --uid-owner {kept_uid} -j CYFR_GUARD_U{kept_uid} && "
            f"{tool} -F CYFR_GUARD_U{kept_uid} && {tool} -X CYFR_GUARD_U{kept_uid}" for tool in ("iptables", "ip6tables")))
        expect(tampered.returncode == 0, f"uid {kept_uid}'s jump and chains are removed behind the guard's back",
               tampered.stderr)
        changed = stack.guard_exec(f"cyfr-guard admit {spare} 203.0.113.9 && cyfr-guard clear {spare}")
        expect(changed.returncode == 0, f"the guard admits and clears uid {spare}", changed.stdout + changed.stderr)
        stale = stack.guard_exec("cyfr-guard check")
        expect(stale.returncode != 0 and "not the ones the guard admitted" in stale.stderr,
               f"the check still fails for uid {kept_uid}'s missing chain after another uid's changes",
               stale.stdout + stale.stderr)
        readmitted = stack.guard_exec(f"cyfr-guard admit {kept_uid} {' '.join(kept_addresses)} && cyfr-guard check")
        expect(readmitted.returncode == 0, f"uid {kept_uid} admitted again as it was, the check passes",
               readmitted.stdout + readmitted.stderr)

        # One rule of an admission changed behind the guard's back fails the
        # check; restored where it stood, the check passes.
        returned = next(rule for rule in chain if rule.endswith("-j RETURN"))
        address = re.search(r"-d (\S+) -j RETURN", returned).group(1)
        removed = stack.guard_exec(f"iptables -D CYFR_GUARD_U{listed_uid} -d {address} -j RETURN && cyfr-guard check")
        expect(removed.returncode != 0 and f"uid {listed_uid}'s admission is not installed" in removed.stderr,
               "a uid's rule changed behind the guard's back fails its health check", removed.stdout + removed.stderr)
        restored = stack.guard_exec(f"iptables -I CYFR_GUARD_U{listed_uid} 1 -d {address} -j RETURN && cyfr-guard check")
        expect(restored.returncode == 0, "the rule restored where it stood, the check passes again",
               restored.stdout + restored.stderr)

        # ————— retirement clears; the keeper's loss refuses —————
        status, _answer, _ = c.release([LISTED])
        expect(status == 200, "the listed program's owner is released")
        eventually(lambda: uid_chain(stack, listed_uid) is None, f"uid {listed_uid}'s chain to be cleared at its retirement")
        run("docker", "kill", stack.container)
        lost = eventually(lambda: (lambda rules: rules if rules == [f"-N CYFR_GUARD_U{kept_uid}",
                                                                     f"-A CYFR_GUARD_U{kept_uid} -j REJECT --reject-with icmp-admin-prohibited"]
                                   else None)(uid_chain(stack, kept_uid)),
                          "the kept uid, admitted by the lost keeper, to be refused every public address")
        expect(lost and "refused every public address until their next spawn" in stack.guard_logs(),
               "the guard says the lost connection's uids are refused", stack.guard_logs()[-2000:])
        expect(stack.guard_exec("cyfr-guard check").returncode == 0, "the guard stays healthy through the keeper's loss")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
