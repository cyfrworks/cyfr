# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The namespace suite's kill of a runner, with docker stubbed, and its measure step's client, service and verdict.

A runner's keeper group counts as removed only on a probe whose successful
exec says so. A failed exec is no answer, whatever its status, and it fails
the kill. The measure step's client speaks the keeper's protocol to a
keeper that answers as cyfr-locus does, beside a stand-in for this
machine's marks, naming no bound on its spawn, and its verdict refuses a
place answered without a runner's bound, a refused assign, a place read under
another owner, a reading at the work taken before the work held its memory
or not holding it, a reading answered only after `released`, and a reading
of a place after `released`. The service's frames reproduce the control
and relay vectors, and the work's verdict refuses an unclean `complete`
and an emit not held for the client.

Usage: python3 -I tests/locus-runtime-image/namespace_test.py
"""

import json
import os
import socket
import subprocess
import sys
import shutil
import tempfile
import threading
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import namespace  # noqa: E402
import stack  # noqa: E402
import imagesuite  # noqa: E402

CONTAINER = "cyfr-locus-runtime-1"
UID = stack.POOL_FIRST
RUNNER = {"pid": 4242, "uid": UID, "home": os.path.join(stack.HOME_ROOT, "runner-a1"), "runner": "a1"}


def docker(group, status=0):
    """`run` standing in for docker. The keeper group is `absent` or `present`, or `failed`: the exec itself exits
    `status` and prints nothing. A probe exits as `test -e` does, and prints its word when it is written with one,
    so the same container reads the same whichever form the code runs. Every other exec succeeds with an empty listing.
    A checked call exits as imagesuite.run's does."""

    def run(*args, check=True, env=None, timeout=None):
        script = args[-1]
        if "test -e" not in script:
            code, out = 0, ""
        elif group == "failed":
            code, out = status, ""
        elif "echo absent" in script:
            code, out = 0, "present\n" if group == "present" else "absent\n"
        else:
            code, out = (0 if group == "present" else 1), ""
        if check and code != 0:
            sys.exit(f"FAIL: {' '.join(args)} exited {code}")
        return subprocess.CompletedProcess(args, code, out, "" if code == 0 else "daemon error")

    return run


def settle(predicate, timeout, what, interval=None):
    """The kill's waits, each read once: a predicate that is not met at once is a timeout."""
    if predicate():
        return True
    sys.exit(f"FAIL: timed out after {timeout}s waiting for {what}")


class KillRunner(unittest.TestCase):
    def kill(self, group, status=0):
        fake = docker(group, status)
        for module in (stack, imagesuite):
            patch = mock.patch.object(module, "run", fake)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(namespace, "wait_until", settle)
        patch.start()
        self.addCleanup(patch.stop)
        observed = namespace.IsolatedStack.__new__(namespace.IsolatedStack)
        observed.container = CONTAINER
        namespace.kill_runner(observed, RUNNER, "retired runner")

    def test_an_absent_group_ends_the_kill(self):
        self.kill("absent")

    def test_a_present_group_does_not_end_the_kill(self):
        with self.assertRaises(SystemExit):
            self.kill("present")

    def test_a_failed_exec_fails_the_kill(self):
        with self.assertRaises(SystemExit):
            self.kill("failed", status=125)

    def test_a_failed_exec_with_status_one_fails_the_kill(self):
        with self.assertRaises(SystemExit):
            self.kill("failed", status=1)


