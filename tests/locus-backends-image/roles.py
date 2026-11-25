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
- Each role's group holds the bounds of its container of before: runtime
  4G of memory and as much swap, 4 processors; builds 4G and 2; backends 2G
  and no processor bound.
- A role killed starts again alone: the other two keep their processes and
  a program's session keeps running.
- A kept home a three-container image made (OLD_IMAGE, the backends service
  of before, on the same `homes` volume) opens under the new image with its
  file under its own uid, is listed and is reset under that uid; after the
  backends role restarts, and after the container restarts, it opens so
  again, and a new home never draws its uid.

A request on a role's channel naming another role's pool, spawn, place or
home is refused by the keeper itself, and a role's environment holds its
own variables alone, as the keeper's tests prove
(apps/locus/keeper/internal/serve/roles_linux_test.go,
TestARoleNamesOnlyItsOwn, and config_test.go,
TestRoleEnvironHoldsTheRolesOwnAndNothingOfAnothers): no client of this
suite holds a role's channel, and a role's environment is not readable
from outside its space.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/roles.py IMAGE OLD_IMAGE
"""

import importlib.util
import json
import os
import secrets
import shutil
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from harness import (  # noqa: E402
    GUARD, KEPT_FIRST, KEPT_LAST, KEPT_ROOT, POOL_FIRST, POOL_LAST, RELEASE, ROOT, VERSION, Controller, Stack, eventually,
    expect,
    owner_of, probe, require_docker, run, wait_healthy,
)
import imagesuite  # noqa: E402
from kept_home import sh, whoami  # noqa: E402

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
HOME = "mcp_roles-kept"
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


def old_home(stack, old_image, old_root):
    """A kept home the three-container image makes: its backends service on the project's `homes` volume, a probe
    program writing a file in its home. Answers the home's uid; the project is then taken down, the volume kept."""
    old = [os.path.join(old_root, "docker-compose.yml"),
           os.path.join(old_root, "tests", "locus-backends-image", "compose.locus-backends.yml")]
    env = stack.env(BACKENDS_IMAGE=old_image, PROBE_DIR=os.path.join(old_root, "tests", "locus-backends-image"))
    # The backends role as the three-container stack names it, from that stack's own role table.
    with open(os.path.join(old_root, "tests", "fixtures", "locus_roles.json"), encoding="utf-8") as table:
        then = next(role for role in json.load(table)["roles"] if role["name"] == "backends")

    def compose(*args, check=True):
        return run("docker", "compose", "--project-name", stack.project, "--project-directory", stack.project_dir,
                   *[arg for file in old for arg in ("-f", file)], *args, env=env, check=check)

    try:
        compose("up", "--detach", "--no-build", "--force-recreate", then["service"])
        guard = compose("ps", "--quiet", then["guard"]).stdout.strip()
        address = run("docker", "port", guard, str(then["port"])).stdout.strip().splitlines()[0]
        base = f"http://{address}"
        wait_healthy(base)
        c = Controller(base, stack.key)
        expect(c.hello()[0] == 200, "the three-container image's backends service is greeted")
        status, answer, _ = c.sync(OWNER, [probe(home="kept")])
        expect(status == 200, "under the three-container image an owner of a kept program is synced", answer)
        made = whoami(c, OWNER, home_id=HOME)
        sh(c, OWNER, 'echo made-before > "$HOME/before.txt"', home_id=HOME)
        expect(KEPT_FIRST <= made["uid"] <= KEPT_LAST and made["home"] == f"{KEPT_ROOT}/{HOME}",
               "the three-container image makes a kept home with a file, under a kept uid", made)
        c.close(OWNER, c.mcp(OWNER, "probe", home_id=HOME).session)
        return made["uid"]
    finally:
        compose("down", "--remove-orphans", check=False)


def opens_as_before(c, uid, what):
    seen = whoami(c, OWNER, home_id=HOME)
    read = sh(c, OWNER, 'cat "$HOME/before.txt"; stat -c %u "$HOME/before.txt"', home_id=HOME)
    expect(seen["uid"] == uid and seen["home"] == f"{KEPT_ROOT}/{HOME}" and read["stdout"] == f"made-before\n{uid}\n",
           f"{what}: the home the three-container image made opens with its file under its own uid {uid}",
           [seen, read])
    c.close(OWNER, c.mcp(OWNER, "probe", home_id=HOME).session)


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


