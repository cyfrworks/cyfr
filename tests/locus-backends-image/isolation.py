#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends image isolates its backends, run as docker-compose.yml's locus-backends service.

Driven only by requests signed as CYFR signs them (harness.py):

- cyfr-locus holds exactly SETUID, SETGID and KILL and no inet socket; the
  release runs as locus with no capability; the root is read-only, and an
  unsigned control or session message is refused.
- Each program's process runs under its own pooled uid, alone in its
  group, in a 0700 home, with an environment of its sealed block and the
  keeper's own variables alone, under the keeper's resource limits; one
  owner's key reaches no other owner's sessions; the program's own
  tools/list answers over its session.
- Every backend runs in a space of its own processes and files: it lists
  its own processes alone, under the space's init, and sees no other
  backend's, nor the release (which holds LOCUS_BACKENDS_KEY), a relay or
  cyfr-locus, so it can read no other's environment or command line and
  signal none of them; it sees its own home alone under the homes' root,
  no kept homes' root and no run folder of the service's.
- Releasing an owner retires every process of its uid, a detached daemon
  that ignores SIGTERM included, its relay and its home; a program that
  exits ends its session, is counted as a crash and retired, and the next
  call starts it again, initialized afresh, in a new home.
- The release refuses to start without a valid backends key; when it dies,
  cyfr-locus retires every backend and exits 70; when cyfr-locus is lost,
  the container ends with every backend in it; cyfr-locus refuses Docker's
  default capabilities; and stopping the service retires every backend.
- Every backend runs in a space of its own, a user, network and IPC
  namespace, with its own loopback and one route, its guard's. The service
  listens in the namespace of its egress guard, the image under test
  holding NET_ADMIN alone, and a backend leaves only through its route's
  rules: its connections to cyfr's name on the backends network and to
  cyfr's fixed endpoint address (a stand-in answers both to a container
  outside the guard), to the IPv4 metadata addresses, to other private
  addresses (RFC 1918, CGNAT, benchmarking) and to the island's own
  address are refused at once, each counted on the guard's own rule; IPv6
  has no route out of a space at all; its names are answered by the guard
  on the space's own 127.0.0.11:53, which the route's withdrawal counts;
  and the public registry is reached (skipped, with its reason, under
  CYFR_TEST_OFFLINE=1).
- A backend's listener on its own loopback is its own: the container's
  root and another owner's backend reach nothing there, and the other can
  listen on the same port at the same time, reaching its own.
- Two sessions of one kept folder, under one uid of the kept range, each
  listen on the same port of their own loopbacks and each reaches its own;
  neither reaches the service's listener. Each lists and signals only its
  own processes, has a /tmp of its own, sees no other home, terminal or
  group, reads its own memory cap at the root of its cgroup tree and can
  mount nothing. Two terminal sessions of that folder, open at once, each
  hold the space's first terminal and see no other.
