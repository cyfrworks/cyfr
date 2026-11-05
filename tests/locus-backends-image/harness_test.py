# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends suite's listing of its container and its home probe, with docker stubbed, and its session client.

A failed `docker exec` is no answer about the processes of the container or
about whether a home is there: the listing and the probe fail the
observation. Docker's refusal that the container is not running, or is
restarting, is the one exception to the listing, and it is read from the call.

The session client signs every session message as the wire's vectors do,
writes an absent optional member as absent, and its MCP client, against a
service stood in for here, initializes once, opens the session again and
initializes afresh when a send finds it ended, and fails a request whose
session ends before it is answered without sending it again.

Usage: python3 -I tests/locus-backends-image/harness_test.py
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

import e2e  # noqa: E402
import harness  # noqa: E402
import isolation  # noqa: E402
import imagesuite  # noqa: E402

CONTAINER = "cyfr-locus-backends-1"
PROCESS_LINE = ("4242|4000|1001,1001,1001,1001|00000000000000e0|00000000000000e0|00000000000000e0|0|"
                "beam.smp -- backend\n")
HOME = os.path.join(harness.HOME_ROOT, "backend-a1")

OTHER = "OCI runtime exec failed: unable to start container process"
NOT_RUNNING = f"container {CONTAINER} is not running"
RESTARTING = f"Container {CONTAINER} is restarting, wait until the container is running"


def state(status, running, restarting):
    return {"Status": status, "Running": running, "Restarting": restarting, "StartedAt": "2026-10-28T00:00:00Z"}


RUNNING = state("running", True, False)
STOPPED = state("exited", False, False)
RESTARTING_STATE = state("restarting", True, True)


def docker(refusal=None, stdout="", container_state=RUNNING, status=1):
    """`run` standing in for docker: a call the daemon refuses exits `status` with its refusal on stderr, and any other
    call exits 0 with `stdout`. The inspection reports `container_state`, which a later read may find already changed."""

    def run(*args, check=True, env=None, timeout=None):
        if args[1] == "inspect":
            code, out, err = 0, json.dumps([{"State": container_state, "RestartCount": 0}]), ""
        elif refusal:
            code, out, err = status, "", f"Error response from daemon: {refusal}"
        else:
            code, out, err = 0, stdout, ""
        if check and code != 0:
            sys.exit(f"FAIL: {' '.join(args)} exited {code}")
        return subprocess.CompletedProcess(args, code, out, err)

    return run


class Stub(unittest.TestCase):
    def container(self, refusal=None, stdout="", container_state=RUNNING, status=1):
        fake = docker(refusal, stdout, container_state, status)
        for module in (harness, imagesuite):
            patch = mock.patch.object(module, "run", fake)
            patch.start()
            self.addCleanup(patch.stop)
        observed = harness.Stack.__new__(harness.Stack)
        observed.container = CONTAINER
        return observed


class Processes(Stub):
    def test_a_failed_exec_fails_the_process_listing(self):
        with self.assertRaises(SystemExit):
            self.container(OTHER).processes()

    def test_a_stopped_container_holds_no_process(self):
        self.assertEqual(self.container(NOT_RUNNING, container_state=STOPPED).processes(), [])

    def test_a_container_restarting_between_one_keeper_and_the_next_holds_none(self):
        self.assertEqual(self.container(RESTARTING, container_state=RESTARTING_STATE).processes(), [])

    def test_a_restart_refused_and_finished_before_the_inspection_holds_none(self):
        self.assertEqual(self.container(RESTARTING, container_state=RUNNING).processes(), [])

    def test_a_readable_container_lists_what_it_holds(self):
        self.assertEqual(self.container(stdout=PROCESS_LINE).processes(), [{
            "pid": 4242, "sid": 4000, "uids": [1001] * 4, "cap_eff": "00000000000000e0", "cap_prm": "00000000000000e0",
            "cap_bnd": "00000000000000e0", "no_new_privs": False, "cmd": "beam.smp -- backend"}])


class HomeProbe(Stub):
    def test_a_home_the_probe_finds_is_not_gone(self):
        self.assertFalse(isolation.home_gone(self.container(stdout="present\n"), HOME))

    def test_a_home_the_probe_does_not_find_is_gone(self):
        self.assertTrue(isolation.home_gone(self.container(stdout="absent\n"), HOME))

    def test_a_failed_probe_is_no_answer_whatever_its_status(self):
        for status in (1, 125):
            with self.subTest(status=status):
                with self.assertRaises(SystemExit):
                    isolation.home_gone(self.container(OTHER, status=status), HOME)


