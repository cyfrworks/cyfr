#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends image isolates its backends, run as docker-compose.yml's locus-backends service.

Driven only by requests signed as CYFR signs them (harness.py):

- cyfr-locus holds exactly SETUID, SETGID and KILL and no inet socket; the
  release runs as locus with no capability; the root is read-only, and an
  unsigned control message or invoke is refused.
- Each backend runs under its own pooled uid, alone in its group, in a 0700
  home, with an environment of its sealed block and the keeper's own
  variables alone, under the keeper's resource limits; one owner's key
  reaches no other owner's backends.
- No backend can read another's home or /proc environ, or the release's
  (which holds LOCUS_BACKENDS_KEY), nor signal another backend, a relay,
  the release or cyfr-locus. Each reads another's command line, the limit
  README.md and integration-guide.md state: the service runs every backend
  in one process namespace with an ordinary /proc.
- Releasing an owner retires every process of its uid, a detached daemon
  that ignores SIGTERM included, its relay and its home; a backend that
  exits is retired and restarts ready in a new home.
- The release refuses to start without a valid backends key; when it dies,
  cyfr-locus retires every backend and exits 70; when cyfr-locus is lost,
  the container ends with every backend in it; cyfr-locus refuses Docker's
  default capabilities; and stopping the service retires every backend.
- The service listens in the namespace of its egress guard, the image under
  test holding NET_ADMIN alone, and a backend leaves only through the
  guard's rules: its connections to cyfr's name on the backends network
  and to cyfr's fixed endpoint address (a stand-in answers both to a
  container outside the guard), to the metadata and link-local addresses
  of both families, to other private addresses (RFC 1918, CGNAT,
  benchmarking, a NAT64 form of a private address) and to the island's own
  loopback are refused at once, and its datagrams to an IPv4 and an IPv6
  multicast group are refused as they are sent, each counted on the
  guard's own rule; the resolver and the public registry are reached (the
  registry step is skipped, with its reason, under CYFR_TEST_OFFLINE=1).
- A backend's listener on the shared loopback is reached by the container's
  root and refused to another owner's backend, on the loopback, on `::1`
  and on the island's own address.
- A guard started with an ip6tables that fails writes no ready file, never
  turns healthy, names the rule that failed, and the service behind it is
  never started.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/isolation.py IMAGE