- A session's name lookup reaches an upstream resolver the suite runs
  (name-listener.mjs, beside the guard as its resolver's upstream), which
  hears the session's own name.
- When the guard's control dies, the keeper kills every routed space at
  once: a session's processes are gone within a second, before any guard
  is dialled again.
- A guard started with an ip6tables that fails writes no ready file, never
  turns healthy, names the rule that failed, and the service behind it is
  never started.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/isolation.py IMAGE
"""

import ipaddress
import json
import os
import re
import secrets
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    CONNECT_PROBE, ENDPOINT_ADDRESS, GUARD, HOME_ROOT, KEEPER_CAPS, KEPT_FIRST, KEPT_LAST, KEPT_ROOT, NETWORK,
    POOL_FIRST, POOL_LAST, PORT,
    PROBE, PROJECT_PREFIX, REFUSED, RELEASE, RELEASE_BIN, RELEASE_UID, RELEASE_USER, ROLE, ROUTES, RUN_DIR, SERVICE,
    VERSION, Controller, Stack, eventually, expect, owner_of, owner_key, pool_user, post, probe, require_docker, run,
    image_user_name, wait_healthy, wire_json,
)

# On the path once harness.py is loaded.
import imagesuite  # noqa: E402

ALPHA, BETA = owner_of("alpha"), owner_of("beta")
KEPT_OWNER, KEPT_ENTRY = owner_of("kept"), "vlt_isolation-kept"
ALPHA_SECRET = "alpha-secret-value"
NO_CAPS = "0000000000000000"
PROBE_TOOLS = ["echo_env", "exit", "fail", "hog", "read_environ", "read_path", "run", "signal", "spawn_daemon",
               "whoami"]
OPEN = {"type": "open", "program": "probe", "key": "k", "mode": "run", "argv": []}
# A terminal's command: it names its terminal and every terminal its space
# lists, then waits for a line.
TTY = {"name": "tty", "home": "kept", "env": {},
       "command": """sh -c 'echo "tty=$(tty) pts=$(ls -A /dev/pts | tr "\\n" " ")."; read line' sh"""}
OWN_TERMINAL = b"tty=/dev/pts/0 pts=0 ptmx .\r\n"


def home_gone(stack, home):
    """Whether `home` is gone from the container, from the word its probe prints in a successful exec.

    A failed exec is no answer whatever its status.
    """
    probe = f"test -e {home} && echo present || echo absent"
    return imagesuite.read_word(stack.exec(probe), ("present", "absent"), f"the probe of {home}") == "absent"


def sync_probe(c, owner, env=None):
    status, answer, _ = c.sync(owner, [probe(env=env)])
    expect(status == 200, f"{owner['athanor']} is synced", answer)
    c.running(owner)
    report = c.report(owner)
    expect([(p["status"], p["sessions"]) for p in report["programs"]] == [("idle", 0)],
           f"{owner['athanor']}'s program is defined and nothing of it runs yet", report)


def inspect_pid(stack, image, script):
    """A script run beside the service, in its PID and network namespaces with CAP_SYS_PTRACE:
    cyfr-locus is not dumpable, so root inside the service cannot list its descriptors. The inspector runs under the
    service's own AppArmor profile, which lets a process of that profile alone read another's."""
    name = f"{stack.project}-inspect"
    run("docker", "rm", "--force", name, check=False)
    return run("docker", "run", "--rm", "--name", name, "--pid", f"container:{stack.container}",
               "--network", f"container:{stack.container}", "--cap-add", "SYS_PTRACE",
               "--security-opt", f"apparmor={imagesuite.APPARMOR}", "--entrypoint", "sh", image, "-c", script, check=False)


# A daemon of probe-backend.mjs's spawn_daemon, as its command line reads.
DAEMON = "sleep 1000000"


def own_processes(c, owner):
    """The pids a backend's /proc lists and the uid of each, from inside its space."""
    listed = c.tool(owner, "probe__run", {"argv": ["sh", "-c",
                                                   "for p in /proc/[0-9]*; do echo ${p#/proc/} $(awk '/^Uid:/ {print $2}' $p/status); done"]})
    expect(listed["status"] == 0, f"{owner['athanor']} lists its own processes", listed)
    return dict(tuple(map(int, line.split())) for line in listed["stdout"].splitlines() if len(line.split()) == 2)


# The ports backends listen on for the own-loopback cases.
SIBLING_PORT = 47331
KEPT_PORT = 47332

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


# A space has no IPv6 route: an IPv6 connection never leaves it.
UNROUTED = ("ENETUNREACH",)
# Its own loopback, nothing listening there.
OWN_NOTHING = ("ECONNREFUSED",)


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
    own = island_address(stack)
    targets = ["cyfr:4000", f"{stand_in_v4}:4000", f"[{stand_in_v6}]:4000", f"{ENDPOINT_ADDRESS}:4000", "169.254.169.254:80",
               "100.100.100.200:80", "192.0.0.192:80", "[fd00:ec2::254]:80", "10.1.2.3:80",
               "100.64.0.1:80", "198.18.0.1:80", "[64:ff9b::a01:203]:80", f"{own}:{PORT}", "127.0.0.11:53", "127.0.0.1:1"
               ] + ([] if offline else ["registry.npmjs.org:443"])
    before = stack.guard_counters()
    resolved = c.tool(owner, "probe__run", {"argv": ["getent", "hosts", "cyfr"]})
    probed = c.tool(owner, "probe__run", {"argv": ["node", "-e", CONNECT_PROBE, "targets", *targets]})
    fetched = None if offline else c.tool(owner, "probe__run", {"argv": ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                                                                           "--max-time", "8", "https://registry.npmjs.org/"]})
    after = stack.guard_counters()
    codes = fields(probed.get("stdout"))
    detail = {"codes": codes, "probe": probed, "resolved": resolved, "fetched": fetched}
    expect(probed["status"] == 0, "the backend's connection probe ran to its end", detail)
    expect(codes.get("cyfr:4000") in REFUSED and codes.get(f"{stand_in_v4}:4000") in REFUSED
           and codes.get(f"{ENDPOINT_ADDRESS}:4000") in REFUSED and codes.get(f"{own}:{PORT}") in REFUSED,
           "a backend's connections to cyfr:4000, to cyfr's address on the backends network, to cyfr's fixed endpoint "
           "address and to the island's own address are refused by the guard", detail)
    expect(codes.get("169.254.169.254:80") in REFUSED and codes.get("100.100.100.200:80") in REFUSED
           and codes.get("192.0.0.192:80") in REFUSED,
           "a backend's connections to the IPv4 metadata addresses are refused", detail)
    expect(codes.get("10.1.2.3:80") in REFUSED and codes.get("100.64.0.1:80") in REFUSED and codes.get("198.18.0.1:80") in REFUSED,
           "a backend's connections to another private, a CGNAT and a benchmarking address are refused", detail)
    expect(all(codes.get(t) in UNROUTED for t in [f"[{stand_in_v6}]:4000", "[fd00:ec2::254]:80", "[64:ff9b::a01:203]:80"]),
           "a backend's IPv6 connections, metadata, cyfr's and a NAT64 form of a private address among them, have no route "
           "out of its space", detail)
    expect(codes.get("127.0.0.1:1") in OWN_NOTHING,
           "a backend's own loopback holds nothing of anyone else's: nothing listens on its port 1", detail)
    expect(codes.get("127.0.0.11:53") == "connected" and resolved["status"] == 0 and "cyfr" in (resolved.get("stdout") or ""),
           "a backend's names are answered on its own 127.0.0.11:53, over TCP and for cyfr's name", detail)
    if offline:
        print("skip: registry.npmjs.org:443 is not reached from a backend: CYFR_TEST_OFFLINE=1 says this host has no public network",
              flush=True)
    else:
        expect(codes.get("registry.npmjs.org:443") == "connected" and fetched["status"] == 0 and fetched.get("stdout") == "200",
               "a backend reaches the public registry", detail)

    # Each refusal was the guard's own rule for every space: that rule's
    # counter rose while the backend probed.
    rose = {rule: after.get(rule, 0) - before.get(rule, 0) for rule in after}
    matched = {fragment: any(count > 0 for rule, count in rose.items() if fragment in rule)
               for fragment in ["CYFR_GUARD_REFUSE -d 169.254.0.0/16", "CYFR_GUARD_REFUSE -d 100.100.100.200/32",
                                "CYFR_GUARD_REFUSE -d 192.0.0.192/32", f"CYFR_GUARD_REFUSE -d {ENDPOINT_ADDRESS}/32",
                                "CYFR_GUARD_PRIVATE -d 10.0.0.0/8", "CYFR_GUARD_PRIVATE -d 100.64.0.0/10",
                                "CYFR_GUARD_PRIVATE -d 198.18.0.0/15"]}
    matched["the island subnet holding cyfr"] = island_rule_counted(rose, subnets, stand_in_v4)
    expect(all(matched.values()), "each refusal counted on the guard's own rule", {"rose": rose, "matched": matched})