class Logs(unittest.TestCase):
    """The logs are read whole from a compose call that exits 0: a failed read fails the predicate that reads them,
    and the text that was read is the control."""

    def observed(self, cls, returncode, stdout):
        observed = cls.__new__(cls)
        observed.container = CONTAINER
        observed.compose = lambda *args, **kwargs: subprocess.CompletedProcess(
            [], returncode, stdout, "" if returncode == 0 else "daemon error")
        return observed

    def test_a_failed_read_of_the_service_log_fails_it(self):
        with self.assertRaises(SystemExit):
            self.observed(harness.Stack, 1, "").logs()

    def test_a_failed_read_of_the_guard_log_fails_it(self):
        with self.assertRaises(SystemExit):
            self.observed(harness.Stack, 1, "").guard_logs()

    def test_a_failed_read_of_the_app_log_fails_it(self):
        with self.assertRaises(SystemExit):
            self.observed(e2e.CyfrStack, 1, "").cyfr_logs()

    def test_the_service_log_that_was_read_is_the_control(self):
        self.assertIn("[cyfr-locus] info: stopped", self.observed(harness.Stack, 0, "[cyfr-locus] info: stopped\n").logs())


class GuardCounters(unittest.TestCase):
    """The guard's rule counters come from a command chain: `iptables-save` failing ends the read, whatever `ip6tables-save` printed."""

    def guard(self, iptables, ip6tables):
        """A guard whose `guard_exec` runs its script under sh, with fake `*-save` commands on the path that print their text and exit their status."""
        bin_dir = tempfile.mkdtemp(prefix="backends-guard-counters-")
        self.addCleanup(shutil.rmtree, bin_dir, True)
        for name, (status, text) in (("iptables-save", iptables), ("ip6tables-save", ip6tables)):
            tool = os.path.join(bin_dir, name)
            with open(tool, "w") as f:
                f.write(f"#!/bin/sh\nprintf '%s' {shlex.quote(text)}\nexit {status}\n")
            os.chmod(tool, 0o700)
        observed = harness.Stack.__new__(harness.Stack)
        observed.guard_exec = lambda script: subprocess.run(
            ["/bin/sh", "-c", script], env={**os.environ, "PATH": bin_dir + os.pathsep + os.environ["PATH"]},
            capture_output=True, text=True)
        return observed

    def test_a_failed_iptables_save_fails_the_counters(self):
        with self.assertRaises(SystemExit):
            self.guard((1, "[1:2] -A INPUT -j DROP\n"), (0, "[3:4] -A OUTPUT -j ACCEPT\n")).guard_counters()

    def test_a_failed_ip6tables_save_fails_the_counters(self):
        with self.assertRaises(SystemExit):
            self.guard((0, "[1:2] -A INPUT -j DROP\n"), (1, "")).guard_counters()

    def test_the_counters_that_were_read_are_the_control(self):
        self.assertEqual(self.guard((0, "[1:2] -A INPUT -j DROP\n"), (0, "[3:4] -A OUTPUT -j ACCEPT\n")).guard_counters(),
                         {"-A INPUT -j DROP": 1, "-A OUTPUT -j ACCEPT": 3})


class ExecAnswering:
    """An observer whose exec exits `status` with `stdout`, and records the user each command was run as."""

    def __init__(self, status, stdout):
        self.status = status
        self.stdout = stdout
        self.users = []

    def exec(self, script, user=None):
        self.users.append(user)
        return subprocess.CompletedProcess([], self.status, self.stdout, "" if self.status == 0 else "daemon error")


class BackendEnviron(unittest.TestCase):
    """A backend's environment is read from a command that exits 0, run as the backend's own uid: a failed read is no answer."""

    def test_a_failed_read_is_no_answer(self):
        with self.assertRaises(SystemExit):
            harness.backend_environ(ExecAnswering(1, ""), 4242, 30001)

    def test_the_environment_that_was_read_is_the_control_run_as_the_backend(self):
        observer = ExecAnswering(0, "PROBE_SECRET=x\nLOG_LEVEL=info\n")
        self.assertEqual(harness.backend_environ(observer, 4242, 30001), "PROBE_SECRET=x\nLOG_LEVEL=info\n")
        self.assertEqual(observer.users, ["30001"])


class ImageUserName(unittest.TestCase):
    """A uid's name in the image is read from a lookup that exits 0: a failed lookup is no answer, not an empty name."""

    def lookup(self, status, stdout):
        """An observer whose exec runs its script under sh, with a fake getent on the path that prints `stdout` and exits `status`."""
        bin_dir = tempfile.mkdtemp(prefix="backends-image-user-")
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
            harness.image_user_name(self.lookup(2, ""), 30001)

    def test_the_name_that_was_read_is_the_control(self):
        self.assertEqual(harness.image_user_name(self.lookup(0, "cyfr-pool-1:x:30001:30001::/home/x:/bin/sh\n"), 30001),
                         "cyfr-pool-1")


OWNER = {"athanor": "ath_unit", "server": "mcp_unit", "e": 3}


