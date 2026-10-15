#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The image suites' shared plumbing, without Docker: a suite that TERM or INT
stops tears its stacks and temporary directories down, a second signal does
not cut that teardown short, the runtime suite's namespace prerequisite
refuses the hosts it names and passes the others, the runtime stack waits
out a restart Docker reports running before the container is started again
and a port compose publishes late, and fails within its bound where either
never comes, and no entry script writes bytecode for anything under tests/,
whatever cache is already there.

Usage: python3 -I tests/imagesuite_test.py
"""

import glob
import http.server
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

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


class RuntimeRestart(unittest.TestCase):
    """The runtime stack's restart wait and listener wait, against Docker's answers as a restart gives them."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, os.path.join(TESTS, "locus-runtime-image"))
        import stack
        cls.module = stack

    def inspection(self, status, restarts, port):
        # `docker inspect` of a container its restart policy restarts: from
        # its process's exit until it is started again Docker reports it
        # running and restarting, its restart counted, with no port.
        state = {"Status": status, "Running": status in ("running", "restarting"), "Restarting": status == "restarting",
                 "StartedAt": "2026-10-15T09:42:51Z"}
        ports = {f"{self.module.PORT}/tcp": [{"HostIp": "127.0.0.1", "HostPort": str(port)}]} if port else {}
        return json.dumps([{"State": state, "RestartCount": restarts, "NetworkSettings": {"Ports": ports}}])

    def fake(self, inspections=(), ports=()):
        """A runtime stack whose Docker answers `inspections` in turn and whose compose answers `ports` in turn."""
        module, test = self.module, self
        inspected, published = list(inspections), list(ports)

        class Fake(module.Stack):
            def compose(self, *args, check=True):
                if args[0] == "port":
                    answer = published.pop(0) if len(published) > 1 else published[0]
                    return subprocess.CompletedProcess(args, 0 if answer else 1, f"{answer}\n" if answer else "",
                                                       "" if answer else f"no port {module.PORT}/tcp for container test-1\n")
                return subprocess.CompletedProcess(args, 0, "", "")

            def logs(self):
                return "the service's log\n"

            def status(self):
                return 200, {"ok": {"boot": "boot_after"}}

        def run(*args, **_options):
            test.assertEqual(args[:2], ("docker", "inspect"))
            answer = inspected.pop(0) if len(inspected) > 1 else inspected[0]
            return subprocess.CompletedProcess(args, 0, answer, "")

        patched = mock.patch.object(module, "run", run)
        patched.start()
        self.addCleanup(patched.stop)
        stack = Fake("imagesuite-test", "image", plane=None)
        self.addCleanup(stack.down)
        stack.container = "test-1"
        return stack

    def listener(self):
        """A listener on the loopback that refuses an unsigned status with 401, as the image's does."""
        class Refuse(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.send_response(401)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Refuse)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"127.0.0.1:{server.server_address[1]}"

    def test_a_restarting_container_is_not_restarted_until_it_runs(self):
        before = self.inspection("running", 0, 33584)
        restarting = self.inspection("restarting", 1, None)
        started = self.inspection("running", 1, 33585)
        stack = self.fake([before, restarting, restarting, started])
        state = stack.container_state()
        self.assertEqual((state["running"], state["restarting"], state["restarts"]), (True, False, 0))
        restarted = stack.wait_restarted(state, 5)
        self.assertEqual((restarted["running"], restarted["restarting"], restarted["restarts"]), (True, False, 1))

    def test_a_container_that_never_starts_again_fails_the_restart_wait(self):
        stack = self.fake([self.inspection("running", 0, 33584), self.inspection("restarting", 1, None)])
        state = stack.container_state()
        with self.assertRaises(SystemExit) as failure:
            stack.wait_restarted(state, 0.5)
        self.assertIn("the container to restart in place", str(failure.exception))

    def test_the_listener_wait_reads_a_port_published_late(self):
        address = self.listener()
        stack = self.fake(ports=[None, None, address])
        self.assertEqual(stack.wait_listener(timeout=10), {"boot": "boot_after"})
        self.assertEqual((stack.base, stack.boot), (f"http://{address}", "boot_after"))

    def test_a_port_never_published_fails_the_listener_wait_naming_it(self):
        stack = self.fake(ports=[None])
        with self.assertRaises(SystemExit) as failure:
            stack.wait_listener(timeout=1)
        message = str(failure.exception)
        self.assertIn(f"compose never published port {self.module.PORT}", message)
        self.assertIn(f"no port {self.module.PORT}/tcp for container test-1", message)
        self.assertIn("the service's log", message)


class Bytecode(unittest.TestCase):
    def test_no_entry_script_writes_bytecode(self):
        # Under `-X pycache_prefix` Python reads and writes every bytecode
        # cache below a fresh directory and ignores the __pycache__
        # directories beside the sources, so a stale cache under tests/ (an
        # empty directory, or a valid .pyc) neither hides a write nor answers
        # an import. A .pyc below the directory's copy of tests/ is one an
        # entry script wrote; the standard library's land elsewhere in it.
        prefix = tempfile.mkdtemp(prefix="imagesuite-test-pycache-")
        self.addCleanup(shutil.rmtree, prefix, True)
        mirror = os.path.join(prefix, TESTS.lstrip(os.sep))
        ran = set()
        for suite in SUITES:
            for script in sorted(glob.glob(os.path.join(TESTS, suite, "*.py"))):
                with open(script) as f:
                    if '__name__ == "__main__"' not in f.read():
                        continue
                # The script's own module code runs, its siblings' imports
                # among it, and its __main__ block does not.
                result = subprocess.run(
                    [sys.executable, "-I", "-X", f"pycache_prefix={prefix}", "-c",
                     "import runpy, sys; runpy.run_path(sys.argv[1], run_name='imported')", script],
                    capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, f"{script}\n{result.stderr}")
                ran.add(suite)
                written = sorted(os.path.relpath(path, mirror)
                                 for path in glob.glob(os.path.join(mirror, "**", "*.pyc"), recursive=True))
                self.assertEqual(written, [], f"{os.path.relpath(script, TESTS)} wrote bytecode")
        # Each suite's entry scripts ran, so a glob that matched nothing
        # does not pass the case.
        self.assertEqual(ran, set(SUITES))


if __name__ == "__main__":
    unittest.main()
