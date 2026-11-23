#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Every runner of the Locus image runs in a user and network namespace of its own, proven on the kernel.

cyfr-locus serves the image's runner pool isolated, under the pool and
isolation the role table names (stack.py reads them): it clones each
runner's stage into a new user and network namespace, maps the
runner's pooled uid and gid to themselves from the parent side, places the
stage in its cgroup, and only then releases it to drop every capability set
and execute the runner. The clone needs the image's seccomp profile
(apps/locus/keeper/seccomp/keeper.json, /etc/cyfr/keeper.json in the image) and a
host that allows unprivileged user namespaces; the service runs here under
that profile, as docker-compose.yml names it.

The steps, each observed from inside the container as root, which owns
every runner's user namespace and so reads a runner's /proc entries (the
runner's own uid, outside that namespace, may not):

- `refusals`: the image under Docker's default seccomp profile refuses to
  serve, naming user.max_user_namespaces and
  kernel.apparmor_restrict_unprivileged_userns; under the profile a spawn
  of the isolated pool without `isolation` is refused as bad_request.
- `connect`: a keeper started from the image under the profile, whose
  client is a shell speaking the keeper protocol, spawns a command of the
  isolated pool that dials the container's own loopback and its gateway:
  both are unreachable from the command (no route exists), while the same
  dial from the container's own namespace is answered.
- `relay`: under the profile a spawn of the isolated pool gets its relay
  on fd 4, carried as the keeper's stream 5: with a client that opens the
  stream, the runner's call on fd 4 arrives there and the answer reaches
  it; with one that never opens it, the runner writes to fd 4 and exits
  and the client receives no frame on stream 5, its end frame included.
- `nested`: under the profile, which lets a clone make a user and network
  namespace so the keeper can isolate each spawn, a runner makes none of
  its own: its clone with CLONE_NEWUSER, alone or with CLONE_NEWNET, is
  refused EPERM, where the same clone without a namespace flag makes a
  child; `unshare -U` is refused; and it still starts a thread.
- `measure`: one real runner, the release's own runner command with its
  control channel and relay as the shipped service spawns it, its relay
  attached and its control channel held open by this machine (no worker
  service speaks on it, and a runner with nothing assigned waits on it):
  its place is `warm` and no athanor's; once the keeper has read its
  group, a measure answers a reading above zero under that owner; assigned
  `run` for an athanor, `warm` for that athanor and `run` again for another
  run, each assign answered `assigned` under its own id before the next
  request, each measure answers above zero under the owner of the moment;
  after its `release`, a measure sent with it is still answered with a
  reading before `released`, and one after `released` is `unmeasured`.
- `spawn`: the shipped service fills its pool; every runner runs under a
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
of them needs the service to reach it. The keeper steps' clients speak
keeper protocol 3, each placing the place its spawn names first.

Usage: tests/locus-runtime-image/namespace.py IMAGE [STEP]...
"""

import json
import os
import re
import secrets
import shutil
import socket
import struct
import sys
import tempfile
import threading

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from control_plane import ControlPlane  # noqa: E402
from stack import (HOME_ROOT, POOL_FIRST, POOL_LAST, PROFILE, RELEASE, ROLE, RUN_DIR, SERVICE, SERVICE_UID,  # noqa: E402
                   SERVICE_USER, Stack, expect, run, wait_until)
from imagesuite import PROJECT_PREFIX, read_output, read_word, run_name  # noqa: E402

IMAGE_PROFILE = "/etc/cyfr/keeper.json"
KEEPER_STEPS = ("refusals", "connect", "relay", "nested", "measure")
STEPS = KEEPER_STEPS + ("spawn", "cgroup", "network", "descriptors", "kill", "reuse", "restart")
POOL = f"{ROLE['pool']}:{POOL_FIRST}-{POOL_LAST}:{ROLE['isolation']}"
TOKEN = "0123456789abcdef" * 4
# The place every spawn of the keeper steps but `measure` names.
PLACE = "p1"
# The bound every spawn names (`memory_bytes`, which the keeper requires): room enough for a shell and curl.
MEMORY_BYTES = 64 << 20
# One CPU of every 100000-microsecond period.
CPU_QUOTA = 100_000
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


def keeper_run(image, client_script, seccomp=True, timeout=120, mounts=()):
    """cyfr-locus from the image under the shipped service's options, serving the isolated pool to a shell client."""
    args = ["docker", "run", "--rm", *run_name(f"{PROJECT_PREFIX}locus-keeper-run-{os.getpid()}-{secrets.token_hex(4)}"),
            *[arg for mount in mounts for arg in ("-v", mount)], "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "KILL",
            "--security-opt", "no-new-privileges:true", "--security-opt", "writable-cgroups=true", "--read-only", "--ipc", "none", "--init",
            "--tmpfs", f"{HOME_ROOT}:mode=1733,exec,size=64m", "--tmpfs", f"{RUN_DIR}:uid={SERVICE_UID},gid={SERVICE_UID},mode=0700,size=4m"]
    if seccomp:
        args += ["--security-opt", f"seccomp={PROFILE}"]
    args += ["--entrypoint", "cyfr-locus", image, "serve", "--pool", POOL, "--home-root", HOME_ROOT,
             "--client-user", SERVICE_USER, "--", "/bin/sh", "-c", client_script]
    return run(*args, check=False, timeout=timeout)


def place_line(place, kind="warm", athanor=None):
    request = {"v": 3, "type": "place", "id": place, "kind": kind}
    if athanor:
        request["athanor"] = athanor
    return json.dumps(request)


def spawn_line(spawn_id, argv, isolated=True, env=None, control=False, attach=f"{RUN_DIR}/attach.sock", place=PLACE,
               memory_bytes=MEMORY_BYTES):
    request = {"v": 3, "type": "spawn", "id": spawn_id, "place": place, "pool": ROLE["pool"], "argv": argv, "env": env or {},
               "memory_bytes": memory_bytes, "cpu_quota": CPU_QUOTA, "attach": {"path": attach, "token": TOKEN}}
    if control:
        request["control"] = True
    if isolated:
        request["isolation"] = ROLE["isolation"]
    return json.dumps(request)


# The client's first request: the place its spawn names, whose answer it prints before it sends the spawn.
PLACE_FIRST = f"printf '%s\\n' '{place_line(PLACE)}' >&3; read -r line <&3; echo \"reply:$line\"; "


def replies(stdout):
    return [json.loads(line[len("reply:"):]) for line in stdout.splitlines() if line.startswith("reply:")]


def after_placed(ran, step):
    """The replies the client read after its first, which must be the keeper's `placed` for the place its spawn names."""
    got = replies(ran.stdout)
    expect(got[:1] == [{"v": 3, "type": "placed", "id": PLACE}],
           f"{step}: the keeper placed {PLACE} before the client sent the spawn naming it", {"replies": got, "stderr": ran.stderr[-2000:]})
    return got[1:]


def test_refusals(image):
    refused = keeper_run(image, "exec sleep 5", seccomp=False, timeout=60)
    expect(refused.returncode == 78 and "user.max_user_namespaces" in refused.stderr
           and "kernel.apparmor_restrict_unprivileged_userns" in refused.stderr,
           f"under Docker's default seccomp profile cyfr-locus refuses to serve the isolated pool, naming both settings (exit {refused.returncode})",
           refused.stderr)
    client = PLACE_FIRST + (f"printf '%s\\n' '{spawn_line('1', ['/bin/true'], isolated=False)}' >&3; "
                            "read -r line <&3; echo \"reply:$line\"")
    answered = keeper_run(image, client)
    expect(after_placed(answered, "refusals") == [{"v": 3, "type": "error", "id": "1", "code": "bad_request"}],
           "under the profile, a spawn of the isolated pool without isolation is refused as bad_request",
           answered.stdout + answered.stderr)


def test_connect(image):
    # The command dials the container's loopback and the container's own
    # address and exits 42 when both are unreachable. Its output has no
    # reader, since no client listens on the attach socket, so its exit
    # status is the answer. The client's shell, in the container's own
    # namespace, dials the same two first.
    command = ('n=0; for t in 127.0.0.1:9 "$TARGET:9"; do '
               'curl -sv --max-time 3 "http://$t/" 2>&1 | grep -q "Network is unreachable" && n=$((n+1)); done; '
               '[ $n -eq 2 ] && exit 42; exit $n')
    request = spawn_line("1", ["/bin/sh", "-c", command], env={"TARGET": "@ADDR@"})
    assert "'" not in request
    client = ('addr=$(getent hosts "$(cat /etc/hostname)" | awk "{print \\$1; exit}"); '
              'for t in 127.0.0.1:9 "$addr:9"; do '
              'echo "own $t:$(curl -sv --max-time 3 "http://$t/" 2>&1 | grep -o "Connection refused\\|Network is unreachable" | head -n1)"; done; '
              + PLACE_FIRST + f"printf '%s\\n' \"$(printf '%s' '{request}' | sed \"s/@ADDR@/$addr/\")\" >&3; "
              'read -r line <&3; echo "reply:$line"; read -r line <&3; echo "reply:$line"')
    ran = keeper_run(image, client)
    got = after_placed(ran, "connect")
    expect(len(got) == 2 and got[0]["type"] == "spawned" and POOL_FIRST <= got[0]["uid"] <= POOL_LAST,
           "connect: under the profile the keeper serves and spawns a command of the isolated pool", ran.stdout + ran.stderr)
    own = re.findall(r"^own (\S+):(.*)$", ran.stdout, re.M)
    expect(len(own) == 2 and all(answer == "Connection refused" for _, answer in own),
           "connect: from the container's own namespace its loopback and its address answer (the dial is refused, not unreachable)", own)
    expect(got[1]["type"] == "exited" and got[1]["code"] == 42,
           "connect: from the command's namespace neither the loopback nor the container's address is reachable: no route exists",
           {"replies": got, "stdout": ran.stdout, "stderr": ran.stderr[-2000:]})


class Attach:
    """The client's attach socket, on this machine in a directory mounted into the container, speaking the keeper's frames."""

    MOUNT = "/run/cyfr-attach"

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix=os.environ.get("PROOF_RUN_PREFIX", "") + "cyfr-attach-")
        os.chmod(self.dir, 0o755)
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

    def close(self):
        self.server.close()
        shutil.rmtree(self.dir, ignore_errors=True)


