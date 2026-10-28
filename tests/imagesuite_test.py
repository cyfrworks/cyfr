#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The image suites' shared plumbing, without Docker: a suite that TERM or INT
stops tears its stacks and temporary directories down, a second signal does
not cut that teardown short, a `docker compose down` that fails is retried
a bounded number of times and a teardown that never succeeds keeps its stack
registered and fails the run, the runtime suite's namespace prerequisite
refuses the hosts it names and passes the others, the runtime stack waits
out a restart Docker reports running before the container is started again
and a port compose publishes late, and fails within its bound where either
never comes, a guard's failure is read from its inspect record whether the
guard has exited or is between one exit and its next start, and no entry
script writes bytecode for anything under tests/, whatever cache is already
there. What a container holds and what a probe answers are read as
imagesuite.py defines them, and each suite's stub test of its observations
(tests/<suite>/*_test.py) runs here as its own entry script.

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
sys.path.insert(0, TESTS)
import imagesuite  # noqa: E402

# A suite as the harnesses run one: a stack whose compose records its calls
# instead of calling Docker, a temporary directory, and a body that waits.
# `down` sleeps when told to, so a second signal can arrive inside it, and
# fails as many times as the suite's fourth argument says ("always" for
# every time).
SUITE = r"""
import json, os, subprocess, sys, time
sys.dont_write_bytecode = True
sys.path.append(sys.argv[1])
import imagesuite

imagesuite.stop_on_signals()
imagesuite.DOWN_RETRY_S = 0.05
calls, slow, body, failing = sys.argv[2], sys.argv[3] == "slow", sys.argv[4], sys.argv[5]
downs = []


class Fake(imagesuite.Stack):
    def compose(self, *args, check=True):
        with open(calls, "a") as f:
            f.write(json.dumps(["start", *args]) + "\n")
        if slow and args[0] == "down":
            time.sleep(1.5)
        with open(calls, "a") as f:
            f.write(json.dumps(["end", *args]) + "\n")
        if args[0] == "down":
            downs.append(True)
            if failing == "always" or len(downs) <= int(failing):
                return subprocess.CompletedProcess(args, 1, "", "Cannot connect to the Docker daemon\n")
        return subprocess.CompletedProcess(args, 0, "", "")

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
elif body == "returns":
    try:
        pass
    finally:
        stack.down()
    print(json.dumps({"registered": stack in imagesuite._stacks}), flush=True)
"""


class Teardown(unittest.TestCase):
    def suite(self, slow=False, body="guarded", failing="0"):
        calls = os.path.join(self.scratch, "calls")
        # The suite's stdout carries only its JSON lines, and its stderr
        # names its project, wherever this runs: under CI `down` prints the
        # stack's logs to stdout, and PROOF_RUN_PREFIX renames the project.
        env = {name: value for name, value in os.environ.items() if name not in ("CI", "PROOF_RUN_PREFIX")}
        process = subprocess.Popen(
            [sys.executable, "-I", "-c", SUITE, TESTS, calls, "slow" if slow else "fast", body, failing],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.addCleanup(process.stderr.close)
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


    def downs(self, calls):
        return [record for record in self.records(calls) if record[:2] == ["end", "down"]]

    def test_a_down_that_fails_is_retried_until_it_succeeds(self):
        process, paths, calls = self.suite(body="returns", failing="2")
        self.assertEqual(json.loads(process.stdout.readline()), {"registered": False})
        self.assertEqual(process.wait(timeout=30), 0)
        self.assertEqual(len(self.downs(calls)), 3)
        self.assertFalse(os.path.exists(paths["project"]), "the project directory is left behind")
        self.assertIn("attempt 2 of 3", process.stderr.read())

    def test_a_down_that_always_fails_keeps_the_stack_and_fails_the_run(self):
        # A daemon that does not answer the teardown: the stack stays
        # registered with its project directory, the run ends with the FAIL
        # named, and the exit hook's retries do not turn it into a pass.
        process, paths, calls = self.suite(body="returns", failing="always")
        stderr = process.stderr.read()
        self.assertNotEqual(process.wait(timeout=30), 0)
        self.assertIn("FAIL: docker compose down of imagesuite-test failed 3 times", stderr)
        self.assertEqual(len(self.downs(calls)), 3 + 3, "the exit hook retried the down once more, bounded")
        self.assertFalse(os.path.exists(paths["project"]), "the exit hook left the project directory behind")

    def test_a_down_that_fails_beside_a_failing_suite_keeps_its_failure(self):
        # The suite fails first; the teardown in its `finally` fails too and
        # says so without hiding the suite's own failure, and the exit hook
        # fails the run however its retries end.
        process, paths, calls = self.suite(failing="always")
        process.send_signal(signal.SIGTERM)
        stderr = process.stderr.read()
        self.assertEqual(process.wait(timeout=30), 128 + signal.SIGTERM)
        self.assertIn("FAIL: docker compose down of imagesuite-test failed 3 times", stderr)
        self.assertIn("FAIL: the teardown of imagesuite-test failed; the run fails", stderr)
        for path in paths.values():
            self.assertFalse(os.path.exists(path), f"{path} is left behind")


class FailedDown(unittest.TestCase):
    def test_a_failed_down_stays_registered_with_its_directory(self):
        # In process: a down whose compose exits 1 every time keeps the
        # stack for the exit hook to retry, with the project directory
        # whose .env compose reads.
        sys.path.insert(0, TESTS)
        self.addCleanup(sys.path.remove, TESTS)
        import imagesuite

        class Failing(imagesuite.Stack):
            def compose(self, *args, check=True):
                return subprocess.CompletedProcess(args, 1, "", "daemon unavailable")

            def logs(self):
                return ""

        patched = mock.patch.object(imagesuite, "DOWN_RETRY_S", 0)
        patched.start()
        self.addCleanup(patched.stop)
        stack = Failing("teardown-fault-probe")
        self.addCleanup(shutil.rmtree, stack.project_dir, True)
        self.addCleanup(lambda: stack in imagesuite._stacks and imagesuite._stacks.remove(stack))
        with self.assertRaises(SystemExit) as raised:
            stack.down()
        self.assertIn("failed 3 times", str(raised.exception))
        self.assertIn(stack, imagesuite._stacks)
        self.assertTrue(os.path.isfile(os.path.join(stack.project_dir, ".env")))


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


class SuiteObservations(unittest.TestCase):
    """The image suites' stub tests of what their observations read (tests/<suite>/*_test.py), each run as its own entry script."""

    def run_entry(self, suite, name):
        script = os.path.join(TESTS, suite, name)
        result = subprocess.run([sys.executable, "-I", "-B", script], capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_runtime_stack_observations(self):
        self.run_entry("locus-runtime-image", "stack_test.py")

    def test_builder_stack_observations(self):
        self.run_entry("builder-image", "stack_test.py")

    def test_namespace_runner_kills(self):
        self.run_entry("locus-runtime-image", "namespace_test.py")

    def test_backends_listing_and_home_probe(self):
        self.run_entry("locus-backends-image", "harness_test.py")

    def test_backends_residue_reads(self):
        self.run_entry("locus-backends-image", "residue_test.py")

    def test_builder_isolation_ipc_tables(self):
        self.run_entry("builder-image", "isolation_test.py")


class ObservationAnswers(unittest.TestCase):
    """What a probe's output or a container's state may answer: a word from a successful exec, and no process in a stopped container."""

    def probe(self, returncode, stdout):
        return subprocess.CompletedProcess([], returncode, stdout, "daemon error")

    def test_the_word_of_a_successful_probe_is_read(self):
        self.assertEqual(imagesuite.read_word(self.probe(0, "present\n"), ("present", "absent"), "the probe"), "present")

    def test_a_failed_probe_is_no_answer_whatever_it_printed(self):
        for returncode, stdout in ((1, "absent\n"), (125, "")):
            with self.subTest(returncode=returncode, stdout=stdout):
                with self.assertRaises(SystemExit):
                    imagesuite.read_word(self.probe(returncode, stdout), ("present", "absent"), "the probe")

    def test_output_of_neither_word_is_no_answer(self):
        with self.assertRaises(SystemExit):
            imagesuite.read_word(self.probe(0, ""), ("present", "absent"), "the probe")

    def test_a_call_refused_as_not_running_or_restarting_lists_nothing(self):
        for refusal in ("container e1 is not running",
                        "Container e1 is restarting, wait until the container is running"):
            with self.subTest(refusal=refusal):
                done = subprocess.CompletedProcess([], 1, "", f"Error response from daemon: {refusal}")
                self.assertEqual(imagesuite.listing(done, "the listing"), "")

    def test_any_other_failed_call_fails_the_listing(self):
        for stderr in ("Error response from daemon: Container e1 is paused, unpause the container before exec",
                       "OCI runtime exec failed"):
            with self.subTest(stderr=stderr):
                with self.assertRaises(SystemExit):
                    imagesuite.listing(subprocess.CompletedProcess([], 1, "", stderr), "the listing")

    def test_a_successful_call_lists_its_output(self):
        self.assertEqual(imagesuite.listing(subprocess.CompletedProcess([], 0, "a\n", ""), "the listing"), "a\n")

    def test_a_listing_in_word_form_is_read_from_a_command_that_exits_zero(self):
        self.assertEqual(imagesuite.read_listing(self.probe(0, "present\n/a: 1\n"), "the listing"), ["/a: 1"])
        self.assertEqual(imagesuite.read_listing(self.probe(0, "absent\n"), "the listing"), [])

    def test_a_failed_or_wordless_listing_is_no_answer(self):
        for returncode, stdout in ((1, "absent\n"), (125, ""), (0, ""), (0, "present\n"), (0, "absent\n/a: 1\n")):
            with self.subTest(returncode=returncode, stdout=stdout):
                with self.assertRaises(SystemExit):
                    imagesuite.read_listing(self.probe(returncode, stdout), "the listing")

    def test_a_table_is_read_only_from_a_command_that_exits_zero(self):
        self.assertEqual(imagesuite.read_output(self.probe(0, "table\n"), "the table"), "table\n")
        with self.assertRaises(SystemExit):
            imagesuite.read_output(self.probe(1, "table\n"), "the table")


# A suite's one-off containers as its functions start them, each call to
# `run` recorded instead of made: the first `docker run` ends the call.
ONE_OFF = r"""
import json, os, sys, types
suite, case = sys.argv[1:]
sys.path.insert(0, suite)
calls = []
class Started(Exception):
    pass
def fake(*args, **kwargs):
    calls.append(list(args))
    if args[:2] == ("docker", "run"):
        raise Started
    return types.SimpleNamespace(returncode=0, stdout="", stderr="")
if case == "keeper_run":
    import namespace as m
    m.run = fake
    call = lambda: m.keeper_run("image", "true")
elif case == "prerequisites":
    import namespace as m
    m.run = fake
    m.shutil = types.SimpleNamespace(which=lambda name: "/usr/bin/docker")
    m.os = types.SimpleNamespace(path=types.SimpleNamespace(isfile=lambda path: True), getpid=os.getpid)
    call = lambda: m.prerequisites("image")
elif case == "dial":
    import runners as m
    m.run = fake
    call = lambda: m.dial(types.SimpleNamespace(project="project", container="c", image="image"), 7, "host:1")
try:
    call()
except Started:
    pass
print(json.dumps([c for c in calls if c[:2] == ["docker", "run"]]))
"""


class OneOffNames(unittest.TestCase):
    """A one-off container a suite starts is named only under
    PROOF_RUN_PREFIX, so CI starts it unnamed, as it did before the gate
    named its runs."""

    def started(self, suite, case, prefix):
        env = {k: v for k, v in os.environ.items() if k != "PROOF_RUN_PREFIX"}
        if prefix:
            env["PROOF_RUN_PREFIX"] = prefix
        result = subprocess.run([sys.executable, "-I", "-B", "-c", ONE_OFF, os.path.join(TESTS, suite), case],
                                capture_output=True, text=True, timeout=60, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        runs = json.loads(result.stdout)
        self.assertEqual(len(runs), 1, runs)
        return runs[0]

    def test_run_name_is_nothing_without_the_prefix(self):
        with mock.patch.object(imagesuite, "PROJECT_PREFIX", ""):
            self.assertEqual(imagesuite.run_name("x"), [])
        with mock.patch.object(imagesuite, "PROJECT_PREFIX", "cyfr-gate-1-harness-"):
            self.assertEqual(imagesuite.run_name("cyfr-gate-1-harness-x"), ["--name", "cyfr-gate-1-harness-x"])

    def test_each_one_off_container_is_named_only_under_the_prefix(self):
        for suite, case in (("locus-runtime-image", "keeper_run"), ("locus-runtime-image", "prerequisites"),
                            ("locus-runtime-image", "dial")):
            with self.subTest(case=case):
                self.assertNotIn("--name", self.started(suite, case, None))
                args = self.started(suite, case, "cyfr-gate-1-harness-")
                self.assertIn("--name", args)
                name = args[args.index("--name") + 1]
                self.assertTrue(name.startswith("cyfr-gate-1-harness-") or name.startswith("project-"), name)


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


class GuardFailed(unittest.TestCase):
    """A guard's failure read from its `docker inspect` record (`imagesuite.guard_failed`)."""

    def record(self, status, exit_code, restarts, health=None):
        # RestartCount is the record's own field, beside State.
        state = {"Status": status, "Running": status in ("running", "restarting"), "Restarting": status == "restarting",
                 "ExitCode": exit_code}
        if health:
            state["Health"] = {"Status": health}
        return {"State": state, "RestartCount": restarts}

    def test_a_guard_that_exited_with_an_error_failed(self):
        self.assertTrue(imagesuite.guard_failed(self.record("exited", 1, 0)))

    def test_a_guard_between_one_exit_and_its_next_start_failed_by_its_restart_count(self):
        # Inspected mid-restart, Docker reports it running and restarting
        # with ExitCode 0: only RestartCount says it failed, and the count
        # is not under State (reading it there raises KeyError).
        self.assertTrue(imagesuite.guard_failed(self.record("restarting", 0, 1)))
        self.assertTrue(imagesuite.guard_failed(self.record("running", 0, 2, health="starting")))

    def test_a_healthy_guard_has_not_failed(self):
        self.assertFalse(imagesuite.guard_failed(self.record("running", 0, 0, health="healthy")))
        self.assertFalse(imagesuite.guard_failed(self.record("running", 0, 1, health="healthy")))

    def test_a_guard_still_starting_for_the_first_time_has_not_failed(self):
        self.assertFalse(imagesuite.guard_failed(self.record("running", 0, 0, health="starting")))


if __name__ == "__main__":
    unittest.main()
