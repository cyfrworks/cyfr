#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builder image isolates its builds, run as docker-compose.yml's locus-builds service.

- cyfr-locus holds exactly SETUID, SETGID and KILL; the release runs as
  locus with no capability and no Erlang distribution listener; the
  release refuses to serve builds when started without cyfr-locus, and to
  start at all with a control-plane variable in its environment.
- A build runs under a pooled uid, alone in its group, in a 0700 home,
  with none of the release's environment; it cannot read the release's
  /proc environ (which holds LOCUS_BUILDS_KEY) nor signal it.
- A build cannot list the home root nor read a concurrent build's tree,
  even knowing its path.
- No process of a build's uid survives the build — a daemon a build.rs
  starts in a session of its own, ignoring SIGTERM, included — and its
  home is gone when the response arrives.
- With a pool of one uid, what one build leaves outside its home (an entry
  in the home root, a directory tree it made unwritable, System V shared
  memory, semaphores and message queues, a POSIX message queue) is gone
  before the next build runs under the same uid; /tmp, /var/tmp, /dev/shm,
  /run and the release's run directory are not writable to it.
- Started without the `writable-cgroups=true` security option, as a
  deployment that lacks it would be, the service answers every build
  `unavailable`, naming the option, and runs nothing: no build is ever run
  without its memory bound (tests/builder-image/memory.py proves the bound).
- The builder listens in the namespace of its egress guard, the image under
  test holding NET_ADMIN alone, and a build leaves only through the guard's
  rules: its connections to cyfr's name on the builds network and to
  cyfr's fixed endpoint address (a stand-in answers both to a container
  outside the guard), to the metadata and link-local addresses of both
  families, to other private addresses (RFC 1918, CGNAT, benchmarking, a
  NAT64 form of a private address) and to the island's own loopback are
  refused at once, and its datagrams to an IPv4 and an IPv6 multicast
  group are refused as they are sent, each counted on the guard's own
  rule; the resolver and the public registry are reached (the registry
  step is skipped, with its reason, under CYFR_TEST_OFFLINE=1).
- A build's listener on the shared loopback is reached by the container's
  root and refused to a concurrent build of another uid, on the loopback,
  on `::1` and on the island's own address.
- A guard started with an ip6tables that fails writes no ready file, never
  turns healthy, names the rule that failed, and the builder behind it is
  never started.
- A guard whose rule table of either family cannot be read is not healthy:
  its probe refuses while the read fails, Docker sees it unhealthy, and
  once the read works again the probe compares the rules in place with the
  ones recorded, so a chain cleared behind the probe's back is refused too;
  a guard whose table cannot be read as it starts records no ready file.

Usage: tests/builder-image/isolation.py IMAGE
"""

import ipaddress
import json
import os
import re
import shutil
import sys
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stack import (  # noqa: E402
    CONNECT_PROBE, ENDPOINT_ADDRESS, GUARD, HOME_ROOT, NETWORK, POOL_FIRST, POOL_LAST, PORT, PROJECT_PREFIX, REFUSED, RELEASE,
    RELEASE_BIN, RELEASE_UID, RELEASE_USER, ROLE, RUN_DIR, SERVICE, Stack, brief, build_canary, expect, output_file, run,
    tincture,
)

# On the path once stack.py is loaded.
import imagesuite  # noqa: E402

KEEPER_CAPS = "00000000000000e0"
TAG = "locus-builds-residue"
SHARED = [f"/tmp/{TAG}", f"/var/tmp/{TAG}", f"/dev/shm/{TAG}", f"/run/{TAG}", f"{RUN_DIR}/{TAG}"]
LEFT = [f"{HOME_ROOT}/{TAG}", f"{HOME_ROOT}/{TAG}-tree/"]

PROBE = r"""
set -u
mkdir -p dist
{
  echo "uid=$(id -u)"
  echo "user=$(id -un)"
  echo "gid=$(id -g)"
  echo "groups=$(id -G)"
  echo "home=$HOME"
  echo "home_mode=$(stat -c %a "$HOME")"
  echo "tmpdir=$TMPDIR"
  echo "caps=$(awk '/^CapEff:/ {print $2}' /proc/self/status)"
} > dist/who.txt
env > dist/env.txt
for d in /proc/[0-9]*; do
  if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q 'beam.smp'; then
    pid="${d#/proc/}"
    echo "pid=$pid" >> dist/release.txt
    cat "$d/environ" >> dist/release.txt 2>&1 || true
    kill -0 "$pid" >> dist/release.txt 2>&1 || true
  fi