def relay_session(image, command, opens, env=None):
    """A spawn of the isolated pool running `command`, its relay served by this machine: the replies and what the relay carried."""
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
        return after_placed(ran, "a spawn of the isolated pool with its relay"), attach.result, ran
    finally:
        attach.close()


def test_relay(image):
    # A runner that calls on its relay (fd 4) and waits for the answer, the
    # client opening stream 5 first, as the worker service does.
    got, carried, ran = relay_session(image, 'printf "call\\n" >&4; IFS= read -r a <&4; echo "got:$a"', opens=True)
    expect([r["type"] for r in got] == ["spawned", "exited", "released"] and got[1].get("code") == 0,
           "relay: a spawn of the isolated pool whose client opens stream 5 runs to its exit", {"replies": got, "stderr": ran.stderr[-2000:]})
    expect(carried and carried.get("got", {}).get(5) == b"call\n" and carried["got"].get(1) == b"got:answer\n" and 5 in carried["ended"],
           "relay: once the client opened stream 5, the runner's call on fd 4 arrives there, the client's answer reaches fd 4, and the stream ends",
           carried)
    # A client that never opens stream 5 receives nothing on it from a
    # runner that writes to its relay and exits, its end frame included.
    got, carried, ran = relay_session(image, 'printf "call\\n" >&4; echo done', opens=False)
    expect([r["type"] for r in got] == ["spawned", "exited", "released"] and got[1].get("code") == 0,
           "relay: a spawn of the isolated pool whose client never opens stream 5 runs to its exit", {"replies": got, "stderr": ran.stderr[-2000:]})
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