# A listener that answers each connection with its word, started in the
# background of the backend's space, and a reader of 127.0.0.1:<port>.
def listen_script(port, word):
    return (f"setsid node -e \"require('net').createServer((s) => s.end('{word}')).listen({port}, '127.0.0.1')\""
            " >/dev/null 2>&1 & sleep 1")


def read_own(port):
    return ["node", "-e", f"require('net').connect({port}, '127.0.0.1').on('data', (d) => process.stdout.write(d))"
                          ".on('error', (e) => console.log(e.code))"]


def test_own_loopback(stack, c, listener, other):
    """`listener` and `other` are two owners whose backends run in spaces of their own."""
    started = c.tool(listener, "probe__run", {"argv": ["sh", "-c", listen_script(SIBLING_PORT, "listener")]})
    expect(started["status"] == 0, "a backend started a listener on its own loopback", started)
    mine = eventually(lambda: (lambda r: r if r.get("stdout") == "listener" else None)(
        c.tool(listener, "probe__run", {"argv": read_own(SIBLING_PORT)})), "the backend's listener to answer it")
    root = stack.exec(f"curl -sS --max-time 2 http://127.0.0.1:{SIBLING_PORT}/ 2>&1; echo status=$?")
    expect("status=7" in root.stdout, "the container's root finds nothing on that port: the listener is in the backend's space",
           root.stdout)
    probed = c.tool(other, "probe__run", {"argv": ["node", "-e", CONNECT_PROBE, "targets",
                                                    f"127.0.0.1:{SIBLING_PORT}", f"[::1]:{SIBLING_PORT}"]})
    codes = fields(probed.get("stdout"))
    expect(probed["status"] == 0 and codes.get(f"127.0.0.1:{SIBLING_PORT}") in OWN_NOTHING
           and codes.get(f"[::1]:{SIBLING_PORT}") in OWN_NOTHING,
           "another owner's backend finds nothing on that port of its own loopback, on 127.0.0.1 and ::1",
           {"codes": codes, "mine": mine})
    started = c.tool(other, "probe__run", {"argv": ["sh", "-c", listen_script(SIBLING_PORT, "other")]})
    theirs = eventually(lambda: (lambda r: r if r.get("stdout") == "other" else None)(
        c.tool(other, "probe__run", {"argv": read_own(SIBLING_PORT)})), "the other backend's listener on the same port")
    again = c.tool(listener, "probe__run", {"argv": read_own(SIBLING_PORT)})
    expect(again.get("stdout") == "listener", "two backends listen on one port at once, each reaching its own",
           {"listener": again, "other": theirs})