"""

import ipaddress
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    CONNECT_PROBE, ENDPOINT_ADDRESS, GUARD, HOME_ROOT, KEEPER_CAPS, MCP_VERSION, NETWORK, POOL_FIRST, POOL_LAST, PORT,
    PROBE, PROJECT_PREFIX, REFUSED, RELEASE, RELEASE_BIN, RELEASE_UID, RELEASE_USER, ROLE, ROUTES, RUN_DIR, SERVICE,
    Controller, Stack, eventually, expect, owner_of, owner_key, pool_user, post, probe, require_docker, run,
    wait_healthy, wire_json,
)

# On the path once harness.py is loaded.
import imagesuite  # noqa: E402

ALPHA, BETA = owner_of("alpha"), owner_of("beta")
ALPHA_SECRET = "alpha-secret-value"
NO_CAPS = "0000000000000000"
PROBE_TOOLS = ["probe__echo_env", "probe__exit", "probe__fail", "probe__hog", "probe__read_environ",
               "probe__read_path", "probe__run", "probe__signal", "probe__spawn_daemon", "probe__whoami"]


def sync_probe(c, owner, env=None):
    status, answer, _ = c.sync(owner, [probe(env=env)])
    expect(status == 200, f"{owner['athanor']} is synced", answer)
    c.running(owner)
    report = c.report(owner)
    expect([b["status"] for b in report["backends"]] == ["ready"], f"{owner['athanor']}'s backend is ready", report)


def inspect_pid(stack, image, script):
    """A script run beside the service, in its PID and network namespaces with CAP_SYS_PTRACE:
    cyfr-locus is not dumpable, so root inside the service cannot list its descriptors."""
    name = f"{stack.project}-inspect"
    run("docker", "rm", "--force", name, check=False)
    return run("docker", "run", "--rm", "--name", name, "--pid", f"container:{stack.container}",
               "--network", f"container:{stack.container}", "--cap-add", "SYS_PTRACE", "--entrypoint", "sh",
               image, "-c", script, check=False)


# The port a backend listens on for the sibling case.
SIBLING_PORT = 47331

# A probe of one datagram per target, run by node as a backend: for each
# `host:port` after the argument `targets` (an IPv6 host in brackets), the
# code the send answers with, or `sent`. A TCP connect to a multicast group
# is refused by the kernel before any rule sees it, so a group is probed
# with a datagram; the guard's rule drops it, which the send answers EPERM,
# since no ICMP error answers a multicast destination.
DGRAM_PROBE = r"""
const dgram = require("dgram");
(async () => {
  const lines = [];
  for (const target of process.argv.slice(process.argv.indexOf("targets") + 1)) {
    const at = target.lastIndexOf(":");
    const host = target.slice(0, at).replace(/^\[|\]$/g, "");
    const code = await new Promise((resolve) => {
      const socket = dgram.createSocket(host.includes(":") ? "udp6" : "udp4");
      socket.on("error", (error) => { socket.close(); resolve(error.code || String(error)); });
      socket.send("probe", Number(target.slice(at + 1)), host, (error) => { socket.close(); resolve(error ? error.code || String(error) : "sent"); });
    });
    lines.push(`${target}=${code}`);
  }
  console.log(lines.join("\n"));
})();
"""


def fields(text):
    return dict(line.split("=", 1) for line in (text or "").splitlines() if "=" in line)


def island_address(stack):
    """The island's own address on the backends network: the guard's, whose namespace the service shares."""
    return stack.inspect(stack.guard)["NetworkSettings"]["Networks"][f"{stack.project}_{NETWORK}"]["IPAddress"]


def stand_in_addresses(stack):
    """The stand-in's IPv4 and IPv6 addresses on the backends network, where it answers to cyfr's name."""
    stand_in = stack.compose("ps", "--quiet", "cyfr-stand-in").stdout.strip()
    network = stack.inspect(stand_in)["NetworkSettings"]["Networks"][f"{stack.project}_{NETWORK}"]
    return network["IPAddress"], network["GlobalIPv6Address"]


def island_rule_counted(rose, subnets, address):
    """Whether a REJECT rule of one of the guard's logged island subnets, the one holding `address`, counted a packet."""
    ip = ipaddress.ip_address(address)
    logged = [ipaddress.ip_network(subnet, strict=False) for subnet in subnets]
    for rule, count in rose.items():
        found = re.search(r"-d (\S+) -j REJECT", rule)
        if not found or count <= 0:
            continue
        network = ipaddress.ip_network(found.group(1), strict=False)
        if network.version == ip.version and ip in network and network in logged:
            return True
    return False