def test_nested(image):
    command = ('arch=$(uname -m); echo "arch=$arch"; '
               'case "$arch" in ' + " ".join(f"{arch}) nr={nr};;" for arch, nr in CLONE_NR.items()) + ' *) nr=;; esac; '
               'u=$(unshare -U true 2>&1); echo "unshare=$u status $?"; '
               '[ -n "$nr" ] && perl -e "$CLONES" "$nr"; perl -Mthreads -e "$THREAD"')
    got, carried, ran = relay_session(image, command, opens=False, env={"CLONES": NESTED_CLONES, "THREAD": NESTED_THREAD})
    out = (carried or {}).get("got", {}).get(1, b"").decode(errors="replace")
    facts = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    detail = {"stdout": out, "stderr": (carried or {}).get("got", {}).get(2, b"").decode(errors="replace"), "replies": got,
              "keeper": ran.stderr[-2000:]}
    expect([r["type"] for r in got] == ["spawned", "exited", "released"] and got[1].get("code") == 0,
           "nested: a spawn of the isolated pool runs the probe to its exit", detail)
    expect(facts.get("arch") in CLONE_NR, f"nested: the runner knows clone's number on {facts.get('arch')}", detail)
    expect(facts.get("process") == "ok", "nested: a runner's clone without a namespace flag makes a child (the probe's control)", detail)
    expect(facts.get("newuser") == "EPERM" and facts.get("newuser_newnet") == "EPERM",
           "nested: a runner's clone with CLONE_NEWUSER, alone or with CLONE_NEWNET, is refused EPERM, "
           "though the profile lets the keeper make that clone", detail)
    expect("Operation not permitted" in facts.get("unshare", "") and not facts.get("unshare", "").endswith(" status 0"),
           "nested: a runner's `unshare -U` is refused", detail)
    expect(facts.get("thread") == "7", "nested: a runner still starts a thread and joins it", detail)


