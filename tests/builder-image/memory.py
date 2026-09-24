#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A build cannot take more memory than its bound, run as docker-compose.yml's builder service.

cyfr-keeper bounds a spawn that asks for `memory_bytes` with a cgroup of its
own (apps/keeper/internal/cgroup): the kernel never lets the spawn's whole
process tree, the tmpfs pages of its home and the kernel memory charged to
it pass the bound, kills every process of the spawn when they cannot stay
under it, and cyfr-keeper reports that end as `memory_exceeded`. It can do
so only where the service mounts the container's cgroup writable
(`security_opt: writable-cgroups=true`); anywhere else it refuses a spawn
that asks for a bound.

`keeper` drives a second cyfr-keeper inside the running service, over its
own uids, with a client that speaks the spawner's protocol
(tests/fixtures/keeper_protocol.json):

- a bound that is zero, not a number or above the maximum is refused, and a
  command runs under the least bound the protocol allows;
- beside a sibling spawn that holds 64 MiB under its bound and completes,
  three hostile spawns end at theirs, reported `memory_exceeded` with
  SIGKILL: one process allocating without end, with a daemon in a session
  of its own that ignores SIGTERM; 48 processes of 16 MiB, none of them
  large; and one filling its home, which no process holds;
- no group's peak, as the kernel accounts it, passed its bound; no process
  of their uids, no home and no group is left; the release and the
  container were not touched;
- where the service gives cyfr-keeper no writable cgroup, every spawn that
  asks for a bound is refused as `memory_unavailable` while one that asks
  for none runs, and this suite fails, naming the option the service lacks.

The build cases run the same hostile work through the builder's own build
path, each beside a sibling build: `javascript` (a build script allocating
without end), `rust` (a build.rs doing so), `tree` (100 processes of
64 MiB) and `home` (files until the home is full). Each must be answered
with the build wire's `memory` class (`Prima.BuilderProtocol`), leave no
process of its uid and no home, and leave its sibling, the release and the
container as they were. The builder asks cyfr-keeper for a bound for every
build (`Locus.Keeper`, LOCUS_BUILDS_MEMORY_BYTES); a build ended by the
container's own limit or the deadline instead fails its case here.

