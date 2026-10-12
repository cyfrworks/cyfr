#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The credential canary's own checks, without the image: the streamed needle count against a count over the
whole buffer, across real chunk boundaries, and the observer verdicts against observers that fail, including
the home dump itself on a home it cannot read.

Usage: python3 -I tests/locus-runtime-image/canary_test.py
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import canary  # noqa: E402

SHORT = b"sk-1"
LONG = b"sk-canary-0123456789abcdef"


def chunked(buffer, size):
    return [buffer[i:i + size] for i in range(0, len(buffer), size)]


class CountStream(unittest.TestCase):
    def assert_whole(self, buffer, needles, sizes):
        """For each chunk size, the streamed count is the whole buffer's count of every needle."""
        for size in sizes:
            with self.subTest(size=size):
                chunks = chunked(buffer, size)
                self.assertGreater(len(chunks), 1, "the buffer must cross a chunk boundary")
                found, total = canary.count_stream(chunks, needles)
                self.assertEqual(total, len(buffer))
                self.assertEqual(found, {needle: buffer.count(needle) for needle in needles})

    def test_short_and_long_needles_straddling_a_boundary(self):
        # The short needle sits inside the long needle's kept tail at every
        # boundary, and both straddle boundaries for the sizes below.
        buffer = b"x" * 37 + SHORT + b"y" * 5 + LONG + b"z" * 3 + SHORT + LONG + b"q" * 11 + SHORT
        self.assert_whole(buffer, [SHORT, LONG], range(1, len(buffer)))

    def test_a_short_needle_wholly_in_the_kept_tail_is_counted_once(self):
        # A chunk of 40 ends 3 bytes after SHORT, which lies wholly in the
        # 25 bytes kept for LONG: counted in the first window only.
        buffer = b"a" * 33 + SHORT + b"bbb" + b"c" * 60
        self.assertEqual(len(chunked(buffer, 40)[0]), 40)
        found, _total = canary.count_stream(chunked(buffer, 40), [SHORT, LONG])
        self.assertEqual(found, {SHORT: 1, LONG: 0})

    def test_matches_never_overlap_as_with_a_whole_count(self):
        buffer = b"aaaaaaa" + b"-" * 9 + b"aaa"
        self.assert_whole(buffer, [b"aa", b"aaa", LONG], range(1, len(buffer)))

    def test_one_megabyte_chunks_as_the_canary_reads(self):
        size = 1 << 20
        buffer = b"\0" * (size - 10) + LONG + b"\0" * (size - 2) + SHORT + os.urandom(1000) + SHORT
        self.assert_whole(buffer, [SHORT, LONG], [size])


def fake(script):
    """An observer that runs `script` locally, as `sh -c` does in the container."""
    return ["sh", "-c", script, "sh"]


PLENTY = canary.MIN_DUMP_BYTES


