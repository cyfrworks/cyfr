#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The image suites' shared plumbing, without Docker: a suite that TERM or INT
stops tears its stacks and temporary directories down, a second signal does
not cut that teardown short, the runtime suite's namespace prerequisite
refuses the hosts it names and passes the others, and no entry script leaves
`__pycache__` under tests/.

Usage: python3 -I tests/imagesuite_test.py
"""

import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
TESTS = os.path.dirname(os.path.abspath(__file__))
SUITES = ("builder-image", "locus-runtime-image", "locus-backends-image")

# A suite as the harnesses run one: a stack whose compose records its calls
# instead of calling Docker, a temporary directory, and a body that waits.
# `down` sleeps when told to, so a second signal can arrive inside it.
SUITE = r"""
import json, os, sys, time
sys.dont_write_bytecode = True
sys.path.append(sys.argv[1])
import imagesuite

imagesuite.stop_on_signals()
calls, slow, body = sys.argv[2], sys.argv[3] == "slow", sys.argv[4]


class Fake(imagesuite.Stack):
    def compose(self, *args, check=True):
        with open(calls, "a") as f:
            f.write(json.dumps(["start", *args]) + "\n")
        if slow and args[0] == "down":
            time.sleep(1.5)
        with open(calls, "a") as f:
            f.write(json.dumps(["end", *args]) + "\n")

    def logs(self):
        return ""


stack = Fake("imagesuite-test")
directory = imagesuite.temporary_directory("imagesuite-test-")
print(json.dumps({"project": stack.project_dir, "directory": directory}), flush=True)
if body == "guarded":
    try:
        time.sleep(60)
    finally:
        stack.down()
elif body == "bare":
    time.sleep(60)
"""


def pycaches():
    return set(glob.glob(os.path.join(TESTS, "**", "__pycache__"), recursive=True))


class Teardown(unittest.TestCase):
    def suite(self, slow=False, body="guarded"):
        calls = os.path.join(self.scratch, "calls")
        process = subprocess.Popen(
            [sys.executable, "-I", "-c", SUITE, TESTS, calls, "slow" if slow else "fast", body],
            stdout=subprocess.PIPE, text=True)
        self.addCleanup(process.stdout.close)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        paths = json.loads(process.stdout.readline())
        for path in paths.values():
            self.assertTrue(os.path.isdir(path), path)
        self.assertTrue(os.path.isfile(os.path.join(paths["project"], ".env")))
        return process, paths, calls

    def setUp(self):
        self.scratch = tempfile.mkdtemp(prefix="imagesuite-test-calls-")
        self.addCleanup(shutil.rmtree, self.scratch, True)

    def records(self, calls):
        with open(calls) as f:
            return [json.loads(line) for line in f]

    def assert_torn_down(self, process, paths, calls, signum):
        self.assertEqual(process.wait(timeout=30), 128 + signum)
        for path in paths.values():
            self.assertFalse(os.path.exists(path), f"{path} is left behind")
        downs = [record for record in self.records(calls) if record[1] == "down"]
        self.assertEqual(downs, [["start", "down", "--volumes", "--remove-orphans", "--timeout", "10"],
                                 ["end", "down", "--volumes", "--remove-orphans", "--timeout", "10"]])

    def test_term_runs_the_finally_teardown(self):
        process, paths, calls = self.suite()
        process.send_signal(signal.SIGTERM)
        self.assert_torn_down(process, paths, calls, signal.SIGTERM)

    def test_int_runs_the_finally_teardown(self):
        process, paths, calls = self.suite()
        process.send_signal(signal.SIGINT)
        self.assert_torn_down(process, paths, calls, signal.SIGINT)

    def test_a_stack_made_outside_any_try_is_torn_down_at_exit(self):
        process, paths, calls = self.suite(body="bare")
        process.send_signal(signal.SIGTERM)
        self.assert_torn_down(process, paths, calls, signal.SIGTERM)

    def wait_for_down(self, calls):
        deadline = time.monotonic() + 10
        while not os.path.exists(calls) or not any(record[:2] == ["start", "down"] for record in self.records(calls)):
            self.assertLess(time.monotonic(), deadline, "the teardown never began")
            time.sleep(0.02)

    def test_a_second_signal_does_not_cut_the_teardown_short(self):
        process, paths, calls = self.suite(slow=True)
        process.send_signal(signal.SIGTERM)
        self.wait_for_down(calls)
        process.send_signal(signal.SIGTERM)
        self.assert_torn_down(process, paths, calls, signal.SIGTERM)

    def test_a_first_signal_inside_the_exit_teardown_runs_it_again(self):
        # The suite ends without a signal and leaves its stack to the exit
        # hook, whose down the signal interrupts.
        process, paths, calls = self.suite(slow=True, body="ends")
        self.wait_for_down(calls)
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=30)
        for path in paths.values():
            self.assertFalse(os.path.exists(path), f"{path} is left behind")
        downs = [record for record in self.records(calls) if record[1] == "down"]
        self.assertEqual(downs, [["start", "down", "--volumes", "--remove-orphans"],
                                 ["start", "down", "--volumes", "--remove-orphans", "--timeout", "10"],
                                 ["end", "down", "--volumes", "--remove-orphans", "--timeout", "10"]])


class NamespacePrerequisite(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, os.path.join(TESTS, "locus-runtime-image"))
        import namespace
        cls.refusal = staticmethod(namespace.userns_refusal)

    def test_no_user_namespaces_at_all_is_refused_by_name(self):
        for restrict in ("absent", "0", "1"):
            refusal = self.refusal("0", restrict, ["name=apparmor"])
            self.assertIn("user.max_user_namespaces is 0", refusal)

    def test_restricted_userns_without_dockers_apparmor_profile_is_refused_by_name(self):
        for options in ([], ["name=seccomp,profile=builtin", "name=cgroupns"], ["name=selinux"]):
            refusal = self.refusal("63000", "1", options)
            self.assertIn("kernel.apparmor_restrict_unprivileged_userns is 1", refusal)
            self.assertIn("name=apparmor", refusal)

    def test_hosts_that_allow_the_namespaces_pass(self):
        allowed = [
            ("63000", "1", ["name=apparmor", "name=seccomp,profile=builtin"]),
            ("63000", "0", []),
            ("63000", "absent", []),
            ("absent", "absent", []),
        ]
        for limit, restrict, options in allowed:
            self.assertIsNone(self.refusal(limit, restrict, options), (limit, restrict, options))


class Bytecode(unittest.TestCase):
    def test_no_entry_script_writes_pycache(self):
        before = pycaches()
        for suite in SUITES:
            for script in sorted(glob.glob(os.path.join(TESTS, suite, "*.py"))):
                with open(script) as f:
                    if '__name__ == "__main__"' not in f.read():
                        continue
                # The script's own module code runs, its siblings' imports
                # among it, and its __main__ block does not.
                result = subprocess.run(
                    [sys.executable, "-I", "-c", "import runpy, sys; runpy.run_path(sys.argv[1], run_name='imported')", script],
                    capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, f"{script}\n{result.stderr}")
        written = pycaches() - before
        for path in written:
            shutil.rmtree(path, ignore_errors=True)
        self.assertEqual(sorted(written), [])


if __name__ == "__main__":
    unittest.main()
