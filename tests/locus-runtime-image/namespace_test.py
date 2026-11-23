# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The namespace suite's kill of a runner, with docker stubbed, and its measure step's client and verdict.

A runner's keeper group counts as removed only on a probe whose successful
exec says so. A failed exec is no answer, whatever its status, and it fails
the kill. The measure step's client speaks keeper protocol 3 to a keeper
that answers as cyfr-locus does, and its verdict refuses a refused assign,
a place read under another owner, a reading answered only after
`released`, and a reading of a place after `released`.

Usage: python3 -I tests/locus-runtime-image/namespace_test.py
"""

import json
import os
import socket
import subprocess
import sys
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


def keeper(sock, requests):
    """A keeper on the client's channel, answering as cyfr-locus does: a place `placed`, a spawn `spawned`, an assign
    `assigned` under its id; a measure `unmeasured` until the place's first reading, which the first measure finds missing, then the
    reading under the place's owner of the moment; a measure sent with a release is answered before `exited` and
    `released`, and one after is `unmeasured`. Every request is kept in `requests`."""

    def send(reply):
        sock.sendall(json.dumps(reply, separators=(",", ":")).encode() + b"\n")

    owner, measures, releasing, free = None, 0, False, False
    for line in sock.makefile("rb"):
        request = json.loads(line)
        requests.append(request)
        if request["type"] == "place":
            owner = {key: request[key] for key in ("kind", "athanor") if key in request}
            send({"v": 3, "type": "placed", "id": request["id"]})
        elif request["type"] == "spawn":
            send({"v": 3, "type": "spawned", "id": request["id"], "spawn_id": SPAWN_ID, "uid": UID, "pid": 4242})
        elif request["type"] == "assign":
            owner = {key: request[key] for key in ("kind", "athanor") if key in request}
            send({"v": 3, "type": "assigned", "id": request["id"]})
        elif request["type"] == "release":
            releasing = True
        elif request["type"] == "measure":
            measures += 1
            if free or measures == 1:
                send({"v": 3, "type": "error", "id": request["id"], "code": "unmeasured"})
            else:
                send({"v": 3, "type": "measured", "id": request["id"], **owner, "bytes": 180 << 20, "lesser": False, "age_ms": 412})
            if releasing:
                send({"v": 3, "type": "exited", "spawn_id": SPAWN_ID, "code": None, "signal": "SIGTERM", "memory": None})
                send({"v": 3, "type": "released", "spawn_id": SPAWN_ID})
                releasing, free = False, True


class PlacesClient(unittest.TestCase):
    """The measure step's client, run by this machine's /bin/sh against a keeper on its fd 3, and the verdict on what it read."""

    @classmethod
    def setUpClass(cls):
        parent, child = socket.socketpair()
        script = namespace.places_client({"LANG": "C.UTF-8", **namespace.RUNNER_ENV})
        process = subprocess.Popen(["/bin/sh", "-c", f"exec 3<&{child.fileno()}\n{script}"], pass_fds=(child.fileno(),),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        child.close()
        cls.requests = []
        serving = threading.Thread(target=keeper, args=(parent, cls.requests), daemon=True)
        serving.start()
        try:
            cls.stdout, cls.stderr = process.communicate(timeout=30)
        finally:
            process.kill()
            serving.join(5)
            parent.close()
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

    def test_the_client_speaks_version_3_and_places_before_its_spawn(self):
        self.assertEqual(self.returncode, 0, self.stderr)
        place = namespace.RUNNER
        assign = {"v": 3, "type": "assign", "place": place, "athanor": namespace.ATHANOR}
        self.assertEqual([r["type"] for r in self.requests],
                         ["place", "spawn", "measure", "measure", "assign", "measure", "assign", "measure", "assign", "measure",
                          "release", "measure", "measure"])
        self.assertEqual(self.requests[0], {"v": 3, "type": "place", "id": place, "kind": "warm"})
        spawn = self.requests[1]
        self.assertEqual({key: spawn[key] for key in ("v", "id", "place", "pool", "argv", "env", "memory_bytes", "control", "isolation")},
                         {"v": 3, "id": "1", "place": place, "pool": stack.ROLE["pool"], "argv": namespace.RUNNER_ARGV,
                          "env": {"LANG": "C.UTF-8", **namespace.RUNNER_ENV}, "memory_bytes": namespace.RUNNER_MEMORY_BYTES,
                          "control": True, "isolation": stack.ROLE["isolation"]})
        self.assertEqual([r for r in self.requests if r["type"] == "assign"],
                         [{**assign, "id": "as1", "kind": "run"}, {**assign, "id": "as2", "kind": "warm"},
                          {**assign, "id": "as3", "kind": "run"}])
        self.assertEqual(self.requests[10], {"v": 3, "type": "release", "spawn_id": SPAWN_ID, "grace_ms": namespace.RELEASE_GRACE_MS})
        self.assertEqual([r["id"] for r in self.requests if r["type"] == "measure"], [f"m{n}" for n in range(1, 8)])
        self.assertTrue(all(r["place"] == place for r in self.requests if r["type"] == "measure"))

    def test_a_runner_read_under_each_owner_and_free_only_after_released_passes(self):
        self.assertEqual([step for step, _ in self.read],
                         ["placed", "spawned", "fresh", "fresh", "assigned.assign", "assigned", "warm.assign", "warm", "reused.assign",
                          "reused", "release", "release", "release", "after"])
        self.judge(self.read)

    def test_a_refused_assign_fails(self):
        self.fails(self.edited("warm.assign", lambda got: [{"v": 3, "type": "error", "id": got[0]["id"], "code": "bad_request"}]),
                   "before warm, the keeper applied the assign")

    def test_a_reading_under_another_owner_fails(self):
        self.fails(self.edited("assigned", lambda got: [{**reply, "athanor": "ath_other"} for reply in got]),
                   f"assigned a run of {namespace.ATHANOR}")

    def test_a_reading_of_zero_fails(self):
        self.fails(self.edited("reused", lambda got: [{**reply, "bytes": 0} for reply in got]), "reused for another run")

    def test_a_runner_that_ended_before_its_release_fails(self):
        exited = {"v": 3, "type": "exited", "spawn_id": SPAWN_ID, "code": 1, "signal": None, "memory": None}
        self.fails(self.edited("warm", lambda got: [exited] + got), "back at rest")

    def test_a_reading_answered_only_after_released_fails(self):
        self.fails(self.edited("release", lambda got: [reply for reply in got if reply["type"] != "measured"]
                               + [reply for reply in got if reply["type"] == "measured"]),
                   "answered before its released")

    def test_a_place_read_after_released_fails(self):
        self.fails(self.edited("after", lambda got: [{"v": 3, "type": "measured", "id": got[0]["id"], "kind": "run",
                                                      "athanor": namespace.ATHANOR, "bytes": 1 << 20, "lesser": False,
                                                      "age_ms": 9}]),
                   "the runner's place is free")


if __name__ == "__main__":
    unittest.main()