# The runner as the shipped service spawns it from a release (Locus.Runtime.Release.runner_command/1): the release's
# own command, the service's environment it shares (that module's shared names, as the image sets them) and the
# runner's own (Locus.Runtime.Settings.runner_environment/1), under the bound and grace the service's defaults give
# (Locus.Runtime.Settings). Its id names its place, as the runner pool's does.
RUNNER_ARGV = ["/bin/sh", "-c", 'RELEASE_TMP="${TMPDIR:-/tmp}" exec "$0" start', RELEASE["bin"]]
SHARED_ENVIRONMENT = ("LANG", "LANGUAGE", "LC_ALL", "ELIXIR_ERL_OPTIONS")
RUNNER = "runner_measured"
RUNNER_ENV = {"RELEASE_DISTRIBUTION": "none", "RUNTIME_ROLE": "runner", "RUNTIME_RUNNER_ID": RUNNER, "RUNTIME_SERVICE_ID": SERVICE,
              "RUNTIME_BOOT_ID": "boot_measured", "RUNTIME_WATCHDOG_GRACE_MS": "5000"}
RUNNER_MEMORY_BYTES = 384 << 20
RELEASE_GRACE_MS = 2_000
ATHANOR = "ath_measured"
# The runner's owners, one step each, read once the keeper has read its group: the place's own, then the owner an
# `assign` sent before the step gives it where the step before's was another (`assigns`).
OWNERS = (
    ("fresh", "warm", None, "fresh"),
    ("assigned", "run", ATHANOR, f"assigned a run of {ATHANOR}"),
    ("warm", "warm", ATHANOR, f"back at rest, still {ATHANOR}'s"),
    ("reused", "run", ATHANOR, f"reused for another run of {ATHANOR}"),
)

# The measure step's client, after the variables places_client sets. `ask` sends one measure of the place and
# reads up to its answer; `poll` asks until a reading answers it, the keeper reading each group once a second;
# `assign` sends an assign and reads up to its answer. Every reply read is printed as `read:<step>:<reply>`, an
# assign's as `read:<step>.assign:<reply>`. The release and a measure go in one write, and the replies are read up
# to `released`; then one more measure.
PLACES_CLIENT = r"""
ask() {
  n=$((n + 1))
  printf '{"v":3,"type":"measure","id":"m%s","place":"%s"}\n' "$n" "$place" >&3
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
n=0
printf '%s\n' "$placing" >&3; read -r line <&3; echo "read:placed:$line"
printf '%s\n' "$spawning" >&3; read -r line <&3; echo "read:spawned:$line"
sid=$(printf '%s' "$line" | sed -n 's/.*"spawn_id":"\([0-9a-f]*\)".*/\1/p')
[ -n "$sid" ] || exit 1
@OWNERS@
n=$((n + 1))
printf '{"v":3,"type":"release","spawn_id":"%s","grace_ms":%s}\n{"v":3,"type":"measure","id":"m%s","place":"%s"}\n' \
  "$sid" "$grace" "$n" "$place" >&3
while read -r line <&3; do
  echo "read:release:$line"
  case "$line" in *'"type":"released"'*) break ;; esac
done
ask after
"""


