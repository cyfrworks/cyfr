#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The Opus image ends its runners as the contract says, run as
docker-compose.yml's opus service against a scripted control plane.

Each case is observed three ways, and each is asserted on its own: what
the service detected and when (its status counts, its reports, the
runner's own host calls), what the control plane recorded as settled (the
attempt's close, or its absence), and what the operating system shows
inside the container (the runner's process gone, its uid free, its home
scrubbed, the container's CPU flat).

- A spinning WASM guest assigned with a short deadline is killed at the
  bound: the runner process is gone within the watchdog grace and CPU
  stays flat afterwards.
- A sibling subtree in another runner completes while the first is
  killed, and its runner survives.
- Killing the service's VM ends every runner with it (cyfr-spawn retires
  every spawn when its client dies), the container restarts, and the new
  boot inherits nothing.
- With the control plane cut, a running attempt keeps running to its
  deadline and settles there: the runner stops, is retired, and the
  service tried to report it; nothing of it reaches the control plane
  when it returns.
- A child CYFR admits late, after its parent's runner was killed, never
  runs: nothing under its keys reaches the control plane and the service
  never ran it.
- An abandoned stream (the control plane stops answering `push_deltas`)
  is asked once more as the same batch, then lost; the runner is tainted
  and ended after the attempt closes.
- A tainted runner is counted, never reassigned, and its process is gone
  before the next assignment for its athanor takes a fresh one.
- Taking a fresh runner from the pool is quick: its queue age, from the
  start request to the runner's attach, has a p95 of at most one second.

Usage: tests/worker-image/runners.py IMAGE
"""

import json
import os
import re
import secrets
import shutil
import sys
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import worker_auth as auth  # noqa: E402
from control_plane import DROP, ControlPlane  # noqa: E402
from stack import (  # noqa: E402
    HOME_ROOT, POOL_FIRST, POOL_LAST, ROOT, SERVICE, SERVICE_UID, SPAWNER_CAPS, Stack, StatusSampler, expect, run, wait_until,
)

FIXTURES = {
    "spin": os.path.join(ROOT, "apps", "opus", "test", "support", "test_wasm", "spin.wasm"),
    "echo": os.path.join(ROOT, "apps", "opus", "test", "support", "test_wasm", "echo.wasm"),
    "stub": os.path.join(ROOT, "apps", "cyfr", "test", "support", "test_wasm", "step_stub", "step_stub.wasm"),
    "probe": os.path.join(ROOT, "apps", "cyfr", "test", "integration", "opus", "support", "test_wasm", "nested_probe", "nested_probe.wasm"),
}
REFS = {
    "spin": "reagent:local.spin:0.1.0",
    "echo": "reagent:local.echo:0.1.0",
    "stub": "catalyst:local.step-stub:0.1.0",
    "probe": "formula:local.nested-probe:0.1.0",
}
STUB_KEY = {"STUB_API_KEY": "sk-worker-image-test"}
# A runner is a VM booting from nothing: its first attach takes seconds.
BOOT_S = 60
# cyfr-spawn gives every spawn a second when its client dies (lostGrace).
LOST_GRACE_S = 1.0

WASM = {}


def prerequisites(image):
    for tool in ("docker",):
        if shutil.which(tool) is None:
            sys.exit(f"FAIL: prerequisite missing: {tool} is not on PATH")
    if run("docker", "compose", "version", check=False).returncode != 0:
        sys.exit("FAIL: prerequisite missing: docker compose does not answer")
    if run("docker", "image", "inspect", image, check=False).returncode != 0:
        sys.exit(f"FAIL: prerequisite missing: the image {image} is not built")
    for name, path in FIXTURES.items():
        if not os.path.isfile(path):
            sys.exit(f"FAIL: prerequisite missing: the {name} guest {path}")
        with open(path, "rb") as f:
            WASM[name] = f.read()
    vectors = os.path.join(ROOT, "tests", "fixtures", "worker_auth.json")
    if not os.path.isfile(vectors):
        sys.exit(f"FAIL: prerequisite missing: {vectors}")
    auth.check_vectors(vectors)
    print("ok: the control plane reproduces every vector of tests/fixtures/worker_auth.json", flush=True)


def ms(seconds):
    return round(seconds * 1000, 1)


def percentile(values, p):
    ordered = sorted(values)
    index = max(int(-(-p * len(ordered) // 100)) - 1, 0)
    return ordered[index]


# ---------------------------------------------------------------------------
# Runner observations
# ---------------------------------------------------------------------------


def attached_runner(stack, plane, attempt, timeout=BOOT_S):
    """The runner that attached the attempt: its id, OS pid, uid and home, once its process is found."""
    attach = plane.wait_seen("attach", attempt["execution_id"], timeout)[0]
    process = wait_until(lambda: stack.runner_process(attach["runner"]), 10, f"the process of runner {attach['runner']}")
    return {**process, "attach": attach}


def uid_gone(stack, uid):
    return stack.uid_processes(uid) == []


def wait_gone(stack, runner, timeout, what):
    """When the runner's uid held no process any more, as wall-clock seconds."""
    return wait_until(lambda: uid_gone(stack, runner["uid"]) and time.time(), timeout, what)


def home_scrubbed(stack, runner):
    return os.path.basename(runner["home"]) not in stack.homes()


def os_cleanup(stack, runner, label):
    """The three OS facts of a retired runner: uid free, home scrubbed, no process of it."""
    expect(stack.uid_processes(runner["uid"]) == [], f"{label}: no process of uid {runner['uid']} remains", stack.processes())
    expect(home_scrubbed(stack, runner), f"{label}: its home {runner['home']} is scrubbed", stack.homes())


def exit_reports(plane, attempt, timeout):
    """The exit reports naming the attempt, once the first has arrived."""
    named = lambda: [r for r in plane.seen("runner_exited") if attempt["attempt"] in r["attempts"]]
    return plane.wait_for(named, timeout, f"an exit report naming {attempt['attempt']}")


def since(stack, plane, execution_id, t):
    return [r for r in plane.seen(None, execution_id) if r["t"] > t]


# ---------------------------------------------------------------------------
# The cases
# ---------------------------------------------------------------------------


def test_process_model(stack):
    procs = stack.processes()
    spawner = [p for p in procs if p["cmd"].startswith("cyfr-spawn serve")]
    service = [p for p in procs if p["uids"][0] == SERVICE_UID and "beam.smp" in p["cmd"]]
    runners = stack.runner_processes()
    expect(len(spawner) == 1 and spawner[0]["uids"] == [0, 0, 0, 0] and spawner[0]["cap_eff"] == SPAWNER_CAPS,
           "cyfr-spawn runs as root holding exactly SETUID, SETGID and KILL", procs)
    expect(len(service) == 1 and [p for p in procs if p["pid"] == service[0]["pid"]][0]["cap_eff"] == "0000000000000000",
           "the service runs as opus with no capability", procs)
    expect(len(runners) == stack.pool_size and all(POOL_FIRST <= r["uid"] <= POOL_LAST for r in runners)
           and len({r["uid"] for r in runners}) == len(runners) and all(r["runner"] for r in runners),
           f"{stack.pool_size} fresh runners run ahead, each a VM under a pooled uid of its own", runners)
    homes = stack.homes()
    expect(sorted(homes) == sorted(os.path.basename(r["home"]) for r in runners),
           "the home root holds exactly the fresh runners' homes", {"homes": homes, "runners": runners})
    expect(all(r["cap_eff"] == "0000000000000000" for r in procs if r["uids"][0] in {x["uid"] for x in runners}),
           "a runner holds no capability", procs)


def test_spinning_guest_killed_at_bound(stack, plane):
    timeout_ms = 2_000
    attempt = plane.mint(stack.boot, "reagent", REFS["spin"], WASM["spin"], {"spin": True}, "ath_spin", timeout_ms)
    code, answer = stack.start(attempt)
    expect(code == 200 and answer == {"ok": True}, "a spinning guest with a 2 s deadline starts", answer)
    runner = attached_runner(stack, plane, attempt)
    share = stack.cpu_share(1.0)
    expect(share >= 0.5, f"the guest spins: the container uses {share:.2f} of a CPU over 1 s", share)

    # Detection: the attempt's own timeout kills the component call and
    # closes the attempt failed as abandoned, at the deadline.
    fail = plane.wait_seen("fail", attempt["execution_id"], timeout_ms / 1000 + 5)[0]
    outcome = fail["args"]["outcome"]
    offset_ms = fail["at"] * 1000 - attempt["deadline"]
    # The budget is what was left of the deadline when the runner received
    # the assignment, so the sentence names a little under the timeout.
    budget = re.fullmatch(r"Execution timeout after (\d+)ms", outcome["error"])
    expect(outcome["abandoned"] is True and budget and timeout_ms - 1_000 <= int(budget.group(1)) <= timeout_ms
           and -500 <= offset_ms <= 1_500,
           f"detection: the runner closed the attempt failed, abandoned ({outcome['error']}), {offset_ms:+.0f} ms from its deadline", fail)
    gone_at = wait_gone(stack, runner, stack.watchdog_grace_ms / 1000 + stack.release_grace_ms / 1000 + 4,
                        "the spinning runner's process to be gone")
    gone_ms = gone_at * 1000 - attempt["deadline"]
    bound_ms = stack.watchdog_grace_ms + stack.release_grace_ms
    expect(gone_ms <= bound_ms + 4_000,
           f"detection: the runner's process was gone {gone_ms:.0f} ms after the deadline (watchdog grace {stack.watchdog_grace_ms} ms, release grace {stack.release_grace_ms} ms)",
           gone_ms)
    wait_until(lambda: stack.runners()["busy"] == 0 and stack.runners()["tainted"] == 0, 10, "the pool to hold no busy or tainted runner")

    # Durable settlement: the close the control plane recorded is the one
    # failure, answered; nothing else closed or reported the attempt.
    expect(fail["answered"] == "ok" and plane.seen("complete", attempt["execution_id"]) == []
           and [r for r in plane.seen("runner_exited") if attempt["attempt"] in r["attempts"]] == [],
           "settlement: the attempt closed failed once, and no exit report names it", plane.seen(None, attempt["execution_id"]))
    expect(stack.attempts() == [], "settlement: the service holds no attempt", stack.attempts())

    # OS cleanup: the process, its uid, its home and its CPU.
    os_cleanup(stack, runner, "cleanup")
    share = stack.cpu_share(2.0)
    expect(share <= 0.25, f"cleanup: the container's CPU is flat afterwards ({share:.2f} of a CPU over 2 s)", share)
    return runner


def test_sibling_survives(stack, plane):
    spinner = plane.mint(stack.boot, "reagent", REFS["spin"], WASM["spin"], {"spin": True}, "ath_sib_spin", 2_000)
    sibling = plane.mint(stack.boot, "reagent", REFS["echo"], WASM["echo"], {"sibling": "alive"}, "ath_sib_echo", 10_000)
    expect(stack.start(spinner)[1] == {"ok": True} and stack.start(sibling)[1] == {"ok": True},
           "a spinning guest and a sibling echo start in two runners")
    spin_runner = attached_runner(stack, plane, spinner)
    echo_runner = attached_runner(stack, plane, sibling)
    expect(spin_runner["uid"] != echo_runner["uid"], "the two subtrees run under different uids", [spin_runner, echo_runner])

    complete = plane.wait_seen("complete", sibling["execution_id"], BOOT_S)[0]
    fail = plane.wait_seen("fail", spinner["execution_id"], 10)[0]
    expect(complete["args"]["outcome"]["output"] == {"sibling": "alive"} and complete["t"] < fail["t"] + 1,
           f"detection: the sibling completed {ms(fail['t'] - complete['t'])} ms before the spinner was killed", [complete, fail])
    wait_gone(stack, spin_runner, 10, "the spinner's process to be gone")
    expect(stack.runner_process(echo_runner["runner"]) is not None and not uid_gone(stack, echo_runner["uid"]),
           "cleanup: the sibling's runner survives the spinner's end", stack.runner_processes())
    wait_until(lambda: stack.runners()["idle"] >= 1, 10, "the sibling's runner to be idle for its athanor")
    expect(plane.seen("runner_exited") == [], "settlement: no exit report was needed for either", plane.seen("runner_exited"))
    os_cleanup(stack, spin_runner, "cleanup")


def test_service_death(stack, plane):
    attempt = plane.mint(stack.boot, "reagent", REFS["spin"], WASM["spin"], {"spin": True}, "ath_death", 30_000)
    expect(stack.start(attempt)[1] == {"ok": True}, "a guest with a long deadline starts")
    runner = attached_runner(stack, plane, attempt)
    others = [r for r in stack.runner_processes() if r["runner"] != runner["runner"]]
    old_boot, old_homes = stack.boot, stack.homes()
    state = stack.container_state()
    beam = stack.service_beam_pid()
    expect(beam is not None, f"the service's VM is pid {beam}", stack.processes())

    t_kill = time.time()
    stack.exec(f"kill -9 {beam}")
    t_cut = plane.elapsed()
    gone = wait_gone(stack, runner, LOST_GRACE_S + 10, "the busy runner's process to be gone")
    expect(all(uid_gone(stack, r["uid"]) for r in others),
           f"detection: every runner was retired {ms(gone - t_kill)} ms after the service's VM died (cyfr-spawn's lost grace is {LOST_GRACE_S} s)",
           stack.runner_processes())

    restarted = wait_until(lambda: (lambda s: s if s["restarts"] > state["restarts"] and s["running"] else None)(stack.container_state()),
                           60, "the container to restart")
    stack.wait_listener()
    expect(stack.boot != old_boot, f"detection: the restarted service is a new boot ({stack.boot}) after restart {restarted['restarts']}", restarted)
    stack.wait_pool()
    expect(stack.attempts() == [], "settlement: the new boot holds no attempt", stack.attempts())
    code, answer = stack.kill(attempt["execution_id"])
    expect(answer == {"error": "not_found"}, "settlement: the new boot never ran the old attempt (its kill is not found)", answer)
    time.sleep(2)
    expect(since(stack, plane, attempt["execution_id"], t_cut) == []
           and [r for r in plane.seen("runner_exited") if r["t"] > t_cut] == [],
           "settlement: nothing of the old boot reached the control plane after it died", plane.seen())
    fresh = stack.runner_processes()
    expect(sorted(stack.homes()) == sorted(os.path.basename(r["home"]) for r in fresh) and not set(old_homes) & set(stack.homes()),
           "cleanup: the home root holds only the new boot's fresh homes", {"before": old_homes, "after": stack.homes()})
    expect({r["runner"] for r in fresh}.isdisjoint({runner["runner"]} | {o["runner"] for o in others}),
           "cleanup: the new boot's runners are new", fresh)


def test_control_plane_cut(stack, plane):
    timeout_ms = 6_000
    attempt = plane.mint(stack.boot, "reagent", REFS["spin"], WASM["spin"], {"spin": True}, "ath_cut", timeout_ms)
    expect(stack.start(attempt)[1] == {"ok": True}, "a guest with a 6 s deadline starts")
    runner = attached_runner(stack, plane, attempt)
    plane.stop()
    t_cut = plane.elapsed()
    port = plane.port

    # The runner keeps running while its deadline and lease hold.
    until_deadline = attempt["deadline"] / 1000 - time.time() - 1.0
    if until_deadline > 0:
        time.sleep(until_deadline)
    expect(not uid_gone(stack, runner["uid"]), "detection: the runner kept running with the control plane down, its deadline not yet reached")
    gone = wait_gone(stack, runner, timeout_ms / 1000 + stack.watchdog_grace_ms / 1000 + stack.release_grace_ms / 1000 + 6,
                     "the runner's process to be gone")
    after_deadline_ms = gone * 1000 - attempt["deadline"]
    before_lease_ms = attempt["lease_until"] - gone * 1000
    expect(after_deadline_ms >= -500 and before_lease_ms > 0,
           f"detection: the runner stopped {after_deadline_ms:.0f} ms after its deadline, {before_lease_ms:.0f} ms before its lease expired", {"gone": gone})
    # The report is tried twice, and its failure is logged once both were
    # refused at the socket.
    unreported = f"the exit of runner {runner['runner']}"
    wait_until(lambda: any(unreported in line and "was not reported" in line for line in stack.logs().splitlines()),
               30, "the service to give up reporting the runner's exit", interval=1.0)
    expect(True, f"detection: the service tried to report the runner's exit and gave up {ms(time.time() - gone)} ms after the runner stopped")

    plane.port = port
    plane.serve()
    wait_until(lambda: stack.status()[0] == 200, 10, "the service to be reachable again")
    expect(stack.status()[1]["ok"]["boot"] == stack.boot, "the service survived the cut on the same boot")
    wait_until(lambda: stack.runners()["busy"] == 0 and stack.runners()["tainted"] == 0, 10, "no busy or tainted runner")
    time.sleep(2)
    expect(since(stack, plane, attempt["execution_id"], t_cut) == []
           and [r for r in plane.seen("runner_exited") if r["t"] > t_cut] == [] and stack.attempts() == [],
           "settlement: the attempt's close and the runner's exit report never reached the control plane; the service holds nothing of it",
           plane.seen())
    os_cleanup(stack, runner, "cleanup")


def test_late_child_refused(stack, plane):
    parent = plane.mint(stack.boot, "formula", REFS["probe"], WASM["probe"],
                        {"op": "call", "request": {"tool": "execution", "action": "run", "args": {"reference": REFS["echo"], "input": {"child": 1}}}},
                        "ath_child", 30_000, intercepted=("execution.run", "execution.run_stream"))
    child = plane.mint(stack.boot, "reagent", REFS["echo"], WASM["echo"], {"child": 1}, "ath_child", 30_000, parent=parent)
    release = threading.Event()
    answer_child = plane.child_answer(child)

    def held(args, caller, entry):
        entry["held"] = True
        release.wait(30)
        entry["released_t"] = plane.elapsed()
        return answer_child(args, caller, entry)

    plane.script("admit_child", held, parent["execution_id"])
    expect(stack.start(parent)[1] == {"ok": True}, "a formula that asks for one child starts")
    runner = attached_runner(stack, plane, parent)
    admit = plane.wait_seen("admit_child", parent["execution_id"], BOOT_S)[0]
    expect(admit["args"]["reference"] == REFS["echo"], "the formula asked the control plane to admit its child", admit)

    code, answer = stack.kill(parent["execution_id"])
    expect(answer == {"ok": True}, "the parent is killed while its admission is pending", answer)
    exited = exit_reports(plane, parent, 15)
    gone = wait_gone(stack, runner, stack.release_grace_ms / 1000 + 10, "the parent's runner process to be gone")
    expect(exited and exited[0]["report"]["service"] == SERVICE and exited[0]["args"]["runner"] == runner["runner"],
           "detection: the service reported the parent's runner exited holding the parent's attempt", plane.seen("runner_exited"))

    release.set()
    wait_until(lambda: "released_t" in admit, 5, "the held admission to be answered")
    time.sleep(3)
    expect(plane.seen(None, child["execution_id"]) == [],
           f"settlement: the child admitted late (answer {admit.get('answered')}) made no host call", plane.seen(None, child["execution_id"]))
    code, answer = stack.kill(child["execution_id"])
    expect(answer == {"error": "not_found"}, "settlement: the service never ran the child", answer)
    expect(stack.attempts() == [], "settlement: the service holds no attempt", stack.attempts())
    os_cleanup(stack, runner, "cleanup")


def test_abandoned_stream(stack, plane):
    attempt = plane.mint(stack.boot, "catalyst", REFS["stub"], WASM["stub"], {"operation": "chat", "params": {}}, "ath_stream", 30_000, secrets=STUB_KEY)
    plane.script("push_deltas", DROP, attempt["execution_id"])
    sampler = StatusSampler(stack).start()
    expect(stack.start(attempt)[1] == {"ok": True}, "a streaming catalyst starts, its stream answered nothing")
    runner = attached_runner(stack, plane, attempt)
    complete = plane.wait_seen("complete", attempt["execution_id"], BOOT_S)[0]
    gone = wait_gone(stack, runner, stack.release_grace_ms / 1000 + 10, "the tainted runner's process to be gone")
    samples = sampler.stop()

    pushes = plane.seen("push_deltas", attempt["execution_id"])
    batches = [json.dumps(p["args"]["deltas"], sort_keys=True) for p in pushes]
    pairs = all(batches[i] == batches[i + 1] for i in range(0, len(batches) - 1, 2))
    nonces = {p["caller"]["nonce"] for p in pushes}
    expect(len(pushes) >= 2 and len(pushes) % 2 == 0 and pairs and len(nonces) == len(pushes),
           f"detection: each of the {len(pushes) // 2} batches was pushed twice as the same batch under fresh nonces, then lost", batches)
    expect(all(p["answered"] == "dropped" for p in pushes), "detection: none of them was answered", pushes)
    expect(sampler.max_of("tainted") >= 1 or gone,
           f"detection: the runner was tainted (at most {sampler.max_of('tainted')} counted at once) and ended {ms(gone - complete['at'])} ms after the attempt closed",
           samples[-5:])
    output = complete["args"]["outcome"]["output"]
    expect(complete["answered"] == "ok" and isinstance(output, dict) and output.get("status") == 200,
           "settlement: the attempt closed completed with the guest's answer, its stream lost", complete)
    expect([r for r in plane.seen("runner_exited") if attempt["attempt"] in r["attempts"]] == [] and stack.attempts() == [],
           "settlement: no exit report names the attempt, and the service holds none", plane.seen("runner_exited"))
    os_cleanup(stack, runner, "cleanup")

    plane.unscript("push_deltas", attempt["execution_id"])
    again = plane.mint(stack.boot, "catalyst", REFS["stub"], WASM["stub"], {"operation": "chat", "params": {}}, "ath_stream", 30_000, secrets=STUB_KEY)
    expect(stack.start(again)[1] == {"ok": True}, "the athanor's next streaming catalyst starts")
    fresh = attached_runner(stack, plane, again)
    complete = plane.wait_seen("complete", again["execution_id"], BOOT_S)[0]
    pushes = plane.wait_seen("push_deltas", again["execution_id"], 5)
    expect(fresh["runner"] != runner["runner"] and all(p["answered"] == "ok" for p in pushes) and complete["answered"] == "ok",
           f"a fresh runner ran it, its {len(pushes)} deltas each answered once", pushes)
    return runner


def test_tainted_never_reassigned(stack, plane, tries=3):
    """A runner is tainted only from its kill to its retirement, which the
    keeper finishes within tens of milliseconds, so the count is looked for
    in up to `tries` kills; every other assertion holds in each."""
    for n in range(1, tries + 1):
        if tainted_runner_case(stack, plane, f"ath_taint_{n}", last=n == tries):
            return
        stack.wait_pool()


def tainted_runner_case(stack, plane, athanor, last):
    attempt = plane.mint(stack.boot, "reagent", REFS["spin"], WASM["spin"], {"spin": True}, athanor, 30_000)
    expect(stack.start(attempt)[1] == {"ok": True}, "a guest starts for an athanor")
    runner = attached_runner(stack, plane, attempt)
    sampler = StatusSampler(stack).start()
    t_kill = time.time()
    code, answer = stack.kill(attempt["execution_id"])
    expect(answer == {"ok": True}, "its root is killed", answer)
    exited = exit_reports(plane, attempt, 15)
    gone = wait_gone(stack, runner, stack.release_grace_ms / 1000 + 10, "the killed runner's process to be gone")
    wait_until(lambda: stack.runners()["tainted"] == 0 and stack.runners()["busy"] == 0, 10, "the tainted runner to leave the pool")
    samples = sampler.stop()
    time.sleep(0.5)
    exited = [r for r in plane.seen("runner_exited") if attempt["attempt"] in r["attempts"]]
    counted = sampler.max_of("tainted") >= 1
    if counted or last:
        expect(counted,
               f"detection: the status counted the runner tainted ({len(samples)} samples over {ms(samples[-1][0] - samples[0][0])} ms), gone {ms(gone - t_kill)} ms after the kill",
               [s[1] for s in samples])
    else:
        print(f"note: the tainted count fell between {len(samples)} status samples; killing another runner", flush=True)
    expect(len(exited) == 1 and exited[0]["args"]["runner"] == runner["runner"] and exited[0]["answered"] == "ok",
           "settlement: the service reported the runner's exit once, holding the attempt", plane.seen("runner_exited"))
    expect(stack.kill(attempt["execution_id"])[1] == {"ok": True} and plane.seen("complete", attempt["execution_id"]) == [],
           "settlement: a second kill is ok again, and the attempt never closed", plane.seen(None, attempt["execution_id"]))

    next_attempt = plane.mint(stack.boot, "reagent", REFS["echo"], WASM["echo"], {"after": "taint"}, athanor, 10_000)
    expect(stack.start(next_attempt)[1] == {"ok": True}, "the athanor's next subtree starts")
    fresh = attached_runner(stack, plane, next_attempt)
    plane.wait_seen("complete", next_attempt["execution_id"], BOOT_S)
    expect(fresh["runner"] != runner["runner"] and fresh["uid"] != runner["uid"] or fresh["pid"] != runner["pid"],
           f"the tainted runner {runner['runner']} was never reassigned: a fresh one ({fresh['runner']}) ran the next subtree", [runner, fresh])
    expect(all(r["runner"] != runner["runner"] for r in plane.seen("attach")[1:] if r["execution_id"] != attempt["execution_id"]),
           "no later attach presented the tainted runner")
    os_cleanup(stack, runner, "cleanup")
    return counted


def fresh_runners_booted(stack, first_seen, settle_s=4.0):
    """Whether the pool is full of fresh runners whose VMs have had `settle_s`
    to boot and nothing idle is left: a runner counts as fresh from its
    spawn, seconds before its VM reads its first assignment."""
    now = time.monotonic()
    live = {r["runner"] for r in stack.runner_processes()}
    for runner in live:
        first_seen.setdefault(runner, now)
    counts = stack.runners()
    booted = [r for r in live if now - first_seen[r] >= settle_s]
    return counts["idle"] == 0 and counts["busy"] == 0 and counts["fresh"] >= stack.pool_size and len(booted) >= stack.pool_size


def measure_acquisition(stack, plane, count=12):
    """Queue age: from the start request to the runner's attach, with the
    pool's fresh runners booted. The service is recreated with a short idle
    time, so each distinct athanor's runner is retired before the next start
    and the eight uids are never exhausted."""
    stack.idle_ttl_ms = 300
    stack.up()
    fresh_ages, warm_ages, first_seen = [], [], {}
    for i in range(count):
        wait_until(lambda: fresh_runners_booted(stack, first_seen), BOOT_S, "the pool's fresh runners to have booted", interval=0.25)
        attempt = plane.mint(stack.boot, "reagent", REFS["echo"], WASM["echo"], {"n": i}, f"ath_queue_{i}", 10_000)
        t_send = time.time()
        expect(stack.start(attempt)[1] == {"ok": True}, f"queued start {i + 1}")
        attach = plane.wait_seen("attach", attempt["execution_id"], BOOT_S)[0]
        fresh_ages.append((attach["at"] - t_send) * 1000)
        plane.wait_seen("complete", attempt["execution_id"], BOOT_S)
    for i in range(count):
        attempt = plane.mint(stack.boot, "reagent", REFS["echo"], WASM["echo"], {"n": i}, "ath_queue_warm", 10_000)
        if i:
            wait_until(lambda: stack.runners()["idle"] >= 1, 5, "the athanor's runner to be idle", interval=0.01)
        t_send = time.time()
        expect(stack.start(attempt)[1] == {"ok": True}, f"warm start {i + 1}")
        attach = plane.wait_seen("attach", attempt["execution_id"], BOOT_S)[0]
        warm_ages.append((attach["at"] - t_send) * 1000)
        plane.wait_seen("complete", attempt["execution_id"], BOOT_S)
    report = {
        "fresh": {"p50": round(percentile(fresh_ages, 50), 1), "p95": round(percentile(fresh_ages, 95), 1), "max": round(max(fresh_ages), 1)},
        "warm": {"p50": round(percentile(warm_ages, 50), 1), "p95": round(percentile(warm_ages, 95), 1), "max": round(max(warm_ages), 1)},
    }
    print(f"queue age (ms): fresh runner {report['fresh']}; idle runner of the athanor {report['warm']}", flush=True)
    expect(report["fresh"]["p95"] <= 1_000, f"fresh-runner acquisition p95 is {report['fresh']['p95']} ms (at most 1000)", report)
    return report


def main(image):
    prerequisites(image)
    plane = ControlPlane(secrets.token_bytes(32), SERVICE).serve()
    stack = Stack("cyfr-opus-runners", image, plane)
    try:
        stack.up()
        print(f"the service runs boot {stack.boot} with a pool of {stack.pool_size}, watchdog grace {stack.watchdog_grace_ms} ms, release grace {stack.release_grace_ms} ms", flush=True)
        test_process_model(stack)
        test_spinning_guest_killed_at_bound(stack, plane)
        test_sibling_survives(stack, plane)
        test_tainted_never_reassigned(stack, plane)
        test_abandoned_stream(stack, plane)
        test_late_child_refused(stack, plane)
        test_control_plane_cut(stack, plane)
        test_service_death(stack, plane)
        measure_acquisition(stack, plane)
        # The runners spawned behind the last starts are VMs still booting.
        settled = {}
        wait_until(lambda: fresh_runners_booted(stack, settled, settle_s=6.0), BOOT_S, "the pool to settle", interval=0.5)
        share = stack.cpu_share(2.0)
        expect(share <= 0.25, f"the container's CPU is flat at the end ({share:.2f} of a CPU over 2 s)", share)
    finally:
        stack.down()
        plane.stop()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
