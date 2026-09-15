#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builder image isolates its builds, run as docker-compose.yml's builder service.

- cyfr-spawn holds exactly SETUID, SETGID and KILL; the release runs as
  cyfr-builder with no capability and no Erlang distribution listener; and
  the release refuses to serve builds when started without cyfr-spawn.
- A build runs under a pooled uid, alone in its group, in a 0700 home,
  with none of the release's environment; it cannot read the release's
  /proc environ (which holds CYFR_BUILDER_TOKEN) nor signal it.
- A build cannot list the home root nor read a concurrent build's tree,
  even knowing its path.
- No process of a build's uid survives the build — a daemon a build.rs
  starts in a session of its own, ignoring SIGTERM, included — and its
  home is gone when the response arrives.
- With a pool of one uid, what one build leaves outside its home (an entry
  in the home root, a directory tree it made unwritable, System V shared
  memory, semaphores and message queues, a POSIX message queue) is gone
  before the next build runs under the same uid; /tmp, /var/tmp, /dev/shm,
  /run and /run/cyfr-builder are not writable to it.

Usage: tests/builder-image/isolation.py IMAGE
"""

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
    HOME_ROOT, POOL_FIRST, POOL_LAST, RELEASE_UID, TOKEN, Stack, build_canary, expect, output_file, run, tincture,
)

SPAWNER_CAPS = "00000000000000e0"
TAG = "cyfr-builder-residue"
SHARED = [f"/tmp/{TAG}", f"/var/tmp/{TAG}", f"/dev/shm/{TAG}", f"/run/{TAG}", f"/run/cyfr-builder/{TAG}"]
LEFT = [f"{HOME_ROOT}/{TAG}", f"{HOME_ROOT}/{TAG}-tree/"]

PROBE = r"""
set -u
mkdir -p dist
{
  echo "uid=$(id -u)"
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


def fields(text):
    return dict(line.split("=", 1) for line in (text or "").splitlines() if "=" in line)


def test_process_model(stack, image):
    procs = stack.processes()
    spawner = [p for p in procs if p["cmd"].startswith("cyfr-spawn serve")]
    release = [p for p in procs if "beam.smp" in p["cmd"]]
    expect(len(spawner) == 1 and spawner[0]["uids"] == [0, 0, 0, 0] and spawner[0]["cap_eff"] == SPAWNER_CAPS,
           "cyfr-spawn runs as root holding exactly SETUID, SETGID and KILL", procs)
    expect(len(release) == 1 and release[0]["uids"] == [RELEASE_UID] * 4 and release[0]["cap_eff"] == "0000000000000000",
           "the release runs as cyfr-builder with no capability", procs)
    expect(not any("epmd" in p["cmd"] for p in procs) and "-sname" not in release[0]["cmd"] and " -name " not in release[0]["cmd"],
           "the release starts no Erlang distribution", release)
    # Docker's embedded DNS resolver listens on 127.0.0.11 (0B00007F) in every
    # container on a user-defined network.
    listening = stack.exec("cat /proc/net/tcp /proc/net/tcp6 | awk '$4 == \"0A\" {print $2}'").stdout.split()
    ports = sorted({int(address.rsplit(":", 1)[1], 16) for address in listening if not address.startswith("0B00007F:")})
    expect(ports == [4100], "besides Docker's resolver, the builder's only listening TCP port is 4100", listening)

    refused = run("docker", "run", "--rm", "-e", "CYFR_BUILDER_LISTEN=true", "-e", f"CYFR_BUILDER_TOKEN={TOKEN}",
                  "--entrypoint", "/app/bin/builder", image, "start", check=False, timeout=120)
    expect(refused.returncode != 0 and "runs builds only through cyfr-spawn" in refused.stdout + refused.stderr,
           "the release refuses to serve builds when started without cyfr-spawn", refused.stdout + refused.stderr)


def test_build_identity(stack):
    status, answer = stack.build(tincture(PROBE), "javascript", "tincture")
    expect(status == 200, "a probe build succeeds", answer)
    who = fields(output_file(answer, "who.txt"))
    uid = int(who["uid"])
    expect(POOL_FIRST <= uid <= POOL_LAST and who["gid"] == str(uid) and who["groups"] == str(uid),
           "a build runs under a pooled uid, alone in its group", who)
    expect(re.fullmatch(rf"{HOME_ROOT}/{uid}-[0-9a-f]{{32}}", who["home"]) and who["home_mode"] == "700"
           and who["tmpdir"] == who["home"] + "/tmp" and who["caps"] == "0000000000000000",
           "its home is a 0700 directory of its own, TMPDIR is inside it and it holds no capability", who)

    env = output_file(answer, "env.txt")
    expect(TOKEN not in env and not re.search(r"^(CYFR_|RELEASE_|ERL_|ELIXIR_)", env, re.M),
           "none of the release's environment reaches a build", env)

    release = output_file(answer, "release.txt") or ""
    expect(release.startswith("pid=") and TOKEN not in release
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
    expect(status == 200, "the intruding build succeeds", answer)
    probe = output_file(answer, "probe.txt") or ""
    found = fields(probe).get("found", "")
    expect(re.fullmatch(rf"{HOME_ROOT}/3\d{{4}}-[0-9a-f]{{32}}", found),
           "the intruding build found the concurrent build's home path", probe)
    expect("victim secret" not in probe and probe.count("Permission denied") >= 3
           and "ls_status=0" not in probe and "cat_status=0" not in probe and "root_status=0" not in probe,
           "it can neither list nor read the concurrent build's tree, nor list the home root", probe)
    expect(results["victim"][0] == 200, "the concurrent build completes undisturbed", results["victim"][1])


def test_no_survivors(stack):
    manifest_result = stack.exec(
        """/app/bin/builder eval 'IO.puts("<<<" <> Locus.Builder.cargo_toml_for(:reagent) <> ">>>")'""", user="cyfr-builder")
    manifest = manifest_result.stdout.split("<<<", 1)[1].split(">>>", 1)[0]
    status, answer = stack.build({"src/lib.rs": LIB_RS, "build.rs": DAEMON_BUILD_RS, "Cargo.toml": manifest}, "rust", "reagent")
    expect(status == 200, "a Rust build whose build.rs starts a daemon succeeds", answer)
    survivors = stack.pool_processes()
    expect(survivors == [], "no process of the build's uid survives the build, its daemon included", survivors)
    expect(stack.homes() == [], "the build's home is gone when its response arrives", stack.homes())


def test_residue(stack):
    stack.up(pool=f"{POOL_FIRST}-{POOL_FIRST}")
    paths = " ".join(SHARED + LEFT)

    status, answer = stack.build(tincture(f"mkdir -p dist && /canary/canary plant {TAG} {paths} > dist/plant.json"),
                                 "javascript", "tincture")
    expect(status == 200, "a build plants canaries", answer)
    planted = json.loads(output_file(answer, "plant.json"))
    expect(planted["uid"] == POOL_FIRST, "the first build runs under the pool's one uid", planted)
    expect(planted["files"] == {
        f"/tmp/{TAG}": "EROFS", f"/var/tmp/{TAG}": "EROFS", f"/dev/shm/{TAG}": "ENOENT", f"/run/{TAG}": "EROFS",
        f"/run/cyfr-builder/{TAG}": "EACCES", f"{HOME_ROOT}/{TAG}": "ok", f"{HOME_ROOT}/{TAG}-tree/": "ok",
    }, "outside its home a build can write only into the home root", planted)
    expect(all(planted[kind] == "ok" for kind in ("shm", "sem", "msg", "mqueue")),
           "a build can create System V IPC objects and a POSIX message queue", planted)

    status, answer = stack.build(tincture(f"mkdir -p dist && /canary/canary probe {TAG} {paths} > dist/probe.json"),
                                 "javascript", "tincture")
    expect(status == 200, "a second build probes for them", answer)
    probed = json.loads(output_file(answer, "probe.json"))
    expect(probed["uid"] == POOL_FIRST, "the second build runs under the same uid", probed)
    expect(probed["files"] == {
        f"/tmp/{TAG}": "absent", f"/var/tmp/{TAG}": "absent", f"/dev/shm/{TAG}": "absent", f"/run/{TAG}": "absent",
        f"/run/cyfr-builder/{TAG}": "denied", f"{HOME_ROOT}/{TAG}": "absent", f"{HOME_ROOT}/{TAG}-tree/": "absent",
    } and all(probed[kind] == "absent" for kind in ("shm", "sem", "msg", "mqueue")),
        "nothing the first build left reaches the second", probed)
    sysvipc = stack.exec("cat /proc/sysvipc/shm /proc/sysvipc/sem /proc/sysvipc/msg; ls -A /dev/mqueue").stdout
    expect(str(POOL_FIRST) not in sysvipc and TAG not in sysvipc, "the kernel holds no IPC object of the uid", sysvipc)
    logs = stack.logs()
    expect("quarantined" not in logs and "outlived retirement" not in logs, "every build uid was retired clean", logs)


def main(image):
    canary = build_canary()
    stack = Stack("cyfr-builder-isolation", image, canary)
    try:
        stack.up()
        test_process_model(stack, image)
        test_build_identity(stack)
        test_concurrent_trees(stack)
        test_no_survivors(stack)
        test_residue(stack)
    finally:
        stack.down()
        shutil.rmtree(canary, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