def test_egress(stack, c, owner):
    guard, island = stack.inspect(stack.guard), stack.inspect(stack.container)
    # Docker spells a capability it was given with or without its CAP_ prefix.
    caps = [cap.removeprefix("CAP_") for cap in guard["HostConfig"]["CapAdd"] or []]
    expect(guard["Config"]["Image"] == stack.image and caps == ["NET_ADMIN"]
           and guard["HostConfig"]["CapDrop"] == ["ALL"] and guard["State"]["Health"]["Status"] == "healthy",
           "the guard is the image under test, holding NET_ADMIN alone, and healthy", guard["HostConfig"])
    expect(island["HostConfig"]["NetworkMode"] == f"container:{stack.guard}",
           "the service shares its guard's network namespace", island["HostConfig"]["NetworkMode"])
    subnets = re.findall(r"island subnet (\S+)", stack.guard_logs())
    expect(subnets, "the guard found the island's subnets", stack.guard_logs())

    # The controls: outside the guard, both of cyfr's addresses answer.
    for network, url in [(NETWORK, "http://cyfr:4000/"), (RELEASE["endpoint_network"], f"http://{ENDPOINT_ADDRESS}:4000/")]:
        control = stack.beside(network, "curl", "-sS", "--max-time", "5", url)
        expect(control.returncode == 0 and control.stdout == "stand-in",
               f"the stand-in for cyfr answers {url} to a container on the {network} network outside the guard",
               control.stdout + control.stderr)

    offline = os.environ.get("CYFR_TEST_OFFLINE") == "1"
    stand_in_v4, stand_in_v6 = stand_in_addresses(stack)
    expect(stand_in_v4 and stand_in_v6, "the stand-in holds an address of each family on the backends network", [stand_in_v4, stand_in_v6])
    targets = ["cyfr:4000", f"{stand_in_v4}:4000", f"[{stand_in_v6}]:4000", f"{ENDPOINT_ADDRESS}:4000", "169.254.169.254:80",
               "100.100.100.200:80", "192.0.0.192:80", "[fd00:ec2::254]:80", "[fe80::1%eth0]:80", "10.1.2.3:80",
               "100.64.0.1:80", "198.18.0.1:80", "[64:ff9b::a01:203]:80", "127.0.0.11:53", "127.0.0.1:1"
               ] + ([] if offline else ["registry.npmjs.org:443"])
    before = stack.guard_counters()
    resolved = c.tool(owner, "probe__run", {"argv": ["getent", "hosts", "cyfr"]})
    probed = c.tool(owner, "probe__run", {"argv": ["node", "-e", CONNECT_PROBE, "targets", *targets]})
    sent = c.tool(owner, "probe__run", {"argv": ["node", "-e", DGRAM_PROBE, "targets", "224.0.0.1:9", "[ff0e::1]:9"]})
    fetched = None if offline else c.tool(owner, "probe__run", {"argv": ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                                                                           "--max-time", "8", "https://registry.npmjs.org/"]})
    after = stack.guard_counters()
    codes = fields(probed.get("stdout"))
    datagrams = fields(sent.get("stdout"))
    detail = {"codes": codes, "probe": probed, "datagrams": sent, "resolved": resolved, "fetched": fetched}
    expect(probed["status"] == 0 and sent["status"] == 0, "the backend's connection and datagram probes ran to their end", detail)
    expect(codes.get("cyfr:4000") in REFUSED and codes.get(f"{stand_in_v4}:4000") in REFUSED
           and codes.get(f"[{stand_in_v6}]:4000") in REFUSED and codes.get(f"{ENDPOINT_ADDRESS}:4000") in REFUSED,
           "a backend's connections to cyfr:4000, to cyfr's address of each family on the backends network and to cyfr's "
           "fixed endpoint address are refused by the guard", detail)
    expect(codes.get("169.254.169.254:80") in REFUSED and codes.get("100.100.100.200:80") in REFUSED
           and codes.get("192.0.0.192:80") in REFUSED,
           "a backend's connections to the IPv4 metadata addresses are refused", detail)
    expect(codes.get("[fd00:ec2::254]:80") in REFUSED and codes.get("[fe80::1%eth0]:80") not in (None, "connected"),
           "a backend's connections to the IPv6 metadata and link-local addresses are refused", detail)
    expect(codes.get("10.1.2.3:80") in REFUSED, "a backend's connection to another private address is refused", detail)
    expect(codes.get("100.64.0.1:80") in REFUSED and codes.get("198.18.0.1:80") in REFUSED
           and codes.get("[64:ff9b::a01:203]:80") in REFUSED,
           "a backend's connections to a CGNAT address, a benchmarking address and the NAT64 form of a private address are refused",
           detail)
    expect(datagrams.get("224.0.0.1:9") == "EPERM" and datagrams.get("[ff0e::1]:9") == "EPERM",
           "a backend's datagrams to an IPv4 and an IPv6 multicast group are refused as they are sent", detail)
    expect(codes.get("127.0.0.1:1") in REFUSED, "a backend's connection to the island's loopback is refused", detail)
    expect(codes.get("127.0.0.11:53") == "connected" and resolved["status"] == 0 and "cyfr" in (resolved.get("stdout") or ""),
           "a backend reaches Docker's resolver, over TCP and for cyfr's name", detail)
    if offline:
        print("skip: registry.npmjs.org:443 is not reached from a backend: CYFR_TEST_OFFLINE=1 says this host has no public network",
              flush=True)
    else:
        expect(codes.get("registry.npmjs.org:443") == "connected" and fetched["status"] == 0 and fetched.get("stdout") == "200",
               "a backend reaches the public registry", detail)

    # Each refusal, and the resolver's exception, was the guard's own rule:
    # that rule's counter rose while the backend probed. The island's subnets are
    # matched as networks, since the guard logs them in full and
    # ip6tables-save prints them compressed.
    rose = {rule: after.get(rule, 0) - before.get(rule, 0) for rule in after}
    matched = {fragment: any(count > 0 for rule, count in rose.items() if fragment in rule)
               for fragment in ["-d 169.254.0.0/16", "-d 100.100.100.200/32", "-d 192.0.0.192/32", f"-d {ENDPOINT_ADDRESS}/32",
                                "-d fe80::/10", "-d fd00:ec2::254/128", "-d 10.0.0.0/8", "-d 100.64.0.0/10",
                                "-d 198.18.0.0/15", "-d 64:ff9b::a00:0/104", "-d 224.0.0.0/4", "-d ff00::/8",
                                "--dst-type LOCAL -j REJECT", "--ctorigdst 127.0.0.11"]}
    for address in (stand_in_v4, stand_in_v6):
        matched[f"the island subnet holding {address}"] = island_rule_counted(rose, subnets, address)
    expect(all(matched.values()), "each refusal and the resolver's exception counted on the guard's own rule", {"rose": rose, "matched": matched})


