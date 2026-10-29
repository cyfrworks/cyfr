# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builds headroom suite's reads of the cgroup files, with the exec stubbed.

A cgroup file that cannot be read is no answer, and a counter that is not
there is refused rather than read as zero: the no-kill assertion holds only on
counters that were read.

Usage: python3 -I tests/builder-image/headroom_test.py
"""

import os
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import stack  # noqa: E402
import headroom  # noqa: E402
import imagesuite  # noqa: E402


class Exec:
    """An observer whose exec exits `returncode` and prints `stdout`."""

    def __init__(self, returncode, stdout):
        self.result = subprocess.CompletedProcess([], returncode, stdout, "" if returncode == 0 else "daemon error")

    def exec(self, script, user=None):
        return self.result


class CgroupFiles(unittest.TestCase):
    def test_a_failed_read_fails_the_read(self):
        with self.assertRaises(SystemExit):
            headroom.read(Exec(1, ""), "memory.peak")

    def test_a_failed_read_fails_the_events_instead_of_reading_no_kills(self):
        with self.assertRaises(SystemExit):
            headroom.events(Exec(1, ""), "memory.events")

    def test_counters_that_were_read_are_the_control(self):
        events = headroom.events(Exec(0, "oom 1\noom_kill 1\n"), "memory.events")
        self.assertEqual(events, {"oom": 1, "oom_kill": 1})
        self.assertFalse(imagesuite.no_kills(events))
        self.assertTrue(imagesuite.no_kills(headroom.events(Exec(0, "oom 0\noom_kill 0\n"), "memory.events")))

    def test_a_counter_that_is_not_read_fails_the_events(self):
        with self.assertRaises(SystemExit):
            headroom.events(Exec(0, "oom 0\n"), "memory.events")


class ReleaseSetting(unittest.TestCase):
    """A setting is read from the release's eval, which must exit 0: a failed eval is no answer, even when it printed the marker."""

    def test_a_failed_eval_is_no_answer_even_with_the_marker_printed(self):
        with self.assertRaises(SystemExit):
            headroom.setting(Exec(1, "<<<5>>>\n"), "builds_memory_bytes")

    def test_the_setting_that_was_read_is_the_control(self):
        self.assertEqual(headroom.setting(Exec(0, "<<<5>>>\n"), "builds_memory_bytes"), 5)


if __name__ == "__main__":
    unittest.main()
