#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A runner cannot take more memory than its bound, run as docker-compose.yml's opus service.

The service asks cyfr-spawn for a memory bound on every runner it spawns
(`Opus.Keeper.Spawn`, the pool's `:runner_memory_bytes`): cyfr-spawn gives
the runner a cgroup v2 group of its own at that bound, with no swap and the
group killed whole, charged for the runner's VM, every guest's linear
memory, the pages of its home and the kernel memory it causes, together. It
can do so only where the service mounts the container's cgroup writable
(`security_opt: writable-cgroups=true`); anywhere else it refuses a spawn
that asks for a bound, and the service starts no runner.

- `bound`: every runner runs in such a group. A guest that holds more than
  the bound (hog.wasm: ten linear memories of 64 MiB, each within the
  engine's own per-memory limit, every page touched) is ended with its
  runner by the kernel at the bound: the keeper reports the end at the
  bound (the service logs it), the guest neither completed nor trapped, the
  container's own limit was not reached, and the group never held more than
  the bound. The service reports the runner's exit holding the attempt; the
  runner is tainted and never assigned again; its uid holds no process, its
  home is scrubbed and its group is gone; the container's memory returns; a
  sibling runner busy meanwhile keeps its process and completes; the release
  is not touched; and when the uid is next given to a runner, that runner
  has a home and a group of its own, which the hostile one left nothing in.
- `unavailable`: under the shipped service without `writable-cgroups=true`,
  no runner process ever starts: every spawn is refused, the pool keeps none
  of the runners it was refused and backs off, its status reports the
  refusal naming the option beside the bound every runner would run under,
  a start is refused 503 `unavailable` naming it with nothing of the attempt
  run, and the service logs once what the deployment lacks and stays up on
  the same boot.

`--measure` runs the seed components through the scripted control plane,
each subtree in a fresh runner of a fresh container, and prints each
runner's group memory.peak as the kernel accounts it: a runner that booted
and ran nothing; each model catalyst's `chat` with a long thread and
an image (its egress denied, as the scripted plane's authority grants none);
the chat fixture's `chat` streaming a long answer; the http and files
catalysts; the list-models formula spawning its five catalyst children in
the same runner; and one runner of one athanor running all of them in turn.
It prints the service's own group peak and what 1.8 times the largest
runner peak comes to, the margin the build bound took over the seed builds.

Usage: tests/worker-image/memory.py IMAGE [--measure [ROUNDS]] [bound|unavailable]...
"""

import base64
import json
import os
import secrets
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from control_plane import ControlPlane  # noqa: E402
from stack import HERE, POOL_FIRST, POOL_LAST, ROOT, SERVICE, Stack, StatusSampler, expect, run, wait_until  # noqa: E402

MIB = 1 << 20
# A runner is a VM booting from nothing: its first attach takes seconds.
BOOT_S = 60
HOG = os.path.join(HERE, "hog.wasm")
HOG_REF = "reagent:local.hog:0.1.0"
# What hog.wasm holds once every page is touched: ten memories of 64 MiB.
HOG_BYTES = 10 * 64 * MIB
ECHO = os.path.join(ROOT, "apps", "opus", "test", "support", "test_wasm", "echo.wasm")
ECHO_REF = "reagent:local.echo:0.1.0"
SEED = os.path.join(ROOT, "seed", "components")
CHAT_FIXTURE = os.path.join(ROOT, "apps", "cyfr", "test", "support", "test_wasm", "chat_fixture", "chat_fixture.wasm")
CHAT_FIXTURE_REF = "catalyst:local.chat-fixture:0.1.0"
# The model ids each bundled catalyst's `chat` is asked for.
MODELS = {
    "claude": "claude-sonnet-4-6",
    "openai": "gpt-4.1",
    "gemini": "gemini-2.5-pro",
    "grok": "grok-4",
    "openrouter": "anthropic/claude-sonnet-4.6",
}
# The margin the build bound took over the largest seed build's peak (§13).
MARGIN = 1.8


def group(uid):
    return f"/sys/fs/cgroup/spawn-{uid}"


def read_group(stack, uid):
    """The group of the spawn running under `uid` as the kernel accounts it, or None when there is none."""
    out = stack.exec(
        f"g={group(uid)}; [ -d $g ] || exit 3; "
        "printf '%s|%s|%s|%s|%s|%s\\n' \"$(cat $g/memory.max)\" \"$(cat $g/memory.swap.max)\" "
        "\"$(cat $g/memory.oom.group)\" \"$(cat $g/memory.peak)\" \"$(cat $g/memory.current)\" "
        "\"$(tr '\\n' ' ' < $g/memory.events)\"")
    if out.returncode != 0 or out.stdout.count("|") != 5:
        return None
    limit, swap, oom_group, peak, current, events = out.stdout.strip().split("|")
    return {"max": limit, "swap_max": swap, "oom_group": oom_group, "peak": int(peak), "current": int(current),
            "events": dict(zip(events.split()[::2], map(int, events.split()[1::2])))}


def container_memory(stack):
    """The container's own cgroup: its limit, current use, and the events of its own limit alone."""
    out = stack.exec("cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.current; cat /sys/fs/cgroup/memory.events.local")
    lines = out.stdout.split("\n")
    events = dict((line.split()[0], int(line.split()[1])) for line in lines[2:] if len(line.split()) == 2)
    return {"max": lines[0].strip(), "current": int(lines[1]), "events_local": events}


def group_stat(stack, uid):
    """What the group holds now, by kind (memory.stat): anonymous pages, page cache, kernel memory, tmpfs."""
    out = stack.exec(f"cat {group(uid)}/memory.stat").stdout.split("\n")
    stat = dict((line.split()[0], int(line.split()[1])) for line in out if len(line.split()) == 2)
    return {kind: stat.get(kind, 0) for kind in ("anon", "file", "kernel", "shmem")}


def brief_stat(stat):
    return ", ".join(f"{kind} {mib(count)}" for kind, count in stat.items())


def keeper_group(stack):
    """The keeper's group (cyfr-spawn, the service and every spawn without a bound): its peak and current use."""
    out = stack.exec("cat /sys/fs/cgroup/keeper/memory.peak /sys/fs/cgroup/keeper/memory.current").stdout.split()
    return {"peak": int(out[0]), "current": int(out[1])} if len(out) == 2 else None


def oom_killed_flag(stack):
    """Docker's OOMKilled flag for the container, which it reads from the container's cgroup, descendants included."""
    return json.loads(run("docker", "inspect", "--format", "{{json .State.OOMKilled}}", stack.container).stdout)


def release_identity(stack):
    """The service's VM as its pid and the kernel's start time for it: a restarted release changes it."""
    pid = stack.service_beam_pid()
    started = stack.exec(f"cut -d' ' -f22 /proc/{pid}/stat").stdout.strip() if pid else None
    return (pid, started)


def mib(count):
    return f"{count / MIB:.0f} MiB" if count is not None else "none"


def wasm(path):
    with open(path, "rb") as f:
        return f.read()


class GroupSampler(threading.Thread):
    """Samples one uid's group and the container's memory from inside it, as fast as a shell reads a file.

    The loop forks nothing (`read` and `echo` are the shell's own), so it
    sees a group that fills its bound within a fraction of a second, and
    reads the group's own out-of-memory counters until the keeper removes
    it. It spins a CPU while it runs, and ending `docker exec` would not end
    it, so it names its own pid first and `stop` kills it in the
    container."""

    SCRIPT = r"""
      echo "pid $$"
      g=/sys/fs/cgroup/spawn-UID
      while :; do
        p=; c=; k=; o=; ok=
        { read -r p < $g/memory.peak; read -r c < $g/memory.current; } 2>/dev/null
        read -r k < /sys/fs/cgroup/memory.current
        { while read -r name value; do
            case $name in oom) o=$value ;; oom_kill) ok=$value ;; esac
          done < $g/memory.events; } 2>/dev/null
        echo "$p|$c|$k|oom $o oom_kill $ok"
      done"""

    def __init__(self, container, uid):
        super().__init__(daemon=True)
        self.container = container
        self.pid = None
        self.process = subprocess.Popen(
            ["docker", "exec", container, "sh", "-c", self.SCRIPT.replace("UID", str(uid))],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.samples = []

    def run(self):
        for line in self.process.stdout:
            if line.startswith("pid "):
                self.pid = int(line.split()[1])
                continue
            parts = line.rstrip("\n").split("|")
            if len(parts) != 4:
                continue
            peak, current, container, events = parts
            words = events.split()
            if len(words) != 4:
                words = []
            self.samples.append({
                "t": time.time(),
                "peak": int(peak) if peak else None,
                "current": int(current) if current else None,
                "container": int(container) if container else None,
                "events": dict(zip(words[::2], map(int, words[1::2]))),
            })

    def stop(self):
        if self.pid:
            # The image carries no kill binary: the shell's own does it.
            run("docker", "exec", self.container, "sh", "-c", f"kill {self.pid}", check=False)
        self.process.kill()
        self.process.wait()
        self.join(5)
        alive = f"[ -d /proc/{self.pid} ] && ! grep -q '^State:.*Z' /proc/{self.pid}/status && echo alive"
        wait_until(lambda: self.pid and "alive" not in run("docker", "exec", self.container, "sh", "-c", alive, check=False).stdout,
                   5, f"the sampler's loop (pid {self.pid}) to end in the container")

    def group_peak(self):
        return max((s["peak"] for s in self.samples if s["peak"] is not None), default=None)

    def container_peak(self):
        return max((s["container"] for s in self.samples if s["container"] is not None), default=None)

    def last_events(self):
        return next((s["events"] for s in reversed(self.samples) if s["events"]), {})


def attached_runner(stack, plane, attempt, timeout=BOOT_S):
    """The runner that attached the attempt: its id, OS pid, uid and home, once its process is found."""
    attach = plane.wait_seen("attach", attempt["execution_id"], timeout)[0]
    process = wait_until(lambda: stack.runner_process(attach["runner"]), 10, f"the process of runner {attach['runner']}")
    return {**process, "attach": attach}


def terminal(plane, execution_id, timeout):
    """The attempt's close (a complete or a fail), once one was answered."""
    def closed():
        return [r for r in plane.seen(None, execution_id) if r["op"] in ("complete", "fail") and "answered" in r]
    return plane.wait_for(closed, timeout, f"the close of {execution_id}")[0]


def held(plane, op, execution_id):
    """Holds `op` for `execution_id` until the event it answers is set, then answers as the plane would."""
    release = threading.Event()

    def answer(args, caller, entry):
        entry["held"] = True
        release.wait(60)
        return plane.default(op, args, caller)

    plane.script(op, answer, execution_id)
    return release


# ---------------------------------------------------------------------------
# The bound
# ---------------------------------------------------------------------------


def fresh_groups(stack):
    """Every live runner's group, by uid."""
    return {r["uid"]: read_group(stack, r["uid"]) for r in stack.runner_processes()}


def test_runner_bound(stack, plane):
    """A guest holding more than a runner's bound ends with its runner, at the bound, and nothing else is touched."""
    groups = wait_until(lambda: (lambda g: g if g and all(g.values()) else None)(fresh_groups(stack)), 20,
                        "every runner's group to be readable")
    bounds = {g["max"] for g in groups.values()}
    expect(len(bounds) == 1 and bounds.pop().isdigit() and all(g["swap_max"] == "0" and g["oom_group"] == "1" for g in groups.values()),
           f"each of the {len(groups)} runners runs in a group of its own with one bound, no swap and the group killed whole",
           groups)
    bound = int(next(iter(groups.values()))["max"])
    print(f"the runner bound is {bound} bytes ({mib(bound)}); the hostile guest holds {mib(HOG_BYTES)} of linear memory", flush=True)
    expect(bound < HOG_BYTES, f"the hostile guest holds more than the bound ({mib(HOG_BYTES)} > {mib(bound)})")

    # A sibling in another runner, held at its attach while the hostile
    # guest runs, then let complete.
    sibling = plane.mint(stack.boot, "reagent", ECHO_REF, wasm(ECHO), {"sibling": "alive"}, "ath_mem_sibling", 30_000)
    release_sibling = held(plane, "attach", sibling["execution_id"])
    expect(stack.start(sibling)[1] == {"ok": True}, "a sibling subtree starts and is held at its attach")
    sibling_runner = attached_runner(stack, plane, sibling)

    # The hostile guest's artifact is held until its group is watched.
    hog = plane.mint(stack.boot, "reagent", HOG_REF, wasm(HOG), {"hog": True}, "ath_mem_hog", 30_000)
    release_hog = held(plane, "fetch_artifact", hog["execution_id"])
    expect(stack.start(hog)[1] == {"ok": True}, "a guest that holds ten memories of 64 MiB starts")
    runner = attached_runner(stack, plane, hog)
    plane.wait_seen("fetch_artifact", hog["execution_id"], 30)
    expect(runner["uid"] != sibling_runner["uid"], "the two subtrees run under different uids", [runner, sibling_runner])
    settled = {}
    wait_until(lambda: fresh_runners_booted(stack, settled, busy=2), BOOT_S, "the pool's fresh runners to have booted",
               interval=0.25)
    before = container_memory(stack)
    release_before = release_identity(stack)
    state_before = stack.container_state()
    flag_before = oom_killed_flag(stack)
    hostile_before = read_group(stack, runner["uid"])
    sampler = GroupSampler(stack.container, runner["uid"])
    sampler.start()
    time.sleep(0.3)

    t_run = time.time()
    release_hog.set()
    gone = wait_until(lambda: stack.uid_processes(runner["uid"]) == [] and time.time(), 30,
                      "the hostile runner's process to be gone")
    exits = plane.wait_for(lambda: [r for r in plane.seen("runner_exited") if hog["attempt"] in r["attempts"]], 15,
                           "the service's report of the hostile runner's exit")
    wait_until(lambda: read_group(stack, runner["uid"]) is None, 15, "the hostile runner's group to be removed")
    time.sleep(0.5)
    sampler.stop()
    logs = stack.logs()
    ended_line = f"runner {runner['runner']} was ended at its memory bound of {bound} bytes"

    # Detection: which layer ended it.
    print(f"hostile runner {runner['runner']} (uid {runner['uid']}): group at {mib(hostile_before['current'])} before its guest ran; "
          f"group peak sampled {mib(sampler.group_peak())} of {mib(bound)} over {len(sampler.samples)} samples; "
          f"its last counters read {sampler.last_events()}; process gone {gone - t_run:.2f} s after the guest was let run; "
          f"container peak {mib(sampler.container_peak())} of {before['max']} bytes", flush=True)
    expect(any(ended_line in line for line in logs.splitlines()),
           "detection: the keeper reported the runner ended at its own bound (memory_exceeded, from the group's own "
           "counters), and the service logged it", [line for line in logs.splitlines() if "memory" in line][-10:])
    expect(plane.seen("complete", hog["execution_id"]) == [] and plane.seen("fail", hog["execution_id"]) == [],
           "detection: the guest neither completed nor trapped: the engine refused it nothing, so the engine did not end it",
           plane.seen(None, hog["execution_id"]))
    after = container_memory(stack)
    expect(after["events_local"].get("oom_kill", 0) == before["events_local"].get("oom_kill", 0)
           and after["events_local"].get("oom", 0) == before["events_local"].get("oom", 0),
           f"detection: the container's own limit was not what ended it (its local oom events {before['events_local']} -> {after['events_local']})",
           [before, after])
    # The group reaches its bound and is killed within a fraction of a
    # second, so the sampler may miss its last pages; that it reached the
    # bound is the kernel's own count, which the keeper reported. What was
    # sampled holds what the guest touched and never passed the bound.
    peak = sampler.group_peak()
    expect(peak is not None and hostile_before["current"] < peak <= bound,
           f"detection: the guest's pages were charged to the runner's own group, whose sampled peak {mib(peak)} "
           f"({peak} bytes{', the bound exactly' if peak == bound else ''}) never passed the bound",
           sampler.samples[-5:])

    # Durable settlement: the service reported the runner's exit holding the attempt.
    expect(len(exits) == 1 and exits[0]["args"]["runner"] == runner["runner"] and exits[0]["report"]["service"] == SERVICE
           and exits[0]["answered"] == "ok",
           f"settlement: the service reported runner {runner['runner']}'s exit once, holding the attempt, "
           f"{exits[0]['at'] - t_run:.2f} s after the guest was let run", exits)
    wait_until(lambda: stack.runners()["busy"] == 1 and stack.runners()["tainted"] == 0, 10,
               "the hostile runner to leave the pool, the sibling alone busy")
    expect(hog["attempt"] not in stack.attempts(), "settlement: the service holds nothing of the hostile attempt", stack.attempts())

    # OS cleanup.
    expect(stack.uid_processes(runner["uid"]) == [], f"cleanup: no process of uid {runner['uid']} remains", stack.processes())
    expect(os.path.basename(runner["home"]) not in stack.homes(), f"cleanup: its home {runner['home']} is scrubbed", stack.homes())
    expect(read_group(stack, runner["uid"]) is None, f"cleanup: its group {group(runner['uid'])} is gone")
    settled = {}
    wait_until(lambda: fresh_runners_booted(stack, settled, busy=1), BOOT_S, "the pool to settle", interval=0.25)
    after = container_memory(stack)
    expect(after["current"] <= before["current"] + 32 * MIB,
           f"cleanup: the container's memory returned: {mib(before['current'])} before, {mib(sampler.container_peak())} at its peak, "
           f"{mib(after['current'])} after", [before, after])
    expect(release_identity(stack) == release_before and stack.container_state()["restarts"] == state_before["restarts"],
           "cleanup: the release and the container were not touched", [release_before, release_identity(stack)])
    # Docker reads the flag from the container's memory.events, which counts
    # a kill in any group below it: a runner ended at its own bound sets it
    # though the container's limit and its release were never touched.
    print(f"Docker's OOMKilled flag for the container: {flag_before} before the hostile guest ran, "
          f"{oom_killed_flag(stack)} after", flush=True)

    # The sibling kept its process, and its group, which took nothing of the
    # hostile guest, and completes. The group is read while the sibling still
    # holds its runner: once it completes, its runner is idle and retired
    # after the service's idle time, which may be shorter than the read.
    expect(stack.runner_process(sibling_runner["runner"]) is not None
           and stack.runner_process(sibling_runner["runner"])["pid"] == sibling_runner["pid"],
           "the sibling's runner kept its process through the hostile runner's end", stack.runner_processes())
    sibling_group = read_group(stack, sibling_runner["uid"])
    expect(sibling_group is not None and sibling_group["peak"] < bound,
           f"the sibling's group peaked at {mib(sibling_group and sibling_group['peak'])}, under its bound", sibling_group)
    release_sibling.set()
    complete = terminal(plane, sibling["execution_id"], BOOT_S)
    expect(complete["op"] == "complete" and complete["args"]["outcome"]["output"] == {"sibling": "alive"},
           "the sibling completed", complete)

    # The uid, next given to a runner, holds nothing of the hostile one.
    reused = reuse_uid(stack, plane, runner)
    expect(reused["runner"] != runner["runner"] and reused["home"] != runner["home"],
           f"the uid {runner['uid']} was given to a new runner ({reused['runner']}) with a home of its own", [runner, reused])
    expect(reused["group"]["max"] == str(bound) and reused["group"]["peak"] < bound // 2 and not reused["group"]["events"].get("oom_kill"),
           f"its group is its own: bound {reused['group']['max']}, peak {mib(reused['group']['peak'])}, no kill counted",
           reused["group"])
    expect(all(r["runner"] != runner["runner"] for r in plane.seen("attach") if r["execution_id"] != hog["execution_id"]),
           "no later attach presented the hostile runner")


def fresh_runners_booted(stack, first_seen, settle_s=4.0, busy=0):
    """Whether the pool holds its fresh runners, each booted for `settle_s`, and `busy` busy ones."""
    now = time.monotonic()
    live = {r["runner"] for r in stack.runner_processes()}
    for runner in live:
        first_seen.setdefault(runner, now)
    counts = stack.runners()
    booted = [r for r in live if now - first_seen[r] >= settle_s]
    return counts["busy"] == busy and counts["fresh"] >= stack.pool_size and len(booted) >= stack.pool_size + busy


def reuse_uid(stack, plane, hostile, tries=12):
    """Runs subtrees of new athanors until a runner is given the hostile runner's uid; that runner, its home and group."""
    for n in range(tries):
        for process in stack.runner_processes():
            if process["uid"] == hostile["uid"]:
                return {**process, "group": wait_until(lambda: read_group(stack, process["uid"]), 10, "the new runner's group")}
        attempt = plane.mint(stack.boot, "reagent", ECHO_REF, wasm(ECHO), {"cycle": n}, f"ath_mem_cycle_{n}", 30_000)
        expect(stack.start(attempt)[1] == {"ok": True}, f"a subtree of another athanor starts ({n + 1})")
        terminal(plane, attempt["execution_id"], BOOT_S)
        time.sleep(stack.idle_ttl_ms / 1000 + 0.5)
    sys.exit(f"FAIL: uid {hostile['uid']} was not given to a runner again within {tries} subtrees")


# ---------------------------------------------------------------------------
# No writable cgroup
# ---------------------------------------------------------------------------


def test_bound_unavailable(image, plane, window_s=5.0):
    """Without writable-cgroups=true, no runner process ever starts, the pool keeps none, and the service says what it lacks."""
    stack = Stack("cyfr-opus-unbounded", image, plane, writable_cgroups=False)
    try:
        stack.up(wait_pool=False)
        probe = stack.exec("mkdir /sys/fs/cgroup/probe-writable")
        expect(probe.returncode != 0 and "Read-only" in probe.stderr,
               f"the service's cgroup is mounted read-only without the option ({probe.stderr.strip()})", probe.stderr)
        boot = stack.boot
        refused = wait_until(lambda: (lambda s: s if s[0] == 200 and s[1]["ok"]["refusal"] else None)(stack.status()),
                             10, "the status to report the keeper's refusal")[1]["ok"]
        expect(refused["refusal"]["reason"] == "memory_unavailable" and "writable-cgroups=true" in refused["refusal"]["message"]
               and refused["memory_bytes"] == 402653184,
               "the status reports the refusal, naming writable-cgroups=true, and the bound every runner would run under", refused)
        sampler = StatusSampler(stack, interval=0.1, threads=1).start()
        seen = set()
        deadline = time.monotonic() + window_s
        attempt = plane.mint(stack.boot, "reagent", ECHO_REF, wasm(ECHO), {"unbounded": True}, "ath_mem_unbounded", 30_000)
        code, answer = stack.start(attempt)
        while time.monotonic() < deadline:
            seen.update(p["pid"] for p in stack.processes() if any(POOL_FIRST <= u <= POOL_LAST for u in p["uids"]))
            time.sleep(0.2)
        samples = sampler.stop()
        logs = stack.logs().splitlines()
        refusals = [line for line in logs if "was not started" in line and "writable-cgroups=true" in line]
        counts = [s[1] for s in samples]
        print(f"status without the option, over {window_s:.0f} s: {len(samples)} samples, first {counts[0] if counts else None}, "
              f"last {counts[-1] if counts else None}; the start answered {code} {answer}", flush=True)
        expect(seen == set() and stack.homes() == [], "no runner process ever ran under a pooled uid, and no home was made",
               {"pids": sorted(seen), "homes": stack.homes()})
        expect(len(refusals) == 1, "the service logged once that cyfr-spawn cannot bound a runner, naming writable-cgroups=true",
               [line for line in logs if "memory" in line or "Keeper" in line][-10:])
        expect(counts and all(c == {"fresh": 0, "idle": 0, "busy": 0, "tainted": 0} for c in counts),
               f"the pool kept no runner it was refused, tainted or otherwise, in any of {len(counts)} samples",
               [c for c in counts if c != {"fresh": 0, "idle": 0, "busy": 0, "tainted": 0}][:5])
        expect(code == 503 and answer.get("error") == "unavailable" and "writable-cgroups=true" in answer.get("message", ""),
               "the start was refused 503 unavailable, naming writable-cgroups=true", answer)
        exits = [r for r in plane.seen("runner_exited") if attempt["attempt"] in r["attempts"]]
        expect(plane.seen(None, attempt["execution_id"]) == [] and exits == [],
               "the attempt it was refused made no host call and no runner exit was reported for it: nothing of it ran",
               {"calls": plane.seen(None, attempt["execution_id"]), "exits": exits})
        code, status = stack.status()
        expect(code == 200 and status["ok"]["boot"] == boot and status["ok"]["refusal"] == refused["refusal"],
               "the service stayed up on the same boot, still reporting the refusal", status)
    finally:
        stack.down()


# ---------------------------------------------------------------------------
# The measurement
# ---------------------------------------------------------------------------


def seed(kind, name):
    base = os.path.join(SEED, f"{kind}s", "local", name)
    version = sorted(os.listdir(base))[-1]
    with open(os.path.join(base, version, "cyfr-manifest.json")) as f:
        manifest = json.load(f)
    fields = [field for need in (manifest.get("needs") or {}).values() if isinstance(need, dict) for field in need.get("fields", [])]
    binary = {"catalyst": "catalyst.wasm", "formula": "formula.wasm", "reagent": "reagent.wasm"}[kind]
    return {"ref": f"{kind}:local.{name}:{version}", "name": name, "type": kind,
            "wasm": wasm(os.path.join(base, version, binary)), "secrets": {f: "sk-memory-measure" for f in fields}}


def chat_request(model):
    """A model turn with a long thread, a tool result and an image: some 600 KB of input."""
    notes = ("The estate's notes, read back in full so the model sees every line of them. " * 64)[:4_000]
    image = base64.b64encode(os.urandom(150_000)).decode()
    messages = []
    for i in range(50):
        messages.append({"role": "user", "content": f"Note {i}: {notes}"})
        messages.append({"role": "assistant", "content": [
            {"type": "text", "text": "Reading it."},
            {"type": "tool_call", "id": f"call_{i}", "name": "files.read", "arguments": {"path": f"notes/{i}.txt"}}]})
        messages.append({"role": "tool", "content": [
            {"type": "tool_result", "tool_call_id": f"call_{i}", "name": "files.read", "content": notes, "is_error": False}]})
    messages.append({"role": "user", "content": [{"type": "text", "text": "And this?"},
                                                 {"type": "image", "media_type": "image/png", "data": image}]})
    tools = [{"name": f"tool_{i}", "description": "A tool the estate offers. " * 8,
              "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}} for i in range(40)]
    return {"operation": "chat", "params": {"model": model, "system": "You are the estate's assistant. " * 20,
                                             "messages": messages, "tools": tools, "max_tokens": 4096}}


def fixture_request():
    """The chat fixture streaming 1,000 deltas of 300 bytes, then answering 600 KB of text."""
    script = {"steps": [{
        "emit": [{"$repeat": 1000, "event": {"type": "text.delta", "text": {"$fill": "streamed ", "bytes": 300}}}],
        "answer": {"content": [{"type": "text", "text": {"$fill": "answered ", "bytes": 600_000}}], "stop_reason": "end_turn",
                   "usage": {"input_tokens": 1000, "output_tokens": 150_000}}}]}
    text = "```chat-fixture\n" + json.dumps(script) + "\n```"
    return {"operation": "chat", "params": {"model": "fixture", "messages": [{"role": "user", "content": text}]}}


def bound_authority(ref, tasks):
    """An authority bound to `ref` whose node allows `tasks` concurrent children (`Cyfr.Authority` on the wire)."""
    name = ref.rsplit(":", 1)[0]
    return {
        "activation": {}, "budget": {"id": "bgt_AAAAAAAAAAHKmY6r"}, "chain": [], "cursor": {"bound": name}, "depth": 0,
        "invoke_mode": "open_inert",
        "policy": {"canonical": "jcs-1", "nodes": {name: {"limits": {
            "timeout": "5m", "batch_timeout": "5m", "max_memory_bytes": 64 * MIB, "max_request_size": 1_048_576,
            "max_response_size": 5_242_880, "max_concurrent_tasks": tasks, "rate_limit": {"requests": 100, "window": "1m"}},
            "edges": {}}}},
    }


def admit_children(plane, stack, parent, components):
    """Answers each `admit_child` of `parent` with a child minted for the reference it names."""
    by_name = {c["ref"].rsplit(":", 1)[0]: c for c in components}

    def answer(args, caller, entry):
        component = by_name.get(args.get("reference"))
        if component is None:
            return {"error": "guest_error", "type": "not_found", "message": "No such component."}
        child = plane.mint(stack.boot, component["type"], component["ref"], component["wasm"], args.get("input") or {},
                           parent["athanor_id"], 60_000, secrets=component["secrets"], parent=parent)
        return plane.child_answer(child)(args, caller, entry)

    plane.script("admit_child", answer, parent["execution_id"])


def workloads():
    catalysts = {name: seed("catalyst", name) for name in ("claude", "openai", "gemini", "grok", "openrouter", "http", "files")}
    fixture = {"ref": CHAT_FIXTURE_REF, "type": "catalyst", "wasm": wasm(CHAT_FIXTURE), "secrets": {"FIXTURE_API_KEY": "sk-fixture"}}
    echo = {"ref": ECHO_REF, "type": "reagent", "wasm": wasm(ECHO), "secrets": {}}
    formula = seed("formula", "list-models")
    out = [("reagent echo", echo, {"echo": "x" * 1_000}, None)]
    for name, model in MODELS.items():
        out.append((f"{name} chat", catalysts[name], chat_request(model), None))
    out.append(("chat fixture: 1,000 deltas, 600 KB answer", fixture, fixture_request(), None))
    out.append(("http fetch", catalysts["http"], {"operation": "fetch", "params": {"url": "https://example.com/"}}, None))
    out.append(("files list", catalysts["files"], {"operation": "list", "params": {"path": "/"}}, None))
    out.append(("list-models: 5 catalyst children", formula, {}, list(catalysts[n] for n in MODELS)))
    return out


def run_workload(stack, plane, label, component, input_, children, athanor):
    authority = bound_authority(component["ref"], 5) if children else None
    intercepted = ("execution.run", "execution.run_stream") if children else ()
    attempt = plane.mint(stack.boot, component["type"], component["ref"], component["wasm"], input_, athanor, 120_000,
                         intercepted=intercepted, secrets=component["secrets"], authority=authority)
    if children:
        admit_children(plane, stack, attempt, children)
    code, answer = stack.start(attempt)
    expect(code == 200 and answer == {"ok": True}, f"{label}: starts", answer)
    runner = attached_runner(stack, plane, attempt)
    closed = terminal(plane, attempt["execution_id"], 180)
    measured = read_group(stack, runner["uid"])
    admitted = len(plane.seen("admit_child", attempt["execution_id"]))
    outcome = closed["args"].get("outcome", {})
    summary = "completed" if closed["op"] == "complete" else f"failed: {str(outcome.get('error'))[:120]}"
    return runner, measured, summary, admitted


def measure(image, rounds):
    results = {}
    keeper_peaks = []
    for n in range(rounds):
        plane = ControlPlane(secrets.token_bytes(32), SERVICE).serve()
        stack = Stack("cyfr-opus-memory-measure", image, plane, pool_size=2, idle_ttl_ms=3_000)
        try:
            stack.up()
            settled = {}
            wait_until(lambda: fresh_runners_booted(stack, settled, settle_s=8.0), BOOT_S, "the fresh runners to boot", interval=0.5)
            live = stack.runner_processes()
            fresh = [read_group(stack, r["uid"]) for r in live]
            results.setdefault("a fresh runner that ran nothing", []).extend(g["peak"] for g in fresh if g)
            print(f"round {n + 1}: bound {fresh[0]['max'] if fresh and fresh[0] else '?'}; fresh runners peaked at "
                  f"{[mib(g['peak']) for g in fresh if g]}; one holds now {brief_stat(group_stat(stack, live[0]['uid']))}",
                  flush=True)
            for i, (label, component, input_, children) in enumerate(workloads()):
                runner, group_, summary, admitted = run_workload(stack, plane, label, component, input_, children, f"ath_measure_{n}_{i}")
                results.setdefault(label, []).append(group_["peak"])
                extra = f", {admitted} children admitted" if children else ""
                print(f"round {n + 1}: {label}: runner {runner['runner']} peaked at {mib(group_['peak'])} "
                      f"({group_['peak']} bytes; {summary}{extra}); it holds now {brief_stat(group_stat(stack, runner['uid']))}",
                      flush=True)
                # The idle runner retires, so the pool's eight uids are never exhausted.
                time.sleep(stack.idle_ttl_ms / 1000 + 0.5)
            athanor = f"ath_measure_{n}_all"
            runners = set()
            for label, component, input_, children in workloads():
                runner, group_, summary, _ = run_workload(stack, plane, label, component, input_, children, athanor)
                runners.add(runner["runner"])
            label = "one runner of one athanor running all of them in turn"
            results.setdefault(label, []).append(group_["peak"])
            print(f"round {n + 1}: {label}: {len(runners)} runner(s), peaked at {mib(group_['peak'])} ({group_['peak']} bytes)", flush=True)
            keeper = keeper_group(stack)
            keeper_peaks.append(keeper["peak"])
            print(f"round {n + 1}: the keeper group (cyfr-spawn and the service) peaked at {mib(keeper['peak'])}", flush=True)
        finally:
            stack.down()
            plane.stop()
    print("--- runner peaks (memory.peak of the runner's own group), over every round")
    for label, peaks in results.items():
        print(f"{label}: {', '.join(mib(p) for p in peaks)} (max {max(peaks)} bytes)")
    largest = max(max(p) for p in results.values())
    print(f"largest runner peak {largest} bytes ({mib(largest)}); x{MARGIN} = {int(largest * MARGIN)} bytes "
          f"({mib(largest * MARGIN)}); the keeper group peaked at {', '.join(mib(p) for p in keeper_peaks)}")


def main(image, cases, rounds):
    if run("docker", "image", "inspect", image, check=False).returncode != 0:
        sys.exit(f"FAIL: prerequisite missing: the image {image} is not built")
    if rounds:
        measure(image, rounds)
        return
    plane = ControlPlane(secrets.token_bytes(32), SERVICE).serve()
    try:
        for case in cases:
            if case == "bound":
                stack = Stack("cyfr-opus-memory", image, plane, idle_ttl_ms=1_000)
                try:
                    stack.up()
                    test_runner_bound(stack, plane)
                finally:
                    stack.down()
            elif case == "unavailable":
                test_bound_unavailable(image, plane)
            else:
                sys.exit(f"unknown case {case}\n{__doc__}")
    finally:
        plane.stop()


if __name__ == "__main__":
    arguments = sys.argv[1:]
    rounds = 0
    if "--measure" in arguments:
        at = arguments.index("--measure")
        rounds = int(arguments[at + 1]) if at + 1 < len(arguments) and arguments[at + 1].isdigit() else 3
        arguments = arguments[:at] + arguments[at + 1 + (1 if at + 1 < len(arguments) and arguments[at + 1].isdigit() else 0):]
    if not arguments:
        sys.exit(__doc__)
    main(arguments[0], arguments[1:] or ["bound", "unavailable"], rounds)