# The command's first instruction records the space's IPv6 addresses and
# IPv4 routes, as the kernel lists them in the space's own /proc/net.
STILL_COMMAND = ("sh -c 'cat /proc/net/if_inet6 /proc/net/route > \"$HOME/network-at-start\"; "
                 "exec node /probe/probe-backend.mjs'")
# Past an IPv6 address's duplicate address detection, which ends one to two
# seconds after its link comes up.
STILL_FOR_S = 5


def test_still_network(c):
    """A space's network is whole and still before its command starts: what the command found at its first instruction
    is what the space holds seconds later, and no link but the loopback has an IPv6 address to change."""
    owner = owner_of("still")
    status, answer, _ = c.sync(owner, [{"name": "probe", "command": STILL_COMMAND, "env": {}}])
    expect(status == 200, f"{owner['athanor']} is synced", answer)
    c.tool(owner, "probe__whoami")
    started = time.monotonic()
    at_start = c.tool(owner, "probe__run", {"argv": ["cat", "network-at-start"]})
    time.sleep(max(0, STILL_FOR_S - (time.monotonic() - started)))  # past any address's detection
    later = c.tool(owner, "probe__run", {"argv": ["cat", "/proc/net/if_inet6", "/proc/net/route"]})
    addresses = [line.split() for line in (at_start.get("stdout") or "").splitlines() if len(line.split()) == 6]
    expect(at_start["status"] == 0 and later["status"] == 0 and at_start["stdout"] == later["stdout"],
           f"what the command found at its start is what its space holds {STILL_FOR_S} s later",
           {"at start": at_start, "later": later})
    expect([a[5] for a in addresses] == ["lo"], "at the command's start only the loopback has an IPv6 address: the route's "
           "link has none, and any other link of the space, as Docker Desktop's tunnel devices, is down",
           addresses)
    c.release([owner])


def test_kept_terminals(c):
    """Two terminal sessions of one kept folder, open at once: each holds its space's first terminal and lists no
    other. Answers their sessions, still open."""
    terminals = []
    for key in ("tty-one", "tty-two"):
        status, opened = c.open(KEPT_OWNER, "tty", key=key, mode="terminal", rows=24, cols=80, home_id=KEPT_ENTRY)
        expect(status == 200 and opened.get("status") == "running", f"the terminal session {key} opens", opened)
        terminals.append(opened["session"])
    for session in terminals:
        read, _after, running = c.output_until(KEPT_OWNER, session, lambda read: b"." in read)
        expect(running and OWN_TERMINAL in read,
               "a terminal session of the kept folder holds its own first terminal and lists no other", read)
    return terminals


