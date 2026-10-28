# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builds memory suite's read of the keeper cgroups a container holds, with docker stubbed.

That no keeper cgroup is left is answered only by the word `absent` from a
command that exits 0. A failed exec, and output that answers neither word, are
no answer.

Usage: python3 -I tests/builder-image/memory_test.py
"""

import os
import subprocess
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import memory  # noqa: E402
import stack  # noqa: E402

CONTAINER = "cyfr-locus-builds-1"
GROUPS = ["/sys/fs/cgroup/keeper-30001", "/sys/fs/cgroup/keeper-30002"]


def docker(state, status=1):
    """`run` standing in for docker: no keeper cgroup is left (`absent`), or some are (`present`); the exec exits
    `status` and prints nothing (`failed`), or exits 0 and prints nothing (`silent`). A command in word form answers
    its word, and the command as it was written before answers its paths alone."""

    def run(*args, check=True, env=None, timeout=None):
        word_form = "echo absent" in args[-1]
        if state == "failed":
            code, out = status, ""
        elif state == "silent":
            code, out = 0, ""
        elif state == "absent":
            code, out = 0, ("absent\n" if word_form else "")
        else:
            rows = "".join(f"{group}\n" for group in GROUPS)
            code, out = 0, (f"present\n{rows}" if word_form else rows)
        if check and code != 0:
            sys.exit(f"FAIL: {' '.join(args)} exited {code}")
        return subprocess.CompletedProcess(args, code, out, "" if code == 0 else "daemon error")

    return run


class KeeperGroups(unittest.TestCase):
    def read(self, state, status=1):
        patch = mock.patch.object(stack, "run", docker(state, status))
        patch.start()
        self.addCleanup(patch.stop)
        observed = stack.Stack.__new__(stack.Stack)
        observed.container = CONTAINER
        return memory.keeper_groups(observed)

    def test_no_group_is_read_from_a_command_that_says_so(self):
        self.assertEqual(self.read("absent", status=0), [])

    def test_the_groups_left_are_listed(self):
        self.assertEqual(self.read("present", status=0), GROUPS)

    def test_a_failed_exec_is_no_answer_for_no_group(self):
        for status in (1, 125):
            with self.subTest(status=status):
                with self.assertRaises(SystemExit):
                    self.read("failed", status)

    def test_output_that_answers_no_word_is_no_answer(self):
        with self.assertRaises(SystemExit):
            self.read("silent", status=0)


if __name__ == "__main__":
    unittest.main()