Every case prints what it measured: the peak of the hostile tree (the
resident sets of its uid's processes, sampled from /proc about ten times a
second, and its group's memory.peak where it has one), what ended it and
when, what it left, the sibling's end, and the container's memory before,
at its peak and after, its OOM counters and whether the release or the
container was started again. `--measure` prints without judging a build's
end, to see what a build without a bound does. The hostile work is bounded
by the container's own memory limit, which the suite reads from the
container and refuses to run without.

Usage: tests/builder-image/memory.py IMAGE [--measure] [keeper|javascript|rust|tree|home]...
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stack import HOME_ROOT, POOL_FIRST, POOL_LAST, RELEASE_UID, Stack, expect, run, tincture  # noqa: E402

MIB = 1 << 20
# A build nothing else ends is ended by this deadline.
DEADLINE_MS = 60_000
# The second cyfr-keeper's uids, one for each spawn of its scenario that
# runs: the last of the image's pool, which the service's own spawner is
# started without.
PROBE_FIRST, PROBE_LAST = POOL_LAST - 5, POOL_LAST
# The bound the keeper cases ask for.
BOUND = 256 * MIB
# The least and the most the spawner's protocol lets a bound be.
MIN_BOUND, MAX_BOUND = 16 * MIB, 1 << 40

# One line per sample: `uid:rss_kb:processes,...|memory.current|shmem|uid:memory.peak,...`.
SAMPLER = r"""
while :; do
  cat /proc/[0-9]*/status 2>/dev/null | awk -v first=%d -v last=%d '
    /^Name:/ { uid = -1 }
    /^Uid:/ { uid = $2; if (uid >= first && uid <= last) n[uid]++ }
    /^VmRSS:/ { if (uid >= first && uid <= last) rss[uid] += $2 }
    END { for (u in n) printf "%%s:%%d:%%d,", u, rss[u], n[u] }'
  groups=""
  for d in /sys/fs/cgroup/keeper-*; do
    peak="$(cat "$d/memory.peak" 2>/dev/null)" && groups="$groups${d##*keeper-}:$peak,"
  done
  printf '|%%s|%%s|%%s\n' "$(cat /sys/fs/cgroup/memory.current)" "$(awk '$1 == "shmem" {print $2}' /sys/fs/cgroup/memory.stat)" "$groups"
  sleep 0.1
done
""" % (POOL_FIRST, POOL_LAST)

# Touches every page it allocates, outside V8's heap, until something stops it.
NODE_ALLOCATOR = "const held = []; for (;;) held.push(Buffer.alloc(16 << 20, 1));"
DAEMON = "setsid sh -c \"trap '' TERM; exec sleep 1000\" </dev/null >/dev/null 2>&1 &\n"
FILL_HOME = 'i=0; while head -c 50000000 /dev/zero > "$HOME/fill-$i"; do i=$((i + 1)); done\nsleep 120\n'

# Holds the MiB it is told to and waits: one thread, so the tree case can
# fork nearly as many as a build may have tasks.
HOLDER_C = """
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    size_t bytes = (size_t)atol(argv[1]) << 20;
    char *held = malloc(bytes);
    if (held == NULL) return 3;
    memset(held, 1, bytes);
    sleep(600);
    return held[5];
}
"""

SIBLING = tincture(
    "node -e \"const held = Buffer.alloc(64 << 20, 1); setTimeout(() => {"
    " require('fs').mkdirSync('dist', {recursive: true});"
    " require('fs').writeFileSync('dist/index.html', 'sibling ' + held[5]); }, 20000)\"\n"
)

HOSTILE_BUILD_RS = """
fn main() {
    let mut held: Vec<Vec<u8>> = Vec::new();
    loop {
        held.push(vec![1u8; 16 << 20]);
    }
}
"""

LIB_RS = """#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::reagent::compute::Guest;

struct Hostile;
bindings::export!(Hostile with_types_in bindings);

impl Guest for Hostile {
    fn compute(input: String) -> String {
        input
    }
}
"""

# The keeper cases' client: cyfr-keeper starts it as the release's user with
# the channel on fd 3. It sends every spawn of the scenario, attaches their
# relays, and prints what the spawner answered for each.
CLIENT = r"""
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import crypto from "node:crypto";

const scenario = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const dir = fs.mkdtempSync(path.join(process.env.RELEASE_TMP, "memory-"));
const attach = path.join(dir, "attach.sock");
const spawns = scenario.spawns.map((s, i) => ({
  ...s, id: String(i + 1), token: crypto.randomBytes(32).toString("hex"), stdout: "", replies: [], done: false,
}));
const started = Date.now();

function finish(timedOut) {
  const report = spawns.map(({ name, uid, replies, stdout, done }) => ({ name, uid, replies, stdout: stdout.slice(-400), done }));
  process.stdout.write("<<<" + JSON.stringify({ timed_out: timedOut, spawns: report }) + ">>>\n", () => {
    fs.rmSync(dir, { recursive: true, force: true });
    process.exit(timedOut ? 1 : 0);
  });
}

function settle(spawn, reply) {
  spawn.replies.push({ ...reply, at_ms: Date.now() - started });
  if (reply.type === "spawned") { spawn.uid = reply.uid; spawn.spawn_id = reply.spawn_id; }
  if (reply.type === "released" || (reply.type === "error" && reply.id)) spawn.done = true;
  if (spawns.every((s) => s.done)) finish(false);
}

const server = net.createServer((conn) => {
  let buffer = Buffer.alloc(0);
  let spawn = null;
  conn.on("error", () => {});
  conn.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 5 && buffer.length >= 5 + buffer.readUInt32BE(1)) {
      const stream = buffer[0];
      const payload = buffer.subarray(5, 5 + buffer.readUInt32BE(1));
      buffer = buffer.subarray(5 + payload.length);
      if (stream === 3) {
        spawn = spawns.find((s) => s.token === payload.toString("latin1"));
        if (!spawn) return conn.destroy();
        conn.write(Buffer.from([0, 0, 0, 0, 0]));
      } else if (stream === 1 && spawn) {
        spawn.stdout += payload.toString("utf8");
      }
    }
  });
});

server.listen(attach, () => {
  const channel = new net.Socket({ fd: 3, readable: true, writable: true });
  let lines = "";
  channel.on("data", (chunk) => {
    lines += chunk.toString("utf8");
    for (let at = lines.indexOf("\n"); at >= 0; at = lines.indexOf("\n")) {
      const reply = JSON.parse(lines.slice(0, at));
      lines = lines.slice(at + 1);
      // A request whose fields do not decode is refused without its id: the
      // scenario holds one such request, the bound that is not a number.
      const unnamed = reply.type === "error" && !reply.id && !reply.spawn_id;
      const spawn = unnamed
        ? spawns.find((s) => !s.done && "memory_bytes" in s && typeof s.memory_bytes !== "number")
        : spawns.find((s) => s.id === reply.id || (reply.spawn_id && s.spawn_id === reply.spawn_id));
      if (spawn) settle(spawn, unnamed ? { ...reply, id: spawn.id } : reply);
    }
  });
  for (const s of spawns) {
    const request = { v: 1, type: "spawn", id: s.id, pool: scenario.pool, argv: s.argv, env: {}, attach: { path: attach, token: s.token } };
    if ("memory_bytes" in s) request.memory_bytes = s.memory_bytes;
    channel.write(JSON.stringify(request) + "\n");
  }
});

setTimeout(() => finish(true), scenario.timeout_ms);
"""


def shell(script):
    return ["/bin/sh", "-c", script]


def scenario():
    holders = "for i in $(seq 1 48); do perl -e '$held = \"x\" x (16 << 20); sleep 120' & done\nwait\n"
    sibling = "const held = Buffer.alloc(64 << 20, 1); setTimeout(() => console.log('held ' + held[5]), 8000);"
    return [
        {"name": "a bound of zero", "argv": ["true"], "memory_bytes": 0},
        {"name": "a bound that is not a number", "argv": ["true"], "memory_bytes": "1G"},
        {"name": "a bound above the maximum", "argv": ["true"], "memory_bytes": MAX_BOUND + 1},
        {"name": "no bound", "argv": ["true"]},
        {"name": "the least bound", "argv": shell("echo ran"), "memory_bytes": MIN_BOUND},
        {"name": "sibling", "argv": ["node", "-e", sibling], "memory_bytes": BOUND},
        {"name": "process", "argv": shell(DAEMON + f"exec node -e '{NODE_ALLOCATOR}'"), "memory_bytes": BOUND},
        {"name": "tree", "argv": shell(holders), "memory_bytes": BOUND},
        {"name": "home", "argv": shell(FILL_HOME), "memory_bytes": BOUND},
    ]


def hostile_sources(case):
    if case == "javascript":
        return tincture(DAEMON + f"node -e '{NODE_ALLOCATOR}'\n"), "javascript", "tincture"
    if case == "rust":
        # The builder writes the manifest of a build that brings none, and
        # cargo runs a build.rs it finds beside it.
        return {"src/lib.rs": LIB_RS, "build.rs": HOSTILE_BUILD_RS}, "rust", "reagent"
    if case == "tree":
        # 100 processes of 64 MiB: no one of them is large, the tree is 6.25 GiB.
        script = "cc -O1 -o hold hold.c\nfor i in $(seq 1 100); do ./hold 64 & done\nwait\n"
        return tincture(script, {"hold.c": HOLDER_C}), "javascript", "tincture"
    if case == "home":
        return tincture(FILL_HOME), "javascript", "tincture"
    sys.exit(f"unknown case {case}\n{__doc__}")


class Sampler(threading.Thread):
    """Reads the in-container sampler's lines, stamping each on arrival."""

    def __init__(self, container):
        super().__init__(daemon=True)
        self.process = subprocess.Popen(
            ["docker", "exec", container, "sh", "-c", SAMPLER], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.samples = []
        self.group_peaks = {}

    def run(self):
        for line in self.process.stdout:
            try:
                uids, current, shmem, groups = line.strip().split("|")
                tree = {}
                for entry in filter(None, uids.split(",")):
                    uid, rss_kb, count = entry.split(":")
                    tree[int(uid)] = (int(rss_kb) * 1024, int(count))
                for entry in filter(None, groups.split(",")):
                    uid, peak = entry.split(":")
                    self.group_peaks[int(uid)] = max(self.group_peaks.get(int(uid), 0), int(peak))
                self.samples.append((time.monotonic(), tree, int(current), int(shmem or 0)))
            except ValueError:
                continue

    def stop(self):
        self.process.kill()
        self.process.wait()

    def container_peak(self):
        return max((current for _, _, current, _ in self.samples), default=0)

    def shmem_peak(self):
        return max((shmem for _, _, _, shmem in self.samples), default=0)

    def tree_peak(self, uid):
        """The uid's largest sampled resident set, its process count then, and when."""
        best = (0, 0, None)
        for at, tree, _, _ in self.samples:
            if uid in tree and tree[uid][0] > best[0]:
                best = (tree[uid][0], tree[uid][1], at)
        return best


def container_state(stack):
    """The container as Docker and its own cgroup report it; a container that is down reports what it can.

    A container started again gives its init and its release the pids they
    had, and Docker's own start time can lag the restart, so each is named by
    its pid and the kernel's start time for it (field 22 of /proc/<pid>/stat).
    """
    inspect = json.loads(run("docker", "inspect", stack.container).stdout)[0]
    events = {}
    for line in stack.exec("cat /sys/fs/cgroup/memory.events").stdout.splitlines():
        name, count = line.split()
        events[name] = int(count)
    pids = [1] + [p["pid"] for p in stack.processes() if "beam.smp" in p["cmd"]]
    started = stack.exec(" ".join(f"echo {pid}:$(cut -d' ' -f22 /proc/{pid}/stat 2>/dev/null);" for pid in pids)).stdout.split()
    return {
        "oom_killed": inspect["State"]["OOMKilled"],
        "init": started[:1],
        "events": events,
        "release": started[1:],
        "current": int(stack.exec("cat /sys/fs/cgroup/memory.current").stdout.strip() or 0),
    }


def mib(count):
    return f"{count / MIB:.0f} MiB"


def brief(answer):
    """A build's answer without its files, its error cut to its end."""
    if not isinstance(answer, dict):
        return str(answer)[:900]
    answer = {key: value for key, value in answer.items() if key not in ("output_files", "outputs", "wasm_base64", "logs", "diagnostics")}
    if isinstance(answer.get("error"), str):
        answer["error"] = answer["error"][-500:]
    return json.dumps(answer)[:900]


def print_container(limit, before, after, sampler):
    again = after["init"] != before["init"]
    delta = {name: count - (0 if again else before["events"].get(name, 0)) for name, count in after["events"].items()}
    print(f"container: limit {mib(limit)}; {mib(before['current'])} before, {mib(sampler.container_peak())} at its peak "
          f"({mib(sampler.shmem_peak())} of it tmpfs), {mib(after['current'])} after")
    print(f"container: cgroup events {delta}{' since it started again' if again else ''}; Docker's OOMKilled flag "
          f"{after['oom_killed']}; container started again {again}; release (pid:start) {before['release']} -> {after['release']}")
    return again


def own_limit_writable(stack):
    """Whether uid 0 in the container can rewrite the container's own limit, by writing its value back."""
    result = stack.exec('v="$(cat /sys/fs/cgroup/memory.max)" && echo "$v" > /sys/fs/cgroup/memory.max')
    if result.returncode == 0:
        return ("writable from inside: this host mounts cgroup2 without nsdelegate, so uid 0 in the container "
                "(cyfr-keeper and the container's init, nothing else) can rewrite the container's own limits")
    return "not writable from inside: " + (result.stderr.strip().rsplit(": ", 1)[-1] or "refused")


def test_keeper(stack, limit, canary):
    user = stack.exec(f"getent passwd {RELEASE_UID} | cut -d: -f1").stdout.strip()
    expect(user, "the release's user has a name cyfr-keeper can start a client under", user)
    with open(os.path.join(canary, "memory-client.mjs"), "w") as out:
        out.write(CLIENT)
    with open(os.path.join(canary, "memory-scenario.json"), "w") as out:
        json.dump({"pool": "probe", "timeout_ms": 90_000, "spawns": scenario()}, out)
    os.chmod(canary, 0o755)

    before = container_state(stack)
    sampler = Sampler(stack.container)
    sampler.start()
    result = stack.exec(
        f"exec cyfr-keeper serve --pool probe:{PROBE_FIRST}-{PROBE_LAST} --home-root {HOME_ROOT} --client-user {user} "
        "-- node /canary/memory-client.mjs /canary/memory-scenario.json")
    time.sleep(1)
    sampler.stop()
    expect("<<<" in result.stdout, "the second cyfr-keeper ran the scenario's client", result.stdout + result.stderr)
    report = json.loads(result.stdout.split("<<<", 1)[1].rsplit(">>>", 1)[0])
    spawns = {spawn["name"]: spawn for spawn in report["spawns"]}
    after = container_state(stack)

    def reply(name, kind):
        return next((r for r in spawns[name]["replies"] if r["type"] == kind), None)

    print("--- keeper")
    print(f"the container's own memory.max is {own_limit_writable(stack)}")
    again = print_container(limit, before, after, sampler)
    for name, spawn in spawns.items():
        uid = spawn.get("uid")
        exited, error = reply(name, "exited"), reply(name, "error")
        resident, processes, _ = sampler.tree_peak(uid)
        end = (f"exited {({k: exited[k] for k in ('code', 'signal', 'memory_exceeded')})} {exited['at_ms'] / 1000:.1f} s in"
               if exited else f"refused as {error['code']}" if error else "no answer")
        peak = sampler.group_peaks.get(uid)
        measured = f"; uid {uid}, group peak {mib(peak) if peak else 'unseen'}, {mib(resident)} resident over {processes} processes" if uid else ""
        print(f"{name}: {end}{measured}")
    for line in result.stderr.splitlines():
        if "memory" in line:
            print("  spawner: " + line.split("] ", 1)[-1][:300])

    expect(not report["timed_out"], "every spawn of the scenario was answered and released", report)
    for name in ("a bound of zero", "a bound that is not a number", "a bound above the maximum"):
        expect(reply(name, "error") and reply(name, "error")["code"] == "bad_request" and not reply(name, "spawned"),
               f"{name} is refused as a bad request", spawns[name])
    unbounded = reply("no bound", "exited")
    expect(unbounded and unbounded["code"] == 0 and unbounded["memory_exceeded"] is False,
           "a spawn asking for no bound runs", spawns["no bound"])

    bounded = ("the least bound", "sibling", "process", "tree", "home")
    refused = [name for name in bounded if reply(name, "error")]
    if refused:
        expect(all(reply(name, "error")["code"] == "memory_unavailable" and not reply(name, "spawned") for name in bounded),
               "where it cannot enforce a bound, cyfr-keeper refuses every spawn that asks for one", spawns)
        sys.exit("FAIL: the service gives cyfr-keeper no writable cgroup, so no build can be bounded: "
                 "the service needs `security_opt: writable-cgroups=true` (Docker Engine 28 or later)\n" + result.stderr[-1500:])

    least = reply("the least bound", "exited")
    expect(least and least["code"] == 0 and least["memory_exceeded"] is False and "ran" in spawns["the least bound"]["stdout"],
           f"a command runs under the least bound the protocol allows, {mib(MIN_BOUND)}", spawns["the least bound"])
    sibling = reply("sibling", "exited")
    expect(sibling and sibling["code"] == 0 and sibling["memory_exceeded"] is False and "held 1" in spawns["sibling"]["stdout"],
           "a sibling spawn holding 64 MiB under its bound completes", spawns["sibling"])
    for name in ("process", "tree", "home"):
        exited = reply(name, "exited")
        expect(exited and exited["signal"] == "SIGKILL" and exited["code"] is None and exited["memory_exceeded"] is True,
               f"the hostile {name} is ended at its bound and reported so", spawns[name])
        expect(reply(name, "released"), f"the hostile {name}'s uid is reported retired", spawns[name])
    # A hostile group lives for less than a second, so the sampler may miss
    # its last pages; that it reached its bound is the kernel's own count,
    # which `memory_exceeded` reports. What was sampled never passed it.
    asked = {spawn["name"]: spawn.get("memory_bytes") for spawn in scenario()}
    seen = {name: sampler.group_peaks.get(spawns[name]["uid"]) for name in bounded}
    expect(seen["sibling"] and all(peak is None or peak <= asked[name] for name, peak in seen.items()),
           "no group's peak, as the kernel accounts it, passed the bound its spawn asked for", {"asked": asked, "seen": seen})

    left = stack.pool_processes()
    expect(left == [], "no process of any spawn's uid is left, the daemon included", left)
    expect(stack.homes() == [], "no home is left", stack.homes())
    groups = stack.exec("ls -d /sys/fs/cgroup/keeper-* 2>/dev/null").stdout.split()
    expect(groups == [], "no spawn's cgroup is left", groups)
    expect(not again and after["release"] == before["release"] and after["release"],
           "the release and the container were not touched", {"before": before, "after": after})


def test_build(stack, case, limit, measure):
    sources, language, target_type = hostile_sources(case)
    before = container_state(stack)
    sampler = Sampler(stack.container)
    sampler.start()
    results = {}

    def build(name, *args):
        started = time.monotonic()
        try:
            status, answer = stack.build(*args)
        except OSError as error:
            status, answer = None, f"the builder gave no answer: {error!r}"
        results[name] = (status, answer, started, time.monotonic())

    sibling = threading.Thread(target=build, args=("sibling", SIBLING, "javascript", "tincture"))
    sibling.start()
    time.sleep(3)
    sibling_uids = {uid for _, tree, _, _ in sampler.samples for uid in tree}
    hostile = threading.Thread(target=build, args=("hostile", sources, language, target_type))
    hostile.start()
    hostile.join()
    survivors = stack.pool_processes()
    homes = stack.homes()
    sibling.join()
    time.sleep(1)
    sampler.stop()
    after = container_state(stack)

    status, answer, started, ended = results["hostile"]
    sibling_status, sibling_answer, _, _ = results["sibling"]
    # The hostile build's uid is the one the sibling did not run under.
    uids = {uid for _, tree, _, _ in sampler.samples for uid in tree} - sibling_uids
    uid = max(uids, key=lambda candidate: sampler.tree_peak(candidate)[0], default=None)
    resident, processes, peak_at = sampler.tree_peak(uid)
    last_seen = max((at for at, tree, _, _ in sampler.samples if uid in tree), default=ended)
    group_peak = sampler.group_peaks.get(uid)
    left = [p for p in survivors if uid in p["uids"]]
    left_homes = [home for home in homes if home.startswith(f"{uid}-")]

    print(f"--- {case}")
    again = print_container(limit, before, after, sampler)
    print(f"hostile build: uid {uid}; its tree's peak {mib(resident)} resident over {processes} processes, "
          f"{(peak_at or ended) - started:.1f} s after it started; its group's peak "
          f"{mib(group_peak) if group_peak else 'none: it ran in no group of its own'}")
    print(f"ended by: HTTP {status} {brief(answer)}")
    print(f"ended {ended - started:.1f} s after it started, {ended - (peak_at or ended):.1f} s after the sample at its peak; "
          f"a process of its uid was last seen {last_seen - (peak_at or ended):.1f} s after that sample")
    print(f"when its answer arrived: processes of its uid {left}, homes of its uid {left_homes}")
    print(f"sibling: HTTP {sibling_status} {'completed' if sibling_status == 200 else brief(sibling_answer)}")
    if measure:
        return

    expect(isinstance(answer, dict) and answer.get("class") == "memory",
           f"{case}: the hostile build is answered with the memory class", {"status": status, "answer": brief(answer)})
    expect(left == [] and left_homes == [], f"{case}: no process of its uid and no home of its is left", [left, left_homes])
    expect(sibling_status == 200, f"{case}: the sibling build completes", brief(sibling_answer))
    expect(not again and after["release"] == before["release"] and after["release"],
           f"{case}: the release and the container were not touched", {"before": before, "after": after})


def main(image, measure, cases):
    canary = tempfile.mkdtemp(prefix="cyfr-builder-memory-")
    stack = Stack("cyfr-builder-memory", image, canary)
    try:
        for case in cases:
            # A fresh container per case, so one case's damage is not the next one's start.
            stack.up(pool=f"{POOL_FIRST}-{PROBE_FIRST - 1}", timeout_ms=DEADLINE_MS)
            limit = stack.exec("cat /sys/fs/cgroup/memory.max").stdout.strip()
            expect(limit.isdigit(), "the container has a memory limit of its own, which bounds the hostile work", limit)
            if case == "keeper":
                test_keeper(stack, int(limit), canary)
            else:
                test_build(stack, case, int(limit), measure)
    finally:
        stack.down()
        shutil.rmtree(canary, ignore_errors=True)


if __name__ == "__main__":
    arguments = [argument for argument in sys.argv[1:] if argument != "--measure"]
    if not arguments:
        sys.exit(__doc__)
    main(arguments[0], "--measure" in sys.argv, arguments[1:] or ["keeper", "javascript", "rust", "tree", "home"])
