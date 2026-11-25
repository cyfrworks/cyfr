# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builds stack's listings of its container, with docker stubbed, and its reading of an answer.

A failed `docker exec` is no answer about the processes or the home root of
the container: the listings fail the observation. Docker's refusal that the
container is not running, or is restarting, is the one exception, and it is
read from the call.

An answer's lines are read as the wire's vectors say every reader reads
them: each stream under `lines.streams` of tests/fixtures/locus_builds.json,
which `stack.WIRE` holds, reads to its files and log, to its refusal keeping
nothing, or fails by the error the vector names.

Usage: python3 -I tests/builder-image/stack_test.py
"""

import base64
import hashlib
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

import stack  # noqa: E402
import imagesuite  # noqa: E402

CONTAINER = "cyfr-locus-1"
PROCESS_LINE = "4242|1001,1001,1001,1001|00000000000000e0|beam.smp -- builder\n"
HOME_LINE = "build-a1\n"

OTHER = "OCI runtime exec failed: unable to start container process"
NOT_RUNNING = f"container {CONTAINER} is not running"
RESTARTING = f"Container {CONTAINER} is restarting, wait until the container is running"


def state(status, running, restarting):
    return {"Status": status, "Running": running, "Restarting": restarting, "StartedAt": "2026-10-28T00:00:00Z"}


RUNNING = state("running", True, False)
STOPPED = state("exited", False, False)
RESTARTING_STATE = state("restarting", True, True)


def docker(refusal=None, stdout="", container_state=RUNNING):
    """`run` standing in for docker: a call the daemon refuses exits 1 with its refusal on stderr, and any other call
    exits 0 with `stdout`. The inspection reports `container_state`, which a later read may find already changed."""

    def run(*args, check=True, env=None, timeout=None):
        if args[1] == "inspect":
            code, out, err = 0, json.dumps([{"State": container_state, "RestartCount": 0}]), ""
        elif refusal:
            code, out, err = 1, "", f"Error response from daemon: {refusal}"
        else:
            code, out, err = 0, stdout, ""
        if check and code != 0:
            sys.exit(f"FAIL: {' '.join(args)} exited {code}")
        return subprocess.CompletedProcess(args, code, out, err)

    return run


class Listings(unittest.TestCase):
    def container(self, refusal=None, stdout="", container_state=RUNNING):
        fake = docker(refusal, stdout, container_state)
        for module in (stack, imagesuite):
            patch = mock.patch.object(module, "run", fake)
            patch.start()
            self.addCleanup(patch.stop)
        observed = stack.Stack.__new__(stack.Stack)
        observed.container = CONTAINER
        return observed

    def test_a_failed_exec_fails_the_process_listing(self):
        with self.assertRaises(SystemExit):
            self.container(OTHER).processes()

    def test_a_failed_exec_fails_the_home_listing(self):
        with self.assertRaises(SystemExit):
            self.container(OTHER).homes()

    def test_a_stopped_container_holds_no_process_and_no_home(self):
        observed = self.container(NOT_RUNNING, container_state=STOPPED)
        self.assertEqual(observed.processes(), [])
        self.assertEqual(observed.homes(), [])

    def test_a_container_restarting_between_one_keeper_and_the_next_holds_none(self):
        observed = self.container(RESTARTING, container_state=RESTARTING_STATE)
        self.assertEqual(observed.processes(), [])
        self.assertEqual(observed.homes(), [])

    def test_a_restart_refused_and_finished_before_the_inspection_holds_none(self):
        observed = self.container(RESTARTING, container_state=RUNNING)
        self.assertEqual(observed.processes(), [])

    def test_a_readable_container_lists_what_it_holds(self):
        observed = self.container(stdout=PROCESS_LINE)
        self.assertEqual(observed.processes(), [{"pid": 4242, "uids": [1001] * 4, "cap_eff": "00000000000000e0",
                                                 "cmd": "beam.smp -- builder"}])
        observed = self.container(stdout=HOME_LINE)
        self.assertEqual(observed.homes(), ["build-a1"])


class Logs(unittest.TestCase):
    """The container's log is read whole from a compose call that exits 0: a failed read fails, and the text that
    was read is the control."""

    def observed(self, returncode, stdout):
        observed = stack.Stack.__new__(stack.Stack)
        observed.container = CONTAINER
        observed.compose = lambda *args, **kwargs: subprocess.CompletedProcess(
            [], returncode, stdout, "" if returncode == 0 else "daemon error")
        return observed

    def test_a_failed_read_of_the_log_fails_it(self):
        with self.assertRaises(SystemExit):
            self.observed(1, "").logs()

    def test_the_log_that_was_read_is_the_control(self):
        self.assertIn("quarantined", self.observed(0, "quarantined\n").logs())

    def test_a_failed_read_of_the_guard_log_fails_it(self):
        with self.assertRaises(SystemExit):
            self.observed(1, "").guard_logs()

    def test_the_guard_log_that_was_read_is_the_control(self):
        self.assertIn("island subnet", self.observed(0, "island subnet 172.16.230.0/24\n").guard_logs())


class GuardCounters(unittest.TestCase):
    """The guard's rule counters come from a command chain: `iptables-save` failing ends the read, whatever `ip6tables-save` printed."""

    def guard(self, iptables, ip6tables):
        """A guard whose `guard_exec` runs its script under sh, with fake `*-save` commands on the path that print their text and exit their status."""
        bin_dir = tempfile.mkdtemp(prefix="builder-guard-counters-")
        self.addCleanup(shutil.rmtree, bin_dir, True)
        for name, (status, text) in (("iptables-save", iptables), ("ip6tables-save", ip6tables)):
            tool = os.path.join(bin_dir, name)
            with open(tool, "w") as f:
                f.write(f"#!/bin/sh\nprintf '%s' {shlex.quote(text)}\nexit {status}\n")
            os.chmod(tool, 0o700)
        observed = stack.Stack.__new__(stack.Stack)
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


