# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builds memory suite's cgroup reads, keeper-client output collection and measured build.

That no keeper cgroup is left is answered only by the word `absent` from a
command that exits 0. A failed exec, and output that answers neither word, are
no answer. The client places each spawn before it sends it. A closed relay's
output is read in full before the client reports. The measured build is read
until a reading taken after it holds its memory, released with a measure, and
measured after `released`; the verdict refuses a reading under another owner,
one taken before the build held its memory, one answered only after
`released` and a place read after it.

Usage: python3 -I tests/builder-image/memory_test.py
"""

import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import memory  # noqa: E402
import stack  # noqa: E402
import imagesuite  # noqa: E402

CONTAINER = "cyfr-locus-1"
# The builds pool's first two uids, from the suite's own constants, which read the role table.
GROUPS = [f"{memory.ROLE_GROUP}/keeper-{stack.POOL_FIRST}", f"{memory.ROLE_GROUP}/keeper-{stack.POOL_FIRST + 1}"]


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
        reads = {f"cat {memory.BOUND_GROUP}/memory.events": events, f"cat {memory.BOUND_GROUP}/memory.current": current}

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
    """The builds role's memory.max is read from a command that exits 0: a failed read fails the observation, and the value read is the control."""

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


def frame(stream, payload):
    return bytes([stream]) + struct.pack(">I", len(payload)) + payload


