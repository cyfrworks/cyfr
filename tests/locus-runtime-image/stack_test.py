# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The runtime stack's listings of its container, with docker stubbed.

A failed `docker exec`, `docker top` or `docker exec --privileged` is no
answer about what the container holds: the listings fail the observation.
Docker's refusal that the container is not running, or is restarting,
is the one exception, and it is read from the call.

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

# Docker's refusals of a call, as its error response names them.
OTHER = "OCI runtime exec failed: unable to start container process"
NOT_RUNNING = f"container {CONTAINER} is not running"
RESTARTING = f"Container {CONTAINER} is restarting, wait until the container is running"
PAUSED = f"Container {CONTAINER} is paused, unpause the container before exec"


def state(status, running, restarting):
    return {"Status": status, "Running": running, "Restarting": restarting, "StartedAt": "2026-10-28T00:00:00Z"}


RUNNING = state("running", True, False)
STOPPED = state("exited", False, False)
RESTARTING_STATE = state("restarting", True, True)


def docker(refusal=None, stdout="", container_state=RUNNING):
    """`run` standing in for docker: a call the daemon refuses exits 1 with its refusal on stderr, and any other call
    exits 0 with `stdout`. The inspection reports `container_state`, which a later read may find already changed."""

    def run(*args, check=True, env=None, timeout=None):
        if args[1] == "inspect":
            code, out, err = 0, json.dumps([{"State": container_state, "RestartCount": 0}]), ""
        elif refusal:
            code, out, err = 1, "", f"Error response from daemon: {refusal}"
        else:
            code, out, err = 0, stdout, ""
        if check and code != 0:
            sys.exit(f"FAIL: {' '.join(args)} exited {code}")
        return subprocess.CompletedProcess(args, code, out, err)

    return run


class Listings(unittest.TestCase):
    def container(self, refusal=None, stdout="", container_state=RUNNING):
        fake = docker(refusal, stdout, container_state)
        for module in (stack, imagesuite):
            patch = mock.patch.object(module, "run", fake)
            patch.start()
            self.addCleanup(patch.stop)
        observed = stack.Stack.__new__(stack.Stack)
        observed.container = CONTAINER
        return observed

    def test_a_failed_exec_fails_the_process_listing(self):
        with self.assertRaises(SystemExit):
            self.container(OTHER).processes()

    def test_a_failed_exec_fails_the_home_listing(self):
        with self.assertRaises(SystemExit):
            self.container(OTHER).homes()

    def test_a_failed_top_fails_the_host_listing(self):
        with self.assertRaises(SystemExit):
            self.container(OTHER).host_processes()

    def test_a_failed_privileged_exec_fails_the_runner_listing(self):
        with self.assertRaises(SystemExit):
            self.container(OTHER).runner_processes()

    def test_a_paused_container_fails_the_listing_it_was_read_for(self):
        with self.assertRaises(SystemExit):
            self.container(PAUSED).processes()

    def test_a_failed_exec_is_not_read_as_cleanup(self):
        observed = self.container(OTHER)
        with self.assertRaises(SystemExit):
            runners.uid_gone(observed, UID)
        with self.assertRaises(SystemExit):
            runners.os_cleanup(observed, {"uid": UID, "home": HOME}, "retired runner")

    def test_a_stopped_container_holds_no_process_and_no_home(self):
        observed = self.container(NOT_RUNNING, container_state=STOPPED)
        self.assertEqual(observed.processes(), [])
        self.assertEqual(observed.homes(), [])
        self.assertEqual(observed.host_processes(), [])
        self.assertEqual(observed.runner_processes(), [])
        self.assertTrue(runners.uid_gone(observed, UID))
        self.assertTrue(runners.home_scrubbed(observed, {"home": HOME}))

    def test_a_container_restarting_between_one_keeper_and_the_next_holds_none(self):
        observed = self.container(RESTARTING, container_state=RESTARTING_STATE)
        self.assertEqual(observed.processes(), [])
        self.assertEqual(observed.homes(), [])

    def test_a_restart_refused_and_finished_before_the_inspection_holds_none(self):
        # The call is refused while the restart runs; the inspection reads the container once it runs again.
        observed = self.container(RESTARTING, container_state=RUNNING)
        self.assertEqual(observed.processes(), [])
        self.assertEqual(observed.host_processes(), [])

    def test_a_readable_container_lists_what_it_holds(self):
        observed = self.container(stdout=PROCESS_LINE)
        self.assertEqual(observed.processes(), [{"pid": 4242, "uids": [UID] * 4, "cap_eff": "00000000000000e0",
                                                 "cmd": "beam.smp -- runner"}])
        self.assertFalse(runners.uid_gone(observed, UID))
        observed = self.container(stdout=HOME_LINE)
        self.assertEqual(observed.homes(), ["runner-a1"])
        self.assertFalse(runners.home_scrubbed(observed, {"home": HOME}))


class Logs(unittest.TestCase):
    """The container's log is read whole from a compose call that exits 0: a failed read fails, and the text that
    was read is the control."""

    def observed(self, returncode, stdout):
        observed = stack.Stack.__new__(stack.Stack)
        observed.container = CONTAINER
        observed.compose = lambda *args, **kwargs: subprocess.CompletedProcess(
            [], returncode, stdout, "" if returncode == 0 else "daemon error")
        return observed

    def test_a_failed_read_of_the_log_fails_it(self):
        with self.assertRaises(SystemExit):
            self.observed(1, "").logs()

    def test_the_log_that_was_read_is_the_control(self):
        self.assertIn("quarantined", self.observed(0, "quarantined\n").logs())


class CpuShare(unittest.TestCase):
    """The container's CPU time is read only from a command that exits 0: a failed read fails the share, whatever its
    stdout holds, and the time that was read is the control."""

    def observed(self, status, stdout):
        observed = stack.Stack.__new__(stack.Stack)
        observed.exec = lambda *args, **kwargs: subprocess.CompletedProcess(
            [], status, stdout, "" if status == 0 else "read error")
        return observed

    def test_a_failed_read_with_a_number_on_stdout_fails_the_share(self):
        with self.assertRaises(SystemExit):
            self.observed(1, "123456\n").cpu_share(0.01)

    def test_the_cpu_time_that_was_read_is_the_control(self):
        self.assertEqual(self.observed(0, "123456\n").cpu_usec(), 123456)


class HostGateway(unittest.TestCase):
    """The host gateway is read from a lookup that exits 0: a failed lookup is no answer, and a lookup that names no address is none."""

    def observer(self, status, stdout):
        observed = stack.Stack.__new__(stack.Stack)
        observed.exec = lambda script, user=None: subprocess.CompletedProcess([], status, stdout, "" if status == 0 else "daemon error")
        return observed

    def test_a_failed_lookup_is_no_answer(self):
        with self.assertRaises(SystemExit):
            self.observer(2, "").host_gateway()

    def test_the_address_that_was_read_is_the_control(self):
        self.assertEqual(self.observer(0, "172.17.0.1      STREAM host.docker.internal\n").host_gateway(), "172.17.0.1")

    def test_a_lookup_that_names_no_address_is_none(self):
        self.assertIsNone(self.observer(0, "").host_gateway())


if __name__ == "__main__":
    unittest.main()