class RunnerFacts(unittest.TestCase):
    """The facts of a runner are read whole from the observer, which must exit 0: a failed read fails the observation
    that reads them, and the facts read are the control."""

    def observed(self, returncode, stdout):
        class Observer:
            def observe(self, script):
                return subprocess.CompletedProcess([], returncode, stdout, "" if returncode == 0 else "daemon error")

        return Observer()

    def test_a_failed_observer_fails_the_runner_facts(self):
        with self.assertRaises(SystemExit):
            namespace.runner_facts(self.observed(1, ""), {"pid": 4242, "uid": UID})

    def test_the_facts_that_were_read_are_the_control(self):
        facts = namespace.runner_facts(self.observed(0, f"uid_map={UID} {UID} 1\nfd=3 socket:[9]\n"),
                                       {"pid": 4242, "uid": UID})
        self.assertEqual(facts["uid_map"], f"{UID} {UID} 1")
        self.assertEqual(facts["fds"], {3: "socket:[9]"})


SPAWN_ID = "ab" * 16
V = namespace.V


def memtotal_kb():
    """This machine's MemTotal, in kB, which the client prints."""
    with open("/proc/meminfo") as meminfo:
        return next(int(line.split()[1]) for line in meminfo if line.startswith("MemTotal:"))


# The bound the keeper answers the runner's place with: half of the machine's memory, never under a runner's least.
BOUND = imagesuite.cap_bytes("warm", memtotal_kb() * 1024)


def keeper(sock, requests, marks):
    """A keeper on the client's channel, answering as cyfr-locus does: a place `placed` with a runner's bound, a spawn `spawned`, an assign
    `assigned` under its id; a measure `unmeasured` until the place's first reading, which the first measure finds
    missing, then the reading under the place's owner of the moment, 64 MiB more while the work holds its memory (from
    the mark `holding` to `complete` in `marks`); a measure sent with a release is answered before `exited` and
    `released`, and one after is `unmeasured`. Every request is kept in `requests`."""

    def send(reply):
        sock.sendall(json.dumps(reply, separators=(",", ":")).encode() + b"\n")

    def holding():
        return os.path.exists(os.path.join(marks, "holding")) and not os.path.exists(os.path.join(marks, "complete"))

    owner, measures, releasing, free = None, 0, False, False
    for line in sock.makefile("rb"):
        request = json.loads(line)
        requests.append(request)
        if request["type"] == "place":
            owner = {key: request[key] for key in ("kind", "athanor") if key in request}
            send({"v": V, "type": "placed", "id": request["id"], "memory_bytes": BOUND})
        elif request["type"] == "spawn":
            send({"v": V, "type": "spawned", "id": request["id"], "spawn_id": SPAWN_ID, "uid": UID, "pid": 4242})
        elif request["type"] == "assign":
            owner = {key: request[key] for key in ("kind", "athanor") if key in request}
            send({"v": V, "type": "assigned", "id": request["id"]})
        elif request["type"] == "release":
            releasing = True
        elif request["type"] == "measure":
            measures += 1
            if free or measures == 1:
                send({"v": V, "type": "error", "id": request["id"], "code": "unmeasured"})
            else:
                send({"v": V, "type": "measured", "id": request["id"], **owner, "bytes": (180 << 20) + (64 << 20) * holding(),
                      "lesser": False, "age_ms": 412})
            if releasing:
                send({"v": V, "type": "exited", "spawn_id": SPAWN_ID, "code": None, "signal": "SIGTERM", "memory": None})
                send({"v": V, "type": "released", "spawn_id": SPAWN_ID})
                releasing, free = False, True


def service_marks(marks):
    """This machine's marks as serve_work and the plane leave them: `holding` once the client marks `assigned`, then
    `complete` once it marks `measured`."""
    for theirs, ours in (("assigned", "holding"), ("measured", "complete")):
        stack.wait_until(lambda: os.path.exists(os.path.join(marks, theirs)), 20, f"the client's mark {theirs}")
        open(os.path.join(marks, ours), "w").close()