done
ls "$(dirname "$HOME")" > dist/home-root.txt 2>&1 || true
"""

# Waits in a process whose command line carries its home, so the concurrent
# build can find the path and try it.
VICTIM = r"""
set -eu
mkdir -p dist src-secret
echo "victim secret" > src-secret/secret.txt
sh -c 'sleep 25; true' cyfr-victim-marker "$HOME"
echo done > dist/index.html
"""

INTRUDER = r"""
set -u
mkdir -p dist
home=""
for attempt in $(seq 1 40); do
  for d in /proc/[0-9]*; do
    line="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)" || continue
    case "$line" in *cyfr-victim-marker*) home="${line##*cyfr-victim-marker }"; home="${home%% *}";; esac
  done
  [ -n "$home" ] && break
  sleep 0.5
done
{
  echo "found=$home"
  ls "$home" 2>&1; echo "ls_status=$?"
  cat "$home/src/src-secret/secret.txt" 2>&1; echo "cat_status=$?"
  ls "$(dirname "$home")" 2>&1; echo "root_status=$?"
} > dist/probe.txt
"""

DAEMON_BUILD_RS = r"""
use std::process::{Command, Stdio};

fn main() {
    Command::new("setsid")
        .args(["sh", "-c", "trap '' TERM; exec sleep 1000"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("the daemon starts");
}
"""

LIB_RS = """#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::reagent::compute::Guest;

struct Daemon;
bindings::export!(Daemon with_types_in bindings);

impl Guest for Daemon {
    fn compute(input: String) -> String {
        input
    }
}
"""


# A build's connection probe: cyfr's name on the builds network and
# cyfr's fixed endpoint address (the stand-in answers both), the metadata
# and link-local addresses of both families, private addresses of each
# kind, Docker's resolver, the island's own loopback and, unless the host
# is offline, the public registry; and its datagram probe of a multicast
# group of each family. The resolver is also asked for cyfr's name, as a
# build asks for a registry's.
EGRESS = r"""
set -u
mkdir -p dist
getent hosts cyfr > dist/cyfr.txt 2>&1; echo "status=$?" >> dist/cyfr.txt
node probe.js targets "cyfr:4000" "@STAND_IN_V4@:4000" "[@STAND_IN_V6@]:4000" "@ENDPOINT@:4000" "169.254.169.254:80" \
  "100.100.100.200:80" "192.0.0.192:80" "[fd00:ec2::254]:80" "[fe80::1%eth0]:80" "10.1.2.3:80" "100.64.0.1:80" \
  "198.18.0.1:80" "[64:ff9b::a01:203]:80" "127.0.0.11:53" "127.0.0.1:1" @REGISTRY@ > dist/egress.txt 2>&1
node dgram.js targets "224.0.0.1:9" "[ff0e::1]:9" > dist/dgram.txt 2>&1
if [ -n "@REGISTRY@" ]; then
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://registry.npmjs.org/ > dist/registry.txt 2>&1
fi
"""

# A build that listens on the shared loopback, on every address, and waits
# for a concurrent build to try it; and that build, which tries the
# loopback, `::1` and the island's own address.
SIBLING_PORT = 47331
SIBLING_LISTENER = r"""
set -eu
mkdir -p dist
id -u > dist/uid.txt
node -e "require('http').createServer((q, s) => s.end('sibling ' + process.getuid())).listen(@PORT@, '::')" > dist/listener.log 2>&1 &
sleep 25
echo done > dist/index.html
""".replace("@PORT@", str(SIBLING_PORT))
SIBLING_INTRUDER = r"""
set -u
mkdir -p dist
id -u > dist/uid.txt
node probe.js targets "127.0.0.1:@PORT@" "[::1]:@PORT@" "@OWN@:@PORT@" > dist/sibling.txt 2>&1
""".replace("@PORT@", str(SIBLING_PORT))


# A probe of one datagram per target, run by node under a spawn's uid: for
# each `host:port` after the argument `targets` (an IPv6 host in
# brackets), the code the send answers with, or `sent`. A TCP connect to a
# multicast group is refused by the kernel before any rule sees it, so a
# group is probed with a datagram; the guard's rule drops it, which the
# send answers EPERM, since no ICMP error answers a multicast destination.
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


def pool_user(uid):
    """The name the image gives a build uid: the role's user prefix and the uid's two-digit ordinal in the pool (Dockerfile.locus)."""
    return f"{ROLE['user_prefix']}{uid - POOL_FIRST + 1:02d}"


def fields(text):
    return dict(line.split("=", 1) for line in (text or "").splitlines() if "=" in line)


def test_process_model(stack, image):
    procs = stack.processes()
    keeper = [p for p in procs if p["cmd"].startswith("cyfr-locus serve")]
    release = [p for p in procs if "beam.smp" in p["cmd"]]
    expect(len(keeper) == 1 and keeper[0]["uids"] == [0, 0, 0, 0] and keeper[0]["cap_eff"] == KEEPER_CAPS,
           "cyfr-locus runs as root holding exactly SETUID, SETGID and KILL", procs)
    expect(len(release) == 1 and release[0]["uids"] == [RELEASE_UID] * 4 and release[0]["cap_eff"] == "0000000000000000",
           f"the release runs as {RELEASE_USER} with no capability", procs)
    expect(not any("epmd" in p["cmd"] for p in procs) and "-sname" not in release[0]["cmd"] and " -name " not in release[0]["cmd"],
           "the release starts no Erlang distribution", release)
    # Docker's embedded DNS resolver listens on 127.0.0.11 (0B00007F) in every
    # container on a user-defined network.
    listening = stack.exec("cat /proc/net/tcp /proc/net/tcp6 | awk '$4 == \"0A\" {print $2}'").stdout.split()
    ports = sorted({int(address.rsplit(":", 1)[1], 16) for address in listening if not address.startswith("0B00007F:")})
    expect(ports == [PORT], f"besides Docker's resolver, the builder's only listening TCP port is {PORT}", listening)

    def start_alone(name, *env):
        return run("docker", "run", "--rm", "--name", f"{PROJECT_PREFIX}locus-builds-isolation-{name}-{os.getpid()}",
                   "-e", f"LOCUS_BUILDS_KEY={stack.key}", *env, "--entrypoint", RELEASE_BIN, image, "start", check=False, timeout=120)

    refused = start_alone("alone")
    expect(refused.returncode != 0 and "only through cyfr-locus" in refused.stdout + refused.stderr,
           "the release refuses to serve builds when started without cyfr-locus", refused.stdout + refused.stderr)
    refused = start_alone("keyring", "-e", "CYFR_CRYPTO_KEYRING=not-a-builders")
    expect(refused.returncode != 0 and "must not see CYFR_CRYPTO_KEYRING" in refused.stdout + refused.stderr
           and "not-a-builders" not in refused.stdout + refused.stderr,
           "the release refuses to start with a control-plane variable in its environment", refused.stdout + refused.stderr)


def test_build_identity(stack):
    status, answer = stack.build(tincture(PROBE), "javascript", "tincture")
    expect(status == 200, "a probe build succeeds", brief(answer))
    who = fields(output_file(answer, "who.txt"))
    uid = int(who["uid"])
    expect(POOL_FIRST <= uid <= POOL_LAST and who["gid"] == str(uid) and who["groups"] == str(uid),
           "a build runs under a pooled uid, alone in its group", who)
    expect(who["user"] == pool_user(uid), f"the build's uid is the image's {pool_user(uid)}", who)
    expect(re.fullmatch(rf"{HOME_ROOT}/{uid}-[0-9a-f]{{32}}", who["home"]) and who["home_mode"] == "700"
           and who["tmpdir"] == who["home"] + "/tmp" and who["caps"] == "0000000000000000",
           "its home is a 0700 directory of its own, TMPDIR is inside it and it holds no capability", who)

    env = output_file(answer, "env.txt")
    expect(stack.key not in env and not re.search(r"^(CYFR_|LOCUS_|RELEASE_|ERL_|ELIXIR_)", env, re.M),
           "none of the release's environment reaches a build", env)

    release = output_file(answer, "release.txt") or ""
    expect(release.startswith("pid=") and stack.key not in release
           and "Permission denied" in release and "Operation not permitted" in release,
           "a build can neither read the release's environ nor signal it", release)
    expect("Permission denied" in (output_file(answer, "home-root.txt") or ""),
           "a build cannot list the home root", output_file(answer, "home-root.txt"))


def test_concurrent_trees(stack):
    results = {}

    def build(name, script):
        results[name] = stack.build(tincture(script), "javascript", "tincture")

    victim = threading.Thread(target=build, args=("victim", VICTIM))
    victim.start()
    time.sleep(3)
    build("intruder", INTRUDER)
    victim.join()

    status, answer = results["intruder"]
    expect(status == 200, "the intruding build succeeds", brief(answer))
    probe = output_file(answer, "probe.txt") or ""
    found = fields(probe).get("found", "")
    expect(re.fullmatch(rf"{HOME_ROOT}/3\d{{4}}-[0-9a-f]{{32}}", found),
           "the intruding build found the concurrent build's home path", probe)
    expect("victim secret" not in probe and probe.count("Permission denied") >= 3
           and "ls_status=0" not in probe and "cat_status=0" not in probe and "root_status=0" not in probe,
           "it can neither list nor read the concurrent build's tree, nor list the home root", probe)
    expect(results["victim"][0] == 200, "the concurrent build completes undisturbed", brief(results["victim"][1]))


def test_no_survivors(stack):
    manifest_result = stack.exec(
        f"""{RELEASE_BIN} eval 'IO.puts("<<<" <> Locus.Builder.cargo_toml_for(:reagent) <> ">>>")'""", user=RELEASE_USER)
    manifest = manifest_result.stdout.split("<<<", 1)[1].split(">>>", 1)[0]
    status, answer = stack.build({"src/lib.rs": LIB_RS, "build.rs": DAEMON_BUILD_RS, "Cargo.toml": manifest}, "rust", "reagent")
    expect(status == 200, "a Rust build whose build.rs starts a daemon succeeds", brief(answer))
    survivors = stack.pool_processes()
    expect(survivors == [], "no process of the build's uid survives the build, its daemon included", survivors)
    expect(stack.homes() == [], "the build's home is gone when its response arrives", stack.homes())


def test_residue(stack):
    stack.up(pool=f"{POOL_FIRST}-{POOL_FIRST}")
    paths = " ".join(SHARED + LEFT)

    status, answer = stack.build(tincture(f"mkdir -p dist && /canary/canary plant {TAG} {paths} > dist/plant.json"),
                                 "javascript", "tincture")
    expect(status == 200, "a build plants canaries", brief(answer))
    planted = json.loads(output_file(answer, "plant.json"))
    expect(planted["uid"] == POOL_FIRST, "the first build runs under the pool's one uid", planted)
    expect(planted["files"] == {
        f"/tmp/{TAG}": "EROFS", f"/var/tmp/{TAG}": "EROFS", f"/dev/shm/{TAG}": "ENOENT", f"/run/{TAG}": "EROFS",
        f"{RUN_DIR}/{TAG}": "EACCES", f"{HOME_ROOT}/{TAG}": "ok", f"{HOME_ROOT}/{TAG}-tree/": "ok",
    }, "outside its home a build can write only into the home root", planted)
    expect(all(planted[kind] == "ok" for kind in ("shm", "sem", "msg", "mqueue")),
           "a build can create System V IPC objects and a POSIX message queue", planted)

    status, answer = stack.build(tincture(f"mkdir -p dist && /canary/canary probe {TAG} {paths} > dist/probe.json"),
                                 "javascript", "tincture")
    expect(status == 200, "a second build probes for them", brief(answer))
    probed = json.loads(output_file(answer, "probe.json"))
    expect(probed["uid"] == POOL_FIRST, "the second build runs under the same uid", probed)
    expect(probed["files"] == {
        f"/tmp/{TAG}": "absent", f"/var/tmp/{TAG}": "absent", f"/dev/shm/{TAG}": "absent", f"/run/{TAG}": "absent",
        f"{RUN_DIR}/{TAG}": "denied", f"{HOME_ROOT}/{TAG}": "absent", f"{HOME_ROOT}/{TAG}-tree/": "absent",
    } and all(probed[kind] == "absent" for kind in ("shm", "sem", "msg", "mqueue")),
        "nothing the first build left reaches the second", probed)
    sysvipc = stack.exec("cat /proc/sysvipc/shm /proc/sysvipc/sem /proc/sysvipc/msg; ls -A /dev/mqueue").stdout
    expect(str(POOL_FIRST) not in sysvipc and TAG not in sysvipc, "the kernel holds no IPC object of the uid", sysvipc)
    logs = stack.logs()
    expect("quarantined" not in logs and "outlived retirement" not in logs, "every build uid was retired clean", logs)


def island_address(stack):
    """The island's own address on the builds network: the guard's, whose namespace the builder shares."""
    return stack.inspect(stack.guard)["NetworkSettings"]["Networks"][f"{stack.project}_{NETWORK}"]["IPAddress"]


def stand_in_addresses(stack):
    """The stand-in's IPv4 and IPv6 addresses on the builds network, where it answers to cyfr's name."""
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


def test_egress(stack):
    guard, island = stack.inspect(stack.guard), stack.inspect(stack.container)
    # Docker spells a capability it was given with or without its CAP_ prefix.
    caps = [cap.removeprefix("CAP_") for cap in guard["HostConfig"]["CapAdd"] or []]
    expect(guard["Config"]["Image"] == stack.image and caps == ["NET_ADMIN"]
           and guard["HostConfig"]["CapDrop"] == ["ALL"] and guard["State"]["Health"]["Status"] == "healthy",
           "the guard is the image under test, holding NET_ADMIN alone, and healthy", guard["HostConfig"])
    expect(island["HostConfig"]["NetworkMode"] == f"container:{stack.guard}",
           "the builder shares its guard's network namespace", island["HostConfig"]["NetworkMode"])
    subnets = re.findall(r"island subnet (\S+)", stack.guard_logs())
    expect(subnets, "the guard found the island's subnets", stack.guard_logs())

    # The controls: outside the guard, both of cyfr's addresses answer.
    for network, url in [(NETWORK, "http://cyfr:4000/"), (RELEASE["endpoint_network"], f"http://{ENDPOINT_ADDRESS}:4000/")]:
        control = stack.beside(network, "curl", "-sS", "--max-time", "5", url)
        expect(control.returncode == 0 and control.stdout == "stand-in",
               f"the stand-in for cyfr answers {url} to a container on the {network} network outside the guard",
               control.stdout + control.stderr)

    offline = os.environ.get("CYFR_TEST_OFFLINE") == "1"
    registry = "" if offline else "registry.npmjs.org:443"
    stand_in_v4, stand_in_v6 = stand_in_addresses(stack)
    expect(stand_in_v4 and stand_in_v6, "the stand-in holds an address of each family on the builds network", [stand_in_v4, stand_in_v6])
    before = stack.guard_counters()
    script = (EGRESS.replace("@ENDPOINT@", ENDPOINT_ADDRESS).replace("@REGISTRY@", registry)
              .replace("@STAND_IN_V4@", stand_in_v4).replace("@STAND_IN_V6@", stand_in_v6))
    status, answer = stack.build(tincture(script, {"probe.js": CONNECT_PROBE, "dgram.js": DGRAM_PROBE}), "javascript", "tincture")
    expect(status == 200, "the egress probe build succeeds", brief(answer))
    after = stack.guard_counters()
    codes = fields(output_file(answer, "egress.txt"))
    datagrams = fields(output_file(answer, "dgram.txt"))
    detail = {"codes": codes, "datagrams": datagrams, "cyfr": output_file(answer, "cyfr.txt"),
              "registry": output_file(answer, "registry.txt")}
    expect(codes.get("cyfr:4000") in REFUSED and codes.get(f"{stand_in_v4}:4000") in REFUSED
           and codes.get(f"[{stand_in_v6}]:4000") in REFUSED and codes.get(f"{ENDPOINT_ADDRESS}:4000") in REFUSED,
           "a build's connections to cyfr:4000, to cyfr's address of each family on the builds network and to cyfr's fixed "
           "endpoint address are refused by the guard", detail)
    expect(codes.get("169.254.169.254:80") in REFUSED and codes.get("100.100.100.200:80") in REFUSED
           and codes.get("192.0.0.192:80") in REFUSED,
           "a build's connections to the IPv4 metadata addresses are refused", detail)
    expect(codes.get("[fd00:ec2::254]:80") in REFUSED and codes.get("[fe80::1%eth0]:80") not in (None, "connected"),
           "a build's connections to the IPv6 metadata and link-local addresses are refused", detail)
    expect(codes.get("10.1.2.3:80") in REFUSED, "a build's connection to another private address is refused", detail)
    expect(codes.get("100.64.0.1:80") in REFUSED and codes.get("198.18.0.1:80") in REFUSED
           and codes.get("[64:ff9b::a01:203]:80") in REFUSED,
           "a build's connections to a CGNAT address, a benchmarking address and the NAT64 form of a private address are refused",
           detail)
    expect(datagrams.get("224.0.0.1:9") == "EPERM" and datagrams.get("[ff0e::1]:9") == "EPERM",
           "a build's datagrams to an IPv4 and an IPv6 multicast group are refused as they are sent", detail)
    expect(codes.get("127.0.0.1:1") in REFUSED, "a build's connection to the island's loopback is refused", detail)
    expect(codes.get("127.0.0.11:53") == "connected" and "status=0" in (output_file(answer, "cyfr.txt") or ""),
           "a build reaches Docker's resolver, over TCP and for cyfr's name", detail)
    if offline:
        print("skip: registry.npmjs.org:443 is not reached from a build: CYFR_TEST_OFFLINE=1 says this host has no public network",
              flush=True)
    else:
        expect(codes.get("registry.npmjs.org:443") == "connected" and output_file(answer, "registry.txt") == "200",
               "a build reaches the public registry", detail)

    # Each refusal, and the resolver's exception, was the guard's own rule:
    # that rule's counter rose while the build ran. The island's subnets are
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


def test_sibling_loopback(stack):
    results = {}

    def build(name, script):
        results[name] = stack.build(tincture(script, {"probe.js": CONNECT_PROBE}), "javascript", "tincture")

    own = island_address(stack)
    listener = threading.Thread(target=build, args=("listener", SIBLING_LISTENER))
    listener.start()
    control = None
    for _ in range(150):
        control = stack.exec(f"curl -sS --max-time 2 http://127.0.0.1:{SIBLING_PORT}/")
        if control.returncode == 0 and control.stdout.startswith("sibling "):
            break
        time.sleep(0.1)
    expect(control is not None and control.stdout.startswith("sibling "),
           "a build's listener on the shared loopback answers the container's root", control and control.stdout + control.stderr)
    before = stack.guard_counters()
    build("intruder", SIBLING_INTRUDER.replace("@OWN@", own))
    listener.join()
    after = stack.guard_counters()

    status, answer = results["intruder"]
    expect(status == 200, "the intruding build succeeds", brief(answer))
    expect(results["listener"][0] == 200, "the listening build completes undisturbed", brief(results["listener"][1]))
    listening_uid = (output_file(results["listener"][1], "uid.txt") or "").strip()
    intruding_uid = (output_file(answer, "uid.txt") or "").strip()
    codes = fields(output_file(answer, "sibling.txt"))
    detail = {"codes": codes, "listener": listening_uid, "intruder": intruding_uid, "control": control.stdout}
    expect(listening_uid and intruding_uid and listening_uid != intruding_uid and control.stdout == f"sibling {listening_uid}",
           "the two builds ran under different uids, and the listener was the first's", detail)
    expect(all(codes.get(target) in REFUSED for target in [f"127.0.0.1:{SIBLING_PORT}", f"[::1]:{SIBLING_PORT}", f"{own}:{SIBLING_PORT}"]),
           "the other build's connections to the listener, on the loopback, on ::1 and on the island's own address, are refused", detail)
    rose = {rule: after.get(rule, 0) - before.get(rule, 0) for rule in after if "--dst-type LOCAL -j REJECT" in rule}
    expect(sum(rose.values()) >= 3, "each refusal counted on the guard's loopback rule for the island's uids", rose)


def test_guard_failure(image, canary):
    tools = imagesuite.temporary_directory("cyfr-guard-fails-", 0o755)
    with open(os.path.join(tools, "ip6tables"), "w") as f:
        f.write("#!/bin/sh\necho 'ip6tables: forced failure' >&2\nexit 1\n")
    os.chmod(os.path.join(tools, "ip6tables"), 0o755)
    stack = Stack("locus-builds-isolation-guard-fails", image, canary, guard_tools_dir=tools)
    try:
        refused = stack.up_refused()
        expect(refused.returncode != 0 and "dependency failed to start" in refused.stderr,
               "compose does not start the builder: its guard never turned healthy", refused.stdout + refused.stderr)
        guard = stack.compose("ps", "--all", "--quiet", GUARD).stdout.strip()
        island = stack.compose("ps", "--all", "--quiet", SERVICE).stdout.strip()
        expect(guard and island, "compose created the guard and the builder", [guard, island])
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
               "the builder behind the guard was never started", state)
    finally:
        stack.down()
        imagesuite.remove_directory(tools)


# A wrapper over one family's save tool, installed first on the guard's
# PATH by a test: it fails while the marker file named in it exists in the
# guard's tmpfs, and runs the image's own tool otherwise.
SAVE_WRAPPER = """#!/bin/sh
if [ -e /run/cyfr-guard/fail-@SAVE@ ]; then
  echo '@SAVE@: injected read failure' >&2
  exit 23
fi
exec /usr/sbin/@SAVE@ "$@"
"""
FAMILIES = (("iptables", "iptables-save"), ("ip6tables", "ip6tables-save"))


def test_guard_unreadable(image, canary):
    tools = imagesuite.temporary_directory("cyfr-guard-unreadable-", 0o755)

    def install(save, text):
        with open(os.path.join(tools, save), "w") as f:
            f.write(text)
        os.chmod(os.path.join(tools, save), 0o755)

    # A guard whose table cannot be read as it starts records no ready file
    # and starts no island: nothing is recorded of a table that was not read.
    for _table, save in FAMILIES:
        for other in FAMILIES:
            install(other[1], SAVE_WRAPPER.replace("@SAVE@", other[1]))
        install(save, f"#!/bin/sh\necho '{save}: injected read failure' >&2\nexit 23\n")
        stack = Stack("locus-builds-isolation-guard-unreadable", image, canary, guard_tools_dir=tools)
        try:
            refused = stack.up_refused()
            guard = stack.compose("ps", "--all", "--quiet", GUARD).stdout.strip()
            logs = run("docker", "logs", guard, check=False)
            text = logs.stdout + logs.stderr
            expect(refused.returncode != 0 and "dependency failed to start" in refused.stderr,
                   f"compose does not start the builder behind a guard whose {save} fails as it starts",
                   refused.stdout + refused.stderr + text[-2000:])
            expect(f"[cyfr-guard] error: {save} failed" in text and "ready:" not in text,
                   f"the guard named the failed {save} and wrote no ready file", text[-2000:])
        finally:
            stack.down()

    # A guard whose table stops reading later is not healthy while the read
    # fails, and once the read works again its probe compares the rules in
    # place with the ones recorded, so a chain cleared meanwhile is refused.
    for _table, save in FAMILIES:
        install(save, SAVE_WRAPPER.replace("@SAVE@", save))
    stack = Stack("locus-builds-isolation-guard-unreadable", image, canary, guard_tools_dir=tools)
    try:
        stack.up()
        healthy = stack.inspect(stack.guard)["State"]["Health"]["Status"]
        expect(healthy == "healthy", "the guard is healthy while both rule tables read", healthy)
        for table, save in FAMILIES:
            marker = f"/run/cyfr-guard/fail-{save}"
            stack.guard_exec(f"touch {marker}")
            probe = stack.guard_exec("cyfr-guard check")
            expect(probe.returncode != 0 and "could not be read" in probe.stderr,
                   f"the probe refuses while {save} fails, the rules standing", probe.stdout + probe.stderr)
            stack.guard_exec(f"{table} -F CYFR_GUARD")
            probe = stack.guard_exec("cyfr-guard check")
            expect(probe.returncode != 0, f"the probe refuses while {save} fails and the {table} chain is cleared",
                   probe.stdout + probe.stderr)
            stack.guard_exec(f"rm -f {marker}")
            probe = stack.guard_exec("cyfr-guard check")
            expect(probe.returncode != 0 and "not the ones recorded" in probe.stderr,
                   f"once {save} reads again, the probe refuses the cleared {table} chain", probe.stdout + probe.stderr)
        # Docker's own probe reaches the same verdict.
        for _ in range(600):
            if stack.inspect(stack.guard)["State"]["Health"]["Status"] == "unhealthy":
                break
            time.sleep(0.1)
        health = stack.inspect(stack.guard)["State"]["Health"]
        expect(health["Status"] == "unhealthy", "Docker sees the guard unhealthy once its rules are gone", health)
    finally:
        stack.down()
        imagesuite.remove_directory(tools)


def test_no_bound_no_build(stack):
    stack.up(writable_cgroups=False)
    options = json.loads(run("docker", "inspect", stack.container).stdout)[0]["HostConfig"]["SecurityOpt"]
    expect(options == ["no-new-privileges:true"], "the service is started without the writable-cgroups=true option", options)
    expect(all(toolchain["available"] for toolchain in stack.health["toolchains"].values()),
           "it starts and answers health as the shipped service does", stack.health)

    status, answer = stack.build(tincture("mkdir -p dist && id -u > dist/ran.txt"), "javascript", "tincture")
    expect(status == 503 and answer.get("class") == "unavailable" and "writable-cgroups=true" in answer.get("reason", ""),
           "a build is refused as unavailable, naming the option the service lacks", brief(answer))
    expect(stack.pool_processes() == [] and stack.homes() == [], "nothing of the build was run: no process of a pool uid, no home",
           [stack.pool_processes(), stack.homes()])
    status, again = stack.build(tincture("mkdir -p dist && id -u > dist/ran.txt"), "javascript", "tincture")
    expect(status == 503 and again.get("class") == "unavailable", "and so is the next: the service keeps refusing, and keeps running", brief(again))


def main(image):
    canary = build_canary()
    stack = Stack("locus-builds-isolation", image, canary)
    try:
        stack.up(stand_in=True)
        test_process_model(stack, image)
        test_build_identity(stack)
        test_concurrent_trees(stack)
        test_egress(stack)
        test_sibling_loopback(stack)
        test_no_survivors(stack)
        test_residue(stack)
        test_no_bound_no_build(stack)
    finally:
        stack.down()
    try:
        # After the first project is down: a second default network of the
        # fixed subnet could not exist beside the first's.
        test_guard_failure(image, canary)
        test_guard_unreadable(image, canary)
    finally:
        shutil.rmtree(canary, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
