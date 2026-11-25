#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""One Locus container serves the three roles, each apart and bounded as its container was.

Run as docker-compose.yml's locus service behind its guard, holding all
three keys (compose.backends.yml, compose.roles.yml), and driven by requests
signed as CYFR signs them:

- The container turns healthy, which the image's probe (apps/locus/health.sh)
  says only once every role answers; a run of the runtime completes, a build
  of the builds role succeeds and a program of the backends role answers.
- Each role is a process of its own user, in namespaces of its own: no two
  roles, and no role and the container, share a pid, IPC, mount, network or
  user namespace. A role's process serves its own port alone, as a release
  holding another role's key would not; its view of the files holds its own
  run folder and no other role's, no home root and no kept homes' root.
- From a build and from a program, another role's key, processes, IPC
  objects, port, homes and run folder are each out of reach; a runner has no
  network at all (tests/locus-runtime-image/runners.py).
- Each role's live process runs in its role's group and is held to the
  bounds of its container of before, read from its own group up: runtime
  4G of memory and as much swap, 4 processors; builds 4G and 2; backends 2G
  and no processor bound.
- A role killed starts again alone: the other two keep their processes and
  a program's session keeps running; the container started again serves
  all three.

A request on a role's channel naming another role's pool, spawn, place or
home is refused by the keeper itself, and a role's environment holds its
own variables alone, as the keeper's tests prove
(apps/locus/keeper/internal/serve/roles_linux_test.go,
TestARoleNamesOnlyItsOwn, and config_test.go,
TestRoleEnvironHoldsTheRolesOwnAndNothingOfAnothers): no client of this
suite holds a role's channel, and a role's environment is not readable
from outside its space.

It serves nothing on the host's port 4000 (every role's port is published
on a loopback port of Docker's choosing) and reaches no cyfr.run: the
runtime's host API is a control plane on this machine, and no program
fetches anything. The update from the three-container image, which needs
that image, is roles_update.py's, run by hand.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/roles.py IMAGE
"""

import importlib.util
import json
import os
import secrets
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from harness import (  # noqa: E402
    GUARD, KEPT_ROOT, RELEASE, ROOT, Stack, eventually, expect, owner_of, probe, require_docker, run, wait_healthy,
)
import imagesuite  # noqa: E402
from kept_home import sh  # noqa: E402

with open(os.path.join(ROOT, "tests", "fixtures", "locus_roles.json"), encoding="utf-8") as _roles:
    ROLES = {role["name"]: role for role in json.load(_roles)["roles"]}


def load(name, path):
    """A suite module of another directory, under a name of its own: each image suite has its own `stack`."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, os.path.dirname(path))
    spec.loader.exec_module(module)
    return module


builder = load("builder_stack", os.path.join(ROOT, "tests", "builder-image", "stack.py"))
plane_module = load("runtime_control_plane", os.path.join(ROOT, "tests", "locus-runtime-image", "control_plane.py"))

OWNER = owner_of("roles")
SERVICE_ID = "wrk_roles"
ECHO = os.path.join(ROOT, "apps", "locus", "test", "support", "runtime", "test_wasm", "echo.wasm")
ECHO_REF = "reagent:local.echo:0.1.0"
# Each role's bounds as its container had them: memory and swap, in bytes,
# and the processors as cgroup v2's `cpu.max` reads them.
BOUNDS = {
    "runtime": ("4294967296", "4294967296", "400000 100000"),
    "builds": ("4294967296", "4294967296", "200000 100000"),
    "backends": ("2147483648", "2147483648", "max 100000"),
}
# What a build and a program try of the other roles, from their own spaces,
# each printing `<what>:<answer>`: the other roles' run folders, homes and the
# kept root, the role processes and their keys, IPC objects, and each role's
# port at Locus's address.
REACH = (
    "for p in " + " ".join([role["run_dir"] for role in ROLES.values()] + [role["home_root"] for role in ROLES.values()]
                           + [ROLES["backends"]["kept_root"]]) + "; do\n"
    '  if ls -A "$p" >/dev/null 2>&1; then echo "path $p:listed"; else echo "path $p:refused"; fi\n'
    "done\n"
    'echo "beam:$(grep -l "beam[.]smp" /proc/[0-9]*/cmdline 2>/dev/null | wc -l)"\n'
    "echo \"keys:$(cat /proc/[0-9]*/environ 2>/dev/null | tr '\\0' '\\n' | grep -c '^LOCUS_.*_KEY=')\"\n"
    "echo \"ipc:$(cat /proc/sysvipc/shm /proc/sysvipc/sem /proc/sysvipc/msg 2>/dev/null | grep -vc '^ *key')\"\n"
    "for port in " + " ".join(str(role["port"]) for role in ROLES.values()) + "; do\n"
    f'  if curl -s -o /dev/null --max-time 3 "http://{RELEASE["service"]}:$port/"; then echo "port $port:reached"; '
    'else echo "port $port:refused"; fi\n'
    "done\n"
)


