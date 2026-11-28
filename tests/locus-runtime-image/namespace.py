#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Every runner of the Locus image runs in a relay space of its own, a user, network and IPC namespace, proven on the kernel.

cyfr-locus serves the image's runner pool as relay spaces, under the pool
and reach the role table names (stack.py reads them): it clones each
runner's stage into a new user, network and IPC namespace, maps the
runner's pooled uid and gid to themselves from the parent side, places the
stage in its cgroup, and only then releases it to drop every capability set
and execute the runner. The clone needs the image's seccomp profile
(apps/locus/keeper/seccomp/keeper.json, /etc/cyfr/keeper.json in the image) and a
host that allows unprivileged user namespaces; the service runs here under
that profile, as docker-compose.yml names it.

The steps, each observed from inside the container as root, which owns
every runner's user namespace and so reads a runner's /proc entries (the
runner's own uid, outside that namespace, may not):

- `refusals`: on a host that enforces AppArmor, the image under Docker's
  default AppArmor profile refuses to start, naming this release's
  profile; a routed keeper whose guard's socket is not there refuses
  to start, naming the socket; the image under Docker's default seccomp
  profile refuses to serve, naming user.max_user_namespaces and
  kernel.apparmor_restrict_unprivileged_userns; under the profile a spawn
  of the relay pool naming hosts, which it could never reach, is refused
  as bad_request, and so is one carrying `isolation`, which no request has.
- `connect`: a keeper started from the image under the profile, whose
  client is a shell speaking the keeper protocol, spawns a command of the
  relay pool that dials the container's own loopback and its gateway:
  both are unreachable from the command (no route exists), while the same
  dial from the container's own namespace is answered; the command has no
  resolver either, its name lookup failing at once, and an IPC namespace
  of its own.
- `names`: a keeper started from the image in the namespace of the suites'
  name listener (tests/locus-backends-image/name-listener.mjs), an
  upstream resolver the suite runs whose answers name each query: the
  client's lookup in the container's namespace reaches it and is answered,
  and a runner's same kind of lookup finds no resolver, and the listener
  never hears it.
- `relay`: under the profile a spawn of the relay pool gets its relay
  on fd 4, carried as the keeper's stream 5: with a client that opens the
  stream, the runner's call on fd 4 arrives there and the answer reaches
  it; with one that never opens it, the runner writes to fd 4 and exits
  and the client receives no frame on stream 5, its end frame included.
- `nested`: under the profile, which lets a clone make a user and network
  namespace so the keeper can isolate each spawn, a runner makes none of
  its own: its clone with CLONE_NEWUSER, alone or with CLONE_NEWNET, is
  refused EPERM, where the same clone without a namespace flag makes a
  child; `unshare -U` is refused; and it still starts a thread. It makes
  an AF_UNIX socket and socket pair, and is refused EPERM an AF_VSOCK one
  of each, and so with the domain's high bits set, which the kernel reads
  as AF_VSOCK; on x86_64 its 32-bit socketcall of AF_VSOCK makes no socket,
  and under the profile alone, outside any space, a 32-bit socketcall of
  AF_INET or AF_VSOCK is killed, as every 32-bit call is.
- `measure`: one real runner, the image's `/usr/local/bin/cyfr-runner` with its
  control channel and relay as the shipped service spawns it, its attach
  connection served by this machine as its worker service: its place is
  `warm` and no athanor's; once the keeper has read its group, a measure
  answers a reading above zero under that owner. Its place is assigned
  `run` for an athanor, each assign answered `assigned` under its own id,
  and only then is the runner sent real work of that athanor on its
  control stream: an attempt the scripted control plane minted, running
  hog.wasm (memory.py's), whose every host call the runner makes on its
  relay this machine posts to the plane and answers with the plane's
  answer. While the work holds the 64 MiB its emit `hog.holding` says it
  holds (the plane holds that emit's answer), a reading the keeper took
  after it is `run` of that athanor and holds at least half of those
  bytes more than the reading before the work was sent; the work then
  closes its attempt completed and the runner says on its control stream
  that it entered the work's authority and then `complete`, clean.
  Assigned `warm` for that athanor and `run` again for another run, each
  measure answers above zero under the owner of the moment; after its
  `release`, a measure sent with it is still answered with a reading
  before `released`, and one after `released` is `unmeasured`.
- `spawn`: the shipped service fills its warm floor; every runner runs under a
  pooled uid whose user namespace maps only that uid and gid to themselves
  with setgroups denied, and holds no capability in any of the five sets,
  with no_new_privs.
- `cgroup`: every runner is in its own group, /keeper-<uid>, at its bound.
- `network`: every runner's network and user namespaces are not the
  service's; its namespace has one interface, the loopback, and no route.
- `descriptors`: a runner's standard descriptors are pipes, its fd 3 is
  its control socket and its fd 4 its relay, another socket, and none of
  its descriptors reaches the release's run directory or the service's
  keeper channel.
- `kill`: a runner killed from outside is gone with every process of its
  uid, its home scrubbed and its group removed, and the pool refills.
- `reuse`: runners are killed until a uid is lent again; the runner that
  gets it has a fresh home and a fresh namespace, isolated as the first.
- `restart`: the service's VM is killed, the keeper retires every runner
  and exits, the container restarts in place in the same cgroup, and the
  new keeper serves with its memory bounds (its start-time drain moved
  every process of the reused cgroup root, or its refusal names each pid
  it could not move with the write's error); its runners are isolated.

The suite needs a host that allows unprivileged user namespaces. It fails
before its first step on the two refusals it reads: where
user.max_user_namespaces is 0, or where
kernel.apparmor_restrict_unprivileged_userns is 1 and Docker's default
AppArmor profile, which allows them then, is not in force (`docker info`
lists no `name=apparmor` security option). The service steps sign their
requests with the scripted control plane's keys (control_plane.py); none
of them needs the service to reach it. `measure`'s work is that plane's
too, reached by this machine alone, as the runner's relay reaches it
through its service. The keeper steps' clients speak the keeper's
protocol (`V`), each placing the place its spawn names first, naming no
bound on a spawn, and reading the place's `placed` answer with the bound
the keeper sets on a runner: half of the pool's work, the machine's whole
memory here, never under a runner's least.

Usage: tests/locus-runtime-image/namespace.py IMAGE [STEP]...
"""

import base64
import json
import os
import re
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from control_plane import ControlPlane  # noqa: E402
from memory import CHILD_BYTES as HOG_BYTES, HOG, HOG_REF, wasm  # noqa: E402
from stack import (HOME_ROOT, POOL_FIRST, POOL_LAST, PROFILE, RELEASE, ROLE, RUN_DIR, SERVICE, SERVICE_UID,  # noqa: E402
                   SERVICE_USER, Stack, expect, run, wait_until)
import imagesuite  # noqa: E402
from imagesuite import APPARMOR, PROJECT_PREFIX, read_output, read_word, run_name  # noqa: E402
from worker_auth import ATTEMPT_FIELDS  # noqa: E402

IMAGE_PROFILE = "/etc/cyfr/keeper.json"
KEEPER_STEPS = ("refusals", "connect", "names", "relay", "nested", "measure")
STEPS = KEEPER_STEPS + ("spawn", "cgroup", "network", "descriptors", "kill", "reuse", "restart")
POOL = f"{ROLE['pool']}:{POOL_FIRST}-{POOL_LAST}:{ROLE['reach']}"
TOKEN = "0123456789abcdef" * 4
# The place every spawn of the keeper steps but `measure` names.
PLACE = "p1"
# The keeper's protocol: every line carries its version.
V = 9
BOOT_S = 90
NO_CAPS = "0000000000000000"


def prerequisites(image):
    if shutil.which("docker") is None:
        sys.exit("FAIL: prerequisite missing: docker is not on PATH")
    if run("docker", "compose", "version", check=False).returncode != 0:
        sys.exit("FAIL: prerequisite missing: docker compose does not answer")
    if run("docker", "image", "inspect", image, check=False).returncode != 0:
        sys.exit(f"FAIL: prerequisite missing: the image {image} is not built")
    if not os.path.isfile(PROFILE):
        sys.exit(f"FAIL: prerequisite missing: {PROFILE}")
    shipped = run("docker", "run", "--rm", *run_name(f"{PROJECT_PREFIX}locus-keeper-profile-{os.getpid()}"),
                  "--entrypoint", "cat", image, IMAGE_PROFILE, check=False).stdout
    with open(PROFILE) as f:
        expect(json.loads(shipped or "null") == json.load(f), f"the image carries {PROFILE} as {IMAGE_PROFILE}")
    limit, restrict = read_sysctl("user.max_user_namespaces"), read_sysctl("kernel.apparmor_restrict_unprivileged_userns")
    options = docker_security_options()
    print(f"host: user.max_user_namespaces = {limit}", flush=True)
    print(f"host: kernel.apparmor_restrict_unprivileged_userns = {restrict}", flush=True)
    print(f"host: docker security options {options}", flush=True)
    refusal = userns_refusal(limit, restrict, options)
    if refusal:
        sys.exit(f"FAIL: prerequisite missing: {refusal}")


def read_sysctl(name):
    """A sysctl's value as /proc/sys holds it, or `absent` where this kernel has none."""
    path = os.path.join("/proc/sys", *name.split("."))
    return open(path).read().strip() if os.path.exists(path) else "absent"


def docker_security_options():
    """The daemon's security options as `docker info` lists them, `name=apparmor` among them where its profile is in force."""
    return json.loads(run("docker", "info", "--format", "{{json .SecurityOptions}}").stdout or "null") or []


def userns_refusal(limit, restrict, options):
    """Why a host with these values refuses the runners their user namespaces, or None where it allows them.

    `limit` and `restrict` are user.max_user_namespaces and
    kernel.apparmor_restrict_unprivileged_userns as `read_sysctl` reads
    them, `options` the daemon's security options."""
    if limit == "0":
        return ("user.max_user_namespaces is 0: the kernel creates no user namespace, "
                "and every runner is cloned into one")
    apparmor = any(option == "name=apparmor" or option.startswith("name=apparmor,") for option in options)
    if restrict == "1" and not apparmor:
        return ("kernel.apparmor_restrict_unprivileged_userns is 1 and docker info lists no name=apparmor security option: "
                "without Docker's default AppArmor profile the kernel refuses the runners' user namespaces")
    return None


class IsolatedStack(Stack):
    """The shipped locus-runtime service, under the keeper's seccomp profile compose names."""

    def as_uid(self, uid, script):
        """`script` run in the container as `uid`, which may read that uid's /proc entries in the container's own user namespace."""
        return self.exec(f"setpriv --reuid={uid} --regid={uid} --clear-groups sh -c '{script}'")


# ---------------------------------------------------------------------------
# A keeper started from the image with a shell for its client
# ---------------------------------------------------------------------------


# What the client's shell prints once its script is done, with the script's status: a role's process that ends is
# started again by its keeper, so the client stays until the run stops it.
CLIENT_DONE = "<<<client done "


def keeper_run(image, client_script, seccomp=True, timeout=120, mounts=(), guard=None, pool_args=None,
               apparmor=APPARMOR, guarded=True, on_start=None):
    """cyfr-locus from the image under the shipped service's options, serving the runtime's role, whose process is
    a shell running `client_script`, and the relay pool, in the network namespace of `guard` (an
    `imagesuite.Guard`), or of a guard of its own made for the run. `guarded=False` names a guard's control no
    guard serves. Without `seccomp` it runs under Docker's default seccomp profile, and with `apparmor` None under
    Docker's default AppArmor profile. `on_start` is told the container's id once it runs. Answers the run as a
    finished process: the keeper's status where it ended, else the client script's once it is done, and what the
    container printed."""
    own = None
    if guard is None and guarded:
        own = guard = imagesuite.Guard(image, f"locus-keeper-run-{os.getpid()}-{secrets.token_hex(4)}", runner=run)
    name = None
    client = f"{client_script}\necho \"{CLIENT_DONE}$?>>>\"; exec sleep 1000000"
    try:
        args = ["docker", "run", "--detach",
                *run_name(f"{PROJECT_PREFIX}locus-keeper-run-{os.getpid()}-{secrets.token_hex(4)}"),
                *(guard.keeper_args() if guard else []),
                *[arg for mount in mounts for arg in ("-v", mount)], "--cap-drop", "ALL", "--cap-add", "SETUID",
                "--cap-add", "SETGID", "--cap-add", "KILL", "--security-opt", "no-new-privileges:true",
                "--security-opt", "writable-cgroups=true", "--read-only", "--ipc", "none", "--init",
                *imagesuite.role_mounts(RELEASE, ROLE, home_size="64m"),
                "-e", f"{ROLE['key']}={secrets.token_hex(32)}"]
        if seccomp:
            args += ["--security-opt", f"seccomp={PROFILE}"]
        if apparmor:
            args += ["--security-opt", f"apparmor={apparmor}"]
        args += ["--security-opt", "systempaths=unconfined"]
        args += ["--entrypoint", "cyfr-locus", image, "serve", "--role", imagesuite.role_spec(ROLE),
                 *(pool_args or ["--pool", POOL]), "--home-root", RELEASE["home_root"],
                 "--guard", imagesuite.Guard.CONTROL, "--", "/bin/sh", "-c", client]
        name = run(*args).stdout.strip()
        if on_start:
            on_start(name)
        deadline = time.monotonic() + timeout
        while True:
            logs = run("docker", "logs", name, check=False)
            if CLIENT_DONE in logs.stdout:
                head, tail = logs.stdout.split(CLIENT_DONE, 1)
                return subprocess.CompletedProcess(args, int(tail.split(">>>", 1)[0]), head, logs.stderr)
            state = json.loads(run("docker", "inspect", name).stdout)[0]["State"]
            if not state["Running"]:
                logs = run("docker", "logs", name, check=False)
                return subprocess.CompletedProcess(args, state["ExitCode"], logs.stdout, logs.stderr)
            if time.monotonic() > deadline:
                sys.exit(f"FAIL: the keeper's client was not done within {timeout} s\n{logs.stdout[-3000:]}\n"
                         f"{logs.stderr[-3000:]}")
            time.sleep(0.2)  # sleep-ok: polling the client's log for its end
    finally:
        if name:
            run("docker", "rm", "--force", name, check=False)
        if own:
            own.down()


def place_line(place, kind="warm", athanor=None):
    request = {"v": V, "type": "place", "id": place, "kind": kind}
    if athanor:
        request["athanor"] = athanor
    return json.dumps(request)


def spawn_line(spawn_id, argv, env=None, control=False, attach=f"{RUN_DIR}/attach.sock", place=PLACE, **extra):
    """A spawn naming its place and no bound: the keeper sets a spawn's bound by its place's kind."""
    request = {"v": V, "type": "spawn", "id": spawn_id, "place": place, "pool": ROLE["pool"], "argv": argv, "env": env or {},
               "attach": {"path": attach, "token": TOKEN}, **extra}
    if control:
        request["control"] = True
    return json.dumps(request)


# What the client prints of the machine's memory, MemTotal in kB, which the keeper sizes its pool's work from.
MEMTOTAL = "printf 'memtotal:%s\\n' \"$(awk '$1 == \"MemTotal:\" {print $2}' /proc/meminfo)\"; "
# The client's first request: the place its spawn names, whose answer it prints before it sends the spawn.
PLACE_FIRST = MEMTOTAL + f"printf '%s\\n' '{place_line(PLACE)}' >&3; read -r line <&3; echo \"reply:$line\"; "


def replies(stdout):
    return [json.loads(line[len("reply:"):]) for line in stdout.splitlines() if line.startswith("reply:")]


def runner_bound(stdout):
    """The bound the keeper sets on a runner of the keeper steps: half of the pool's work, which with no reserve, no
    share and no limit of its container is the machine's whole memory, as the client printed it; None where it did
    not."""
    found = re.findall(r"^memtotal:(\d+)$", stdout, re.M)
    return imagesuite.cap_bytes("warm", int(found[0]) * 1024) if len(found) == 1 else None


def placed(place, bound):
    """The keeper's `placed` answer to the place `place`, with the bound its spawn will have."""
    return {"v": V, "type": "placed", "id": place, "memory_bytes": bound}


def after_placed(ran, step):
    """The replies the client read after its first, which must be the keeper's `placed` for the place its spawn names,
    with a runner's bound."""
    got = replies(ran.stdout)
    bound = runner_bound(ran.stdout)
    expect(bound is not None and got[:1] == [placed(PLACE, bound)],
           f"{step}: the keeper placed {PLACE} with a runner's bound, {bound} bytes, before the client sent the spawn naming it",
           {"replies": got, "stderr": ran.stderr[-2000:]})
    return got[1:]


def test_refusals(image):
    # Under Docker's default AppArmor profile, on a host that enforces
    # AppArmor, the keeper refuses before anything else of a space is tried,
    # naming this release's profile.
    with open("/sys/module/apparmor/parameters/enabled") as enabled:
        apparmor_on = enabled.read().strip() == "Y"
    if apparmor_on:
        defaulted = keeper_run(image, "exec sleep 5", apparmor=None, timeout=60)
        expect(defaulted.returncode == 78 and "docker-default (enforce)" in defaulted.stderr
               and f"not this release's profile {APPARMOR} (enforce)" in defaulted.stderr,
               f"under Docker's default AppArmor profile cyfr-locus refuses to start, naming {APPARMOR} "
               f"(exit {defaulted.returncode})", defaulted.stderr[-2000:])
    refused = keeper_run(image, "exec sleep 5", seccomp=False, timeout=60)
    expect(refused.returncode == 78 and "user.max_user_namespaces" in refused.stderr
           and "kernel.apparmor_restrict_unprivileged_userns" in refused.stderr,
           f"under Docker's default seccomp profile cyfr-locus refuses to serve the relay pool, naming both settings (exit {refused.returncode})",
           refused.stderr)
    # The keeper's own entry point: a guard that is not there refuses the
    # boot, naming the guard's socket.
    guard = imagesuite.Guard.CONTROL
    unguarded = keeper_run(image, "exec sleep 5", timeout=60, guarded=False)
    expect(unguarded.returncode != 0 and "its route was not made" in unguarded.stderr and guard in unguarded.stderr,
           f"a keeper whose guard is not there refuses to start the role, naming {guard} (exit {unguarded.returncode})",
           unguarded.stderr[-2000:])
    for name, extra in [("naming hosts", {"hosts": ["api.example.com"]}), ("carrying isolation", {"isolation": "netns"})]:
        client = PLACE_FIRST + (f"printf '%s\\n' '{spawn_line('1', ['/bin/true'], **extra)}' >&3; "
                                "read -r line <&3; echo \"reply:$line\"")
        answered = keeper_run(image, client)
        got = after_placed(answered, "refusals")
        expect(len(got) == 1 and got[0]["type"] == "error" and got[0]["code"] == "bad_request",
               f"under the profile, a spawn of the relay pool {name} is refused as bad_request",
               answered.stdout + answered.stderr)


def test_connect(image):
    # The command dials the container's loopback and the container's own
    # address and exits 42 when both are unreachable. Its output has no
    # reader, since no client listens on the attach socket, so its exit
    # status is the answer. The client's shell, the role's process in its
    # own space, dials its own loopback and address first.
    # Then it asks for a name, which no resolver of its own answers (the
    # loopback is down), within a second, and it reads its IPC namespace,
    # which is not the container's: exit 42 for all of it.
    command = ('n=0; for t in 127.0.0.1:9 "$TARGET:9"; do '
               'curl -sv --max-time 3 "http://$t/" 2>&1 | grep -q "Network is unreachable" && n=$((n+1)); done; '
               'start=$(date +%s%N); getent hosts cyfr >/dev/null 2>&1 && exit 3; '
               '[ $(( ($(date +%s%N) - start) / 1000000 )) -lt 1000 ] || exit 4; '
               '[ "$(readlink /proc/self/ns/ipc)" != "$IPC" ] || exit 5; '
               '[ $n -eq 2 ] && exit 42; exit $n')
    request = spawn_line("1", ["/bin/sh", "-c", command], env={"TARGET": "@ADDR@", "IPC": "@IPC@"})
    assert "'" not in request
    client = ('addr=$(awk \'/\\|-- / {a = $2} /\\/32 host LOCAL/ && a !~ /^127\\./ {print a; exit}\' /proc/net/fib_trie); '
              'for t in 127.0.0.1:9 "$addr:9"; do '
              'echo "own $t:$(curl -sv --max-time 3 "http://$t/" 2>&1 | grep -o "Connection refused\\|Network is unreachable" | head -n1)"; done; '
              'ipc=$(readlink /proc/self/ns/ipc); '
              + PLACE_FIRST + f"printf '%s\\n' \"$(printf '%s' '{request}' | sed \"s/@ADDR@/$addr/; s/@IPC@/$ipc/\")\" >&3; "
              'read -r line <&3; echo "reply:$line"; read -r line <&3; echo "reply:$line"')
    ran = keeper_run(image, client)
    got = after_placed(ran, "connect")
    expect(len(got) == 2 and got[0]["type"] == "spawned" and POOL_FIRST <= got[0]["uid"] <= POOL_LAST,
           "connect: under the profile the keeper serves and spawns a command of the relay pool", ran.stdout + ran.stderr)
    own = re.findall(r"^own (\S+):(.*)$", ran.stdout, re.M)
    expect(len(own) == 2 and all(answer == "Connection refused" for _, answer in own),
           "connect: from the role's own space its loopback and its address answer (the dial is refused, not unreachable)", own)
    expect(got[1]["type"] == "exited" and got[1]["code"] == 42,
           "connect: from the command's namespace neither the loopback nor the role's address is reachable (no route "
           "exists), no name resolves at once, and its IPC namespace is its own",
           {"replies": got, "stdout": ran.stdout, "stderr": ran.stderr[-2000:]})


# The suites' name listener (tests/locus-backends-image/name-listener.mjs):
# an upstream resolver the suite runs, which the code under test did not
# write, that prints `heard <name>` for each query.
LISTENER_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "locus-backends-image")


def test_names(image):
    """The container's own resolver asks the suites' name listener; a runner's same kind of query reaches nothing."""
    tag = secrets.token_hex(4)
    listener = f"{PROJECT_PREFIX}locus-names-{os.getpid()}-{tag}"
    run("docker", "rm", "--force", listener, check=False)
    # The guard's resolver asks the listener, which shares its namespace on
    # 127.0.0.53 (compose.names.yml's shape).
    guard = imagesuite.Guard(image, f"locus-names-guard-{os.getpid()}-{tag}", extra=["--dns", "127.0.0.53"])
    run("docker", "run", "--detach", "--name", listener, "--network", f"container:{guard.id}",
        "-v", f"{LISTENER_DIR}:/listener:ro", "--cap-drop", "ALL", "--cap-add", "NET_BIND_SERVICE",
        "--entrypoint", "node", image, "/listener/name-listener.mjs")
    try:
        control, runner = f"keeper-{tag}.l5.test", f"runner-{tag}.l5.test"
        command = f'getent hosts {runner} >/dev/null 2>&1 && exit 3; exit 42'
        request = spawn_line("1", ["/bin/sh", "-c", command])
        client = (f'echo "own:$(getent hosts {control} | cut -d" " -f1)"; '
                  + PLACE_FIRST + f"printf '%s\\n' '{request}' >&3; "
                  'read -r line <&3; echo "reply:$line"; read -r line <&3; echo "reply:$line"')
        ran = keeper_run(image, client, guard=guard)
        got = after_placed(ran, "names")
        heard = [line.split(" ", 1)[1] for line in run("docker", "logs", listener, check=False).stdout.splitlines()
                 if line.startswith("heard ")]
        expect("own:192.0.2.7" in ran.stdout and control in heard,
               "names: the container's own resolver asks the suites' name listener, which answers", {"stdout": ran.stdout, "heard": heard})
        expect(len(got) == 2 and got[1]["type"] == "exited" and got[1]["code"] == 42 and runner not in heard,
               "names: a runner's lookup of the same kind finds no resolver, and the listener never hears it",
               {"replies": got, "heard": heard, "stderr": ran.stderr[-2000:]})
    finally:
        run("docker", "rm", "--force", listener, check=False)
        guard.down()


class Attach:
    """The client's attach socket, on this machine in a directory mounted into the container, speaking the keeper's frames.

    The mount is outside /run, whose run folder alone a role's space holds, so the client, in its space, reads this
    machine's marks there; it leaves its own in its run folder (`ClientMarks`), the one place its space writes."""

    MOUNT = "/cyfr-attach"

    def __init__(self, client_marks=None):
        self.dir = tempfile.mkdtemp(prefix=os.environ.get("PROOF_RUN_PREFIX", "") + "cyfr-attach-")
        # This machine leaves its marks for the client here (`mark`): cyfr-locus refuses to start with a mount a
        # pooled uid could write.
        os.chmod(self.dir, 0o755)
        self.client_marks = client_marks
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(os.path.join(self.dir, "a.sock"))
        os.chmod(os.path.join(self.dir, "a.sock"), 0o777)
        self.server.listen(1)
        self.server.settimeout(60)
        self.result = None

    @property
    def mount(self):
        return f"{self.dir}:{self.MOUNT}"

    @staticmethod
    def send(conn, stream, payload=b""):
        conn.sendall(bytes([stream]) + struct.pack(">I", len(payload)) + payload)

    @staticmethod
    def read(conn):
        header = b""
        while len(header) < 5:
            chunk = conn.recv(5 - len(header))
            if not chunk:
                return None
            header += chunk
        stream, length = header[0], struct.unpack(">I", header[1:])[0]
        payload = b""
        while len(payload) < length:
            chunk = conn.recv(length - len(payload))
            if not chunk:
                return None
            payload += chunk
        return stream, payload

    def serve(self, opens):
        """One relay's session: with `opens`, open stream 5, wait for the runner's call on it and answer it; then read to the end."""
        got, ended, order = {}, [], []
        try:
            conn, _ = self.server.accept()
            conn.settimeout(60)
            attach = self.read(conn)
            if attach != (3, TOKEN.encode()):
                self.result = {"error": f"attach frame {attach}"}
                return
            if opens:
                self.send(conn, 5)
            answered = False
            while True:
                frame = self.read(conn)
                if frame is None:
                    break
                stream, payload = frame
                order.append(stream)
                if payload:
                    got[stream] = got.get(stream, b"") + payload
                else:
                    ended.append(stream)
                if opens and not answered and got.get(5) == b"call\n":
                    self.send(conn, 5, b"answer\n")
                    answered = True
            conn.close()
            self.result = {"got": got, "ended": sorted(ended), "streams": order}
        except OSError as error:
            self.result = {"error": repr(error)}

    def mark(self, name):
        """Leave the mark `name` for the client, which reads it in the directory mounted at MOUNT."""
        open(os.path.join(self.dir, name), "w").close()

    def marked(self, name):
        if self.client_marks is None:
            return False
        return self.client_marks.marked(name)

    def close(self):
        self.server.close()
        shutil.rmtree(self.dir, ignore_errors=True)


def relay_session(image, command, opens, env=None):
    """A spawn of the relay pool running `command`, its relay served by this machine: the replies and what the relay carried."""
    attach = Attach()
    serving = threading.Thread(target=attach.serve, args=(opens,), daemon=True)
    serving.start()
    try:
        request = spawn_line("1", ["/bin/sh", "-c", command], env=env, control=True, attach=f"{Attach.MOUNT}/a.sock")
        assert "'" not in request
        client = PLACE_FIRST + (f"printf '%s\\n' '{request}' >&3; "
                                'for n in 1 2 3; do read -r line <&3; echo "reply:$line"; done')
        ran = keeper_run(image, client, mounts=[attach.mount])
        serving.join(60)
        return after_placed(ran, "a spawn of the relay pool with its relay"), attach.result, ran
    finally:
        attach.close()


def test_relay(image):
    # A runner that calls on its relay (fd 4) and waits for the answer, the
    # client opening stream 5 first, as the worker service does.
    got, carried, ran = relay_session(image, 'printf "call\\n" >&4; IFS= read -r a <&4; echo "got:$a"', opens=True)
    expect([r["type"] for r in got] == ["spawned", "exited", "released"] and got[1].get("code") == 0,
           "relay: a spawn of the relay pool whose client opens stream 5 runs to its exit", {"replies": got, "stderr": ran.stderr[-2000:]})
    expect(carried and carried.get("got", {}).get(5) == b"call\n" and carried["got"].get(1) == b"got:answer\n" and 5 in carried["ended"],
           "relay: once the client opened stream 5, the runner's call on fd 4 arrives there, the client's answer reaches fd 4, and the stream ends",
           carried)
    # A client that never opens stream 5 receives nothing on it from a
    # runner that writes to its relay and exits, its end frame included.
    got, carried, ran = relay_session(image, 'printf "call\\n" >&4; echo done', opens=False)
    expect([r["type"] for r in got] == ["spawned", "exited", "released"] and got[1].get("code") == 0,
           "relay: a spawn of the relay pool whose client never opens stream 5 runs to its exit", {"replies": got, "stderr": ran.stderr[-2000:]})
    expect(carried and 5 not in carried.get("streams", [5]) and carried["got"].get(1) == b"done\n" and {1, 2, 4} <= set(carried["ended"]),
           "relay: a client that never opened stream 5 receives no frame on it, its end included, though the runner wrote to fd 4",
           carried)


# The runner's calls, made with perl's syscall(): clone's number on this
# machine, then each clone's flags with SIGCHLD as its exit signal and no
# stack, so its child is a copy that exits at once. A clone answers `ok`
# when it made a child, else its errno's name.
NESTED_CLONES = (
    "use POSIX (); $| = 1; my $nr = shift; "
    "sub attempt { my $flags = shift; my $pid = syscall($nr, $flags | 17, 0, 0, 0, 0); "
    "if ($pid == 0) { POSIX::_exit(0); } if ($pid > 0) { waitpid($pid, 0); return q{ok}; } "
    "return $!{EPERM} ? q{EPERM} : q{errno} . ($! + 0); } "
    "print qq{process=}, attempt(0), qq{\n}; "
    "print qq{newuser=}, attempt(0x10000000), qq{\n}; "
    "print qq{newuser_newnet=}, attempt(0x50000000), qq{\n};"
)
NESTED_THREAD = "$| = 1; print qq{thread=}, threads->create(sub { 7 })->join, qq{\n};"
CLONE_NR = {"x86_64": 56, "aarch64": 220}
# The runner's sockets, made with syscall() by socket's and socketpair's
# numbers on this machine: AF_UNIX, the probe's control; AF_VSOCK (40),
# which the keeper's profile refuses; and 40 with a high bit set, which the
# kernel reads as AF_VSOCK too, since it reads a domain's low 32 bits. Each
# answers `ok` or its errno's name.
VSOCK_SOCKETS = (
    "$| = 1; my ($nr, $pnr) = @ARGV; "
    "sub answer { my $r = shift; return $r >= 0 ? q{ok} : $!{EPERM} ? q{EPERM} : q{errno} . ($! + 0); } "
    "sub one { answer(syscall($nr, shift, 1, 0)) } "
    "sub pair { my $sv = qq{\\0} x 8; answer(syscall($pnr, shift, 1, 0, $sv)) } "
    "print qq{socket_unix=}, one(1), qq{\n}; "
    "print qq{socket_vsock=}, one(40), qq{\n}; "
    "print qq{socket_vsock_widened=}, one(0x100000028), qq{\n}; "
    "print qq{socketpair_unix=}, pair(1), qq{\n}; "
    "print qq{socketpair_vsock=}, pair(40), qq{\n}; "
    "print qq{socketpair_vsock_widened=}, pair(0x100000028), qq{\n};"
)
SOCKET_NR = {"x86_64": (41, 53), "aarch64": (198, 199)}


def socketcall_program(domain):
    """A 32-bit x86 program that calls socketcall(SYS_SOCKET, {domain, SOCK_STREAM, 0}), the other way into the
    kernel's socket code, which no 64-bit call names, and exits with the call's negated return: 1 for EPERM, 253
    for the descriptor 3, which it made. A 32-bit program is the only kind that can make the call."""
    base = 0x08048000
    code = (b"\x6a\x00" b"\x6a\x01" b"\x68" + struct.pack("<I", domain) +  # push 0, push 1, push domain
            b"\x89\xe1" b"\xbb\x01\x00\x00\x00" b"\xb8\x66\x00\x00\x00" b"\xcd\x80" +  # ecx=args, ebx=1, eax=102, int 0x80
            b"\x89\xc3" b"\xf7\xdb" b"\xb8\x01\x00\x00\x00" b"\xcd\x80")  # exit(-eax)
    size = 52 + 32 + len(code)
    header = b"\x7fELF\x01\x01\x01\x00" + b"\x00" * 8 + struct.pack("<HHIIIIIHHHHHH", 2, 3, 1, base + 84, 52, 0, 0, 52, 32, 1, 40, 0, 0)
    program = struct.pack("<IIIIIIII", 1, 0, base, base, size, size, 5, 0x1000)
    return base64.b64encode(header + program + code).decode()


SOCKETCALL_MADE = 253


def test_nested(image):
    command = ('arch=$(uname -m); echo "arch=$arch"; '
               'case "$arch" in ' + " ".join(f"{arch}) nr={nr} snr={SOCKET_NR[arch][0]} pnr={SOCKET_NR[arch][1]};;"
                                             for arch, nr in CLONE_NR.items()) +
               ' *) nr= snr= pnr=;; esac; '
               'u=$(unshare -U true 2>&1); echo "unshare=$u status $?"; '
               '[ -n "$nr" ] && perl -e "$CLONES" "$nr"; [ -n "$snr" ] && perl -e "$SOCKETS" "$snr" "$pnr"; '
               'if [ "$arch" = x86_64 ]; then echo "$SOCKETCALL" | base64 -d > "$HOME/socketcall" && chmod 0700 "$HOME/socketcall"; '
               '"$HOME/socketcall"; echo "socketcall_vsock=$?"; fi; '
               'perl -Mthreads -e "$THREAD"')
    got, carried, ran = relay_session(image, command, opens=False,
                                      env={"CLONES": NESTED_CLONES, "THREAD": NESTED_THREAD, "SOCKETS": VSOCK_SOCKETS,
                                           "SOCKETCALL": socketcall_program(40)})
    out = (carried or {}).get("got", {}).get(1, b"").decode(errors="replace")
    facts = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    detail = {"stdout": out, "stderr": (carried or {}).get("got", {}).get(2, b"").decode(errors="replace"), "replies": got,
              "keeper": ran.stderr[-2000:]}
    expect([r["type"] for r in got] == ["spawned", "exited", "released"] and got[1].get("code") == 0,
           "nested: a spawn of the relay pool runs the probe to its exit", detail)
    expect(facts.get("arch") in CLONE_NR, f"nested: the runner knows clone's number on {facts.get('arch')}", detail)
    expect(facts.get("process") == "ok", "nested: a runner's clone without a namespace flag makes a child (the probe's control)", detail)
    expect(facts.get("newuser") == "EPERM" and facts.get("newuser_newnet") == "EPERM",
           "nested: a runner's clone with CLONE_NEWUSER, alone or with CLONE_NEWNET, is refused EPERM, "
           "though the profile lets the keeper make that clone", detail)
    expect("Operation not permitted" in facts.get("unshare", "") and not facts.get("unshare", "").endswith(" status 0"),
           "nested: a runner's `unshare -U` is refused", detail)
    expect(facts.get("thread") == "7", "nested: a runner still starts a thread and joins it", detail)
    expect(facts.get("socket_unix") == "ok", "nested: a runner makes an AF_UNIX socket (the vsock probe's control)", detail)
    expect(facts.get("socket_vsock") == "EPERM" and facts.get("socket_vsock_widened") == "EPERM",
           "nested: a runner is refused socket(AF_VSOCK) EPERM, and so with the domain's high bits set, "
           "which the kernel reads as AF_VSOCK too", detail)
    expect(facts.get("socketpair_unix") == "ok", "nested: a runner makes an AF_UNIX socket pair (the pair probe's control)", detail)
    expect(facts.get("socketpair_vsock") == "EPERM" and facts.get("socketpair_vsock_widened") == "EPERM",
           "nested: a runner is refused socketpair(AF_VSOCK) EPERM by the profile, and so with the domain's high bits set", detail)
    if facts.get("arch") == "x86_64":
        expect(facts.get("socketcall_vsock") not in (None, str(SOCKETCALL_MADE)),
               "nested: a runner's 32-bit socketcall(SYS_SOCKET, AF_VSOCK) makes no socket", detail)
        test_compat_killed(image)
    else:
        print(f"nested: no 32-bit program of {facts.get('arch')} is probed: the 32-bit socketcall is x86's", flush=True)


# A 32-bit call is the profile's own to refuse outside a space, where no
# space's filter stands before it: the keeper's profile names no 32-bit
# architecture, so every 32-bit and x32 call in the Locus container is
# killed (SIGSYS, exit 159), and the socketcall whose domain no filter can
# read, behind its pointer, never reaches the kernel's socket code.
SIGSYS_EXIT = 128 + 31


def test_compat_killed(image):
    for domain, name in ((2, "AF_INET"), (40, "AF_VSOCK")):
        ran = run("docker", "run", "--rm", "--network", "none", "--security-opt", f"seccomp={PROFILE}",
                  *run_name(f"{PROJECT_PREFIX}compat-{domain}"), "--entrypoint", "sh", image, "-c",
                  f'echo {socketcall_program(domain)} | base64 -d > /tmp/socketcall && chmod 0700 /tmp/socketcall; '
                  '/tmp/socketcall; echo "exit=$?"', check=False)
        got = dict(line.split("=", 1) for line in ran.stdout.splitlines() if "=" in line)
        expect(got.get("exit") == str(SIGSYS_EXIT),
               f"compat: under the keeper's profile alone, a 32-bit socketcall(SYS_SOCKET, {name}) is killed, "
               "as every 32-bit call is", {"stdout": ran.stdout, "stderr": ran.stderr[-1000:]})


# The runner as the shipped service spawns it (Locus.Runtime.Settings.runner_command/0): the runner program, with no
# argument and none of the service's environment, and the runner's own (Locus.Runtime.Settings.runner_environment/1),
# under the bound the keeper sets on a runner. Its id names its place, as the runner pool's does.
RUNNER_ARGV = ["/usr/local/bin/cyfr-runner"]
RUNNER = "runner_measured"
RUNNER_ENV = {"RUNTIME_RUNNER_ID": RUNNER, "RUNTIME_SERVICE_ID": SERVICE, "RUNTIME_BOOT_ID": "boot_measured"}
RELEASE_GRACE_MS = 2_000
ATHANOR = "ath_measured"
# The runner's owners, one step each, read once the keeper has read its group: the place's own, then the owner an
# `assign` sent before the step gives it where the step before's was another (`assigns`). `working` is read while the
# runner does the work of the athanor its place was assigned to.
WORKING = "working"
OWNERS = (
    ("fresh", "warm", None, "fresh"),
    ("assigned", "run", ATHANOR, f"assigned a run of {ATHANOR}, before its work is sent"),
    (WORKING, "run", ATHANOR, f"at the work of {ATHANOR}, holding its memory"),
    ("warm", "warm", ATHANOR, f"back at rest, still {ATHANOR}'s"),
    ("reused", "run", ATHANOR, f"reused for another run of {ATHANOR}"),
)
# How long the client waits, once the work says it holds its memory, before it reads the runner: more than the second
# between the keeper's readings, so an answer whose reading is younger than this was taken while the work held it.
SETTLE_MS = 2_000
# The work's bound, as the plane mints its attempt: its deadline counts from the mint, before the runner boots.
WORK_TIMEOUT_MS = 120_000

# The measure step's client, after the variables places_client sets. `ask` sends one measure of the place and
# reads up to its answer; `poll` asks until a reading answers it, the keeper reading each group once a second;
# `assign` sends an assign and reads up to its answer. Every reply read is printed as `read:<step>:<reply>`, an
# assign's as `read:<step>.assign:<reply>`. `mark` leaves a mark for this machine in the attach directory and
# `marked` waits for one of its. It prints the machine's memory first, as `read:memtotal:<kB>`. The release and a
# measure go in one write, and the replies are read up to `released`; then one more measure.
PLACES_CLIENT = r"""
ask() {
  n=$((n + 1))
  printf '{"v":@V@,"type":"measure","id":"m%s","place":"%s"}\n' "$n" "$place" >&3
  while read -r line <&3; do
    echo "read:$1:$line"
    case "$line" in *"\"id\":\"m$n\","*) return 0 ;; esac
  done
  return 1
}
poll() {
  tries=0
  while [ "$tries" -lt 50 ]; do
    ask "$1" || return 1
    case "$line" in *'"type":"measured"'*) return 0 ;; esac
    tries=$((tries + 1))
    sleep 0.2
  done
  return 1
}
assign() {
  printf '%s\n' "$3" >&3
  while read -r line <&3; do
    echo "read:$1.assign:$line"
    case "$line" in *"\"id\":\"$2\""[,}]*) return 0 ;; esac
  done
  return 1
}
mark() { mkdir -p "$own_marks" && : > "$own_marks/$1"; }
marked() {
  tries=0
  until [ -e "$marks/$1" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 600 ] || return 1
    sleep 0.1
  done
}
n=0
echo "read:memtotal:$(awk '$1 == "MemTotal:" {print $2}' /proc/meminfo)"
printf '%s\n' "$placing" >&3; read -r line <&3; echo "read:placed:$line"
printf '%s\n' "$spawning" >&3; read -r line <&3; echo "read:spawned:$line"
sid=$(printf '%s' "$line" | sed -n 's/.*"spawn_id":"\([0-9a-f]*\)".*/\1/p')
[ -n "$sid" ] || exit 1
@OWNERS@
n=$((n + 1))
printf '{"v":@V@,"type":"release","spawn_id":"%s","grace_ms":%s}\n{"v":@V@,"type":"measure","id":"m%s","place":"%s"}\n' \
  "$sid" "$grace" "$n" "$place" >&3
while read -r line <&3; do
  echo "read:release:$line"
  case "$line" in *'"type":"released"'*) break ;; esac
done
ask after
"""


def assigns():
    """The assign sent before each step whose owner is not the step before's, by step, with ids `as1`, `as2` and on:
    none is a measure's (`m<n>`), the spawn's (`1`) or the place's."""
    sent, before = {}, OWNERS[0][1:3]
    for step, kind, athanor, _ in OWNERS[1:]:
        if (kind, athanor) != before:
            sent[step] = {"v": V, "type": "assign", "id": f"as{len(sent) + 1}", "place": RUNNER, "kind": kind, "athanor": athanor}
        before = (kind, athanor)
    return sent


class ClientMarks:
    """Where the client leaves its marks for this machine: a folder of the runtime role's run folder, the one place its
    space writes, which this machine reads in the keeper's container as the role's user (`name`, the container that
    `keeper_run` started, told as it starts)."""

    MOUNT = f"{RUN_DIR}/marks"

    def __init__(self):
        self.container = None

    def marked(self, mark):
        return self.container is not None and run(
            "docker", "exec", "-u", SERVICE_USER, self.container, "test", "-e", f"{self.MOUNT}/{mark}",
            check=False).returncode == 0


def places_client(env, marks=Attach.MOUNT, client_marks=ClientMarks.MOUNT):
    """The measure step's client: the runner placed warm, spawned with `env` in its place, read under each owner, released and read again.

    Before `working` it marks `assigned`, for this machine to send the runner its work, and waits for this machine's
    `holding`, the work holding its memory, and SETTLE_MS; after it, it marks `measured`, for the work to go on, and
    waits for `complete`, the runner's word that the work is done."""
    variables = {
        "place": RUNNER,
        "grace": str(RELEASE_GRACE_MS),
        "marks": marks,
        "own_marks": client_marks,
        "placing": place_line(RUNNER),
        "spawning": spawn_line("1", RUNNER_ARGV, env=env, control=True, attach=f"{Attach.MOUNT}/a.sock", place=RUNNER),
    }
    sent = {step: (request["id"], json.dumps(request)) for step, request in assigns().items()}
    assert "'" not in "".join(variables.values()) + "".join(line for _, line in sent.values())
    owners = ""
    for step, *_ in OWNERS:
        if step in sent:
            owners += f"assign {step} {sent[step][0]} '{sent[step][1]}' || exit 1\n"
        if step == WORKING:
            owners += f"mark assigned\nmarked holding || exit 1\nsleep {SETTLE_MS / 1000:g}\n"
        owners += f"poll {step} || exit 1\n"
        if step == WORKING:
            owners += "mark measured\nmarked complete || exit 1\n"
    return ("".join(f"{name}='{value}'\n" for name, value in variables.items())
            + PLACES_CLIENT.replace("@OWNERS@\n", owners).replace("@V@", str(V)))


def transcript(stdout):
    """What the measure step's client read, as (its step, the reply), in the order it arrived; a line that is no JSON stays text."""
    read = []
    for line in stdout.splitlines():
        if line.startswith("read:"):
            step, _, reply = line[len("read:"):].partition(":")
            try:
                read.append((step, json.loads(reply)))
            except ValueError:
                read.append((step, reply))
    return read


def reading(reply, kind, athanor=None):
    """Whether `reply` answers its measure with a reading above zero of a place whose owner is `kind` and `athanor`, and nothing else."""
    if not isinstance(reply, dict):
        return False
    owner = {"v": V, "type": "measured", "id": reply.get("id"), "kind": kind, **({"athanor": athanor} if athanor else {})}
    return ({key: value for key, value in reply.items() if key not in ("bytes", "lesser", "age_ms")} == owner
            and type(reply.get("bytes")) is int and reply["bytes"] > 0 and type(reply.get("lesser")) is bool
            and type(reply.get("age_ms")) is int and reply["age_ms"] >= 0)


def unmeasured(reply):
    return isinstance(reply, dict) and reply == {"v": V, "type": "error", "id": reply.get("id"), "code": "unmeasured"}


def judge_places(read, detail):
    """The measure step's verdict on what its client read (`transcript`)."""
    steps = {}
    for step, reply in read:
        steps.setdefault(step, []).append(reply)
    memtotal = steps.get("memtotal", [None])
    bound = imagesuite.cap_bytes("warm", memtotal[0] * 1024) if len(memtotal) == 1 and type(memtotal[0]) is int else None
    expect(bound is not None and steps.get("placed") == [placed(RUNNER, bound)],
           f"measure: the keeper placed the runner's place {RUNNER}, warm, with a runner's bound, {bound} bytes, half of the "
           "machine's memory, never under a runner's least", detail)
    spawned = (steps.get("spawned") or [None])[0]
    expect(isinstance(spawned, dict)
           and {key: value for key, value in spawned.items() if key not in ("spawn_id", "uid", "pid")} == {"v": V, "type": "spawned", "id": "1"}
           and re.fullmatch(r"[0-9a-f]{32}", str(spawned.get("spawn_id"))) is not None
           and type(spawned.get("uid")) is int and POOL_FIRST <= spawned["uid"] <= POOL_LAST
           and type(spawned.get("pid")) is int and spawned["pid"] > 0,
           "measure: the runner is spawned in its place, under a uid of the relay pool", detail)
    ids = [reply.get("id") for step, reply in read
           if not step.endswith(".assign") and isinstance(reply, dict) and reply.get("type") in ("measured", "error")]
    expect(ids == [f"m{n}" for n in range(1, len(ids) + 1)], "measure: every measure was answered once, under its own id, in the order sent",
           detail)
    sent = assigns()
    for step, kind, athanor, what in OWNERS:
        if step in sent:
            expect(steps.get(f"{step}.assign") == [{"v": V, "type": "assigned", "id": sent[step]["id"]}],
                   f"measure: before {step}, the keeper applied the assign of {kind} for {athanor} and answered it under its id, "
                   "and nothing else came before that answer", detail)
        got = steps.get(step, [])
        # Only the first reading is waited for: until the keeper has read the group, its place is unmeasured.
        expect(got and (step == OWNERS[0][0] or len(got) == 1) and all(unmeasured(reply) for reply in got[:-1])
               and reading(got[-1], kind, athanor),
               f"measure: {what}, the runner is read above zero under that owner ({kind}, {athanor or 'no athanor'})", detail)
    work, before = steps[WORKING][-1], steps["assigned"][-1]
    expect(work["age_ms"] < SETTLE_MS and work["bytes"] - before["bytes"] >= HOG_BYTES // 2,
           f"measure: the reading at the work was taken while the work held its {HOG_BYTES >> 20} MiB ({work['age_ms']} ms old, "
           f"read {SETTLE_MS} ms after it said so), and holds at least half of them more than the reading before the work was sent",
           detail)
    _, kind, athanor, _ = OWNERS[-1]
    released = steps.get("release", [])
    end = next((n for n, reply in enumerate(released) if isinstance(reply, dict) and reply.get("type") == "released"), None)
    measures = [n for n, reply in enumerate(released) if isinstance(reply, dict) and reply.get("type") in ("measured", "error")]
    expect(end is not None and released[end] == {"v": V, "type": "released", "spawn_id": spawned["spawn_id"]}
           and len(measures) == 1 and measures[0] < end and reading(released[measures[0]], kind, athanor),
           "measure: after its release, the runner's place is still read above zero, answered before its released", detail)
    after = steps.get("after", [])
    expect(len(after) == 1 and unmeasured(after[0]), "measure: after its released, the runner's place is free: its measure is unmeasured",
           detail)


# The work's host calls, in order, as the plane answers them, and the events its two emits carry.
WORK_CALLS = ("attach", "fetch_artifact", "push_deltas", "push_deltas", "complete")
WORK_EVENTS = [[{"type": "hog.ready"}], [{"type": "hog.holding", "bytes": HOG_BYTES}]]


def judge_work(served, calls, attempt):
    """The work's verdict: what this machine served the runner (`serve_work`) and the plane's calls of its attempt."""
    expect(served.get("error") is None and served.get("relay") == list(WORK_CALLS),
           "measure: every host call of the work came on the runner's relay, which this machine posted to the plane", served)
    expect([(call["op"], call.get("answered"), call.get("runner")) for call in calls] == [(op, "ok", RUNNER) for op in WORK_CALLS]
           and [call.get("events") for call in calls if call["op"] == "push_deltas"] == WORK_EVENTS and calls[3].get("let") is True
           and calls[4]["args"]["outcome"]["output"] == {"status": 200, "data": {"held": HOG_BYTES}},
           f"measure: the runner attached, fetched hog.wasm, ran it to its answer while its emit of holding {HOG_BYTES >> 20} MiB "
           "was held until the client had read it, and closed the attempt completed", calls)
    entered = {"v": 1, "type": "event", "name": "engine.authority_entered", "measurements": {},
               "metadata": {"execution_id": attempt["execution_id"], "reference": HOG_REF}}
    complete = {"v": 1, "type": "complete", "execution_id": attempt["execution_id"], "clean": True}
    expect(served.get("control") == [json.dumps(frame, separators=(",", ":")) for frame in (entered, complete)],
           "measure: the runner said on its control stream that it entered the work's authority and that the work's subtree "
           "is complete and clean, and nothing else", served)


def relay_frame(frame):
    """One relay frame (Prima.RunnerRelay): its length, then its JSON object, members in the order given."""
    body = json.dumps(frame, separators=(",", ":")).encode()
    return struct.pack(">I", len(body)) + body


def relay_frames(buffer):
    """The whole relay frames at the head of `buffer`, decoded, and the bytes after them."""
    frames = []
    while len(buffer) >= 4 and len(buffer) >= 4 + struct.unpack(">I", buffer[:4])[0]:
        end = 4 + struct.unpack(">I", buffer[:4])[0]
        frames.append(json.loads(buffer[4:end]))
        buffer = buffer[end:]
    return frames, buffer


def control_assign(assignment, input_, keys):
    """A control `assign` line (Prima.RunnerControl): the assignment token, the input text's bytes and the opened keys."""
    return (json.dumps({"v": 1, "type": "assign", "assignment": assignment, "input": base64.b64encode(input_.encode()).decode(),
                        "keys": keys}, separators=(",", ":")) + "\n").encode()


def opened_keys(attempt):
    """A minted attempt's keys as its worker service opens them for the runner: the attempt they are bound to, each key in hex."""
    return {"attempt": {name: attempt[name] for name in ATTEMPT_FIELDS}, "call": attempt["call_key"].hex(), "seal": attempt["seal_key"].hex()}


def post_call(plane, call):
    """The plane's status and body for the runner's host call `call`, posted unchanged as its service posts it; no status
    where no answer came."""
    request = urllib.request.Request(f"http://{plane.host}:{plane.port}/host/v1/{call['op']}", data=base64.b64decode(call["body"]),
                                     headers={"x-cyfr-auth": call["header"], "content-type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except OSError:
        return None, b""


def serve_work(attach, plane, attempt):
    """The measured runner's worker service, on its attach connection: it opens the relay, posts each host call the
    runner makes on it to the plane and answers it with the plane's answer, sends the runner `attempt` on its control
    stream once the client marks `assigned`, and keeps every control line the runner sends, marking `complete` once one
    is. What it saw is `attach.result`: the host calls' ops (any other relay frame by its kind), the control lines and
    the runner's standard error."""
    served = attach.result = {"relay": [], "control": [], "stderr": b""}
    lock, seq, conn = threading.Lock(), [0], None

    def answer(call):
        status, body = post_call(plane, call)
        with lock:
            frame = {"v": 1, "attempt": call["attempt"], "seq": seq[0], "kind": "host_answer", "re": call["seq"], "status": status,
                     "body": base64.b64encode(body).decode()}
            seq[0] += 1
            try:
                attach.send(conn, 5, relay_frame(frame))
            except OSError:
                pass

    def assign():
        wait_until(lambda: attach.marked("assigned"), 120, "the client to mark the runner's place assigned")
        with lock:
            attach.send(conn, 4, control_assign(attempt["token"], attempt["input"], opened_keys(attempt)))

    try:
        conn, _ = attach.server.accept()
        conn.settimeout(180)
        if attach.read(conn) != (3, TOKEN.encode()):
            served["error"] = "the attach frame is not the spawn's token"
            return
        attach.send(conn, 5)
        threading.Thread(target=assign, daemon=True).start()
        control, relay = b"", b""
        while (frame := attach.read(conn)) is not None:
            stream, payload = frame
            if stream == 2:
                served["stderr"] += payload
            elif stream == 4:
                *lines, control = (control + payload).split(b"\n")
                served["control"] += [line.decode(errors="replace") for line in lines]
                if any('"type":"complete"' in line for line in served["control"]):
                    attach.mark("complete")
            elif stream == 5:
                calls, relay = relay_frames(relay + payload)
                for call in calls:
                    served["relay"].append(call.get("op") if call.get("kind") == "host_call" else call.get("kind"))
                    if call.get("kind") == "host_call":
                        threading.Thread(target=answer, args=(call,), daemon=True).start()
        conn.close()
    except (OSError, ValueError) as error:
        served["error"] = repr(error)


def held_until_measured(plane, attach):
    """The work's `push_deltas`, as the plane answers it: `hog.ready` at once; `hog.holding`, which the work sends once it
    holds its memory, marked `holding` and answered once the client has read the runner and marked `measured`."""

    def answer(args, caller, entry):
        entry["events"] = [json.loads(delta["event"]) for delta in args.get("deltas", [])]
        if entry["events"] == WORK_EVENTS[1]:
            attach.mark("holding")
            entry["let"] = wait_until(lambda: attach.marked("measured"), 20, "the client to read the runner at its work")
        return plane.default("push_deltas", args, caller)

    return answer


def test_measure(image):
    env = RUNNER_ENV
    plane = ControlPlane(secrets.token_bytes(32), SERVICE).serve()
    marks = ClientMarks()
    attach = Attach(marks)
    attempt = plane.mint(RUNNER_ENV["RUNTIME_BOOT_ID"], "catalyst", HOG_REF, wasm(HOG), {}, ATHANOR, WORK_TIMEOUT_MS)
    plane.script("push_deltas", held_until_measured(plane, attach), attempt["execution_id"])
    serving = threading.Thread(target=serve_work, args=(attach, plane, attempt), daemon=True)
    serving.start()
    try:
        ran = keeper_run(image, places_client(env), timeout=180, mounts=[attach.mount],
                         on_start=lambda container: setattr(marks, "container", container))
        serving.join(60)
    finally:
        attach.close()
        plane.stop()
    read = transcript(ran.stdout)
    served = attach.result or {}
    calls = plane.seen(None, attempt["execution_id"])
    for step, reply in read:
        if isinstance(reply, dict) and reply.get("type") == "measured":
            print(f"measure: {step}: {reply.get('kind')} of {reply.get('athanor', 'no athanor')}, "
                  f"{reply.get('bytes', 0) / (1 << 20):.0f} MiB (lesser {reply.get('lesser')}), read {reply.get('age_ms')} ms before", flush=True)
    detail = {"read": read, "relay": served.get("relay"), "control": served.get("control"), "attach": served.get("error"),
              "calls": [(call["op"], call.get("answered")) for call in calls],
              "runner_stderr": served.get("stderr", b"").decode(errors="replace")[-3000:], "keeper": ran.stderr[-3000:]}
    judge_places(read, detail)
    judge_work(served, calls, attempt)


# ---------------------------------------------------------------------------
# The shipped service
# ---------------------------------------------------------------------------


def runner_facts(stack, runner):
    """What /proc says of a runner, read by the observer."""
    pid = runner["pid"]
    script = (f"echo uid_map=$(cat /proc/{pid}/uid_map); echo gid_map=$(cat /proc/{pid}/gid_map); "
              f"echo setgroups=$(cat /proc/{pid}/setgroups); echo cgroup=$(cat /proc/{pid}/cgroup); "
              f"grep -E \"^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Groups):\" /proc/{pid}/status | tr -d \"\\t\" | sed \"s/:/=/\"; "
              f"echo net=$(readlink /proc/{pid}/ns/net); echo user=$(readlink /proc/{pid}/ns/user); "
              f"echo ipc=$(readlink /proc/{pid}/ns/ipc); "
              f"echo interfaces=$(tail -n +3 /proc/{pid}/net/dev | cut -d: -f1 | tr -d \" \" | tr \"\\n\" \" \"); "
              f"echo routes=$(tail -n +2 /proc/{pid}/net/route | wc -l); "
              f"for fd in /proc/{pid}/fd/*; do echo \"fd=${{fd##*/}} $(readlink $fd)\"; done")
    facts = {"fds": {}}
    for line in read_output(stack.observe(script), f"the facts of runner uid {runner['uid']}").splitlines():
        key, _, value = line.partition("=")
        if key == "fd":
            number, _, target = value.partition(" ")
            facts["fds"][int(number)] = target
        else:
            facts[key] = " ".join(value.split())
    return facts


def service_namespaces(stack):
    beam = stack.service_beam_pid()
    # Read by the observer (`Stack.observe`): the role's uid outside its own
    # user namespace reads none of its links, and the container's root
    # holds no capability to.
    out = stack.observe(f"readlink /proc/{beam}/ns/net; readlink /proc/{beam}/ns/user; readlink /proc/{beam}/ns/ipc; "
                     f"readlink /proc/{beam}/fd/3").stdout.split()
    return {"net": out[0], "user": out[1], "ipc": out[2], "channel": out[3]} if len(out) == 4 else None


def assert_isolated(stack, runner, label):
    facts = runner_facts(stack, runner)
    uid = runner["uid"]
    expect(facts.get("uid_map") == f"{uid} {uid} 1" and facts.get("gid_map") == f"{uid} {uid} 1" and facts.get("setgroups") == "deny",
           f"{label}: runner uid {uid}'s user namespace maps only its uid and gid to themselves, setgroups denied", facts)
    expect(all(facts.get(s) == NO_CAPS for s in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"))
           and facts.get("NoNewPrivs") == "1" and facts.get("Groups") == "",
           f"{label}: runner uid {uid} holds no capability in any of the five sets, no group, with no_new_privs", facts)
    return facts


def test_spawn(stack):
    runners = stack.runner_processes()
    expect(len(runners) == imagesuite.FLOOR_RUNNERS and all(POOL_FIRST <= r["uid"] <= POOL_LAST for r in runners),
           f"the shipped service under the profile fills its warm floor of {imagesuite.FLOOR_RUNNERS} runner(s)", runners)
    for runner in runners:
        assert_isolated(stack, runner, "spawn")


def test_cgroup(stack):
    for runner in stack.runner_processes():
        facts = runner_facts(stack, runner)
        cgroup = imagesuite.work_group(ROLE).removeprefix(imagesuite.CGROUP)
        expect(facts.get("cgroup") == f"0::{cgroup}/keeper-{runner['uid']}/bound",
               f"cgroup: runner uid {runner['uid']} runs in its own group, placed from the parent side before it ran", facts)


def test_network(stack):
    own = service_namespaces(stack)
    expect(own is not None, "the service's namespaces are read", own)
    for runner in stack.runner_processes():
        facts = runner_facts(stack, runner)
        expect(facts.get("net") and facts.get("net") != own["net"] and facts.get("user") != own["user"]
               and facts.get("ipc") and facts.get("ipc") != own["ipc"],
               f"network: runner uid {runner['uid']} has a network, a user and an IPC namespace of its own",
               {"runner": facts, "service": own})
        expect(facts.get("interfaces") == "lo" and facts.get("routes") == "0",
               f"network: runner uid {runner['uid']}'s namespace holds the loopback alone and no route", facts)


def test_descriptors(stack):
    own = service_namespaces(stack)
    for runner in stack.runner_processes():
        fds = runner_facts(stack, runner)["fds"]
        expect(all(fds.get(n, "").startswith("pipe:") for n in (0, 1, 2)) and fds.get(3, "").startswith("socket:")
               and fds.get(4, "").startswith("socket:") and fds[4] != fds[3],
               f"descriptors: runner uid {runner['uid']}'s stdio are pipes, its fd 3 its control socket and its fd 4 its relay, another socket", fds)
        expect(not [t for t in fds.values() if t.startswith(RUN_DIR) or t == own["channel"]],
               f"descriptors: none of runner uid {runner['uid']}'s descriptors reaches {RUN_DIR} or the service's keeper channel", fds)


def kill_runner(stack, runner, label):
    stack.exec(f"kill -9 {runner['pid']}")
    wait_until(lambda: stack.uid_processes(runner["uid"]) == [], 20, f"{label}: uid {runner['uid']} to hold no process")
    wait_until(lambda: os.path.basename(runner["home"]) not in stack.homes(), 20, f"{label}: the home of uid {runner['uid']} to be scrubbed")
    wait_until(lambda: group_removed(stack, runner["uid"]), 20, f"{label}: the group of uid {runner['uid']} to be removed")


def group_removed(stack, uid):
    """Whether the keeper group of `uid` is gone, from the word its probe prints in a successful exec.

    A failed exec is no answer whatever its status, and a stopped or
    restarting container is not taken for a removed group either.
    """
    probe = f"test -e {imagesuite.work_group(ROLE)}/keeper-{uid} && echo present || echo absent"
    return read_word(stack.exec(probe), ("present", "absent"), f"the keeper group of uid {uid}") == "absent"


def next_runner(stack, not_pid):
    return wait_until(lambda: next((r for r in stack.runner_processes() if r["pid"] != not_pid and r["home"]), None),
                      BOOT_S, "the pool to refill")


def test_kill(stack):
    runner = stack.runner_processes()[0]
    kill_runner(stack, runner, "kill")
    expect(True, f"kill: runner uid {runner['uid']} killed from outside is gone whole, its home scrubbed and its group removed")
    fresh = next_runner(stack, runner["pid"])
    assert_isolated(stack, fresh, "kill")


def test_reuse(stack):
    # A namespace's inode number is reused once the namespace is freed, so
    # the earlier runner's namespace is shown gone by its processes being
    # gone (kill_runner), and the new one is shown its own by what it holds.
    seen = {}
    runner = stack.runner_processes()[0]
    own = service_namespaces(stack)
    for _ in range(POOL_LAST - POOL_FIRST + 2):
        facts = runner_facts(stack, runner)
        if runner["uid"] in seen:
            before = seen[runner["uid"]]
            expect(runner["home"] != before["home"] and runner["pid"] != before["pid"]
                   and facts["net"] not in (own["net"], "") and facts["interfaces"] == "lo" and facts["routes"] == "0",
                   f"reuse: uid {runner['uid']} lent again has a fresh home and a namespace of its own, the loopback alone",
                   {"before": before, "now": facts})
            assert_isolated(stack, runner, "reuse")
            return
        seen[runner["uid"]] = {"pid": runner["pid"], "home": runner["home"]}
        kill_runner(stack, runner, "reuse")
        runner = next_runner(stack, runner["pid"])
    sys.exit(f"FAIL: reuse: no uid was lent twice over {len(seen)} runners")


def test_restart(stack):
    # The runtime role killed starts again alone; the container then
    # restarts, its keeper draining the cgroup the last one left.
    state = stack.container_state()
    beam = stack.service_beam_pid()
    stack.exec(f"kill -9 {beam}")
    wait_until(lambda: stack.service_beam_pid() not in (None, beam), 60, "the runtime role to start again")
    expect(stack.container_state()["restarts"] == state["restarts"],
           "restart: the runtime role killed starts again alone, in the same container", stack.container_state())
    stack.wait_listener()
    stack.wait_pool(timeout=BOOT_S)
    for runner in stack.runner_processes():
        assert_isolated(stack, runner, "role restart")
    run("docker", "restart", stack.container)
    stack.wait_listener()
    logs = stack.logs()
    unavailable = [line for line in logs.splitlines() if "CPU bounds are unavailable" in line]
    expect(not unavailable, "restart: the restarted keeper enforces memory bounds in the reused cgroup "
           "(a refusal names every pid its drain could not move and the write's error)", "\n".join(unavailable))
    stack.wait_pool(timeout=BOOT_S)
    for runner in stack.runner_processes():
        assert_isolated(stack, runner, "restart")


def main(image, steps):
    prerequisites(image)
    if "refusals" in steps:
        test_refusals(image)
    if "connect" in steps:
        test_connect(image)
    if "names" in steps:
        test_names(image)
    if "relay" in steps:
        test_relay(image)
    if "nested" in steps:
        test_nested(image)
    if "measure" in steps:
        test_measure(image)
    service_steps = [s for s in steps if s not in KEEPER_STEPS]
    if not service_steps:
        return
    plane = ControlPlane(secrets.token_bytes(32), SERVICE).serve()
    stack = IsolatedStack("cyfr-locus-runtime-namespace", image, plane)
    try:
        stack.up()
        for step in ("spawn", "cgroup", "network", "descriptors", "kill", "reuse", "restart"):
            if step in service_steps:
                globals()[f"test_{step}"](stack)
    finally:
        stack.down()
        plane.stop()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    chosen = sys.argv[2:] or list(STEPS)
    unknown = [s for s in chosen if s not in STEPS]
    if unknown:
        sys.exit(f"unknown steps {unknown}; the steps are {', '.join(STEPS)}")
    main(sys.argv[1], chosen)