def runner_env(image):
    """The runner's whole environment: the shared names as the image sets them, then the runner's own."""
    config = json.loads(run("docker", "image", "inspect", "--format", "{{json .Config.Env}}", image).stdout or "null") or []
    image_env = dict(entry.split("=", 1) for entry in config)
    return {**{name: image_env[name] for name in SHARED_ENVIRONMENT if name in image_env}, **RUNNER_ENV}


def assigns():
    """The assign sent before each step whose owner is not the step before's, by step, with ids `as1`, `as2` and on:
    none is a measure's (`m<n>`), the spawn's (`1`) or the place's."""
    sent, before = {}, OWNERS[0][1:3]
    for step, kind, athanor, _ in OWNERS[1:]:
        if (kind, athanor) != before:
            sent[step] = {"v": 3, "type": "assign", "id": f"as{len(sent) + 1}", "place": RUNNER, "kind": kind, "athanor": athanor}
        before = (kind, athanor)
    return sent


def places_client(env):
    """The measure step's client: the runner placed warm, spawned with `env` in its place, read under each owner, released and read again."""
    variables = {
        "place": RUNNER,
        "grace": str(RELEASE_GRACE_MS),
        "placing": place_line(RUNNER),
        "spawning": spawn_line("1", RUNNER_ARGV, env=env, control=True, attach=f"{Attach.MOUNT}/a.sock", place=RUNNER,
                               memory_bytes=RUNNER_MEMORY_BYTES),
    }
    sent = {step: (request["id"], json.dumps(request)) for step, request in assigns().items()}
    assert "'" not in "".join(variables.values()) + "".join(line for _, line in sent.values())
    owners = "".join((f"assign {step} {sent[step][0]} '{sent[step][1]}' || exit 1\n" if step in sent else "") + f"poll {step} || exit 1\n"
                     for step, *_ in OWNERS)
    return "".join(f"{name}='{value}'\n" for name, value in variables.items()) + PLACES_CLIENT.replace("@OWNERS@\n", owners)


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
    owner = {"v": 3, "type": "measured", "id": reply.get("id"), "kind": kind, **({"athanor": athanor} if athanor else {})}
    return ({key: value for key, value in reply.items() if key not in ("bytes", "lesser", "age_ms")} == owner
            and type(reply.get("bytes")) is int and reply["bytes"] > 0 and type(reply.get("lesser")) is bool
            and type(reply.get("age_ms")) is int and reply["age_ms"] >= 0)


def unmeasured(reply):
    return isinstance(reply, dict) and reply == {"v": 3, "type": "error", "id": reply.get("id"), "code": "unmeasured"}


