#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A runner cannot take more memory than its bound, run as docker-compose.yml's locus-runtime service.

cyfr-locus bounds every runner by its kind, at half of the pool's work and
never under a runner's least bound (Prima.LocusPool), and the service names
no bound: cyfr-locus gives the runner a cgroup v2 group of its own at that
bound, with no swap and the group killed whole, charged for the runner's
process, every guest's linear memory, the pages of its home and the kernel
memory it causes, together. It can do so only where the service mounts the
container's cgroup writable (`security_opt: writable-cgroups=true`);
anywhere else it can make no role's group and refuses its boot, so no
runner starts.

- `bound`: in a service whose pool's work is sized for the case (`WORK`,
  through the reserve compose reads), every runner runs in such a group.
  A formula whose children run in its runner (the nested probe spawning
  its children and awaiting them all) holds more than the bound although
  no run passes what the engine lets it have: each child (hog.wasm, a
  catalyst) first proves the engine refuses it more than its consented
  64 MiB of linear memory, then touches every page of the 64 MiB and keeps
  it, and as many of them as hold the bound together are spawned, so the
  runner's own memory is the margin by which they pass it. The
  children take their memory one at a time, the group read after each, and
  the kernel ends the runner at the bound while a child's pages are
  charged: the keeper reports the end at the bound (the service logs it),
  no child and not the formula completed or trapped, the container's own
  limit was not reached, and the group never held more than the bound. The
  service reports the runner's exit holding the formula's attempt and
  every child's; the runner is tainted and never assigned again; its uid
  holds no process, its home is scrubbed and its group is gone; the
  container's memory returns; a sibling runner busy meanwhile keeps its
  process and completes; the release is not touched; and when the uid is
  next given to a runner, that runner has a home and a group of its own,
  which the ended one left nothing in.
- `pool`: the service serves the runtime role's report on the pool wire
  (Prima.LocusPool) under the pool key derived from its own key: every
  counter of a runtime alone is a runner's (warm or run), each once, and
  the warm floor's runner, read each second, is counted with time
  measured; a request signed with the builds' or the backends' pool key,
  derived from the same key, is refused.
- `unavailable`: under the shipped service without `writable-cgroups=true`,
  cyfr-locus refuses its boot, saying it can make no cgroup group for a
  role, no runner process ever starts, and the container restart-loops.

