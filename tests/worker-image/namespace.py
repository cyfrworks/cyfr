#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Every runner of the Opus image runs in a user and network namespace of its own, proven on the kernel.

cyfr-keeper serves the image's runner pool isolated (`runner:…:netns`): it
clones each runner's stage into a new user and network namespace, maps the
runner's pooled uid and gid to themselves from the parent side, places the
stage in its cgroup, and only then releases it to drop every capability set
and execute the runner. The clone needs the image's seccomp profile
(apps/keeper/seccomp/keeper.json, /etc/cyfr/keeper.json in the image) and a
host that allows unprivileged user namespaces; the service runs here under
that profile, docker-compose.yml's own when it names it, else layered on
by this suite.

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
  it; with one that never opens it, as today's Opus client, the runner
  writes to fd 4 and exits and the client receives no frame on stream 5,
  its end frame included.
- `spawn`: the shipped service fills its pool; every runner runs under a
  pooled uid whose user namespace maps only that uid and gid to themselves
  with setgroups denied, and holds no capability in any of the five sets,
  with no_new_privs.
- `cgroup`: every runner is in its own group, /keeper-<uid>, at its bound.
- `network`: every runner's network and user namespaces are not the
  service's; its namespace has one interface, the loopback, and no route.
- `descriptors`: a runner's standard descriptors are pipes, its fd 3 is
  its control socket and its fd 4 its relay, another socket, and none of
  its descriptors reaches /run/opus or the service's keeper channel.
  The service never opens stream 5, so every runner exit in the steps
  below is a relay the client never used, and none is a relay fault.
- `kill`: a runner killed from outside is gone with every process of its
  uid, its home scrubbed and its group removed, and the pool refills.
- `reuse`: runners are killed until a uid is lent again; the runner that
  gets it has a fresh home and a fresh namespace, isolated as the first.