def judge_places(read, detail):
    """The measure step's verdict on what its client read (`transcript`)."""
    steps = {}
    for step, reply in read:
        steps.setdefault(step, []).append(reply)
    expect(steps.get("placed") == [{"v": 3, "type": "placed", "id": RUNNER}], f"measure: the keeper placed the runner's place {RUNNER}, warm",
           detail)
    spawned = (steps.get("spawned") or [None])[0]
    expect(isinstance(spawned, dict)
           and {key: value for key, value in spawned.items() if key not in ("spawn_id", "uid", "pid")} == {"v": 3, "type": "spawned", "id": "1"}
           and re.fullmatch(r"[0-9a-f]{32}", str(spawned.get("spawn_id"))) is not None
           and type(spawned.get("uid")) is int and POOL_FIRST <= spawned["uid"] <= POOL_LAST
           and type(spawned.get("pid")) is int and spawned["pid"] > 0,
           "measure: the runner is spawned in its place, under a uid of the isolated pool", detail)
    ids = [reply.get("id") for step, reply in read
           if not step.endswith(".assign") and isinstance(reply, dict) and reply.get("type") in ("measured", "error")]
    expect(ids == [f"m{n}" for n in range(1, len(ids) + 1)], "measure: every measure was answered once, under its own id, in the order sent",
           detail)
    sent = assigns()
    for step, kind, athanor, what in OWNERS:
        if step in sent:
            expect(steps.get(f"{step}.assign") == [{"v": 3, "type": "assigned", "id": sent[step]["id"]}],
                   f"measure: before {step}, the keeper applied the assign of {kind} for {athanor} and answered it under its id, "
                   "and nothing else came before that answer", detail)
        got = steps.get(step, [])
        # Only the first reading is waited for: until the keeper has read the group, its place is unmeasured.
        expect(got and (step == OWNERS[0][0] or len(got) == 1) and all(unmeasured(reply) for reply in got[:-1])
               and reading(got[-1], kind, athanor),
               f"measure: {what}, the runner is read above zero under that owner ({kind}, {athanor or 'no athanor'})", detail)
    _, kind, athanor, _ = OWNERS[-1]
    released = steps.get("release", [])
    end = next((n for n, reply in enumerate(released) if isinstance(reply, dict) and reply.get("type") == "released"), None)
    measures = [n for n, reply in enumerate(released) if isinstance(reply, dict) and reply.get("type") in ("measured", "error")]
    expect(end is not None and released[end] == {"v": 3, "type": "released", "spawn_id": spawned["spawn_id"]}
           and len(measures) == 1 and measures[0] < end and reading(released[measures[0]], kind, athanor),
           "measure: after its release, the runner's place is still read above zero, answered before its released", detail)
    after = steps.get("after", [])
    expect(len(after) == 1 and unmeasured(after[0]), "measure: after its released, the runner's place is free: its measure is unmeasured",
           detail)


def test_measure(image):
    env = runner_env(image)
    attach = Attach()
    serving = threading.Thread(target=attach.serve, args=(False,), daemon=True)
    serving.start()
    try:
        ran = keeper_run(image, places_client(env), mounts=[attach.mount])
        serving.join(60)
    finally:
        attach.close()
    read = transcript(ran.stdout)
    carried = attach.result or {}
    for step, reply in read:
        if isinstance(reply, dict) and reply.get("type") == "measured":
            print(f"measure: {step}: {reply.get('kind')} of {reply.get('athanor', 'no athanor')}, "
                  f"{reply.get('bytes', 0) / (1 << 20):.0f} MiB (lesser {reply.get('lesser')}), read {reply.get('age_ms')} ms before", flush=True)
    judge_places(read, {"read": read, "runner_stderr": carried.get("got", {}).get(2, b"").decode(errors="replace")[-3000:],
                        "attach": carried.get("error"), "keeper": ran.stderr[-3000:]})


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
    out = stack.as_uid(SERVICE_UID, f"readlink /proc/{beam}/ns/net; readlink /proc/{beam}/ns/user; readlink /proc/{beam}/fd/3").stdout.split()
    return {"net": out[0], "user": out[1], "channel": out[2]} if len(out) == 3 else None


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
    expect(len(runners) == stack.pool_size and all(POOL_FIRST <= r["uid"] <= POOL_LAST for r in runners),
           f"the shipped service under the profile fills its pool of {stack.pool_size} runners", runners)
    for runner in runners:
        assert_isolated(stack, runner, "spawn")


def test_cgroup(stack):
    for runner in stack.runner_processes():
        facts = runner_facts(stack, runner)
        expect(facts.get("cgroup") == f"0::/keeper-{runner['uid']}/bound",
               f"cgroup: runner uid {runner['uid']} runs in its own group, placed from the parent side before it ran", facts)


def test_network(stack):
    own = service_namespaces(stack)
    expect(own is not None, "the service's namespaces are read", own)
    for runner in stack.runner_processes():
        facts = runner_facts(stack, runner)
        expect(facts.get("net") and facts.get("net") != own["net"] and facts.get("user") != own["user"],
               f"network: runner uid {runner['uid']} has a network and a user namespace of its own", {"runner": facts, "service": own})
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
    probe = f"test -e /sys/fs/cgroup/keeper-{uid} && echo present || echo absent"
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
    state = stack.container_state()
    beam = stack.service_beam_pid()
    stack.exec(f"kill -9 {beam}")
    stack.wait_restarted(state, 60)
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
    stack = IsolatedStack("cyfr-locus-runtime-namespace", image, plane, pool_size=1)
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