class RolesStack(Stack):
    """The backends suite's stack with the runtime's and the builds' keys beside its own, every port published."""

    def __init__(self, project, image, plane):
        super().__init__(project, image)
        self.plane = plane
        self.builds_key = secrets.token_hex(32)

    def env(self, **extra):
        return super().env(**{
            "LOCUS_RUNTIME_KEY": self.plane.worker_key.hex(),
            "LOCUS_RUNTIME_SERVICE_ID": SERVICE_ID,
            "LOCUS_RUNTIME_HOST_API_URL": self.plane.container_url,
            "CYFR_LOCUS_BUILDS_KEY": self.builds_key,
            **extra,
        })

    def compose(self, *args, check=True, env=None):
        files = [os.path.join(ROOT, "docker-compose.yml"), os.path.join(HERE, "compose.backends.yml"),
                 os.path.join(HERE, "compose.roles.yml")]
        return run("docker", "compose", "--project-name", self.project, "--project-directory", self.project_dir,
                   *[arg for file in files for arg in ("-f", file)], *args, env=env or self.env(), check=check)

    def port(self, role):
        return "http://" + self.compose("port", GUARD, str(ROLES[role]["port"])).stdout.strip().splitlines()[0]

    def role_pids(self):
        """The role processes, by role: the release whose uid is the role's."""
        uids = {role["uid"]: name for name, role in ROLES.items()}
        return {uids[p["uids"][0]]: p["pid"] for p in self.processes()
                if "beam.smp" in p["cmd"] and p["uids"][0] in uids}

    def healthy(self, timeout_s=180):
        def health():
            state = run("docker", "inspect", "--format", "{{.State.Health.Status}}", self.container, check=False)
            return state.stdout.strip() == "healthy"
        return eventually(health, "the container to be healthy", timeout_s=timeout_s)


def namespaces(stack, pid):
    script = " && ".join(f"echo {ns}:$(readlink /proc/{pid}/ns/{ns})" for ns in ("pid", "ipc", "mnt", "net", "user"))
    out = imagesuite.read_output(stack.exec(script), f"the namespaces of {pid}")
    return dict(line.split(":", 1) for line in out.splitlines())


def test_apart(stack, pids):
    """Each role process in namespaces of its own, holding its own key and seeing its own run folder alone."""
    own = namespaces(stack, "self")
    seen = {name: namespaces(stack, pid) for name, pid in pids.items()}
    for ns in ("pid", "ipc", "mnt", "net", "user"):
        values = [own[ns]] + [seen[name][ns] for name in ROLES]
        expect(len(set(values)) == len(values), f"no two roles, and no role and the container, share a {ns} namespace",
               {"container": own[ns], **{name: seen[name][ns] for name in ROLES}})
    for name, pid in pids.items():
        role = ROLES[name]
        user = imagesuite.read_output(stack.exec(f"stat -c %u /proc/{pid}"), f"{name}'s uid").strip()
        expect(user == str(role["uid"]), f"the {name} role runs as {role['user']}", user)
        # A role's process holds its own key alone: the release serves every role whose key it holds, so a role
        # that held another's would listen on that one's port too. Its namespace's table is read from outside.
        listening = imagesuite.read_output(
            stack.exec(f"awk '$4 == \"0A\" {{print $2}}' /proc/{pid}/net/tcp /proc/{pid}/net/tcp6"), f"{name}'s sockets")
        ports = sorted({int(address.rsplit(":", 1)[1], 16) for address in listening.split()
                        if not address.startswith("0B00007F:")})
        expect(ports == [role["port"]], f"the {name} role serves its own port, {role['port']}, and no other role's",
               listening)
        mounts = imagesuite.read_output(stack.exec(f"cat /proc/{pid}/mountinfo"), f"{name}'s mounts")
        points = {line.split()[4] for line in mounts.splitlines()}
        others = [ROLES[other]["run_dir"] for other in ROLES if other != name]
        held = [path for path in others + [ROLES[o]["home_root"] for o in ROLES] + [KEPT_ROOT] if path in points]
        expect(role["run_dir"] in points and held == [],
               f"the {name} role sees its own run folder and no other role's, no home root and no kept root",
               sorted(points))