- `restart`: the service's VM is killed, the keeper retires every runner
  and exits, the container restarts in place in the same cgroup, and the
  new keeper serves with its memory bounds (its start-time drain moved
  every process of the reused cgroup root, or its refusal names each pid
  it could not move with the write's error); its runners are isolated.

The suite needs a host that allows unprivileged user namespaces. The
service steps sign their requests with the scripted control plane's keys
(control_plane.py); none of them needs the service to reach it.

Usage: tests/worker-image/namespace.py IMAGE [STEP]...
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

from control_plane import ControlPlane
from stack import (HOME_ROOT, POOL_FIRST, POOL_LAST, ROOT, SERVICE, SERVICE_UID, Stack, expect, run,
                   wait_until)

PROFILE = os.path.join(ROOT, "apps", "keeper", "seccomp", "keeper.json")
IMAGE_PROFILE = "/etc/cyfr/keeper.json"
STEPS = ("refusals", "connect", "relay", "spawn", "cgroup", "network", "descriptors", "kill", "reuse", "restart")
POOL = f"runner:{POOL_FIRST}-{POOL_LAST}:netns"
TOKEN = "0123456789abcdef" * 4
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
    shipped = run("docker", "run", "--rm", "--entrypoint", "cat", image, IMAGE_PROFILE, check=False).stdout
    with open(PROFILE) as f:
        expect(json.loads(shipped or "null") == json.load(f), f"the image carries {PROFILE} as {IMAGE_PROFILE}")
    for sysctl in ("user/max_user_namespaces", "kernel/apparmor_restrict_unprivileged_userns"):
        path = os.path.join("/proc/sys", sysctl)
        value = open(path).read().strip() if os.path.exists(path) else "absent"
        print(f"host: {sysctl.replace('/', '.')} = {value}", flush=True)


class IsolatedStack(Stack):
    """The shipped opus service under the keeper's seccomp profile: compose's own when it names it, else layered here."""

    def compose(self, *args, check=True):
        files = [os.path.join(ROOT, "docker-compose.yml"), os.path.join(os.path.dirname(os.path.abspath(__file__)), "compose.worker.yml")]
        with open(files[0]) as f:
            if "keeper.json" not in f.read():
                overlay = os.path.join(self.project_dir, "compose.seccomp.yml")
                with open(overlay, "w") as out:
                    out.write(f"services:\n  opus:\n    security_opt:\n      - seccomp={PROFILE}\n")
                files.append(overlay)
        return run("docker", "compose", "--project-name", self.project, "--project-directory", self.project_dir,
                   *[arg for path in files for arg in ("-f", path)], *args, env=self.env(), check=check)

    def as_uid(self, uid, script):
        """`script` run in the container as `uid`, which may read that uid's /proc entries in the container's own user namespace."""
        return self.exec(f"setpriv --reuid={uid} --regid={uid} --clear-groups sh -c '{script}'")


# ---------------------------------------------------------------------------
# A keeper started from the image with a shell for its client
# ---------------------------------------------------------------------------


def keeper_run(image, client_script, seccomp=True, timeout=120, mounts=()):
    """cyfr-keeper from the image under the shipped service's options, serving the isolated pool to a shell client."""
    args = ["docker", "run", "--rm", *[arg for mount in mounts for arg in ("-v", mount)], "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "KILL",
            "--security-opt", "no-new-privileges:true", "--read-only", "--ipc", "none", "--init",
            "--tmpfs", f"{HOME_ROOT}:mode=1733,exec,size=64m", "--tmpfs", f"/run/opus:uid={SERVICE_UID},gid={SERVICE_UID},mode=0700,size=4m"]
    if seccomp:
        args += ["--security-opt", f"seccomp={PROFILE}"]
    args += ["--entrypoint", "cyfr-keeper", image, "serve", "--pool", POOL, "--home-root", HOME_ROOT,
             "--client-user", "opus", "--", "/bin/sh", "-c", client_script]
    return run(*args, check=False, timeout=timeout)


def spawn_line(spawn_id, argv, isolated=True, env=None, control=False, attach="/run/opus/attach.sock"):
    request = {"v": 1, "type": "spawn", "id": spawn_id, "pool": "runner", "argv": argv, "env": env or {},
               "attach": {"path": attach, "token": TOKEN}}
    if control:
        request["control"] = True
    if isolated:
        request["isolation"] = "netns"
    return json.dumps(request)


def replies(stdout):
    return [json.loads(line[len("reply:"):]) for line in stdout.splitlines() if line.startswith("reply:")]


def test_refusals(image):
    refused = keeper_run(image, "exec sleep 5", seccomp=False, timeout=60)
    expect(refused.returncode == 78 and "user.max_user_namespaces" in refused.stderr
           and "kernel.apparmor_restrict_unprivileged_userns" in refused.stderr,
           f"under Docker's default seccomp profile cyfr-keeper refuses to serve the isolated pool, naming both settings (exit {refused.returncode})",
           refused.stderr)
    client = (f"printf '%s\\n' '{spawn_line('1', ['/bin/true'], isolated=False)}' >&3; "
              "read -r line <&3; echo \"reply:$line\"")
    answered = keeper_run(image, client)
    expect(replies(answered.stdout) == [{"v": 1, "type": "error", "id": "1", "code": "bad_request"}],
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
              f"printf '%s\\n' \"$(printf '%s' '{request}' | sed \"s/@ADDR@/$addr/\")\" >&3; "
              'read -r line <&3; echo "reply:$line"; read -r line <&3; echo "reply:$line"')
    ran = keeper_run(image, client)
    got = replies(ran.stdout)
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
        self.dir = tempfile.mkdtemp(prefix="cyfr-attach-")
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


def relay_session(image, command, opens):
    """A spawn of the isolated pool running `command`, its relay served by this machine: the replies and what the relay carried."""
    attach = Attach()
    serving = threading.Thread(target=attach.serve, args=(opens,), daemon=True)
    serving.start()
    try:
        request = spawn_line("1", ["/bin/sh", "-c", command], control=True, attach=f"{Attach.MOUNT}/a.sock")
        assert "'" not in request
        client = (f"printf '%s\\n' '{request}' >&3; "
                  'for n in 1 2 3; do read -r line <&3; echo "reply:$line"; done')
        ran = keeper_run(image, client, mounts=[attach.mount])
        serving.join(60)
        return replies(ran.stdout), attach.result, ran
    finally:
        attach.close()


def test_relay(image):
    # A runner that calls on its relay (fd 4) and waits for the answer, the
    # client opening stream 5 first, as the worker service will.
    got, carried, ran = relay_session(image, 'printf "call\\n" >&4; IFS= read -r a <&4; echo "got:$a"', opens=True)
    expect([r["type"] for r in got] == ["spawned", "exited", "released"] and got[1].get("code") == 0,
           "relay: a spawn of the isolated pool whose client opens stream 5 runs to its exit", {"replies": got, "stderr": ran.stderr[-2000:]})
    expect(carried and carried.get("got", {}).get(5) == b"call\n" and carried["got"].get(1) == b"got:answer\n" and 5 in carried["ended"],
           "relay: once the client opened stream 5, the runner's call on fd 4 arrives there, the client's answer reaches fd 4, and the stream ends",
           carried)
    # Today's Opus client never opens stream 5: a runner that writes to its
    # relay and exits sends it nothing, its end frame included.
    got, carried, ran = relay_session(image, 'printf "call\\n" >&4; echo done', opens=False)
    expect([r["type"] for r in got] == ["spawned", "exited", "released"] and got[1].get("code") == 0,
           "relay: a spawn of the isolated pool whose client never opens stream 5 runs to its exit", {"replies": got, "stderr": ran.stderr[-2000:]})
    expect(carried and 5 not in carried.get("streams", [5]) and carried["got"].get(1) == b"done\n" and {1, 2, 4} <= set(carried["ended"]),
           "relay: a client that never opened stream 5 receives no frame on it, its end included, though the runner wrote to fd 4",
           carried)


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
    for line in stack.observe(script).stdout.splitlines():
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
        expect(facts.get("cgroup") == f"0::/keeper-{runner['uid']}",
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
        expect(not [t for t in fds.values() if t.startswith("/run/opus") or t == own["channel"]],
               f"descriptors: none of runner uid {runner['uid']}'s descriptors reaches /run/opus or the service's keeper channel", fds)


def kill_runner(stack, runner, label):
    stack.exec(f"kill -9 {runner['pid']}")
    wait_until(lambda: stack.uid_processes(runner["uid"]) == [], 20, f"{label}: uid {runner['uid']} to hold no process")
    wait_until(lambda: os.path.basename(runner["home"]) not in stack.homes(), 20, f"{label}: the home of uid {runner['uid']} to be scrubbed")
    wait_until(lambda: stack.exec(f"test -e /sys/fs/cgroup/keeper-{runner['uid']}").returncode != 0, 20,
               f"{label}: the group of uid {runner['uid']} to be removed")


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
    wait_until(lambda: (lambda s: s if s["restarts"] > state["restarts"] and s["running"] else None)(stack.container_state()),
               60, "the container to restart in place")
    stack.wait_listener()
    logs = stack.logs()
    unavailable = [line for line in logs.splitlines() if "memory bounds are unavailable" in line]
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
    service_steps = [s for s in steps if s not in ("refusals", "connect", "relay")]
    if not service_steps:
        return
    plane = ControlPlane(secrets.token_bytes(32), SERVICE).serve()
    stack = IsolatedStack("cyfr-opus-namespace", image, plane, pool_size=1)
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
