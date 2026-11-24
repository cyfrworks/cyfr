# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The backends memory suite's reads of the cgroup limits and of a group's memory, with the exec stubbed.

A cgroup path or limit that cannot be read is no answer: a failed read fails
the observation, rather than reading as an empty path or an empty limit, and
the values that were read are the control. A group's memory is its current
and peak bytes and its two kill counters, each read or failed. The flood
program waits for its line, then writes exactly its lines; the endless one
waits for its line, then writes until it is killed, SIGTERM or not. What an unread
session kept is its newest lines, whole and in order, or nothing yet; and a
round of the session read as it comes fails on a drop. The flood's
allowance is the role table's factor times what the service counts and its
spawns' keeper reads, and their relays' queues.

Usage: python3 -I tests/locus-backends-image/memory_test.py
"""

import os
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import memory  # noqa: E402


class Exec:
    """An observer whose execs answer `answers` in order, each as (exit status, stdout); (0, "") once none is left."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.scripts = []

    def exec(self, script, user=None):
        self.scripts.append(script)
        status, stdout = self.answers.pop(0) if self.answers else (0, "")
        return subprocess.CompletedProcess([], status, stdout, "" if status == 0 else "daemon error")


EVENTS = "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n"


class CgroupLimit(unittest.TestCase):
    def test_a_failed_path_read_fails_the_cgroup_read(self):
        with self.assertRaises(SystemExit):
            memory.cgroup_limit(Exec((2, "")), 4242)

    def test_a_failed_limit_read_fails_it_and_is_not_read_as_empty(self):
        with self.assertRaises(SystemExit):
            memory.cgroup_limit(Exec((0, "/system.slice/x\n"), (1, "")), 4242)

    def test_the_path_and_limit_that_were_read_are_the_control(self):
        self.assertEqual(memory.cgroup_limit(Exec((0, "/system.slice/x\n"), (0, "134217728\n")), 4242),
                         ("/system.slice/x", "134217728"))


class ContainerLimit(unittest.TestCase):
    def test_a_failed_read_fails_the_container_limit(self):
        with self.assertRaises(SystemExit):
            memory.container_limit(Exec((1, "")))

    def test_the_limit_that_was_read_is_the_control(self):
        self.assertEqual(memory.container_limit(Exec((0, "max\n"))), "max")


class GroupMemory(unittest.TestCase):
    def test_the_counts_that_were_read_are_the_control(self):
        observer = Exec((0, EVENTS), (0, "1048576\n"), (0, "2097152\n"))
        read = memory.group_memory(observer)
        self.assertEqual((read["current"], read["peak"], read["events"]["oom"], read["events"]["oom_kill"]),
                         (1048576, 2097152, 0, 0))
        self.assertEqual(observer.scripts, ["cat /sys/fs/cgroup/keeper/memory.events",
                                            "cat /sys/fs/cgroup/keeper/memory.current",
                                            "cat /sys/fs/cgroup/keeper/memory.peak"])

    def test_a_failed_read_of_any_fails_it(self):
        for answers in [[(1, "")], [(0, EVENTS), (1, "")], [(0, EVENTS), (0, "1\n"), (1, "")]]:
            with self.subTest(answers=answers), self.assertRaises(SystemExit):
                memory.group_memory(Exec(*answers))

    def test_a_count_that_is_not_a_number_of_bytes_fails_it(self):
        with self.assertRaises(SystemExit):
            memory.group_memory(Exec((0, EVENTS), (0, "max\n")))

    def test_events_without_a_kill_counter_fail_it(self):
        with self.assertRaises(SystemExit):
            memory.group_memory(Exec((0, "oom 0\n")))


class FloodCommand(unittest.TestCase):
    def test_it_waits_for_its_line_then_writes_exactly_its_lines(self):
        command = memory.flood_command(7, 5).replace("exec sleep 3600", "exit 0")
        idle = subprocess.run(["/bin/sh", "-c", command], input="", capture_output=True, text=True, timeout=10)
        self.assertEqual(idle.stdout, "")
        flooded = subprocess.run(["/bin/sh", "-c", command], input="go\n", capture_output=True, text=True, timeout=10)
        self.assertEqual(flooded.stdout, "0000000\n" * 5)

    def test_it_stays_once_it_has_written(self):
        self.assertTrue(memory.flood_command(7, 5).endswith("; exec sleep 3600"))