def test_sibling_loopback(stack, c, listener, intruder):
    """`listener` and `intruder` are two owners whose backends run under different uids."""
    own = island_address(stack)
    started = c.tool(listener, "probe__run", {"argv": [
        "sh", "-c",
        f"setsid node -e \"require('http').createServer((q, s) => s.end('sibling ' + process.getuid())).listen({SIBLING_PORT}, '::')\""
        " >/dev/null 2>&1 & sleep 1"]})
    expect(started["status"] == 0, "a backend started a listener on the shared loopback", started)
    control = eventually(lambda: (lambda r: r if r.returncode == 0 and r.stdout.startswith("sibling ") else None)(
        stack.exec(f"curl -sS --max-time 2 http://127.0.0.1:{SIBLING_PORT}/")), "the backend's listener to answer the container's root")
    listening_uid = str(c.tool(listener, "probe__whoami")["uid"])
    expect(control.stdout == f"sibling {listening_uid}", "the listener on the shared loopback is the backend's", control.stdout)
    before = stack.guard_counters()
    probed = c.tool(intruder, "probe__run", {"argv": ["node", "-e", CONNECT_PROBE, "targets",
                                                       f"127.0.0.1:{SIBLING_PORT}", f"[::1]:{SIBLING_PORT}", f"{own}:{SIBLING_PORT}"]})
    after = stack.guard_counters()
    codes = fields(probed.get("stdout"))
    detail = {"codes": codes, "probe": probed, "listener": listening_uid, "intruder": c.tool(intruder, "probe__whoami")["uid"]}
    expect(probed["status"] == 0 and all(codes.get(target) in REFUSED for target in codes) and len(codes) == 3,
           "another owner's backend's connections to the listener, on the loopback, on ::1 and on the island's own address, are refused",
           detail)
    rose = {rule: after.get(rule, 0) - before.get(rule, 0) for rule in after if "--dst-type LOCAL -j REJECT" in rule}
    expect(sum(rose.values()) >= 3, "each refusal counted on the guard's loopback rule for the island's uids", rose)