def test_kept_spaces(stack, run_kept, sessions, uid):
    """Two sessions of one kept folder each list and signal only their own, have a /tmp of their own, see no other
    home, terminal or group, read their own cap and can mount nothing, while two terminals of the folder are open."""
    first, second = sessions
    expect(run_kept(first, ["sh", "-c", "echo first > /tmp/mine"])["status"] == 0, "the first session writes its /tmp")
    seen = run_kept(second, ["cat", "/tmp/mine"])
    expect(seen["status"] != 0 and not seen["stdout"], "the second session's /tmp is its own", seen)
    listed = run_kept(second, ["sh", "-c", "for p in /proc/[0-9]*; do cat $p/cmdline | tr '\\0' ' '; echo; done"])
    expect([line.strip() for line in listed["stdout"].splitlines()].count(PROBE) == 1,
           "the second session lists its own program alone", listed)
    theirs = [stack.outside(json.loads(first.call("whoami", {})[1]["result"]["content"][0]["text"]))]
    for p in theirs:
        killed = run_kept(second, ["sh", "-c", f"kill -0 {p['pid']} 2>/dev/null || echo unsignalled"])
        own = run_kept(second, ["sh", "-c", f"test -e /proc/{p['pid']} && echo own || true"])
        expect(own["stdout"].strip() == "own" or killed["stdout"].strip() == "unsignalled",
               f"the second session signals no process of the first, pid {p['pid']} as the container numbers it", killed)
    views = run_kept(second, ["sh", "-c", f"ls -A {KEPT_ROOT}; echo pts:$(ls -A /dev/pts); "
                                          "echo groups:$(find /sys/fs/cgroup -mindepth 1 -type d | wc -l); "
                                          "echo cap:$(cat /sys/fs/cgroup/memory.max); "
                                          "mount -t tmpfs none /tmp 2>/dev/null && echo mounted || echo unmounted; "
                                          "unshare -m true 2>/dev/null && echo unshared || echo kept"])
    lines = views["stdout"].splitlines()
    expect(lines[0] == KEPT_ENTRY and "pts:ptmx" in lines and "groups:0" in lines and "unmounted" in lines and "kept" in lines,
           "the second session sees its own home alone, no other terminal or group, and mounts nothing", views)
    cap = next((l.split(":", 1)[1] for l in lines if l.startswith("cap:")), "")
    expect(cap.isdigit() and int(cap) > 0, "the second session reads its own memory cap at the root of its cgroup tree", views)


def test_kept_sessions(stack, c):
    """Two sessions of one kept folder, under one uid, each with its own loopback."""
    status, answer, _ = c.sync(KEPT_OWNER, [probe(home="kept"), TTY])
    expect(status == 200, "an owner of a kept program is synced", answer)
    sessions = [c.mcp(KEPT_OWNER, "probe", key=key, home_id=KEPT_ENTRY) for key in ("mcp", "second")]

    def run_kept(session, argv):
        status, answer = session.call("run", {"argv": argv})
        result = (answer or {}).get("result") or {}
        expect(status == 200 and not result.get("isError") and "content" in result, f"the kept session ran {argv[0]}",
               [status, answer])
        return json.loads(result["content"][0]["text"])

    whos = [json.loads(s.call("whoami", {})[1]["result"]["content"][0]["text"]) for s in sessions]
    uid = whos[0]["uid"]
    expect(all(KEPT_FIRST <= w["uid"] <= KEPT_LAST for w in whos) and whos[1]["uid"] == uid
           and whos[0]["pidns"] != whos[1]["pidns"] and all(stack.outside(w) for w in whos),
           "two sessions of the kept folder run under its one uid of the kept range, each in a space of its own", whos)
    terminals = test_kept_terminals(c)
    test_kept_spaces(stack, run_kept, sessions, uid)
    for session in terminals:
        c.close(KEPT_OWNER, session)
    for session, word in zip(sessions, ("first", "second")):
        expect(run_kept(session, ["sh", "-c", listen_script(KEPT_PORT, word)])["status"] == 0,
               f"the {word} session listens on port {KEPT_PORT} of its own loopback")
    for session, word in zip(sessions, ("first", "second")):
        got = eventually(lambda: (lambda r: r if r.get("stdout") == word else None)(run_kept(session, read_own(KEPT_PORT))),
                         f"the {word} session to reach its own listener")
        expect(got.get("stdout") == word, f"the {word} session reaches its own listener on the shared port", got)
    reached = run_kept(sessions[0], ["node", "-e", CONNECT_PROBE, "targets", f"127.0.0.1:{PORT}"])
    expect(fields(reached.get("stdout")).get(f"127.0.0.1:{PORT}") in OWN_NOTHING,
           "a kept session finds nothing of the service's on its own loopback", reached)
    for session in sessions:
        c.close(KEPT_OWNER, session.session)
    c.release([KEPT_OWNER])