def reach_lines(text):
    return dict(line.rsplit(":", 1) for line in text.splitlines() if ":" in line)


def judge_reach(where, got, own):
    """`got` from a spawn of the role `own`, which sees its own home under its role's home root and nothing else."""
    paths = {key: value for key, value in got.items() if key.startswith("path ")}
    others = {key: value for key, value in paths.items() if key != f"path {ROLES[own]['home_root']}"}
    expect(len(paths) == 7 and all(value == "refused" for value in others.values()),
           f"from {where}, no role's run folder, no other role's home root and no kept root is reachable", got)
    expect(got.get("beam") == "0" and got.get("keys") == "0",
           f"from {where}, no role's process and no role's key is in sight", got)
    expect(got.get("ipc") == "0", f"from {where}, no IPC object of another is in sight", got)
    ports = {key: value for key, value in got.items() if key.startswith("port ")}
    expect(len(ports) == 3 and all(value == "refused" for value in ports.values()),
           f"from {where}, no role's port is reached", got)


def test_reach(stack, c):
    ran = sh(c, OWNER, REACH, program="scratch")
    judge_reach("a program", reach_lines(ran["stdout"]), "backends")
    b = builder.Stack.__new__(builder.Stack)
    b.base, b.key = stack.port("builds"), stack.builds_key
    status, answer = b.build(builder.tincture(f"mkdir -p dist\n{{ {REACH} }} > dist/index.html\n"), "javascript", "tincture")
    expect(status == 200, "a build of the builds role succeeds", builder.brief(answer))
    judge_reach("a build", reach_lines(builder.output_file(answer, "index.html") or ""), "builds")


def test_run(stack, plane):
    base = stack.port("runtime")
    status = eventually(lambda: (lambda s: s if s[0] == 200 else None)(plane.status(base)),
                        "the runtime to answer a signed status", timeout_s=90)
    boot = status[1]["ok"]["boot"]
    with open(ECHO, "rb") as f:
        attempt = plane.mint(boot, "reagent", ECHO_REF, f.read(), {"roles": "one"}, "ath_roles", 30_000)
    expect(plane.start(base, attempt)[1] == {"v": 1, "ok": True}, "a run starts in the runtime role")
    complete = plane.wait_seen("complete", attempt["execution_id"], 90)[0]
    expect(complete["args"]["outcome"]["output"] == {"roles": "one"}, "the run completes with its answer", complete)


def effective_bounds(chain):
    """A process's bounds from its group's chain, its own group first: each memory file's least value and the
    processors' least share, as the kernel holds the process to them, in cgroup v2's own words."""
    def least(file):
        values = [int(entry[file]) for entry in chain if entry.get(file, "max") != "max"]
        return str(min(values)) if values else "max"
    cpus = [entry["cpu.max"] for entry in chain if not entry.get("cpu.max", "max").startswith("max")]
    cpu = min(cpus, key=lambda v: int(v.split()[0]) / int(v.split()[1])) if cpus else "max 100000"
    return [least("memory.max"), least("memory.swap.max"), cpu]


