# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The runtime memory suite's reads of the cgroups, the service and the sampler's probe, with docker stubbed.

A read that feeds an absence assertion is a successful read or the observation
fails: a missing OOM counter is refused rather than read as zero, a failed
read is no group, no start time and no probe answer.

Usage: python3 -I tests/locus-runtime-image/memory_test.py
"""

import os
import subprocess
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import stack  # noqa: E402
import memory  # noqa: E402

UID = 30101


def answer(returncode, stdout):
    return subprocess.CompletedProcess([], returncode, stdout, "" if returncode == 0 else "daemon error")


class FakeStack:
    """An observer whose exec answers `result`, and whose service VM is `beam` (None when the listing has none)."""

    def __init__(self, result, beam=4242):
        self.result = result
        self.beam = beam

    def exec(self, script, user=None):
        return self.result

    def service_beam_pid(self):
        return self.beam


class ContainerMemory(unittest.TestCase):
    def test_a_failed_read_fails_the_container_memory(self):
        with self.assertRaises(SystemExit):
            memory.container_memory(FakeStack(answer(1, "")))

    def test_the_container_events_that_were_read_are_the_control(self):
        out = "max\n1048576\noom 0\noom_kill 0\n"
        read = memory.container_memory(FakeStack(answer(0, out)))
        self.assertEqual(read["events_local"], {"oom": 0, "oom_kill": 0})
        self.assertEqual(read["current"], 1048576)

    def test_a_missing_oom_kill_counter_fails_the_read(self):
        with self.assertRaises(SystemExit):
            memory.container_memory(FakeStack(answer(0, "max\n1048576\noom 0\n")))


class Groups(unittest.TestCase):
    def test_an_absent_group_is_none_from_a_successful_read(self):
        self.assertIsNone(memory.read_group(FakeStack(answer(0, "absent\n")), UID))

    def test_a_failed_read_fails_the_group_instead_of_reading_absent(self):
        with self.assertRaises(SystemExit):
            memory.read_group(FakeStack(answer(1, "")), UID)

    def test_a_present_group_with_its_counters_is_the_control(self):
        out = "present|1048576|max|0|0|4096|oom 0 oom_kill 0 oom_group_kill 0 \n"
        group = memory.read_group(FakeStack(answer(0, out)), UID)
        self.assertEqual(group["events"], {"oom": 0, "oom_kill": 0, "oom_group_kill": 0})
        self.assertEqual((group["peak"], group["current"]), (0, 4096))

    def test_a_group_whose_events_lack_a_kill_counter_fails_the_read(self):
        with self.assertRaises(SystemExit):
            memory.read_group(FakeStack(answer(0, "present|1048576|max|0|0|4096|oom 0 \n")), UID)


class Keeper(unittest.TestCase):
    def test_a_failed_read_fails_the_keeper_group(self):
        with self.assertRaises(SystemExit):
            memory.keeper_group(FakeStack(answer(1, "")))

    def test_the_keeper_group_that_was_read_is_the_control(self):
        self.assertEqual(memory.keeper_group(FakeStack(answer(0, "4096\n8192\n"))), {"peak": 4096, "current": 8192})


class ReleaseIdentity(unittest.TestCase):
    def test_no_service_vm_fails_the_identity(self):
        with self.assertRaises(SystemExit):
            memory.release_identity(FakeStack(answer(0, ""), beam=None))

    def test_a_failed_start_time_read_fails_the_identity(self):
        with self.assertRaises(SystemExit):
            memory.release_identity(FakeStack(answer(1, "")))

    def test_the_identity_that_was_read_is_the_control(self):
        self.assertEqual(memory.release_identity(FakeStack(answer(0, "812345\n"))), (4242, "812345"))


class ProcessProbe(unittest.TestCase):
    def probe(self, returncode, stdout):
        with mock.patch.object(memory, "run", lambda *args, **kwargs: answer(returncode, stdout)):
            return memory.process_alive("cyfr-locus-runtime-1", 4242)

    def test_a_process_the_probe_finds_running_is_alive(self):
        self.assertTrue(self.probe(0, "alive\n"))

    def test_a_process_the_probe_does_not_find_is_dead(self):
        self.assertFalse(self.probe(0, "dead\n"))

    def test_a_failed_probe_is_no_answer(self):
        with self.assertRaises(SystemExit):
            self.probe(1, "dead\n")


if __name__ == "__main__":
    unittest.main()