`--measure` runs the seed components through the scripted control plane,
each subtree in a fresh runner of a fresh container, and prints each
runner's group memory.peak as the kernel accounts it: a runner that booted
and ran nothing; each model catalyst's `chat` with a long thread and
an image (its egress denied, as the scripted plane's authority grants none);
the chat fixture's `chat` streaming a long answer; the http and files
catalysts; the list-models formula spawning its five catalyst children in
the same runner; and one runner of one athanor running all of them in turn.
It prints the service's own group peak and the largest runner peak beside
a runner's least bound, which holds a component at the platform's ceiling
beside its runner.

Usage: tests/locus-runtime-image/memory.py IMAGE [--measure [ROUNDS]] [bound|pool|unavailable]...
"""

import base64
import hashlib
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
from stack import (  # noqa: E402
    COMPOSE_SERVICE, HERE, POOL_FIRST, POOL_LAST, ROLE, ROOT, SERVICE, Stack, expect, run, wait_until,
)
import imagesuite  # noqa: E402

MIB = 1 << 20
# A runner's first attach, bounded for a loaded host.
BOOT_S = 60
# The formula whose children run in its runner: the nested probe, which
# spawns every request it is given and awaits them all.
PROBE = os.path.join(ROOT, "apps", "cyfr", "test", "integration", "runtime", "support", "test_wasm", "nested_probe",
                     "nested_probe.wasm")
PROBE_REF = "formula:local.nested-probe:0.1.0"
# Its children: hog.wasm, built from hog.wat by build.sh, whose digests
# these are, so a hog.wat changed without a rebuild fails the suite.
HOG = os.path.join(HERE, "hog.wasm")
HOG_REF = "catalyst:local.hog:0.1.0"
HOG_DIGESTS = {
    "hog.wat": "sha256:552e815e288d973f5cfe9c5180b1980944cf1c1c3d3861e2a8304aa6647a5fa2",
    "hog.wasm": "sha256:da93712793bd4ae639d3c8d15fcffe160f1a4ba2ab3f5dd0a7a363b6fc3d1a03",
}
# What one child holds once every page is touched: all the linear memory
# the engine lets one run have under the zero authority it runs under.
CHILD_BYTES = 64 * MIB
# The pool's work of the bound case, 1 GiB. A runner's bound is half of
# it, never under a runner's least, 512 MiB, so the formula's runner ends at
# its bound with the other half left to the case's two other runners, the
# sibling's and the warm floor's fresh one. RUNNER_ALONE is what each may
# hold beside it, far above what a runner alone holds (the runner program
# with a guest compiled), so the kernel's bound over the pool cannot end
# the formula's runner first.
RUNNER_ALONE = 256 * MIB
WORK = 2 * max(imagesuite.LEAST_CAP_BYTES["runner"], 2 * RUNNER_ALONE)


def children_for(bound):
    """The children the formula spawns: as many as hold `bound` before their runner holds a byte of its own, so
    whatever else the runner holds is the margin by which they pass it, however little another architecture gives it."""
    return -(-bound // CHILD_BYTES)

ECHO = os.path.join(ROOT, "apps", "locus", "test", "support", "runtime", "test_wasm", "echo.wasm")
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


# The runtime role's group in the pool's work, which holds each runner's
# group at the rest of LOCUS_RUNTIME_CPU_LIMIT, and work itself, whose
# memory.max is the pool's bound over every role's spawns, the runners'
# beside rest.
ROLE_GROUP = imagesuite.work_group(ROLE)
BOUND_GROUP = imagesuite.bound_group(ROLE)


def group(uid):
    return f"{ROLE_GROUP}/keeper-{uid}/bound"


# The service's group, outside work: the runtime role's process and its relays.
KEEPER_GROUP = imagesuite.service_leaf(ROLE)


def read_group(stack, uid):
    """The group of the spawn running under `uid` as the kernel accounts it, or None when there is none.

    Absence is the word `absent` from a command that exits 0. The fields are
    read whole, and the events must carry both OOM counters.
    """
    # Each field is read by its own command, chained so that any failed read ends the script with its status:
    # a command substitution inside printf's arguments would hide the failure from the status.
    out = imagesuite.read_output(stack.exec(
        f"g={group(uid)}; if [ -d $g ]; then "
        "m=$(cat $g/memory.max) && s=$(cat $g/memory.swap.max) && o=$(cat $g/memory.oom.group) && "
        "p=$(cat $g/memory.peak) && c=$(cat $g/memory.current) && e=$(tr '\\n' ' ' < $g/memory.events) && "
        "printf 'present|%s|%s|%s|%s|%s|%s\\n' \"$m\" \"$s\" \"$o\" \"$p\" \"$c\" \"$e\"; else echo absent; fi"),
        f"the group of uid {uid}").strip()
    if out == "absent":
        return None
    word, limit, swap, oom_group, peak, current, events = out.split("|")
    if word != "present":
        sys.exit(f"FAIL: the group of uid {uid} answered {word!r}")
    pairs = events.split()
    counters = imagesuite.parse_counters("\n".join(f"{name} {count}" for name, count in zip(pairs[::2], pairs[1::2])),
                                         ("oom", "oom_kill"), f"the events of the group of uid {uid}")
    return {"max": limit, "swap_max": swap, "oom_group": oom_group, "peak": int(peak), "current": int(current),
            "events": counters}


def container_memory(stack):
    """Work, the pool's bound over the runners, which stands where their container's cgroup stood: its bound, current
    use, and the events of its own bound alone."""
    out = imagesuite.read_output(
        stack.exec(f"cat {BOUND_GROUP}/memory.max {BOUND_GROUP}/memory.current; cat {BOUND_GROUP}/memory.events.local"),
        "work's memory files")
    lines = out.split("\n")
    events = imagesuite.parse_counters("\n".join(line for line in lines[2:] if line), ("oom", "oom_kill"),
                                       "the container's own events")
    return {"max": lines[0].strip(), "current": int(lines[1]), "events_local": events}


def group_stat(stack, uid):
    """What the group holds now, by kind (memory.stat): anonymous pages, page cache, kernel memory, tmpfs."""
    out = stack.exec(f"cat {group(uid)}/memory.stat").stdout.split("\n")
    stat = dict((line.split()[0], int(line.split()[1])) for line in out if len(line.split()) == 2)
    return {kind: stat.get(kind, 0) for kind in ("anon", "file", "kernel", "shmem")}


def brief_stat(stat):
    return ", ".join(f"{kind} {mib(count)}" for kind, count in stat.items())


def keeper_group(stack):
    """The keeper's group (cyfr-locus, the service and every spawn without a bound): its peak and current use."""
    out = imagesuite.read_output(stack.exec(f"cat {KEEPER_GROUP}/memory.peak {KEEPER_GROUP}/memory.current"),
                                 "the keeper group").split()
    if len(out) != 2:
        sys.exit(f"FAIL: the keeper group answered {out!r}")
    return {"peak": int(out[0]), "current": int(out[1])}


def oom_killed_flag(stack):
    """Docker's OOMKilled flag for the container, which it reads from the container's cgroup, descendants included."""
    return json.loads(run("docker", "inspect", "--format", "{{json .State.OOMKilled}}", stack.container).stdout)


def release_identity(stack):
    """The service's VM as its pid and the kernel's start time for it: a restarted release changes it."""
    pid = stack.service_beam_pid()
    if pid is None:
        sys.exit("FAIL: no service VM is listed, so its identity cannot be read")
    started = imagesuite.read_output(stack.exec(f"cut -d' ' -f22 /proc/{pid}/stat"), "the service VM's start time").strip()
    if not started:
        sys.exit(f"FAIL: the service VM {pid} has no start time")
    return (pid, started)


def mib(count):
    return f"{count / MIB:.0f} MiB" if count is not None else "none"


def wasm(path):
    with open(path, "rb") as f:
        return f.read()


def process_alive(container, pid):
    """Whether process `pid` runs in `container`: the word its probe prints in a command that exits 0."""
    probe = (f"if [ -d /proc/{pid} ] && ! grep -q '^State:.*Z' /proc/{pid}/status; "
             "then echo alive; else echo dead; fi")
    word = imagesuite.read_word(run("docker", "exec", container, "sh", "-c", probe, check=False), ("alive", "dead"),
                                f"whether process {pid} runs")
    return word == "alive"


class GroupSampler(threading.Thread):
    """Samples one group (`group(uid)`, or `KEEPER_GROUP`) and the container's memory from inside it, as fast as a shell reads a file.

    The loop forks nothing (`read` and `echo` are the shell's own), so it
    sees a group that fills its bound within a fraction of a second, and
    reads the group's own out-of-memory counters until the keeper removes
    it. It spins a CPU while it runs, and ending `docker exec` would not end
    it, so it names its own pid first and `stop` kills it in the
    container."""

    SCRIPT = r"""
      echo "pid $$"
      g=GROUP
      while :; do
        p=; c=; k=; o=; ok=
        { read -r p < $g/memory.peak; read -r c < $g/memory.current; } 2>/dev/null
        read -r k < BOUND_GROUP/memory.current
        { while read -r name value; do
            case $name in oom) o=$value ;; oom_kill) ok=$value ;; esac
          done < $g/memory.events; } 2>/dev/null
        echo "$p|$c|$k|oom $o oom_kill $ok"
      done"""

    def __init__(self, container, path):
        super().__init__(daemon=True)
        self.container = container
        self.pid = None
        self.process = subprocess.Popen(
            ["docker", "exec", container, "sh", "-c", self.SCRIPT.replace("BOUND_GROUP", BOUND_GROUP).replace("GROUP", path)],
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
        wait_until(lambda: self.pid and not process_alive(self.container, self.pid),
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


def prerequisites():
    """The bound case's guests are where it reads them, and hog.wasm is the build of hog.wat that HOG_DIGESTS records."""
    for name, path in (("formula", PROBE), ("hog.wat", os.path.join(HERE, "hog.wat")), ("hog.wasm", HOG)):
        if not os.path.isfile(path):
            sys.exit(f"FAIL: prerequisite missing: the {name} {path}")
    for name, recorded in HOG_DIGESTS.items():
        actual = "sha256:" + hashlib.sha256(wasm(os.path.join(HERE, name))).hexdigest()
        if actual != recorded:
            sys.exit(f"FAIL: {name} is {actual}, not the {recorded} build.sh printed for it: rebuild it with "
                     "tests/locus-runtime-image/build.sh and record what it prints in HOG_DIGESTS")


def fresh_groups(stack):
    """Every live runner's group, by uid."""
    return {r["uid"]: read_group(stack, r["uid"]) for r in stack.runner_processes()}


class HogChildren:
    """The formula's children, as the control plane admits them for its runner.

    Each `admit_child` of the formula is answered with a hog minted for the
    reference it names, under the zero authority, as `admit_child` answers
    a child it claimed for the formula's runner. A child's first emit
    (`hog.ready`) is held until `let` lets that child take its memory; its
    second (`hog.holding`) and any later push are held until `finish`, so a
    child that holds its memory keeps it until its runner ends."""

    def __init__(self, plane, stack, parent):
        self.plane = plane
        self.stack = stack
        self.parent = parent
        self.minted = []
        self.lock = threading.Lock()
        self.finished = threading.Event()
        plane.script("admit_child", self.admit, parent["execution_id"])

    def admit(self, args, caller, entry):
        if args.get("reference") != HOG_REF.rsplit(":", 1)[0]:
            return {"error": "guest_error", "type": "not_found", "message": "No such component."}
        child = self.plane.mint(self.stack.boot, "catalyst", HOG_REF, wasm(HOG), args.get("input") or {},
                                self.parent["athanor_id"], 120_000, parent=self.parent)
        child["let"] = threading.Event()
        child["let_at"] = None
        self.plane.script("push_deltas", self.pushed(child), child["execution_id"])
        with self.lock:
            self.minted.append(child)
        return self.plane.child_answer(child)(args, caller, entry)

    def pushed(self, child):
        def answer(args, caller, entry):
            entry["held"] = True
            entry["events"] = [json.loads(delta["event"]) for delta in args.get("deltas", [])]
            ready = [event.get("type") for event in entry["events"]] == ["hog.ready"]
            (child["let"] if ready else self.finished).wait(120)
            return self.plane.default("push_deltas", args, caller)
        return answer

    def children(self):
        with self.lock:
            return list(self.minted)

    def events(self, child, kind):
        """The pushes of `child` carrying `kind`, oldest first."""
        return [r for r in self.plane.seen("push_deltas", child["execution_id"])
                if [event.get("type") for event in r.get("events", [])] == [kind]]

    def let(self, child):
        child["let_at"] = time.time()
        child["let"].set()

    def finish(self):
        self.finished.set()
        for child in self.children():
            child["let"].set()


def test_runner_bound(stack, plane):
    """A formula whose children each hold what the engine lets them, together more than the runner's bound, ends with its runner at the bound, and nothing else is touched."""
    groups = wait_until(lambda: (lambda g: g if g and all(g.values()) else None)(fresh_groups(stack)), 20,
                        "every runner's group to be readable")
    bounds = {g["max"] for g in groups.values()}
    expect(len(bounds) == 1 and bounds.pop().isdigit() and all(g["swap_max"] == "0" and g["oom_group"] == "1" for g in groups.values()),
           f"each of the {len(groups)} runners runs in a group of its own with one bound, no swap and the group killed whole",
           groups)
    bound = int(next(iter(groups.values()))["max"])
    work = imagesuite.read_output(stack.exec(f"cat {imagesuite.CGROUP}/work/memory.max"), "work's memory.max").strip()
    expect(work == str(WORK) and bound == imagesuite.cap_bytes("warm", WORK),
           f"the pool's work is {mib(WORK)} as the kernel bounds it, and every runner is bounded at half of it, never "
           f"under a runner's least bound: {mib(imagesuite.cap_bytes('warm', WORK))}", {"work": work, "bound": bound})
    count = children_for(bound)
    print(f"the runner bound is {bound} bytes ({mib(bound)}); the formula's {count} children each hold {mib(CHILD_BYTES)} "
          f"of linear memory, {mib(count * CHILD_BYTES)} between them", flush=True)
    expect(count * CHILD_BYTES >= bound,
           f"the children alone hold the bound ({count} x {mib(CHILD_BYTES)} >= {mib(bound)}), so what else their runner "
           "holds is the margin by which they pass it")

    # A sibling in another runner, held at its attach while the formula's
    # children take their memory, then let complete.
    sibling = plane.mint(stack.boot, "reagent", ECHO_REF, wasm(ECHO), {"sibling": "alive"}, "ath_mem_sibling", 30_000)
    release_sibling = held(plane, "attach", sibling["execution_id"])
    expect(stack.start(sibling)[1] == {"v": 3, "ok": True}, "a sibling subtree starts and is held at its attach")
    sibling_runner = attached_runner(stack, plane, sibling)

    # The formula spawns its children, each admitted for its runner, and
    # each waits at its first emit until it is let take its memory.
    requests = [{"tool": "execution", "action": "run", "args": {"reference": HOG_REF.rsplit(":", 1)[0], "input": {"child": n}}}
                for n in range(1, count + 1)]
    formula = plane.mint(stack.boot, "formula", PROBE_REF, wasm(PROBE), {"op": "spawn_await_all", "requests": requests},
                         "ath_mem_formula", 120_000, intercepted=("execution.run", "execution.run_stream"),
                         authority=bound_authority(PROBE_REF, count))
    children = HogChildren(plane, stack, formula)
    try:
        bound_case(stack, plane, bound, count, sibling, release_sibling, sibling_runner, formula, children)
    finally:
        children.finish()
        release_sibling.set()


def bound_case(stack, plane, bound, count, sibling, release_sibling, sibling_runner, formula, children):
    # The formula's artifact is held until the pool has booted the runner
    # it spawns behind the formula's, so its children wait at their first
    # emit for seconds, not for a runner's boot.
    release_formula = held(plane, "fetch_artifact", formula["execution_id"])
    try:
        expect(stack.start(formula)[1] == {"v": 3, "ok": True}, f"a formula that spawns {count} children and awaits them all starts")
        runner = attached_runner(stack, plane, formula)
        plane.wait_seen("fetch_artifact", formula["execution_id"], 30)
        expect(runner["uid"] != sibling_runner["uid"], "the formula and the sibling run under different uids",
               [runner, sibling_runner])
        settled = {}
        wait_until(lambda: fresh_runners_booted(stack, settled, busy=2), BOOT_S, "the pool's fresh runners to have booted",
                   interval=0.25)
    finally:
        release_formula.set()
    kids = plane.wait_for(lambda: (lambda c: c if len(c) == count and all(children.events(k, "hog.ready") for k in c) else None)(
        children.children()), BOOT_S, f"the formula's {count} children to wait at their first emit")
    attempts = {formula["attempt"]} | {k["attempt"] for k in kids}
    wait_until(lambda: attempts <= set(stack.attempts()), 10, "the service to hold the formula's and every child's attempt")
    expect(all(r["runner"] == runner["runner"] for k in kids for r in plane.seen(None, k["execution_id"])),
           f"the control plane admitted {count} children for the formula's runner, each running in it: every host "
           f"call of theirs came from runner {runner['runner']}, and the service holds the formula's attempt and all of theirs",
           {"attempts": stack.attempts(), "children": [plane.seen(None, k["execution_id"]) for k in kids]})
    before = container_memory(stack)
    release_before = release_identity(stack)
    state_before = stack.container_state()
    flag_before = oom_killed_flag(stack)
    ready = read_group(stack, runner["uid"])
    sampler = GroupSampler(stack.container, group(runner["uid"]))
    sampler.start()
    time.sleep(0.3)

    # One child at a time takes its memory, until the runner is gone.
    holding, last = [], None
    for n, kid in enumerate(kids, start=1):
        children.let(kid)
        step = wait_until(
            lambda: ("holding" if children.events(kid, "hog.holding") else None)
            or ("gone" if stack.uid_processes(runner["uid"]) == [] else None),
            30, f"child {n} to hold its memory, or its runner to be gone", interval=0.02)
        if step == "gone":
            last = (n, kid, time.time())
            break
        group_ = read_group(stack, runner["uid"])
        if group_ is None:
            last = (n, kid, time.time())
            break
        holding.append((n, kid, group_))
        print(f"child {n} holds its {mib(CHILD_BYTES)}: the runner's group holds {mib(group_['current'])} of {mib(bound)}",
              flush=True)
    expect(last is not None, f"the runner was ended before its {count} children all held their memory",
           [(n, g) for n, _, g in holding])
    n_last, ending, _seen = last
    gone = wait_until(lambda: stack.runner_left(runner) == [] and time.time(), 30,
                      "the formula's runner's process to be gone")
    exits = plane.wait_for(lambda: [r for r in plane.seen("runner_exited") if formula["attempt"] in r["attempts"]], 15,
                           "the service's report of the formula's runner's exit")
    wait_until(lambda: read_group(stack, runner["uid"]) is None, 15, "the formula's runner's group to be removed")
    time.sleep(0.5)
    sampler.stop()
    logs = stack.logs()
    ended_line = f"runner {runner['runner']} was ended at its memory bound of {bound} bytes"

    # Detection: which layer ended it.
    print(f"formula's runner {runner['runner']} (uid {runner['uid']}): group at {mib(ready['current'])} with its "
          f"{count} children waiting; {len(holding)} held {mib(CHILD_BYTES)} each "
          f"({', '.join(mib(g['current']) for _, _, g in holding)} after each); child {n_last} was taking its memory "
          f"when its runner ended, its process gone {gone - ending['let_at']:.2f} s after the child was let; group peak "
          f"sampled {mib(sampler.group_peak())} ({sampler.group_peak()} bytes) of {bound} over {len(sampler.samples)} "
          f"samples; its last counters read {sampler.last_events()}; container peak {mib(sampler.container_peak())} of "
          f"{before['max']} bytes", flush=True)
    expect(any(ended_line in line for line in logs.splitlines()),
           "detection: the keeper reported the runner ended at its own bound (memory cap, from the group's own "
           "counters), and the service logged it", [line for line in logs.splitlines() if "memory" in line][-10:])
    expect(all(ready["current"] < g["current"] < bound for _, _, g in holding)
           and all(a["current"] < b["current"] for (_, _, a), (_, _, b) in zip(holding, holding[1:])),
           f"detection: each child's pages were charged to the runner's own group, which grew with each child that held "
           f"its memory and stayed under the bound until child {n_last} took its own", [ready] + [g for _, _, g in holding])
    expect(all(children.events(k, "hog.holding")[0]["at"] > k["let_at"] for _, k, _ in holding)
           and all(plane.seen("push_deltas", k["execution_id"]) == children.events(k, "hog.ready") for k in kids[n_last:]),
           f"detection: each child took its memory only once it was let, and the {count - n_last} after child {n_last} "
           "never took any", {k["execution_id"]: plane.seen("push_deltas", k["execution_id"]) for k in kids})
    closes = [r for k in [formula] + kids for r in plane.seen(None, k["execution_id"]) if r["op"] in ("complete", "fail")]
    expect(closes == [],
           "detection: neither the formula nor any child completed or trapped: the engine refused none of them anything, so "
           "the engine did not end them", closes)
    after = container_memory(stack)
    expect(after["events_local"]["oom_kill"] == before["events_local"]["oom_kill"]
           and after["events_local"]["oom"] == before["events_local"]["oom"],
           f"detection: the container's own limit was not what ended it (its local oom events {before['events_local']} -> {after['events_local']})",
           [before, after])
    # The keeper reads the group's counters once the runner is reaped and
    # removes the group only after retiring the uid, so the sampler, which
    # reads the group many times a millisecond, reads it after the kill: its
    # peak, a high-water mark, at the bound (within a 2 MiB huge page whose
    # charge the bound refused) and never past it, and its kill counted.
    peak = sampler.group_peak()
    events = sampler.last_events()
    expect(peak is not None and bound - 2 * MIB <= peak <= bound,
           f"detection: the group's peak {mib(peak)} ({peak} bytes{', the bound exactly' if peak == bound else ''}) reached "
           "the bound and never passed it", sampler.samples[-5:])
    expect(events.get("oom", 0) >= 1 and events.get("oom_kill", 0) >= 1,
           f"detection: the group's own counters count the kill ({events})", sampler.samples[-5:])

    # Durable settlement: the service reported the runner's exit holding the
    # formula's attempt and every child's, ended at its own bound.
    expect(len(exits) == 1 and exits[0]["args"]["runner"] == runner["runner"] and exits[0]["report"]["service"] == SERVICE
           and exits[0]["answered"] == "ok" and set(exits[0]["attempts"]) == attempts
           and len(exits[0]["attempts"]) == len(attempts) and exits[0]["args"].get("memory") == "cap",
           f"settlement: the service reported runner {runner['runner']}'s exit once, {exits[0]['at'] - ending['let_at']:.2f} s "
           f"after child {n_last} was let, holding the formula's attempt and its {count} children's, ended at its own "
           "memory bound", {"exits": exits, "attempts": sorted(attempts)})
    wait_until(lambda: stack.runners()["busy"] == 1 and stack.runners()["tainted"] == 0, 10,
               "the formula's runner to leave the pool, the sibling alone busy")
    expect(not attempts & set(stack.attempts()), "settlement: the service holds none of the formula's attempts", stack.attempts())

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
    print(f"Docker's OOMKilled flag for the container: {flag_before} before the children took their memory, "
          f"{oom_killed_flag(stack)} after", flush=True)

    # The sibling kept its process, and its group, which took nothing of the
    # formula's children, and completes. The group is read while the sibling
    # still holds its runner: once it completes, its runner is idle and
    # retired after the service's idle time, which may be shorter than the
    # read.
    expect(stack.runner_process(sibling_runner["runner"]) is not None
           and stack.runner_process(sibling_runner["runner"])["pid"] == sibling_runner["pid"],
           "the sibling's runner kept its process through the formula's runner's end", stack.runner_processes())
    sibling_group = read_group(stack, sibling_runner["uid"])
    expect(sibling_group is not None and sibling_group["peak"] < bound,
           f"the sibling's group peaked at {mib(sibling_group and sibling_group['peak'])}, under its bound", sibling_group)
    release_sibling.set()
    complete = terminal(plane, sibling["execution_id"], BOOT_S)
    expect(complete["op"] == "complete" and complete["args"]["outcome"]["output"] == {"sibling": "alive"},
           "the sibling completed", complete)

    # The uid, next given to a runner, holds nothing of the ended one.
    reused = reuse_uid(stack, plane, runner)
    expect(reused["runner"] != runner["runner"] and reused["home"] != runner["home"],
           f"the uid {runner['uid']} was given to a new runner ({reused['runner']}) with a home of its own", [runner, reused])
    expect(reused["group"]["max"] == str(bound) and reused["group"]["peak"] < bound // 2 and reused["group"]["events"]["oom_kill"] == 0,
           f"its group is its own: bound {reused['group']['max']}, peak {mib(reused['group']['peak'])}, no kill counted",
           reused["group"])
    expect([r for r in plane.seen() if r.get("runner") == runner["runner"] and r["at"] > gone] == []
           and all(r["runner"] != runner["runner"] for r in plane.seen("attach") if r["execution_id"] != formula["execution_id"]),
           "the ended runner made no host call after its end, and no later attach presented it")


def fresh_runners_booted(stack, first_seen, settle_s=4.0, busy=0):
    """Whether the pool holds its fresh runners, each booted for `settle_s`, and `busy` busy ones."""
    now = time.monotonic()
    live = {r["runner"] for r in stack.runner_processes()}
    for runner in live:
        first_seen.setdefault(runner, now)
    counts = stack.runners()
    booted = [r for r in live if now - first_seen[r] >= settle_s]
    return (counts["busy"] == busy and counts["fresh"] >= imagesuite.FLOOR_RUNNERS
            and len(booted) >= imagesuite.FLOOR_RUNNERS + busy)


def reuse_uid(stack, plane, hostile, tries=12):
    """Runs subtrees of new athanors until a runner is given the hostile runner's uid; that runner, its home and group."""
    for n in range(tries):
        for process in stack.runner_processes():
            if process["uid"] == hostile["uid"]:
                return {**process, "group": wait_until(lambda: read_group(stack, process["uid"]), 10, "the new runner's group")}
        attempt = plane.mint(stack.boot, "reagent", ECHO_REF, wasm(ECHO), {"cycle": n}, f"ath_mem_cycle_{n}", 30_000)
        expect(stack.start(attempt)[1] == {"v": 3, "ok": True}, f"a subtree of another athanor starts ({n + 1})")
        terminal(plane, attempt["execution_id"], BOOT_S)
        time.sleep(stack.idle_ttl_ms / 1000 + 0.5)
    sys.exit(f"FAIL: uid {hostile['uid']} was not given to a runner again within {tries} subtrees")


# ---------------------------------------------------------------------------
# No writable cgroup
# ---------------------------------------------------------------------------


def test_bound_unavailable(image, plane):
    """Without writable-cgroups=true cyfr-locus refuses its boot, since no role's group can be made: no runner
    process ever starts, and the container restart-loops."""
    stack = Stack("cyfr-locus-runtime-unbounded", image, plane, writable_cgroups=False)
    try:
        stack.compose("up", "--detach", "--no-build", "--force-recreate", COMPOSE_SERVICE)
        stack.container = stack.compose("ps", "--all", "--quiet", COMPOSE_SERVICE).stdout.strip()
        text = imagesuite.refused_unbounded(stack.container, stack.logs)
        expect(imagesuite.NO_GROUPS in text,
               "cyfr-locus refuses its boot without a writable cgroup, naming what it could not make, and runs no runner",
               text[-2000:])
    finally:
        stack.down()


# ---------------------------------------------------------------------------
# The measurement
# ---------------------------------------------------------------------------


def semver(version):
    """A shipped version's order: its major, minor and patch numbers, as numbers (1.10.0 after 1.9.0)."""
    return tuple(int(part) for part in version.split("-", 1)[0].split("+", 1)[0].split("."))


def seed(kind, name):
    """The newest shipped version of `name`, with a stand-in value for each field its runner is handed: a need
    with an `attach` rule is CYFR's to attach, and its runner is handed nothing for it."""
    base = os.path.join(SEED, f"{kind}s", "local", name)
    version = max(os.listdir(base), key=semver)
    with open(os.path.join(base, version, "cyfr-manifest.json")) as f:
        manifest = json.load(f)
    fields = [field for need in (manifest.get("needs") or {}).values()
              if isinstance(need, dict) and "attach" not in need for field in need.get("fields", [])]
    binary = {"catalyst": "catalyst.wasm", "formula": "formula.wasm", "reagent": "reagent.wasm"}[kind]
    return {"ref": f"{kind}:local.{name}:{version}", "name": name, "type": kind,
            "wasm": wasm(os.path.join(base, version, binary)), "secrets": {f: "sk-memory-measure" for f in fields}}


def chat_request(model):
    """A model turn with a long thread, a tool result and an image: some 600 KB of input."""
    notes = ("The athanor's notes, read back in full so the model sees every line of them. " * 64)[:4_000]
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
    tools = [{"name": f"tool_{i}", "description": "A tool the athanor offers. " * 8,
              "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}} for i in range(40)]
    return {"operation": "chat", "params": {"model": model, "system": "You are the athanor's assistant. " * 20,
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
    """An authority bound to `ref` whose node allows `tasks` concurrent children (`Prima.Authority` on the wire)."""
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
    expect(code == 200 and answer == {"v": 3, "ok": True}, f"{label}: starts", answer)
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
        stack = Stack("cyfr-locus-runtime-memory-measure", image, plane, idle_ttl_ms=3_000)
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
            print(f"round {n + 1}: the keeper group (cyfr-locus and the service) peaked at {mib(keeper['peak'])}", flush=True)
        finally:
            stack.down()
            plane.stop()
    print("--- runner peaks (memory.peak of the runner's own group), over every round")
    for label, peaks in results.items():
        print(f"{label}: {', '.join(mib(p) for p in peaks)} (max {max(peaks)} bytes)")
    largest = max(max(p) for p in results.values())
    least = imagesuite.LEAST_CAP_BYTES["runner"]
    print(f"largest runner peak {largest} bytes ({mib(largest)}), beside a runner's least bound of {least} bytes "
          f"({mib(least)}); the keeper group peaked at {', '.join(mib(p) for p in keeper_peaks)}")


def test_pool_report(stack, plane):
    """The runtime role's report holds a runner's counters alone, the floor's runner counted with time measured, and
    the route refuses the other services' pool keys."""
    key = plane.worker_key

    def floor_counted():
        _boot, counters = imagesuite.pool_reports(stack.base, "runtime", key)
        return [c for c in counters if c["kind"] == "warm" and "athanor" not in c and c["measured_ms"] > 0
                and c["bytes"] > 0]

    counted = wait_until(floor_counted, 30, "the warm floor's runner is counted with time measured", interval=0.5)
    expect(all(c["mib_ms"] > 0 and c["peak_bytes"] >= c["bytes"] for c in counted),
           "a counted runner's MiB-milliseconds and peak follow its readings", counted)
    boot, _ = imagesuite.pool_reports(stack.base, "runtime", key)
    again, _ = imagesuite.pool_reports(stack.base, "runtime", key)
    expect(boot == again, "the keeper's boot is the same from one report to the next", [boot, again])
    imagesuite.pool_refuses_others(stack.base, "runtime", key)
    print("ok: the runtime reports its runners alone, each once, under its own pool key alone", flush=True)


def main(image, cases, rounds):
    if run("docker", "image", "inspect", image, check=False).returncode != 0:
        sys.exit(f"FAIL: prerequisite missing: the image {image} is not built")
    if rounds:
        measure(image, rounds)
        return
    prerequisites()
    plane = ControlPlane(secrets.token_bytes(32), SERVICE).serve()
    try:
        for case in cases:
            if case == "bound":
                stack = Stack("cyfr-locus-runtime-memory", image, plane, idle_ttl_ms=1_000, work_bytes=WORK)
                try:
                    stack.up()
                    test_runner_bound(stack, plane)
                finally:
                    stack.down()
            elif case == "pool":
                stack = Stack("cyfr-locus-runtime-pool", image, plane)
                try:
                    stack.up()
                    test_pool_report(stack, plane)
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
    main(arguments[0], arguments[1:] or ["bound", "pool", "unavailable"], rounds)
