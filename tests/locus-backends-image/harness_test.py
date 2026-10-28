# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends suite's listing of its container and its home probe, with docker stubbed.

A failed `docker exec` is no answer about the processes of the container or
about whether a home is there: the listing and the probe fail the
observation. Docker's refusal that the container is not running, or is
restarting, is the one exception to the listing, and it is read from the call.

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

import e2e  # noqa: E402
import harness  # noqa: E402
import isolation  # noqa: E402
import imagesuite  # noqa: E402

CONTAINER = "cyfr-locus-backends-1"
PROCESS_LINE = ("4242|4000|1001,1001,1001,1001|00000000000000e0|00000000000000e0|00000000000000e0|0|"
                "beam.smp -- backend\n")
HOME = os.path.join(harness.HOME_ROOT, "backend-a1")

OTHER = "OCI runtime exec failed: unable to start container process"
NOT_RUNNING = f"container {CONTAINER} is not running"
RESTARTING = f"Container {CONTAINER} is restarting, wait until the container is running"


def state(status, running, restarting):
    return {"Status": status, "Running": running, "Restarting": restarting, "StartedAt": "2026-10-28T00:00:00Z"}


RUNNING = state("running", True, False)
STOPPED = state("exited", False, False)
RESTARTING_STATE = state("restarting", True, True)


def docker(refusal=None, stdout="", container_state=RUNNING, status=1):
    """`run` standing in for docker: a call the daemon refuses exits `status` with its refusal on stderr, and any other
    call exits 0 with `stdout`. The inspection reports `container_state`, which a later read may find already changed."""

    def run(*args, check=True, env=None, timeout=None):
        if args[1] == "inspect":
            code, out, err = 0, json.dumps([{"State": container_state, "RestartCount": 0}]), ""
        elif refusal:
            code, out, err = status, "", f"Error response from daemon: {refusal}"
        else:
            code, out, err = 0, stdout, ""
        if check and code != 0:
            sys.exit(f"FAIL: {' '.join(args)} exited {code}")
        return subprocess.CompletedProcess(args, code, out, err)

    return run


class Stub(unittest.TestCase):
    def container(self, refusal=None, stdout="", container_state=RUNNING, status=1):
        fake = docker(refusal, stdout, container_state, status)
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
            self.container(OTHER).processes()

    def test_a_stopped_container_holds_no_process(self):
        self.assertEqual(self.container(NOT_RUNNING, container_state=STOPPED).processes(), [])

    def test_a_container_restarting_between_one_keeper_and_the_next_holds_none(self):
        self.assertEqual(self.container(RESTARTING, container_state=RESTARTING_STATE).processes(), [])

    def test_a_restart_refused_and_finished_before_the_inspection_holds_none(self):
        self.assertEqual(self.container(RESTARTING, container_state=RUNNING).processes(), [])

    def test_a_readable_container_lists_what_it_holds(self):
        self.assertEqual(self.container(stdout=PROCESS_LINE).processes(), [{
            "pid": 4242, "sid": 4000, "uids": [1001] * 4, "cap_eff": "00000000000000e0", "cap_prm": "00000000000000e0",
            "cap_bnd": "00000000000000e0", "no_new_privs": False, "cmd": "beam.smp -- backend"}])


class HomeProbe(Stub):
    def test_a_home_the_probe_finds_is_not_gone(self):
        self.assertFalse(isolation.home_gone(self.container(stdout="present\n"), HOME))

    def test_a_home_the_probe_does_not_find_is_gone(self):
        self.assertTrue(isolation.home_gone(self.container(stdout="absent\n"), HOME))

    def test_a_failed_probe_is_no_answer_whatever_its_status(self):
        for status in (1, 125):
            with self.subTest(status=status):
                with self.assertRaises(SystemExit):
                    isolation.home_gone(self.container(OTHER, status=status), HOME)


class Logs(unittest.TestCase):
    """The logs are read whole from a compose call that exits 0: a failed read fails the predicate that reads them,
    and the text that was read is the control."""

    def observed(self, cls, returncode, stdout):
        observed = cls.__new__(cls)
        observed.container = CONTAINER
        observed.compose = lambda *args, **kwargs: subprocess.CompletedProcess(
            [], returncode, stdout, "" if returncode == 0 else "daemon error")
        return observed

    def test_a_failed_read_of_the_service_log_fails_it(self):
        with self.assertRaises(SystemExit):
            self.observed(harness.Stack, 1, "").logs()

    def test_a_failed_read_of_the_guard_log_fails_it(self):
        with self.assertRaises(SystemExit):
            self.observed(harness.Stack, 1, "").guard_logs()

    def test_a_failed_read_of_the_app_log_fails_it(self):
        with self.assertRaises(SystemExit):
            self.observed(e2e.CyfrStack, 1, "").cyfr_logs()

    def test_the_service_log_that_was_read_is_the_control(self):
        self.assertIn("[cyfr-locus] info: stopped", self.observed(harness.Stack, 0, "[cyfr-locus] info: stopped\n").logs())


if __name__ == "__main__":
    unittest.main()