def output(path, seq, data):
    return {"version": stack.VERSION, "type": "output", "path": path, "seq": seq,
            "bytes": base64.b64encode(data).decode()}


def result(files):
    return {"version": stack.VERSION, "type": "result", "language": "javascript", "target_type": "tincture",
            "outputs": [{"path": path, "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
                        for path, data in files.items()]}


PROGRESS = {"version": stack.VERSION, "type": "progress", "stage": "output", "message": "bundling"}


class ReadAnswer(unittest.TestCase):
    """An answer's lines are read as a client reads them: its log, and its files only under a result naming them."""

    def test_a_result_keeps_the_files_its_lines_carried_and_the_log(self):
        progress, terminal = stack.read_answer([
            PROGRESS, output("a.js", 1, b"one "), output("a.js", 2, b"two"),
            result({"a.js": b"one two", "index.html": b""})])
        self.assertEqual(progress, [PROGRESS])
        self.assertEqual(terminal["files"], {"a.js": b"one two", "index.html": b""})
        self.assertEqual(terminal["diagnostics"], ["output: bundling"])
        self.assertEqual(stack.output_bytes(terminal, "a.js"), b"one two")

    def test_a_refusal_keeps_nothing_of_the_lines_before_it(self):
        refusal = {"version": stack.VERSION, "type": "refusal", "class": "failed", "reason": {"status": 2}}
        _progress, terminal = stack.read_answer([output("a.js", 1, b"x"), refusal])
        self.assertNotIn("files", terminal)
        self.assertIsNone(stack.output_bytes(terminal, "a.js"))

    def test_a_line_out_of_order_fails(self):
        with self.assertRaises(SystemExit):
            stack.read_answer([output("a.js", 2, b"x"), result({"a.js": b"x"})])

    def test_a_path_come_back_to_fails(self):
        with self.assertRaises(SystemExit):
            stack.read_answer([output("a", 1, b"x"), output("b", 2, b"y"), output("a", 3, b"z"),
                               result({"a": b"xz", "b": b"y"})])

    def test_a_result_naming_other_files_or_digests_fails(self):
        for named in ({"a": b"x", "b": b"y"}, {"a": b"y"}):
            with self.assertRaises(SystemExit):
                stack.read_answer([output("a", 1, b"x"), result(named)])


def vector_lines(vector):
    """A stream's lines: the vector's own, or those it names synthesized as every reader synthesizes them."""
    if "lines" in vector:
        return [json.loads(line) for line in vector["lines"]]
    synthesize = vector["synthesize"]
    if "files" in synthesize:
        return [output(f"f/{seq}.bin", seq, b"\0") for seq in range(1, synthesize["files"] + 1)]
    most = stack.WIRE["bounds"]["max_chunk_bytes"]
    full = output("big.bin", 1, bytes(most))
    lines, left = [], synthesize["bytes"]
    while left:
        lines.append({**full, "seq": len(lines) + 1} if left >= most else output("big.bin", len(lines) + 1, bytes(left)))
        left -= min(left, most)
    return lines


class Streams(unittest.TestCase):
    def test_every_stream_of_the_vectors_reads_as_they_say(self):
        for vector in stack.WIRE["lines"]["streams"]:
            with self.subTest(vector["name"]):
                lines = vector_lines(vector)
                if "error" in vector:
                    with self.assertRaises(SystemExit) as caught:
                        stack.read_answer(lines)
                    self.assertEqual(getattr(caught.exception, "error", None), vector["error"], caught.exception)
                    continue
                _progress, terminal = stack.read_answer(lines)
                if "refusal" in vector:
                    self.assertEqual({"class": terminal["class"], "reason": terminal["reason"]}, vector["refusal"])
                    self.assertNotIn("files", terminal)
                else:
                    self.assertEqual(terminal["files"], {path: base64.b64decode(data) for path, data in vector["outputs"].items()})
                    self.assertEqual(terminal["diagnostics"], vector["diagnostics"])


if __name__ == "__main__":
    unittest.main()
