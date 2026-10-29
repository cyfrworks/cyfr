# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builds memory suite's read of the keeper cgroups a container holds, with docker stubbed.

That no keeper cgroup is left is answered only by the word `absent` from a
command that exits 0. A failed exec, and output that answers neither word, are
no answer.

Usage: python3 -I tests/builder-image/memory_test.py
"""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import memory  # noqa: E402
import stack  # noqa: E402
import imagesuite  # noqa: E402

CONTAINER = "cyfr-locus-builds-1"
# The builds pool's first two uids, from the suite's own constants, which read the role table.
GROUPS = [f"/sys/fs/cgroup/keeper-{stack.POOL_FIRST}", f"/sys/fs/cgroup/keeper-{stack.POOL_FIRST + 1}"]


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
        self.assertEqual(self.groups(f"echo {GROUPS[0]}; exit 0"), [GROUPS[0]])


class ContainerState(unittest.TestCase):
    """The container's state is read only from commands that exit 0: a failed read of a start time, of the events or of
    the memory in use fails the state, and each value that was read is the control."""

    def state(self, cut=(0, "100"), events=(0, "oom 0\noom_kill 0\n"), current=(0, "4096\n")):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root)
        bindir = os.path.join(root, "bin")
        os.makedirs(bindir)
        status, value = cut
        tool = os.path.join(bindir, "cut")
        with open(tool, "w") as f:
            f.write(f"#!/bin/sh\n{f'echo {value}' if value else ':'}\nexit {status}\n")
        os.chmod(tool, 0o700)
        reads = {"cat /sys/fs/cgroup/memory.events": events, "cat /sys/fs/cgroup/memory.current": current}

        class Shell:
            container = "stub-container"

            def processes(self):
                return [{"pid": 777, "cmd": "beam.smp"}]

            def exec(self, script, user=None):
                if script in reads:
                    status, out = reads[script]
                    return subprocess.CompletedProcess([], status, out, "" if status == 0 else "read error")
                return subprocess.run(["/bin/sh", "-c", script],
                                      env={**os.environ, "PATH": bindir + os.pathsep + os.environ["PATH"]},
                                      text=True, capture_output=True)

        inspected = subprocess.CompletedProcess(
            [], 0, json.dumps([{"State": {"OOMKilled": False}, "RestartCount": 0}]), "")
        with mock.patch.object(memory, "run", return_value=inspected):
            return memory.container_state(Shell())

    def test_a_failed_start_time_read_fails_the_state(self):
        with self.assertRaises(SystemExit):
            self.state(cut=(1, None))

    def test_the_start_time_that_was_read_is_the_control(self):
        self.assertEqual(self.state()["release"], ["777:100"])

    def test_a_failed_events_read_fails_the_state(self):
        with self.assertRaises(SystemExit):
            self.state(events=(1, "oom 0\n"))

    def test_a_failed_memory_read_fails_the_state_and_is_not_read_as_zero(self):
        with self.assertRaises(SystemExit):
            self.state(current=(1, ""))
        self.assertEqual(self.state(current=(0, "4096\n"))["current"], 4096)


class ContainerLimit(unittest.TestCase):
    """The container's memory.max is read from a command that exits 0: a failed read fails the observation, and the value read is the control."""

    def exec_answering(self, status, stdout):
        class Observer:
            def exec(self, script, user=None):
                return subprocess.CompletedProcess([], status, stdout, "" if status == 0 else "daemon error")

        return Observer()

    def test_a_failed_read_fails_the_container_limit(self):
        with self.assertRaises(SystemExit):
            memory.container_limit(self.exec_answering(1, ""))

    def test_the_limit_that_was_read_is_the_control(self):
        self.assertEqual(memory.container_limit(self.exec_answering(0, "1073741824\n")), "1073741824")


class ReleaseUser(unittest.TestCase):
    """The release's user name is read from a lookup that exits 0: a failed lookup is no answer, not an empty name."""

    def lookup(self, status, stdout):
        """An observer whose exec runs its script under sh, with a fake getent on the path that prints `stdout` and exits `status`."""
        bin_dir = tempfile.mkdtemp(prefix="builder-release-user-")
        self.addCleanup(shutil.rmtree, bin_dir, True)
        tool = os.path.join(bin_dir, "getent")
        with open(tool, "w") as f:
            f.write(f"#!/bin/sh\nprintf '%s' {shlex.quote(stdout)}\nexit {status}\n")
        os.chmod(tool, 0o700)

        class Shell:
            def exec(self, script, user=None):
                return subprocess.run(["/bin/sh", "-c", script],
                                      env={**os.environ, "PATH": bin_dir + os.pathsep + os.environ["PATH"]},
                                      capture_output=True, text=True)

        return Shell()

    def test_a_failed_lookup_is_no_answer(self):
        with self.assertRaises(SystemExit):
            memory.release_user(self.lookup(2, ""))

    def test_the_name_that_was_read_is_the_control(self):
        uid = stack.POOL_FIRST
        line = f"cyfr-release:x:{uid}:{uid}::/home/x:/bin/sh\n"
        self.assertEqual(memory.release_user(self.lookup(0, line)), "cyfr-release")


if __name__ == "__main__":
    unittest.main()