class ClientOutput(unittest.TestCase):
    def test_a_closed_relay_delivers_every_byte_before_the_client_reports(self):
        with tempfile.TemporaryDirectory(prefix="memory-client-") as directory:
            client_path = os.path.join(directory, "client.mjs")
            scenario_path = os.path.join(directory, "scenario.json")
            with open(client_path, "w") as out:
                out.write(memory.CLIENT.replace("stdout: stdout.slice(-400)", "stdout"))
            with open(scenario_path, "w") as out:
                json.dump({"pool": "probe", "timeout_ms": 5000, "spawns": [
                    {"name": "short", "argv": ["sh", "-c", "echo ran"], "memory_bytes": memory.MIN_BOUND},
                ]}, out)

            for trial in range(32):
                with self.subTest(trial=trial):
                    parent, child = socket.socketpair()
                    process = subprocess.Popen(
                        ["/bin/sh", "-c", 'exec 3<&"$1"; exec node "$2" "$3"', "client",
                         str(child.fileno()), client_path, scenario_path],
                        pass_fds=(child.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        env={**os.environ, "RELEASE_TMP": directory})
                    child.close()
                    try:
                        parent.settimeout(5)
                        with parent.makefile("rb") as lines:
                            place = json.loads(lines.readline())
                            parent.sendall(json.dumps({"v": 6, "type": "placed", "id": place["id"]}).encode() + b"\n")
                            request = json.loads(lines.readline())
                        self.assertEqual(place, {"v": 6, "type": "place", "id": "p1", "kind": "build"})
                        self.assertEqual((request["v"], request["type"], request["place"]), (6, "spawn", "p1"))
                        os.kill(process.pid, signal.SIGSTOP)
                        _, status = os.waitpid(process.pid, os.WUNTRACED)
                        self.assertTrue(os.WIFSTOPPED(status))
                        output = subprocess.check_output(["/bin/sh", "-c", "printf '%0130000dran\\n' 0"])
                        # A closed peer makes a late stdin write fail before the
                        # next read. Stopping the client fixes that order.
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as relay:
                            relay.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
                            relay.connect(request["attach"]["path"])
                            packet = frame(3, request["attach"]["token"].encode())
                            packet += b"".join(frame(1, output[i:i + 65536]) for i in range(0, len(output), 65536))
                            relay.sendall(packet + frame(1, b"") + frame(2, b""))
                        spawn_id = "a" * 32
                        for reply in (
                            {"v": 6, "type": "spawned", "id": request["id"], "spawn_id": spawn_id, "uid": stack.POOL_FIRST, "pid": 1},
                            {"v": 6, "type": "exited", "spawn_id": spawn_id, "code": 0, "signal": None, "memory": None},
                            {"v": 6, "type": "released", "spawn_id": spawn_id},
                        ):
                            parent.sendall(json.dumps(reply).encode() + b"\n")
                        os.kill(process.pid, signal.SIGCONT)
                        stdout, stderr = process.communicate(timeout=8)
                        self.assertEqual(process.returncode, 0, stderr.decode())
                        report = json.loads(stdout.split(b"<<<", 1)[1].split(b">>>", 1)[0])
                        self.assertFalse(report["timed_out"])
                        self.assertEqual(report["spawns"][0]["stdout"], output.decode())
                    finally:
                        if process.poll() is None:
                            os.kill(process.pid, signal.SIGCONT)
                            process.kill()
                        process.communicate()
                        parent.close()


SPAWN_ID = "b" * 32


def keeper(sock, requests):
    """A keeper on the client's channel, answering as cyfr-locus does: a place `placed`; a spawn `spawned`, its relay
    attached and the build's stdout sent, ending in the line it prints once it holds its memory; a measure `unmeasured`
    until the place's first reading, which the first measure finds missing, then the reading, just taken, under the
    place's owner; a measure sent with a release is answered before `exited` and `released`, and one after is
    `unmeasured`. Every request is kept in `requests`."""

    def send(reply):
        sock.sendall(json.dumps(reply, separators=(",", ":")).encode() + b"\n")

    owner, relay, measures, releasing, free = None, None, 0, False, False
    for line in sock.makefile("rb"):
        request = json.loads(line)
        requests.append(request)
        if request["type"] == "place":
            owner = {key: request[key] for key in ("kind", "athanor") if key in request}
            send({"v": 6, "type": "placed", "id": request["id"]})
        elif request["type"] == "spawn":
            send({"v": 6, "type": "spawned", "id": request["id"], "spawn_id": SPAWN_ID, "uid": stack.POOL_FIRST, "pid": 4242})
            relay = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            relay.connect(request["attach"]["path"])
            relay.sendall(frame(3, request["attach"]["token"].encode())
                          + frame(1, f"> measured@0.0.1 build\n> node build.mjs\n\n{memory.HOLDING}\n".encode()))
        elif request["type"] == "release":
            releasing = True
        elif request["type"] == "measure":
            measures += 1
            if free or measures == 1:
                send({"v": 6, "type": "error", "id": request["id"], "code": "unmeasured"})
            else:
                send({"v": 6, "type": "measured", "id": request["id"], **owner, "bytes": memory.HELD + (90 << 20), "lesser": False,
                      "age_ms": 0})
            if releasing:
                send({"v": 6, "type": "exited", "spawn_id": SPAWN_ID, "code": None, "signal": "SIGKILL", "memory": None})
                relay.sendall(frame(1, b"") + frame(2, b""))
                relay.close()
                send({"v": 6, "type": "released", "spawn_id": SPAWN_ID})
                releasing, free = False, True


class MeasuredBuild(unittest.TestCase):
    """The client's measured build against a keeper on its fd 3, and the verdict on what it reported."""

    @classmethod
    def setUpClass(cls):
        directory = tempfile.mkdtemp(prefix="memory-measured-")
        cls.addClassCleanup(shutil.rmtree, directory, True)
        client_path = os.path.join(directory, "client.mjs")
        scenario_path = os.path.join(directory, "scenario.json")
        with open(client_path, "w") as out:
            out.write(memory.CLIENT)
        with open(scenario_path, "w") as out:
            json.dump({"pool": "probe", "timeout_ms": 10_000, "measure": memory.MEASURE,
                       "spawns": [spawn for spawn in memory.scenario() if spawn.get("measure")]}, out)
        parent, child = socket.socketpair()
        cls.addClassCleanup(parent.close)
        process = subprocess.Popen(["/bin/sh", "-c", 'exec 3<&"$1"; exec node "$2" "$3"', "client", str(child.fileno()),
                                    client_path, scenario_path],
                                   pass_fds=(child.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env={**os.environ, "RELEASE_TMP": directory})
        child.close()
        cls.requests = []
        serving = threading.Thread(target=keeper, args=(parent, cls.requests), daemon=True)
        serving.start()
        try:
            stdout, cls.stderr = process.communicate(timeout=20)
        finally:
            process.kill()
            process.communicate()
        serving.join(5)
        cls.returncode = process.returncode
        cls.report = json.loads(stdout.split(b"<<<", 1)[1].split(b">>>", 1)[0]) if b"<<<" in stdout else None

    def spawn(self, edit=None):
        """The build as the client reported it, a copy given by `edit` of it."""
        spawn = json.loads(json.dumps(self.report["spawns"][0]))
        if edit:
            edit(spawn)
        return spawn

    def fails(self, spawn, check):
        """The verdict on `spawn` fails at the check whose message holds `check`."""
        with self.assertRaises(SystemExit) as failed:
            memory.judge_build(spawn)
        self.assertIn(check, str(failed.exception.code).splitlines()[0])

    def test_the_client_places_the_build_reads_it_and_releases_it_with_a_measure(self):
        self.assertEqual(self.returncode, 0, self.stderr.decode())
        self.assertFalse(self.report["timed_out"])
        types = [request["type"] for request in self.requests]
        self.assertEqual(types[:2], ["place", "spawn"])
        self.assertEqual(types[-3:], ["release", "measure", "measure"])
        self.assertEqual(set(types[2:-3]), {"measure"})
        self.assertEqual(self.requests[0], {"v": 6, "type": "place", "id": "p1", "kind": "build", "athanor": memory.ATHANOR})
        self.assertEqual({key: self.requests[1][key] for key in ("v", "id", "place", "pool", "memory_bytes")},
                         {"v": 6, "id": "1", "place": "p1", "pool": "probe", "memory_bytes": memory.BOUND})
        self.assertEqual(self.requests[-3], {"v": 6, "type": "release", "spawn_id": SPAWN_ID, "grace_ms": 0})
        measures = [request for request in self.requests if request["type"] == "measure"]
        self.assertEqual(measures, [{"v": 6, "type": "measure", "id": f"m{n}", "place": "p1"} for n in range(1, len(measures) + 1)])

    def test_a_build_read_under_its_owner_and_free_only_after_released_passes(self):
        memory.judge_build(self.spawn())

    def test_a_reading_under_another_owner_fails(self):
        def edit(spawn):
            spawn["measures"][-3]["reply"]["athanor"] = "ath_other"
        self.fails(self.spawn(edit), "while the build runs")

    def test_a_reading_taken_before_the_build_held_its_memory_fails(self):
        def edit(spawn):
            spawn["holding_ms"] = spawn["measures"][-3]["at_ms"]
        self.fails(self.spawn(edit), "counts them")

    def test_a_reading_answered_only_after_released_fails(self):
        def edit(spawn):
            spawn["measures"][-2]["seq"] = spawn["replies"][-1]["seq"] + 1
        self.fails(self.spawn(edit), "answered before its released")

    def test_a_place_read_after_released_fails(self):
        def edit(spawn):
            spawn["measures"][-1]["reply"] = {**spawn["measures"][-2]["reply"], "id": spawn["measures"][-1]["id"]}
        self.fails(self.spawn(edit), "the build's place is free")


class Brief(unittest.TestCase):
    def test_a_result_carrying_its_files_shows_each_by_its_size(self):
        _progress, answer = stack.read_answer([
            {"type": "output", "seq": 1, "path": "index.html", "bytes": "aGk="},
            {"type": "result", "language": "javascript", "target_type": "tincture",
             "outputs": [{"path": "index.html", "size": 2,
                          "digest": "sha256:8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4"}]},
        ])
        shown = json.loads(memory.brief(answer))
        self.assertEqual(shown["files"], {"index.html": "2 bytes"})


if __name__ == "__main__":
    unittest.main()