def test_bounds(stack, pids):
    """Each role's live process is in its role's group, and the bounds the kernel holds that process to, read from
    its own group up to the container's, are its container's of before."""
    files = ("memory.max", "memory.swap.max", "cpu.max")
    for name, want in BOUNDS.items():
        # Its own group, then each group up to the container's, at most eight.
        script = (f"g=$(sed -n 's/^0:://p' /proc/{pids[name]}/cgroup); echo \"$g\"; d=/sys/fs/cgroup${{g%/}}\n"
                  "for _ in 1 2 3 4 5 6 7 8; do for f in " + " ".join(files) + "; do\n"
                  "  printf '%s=%s;' \"$f\" \"$(cat \"$d/$f\" 2>/dev/null || echo max)\"; done; echo\n"
                  "  [ \"$d\" = /sys/fs/cgroup ] && break; d=$(dirname \"$d\"); done")
        lines = imagesuite.read_output(stack.exec(script), f"{name}'s process's groups").strip().split("\n")
        group, chain = lines[0], [dict(kv.split("=", 1) for kv in line.strip(";").split(";")) for line in lines[1:]]
        expect(group.startswith(f"/role-{name}/"), f"the {name} role's process runs in the {name} role's group", group)
        expect(effective_bounds(chain) == list(want),
               f"the {name} role's process is held to its container's bounds of before: memory {want[0]}, swap {want[1]}, "
               f"cpu {want[2]}", [group, chain])


def test_restart_alone(stack, c, victim):
    before = stack.role_pids()
    session = c.mcp(OWNER, "scratch", key="steady")
    steady = session.call("whoami", {})
    expect(steady[0] == 200, "a program's session runs before a role is killed", steady)
    stack.exec(f"kill -9 {before[victim]}")
    after = eventually(lambda: (lambda p: p if p.get(victim) not in (None, before[victim]) else None)(stack.role_pids()),
                       f"the {victim} role to start again", timeout_s=60)
    for name in ROLES:
        if name != victim:
            expect(after[name] == before[name], f"killing the {victim} role leaves the {name} role's process", [before, after])
    stack.healthy()
    # The container's health is read every ten seconds: the backends' own
    # answer says the role started again listens.
    wait_healthy(stack.base)
    if victim != "backends":
        again = c.mcp(OWNER, "scratch", key="steady").call("whoami", {})
        expect(again[0] == 200 and json.loads(again[1]["result"]["content"][0]["text"])["pid"]
               == json.loads(steady[1]["result"]["content"][0]["text"])["pid"],
               f"a program's session keeps running while the {victim} role starts again", [steady, again])
    return after


def serving(stack):
    """The stack up with all three roles: healthy by the image's probe, the backends role greeted and its owner
    synced. Answers the controller."""
    stack.up()
    stack.healthy()
    expect(imagesuite.read_output(stack.exec("locus-health && echo answered"), "the image's probe").strip() == "answered",
           "the image's probe answers for all three roles")
    c = stack.controller()
    expect(c.hello()[0] == 200, "the backends role is greeted")
    status, answer, _ = c.sync(OWNER, [probe("scratch"), probe(home="kept")])
    expect(status == 200, "an owner of a pooled and a kept program is synced", answer)
    return c


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: roles.py IMAGE")
    require_docker()
    plane = plane_module.ControlPlane(secrets.token_bytes(32), SERVICE_ID).serve()
    stack = RolesStack("locus-roles", sys.argv[1], plane)
    try:
        c = serving(stack)
        ran = sh(c, OWNER, "echo answered", program="scratch")
        expect(ran["stdout"] == "answered\n", "a program of the backends role answers", ran)
        pids = stack.role_pids()
        expect(sorted(pids) == sorted(ROLES), "one process runs for each role", pids)
        test_apart(stack, pids)
        test_run(stack, plane)
        test_reach(stack, c)
        test_bounds(stack, pids)
        for victim in ("builds", "runtime", "backends"):
            test_restart_alone(stack, c, victim)
        run("docker", "restart", stack.container)
        stack.published()
        stack.healthy()
        expect(sorted(stack.role_pids()) == sorted(ROLES), "the container started again runs every role",
               stack.role_pids())
    finally:
        stack.down()
        plane.stop()


if __name__ == "__main__":
    main()
