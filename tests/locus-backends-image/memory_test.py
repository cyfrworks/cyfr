# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends memory suite's reads of the cgroup limits, with the exec stubbed.

A cgroup path or limit that cannot be read is no answer: a failed read fails
the observation, rather than reading as an empty path or an empty limit, and
the values that were read are the control.

Usage: python3 -I tests/locus-backends-image/memory_test.py
"""

import os
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import memory  # noqa: E402


class Exec:
    """An observer whose execs answer `answers` in order, each as (exit status, stdout); (0, "") once none is left."""

    def __init__(self, *answers):
        self.answers = list(answers)

    def exec(self, script, user=None):
        status, stdout = self.answers.pop(0) if self.answers else (0, "")
        return subprocess.CompletedProcess([], status, stdout, "" if status == 0 else "daemon error")


class CgroupLimit(unittest.TestCase):
    def test_a_failed_path_read_fails_the_cgroup_read(self):
        with self.assertRaises(SystemExit):
            memory.cgroup_limit(Exec((2, "")), 4242)

    def test_a_failed_limit_read_fails_it_and_is_not_read_as_empty(self):
        with self.assertRaises(SystemExit):
            memory.cgroup_limit(Exec((0, "/system.slice/x\n"), (1, "")), 4242)

    def test_the_path_and_limit_that_were_read_are_the_control(self):
        self.assertEqual(memory.cgroup_limit(Exec((0, "/system.slice/x\n"), (0, "134217728\n")), 4242),
                         ("/system.slice/x", "134217728"))


class ContainerLimit(unittest.TestCase):
    def test_a_failed_read_fails_the_container_limit(self):
        with self.assertRaises(SystemExit):
            memory.container_limit(Exec((1, "")))

    def test_the_limit_that_was_read_is_the_control(self):
        self.assertEqual(memory.container_limit(Exec((0, "max\n"))), "max")


if __name__ == "__main__":
    unittest.main()
