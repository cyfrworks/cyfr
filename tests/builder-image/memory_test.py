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
import imagesuite  # noqa: E402

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


class KeeperListShell(unittest.TestCase):
    """The command as the container's shell runs it, with `find` stubbed on the path: a read error inside the
    enumeration is no answer, and only a successful enumeration answers `absent`."""

    def shell(self, behaviour):
        bin_dir = imagesuite.temporary_directory("memory-test-bin-", 0o755)
        find = os.path.join(bin_dir, "find")
        with open(find, "w") as stub:
            stub.write(f"#!/bin/sh\n{behaviour}\n")
        os.chmod(find, 0o700)
        return {"PATH": bin_dir + os.pathsep + os.environ["PATH"]}

    def groups(self, behaviour):
        env = self.shell(behaviour)

        class Shell:
            def exec(self, script, user=None):
                return subprocess.run(["/bin/sh", "-c", script], env={**os.environ, **env},
                                      capture_output=True, text=True)

        return memory.keeper_groups(Shell())

    def test_a_read_error_inside_the_enumeration_fails_the_observation(self):
        with self.assertRaises(SystemExit):
            self.groups('echo "find: /sys/fs/cgroup: Permission denied" >&2; exit 1')

    def test_an_enumeration_that_finds_nothing_answers_absent(self):
        self.assertEqual(self.groups("exit 0"), [])

    def test_an_enumeration_that_finds_groups_lists_them(self):
        self.assertEqual(self.groups("echo /sys/fs/cgroup/keeper-30001; exit 0"),
                         ["/sys/fs/cgroup/keeper-30001"])


if __name__ == "__main__":
    unittest.main()