class MemoryVerdict(unittest.TestCase):
    def account(self, total, unreadable=4, omitted=0, vanished=0, regions=200):
        return f"regions={regions} bytes={total} unreadable={unreadable} omitted={omitted} vanished={vanished}"

    def test_plausible_counters_then_a_non_zero_exit_are_rejected(self):
        seen = canary.observe(fake(f"head -c {PLENTY} /dev/zero; echo '{self.account(PLENTY)}' >&2; exit 1"),
                              [LONG])
        _found, total, said, status = seen
        problems, _omissions = canary.memory_verdict(status, total, said)
        self.assertIn("the observer exited 1", problems)
        self.assertEqual(total, PLENTY)

    def test_a_whole_dump_is_accepted(self):
        _found, total, said, status = canary.observe(
            fake(f"head -c {PLENTY} /dev/zero; echo '{self.account(PLENTY)}' >&2"), [LONG])
        self.assertEqual(canary.memory_verdict(status, total, said), ([], []))

    def test_a_kernel_omission_is_listed_and_accepted(self):
        said = "omitted ffff-10000 r--p [vvar]\nomitted 2000-3000 rw-s /dev/dri/card0\n" + self.account(PLENTY,
                                                                                                    omitted=2)
        problems, omissions = canary.memory_verdict(0, PLENTY, said)
        self.assertEqual(problems, [])
        self.assertEqual(omissions, ["omitted ffff-10000 r--p [vvar]", "omitted 2000-3000 rw-s /dev/dri/card0"])

    def test_a_vanished_mapping_is_listed_and_accepted(self):
        said = "vanished 1000-2000 rw-p \n" + self.account(PLENTY, vanished=1)
        self.assertEqual(canary.memory_verdict(0, PLENTY, said), ([], ["vanished 1000-2000 rw-p"]))

    def test_an_unexpected_omission_is_rejected(self):
        said = "omitted 1000-2000 rw-p [heap]\n" + self.account(PLENTY, omitted=1)
        problems, omissions = canary.memory_verdict(0, PLENTY, said)
        self.assertEqual(problems, ["the observer could not read omitted 1000-2000 rw-p [heap]"])
        self.assertEqual(omissions, ["omitted 1000-2000 rw-p [heap]"])

    def test_an_account_that_does_not_add_up_is_rejected(self):
        cases = {
            "unlisted omission": (PLENTY, self.account(PLENTY, omitted=1)),
            "bytes not written": (PLENTY - 1, self.account(PLENTY)),
            "too few bytes": (1024, self.account(1024)),
            "no account": (PLENTY, "regions=200 bytes=33554432"),
            "an error line": (PLENTY, "dd: /proc/7/mem: Input/output error\n" + self.account(PLENTY)),
            "nothing said": (PLENTY, ""),
        }
        for name, (total, said) in cases.items():
            with self.subTest(name):
                problems, _omissions = canary.memory_verdict(0, total, said)
                self.assertNotEqual(problems, [])

    def test_the_dump_script_parses(self):
        subprocess.run(["sh", "-n", "-c", canary.DUMP_MEMORY], check=True)


# A process whose memory this user may read: it lets any process trace it
# (PR_SET_PTRACER_ANY, for Yama's ptrace_scope 1), holds a needle in more
# than MIN_DUMP_BYTES of memory and waits for its stdin to close.
TARGET = r"""
import ctypes, sys
ctypes.CDLL(None).prctl(0x59616D61, ctypes.c_ulong(-1), 0, 0, 0)
held = bytearray(int(sys.argv[1]))
needle = bytes.fromhex(sys.argv[2])
held[4096:4096 + len(needle)] = needle
print("ready", flush=True)
sys.stdin.read()
"""


def gnu_dd():
    """A directory holding as `dd` a dd that reports its byte count on a failed read, as the image's GNU dd does
    and DUMP_MEMORY reads, or None."""
    for candidate in ("gnudd", "dd"):
        path = shutil.which(candidate)
        failed = path and subprocess.run([path, "if=/proc/self/mem", "bs=1", "count=1"], capture_output=True)
        if failed and failed.returncode != 0 and re.search(rb"^0 bytes", failed.stderr, re.M):
            directory = tempfile.mkdtemp(prefix="cyfr-canary-dd-")
            os.symlink(path, os.path.join(directory, "dd"))
            return directory
    return None


def ptrace_scope():
    try:
        with open("/proc/sys/kernel/yama/ptrace_scope") as f:
            return int(f.read())
    except OSError:
        return 0


@unittest.skipUnless(sys.platform == "linux" and (ptrace_scope() <= 1 or os.geteuid() == 0),
                     "needs /proc/PID/mem readable by a non-ancestor")
