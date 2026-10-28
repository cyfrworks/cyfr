# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The runtime stack's observations of its container, with docker stubbed.

A failed `docker exec`, `docker top` or inspection is no answer about what
the container holds: the readers fail the observation, and the cleanup
predicates built on them (runners.py) fail with it. The one state that
holds nothing is a container whose main process has exited, and its
readers answer empty.

Usage: python3 -I tests/locus-runtime-image/stack_test.py
"""

import json
import os
import subprocess
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import runners  # noqa: E402
import stack  # noqa: E402
import imagesuite  # noqa: E402

CONTAINER = "cyfr-locus-runtime-1"
UID = 1001
HOME = os.path.join(stack.HOME_ROOT, "runner-a1")
PROCESS_LINE = "4242|1001,1001,1001,1001|00000000000000e0|beam.smp -- runner\n"
HOME_LINE = "runner-a1\n"


def state(status, running, restarting):
    return {"Status": status, "Running": running, "Restarting": restarting, "StartedAt": "2026-10-28T00:00:00Z"}


RUNNING = state("running", True, False)
STOPPED = state("exited", False, False)
# Docker's report between one exit of the main process and the next start.
RESTARTING = state("restarting", True, True)


def docker(container_state, status=0, stdout="", inspect_status=0):
    """`stack.run` standing in for docker: every exec and top exits `status` with `stdout`, and the inspection exits
    `inspect_status` and reports `container_state`. A checked call exits as imagesuite.run's does."""

    def run(*args, check=True, env=None, timeout=None):
        if args[1] == "inspect":
            code, out = inspect_status, json.dumps([{"State": container_state, "RestartCount": 0}])
        else:
            code, out = status, stdout
        if check and code != 0:
            sys.exit(f"FAIL: {' '.join(args)} exited {code}")
        return subprocess.CompletedProcess(args, code, out if code == 0 else "", "" if code == 0 else "daemon error")

    return run


class Observations(unittest.TestCase):
    def container(self, container_state, status=0, stdout="", inspect_status=0):
        fake = docker(container_state, status, stdout, inspect_status)
        for module in (stack, imagesuite):
            patch = mock.patch.object(module, "run", fake)
            patch.start()
            self.addCleanup(patch.stop)
        observed = stack.Stack.__new__(stack.Stack)
        observed.container = CONTAINER
        return observed

    def test_a_failed_exec_fails_the_process_listing(self):
        with self.assertRaises(SystemExit):
            self.container(RUNNING, status=1).processes()

    def test_a_failed_exec_fails_the_home_listing(self):
        with self.assertRaises(SystemExit):
            self.container(RUNNING, status=1).homes()

    def test_a_failed_top_fails_the_host_listing(self):
        with self.assertRaises(SystemExit):
            self.container(RUNNING, status=1).host_processes()

    def test_a_failed_privileged_exec_fails_the_runner_listing(self):
        with self.assertRaises(SystemExit):
            self.container(RUNNING, status=1).runner_processes()

    def test_a_failed_inspection_fails_the_listing_it_was_read_for(self):
        with self.assertRaises(SystemExit):
            self.container(RUNNING, status=1, inspect_status=1).processes()

    def test_a_failed_exec_is_not_read_as_cleanup(self):
        observed = self.container(RUNNING, status=1)
        with self.assertRaises(SystemExit):
            runners.uid_gone(observed, UID)
        with self.assertRaises(SystemExit):
            runners.os_cleanup(observed, {"uid": UID, "home": HOME}, "retired runner")

    def test_a_stopped_container_holds_no_process_and_no_home(self):
        observed = self.container(STOPPED, status=1)
        self.assertEqual(observed.processes(), [])
        self.assertEqual(observed.homes(), [])
        self.assertEqual(observed.host_processes(), [])
        self.assertEqual(observed.runner_processes(), [])
        self.assertTrue(runners.uid_gone(observed, UID))
        self.assertTrue(runners.home_scrubbed(observed, {"home": HOME}))

    def test_a_container_restarting_between_one_keeper_and_the_next_holds_none(self):
        observed = self.container(RESTARTING, status=1)
        self.assertEqual(observed.processes(), [])
        self.assertEqual(observed.homes(), [])

    def test_a_readable_container_lists_what_it_holds(self):
        observed = self.container(RUNNING, stdout=PROCESS_LINE)
        self.assertEqual(observed.processes(), [{"pid": 4242, "uids": [UID] * 4, "cap_eff": "00000000000000e0",
                                                 "cmd": "beam.smp -- runner"}])
        self.assertFalse(runners.uid_gone(observed, UID))
        observed = self.container(RUNNING, stdout=HOME_LINE)
        self.assertEqual(observed.homes(), ["runner-a1"])
        self.assertFalse(runners.home_scrubbed(observed, {"home": HOME}))


if __name__ == "__main__":
    unittest.main()