def test_guard_failure(image):
    tools = imagesuite.temporary_directory("cyfr-guard-fails-", 0o755)
    with open(os.path.join(tools, "ip6tables"), "w") as f:
        f.write("#!/bin/sh\necho 'ip6tables: forced failure' >&2\nexit 1\n")
    os.chmod(os.path.join(tools, "ip6tables"), 0o755)
    stack = Stack("locus-backends-isolation-guard-fails", image, guard_tools_dir=tools)
    try:
        refused = stack.up_refused()
        expect(refused.returncode != 0 and "dependency failed to start" in refused.stderr,
               "compose does not start the service: its guard never turned healthy", refused.stdout + refused.stderr)
        guard = stack.compose("ps", "--all", "--quiet", GUARD).stdout.strip()
        island = stack.compose("ps", "--all", "--quiet", SERVICE).stdout.strip()
        expect(guard and island, "compose created the guard and the service", [guard, island])
        state = stack.inspect(guard)["State"]
        logs = run("docker", "logs", guard, check=False)
        text = logs.stdout + logs.stderr
        expect(state.get("Health", {}).get("Status") != "healthy" and (state["ExitCode"] == 1 or state["RestartCount"] >= 1),
               "the guard never turned healthy: it ended with an error, and restarts", state)
        expect("[cyfr-guard] error: ip6tables" in text and "ready:" not in text,
               "the guard named the ip6tables rule that failed and wrote no ready file", text[-2000:])
        state = stack.inspect(island)["State"]
        expect(state["Status"] == "created" and state["StartedAt"].startswith("0001-"),
               "the service behind the guard was never started", state)
    finally:
        stack.down()
        imagesuite.remove_directory(tools)


