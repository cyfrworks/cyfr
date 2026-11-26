# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builds memory suite's cgroup reads, keeper-client output collection and measured build.

That no keeper cgroup is left is answered only by the word `absent` from a
command that exits 0. A failed exec, and output that answers neither word, are
no answer. The client places each spawn before it sends it and names no bound
on it; a spawn it sends with a member the keeper does not know is refused
without its id, matched to its spawn in the order sent, and its place dropped.
A closed relay's output is read in full before the client reports. The
measured build is read
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
    """Rest's memory.max, over the builds, is read from a command that exits 0: a failed read fails the observation, and the value read is the control."""

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
                json.dump({"v": memory.V, "pool": "probe", "timeout_ms": 5000, "spawns": [
                    {"name": "short", "argv": ["sh", "-c", "echo ran"]},
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
                            parent.sendall(json.dumps({"v": 8, "type": "placed", "id": place["id"],
                                                       "memory_bytes": memory.BOUND}).encode() + b"\n")
                            request = json.loads(lines.readline())
                        self.assertEqual(place, {"v": 8, "type": "place", "id": "p1", "kind": "build"})
                        self.assertEqual((request["v"], request["type"], request["place"]), (8, "spawn", "p1"))
                        self.assertFalse({"memory_bytes", "cpu_quota"} & request.keys(), request)
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
                            {"v": 8, "type": "spawned", "id": request["id"], "spawn_id": spawn_id, "uid": stack.POOL_FIRST, "pid": 1},
                            {"v": 8, "type": "exited", "spawn_id": spawn_id, "code": 0, "signal": None, "memory": None},
                            {"v": 8, "type": "released", "spawn_id": spawn_id},
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
    """A keeper on the client's channel, answering as cyfr-locus does: a place `placed` with a build's bound; a spawn
    with a member the protocol does not know refused without its id; any other spawn `spawned`, its relay
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
            send({"v": 8, "type": "placed", "id": request["id"], "memory_bytes": memory.BOUND})
        elif request["type"] == "spawn" and request.keys() & {"memory_bytes", "cpu_quota"}:
            send({"v": 8, "type": "error", "code": "bad_request"})
        elif request["type"] == "spawn":
            send({"v": 8, "type": "spawned", "id": request["id"], "spawn_id": SPAWN_ID, "uid": stack.POOL_FIRST, "pid": 4242})
            relay = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            relay.connect(request["attach"]["path"])
            relay.sendall(frame(3, request["attach"]["token"].encode())
                          + frame(1, f"> measured@0.0.1 build\n> node build.mjs\n\n{memory.HOLDING}\n".encode()))
        elif request["type"] == "release":
            releasing = True
        elif request["type"] == "measure":
            measures += 1
            if free or measures == 1:
                send({"v": 8, "type": "error", "id": request["id"], "code": "unmeasured"})
            else:
                send({"v": 8, "type": "measured", "id": request["id"], **owner, "bytes": memory.HELD + (90 << 20), "lesser": False,
                      "age_ms": 0})
            if releasing:
                send({"v": 8, "type": "exited", "spawn_id": SPAWN_ID, "code": None, "signal": "SIGKILL", "memory": None})
                relay.sendall(frame(1, b"") + frame(2, b""))
                relay.close()
                send({"v": 8, "type": "released", "spawn_id": SPAWN_ID})
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
            json.dump({"v": memory.V, "pool": "probe", "timeout_ms": 10_000, "measure": memory.MEASURE,
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
        self.assertEqual(self.requests[0], {"v": 8, "type": "place", "id": "p1", "kind": "build", "athanor": memory.ATHANOR})
        self.assertEqual({key: self.requests[1][key] for key in ("v", "id", "place", "pool")},
                         {"v": 8, "id": "1", "place": "p1", "pool": "probe"})
        self.assertFalse({"memory_bytes", "cpu_quota"} & self.requests[1].keys(), self.requests[1])
        self.assertEqual(self.requests[-3], {"v": 8, "type": "release", "spawn_id": SPAWN_ID, "grace_ms": 0})
        measures = [request for request in self.requests if request["type"] == "measure"]
        self.assertEqual(measures, [{"v": 8, "type": "measure", "id": f"m{n}", "place": "p1"} for n in range(1, len(measures) + 1)])

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

    def test_a_place_answered_without_a_builds_bound_fails(self):
        def edit(spawn):
            spawn["replies"][0]["memory_bytes"] = memory.BOUND // 4
        self.fails(self.spawn(edit), "placed with a build's bound")


class RefusedSpawns(unittest.TestCase):
    """The scenario's spawns that name a bound of their own, against a keeper that refuses each without its id, as
    cyfr-locus refuses a member it does not know: each refusal is the spawn's sent in that order, and its place is
    dropped."""

    def test_each_refusal_is_its_spawns_in_the_order_sent_and_its_place_is_dropped(self):
        directory = tempfile.mkdtemp(prefix="memory-refused-")
        self.addCleanup(shutil.rmtree, directory, True)
        client_path = os.path.join(directory, "client.mjs")
        scenario_path = os.path.join(directory, "scenario.json")
        refused = [spawn for spawn in memory.scenario() if spawn["name"] in memory.REFUSED]
        with open(client_path, "w") as out:
            out.write(memory.CLIENT)
        with open(scenario_path, "w") as out:
            json.dump({"v": memory.V, "pool": "probe", "timeout_ms": 10_000, "spawns": refused}, out)
        parent, child = socket.socketpair()
        self.addCleanup(parent.close)
        process = subprocess.Popen(["/bin/sh", "-c", 'exec 3<&"$1"; exec node "$2" "$3"', "client", str(child.fileno()),
                                    client_path, scenario_path],
                                   pass_fds=(child.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env={**os.environ, "RELEASE_TMP": directory})
        child.close()
        requests = []
        serving = threading.Thread(target=keeper, args=(parent, requests), daemon=True)
        serving.start()
        try:
            stdout, stderr = process.communicate(timeout=20)
        finally:
            process.kill()
            process.communicate()
        serving.join(5)
        self.assertEqual(process.returncode, 0, stderr.decode())
        report = json.loads(stdout.split(b"<<<", 1)[1].split(b">>>", 1)[0])
        self.assertFalse(report["timed_out"])
        self.assertEqual([(r["type"], r.get("id") or r.get("place")) for r in requests],
                         [("place", "p1"), ("place", "p2"), ("spawn", "1"), ("spawn", "2"), ("drop", "p1"), ("drop", "p2")])
        self.assertEqual([{key: requests[n][key] for key in ("memory_bytes", "cpu_quota") if key in requests[n]} for n in (2, 3)],
                         [spawn["extra"] for spawn in refused])
        self.assertEqual(requests[4], {"v": 8, "type": "drop", "place": "p1"})
        self.assertEqual([[{k: v for k, v in r.items() if k not in ("at_ms", "seq")} for r in spawn["replies"]]
                          for spawn in report["spawns"]],
                         [[{"v": 8, "type": "placed", "id": f"p{n}", "memory_bytes": memory.BOUND},
                           {"v": 8, "type": "error", "code": "bad_request", "id": str(n)}] for n in (1, 2)])


HOLDER_BYTES = memory.ROOM_HELD + (40 << 20)


def room_keeper(sock, requests):
    """A keeper on the room client's channel, answering as cyfr-locus does at ROOM_WORK: the holder's place `placed`
    with a build's bound and its spawn `spawned`, its relay attached; a measure `unmeasured` until the place's first
    reading, then HOLDER_BYTES under the holder's owner; each asker refused `no_memory` with `held` (the keeper's
    wait is not kept here); the release answered `exited` and `released`; and a place after it `placed`. Every
    request is kept in `requests`."""

    def send(reply):
        sock.sendall(json.dumps(reply, separators=(",", ":")).encode() + b"\n")

    holder, measures, relay, released = None, 0, None, False
    for line in sock.makefile("rb"):
        request = json.loads(line)
        requests.append(request)
        kind = request["type"]
        if kind == "place" and request["id"] == memory.ROOM_HOLDER["place"]:
            holder = request
            send({"v": 8, "type": "placed", "id": request["id"], "memory_bytes": memory.BOUND})
        elif kind == "spawn":
            send({"v": 8, "type": "spawned", "id": request["id"], "spawn_id": SPAWN_ID, "uid": stack.POOL_FIRST, "pid": 4242})
            relay = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            relay.connect(request["attach"]["path"])
            relay.sendall(frame(3, request["attach"]["token"].encode()))
        elif kind == "measure":
            measures += 1
            if measures == 1:
                send({"v": 8, "type": "error", "id": request["id"], "code": "unmeasured"})
            else:
                send({"v": 8, "type": "measured", "id": request["id"], "kind": "build", "athanor": holder["athanor"],
                      "subject": holder["subject"], "bytes": HOLDER_BYTES, "lesser": False, "age_ms": 0})
        elif kind == "place" and released:
            send({"v": 8, "type": "placed", "id": request["id"], "memory_bytes": memory.BOUND})
        elif kind == "place":
            mine = request["athanor"] == holder["athanor"]
            send({"v": 8, "type": "error", "id": request["id"], "code": "no_memory", "held": {
                "need": memory.BUILD_ALLOWANCE, "free": memory.ROOM_WORK - HOLDER_BYTES,
                "mine": [{"kind": "build", "subject": holder["subject"], "bytes": HOLDER_BYTES}] if mine else [],
                "others_bytes": 0 if mine else HOLDER_BYTES}})
        elif kind == "release":
            send({"v": 8, "type": "exited", "spawn_id": SPAWN_ID, "code": None, "signal": "SIGKILL", "memory": None})
            relay.close()
            send({"v": 8, "type": "released", "spawn_id": SPAWN_ID})
            released = True


class Room(unittest.TestCase):
    """The room client against a keeper on its fd 3, and the verdict on what it reported: the verdict takes the
    report with each refusal moved to the room's wait after its place, since the stand-in answers at once."""

    @classmethod
    def setUpClass(cls):
        directory = tempfile.mkdtemp(prefix="memory-room-")
        cls.addClassCleanup(shutil.rmtree, directory, True)
        client_path = os.path.join(directory, "client.mjs")
        scenario_path = os.path.join(directory, "scenario.json")
        with open(client_path, "w") as out:
            out.write(memory.ROOM_CLIENT)
        with open(scenario_path, "w") as out:
            json.dump({**memory.room_scenario(), "timeout_ms": 10_000, "stay": False}, out)
        parent, child = socket.socketpair()
        cls.addClassCleanup(parent.close)
        process = subprocess.Popen(["/bin/sh", "-c", 'exec 3<&"$1"; exec node "$2" "$3"', "client", str(child.fileno()),
                                    client_path, scenario_path],
                                   pass_fds=(child.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env={**os.environ, "RELEASE_TMP": directory})
        child.close()
        cls.requests = []
        serving = threading.Thread(target=room_keeper, args=(parent, cls.requests), daemon=True)
        serving.start()
        try:
            stdout, cls.stderr = process.communicate(timeout=20)
        finally:
            process.kill()
            process.communicate()
        serving.join(5)
        cls.returncode = process.returncode
        cls.reported = json.loads(stdout.split(b"<<<", 1)[1].split(b">>>", 1)[0]) if b"<<<" in stdout else None

    def report(self, edit=None, waited=memory.ROOM_WAIT_MS + 400):
        """The client's report, each refusal `waited` ms after its place, a copy given by `edit` of it."""
        report = json.loads(json.dumps(self.reported))
        for asker in report["askers"]:
            for reply in asker["replies"]:
                reply["at_ms"] = asker["sent_ms"] + waited
        if edit:
            edit(report)
        return report

    def fails(self, report, check):
        """The verdict on `report` fails at the check whose message holds `check`."""
        with self.assertRaises(SystemExit) as failed:
            memory.judge_room(report)
        self.assertIn(check, str(failed.exception.code).splitlines()[0])

    def test_the_client_holds_the_room_asks_twice_releases_and_asks_again(self):
        self.assertEqual(self.returncode, 0, self.stderr.decode())
        self.assertFalse(self.reported["timed_out"])
        holder, (mine, other) = memory.ROOM_HOLDER, memory.ROOM_ASKERS
        spawn = self.requests[1]
        self.assertEqual({key: spawn[key] for key in ("v", "type", "id", "place", "pool", "argv", "env")},
                         {"v": 8, "type": "spawn", "id": "holder-spawn", "place": holder["place"], "pool": "probe",
                          "argv": memory.room_scenario()["holder"]["argv"], "env": {}})
        self.assertFalse({"memory_bytes", "cpu_quota"} & spawn.keys(), spawn)
        self.assertEqual([request for n, request in enumerate(self.requests) if n != 1], [
            {"v": 8, "type": "place", "id": holder["place"], "kind": "build", "athanor": holder["athanor"],
             "subject": holder["subject"]},
            {"v": 8, "type": "measure", "id": "m1", "place": holder["place"]},
            {"v": 8, "type": "measure", "id": "m2", "place": holder["place"]},
            {"v": 8, "type": "place", "id": mine["place"], "kind": "build", "athanor": mine["athanor"]},
            {"v": 8, "type": "place", "id": other["place"], "kind": "build", "athanor": other["athanor"]},
            {"v": 8, "type": "release", "spawn_id": SPAWN_ID, "grace_ms": 0},
            {"v": 8, "type": "place", "id": mine["place"], "kind": "build", "athanor": mine["athanor"]},
            {"v": 8, "type": "drop", "place": mine["place"]},
        ])

    def test_refusals_after_the_wait_with_held_whole_and_a_place_after_the_release_pass(self):
        memory.judge_room(self.report())

    def test_a_refusal_before_the_wait_or_past_its_second_fails(self):
        for waited in (memory.ROOM_WAIT_MS - 1, memory.ROOM_WAIT_MS + memory.ROOM_LATE_MS):
            with self.subTest(waited=waited):
                self.fails(self.report(waited=waited), "refused after the room's wait")

    def test_an_asker_placed_while_the_holder_holds_the_room_fails(self):
        def edit(report):
            report["askers"][1]["replies"][0] = {**report["askers"][1]["replies"][0], "type": "placed",
                                                 "memory_bytes": memory.BOUND}
        self.fails(self.report(edit), "is not placed while the holder holds the room")

    def test_a_holder_charged_its_allowance_and_not_its_reading_fails(self):
        def edit(report):
            for asker in report["askers"]:
                held = asker["replies"][0]["held"]
                held["free"] = memory.ROOM_WORK - memory.BUILD_ALLOWANCE
                for holding in held["mine"]:
                    holding["bytes"] = memory.BUILD_ALLOWANCE
                if held["others_bytes"]:
                    held["others_bytes"] = memory.BUILD_ALLOWANCE
        self.fails(self.report(edit), "charges the holder its reading")

    def test_a_held_missing_the_holder_among_its_athanors_places_fails(self):
        def edit(report):
            report["askers"][0]["replies"][0]["held"]["mine"] = []
        self.fails(self.report(edit), "charges the holder its reading")

    def test_a_held_whose_parts_do_not_hold_together_fails(self):
        edits = {
            "free not the work less the holder": lambda held: held.update(free=held["free"] - 1),
            "need not a build's allowance": lambda held: held.update(need=memory.BOUND),
            "the holder's subject left out": lambda held: [holding.pop("subject") for holding in held["mine"]],
            "the holder counted twice": lambda held: held.update(others_bytes=HOLDER_BYTES),
        }
        for name, change in edits.items():
            with self.subTest(name):
                self.fails(self.report(lambda report: change(report["askers"][0]["replies"][0]["held"])), "held is whole")

    def test_another_athanors_held_naming_the_holder_fails(self):
        def edit(report):
            report["askers"][1]["replies"][0]["held"]["mine"] = [
                {"kind": "build", "subject": memory.ROOM_HOLDER["subject"], "bytes": HOLDER_BYTES}]
        self.fails(self.report(edit), "held is whole")

    def test_a_place_after_the_release_that_waits_or_is_refused_fails(self):
        def late(report):
            report["again"]["replies"][0]["at_ms"] = report["again"]["sent_ms"] + memory.ROOM_AT_ONCE_MS
        def refused(report):
            report["again"]["replies"][0] = {**report["askers"][0]["replies"][0], "seq": report["again"]["replies"][0]["seq"]}
        for edit in (late, refused):
            with self.subTest(edit.__name__):
                self.fails(self.report(edit), "placed again is placed at once")


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
