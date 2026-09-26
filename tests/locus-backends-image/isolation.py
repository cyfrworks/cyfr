#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends image isolates its backends, run as docker-compose.yml's locus-backends service.

Driven only by requests signed as CYFR signs them (harness.py):

- cyfr-keeper holds exactly SETUID, SETGID and KILL and no inet socket; the
  release runs as locus with no capability; the root is read-only, and an
  unsigned control message or invoke is refused.
- Each backend runs under its own pooled uid, alone in its group, in a 0700
  home, with an environment of its sealed block and the keeper's own
  variables alone, under the keeper's resource limits; one owner's key
  reaches no other owner's backends.
- No backend can read another's home or /proc environ, or the release's
  (which holds LOCUS_BACKENDS_KEY), nor signal another backend, a relay,
  the release or cyfr-keeper.
- Releasing an owner retires every process of its uid, a detached daemon
  that ignores SIGTERM included, its relay and its home; a backend that
  exits is retired and restarts ready in a new home.
- The release refuses to start without a valid backends key; when it dies,
  cyfr-keeper retires every backend and exits 70; when cyfr-keeper is lost,
  the container ends with every backend in it; cyfr-keeper refuses Docker's
  default capabilities; and stopping the service retires every backend.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/isolation.py IMAGE
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    HOME_ROOT, KEEPER_CAPS, MCP_VERSION, POOL_FIRST, POOL_LAST, PROJECT_PREFIX, RELEASE_UID, RELEASE_USER,
    ROUTES, RUN_DIR, SERVICE, Controller, Stack, eventually, expect, owner_of, owner_key, pool_user, post, probe,
    require_docker, run, wait_healthy, wire_json,
)

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
    cyfr-keeper is not dumpable, so root inside the service cannot list its descriptors."""
    name = f"{stack.project}-inspect"
    run("docker", "rm", "--force", name, check=False)
    return run("docker", "run", "--rm", "--name", name, "--pid", f"container:{stack.container}",
               "--network", f"container:{stack.container}", "--cap-add", "SYS_PTRACE", "--entrypoint", "sh",
               image, "-c", script, check=False)


def keeper_and_release(stack, target=None):
    procs = stack.processes(target)
    keeper = next((p for p in procs if p["cmd"].startswith("cyfr-keeper serve")), None)
    release = next((p for p in procs if p["uids"] == [RELEASE_UID] * 4 and "beam.smp" in p["cmd"]), None)
    return keeper, release


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: isolation.py IMAGE")
    image = sys.argv[1]
    require_docker()
    stack = Stack("locus-backends-isolation", image)
    try:
        stack.up()
        c = stack.controller()
        expect(c.hello()[0] == 200 and c.reconcile([])[0] == 200, "the service is greeted and reconciled")

        # ————— the service's own privileges —————
        keeper, release = keeper_and_release(stack)
        expect(keeper and release, "cyfr-keeper and the locus release run", stack.processes())
        expect(keeper["uids"] == [0, 0, 0, 0] and keeper["cap_eff"] == KEEPER_CAPS and keeper["cap_prm"] == KEEPER_CAPS
               and keeper["cap_bnd"] == KEEPER_CAPS and keeper["no_new_privs"],
               "cyfr-keeper holds exactly SETUID, SETGID and KILL, with no_new_privs", keeper)
        expect(release["cap_eff"] == NO_CAPS and release["cap_prm"] == NO_CAPS and release["no_new_privs"],
               f"the release runs as {RELEASE_USER} with no capability", release)

        fds = inspect_pid(stack, image, f"ls -l /proc/{keeper['pid']}/fd")
        sockets = re.findall(r"socket:\[(\d+)\]", fds.stdout)
        expect(sockets, "cyfr-keeper holds its channel socket", fds.stdout + fds.stderr)
        inet = inspect_pid(stack, image, f"cat /proc/{keeper['pid']}/net/tcp /proc/{keeper['pid']}/net/tcp6 "
                                         f"/proc/{keeper['pid']}/net/udp /proc/{keeper['pid']}/net/udp6 2>/dev/null").stdout
        unix = inspect_pid(stack, image, f"cat /proc/{keeper['pid']}/net/unix").stdout
        for inode in sockets:
            expect(not re.search(rf"\b{inode}\b", inet) and re.search(rf"\b{inode}\b", unix),
                   f"cyfr-keeper's socket {inode} is a unix socket, not an inet one")

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
        relays = [p for p in stack.processes() if p["cmd"].startswith("cyfr-keeper relay")]
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
        expect(c.tool(ALPHA, "probe__whoami")["pid"] == alpha["pid"] and c.tool(BETA, "probe__whoami")["pid"] == beta["pid"],
               "both backends survived each other's attempts")

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
        eventually(lambda: len([p for p in stack.processes() if p["cmd"].startswith("cyfr-keeper relay")]) == 1,
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

        lost = f"{stack.project}-lost"
        run("docker", "rm", "--force", lost, check=False)
        stack.compose("run", "--detach", "--name", lost, "--no-deps", "--service-ports", SERVICE)
        try:
            base = "http://" + run("docker", "port", lost, "4101").stdout.strip().splitlines()[0]
            wait_healthy(base)
            orphan = Controller(base, stack.key)
            expect(orphan.hello()[0] == 200, "a second service is greeted")
            sync_probe(orphan, owner_of("orphan"))
            daemon = orphan.tool(owner_of("orphan"), "probe__spawn_daemon")["pid"]
            eventually(lambda: any(p["pid"] == daemon for p in stack.processes(lost)), "the orphan's daemon to start")
            _keeper, lost_release = keeper_and_release(stack, lost)
            run("docker", "exec", lost, "sh", "-c", f"kill -KILL {lost_release['pid']}")
            expect(run("docker", "wait", lost).stdout.strip() == "70", "cyfr-keeper exits 70 when the release dies")
            logs = run("docker", "logs", lost, check=False)
            text = logs.stdout + logs.stderr
            expect("client channel lost; every spawn retired" in text and "quarantined" not in text
                   and "did not finish" not in text, "every backend was retired cleanly", text[-3000:])
        finally:
            run("docker", "rm", "--force", lost, check=False)

        stack.compose("run", "--detach", "--name", lost, "--no-deps", SERVICE)
        try:
            eventually(lambda: keeper_and_release(stack, lost)[1], "the third service's release to start", timeout_s=60)
            lost_keeper, _ = keeper_and_release(stack, lost)
            run("docker", "exec", lost, "sh", "-c", f"kill -KILL {lost_keeper['pid']}")
            code = run("docker", "wait", lost).stdout.strip()
            expect(code != "0", "losing cyfr-keeper ends the container, and every backend in it", code)
        finally:
            run("docker", "rm", "--force", lost, check=False)

        defaults = run("docker", "run", "--rm", "--name", f"{PROJECT_PREFIX}{stack.project}-defaults",
                       "-e", f"LOCUS_BACKENDS_KEY={stack.key.hex()}", "--entrypoint", "cyfr-keeper", image,
                       "serve", "--pool", f"backends:{POOL_FIRST}-{POOL_LAST}", "--home-root", HOME_ROOT,
                       "--client-user", RELEASE_USER, "--", "/app/bin/locus", "start", check=False)
        expect(defaults.returncode == 78 and "refusing to start: Cap" in defaults.stderr,
               "cyfr-keeper refuses Docker's default capabilities", defaults.stderr[-2000:])

        last = owner_of("last")
        sync_probe(c, last)
        who = c.tool(last, "probe__whoami")
        c.tool(last, "probe__spawn_daemon")
        stack.compose("stop", SERVICE)
        code = run("docker", "inspect", "--format", "{{.State.ExitCode}}", stack.container).stdout.strip()
        text = stack.logs()
        expect(code == "0" and "[cyfr-keeper] info: stopped" in text and "quarantined" not in text
               and "did not finish" not in text,
               f"stopping the service retires every backend, uid {who['uid']} included, and cyfr-keeper exits 0",
               text[-3000:])
        expect(ALPHA_SECRET not in text, "a backend's credential never reaches the service's log")
    finally:
        stack.down()


if __name__ == "__main__":
    main()