class PlacesClient(unittest.TestCase):
    """The measure step's client, run by this machine's /bin/sh against a keeper on its fd 3, and the verdict on what it read."""

    @classmethod
    def setUpClass(cls):
        marks = tempfile.mkdtemp(prefix="cyfr-marks-")
        parent, child = socket.socketpair()
        script = namespace.places_client(namespace.RUNNER_ENV, marks=marks, client_marks=marks)
        process = subprocess.Popen(["/bin/sh", "-c", f"exec 3<&{child.fileno()}\n{script}"], pass_fds=(child.fileno(),),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        child.close()
        cls.requests = []
        serving = threading.Thread(target=keeper, args=(parent, cls.requests, marks), daemon=True)
        serving.start()
        marking = threading.Thread(target=service_marks, args=(marks,), daemon=True)
        marking.start()
        try:
            cls.stdout, cls.stderr = process.communicate(timeout=30)
        finally:
            process.kill()
            serving.join(5)
            marking.join(5)
            parent.close()
            shutil.rmtree(marks, ignore_errors=True)
        cls.returncode = process.returncode
        cls.read = namespace.transcript(cls.stdout)

    def judge(self, read):
        namespace.judge_places(read, {"read": read})

    def fails(self, read, check):
        """The verdict on `read` fails at the check whose message holds `check`."""
        with self.assertRaises(SystemExit) as failed:
            self.judge(read)
        self.assertIn(check, str(failed.exception.code).splitlines()[0])

    def edited(self, step, edit):
        """What the client read, the replies of `step`, which it read together, given in their place by `edit` of them."""
        at = [n for n, (read_in, _) in enumerate(self.read) if read_in == step]
        return self.read[:at[0]] + [(step, reply) for reply in edit([self.read[n][1] for n in at])] + self.read[at[-1] + 1:]

    def test_the_client_speaks_the_protocols_version_and_places_before_its_spawn_naming_no_bound(self):
        self.assertEqual(self.returncode, 0, self.stderr)
        place = namespace.RUNNER
        assign = {"v": V, "type": "assign", "place": place, "athanor": namespace.ATHANOR}
        self.assertEqual([r["type"] for r in self.requests],
                         ["place", "spawn", "measure", "measure", "assign", "measure", "measure", "assign", "measure", "assign",
                          "measure", "release", "measure", "measure"])
        self.assertEqual(self.requests[0], {"v": V, "type": "place", "id": place, "kind": "warm"})
        spawn = self.requests[1]
        self.assertNotIn("isolation", spawn)
        self.assertFalse({"memory_bytes", "cpu_quota"} & spawn.keys(), spawn)
        self.assertEqual({key: spawn[key] for key in ("v", "id", "place", "pool", "argv", "env", "control")},
                         {"v": V, "id": "1", "place": place, "pool": stack.ROLE["pool"], "argv": namespace.RUNNER_ARGV,
                          "env": namespace.RUNNER_ENV, "control": True})
        self.assertEqual([r for r in self.requests if r["type"] == "assign"],
                         [{**assign, "id": "as1", "kind": "run"}, {**assign, "id": "as2", "kind": "warm"},
                          {**assign, "id": "as3", "kind": "run"}])
        self.assertEqual(self.requests[11], {"v": V, "type": "release", "spawn_id": SPAWN_ID, "grace_ms": namespace.RELEASE_GRACE_MS})
        self.assertEqual([r["id"] for r in self.requests if r["type"] == "measure"], [f"m{n}" for n in range(1, 9)])
        self.assertTrue(all(r["place"] == place for r in self.requests if r["type"] == "measure"))

    def test_a_runner_read_under_each_owner_and_free_only_after_released_passes(self):
        self.assertEqual([step for step, _ in self.read],
                         ["memtotal", "placed", "spawned", "fresh", "fresh", "assigned.assign", "assigned", "working", "warm.assign",
                          "warm", "reused.assign", "reused", "release", "release", "release", "after"])
        self.judge(self.read)

    def test_a_place_answered_without_a_runners_bound_fails(self):
        for edit in ({"memory_bytes": BOUND // 2}, {"memory_bytes": None}):
            self.fails(self.edited("placed", lambda got: [{**reply, **edit} for reply in got]), "with a runner's bound")
        self.fails(self.edited("memtotal", lambda got: ["no meminfo"]), "with a runner's bound")

    def test_a_refused_assign_fails(self):
        self.fails(self.edited("warm.assign", lambda got: [{"v": V, "type": "error", "id": got[0]["id"], "code": "bad_request"}]),
                   "before warm, the keeper applied the assign")

    def test_a_reading_at_the_work_under_nobody_or_another_fails(self):
        for edit in ({"kind": "warm"}, {"athanor": "ath_other"}):
            self.fails(self.edited("working", lambda got: [{**reply, **edit} for reply in got]), f"at the work of {namespace.ATHANOR}")
        self.fails(self.edited("working", lambda got: [{k: v for k, v in reply.items() if k != "athanor"} for reply in got]),
                   f"at the work of {namespace.ATHANOR}")

    def test_a_reading_at_the_work_taken_before_it_held_its_memory_fails(self):
        self.fails(self.edited("working", lambda got: [{**reply, "age_ms": namespace.SETTLE_MS} for reply in got]),
                   "the reading at the work was taken while")

    def test_a_reading_at_the_work_without_its_memory_fails(self):
        before = dict(self.read)["assigned"]["bytes"]
        self.fails(self.edited("working", lambda got: [{**reply, "bytes": before} for reply in got]),
                   "the reading at the work was taken while")

    def test_a_reading_under_another_owner_fails(self):
        self.fails(self.edited("assigned", lambda got: [{**reply, "athanor": "ath_other"} for reply in got]),
                   f"assigned a run of {namespace.ATHANOR}")

    def test_a_reading_of_zero_fails(self):
        self.fails(self.edited("reused", lambda got: [{**reply, "bytes": 0} for reply in got]), "reused for another run")

    def test_a_runner_that_ended_before_its_release_fails(self):
        exited = {"v": V, "type": "exited", "spawn_id": SPAWN_ID, "code": 1, "signal": None, "memory": None}
        self.fails(self.edited("warm", lambda got: [exited] + got), "back at rest")

    def test_a_reading_answered_only_after_released_fails(self):
        self.fails(self.edited("release", lambda got: [reply for reply in got if reply["type"] != "measured"]
                               + [reply for reply in got if reply["type"] == "measured"]),
                   "answered before its released")

    def test_a_place_read_after_released_fails(self):
        self.fails(self.edited("after", lambda got: [{"v": V, "type": "measured", "id": got[0]["id"], "kind": "run",
                                                      "athanor": namespace.ATHANOR, "bytes": 1 << 20, "lesser": False,
                                                      "age_ms": 9}]),
                   "the runner's place is free")


class AfterPlaced(unittest.TestCase):
    """The keeper steps' first reply is the place's `placed` with a runner's bound, half of the memory the client
    printed, never under a runner's least; anything else fails the step."""

    def ran(self, memtotal_kb, placed):
        stdout = (f"memtotal:{memtotal_kb}\nreply:{json.dumps(placed)}\n"
                  + 'reply:{"v": 9, "type": "spawned", "id": "1", "spawn_id": "x", "uid": 1, "pid": 2}\n')
        return subprocess.CompletedProcess([], 0, stdout, "")

    def test_the_place_placed_with_half_the_machine_passes_and_the_rest_is_answered(self):
        half = {**namespace.placed(namespace.PLACE, 4 << 30)}
        self.assertEqual([r["type"] for r in namespace.after_placed(self.ran(8 << 20, half), "step")], ["spawned"])

    def test_a_small_machine_bounds_a_runner_at_its_least(self):
        least = namespace.placed(namespace.PLACE, imagesuite.LEAST_CAP_BYTES["runner"])
        namespace.after_placed(self.ran(512 << 10, least), "step")

    def test_another_bound_or_none_fails(self):
        for placed in (namespace.placed(namespace.PLACE, 2 << 30), {"v": V, "type": "placed", "id": namespace.PLACE}):
            with self.subTest(placed=placed), self.assertRaises(SystemExit):
                namespace.after_placed(self.ran(8 << 20, placed), "step")


with open(os.path.join(stack.ROOT, "tests", "fixtures", "runner_control.json")) as f:
    CONTROL = json.load(f)
with open(os.path.join(stack.ROOT, "tests", "fixtures", "runner_relay.json")) as f:
    RELAY = json.load(f)


class ServiceFrames(unittest.TestCase):
    """What serve_work writes and reads reproduces the vectors of Prima.RunnerControl and Prima.RunnerRelay."""

    def test_the_assign_is_the_vectors_line(self):
        vector = CONTROL["valid"][0]
        message = vector["message"]
        keys = message["keys"]
        attempt = {**keys["attempt"], "call_key": bytes.fromhex(keys["call"]), "seal_key": bytes.fromhex(keys["seal"])}
        self.assertEqual(namespace.control_assign(message["assignment"], message["input"], namespace.opened_keys(attempt)),
                         vector["line"].encode() + b"\n")

    def test_a_host_answer_is_the_vectors_frame_and_a_host_call_reads_whole(self):
        call, answer = (json.loads(RELAY["exchange"][n]["json"]) for n in (0, 1))
        self.assertEqual(namespace.relay_frame(answer)[4:], RELAY["exchange"][1]["json"].encode())
        sent = namespace.relay_frame(call) + namespace.relay_frame(answer)
        self.assertEqual(namespace.relay_frames(sent[:-1]), ([call], sent[len(namespace.relay_frame(call)):-1]))
        self.assertEqual(namespace.relay_frames(sent), ([call, answer], b""))


class Work(unittest.TestCase):
    """The work's verdict on what this machine served and the plane's calls."""

    ATTEMPT = {"execution_id": "exec_measured"}

    def served(self, clean=True, entered=True):
        execution_id = self.ATTEMPT["execution_id"]
        event = {"v": 1, "type": "event", "name": "engine.authority_entered", "measurements": {},
                 "metadata": {"execution_id": execution_id, "reference": namespace.HOG_REF}}
        complete = {"v": 1, "type": "complete", "execution_id": execution_id, "clean": clean}
        control = [json.dumps(frame, separators=(",", ":")) for frame in ([event] if entered else []) + [complete]]
        return {"relay": list(namespace.WORK_CALLS), "control": control, "stderr": b""}

    def calls(self, let=True):
        calls = [{"op": op, "answered": "ok", "runner": namespace.RUNNER, "args": {}} for op in namespace.WORK_CALLS]
        calls[2]["events"], calls[3]["events"] = namespace.WORK_EVENTS
        if let:
            calls[3]["let"] = True
        calls[4]["args"] = {"outcome": {"output": {"status": 200, "data": {"held": namespace.HOG_BYTES}}}}
        return calls

    def test_work_run_whole_and_completed_clean_passes(self):
        namespace.judge_work(self.served(), self.calls(), self.ATTEMPT)

    def test_an_unclean_complete_fails(self):
        with self.assertRaises(SystemExit) as failed:
            namespace.judge_work(self.served(clean=False), self.calls(), self.ATTEMPT)
        self.assertIn("complete and clean", str(failed.exception.code).splitlines()[0])

    def test_a_control_stream_without_the_authoritys_event_fails(self):
        with self.assertRaises(SystemExit) as failed:
            namespace.judge_work(self.served(entered=False), self.calls(), self.ATTEMPT)
        self.assertIn("entered the work's authority", str(failed.exception.code).splitlines()[0])

    def test_an_emit_not_held_for_the_client_fails(self):
        with self.assertRaises(SystemExit) as failed:
            namespace.judge_work(self.served(), self.calls(let=False), self.ATTEMPT)
        self.assertIn("was held until the client had read it", str(failed.exception.code).splitlines()[0])


if __name__ == "__main__":
    unittest.main()
