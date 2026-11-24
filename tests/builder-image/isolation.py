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
- Every build runs in a space of its own, a user, network and IPC
  namespace, with its own loopback and one route, its guard's. The
  builder listens in the namespace of its egress guard, the image under
  test holding NET_ADMIN alone, and a build leaves only through its
  route's rules: its connections to cyfr's name on the builds network and
  to cyfr's fixed endpoint address (a stand-in answers both to a container
  outside the guard), to the IPv4 metadata addresses, to other private
  addresses (RFC 1918, CGNAT, benchmarking) and to the island's own
  address are refused at once, each counted on the guard's own rule; IPv6
  has no route out of a space; its names are answered by the guard on the
  space's own 127.0.0.11:53; and the public registry is reached (skipped,
  with its reason, under CYFR_TEST_OFFLINE=1).
- A build's name lookup reaches an upstream resolver the suite runs
  (tests/locus-backends-image/name-listener.mjs, beside the guard as its
  resolver's upstream), which hears the build's own name.
- A build's listener on its own loopback is its own: the container's root
  and a concurrent build of another uid find nothing there, and the other
  build listens on the same port at the same time, reaching its own.
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
import secrets
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
  "100.100.100.200:80" "192.0.0.192:80" "[fd00:ec2::254]:80" "10.1.2.3:80" "100.64.0.1:80" \
  "198.18.0.1:80" "[64:ff9b::a01:203]:80" "@OWN@:@PORT@" "127.0.0.11:53" "127.0.0.1:1" @REGISTRY@ > dist/egress.txt 2>&1
if [ -n "@REGISTRY@" ]; then
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://registry.npmjs.org/ > dist/registry.txt 2>&1
fi
"""

# A build that listens on its own loopback, on every address, and waits
# for a concurrent build to try that port; and that build, which tries the
# port on its own loopback and `::1`, then listens on it itself and reaches
# its own listener.
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
node probe.js targets "127.0.0.1:@PORT@" "[::1]:@PORT@" > dist/sibling.txt 2>&1
node -e "require('http').createServer((q, s) => s.end('own ' + process.getuid())).listen(@PORT@, '::')" > dist/listener.log 2>&1 &
sleep 1
curl -sS --max-time 3 http://127.0.0.1:@PORT@/ > dist/own.txt 2>&1
kill %1
""".replace("@PORT@", str(SIBLING_PORT))
# A space has no IPv6 route: an IPv6 connection never leaves it. Its own
# loopback with nothing listening refuses at once.
UNROUTED = ("ENETUNREACH",)
OWN_NOTHING = ("ECONNREFUSED",)


def pool_user(uid):
    """The name the image gives a build uid: the role's user prefix and the uid's two-digit ordinal in the pool (Dockerfile.locus)."""
    return f"{ROLE['user_prefix']}{uid - POOL_FIRST + 1:02d}"


def fields(text):
    return dict(line.split("=", 1) for line in (text or "").splitlines() if "=" in line)


def listening_addresses(stack):
    """The local address of each listening TCP socket of the container, in hex, from its own tables."""
    return imagesuite.read_output(stack.exec("awk '$4 == \"0A\" {print $2}' /proc/net/tcp /proc/net/tcp6"),
                                  "the container's TCP tables").split()


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
    listening = listening_addresses(stack)
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


def ipc_tables(stack):
    """The kernel's System V IPC tables and the POSIX queue directory, as text: an answer only from a command that exits 0."""
    done = stack.exec("cat /proc/sysvipc/shm /proc/sysvipc/sem /proc/sysvipc/msg && ls -A /dev/mqueue")
    return imagesuite.read_output(done, "the kernel's IPC tables")


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
    sysvipc = ipc_tables(stack)
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
    own = island_address(stack)
    before = stack.guard_counters()
    script = (EGRESS.replace("@ENDPOINT@", ENDPOINT_ADDRESS).replace("@REGISTRY@", registry)
              .replace("@STAND_IN_V4@", stand_in_v4).replace("@STAND_IN_V6@", stand_in_v6)
              .replace("@OWN@", own).replace("@PORT@", str(PORT)))
    status, answer = stack.build(tincture(script, {"probe.js": CONNECT_PROBE}), "javascript", "tincture")
    expect(status == 200, "the egress probe build succeeds", brief(answer))
    after = stack.guard_counters()
    codes = fields(output_file(answer, "egress.txt"))
    detail = {"codes": codes, "cyfr": output_file(answer, "cyfr.txt"), "registry": output_file(answer, "registry.txt")}
    expect(codes.get("cyfr:4000") in REFUSED and codes.get(f"{stand_in_v4}:4000") in REFUSED
           and codes.get(f"{ENDPOINT_ADDRESS}:4000") in REFUSED and codes.get(f"{own}:{PORT}") in REFUSED,
           "a build's connections to cyfr:4000, to cyfr's address on the builds network, to cyfr's fixed endpoint address "
           "and to the island's own address are refused by the guard", detail)
    expect(codes.get("169.254.169.254:80") in REFUSED and codes.get("100.100.100.200:80") in REFUSED
           and codes.get("192.0.0.192:80") in REFUSED,
           "a build's connections to the IPv4 metadata addresses are refused", detail)
    expect(codes.get("10.1.2.3:80") in REFUSED and codes.get("100.64.0.1:80") in REFUSED and codes.get("198.18.0.1:80") in REFUSED,
           "a build's connections to another private, a CGNAT and a benchmarking address are refused", detail)
    expect(all(codes.get(t) in UNROUTED for t in [f"[{stand_in_v6}]:4000", "[fd00:ec2::254]:80", "[64:ff9b::a01:203]:80"]),
           "a build's IPv6 connections, metadata, cyfr's and a NAT64 form of a private address among them, have no route "
           "out of its space", detail)
    expect(codes.get("127.0.0.1:1") in OWN_NOTHING, "a build's own loopback holds nothing of anyone else's", detail)
    expect(codes.get("127.0.0.11:53") == "connected" and "status=0" in (output_file(answer, "cyfr.txt") or ""),
           "a build's names are answered on its own 127.0.0.11:53, over TCP and for cyfr's name", detail)
    if offline:
        print("skip: registry.npmjs.org:443 is not reached from a build: CYFR_TEST_OFFLINE=1 says this host has no public network",
              flush=True)
    else:
        expect(codes.get("registry.npmjs.org:443") == "connected" and output_file(answer, "registry.txt") == "200",
               "a build reaches the public registry", detail)

    # Each refusal was the guard's own rule for every space: that rule's
    # counter rose while the build ran.
    rose = {rule: after.get(rule, 0) - before.get(rule, 0) for rule in after}
    matched = {fragment: any(count > 0 for rule, count in rose.items() if fragment in rule)
               for fragment in ["CYFR_GUARD_REFUSE -d 169.254.0.0/16", "CYFR_GUARD_REFUSE -d 100.100.100.200/32",
                                "CYFR_GUARD_REFUSE -d 192.0.0.192/32", f"CYFR_GUARD_REFUSE -d {ENDPOINT_ADDRESS}/32",
                                "CYFR_GUARD_PRIVATE -d 10.0.0.0/8", "CYFR_GUARD_PRIVATE -d 100.64.0.0/10",
                                "CYFR_GUARD_PRIVATE -d 198.18.0.0/15"]}
    matched["the island subnet holding cyfr"] = island_rule_counted(rose, subnets, stand_in_v4)
    expect(all(matched.values()), "each refusal counted on the guard's own rule", {"rose": rose, "matched": matched})
    answered = None
    for _ in range(100):
        answered = re.search(r"route sp\d+ of spawn \S+ withdrawn; it answered [1-9]\d* names", stack.guard_logs())
        if answered:
            break
        time.sleep(0.1)
    expect(answered, "the build's route, withdrawn at its end, answered its names", stack.guard_logs()[-2000:])


def test_own_loopback(stack):
    results = {}

    def build(name, script):
        results[name] = stack.build(tincture(script, {"probe.js": CONNECT_PROBE}), "javascript", "tincture")

    listener = threading.Thread(target=build, args=("listener", SIBLING_LISTENER))
    listener.start()
    # The listening build is running once its pool uid has a process.
    for _ in range(150):
        if stack.pool_processes():
            break
        time.sleep(0.1)
    time.sleep(1)
    control = stack.exec(f"curl -sS --max-time 2 http://127.0.0.1:{SIBLING_PORT}/ 2>&1; echo status=$?")
    expect("status=7" in control.stdout, "the container's root finds nothing on the build's port: the listener is in its space",
           control.stdout)
    build("intruder", SIBLING_INTRUDER)
    listener.join()

    status, answer = results["intruder"]
    expect(status == 200, "the other build succeeds", brief(answer))
    expect(results["listener"][0] == 200, "the listening build completes undisturbed", brief(results["listener"][1]))
    listening_uid = (output_file(results["listener"][1], "uid.txt") or "").strip()
    intruding_uid = (output_file(answer, "uid.txt") or "").strip()
    codes = fields(output_file(answer, "sibling.txt"))
    own = (output_file(answer, "own.txt") or "").strip()
    detail = {"codes": codes, "listener": listening_uid, "intruder": intruding_uid, "own": own}
    expect(listening_uid and intruding_uid and listening_uid != intruding_uid,
           "the two builds ran at once under different uids", detail)
    expect(all(codes.get(target) in OWN_NOTHING for target in [f"127.0.0.1:{SIBLING_PORT}", f"[::1]:{SIBLING_PORT}"]),
           "the other build finds nothing on that port of its own loopback, on 127.0.0.1 and ::1", detail)
    expect(own == f"own {intruding_uid}", "the other build listens on the same port at once and reaches its own listener", detail)


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


def test_names(image, canary):
    """A build's name reaches the suites' own name listener, upstream of the guard's resolver."""
    stack = Stack("locus-builds-isolation-names", image, canary, names=True)
    try:
        stack.up()
        asked = f"build-{secrets.token_hex(4)}.l5.test"
        status, answer = stack.build(tincture(f"mkdir -p dist && getent hosts {asked} > dist/name.txt 2>&1; echo status=$? >> dist/name.txt"),
                                     "javascript", "tincture")
        expect(status == 200, "the name build succeeds", brief(answer))
        got = output_file(answer, "name.txt") or ""
        expect("192.0.2.7" in got and "status=0" in got, f"a build resolves {asked}, which only the suites' name listener answers", got)
        expect(asked in stack.names_heard(), f"the name listener heard the build's {asked}", stack.names_heard())
    finally:
        stack.down()


def test_no_bound_no_build(stack):
    stack.up(writable_cgroups=False)
    options = json.loads(run("docker", "inspect", stack.container).stdout)[0]["HostConfig"]["SecurityOpt"]
    expect(options[0] == "no-new-privileges:true" and len(options) == 2 and options[1].startswith("seccomp=")
           and not any("writable-cgroups" in o for o in options),
           "the service is started without the writable-cgroups=true option, under the keeper's seccomp profile",
           [o[:60] for o in options])
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
        test_own_loopback(stack)
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
        test_names(image, canary)
    finally:
        shutil.rmtree(canary, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