class EndlessFloodCommand(unittest.TestCase):
    def test_it_waits_for_its_line(self):
        idle = subprocess.run(["/bin/sh", "-c", memory.endless_flood_command(7)], input="", capture_output=True,
                              text=True, timeout=10)
        self.assertEqual(idle.stdout, "")

    def test_it_writes_its_lines_past_sigterm_until_it_is_killed(self):
        flood = subprocess.Popen(["/bin/sh", "-c", memory.endless_flood_command(7)], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE)
        try:
            flood.stdin.write(b"go\n")
            flood.stdin.flush()
            self.assertEqual(flood.stdout.read(16), b"0000000\n" * 2)
            flood.terminate()
            # Past what a pipe holds: written after the signal.
            self.assertEqual(flood.stdout.read(1 << 20), b"0000000\n" * (1 << 17))
            self.assertIsNone(flood.poll())
        finally:
            flood.kill()
            flood.wait(timeout=10)


def line(seq, text="0" * 4):
    return {"seq": seq, "text": text}


class Kept(unittest.TestCase):
    def test_the_newest_lines_whole_and_in_order_are_what_it_kept(self):
        answer = {"lines": [line(4), line(5), line(6)], "dropped": 3}
        self.assertEqual(memory.kept(answer, 6, 4), (3, 3))

    def test_nothing_is_kept_until_its_last_line_is_in(self):
        self.assertIsNone(memory.kept({"lines": [line(1), line(2)], "dropped": 0}, 6, 4))
        self.assertIsNone(memory.kept({"lines": [], "dropped": 6}, 6, 4))

    def test_a_gap_an_uncounted_drop_or_a_changed_line_fails_the_suite(self):
        for answer in [{"lines": [line(4), line(6)], "dropped": 3},
                       {"lines": [line(5), line(6)], "dropped": 3},
                       {"lines": [line(5), line(6, "0001")], "dropped": 4}]:
            with self.subTest(answer=answer), self.assertRaises(SystemExit):
                memory.kept(answer, 6, 4)


class Reading(Exec):
    """A controller whose session echoes what it is sent, `per` lines an answer, every answer telling `dropped`."""

    def __init__(self, per, dropped=0):
        super().__init__()
        self.per, self.dropped, self.echoed, self.seq = per, dropped, [], 0

    def send(self, owner, session, lines):
        for text in lines:
            self.seq += 1
            self.echoed.append({"seq": self.seq, "text": text})
        return 200, {"status": "running"}

    def recv(self, owner, session, after, max_wait_ms):
        lines = [entry for entry in self.echoed if entry["seq"] > after][:self.per]
        return 200, {"lines": lines, "dropped": self.dropped, "running": True}


class ReadRound(unittest.TestCase):
    def test_a_round_reads_back_every_line_it_sent_and_answers_the_last_read(self):
        reading = Reading(per=10)
        self.assertEqual(memory.read_round(reading, {}, "s", 0, 0), memory.ROUND)
        self.assertEqual(memory.read_round(reading, {}, "s", memory.ROUND, 1), 2 * memory.ROUND)
        self.assertEqual([entry["text"][:4] for entry in reading.echoed][memory.ROUND:memory.ROUND + 2], ["1:0:", "1:1:"])

    def test_a_drop_fails_it(self):
        with self.assertRaises(SystemExit):
            memory.read_round(Reading(per=10, dropped=1), {}, "s", 0, 0)


class Allowance(unittest.TestCase):
    """The flood's allowance is the role table's: the factor times the counted bounds and each spawn's keeper read, and each spawn's relay queue."""

    def test_with_no_spawn_it_is_the_factor_times_the_counted_bounds(self):
        shared, own = memory.RELEASE["memory"], memory.ROLE["memory"]
        self.assertEqual(memory.allowance(0), int(shared["byte_cost"] * (own["unread"] + own["answering"])))

    def test_each_spawn_adds_its_keeper_read_at_the_factor_and_its_relay_queue(self):
        shared = memory.RELEASE["memory"]
        per_spawn = shared["byte_cost"] * shared["keeper_read_bytes"] * shared["keeper_read_copies"]
        added = memory.allowance(memory.SESSIONS) - memory.allowance(0)
        self.assertAlmostEqual(added, memory.SESSIONS * (per_spawn + shared["relay_queue_bytes"]), delta=1)


if __name__ == "__main__":
    unittest.main()