class MemoryDump(unittest.TestCase):
    def setUp(self):
        dd = gnu_dd()
        if dd is None:
            self.skipTest("needs GNU dd, the image's")
        self.addCleanup(shutil.rmtree, dd, True)
        self.observer = ["env", f"PATH={dd}:{os.environ.get('PATH', '')}"] + fake(canary.DUMP_MEMORY)

    def test_the_dump_reads_a_live_process_whole_and_finds_what_it_holds(self):
        needle = os.urandom(16)
        target = subprocess.Popen([sys.executable, "-I", "-c", TARGET, str(canary.MIN_DUMP_BYTES + (8 << 20)),
                                   needle.hex()], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(target.wait, 10)
        self.addCleanup(target.stdout.close)
        self.addCleanup(target.stdin.close)
        self.assertEqual(target.stdout.readline(), b"ready\n")
        found, total, said, status = canary.observe(self.observer + [str(target.pid)], [needle])
        problems, omissions = canary.memory_verdict(status, total, said)
        self.assertEqual(problems, [], said)
        self.assertGreaterEqual(found[needle], 1)
        for line in omissions:
            self.assertTrue(line.startswith("vanished") or canary.kernel_omission(line.split(" ", 3)[3]), line)

    def test_a_process_that_is_gone_is_rejected(self):
        gone = subprocess.Popen(["true"])
        gone.wait()
        _found, total, said, status = canary.observe(self.observer + [str(gone.pid)], [LONG])
        self.assertEqual(status, 3)
        self.assertTrue(said.endswith(f"no process {gone.pid}"), said)
        self.assertIn("the observer exited 3", canary.memory_verdict(status, total, said)[0])


class HomeVerdict(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="cyfr-canary-test-")
        self.addCleanup(shutil.rmtree, self.home, True)
        os.makedirs(os.path.join(self.home, ".cache", "nested"))
        with open(os.path.join(self.home, ".cache", "nested", "kept"), "w") as f:
            f.write("contents-" + LONG.decode())
        os.symlink("target-" + SHORT.decode(), os.path.join(self.home, "link"))

    def dump(self):
        return canary.observe(fake(canary.DUMP_HOME) + [self.home], [LONG, SHORT], chunk_size=7)

    def test_a_whole_walk_is_accepted(self):
        found, _total, said, status = self.dump()
        self.assertEqual((status, said), (0, "files=1 links=1 entries=4"))
        self.assertEqual(canary.home_verdict(status, said), [])
        self.assertEqual(found, {LONG: 1, SHORT: 1})

    @unittest.skipIf(os.geteuid() == 0, "root reads a file whatever its mode")
    def test_a_failed_home_read_is_rejected(self):
        unreadable = os.path.join(self.home, ".cache", "nested", "kept")
        os.chmod(unreadable, 0)
        self.addCleanup(os.chmod, unreadable, 0o600)
        _found, _total, said, status = self.dump()
        self.assertNotEqual(canary.home_verdict(status, said), [])
        self.assertNotEqual(status, 0)

    @unittest.skipIf(os.geteuid() == 0, "root walks a directory whatever its mode")
    def test_an_incomplete_walk_is_rejected(self):
        closed = os.path.join(self.home, ".cache")
        os.chmod(closed, 0)
        self.addCleanup(os.chmod, closed, 0o700)
        _found, _total, said, status = self.dump()
        self.assertNotEqual(canary.home_verdict(status, said), [])
        self.assertNotEqual(status, 0)

    def test_counters_then_a_non_zero_exit_are_rejected(self):
        _found, _total, said, status = canary.observe(fake("echo 'files=1 links=0 entries=1' >&2; exit 6"), [LONG])
        self.assertEqual(said, "files=1 links=0 entries=1")
        self.assertEqual(canary.home_verdict(status, said), ["the observer exited 6"])

    def test_counters_beside_an_error_are_rejected(self):
        said = "find: '/home/r/x': Permission denied\nfiles=1 links=0 entries=1"
        self.assertNotEqual(canary.home_verdict(0, said), [])

    def test_a_needle_in_what_the_observer_said_is_masked(self):
        _found, _total, said, _status = canary.observe(fake(f"echo 'no home /h/{LONG.decode()}' >&2; exit 3"),
                                                       [LONG])
        self.assertEqual(said, "no home /h/<value>")


class Reflector(unittest.TestCase):
    def test_it_listens_on_loopback_and_answers_there(self):
        import http.client
        import json

        reflector = canary.Reflector()
        self.addCleanup(reflector.stop)
        self.assertEqual(reflector.server.server_address[0], "127.0.0.1")
        connection = http.client.HTTPConnection("127.0.0.1", reflector.port, timeout=5)
        connection.request("POST", "/reflect", body=b"marker")
        answer = json.loads(connection.getresponse().read())
        connection.close()
        self.assertEqual(answer["reflected"]["body"], "marker")


if __name__ == "__main__":
    unittest.main(verbosity=2)