def test_names(image):
    """A session's name reaches the suites' own name listener, upstream of the guard's resolver."""
    stack = Stack("locus-backends-isolation-names", image, names=True)
    try:
        stack.up()
        c = stack.controller()
        expect(c.hello()[0] == 200 and c.reconcile([])[0] == 200, "the service is greeted and reconciled")
        owner = owner_of("names")
        sync_probe(c, owner)
        asked = f"session-{secrets.token_hex(4)}.l5.test"
        resolved = c.tool(owner, "probe__run", {"argv": ["getent", "hosts", asked]})
        expect(resolved["status"] == 0 and "192.0.2.7" in (resolved.get("stdout") or ""),
               f"a session resolves {asked}, which only the suites' name listener answers", resolved)
        expect(asked in stack.names_heard(), f"the name listener heard the session's {asked}", stack.names_heard())
    finally:
        stack.down()


def test_guard_death(image):
    """The guard's control dies: every routed space is killed at once, before any redial."""
    stack = Stack("locus-backends-isolation-guard-dies", image)
    try:
        stack.up()
        c = stack.controller()
        expect(c.hello()[0] == 200 and c.reconcile([])[0] == 200, "the service is greeted and reconciled")
        owner = owner_of("guard-dies")
        sync_probe(c, owner)
        c.tool(owner, "probe__spawn_daemon")
        who = c.tool(owner, "probe__whoami")
        uid = who["uid"]
        eventually(lambda: stack.outside(who, DAEMON), "the session's daemon to start")
        control = stack.guard_exec("for p in /proc/[0-9]*; do grep -qa guard-control $p/cmdline 2>/dev/null && echo ${p#/proc/}; done")
        pids = control.stdout.split()
        expect(pids, "the guard's control runs", control.stdout + control.stderr)
        killed = time.monotonic()
        stack.guard_exec(f"kill -KILL {' '.join(pids)}")
        gone = eventually(lambda: not stack.under_uid(uid), f"every process of uid {uid} to be gone", timeout_s=5)
        took = time.monotonic() - killed
        expect(gone and took < 2.0, f"the keeper killed the routed session, daemon included, {took:.2f} s after the guard's "
               "control died (the poll's own cost included)", took)
        # The keeper says so once every group it killed is empty, which
        # comes just after the processes are seen gone.
        expect(eventually(lambda: "routed spaces are killed" in stack.logs(), "the keeper to say it killed the routed spaces"),
               "the keeper says it killed the routed spaces")
    finally:
        stack.down()