class Service:
    """A backends service's session route as data: one program per session that answers MCP's lines."""

    def __init__(self):
        self.sessions = {}
        self.opened = 0
        self.received = []
        self.end_on = None

    def post(self, url, headers, body, timeout=60):
        message = json.loads(body)
        self.received.append(message)
        kind = message["type"]
        if kind == "open":
            self.opened += 1
            session = "ss_" + f"{self.opened:032x}"
            self.sessions[session] = {"lines": [], "seq": 0, "running": True}
            return 200, {"version": 2, "status": "running", "session": session, "resumed": False, "pty": False}, "bb"
        state = self.sessions[message["session"]]
        if kind == "send":
            if not state["running"]:
                return 200, {"version": 2, "status": "ended"}, "bb"
            for line in message["lines"]:
                request = json.loads(line)
                if self.end_on and request.get("params", {}).get("name") == self.end_on:
                    state["running"] = False
                    continue
                if "id" in request:
                    state["seq"] += 1
                    state["lines"].append({"seq": state["seq"], "text": json.dumps(
                        {"jsonrpc": "2.0", "id": request["id"], "result": {"method": request["method"]}})})
            return 200, {"version": 2, "status": "running"}, "bb"
        if kind == "recv":
            lines = [x for x in state["lines"] if x["seq"] > message["after"]]
            return 200, {"version": 2, "lines": lines, "dropped": 0, "running": state["running"]}, "bb"
        return 200, {"version": 2, "status": "closed"}, "bb"


class Sessions(unittest.TestCase):
    def setUp(self):
        self.service = Service()
        patch = mock.patch.object(harness, "post", self.service.post)
        patch.start()
        self.addCleanup(patch.stop)
        self.c = harness.Controller("http://unit", bytes(32))
        self.c.boot = "bb"

    def test_a_session_message_names_its_signer_and_leaves_an_absent_member_absent(self):
        request = self.c.sign_session(OWNER, {"type": "open", "program": "probe", "key": "k", "mode": "run",
                                              "argv": []}, ts=1, nonce="n_1")
        body = json.loads(request.body)
        self.assertEqual((body["owner"], body["e"], body["version"]),
                         ({"athanor": "ath_unit", "server": "mcp_unit"}, 3, harness.VERSION))
        self.assertNotIn("home_id", body)
        self.assertTrue(request.url.endswith(harness.ROUTES["session"]))
        signing = harness.owner_key(bytes(32), "ath_unit", "mcp_unit", 1, 3)
        fields = {"athanor": "ath_unit", "server": "mcp_unit", "generation": 1, "epoch": 3, "boot": "bb", "ts": 1,
                  "nonce": "n_1"}
        self.assertEqual(request.headers[harness.AUTH_HEADER], harness.invoke_header(signing, fields, request.body))

    def test_a_program_names_only_the_members_it_has(self):
        self.assertEqual(harness.program_wire(harness.probe()),
                         {"name": "probe", "command": harness.PROBE, "env_names": [], "home": "scratch"})
        kept = harness.program_wire(harness.probe(home="kept", home_max_bytes=7, login_command="login"))
        self.assertEqual((kept["home"], kept["home_max_bytes"], kept["login_command"]), ("kept", 7, "login"))
        self.assertNotIn("memory_bytes", kept)

    def test_the_mcp_client_initializes_once_and_answers_a_call(self):
        status, answer = self.c.call(OWNER, "probe__whoami", {})
        self.assertEqual((status, answer["result"]), (200, {"method": "tools/call"}))
        self.c.call(OWNER, "probe__whoami", {})
        client = self.c.mcp(OWNER, "probe")
        self.assertEqual((client.initializations, self.service.opened), (1, 1))
        methods = [json.loads(line)["method"] for m in self.service.received if m["type"] == "send"
                   for line in m["lines"]]
        self.assertEqual(methods, ["initialize", "notifications/initialized", "tools/call", "tools/call"])

    def test_a_send_that_finds_the_session_ended_opens_it_again_and_initializes_afresh(self):
        self.c.call(OWNER, "probe__whoami", {})
        client = self.c.mcp(OWNER, "probe")
        self.service.sessions[client.session]["running"] = False
        status, answer = self.c.call(OWNER, "probe__whoami", {})
        self.assertEqual((status, answer["result"]), (200, {"method": "tools/call"}))
        self.assertEqual((client.initializations, self.service.opened, client.resumed), (2, 2, False))

    def test_a_session_that_ends_before_it_answers_fails_the_request_once(self):
        self.service.end_on = "hog"
        status, answer = self.c.call(OWNER, "probe__hog", {})
        self.assertEqual((status, answer["ended"]), (200, "before_answer"))
        calls = [line for m in self.service.received if m["type"] == "send" for line in m["lines"]
                 if '"hog"' in line]
        self.assertEqual(len(calls), 1)
        self.assertIsNone(self.c.mcp(OWNER, "probe").session)


if __name__ == "__main__":
    unittest.main()
