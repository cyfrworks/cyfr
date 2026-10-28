# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends suite's listing of its container and its home probe, with docker stubbed.

A failed `docker exec` is no answer about the processes of the container or
about whether a home is there: the listing and the probe fail the
observation. The one state that holds no process is a container whose main
process has exited.

Usage: python3 -I tests/locus-backends-image/harness_test.py
"""

import json
import os
import subprocess
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import harness  # noqa: E402
import isolation  # noqa: E402
import imagesuite  # noqa: E402

CONTAINER = "cyfr-locus-backends-1"
PROCESS_LINE = ("4242|4000|1001,1001,1001,1001|00000000000000e0|00000000000000e0|00000000000000e0|0|"
                "beam.smp -- backend\n")
HOME = "/var/lib/locus/homes/backend-a1"


def state(status, running, restarting):
    return {"Status": status, "Running": running, "Restarting": restarting, "StartedAt": "2026-10-28T00:00:00Z"}


RUNNING = state("running", True, False)
STOPPED = state("exited", False, False)
# Docker's report between one exit of the main process and the next start.
RESTARTING = state("restarting", True, True)


def docker(container_state, status=0, stdout="", inspect_status=0):
    """`run` standing in for docker: every exec exits `status` with `stdout`, and the inspection exits
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


class Stub(unittest.TestCase):
    def container(self, container_state, status=0, stdout="", inspect_status=0):
        fake = docker(container_state, status, stdout, inspect_status)
        for module in (harness, imagesuite):
            patch = mock.patch.object(module, "run", fake)
            patch.start()
            self.addCleanup(patch.stop)
        observed = harness.Stack.__new__(harness.Stack)
        observed.container = CONTAINER
        return observed


class Processes(Stub):
    def test_a_failed_exec_fails_the_process_listing(self):
        with self.assertRaises(SystemExit):
            self.container(RUNNING, status=1).processes()

    def test_a_failed_inspection_fails_the_listing_it_was_read_for(self):
        with self.assertRaises(SystemExit):
            self.container(RUNNING, status=1, inspect_status=1).processes()

    def test_a_stopped_container_holds_no_process(self):
        self.assertEqual(self.container(STOPPED, status=1).processes(), [])

    def test_a_container_restarting_between_one_keeper_and_the_next_holds_none(self):
        self.assertEqual(self.container(RESTARTING, status=1).processes(), [])

    def test_a_readable_container_lists_what_it_holds(self):
        self.assertEqual(self.container(RUNNING, stdout=PROCESS_LINE).processes(), [{
            "pid": 4242, "sid": 4000, "uids": [1001] * 4, "cap_eff": "00000000000000e0", "cap_prm": "00000000000000e0",
            "cap_bnd": "00000000000000e0", "no_new_privs": False, "cmd": "beam.smp -- backend"}])


class HomeProbe(Stub):
    def test_a_home_the_probe_finds_is_not_gone(self):
        self.assertFalse(isolation.home_gone(self.container(RUNNING, stdout="present\n"), HOME))

    def test_a_home_the_probe_does_not_find_is_gone(self):
        self.assertTrue(isolation.home_gone(self.container(RUNNING, stdout="absent\n"), HOME))

    def test_a_failed_probe_is_no_answer_whatever_its_status(self):
        for status in (1, 125):
            with self.subTest(status=status):
                with self.assertRaises(SystemExit):
                    isolation.home_gone(self.container(RUNNING, status=status), HOME)


if __name__ == "__main__":
    unittest.main()