def kill_in(container, pid, what):
    """`kill -KILL pid` in `container`, where `pid` is, or ends, the
    container's main process. The shell exits 0 when it outlives its kill,
    and 137 when the container's end took the shell with it first: both
    say the kill reached `pid`. Any other status is a kill that did not,
    and the `docker wait` that follows would never return.
    """
    done = run("docker", "exec", container, "sh", "-c", f"kill -KILL {pid}", check=False)
    expect(done.returncode in (0, 137), what, {"status": done.returncode, "stderr": done.stderr.strip()})

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
        inspected = stack.inspect(guard)
        logs = run("docker", "logs", guard, check=False)
        text = logs.stdout + logs.stderr
        expect(imagesuite.guard_failed(inspected),
               "the guard never turned healthy: it ended with an error, and restarts",
               {"state": inspected["State"], "restarts": inspected["RestartCount"]})
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
        body = wire_json({**OPEN, "owner": {"athanor": ALPHA["athanor"], "server": ALPHA["server"]}, "e": 1,
                          "version": VERSION})
        for route in ["control", "session"]:
            status, _answer, _ = post(stack.base + ROUTES[route], {"content-type": "application/json"}, body)
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
            named = image_user_name(stack, who["uid"])
            expect(named == pool_user(who["uid"]), f"{name}'s uid is the image's {pool_user(who['uid'])}", named)
            expect(re.fullmatch(rf"{HOME_ROOT}/{who['uid']}-[0-9a-f]{{32}}", who["home"]) and who["home_mode"] == "700"
                   and who["marker_mode"] == "600" and who["tmpdir"] == "/tmp" and who["cwd"] == who["home"],
                   f"{name}'s home is its own, 0700, and its files are its own", who)
            # PWD is set by the backend's own `sh -c`.
            expect(who["env_names"] == ["HOME", "LOGNAME", "PATH", "PROBE_SECRET", "PWD", "TMPDIR", "USER"],
                   f"{name}'s environment is its sealed block and the keeper's own variables", who["env_names"])
            expect(who["limits"] == {"nofile": {"soft": "1024", "hard": "1024"}, "nproc": {"soft": "1024", "hard": "1024"},
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
        status, _answer, _, _ = c.session(ALPHA, OPEN, key=beta_key)
        expect(status == 401, "one owner's key reaches no other owner's sessions", status)
        listed = c.mcp(BETA, "probe").list_tools()
        expect(sorted(t["name"] for t in listed) == PROBE_TOOLS, "a program's own tools/list answers over its session",
               listed)

        # ————— no reach across —————
        relays = [p for p in stack.processes() if p["cmd"].startswith("cyfr-locus relay")]
        expect(len(relays) == 2 and all(p["uids"] == [RELEASE_UID] * 4 for p in relays),
               "one relay per backend, each the release's user", relays)
        for self_owner, other in [(ALPHA, beta), (BETA, alpha)]:
            def refused(tool, args, code, owner=self_owner):
                result = c.tool(owner, f"probe__{tool}", args)
                expect(result == {"ok": False, "code": code}, f"{owner['athanor']} {tool} {args} is refused {code}", result)

            me = alpha if self_owner is ALPHA else beta
            refused("read_path", {"path": other["marker"]}, "ENOENT")
            refused("read_path", {"path": other["home"]}, "ENOENT")
            refused("read_path", {"path": KEPT_ROOT}, "ENOENT")
            refused("read_path", {"path": RUN_DIR}, "ENOENT")
            homes = c.tool(self_owner, "probe__run", {"argv": ["ls", "-A", HOME_ROOT]})
            expect(homes["status"] == 0 and homes["stdout"].split() == [os.path.basename(me["home"])],
                   f"{self_owner['athanor']} sees its own home alone under the homes' root", homes)
            # Its space lists its own processes alone, so nothing of another
            # backend's, the release's, a relay's or cyfr-locus's has a pid
            # there: no environment or command line to read, no one to signal.
            own = own_processes(c, self_owner)
            expect(own and set(own.values()) == {me["uid"]} and me["pid"] in own,
                   f"{self_owner['athanor']} lists its own processes alone", own)
            theirs = stack.outside(other)
            expect(theirs is not None, f"{self_owner['athanor']}'s neighbour runs, as the container numbers it", theirs)
            for target in [theirs, release, keeper] + relays:
                # The two numberings are apart: a number of the container's
                # may also name a process of the space's own, never another's.
                there = c.tool(self_owner, "probe__run", {"argv": ["sh", "-c",
                    f"if [ -e /proc/{target['pid']} ]; then echo \"$(awk '/^Uid:/ {{print $2}}' /proc/{target['pid']}/status)"
                    f"|$(tr '\\0\\n|' '   ' < /proc/{target['pid']}/cmdline)\"; else echo absent; fi"]})
                said = there["stdout"].strip()
                if said != "absent":
                    uid, _, cmd = said.partition("|")
                    expect(uid == str(me["uid"]) and cmd.strip() != target["cmd"].strip(),
                           f"pid {target['pid']} in {self_owner['athanor']}'s space is a process of its own", there)
                    continue
                target = target["pid"]
                refused("read_environ", {"pid": target}, "ENOENT")
                refused("signal", {"pid": target, "sig": "SIGKILL"}, "ESRCH")
                seen = c.tool(self_owner, "probe__run", {"argv": ["cat", f"/proc/{target}/cmdline"]})
                expect(seen["status"] != 0 and not seen["stdout"],
                       f"{self_owner['athanor']} reads no command line of pid {target}, another's", seen)
        expect(c.tool(ALPHA, "probe__whoami")["pid"] == alpha["pid"] and c.tool(BETA, "probe__whoami")["pid"] == beta["pid"],
               "both backends survived each other's attempts")

        # ————— the island's egress —————
        test_egress(stack, c, ALPHA)
        test_own_loopback(stack, c, ALPHA, BETA)
        test_kept_sessions(stack, c)
        test_still_network(c)

        # ————— retirement —————
        c.tool(ALPHA, "probe__spawn_daemon")
        started = eventually(lambda: stack.outside(alpha, DAEMON), "the daemon to start")
        leader = stack.outside(alpha)
        expect(alpha["uid"] in started["uids"] and started["sid"] != leader["sid"],
               "the daemon runs as alpha's uid, in a session of its own", [started, leader])
        status, released, _ = c.release([ALPHA])
        expect(status == 200 and released["released"] == [{"athanor": ALPHA["athanor"], "server": ALPHA["server"],
                                                            "g": 1, "e": 1}],
               "the release names the version it released", released)
        eventually(lambda: not stack.under_uid(alpha["uid"]), f"no process of uid {alpha['uid']}, the daemon included")
        eventually(lambda: len([p for p in stack.processes() if p["cmd"].startswith("cyfr-locus relay")]) == 1,
                   "alpha's relay to end")
        expect(home_gone(stack, alpha["home"]), "alpha's home is gone")
        expect(c.tool(BETA, "probe__whoami")["pid"] == beta["pid"], "releasing alpha disturbed nothing of beta's")

        client = c.mcp(BETA, "probe")
        initialized = client.initializations
        c.tool(BETA, "probe__exit", {"code": 7})
        crashed = eventually(lambda: (lambda p: p if p["sessions"] == 0 and p["restarts"] == 1 else None)(
            c.program(BETA)), "beta's exit to end its session and count as a crash", timeout_s=30)
        expect(crashed["status"] == "idle" and "code=7" in (crashed.get("error") or ""),
               "the exit is reported, its status named, and nothing of beta's runs", crashed)
        eventually(lambda: home_gone(stack, beta["home"]), "the exited program's home to be scrubbed")
        again = c.tool(BETA, "probe__whoami")
        expect(again["home"] != beta["home"]
               and client.initializations == initialized + 1 and client.resumed is False,
               "the next call starts the program again, initialized afresh, in a new home", again)

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
        stack.alone_down("lost")
        stack.alone("lost", publish=True)
        try:
            base = "http://" + run("docker", "port", f"{lost}-guard", str(PORT)).stdout.strip().splitlines()[0]
            wait_healthy(base)
            orphan = Controller(base, stack.key)
            expect(orphan.hello()[0] == 200, "a second service is greeted")
            sync_probe(orphan, owner_of("orphan"))
            orphan.tool(owner_of("orphan"), "probe__spawn_daemon")
            orphan_who = orphan.tool(owner_of("orphan"), "probe__whoami")
            eventually(lambda: stack.outside(orphan_who, DAEMON, lost), "the orphan's daemon to start")
            _keeper, lost_release = keeper_and_release(stack, lost)
            kill_in(lost, lost_release["pid"], "the kill reached the release")
            expect(run("docker", "wait", lost).stdout.strip() == "70", "cyfr-locus exits 70 when the release dies")
            logs = run("docker", "logs", lost, check=False)
            text = logs.stdout + logs.stderr
            expect("client channel lost; every spawn retired" in text and "quarantined" not in text
                   and "did not finish" not in text, "every backend was retired cleanly", text[-3000:])
        finally:
            stack.alone_down("lost")

        stack.alone("lost")
        try:
            eventually(lambda: keeper_and_release(stack, lost)[1], "the third service's release to start", timeout_s=60)
            lost_keeper, _ = keeper_and_release(stack, lost)
            kill_in(lost, lost_keeper["pid"], "the kill reached cyfr-locus")
            code = run("docker", "wait", lost).stdout.strip()
            expect(code != "0", "losing cyfr-locus ends the container, and every backend in it", code)
        finally:
            stack.alone_down("lost")

        defaults = run("docker", "run", "--rm", "--name", f"{PROJECT_PREFIX}{stack.project}-defaults",
                       "-e", f"LOCUS_BACKENDS_KEY={stack.key.hex()}", "--entrypoint", "cyfr-locus", image,
                       "serve", "--role", imagesuite.role_spec(ROLE),
                       "--pool", f"{ROLE['pool']}:{POOL_FIRST}-{POOL_LAST}:{ROLE['reach']}",
                       "--home-root", RELEASE["home_root"], "--kept-homes", f"{KEPT_ROOT}:{KEPT_FIRST}-{KEPT_LAST}",
                       "--guard", imagesuite.Guard.CONTROL, "--", RELEASE_BIN, "start", check=False)
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
    test_guard_death(image)
    test_names(image)


if __name__ == "__main__":
    main()
