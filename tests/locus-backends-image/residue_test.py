# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The residue suite's read of what the kernel holds for a pooled uid, with docker stubbed.

Nothing held is answered only by a command that exits 0 and prints `absent`.
A failed exec, and output that answers neither word, are no answer.

Usage: python3 -I tests/locus-backends-image/residue_test.py
"""

import os
import subprocess
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import harness  # noqa: E402
import residue  # noqa: E402

CONTAINER = "cyfr-locus-backends-1"
HELD = [f"{residue.HOME_ROOT}/{residue.TAG}", "/proc/sysvipc/shm: 4242"]


def docker(state, status=1):
    """`run` standing in for docker. The uid holds `held` or nothing (`absent`); the exec exits `status` and prints
    nothing (`failed`), or exits 0 and prints nothing (`silent`). A command in word form answers its word, and the
    command as it was written before answers its rows alone."""

    def run(*args, check=True, env=None, timeout=None):
        word_form = "echo absent" in args[-1]
        if state == "failed":
            code, out = status, ""
        elif state == "silent":
            code, out = 0, ""
        elif state == "absent":
            code, out = 0, ("absent\n" if word_form else "")
        else:
            rows = "".join(f"{row}\n" for row in HELD)
            code, out = 0, (f"present\n{rows}" if word_form else rows)
        if check and code != 0:
            sys.exit(f"FAIL: {' '.join(args)} exited {code}")
        return subprocess.CompletedProcess(args, code, out, "" if code == 0 else "daemon error")

    return run


class HeldByUid(unittest.TestCase):
    def read(self, state, status=1):
        patch = mock.patch.object(harness, "run", docker(state, status))
        patch.start()
        self.addCleanup(patch.stop)
        observed = harness.Stack.__new__(harness.Stack)
        observed.container = CONTAINER
        return residue.held_by_uid(observed)

    def test_nothing_held_is_read_from_a_command_that_says_so(self):
        self.assertEqual(self.read("absent", status=0), [])

    def test_what_is_held_is_listed(self):
        self.assertEqual(self.read("held", status=0), HELD)

    def test_a_failed_exec_is_no_answer_for_nothing_held(self):
        for status in (1, 125):
            with self.subTest(status=status):
                with self.assertRaises(SystemExit):
                    self.read("failed", status)

    def test_output_that_answers_no_word_is_no_answer(self):
        with self.assertRaises(SystemExit):
            self.read("silent", status=0)


if __name__ == "__main__":
    unittest.main()
