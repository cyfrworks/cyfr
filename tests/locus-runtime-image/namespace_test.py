# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The namespace suite's kill of a runner, with docker stubbed.

A runner's keeper group counts as removed only on a probe whose successful
exec says so. A failed exec is no answer, whatever its status, and it fails
the kill.

Usage: python3 -I tests/locus-runtime-image/namespace_test.py
"""

import os
import subprocess
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import namespace  # noqa: E402
import stack  # noqa: E402
import imagesuite  # noqa: E402

CONTAINER = "cyfr-locus-runtime-1"
RUNNER = {"pid": 4242, "uid": 30101, "home": os.path.join(stack.HOME_ROOT, "runner-a1"), "runner": "a1"}


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
            namespace.runner_facts(self.observed(1, ""), {"pid": 4242, "uid": 30101})

    def test_the_facts_that_were_read_are_the_control(self):
        facts = namespace.runner_facts(self.observed(0, "uid_map=30101 30101 1\nfd=3 socket:[9]\n"),
                                       {"pid": 4242, "uid": 30101})
        self.assertEqual(facts["uid_map"], "30101 30101 1")
        self.assertEqual(facts["fds"], {3: "socket:[9]"})


if __name__ == "__main__":
    unittest.main()