def test_bounds(stack):
    for name, (memory, swap, cpu) in BOUNDS.items():
        group = f"/sys/fs/cgroup/role-{name}"
        got = imagesuite.read_output(
            stack.exec(f"cat {group}/memory.max {group}/memory.swap.max {group}/cpu.max"), f"{name}'s bounds").split("\n")
        expect(got[:3] == [memory, swap, cpu],
               f"the {name} role's group holds its container's bounds of before: memory {memory}, swap {swap}, cpu {cpu}",
               got)


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
    if victim != "backends":
        again = c.mcp(OWNER, "scratch", key="steady").call("whoami", {})
        expect(again[0] == 200 and json.loads(again[1]["result"]["content"][0]["text"])["pid"]
               == json.loads(steady[1]["result"]["content"][0]["text"])["pid"],
               f"a program's session keeps running while the {victim} role starts again", [steady, again])
    return after


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: roles.py IMAGE OLD_IMAGE")
    image, old_image = sys.argv[1:]
    require_docker()
    old_root = os.environ.get("OLD_TREE")
    expect(old_root and os.path.isfile(os.path.join(old_root, "tests", "locus-backends-image", "compose.locus-backends.yml")),
           "OLD_TREE names a checkout of the three-container stack", old_root)
    plane = plane_module.ControlPlane(secrets.token_bytes(32), SERVICE_ID).serve()
    stack = RolesStack("locus-roles", image, plane)
    shutil.copyfile(os.path.join(old_root, "apps", "locus", "keeper", "seccomp", "keeper.json"),
                    os.path.join(stack.project_dir, "keeper.seccomp.json"))
    try:
        uid = old_home(stack, old_image, old_root)
        shutil.copyfile(os.path.join(ROOT, "apps", "locus", "keeper", "seccomp", "keeper.json"),
                        os.path.join(stack.project_dir, "keeper.seccomp.json"))
        stack.up()
        stack.healthy()
        expect(imagesuite.read_output(stack.exec("locus-health && echo answered"), "the image's probe").strip() == "answered",
               "the image's probe answers for all three roles")
        c = stack.controller()
        expect(c.hello()[0] == 200, "the backends role is greeted")
        status, answer, _ = c.sync(OWNER, [probe("scratch"), probe(home="kept")])
        expect(status == 200, "an owner of a pooled and a kept program is synced", answer)
        ran = sh(c, OWNER, "echo answered", program="scratch")
        expect(ran["stdout"] == "answered\n", "a program of the backends role answers", ran)

        pids = stack.role_pids()
        expect(sorted(pids) == sorted(ROLES), "one process runs for each role", pids)
        test_apart(stack, pids)
        test_run(stack, plane)
        test_reach(stack, c)
        test_bounds(stack)

        # ————— the home of before —————
        opens_as_before(c, uid, "under the one container")
        status, listed, _ = c.control({"type": "homes"})
        expect(status == 200 and HOME in listed["homes"], "the home of before is listed", listed)
        status, reset, _ = c.home(OWNER["athanor"], HOME, "reset")
        expect((status, reset) == (200, {"version": VERSION, "home_id": HOME, "state": "empty"}),
               "the home of before is reset", reset)
        empty = whoami(c, OWNER, home_id=HOME)
        expect(empty["uid"] == uid, "after its reset the home opens under its own uid again", empty)
        sh(c, OWNER, 'echo made-before > "$HOME/before.txt"', home_id=HOME)
        c.close(OWNER, c.mcp(OWNER, "probe", home_id=HOME).session)

        # ————— a role killed starts again alone —————
        for victim in ("builds", "runtime", "backends"):
            test_restart_alone(stack, c, victim)
        c = stack.controller()
        expect(c.hello()[0] == 200, "the backends role started again is greeted")
        status, answer, _ = c.sync(OWNER, [probe("scratch"), probe(home="kept")])
        expect(status == 200, "the owner is synced again", answer)
        opens_as_before(c, uid, "after the backends role restarts")

        run("docker", "restart", stack.container)
        stack.published()
        stack.healthy()
        c = stack.controller()
        expect(c.hello()[0] == 200, "the container started again is greeted")
        status, answer, _ = c.sync(OWNER, [probe("scratch"), probe(home="kept")])
        expect(status == 200, "the owner is synced after the container restarts", answer)
        opens_as_before(c, uid, "after the container restarts")

        fresh = whoami(c, OWNER, home_id="mcp_roles-fresh")
        expect(KEPT_FIRST <= fresh["uid"] <= KEPT_LAST and fresh["uid"] != uid
               and not POOL_FIRST <= fresh["uid"] <= POOL_LAST,
               f"a new home draws a kept uid, never the home of before's {uid}", fresh)
    finally:
        stack.down()
        plane.stop()


if __name__ == "__main__":
    main()