def keeper_and_release(stack, target=None):
    procs = stack.processes(target)
    keeper = next((p for p in procs if p["cmd"].startswith("cyfr-locus serve")), None)
    release = next((p for p in procs if p["uids"] == [RELEASE_UID] * 4 and "beam.smp" in p["cmd"]), None)
    return keeper, release


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: isolation.py IMAGE")
    image = sys.argv[1]
    require_docker()
    stack = Stack("locus-backends-isolation", image)
    try:
        stack.up(stand_in=True)
        c = stack.controller()
        expect(c.hello()[0] == 200 and c.reconcile([])[0] == 200, "the service is greeted and reconciled")

        # ————— the service's own privileges —————
        keeper, release = keeper_and_release(stack)
        expect(keeper and release, "cyfr-locus and the locus release run", stack.processes())
        expect(keeper["uids"] == [0, 0, 0, 0] and keeper["cap_eff"] == KEEPER_CAPS and keeper["cap_prm"] == KEEPER_CAPS
               and keeper["cap_bnd"] == KEEPER_CAPS and keeper["no_new_privs"],
               "cyfr-locus holds exactly SETUID, SETGID and KILL, with no_new_privs", keeper)
        expect(release["cap_eff"] == NO_CAPS and release["cap_prm"] == NO_CAPS and release["no_new_privs"],
               f"the release runs as {RELEASE_USER} with no capability", release)

        fds = inspect_pid(stack, image, f"ls -l /proc/{keeper['pid']}/fd")
        sockets = re.findall(r"socket:\[(\d+)\]", fds.stdout)
        expect(sockets, "cyfr-locus holds its channel socket", fds.stdout + fds.stderr)
        inet = inspect_pid(stack, image, f"cat /proc/{keeper['pid']}/net/tcp /proc/{keeper['pid']}/net/tcp6 "
                                         f"/proc/{keeper['pid']}/net/udp /proc/{keeper['pid']}/net/udp6 2>/dev/null").stdout
        unix = inspect_pid(stack, image, f"cat /proc/{keeper['pid']}/net/unix").stdout
        for inode in sockets:
            expect(not re.search(rf"\b{inode}\b", inet) and re.search(rf"\b{inode}\b", unix),
                   f"cyfr-locus's socket {inode} is a unix socket, not an inet one")

        write = stack.exec("touch /app/planted 2>&1; echo status=$?")
        expect("Read-only file system" in write.stdout, "the root is read-only", write.stdout)
        body = wire_json({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}})
        for route in ["control", "mcp"]:
            status, _answer, _ = post(stack.base + ROUTES[route], {"content-type": "application/json",
                                                                   "mcp-protocol-version": MCP_VERSION,
                                                                   "mcp-method": "tools/list"}, body)
            expect(status == 401, f"an unsigned request to the {route} route is refused", status)

        # ————— each backend alone —————
        sync_probe(c, ALPHA, {"PROBE_SECRET": ALPHA_SECRET})
        sync_probe(c, BETA, {"PROBE_SECRET": "beta-secret-value"})
        alpha, beta = c.tool(ALPHA, "probe__whoami"), c.tool(BETA, "probe__whoami")
        expect(alpha["uid"] != beta["uid"], "two backends never share a uid", [alpha["uid"], beta["uid"]])
        for name, who in [("alpha", alpha), ("beta", beta)]:
            expect(POOL_FIRST <= who["uid"] <= POOL_LAST and who["gid"] == who["uid"]
                   and all(g == who["gid"] for g in who["groups"]),
                   f"{name} runs under a pooled uid, alone in its group", who)
            named = stack.exec(f"getent passwd {who['uid']} | cut -d: -f1").stdout.strip()
            expect(named == pool_user(who["uid"]), f"{name}'s uid is the image's {pool_user(who['uid'])}", named)
            expect(re.fullmatch(rf"{HOME_ROOT}/{who['uid']}-[0-9a-f]{{32}}", who["home"]) and who["home_mode"] == "700"
                   and who["marker_mode"] == "600" and who["tmpdir"] == f"{who['home']}/tmp" and who["cwd"] == who["home"],
                   f"{name}'s home is its own, 0700, and its files are its own", who)
            # PWD is set by the backend's own `sh -c`.
            expect(who["env_names"] == ["HOME", "LOGNAME", "PATH", "PROBE_SECRET", "PWD", "TMPDIR", "USER"],
                   f"{name}'s environment is its sealed block and the keeper's own variables", who["env_names"])
            expect(who["limits"] == {"nofile": {"soft": "1024", "hard": "1024"}, "nproc": {"soft": "128", "hard": "128"},
                                     "core": {"soft": "0", "hard": "0"},
                                     "fsize": {"soft": "268435456", "hard": "268435456"}},
                   f"{name} runs under the keeper's resource limits", who["limits"])
            for p in stack.under_uid(who["uid"]):
                expect(p["cap_eff"] == NO_CAPS and p["no_new_privs"], f"{name}'s process {p['pid']} holds no capability", p)

        # The release holds the key in its environment (every signed answer
        # above proves it is in use), and nothing in the container can read
        # that environment, root included: the container holds no
        # CAP_SYS_PTRACE, so /proc/<release>/environ reads back empty even
        # to `docker exec`. A backend's own environment is what it can see.
        expect(c.tool(ALPHA, "probe__echo_env", {"name": "LOCUS_BACKENDS_KEY"}) == {"value": None},
               "a backend's environment holds no backends key")

        beta_key = owner_key(stack.key, BETA["athanor"], BETA["server"], 1, 1)
        status, _answer, _, _ = c.invoke(ALPHA, "tools/call", {"name": "probe__whoami", "arguments": {}}, key=beta_key)
        expect(status == 401, "one owner's key reaches no other owner's backends", status)
        status, listed, _, _ = c.invoke(BETA, "tools/list")
        expect(sorted(t["name"] for t in listed["result"]["tools"]) == PROBE_TOOLS, "an owner lists its own tools", listed)

        # ————— no reach across —————
        relays = [p for p in stack.processes() if p["cmd"].startswith("cyfr-locus relay")]
        expect(len(relays) == 2 and all(p["uids"] == [RELEASE_UID] * 4 for p in relays),
               "one relay per backend, each the release's user", relays)
        for self_owner, other in [(ALPHA, beta), (BETA, alpha)]:
            def refused(tool, args, code, owner=self_owner):
                result = c.tool(owner, f"probe__{tool}", args)
                expect(result == {"ok": False, "code": code}, f"{owner['athanor']} {tool} {args} is refused {code}", result)

            refused("read_path", {"path": other["marker"]}, "EACCES")
            refused("read_path", {"path": other["home"]}, "EACCES")
            refused("read_path", {"path": HOME_ROOT}, "EACCES")
            refused("read_path", {"path": RUN_DIR}, "EACCES")
            refused("read_environ", {"pid": other["pid"]}, "EACCES")
            refused("read_environ", {"pid": release["pid"]}, "EACCES")
            for target in [other["pid"], release["pid"], keeper["pid"]] + [r["pid"] for r in relays]:
                refused("signal", {"pid": target, "sig": "SIGKILL"}, "EPERM")
            # The command line is the one thing of another backend's a backend
            # reads, which is why a definition keeps credentials out of it.
            seen = c.tool(self_owner, "probe__run", {"argv": ["cat", f"/proc/{other['pid']}/cmdline"]})
            expect(seen["status"] == 0 and seen["stdout"].split("\0") == PROBE.split() + [""],
                   f"{self_owner['athanor']} reads another backend's command line, never its environment", seen)
        expect(c.tool(ALPHA, "probe__whoami")["pid"] == alpha["pid"] and c.tool(BETA, "probe__whoami")["pid"] == beta["pid"],
               "both backends survived each other's attempts")

        # ————— the island's egress —————
        test_egress(stack, c, ALPHA)
        test_sibling_loopback(stack, c, ALPHA, BETA)

        # ————— retirement —————
        daemon = c.tool(ALPHA, "probe__spawn_daemon")["pid"]
        started = eventually(lambda: next((p for p in stack.processes() if p["pid"] == daemon), None), "the daemon to start")
        leader = next(p for p in stack.processes() if p["pid"] == alpha["pid"])
        expect(alpha["uid"] in started["uids"] and started["sid"] != leader["sid"],
               "the daemon runs as alpha's uid, in a session of its own", [started, leader])
        status, released, _ = c.release([ALPHA])
        expect(status == 200 and released["released"] == [{"athanor": ALPHA["athanor"], "server": ALPHA["server"],
                                                            "g": 1, "e": 1}],
               "the release names the version it released", released)
        eventually(lambda: not stack.under_uid(alpha["uid"]), f"no process of uid {alpha['uid']}, the daemon included")
        eventually(lambda: len([p for p in stack.processes() if p["cmd"].startswith("cyfr-locus relay")]) == 1,
                   "alpha's relay to end")
        expect(stack.exec(f"test -e {alpha['home']}").returncode == 1, "alpha's home is gone")
        expect(c.tool(BETA, "probe__whoami")["pid"] == beta["pid"], "releasing alpha disturbed nothing of beta's")

        c.tool(BETA, "probe__exit", {"code": 7})
        restarted = eventually(lambda: (lambda b: b if b["status"] == "ready" and b["restarts"] == 1 else None)(
            c.report(BETA)["backends"][0]), "beta to restart ready", timeout_s=30)
        again = c.tool(BETA, "probe__whoami")
        expect(restarted["tools"] == len(PROBE_TOOLS) and again["pid"] != beta["pid"] and again["home"] != beta["home"],
               "a backend that exits restarts ready in a new home", [restarted, again])
        expect(stack.exec(f"test -e {beta['home']}").returncode == 1, "the exited backend's home is gone")

        # ————— the service's lifetime —————
        for key in ["", "not-a-key", "00" * 31]:
            result = stack.compose("run", "--rm", "--no-deps", "-T", "-e", f"LOCUS_BACKENDS_KEY={key}", SERVICE,
                                   check=False)
            expect(result.returncode != 0 and "LOCUS_BACKENDS_KEY" in result.stdout + result.stderr,
                   f"the release refuses to start with the key {key!r}", result.stdout[-2000:] + result.stderr[-2000:])

        # A second instance of the service, in a namespace of its own
        # (harness.py `alone`): in the guard's it would meet the running
        # service's listener.
        lost = f"{stack.project}-lost"
        run("docker", "rm", "--force", lost, check=False)
        stack.alone("lost", publish=True)
        try:
            base = "http://" + run("docker", "port", lost, str(PORT)).stdout.strip().splitlines()[0]
            wait_healthy(base)
            orphan = Controller(base, stack.key)
            expect(orphan.hello()[0] == 200, "a second service is greeted")
            sync_probe(orphan, owner_of("orphan"))
            daemon = orphan.tool(owner_of("orphan"), "probe__spawn_daemon")["pid"]
            eventually(lambda: any(p["pid"] == daemon for p in stack.processes(lost)), "the orphan's daemon to start")
            _keeper, lost_release = keeper_and_release(stack, lost)
            run("docker", "exec", lost, "sh", "-c", f"kill -KILL {lost_release['pid']}")
            expect(run("docker", "wait", lost).stdout.strip() == "70", "cyfr-locus exits 70 when the release dies")
            logs = run("docker", "logs", lost, check=False)
            text = logs.stdout + logs.stderr
            expect("client channel lost; every spawn retired" in text and "quarantined" not in text
                   and "did not finish" not in text, "every backend was retired cleanly", text[-3000:])
        finally:
            run("docker", "rm", "--force", lost, check=False)

        stack.alone("lost")
        try:
            eventually(lambda: keeper_and_release(stack, lost)[1], "the third service's release to start", timeout_s=60)
            lost_keeper, _ = keeper_and_release(stack, lost)
            run("docker", "exec", lost, "sh", "-c", f"kill -KILL {lost_keeper['pid']}")
            code = run("docker", "wait", lost).stdout.strip()
            expect(code != "0", "losing cyfr-locus ends the container, and every backend in it", code)
        finally:
            run("docker", "rm", "--force", lost, check=False)

        defaults = run("docker", "run", "--rm", "--name", f"{PROJECT_PREFIX}{stack.project}-defaults",
                       "-e", f"LOCUS_BACKENDS_KEY={stack.key.hex()}", "--entrypoint", "cyfr-locus", image,
                       "serve", "--pool", f"{ROLE['pool']}:{POOL_FIRST}-{POOL_LAST}", "--home-root", HOME_ROOT,
                       "--client-user", RELEASE_USER, "--", RELEASE_BIN, "start", check=False)
        expect(defaults.returncode == 78 and "refusing to start: Cap" in defaults.stderr,
               "cyfr-locus refuses Docker's default capabilities", defaults.stderr[-2000:])

        last = owner_of("last")
        sync_probe(c, last)
        who = c.tool(last, "probe__whoami")
        c.tool(last, "probe__spawn_daemon")
        stack.compose("stop", SERVICE)
        code = run("docker", "inspect", "--format", "{{.State.ExitCode}}", stack.container).stdout.strip()
        text = stack.logs()
        expect(code == "0" and "[cyfr-locus] info: stopped" in text and "quarantined" not in text
               and "did not finish" not in text,
               f"stopping the service retires every backend, uid {who['uid']} included, and cyfr-locus exits 0",
               text[-3000:])
        expect(ALPHA_SECRET not in text, "a backend's credential never reaches the service's log")
    finally:
        stack.down()
    # After the first project is down: a second default network of the
    # fixed subnet could not exist beside the first's.
    test_guard_failure(image)


if __name__ == "__main__":
    main()
