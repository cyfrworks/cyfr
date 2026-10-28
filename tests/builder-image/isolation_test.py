# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builds isolation suite's read of the kernel's IPC tables, with docker stubbed.

The tables answer the check that no IPC object of the uid is left only from a
command that exits 0. A failed exec, and a command that fails after printing,
are no answer.

Usage: python3 -I tests/builder-image/isolation_test.py
"""

import os
import subprocess
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import isolation  # noqa: E402
import stack  # noqa: E402

CONTAINER = "cyfr-locus-builds-1"
TABLES = "key shmid perms\n0 1 600\n"


def docker(status, stdout):
    """`run` standing in for docker: the exec exits `status` and prints `stdout`, which a command that fails may print
    before it fails. A checked call exits as imagesuite.run's does."""

    def run(*args, check=True, env=None, timeout=None):
        if check and status != 0:
            sys.exit(f"FAIL: {' '.join(args)} exited {status}")
        return subprocess.CompletedProcess(args, status, stdout, "" if status == 0 else "daemon error")

    return run


class IpcTables(unittest.TestCase):
    def read(self, status, stdout):
        patch = mock.patch.object(stack, "run", docker(status, stdout))
        patch.start()
        self.addCleanup(patch.stop)
        observed = stack.Stack.__new__(stack.Stack)
        observed.container = CONTAINER
        return isolation.ipc_tables(observed)

    def test_the_tables_are_read_from_a_command_that_exits_zero(self):
        self.assertEqual(self.read(0, TABLES), TABLES)

    def test_a_failed_exec_is_no_answer(self):
        with self.assertRaises(SystemExit):
            self.read(1, "")

    def test_a_command_that_fails_after_printing_is_no_answer(self):
        with self.assertRaises(SystemExit):
            self.read(2, TABLES)


if __name__ == "__main__":
    unittest.main()
