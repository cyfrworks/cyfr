#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# box.py's reading of the screen's cookie stores off the guest, run as the
# proof runs it there, at its command line, against a stand-in store: read
# as SQLite holds it, a cookie committed to its write-ahead log alone
# among what it counts.
#   python3 -I tests/install-screen-proof/box_test.py
import os
import sqlite3
import subprocess
import sys
import tempfile

BOX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "box.py")
FAILED = []


def box(*args):
    return subprocess.run([sys.executable, "-I", BOX, *args], capture_output=True, text=True, timeout=60)


def check(what, ok, said=""):
    print(("ok: " if ok else "FAIL: ") + what + ("" if ok else f"\n{said}"))
    if not ok:
        FAILED.append(what)


def cookie_store(folder):
    """A cookie store as the engine's: a cookies table in WAL mode, the
    writer's connection left open so nothing is checkpointed."""
    db = sqlite3.connect(os.path.join(folder, "Cookies"))
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA wal_autocheckpoint=0")
    db.execute("CREATE TABLE cookies (name TEXT, encrypted_value BLOB)")
    db.commit()
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    return db


def test_stored():
    with tempfile.TemporaryDirectory() as home:
        folder = os.path.join(home, "Partitions", "screen")
        os.makedirs(folder)
        db = cookie_store(folder)
        said = box("stored", home)
        check("an empty store holds no session cookie", said.returncode == 0 and said.stdout.strip() == "0", said.stderr)
        db.execute("INSERT INTO cookies VALUES ('_cyfr_key', x'00ff')")
        db.execute("INSERT INTO cookies VALUES ('another', x'00')")
        db.commit()
        in_log = os.path.getsize(os.path.join(folder, "Cookies-wal")) > 0
        said = box("stored", home)
        check("a session cookie committed to the write-ahead log alone is counted",
              in_log and said.returncode == 0 and said.stdout.strip() == "1", f"in the log {in_log}: {said.stdout}{said.stderr}")
        db.close()


def test_lacks():
    with tempfile.TemporaryDirectory() as d:
        status = os.path.join(d, "status")
        for name, text, want in [
            ("the group absent", "Name:\tCYFR\nGroups:\t4 24 27 1000 \n", 0),
            ("no group at all", "Name:\tCYFR\nGroups:\t\n", 0),
            ("the group present", "Name:\tCYFR\nGroups:\t4 24 988 1000 \n", 1),
            ("no Groups line", "Name:\tCYFR\nUid:\t1000\n", 2),
        ]:
            with open(status, "w") as f:
                f.write(text)
            said = box("lacks", status, "988")
            check(f"lacks: {name}", said.returncode == want, f"exit {said.returncode}: {said.stdout}{said.stderr}")
        said = box("lacks", os.path.join(d, "gone", "status"), "988")
        check("lacks: a status file that cannot be read is no answer", said.returncode == 2, f"exit {said.returncode}: {said.stderr}")


test_stored()
test_lacks()
sys.exit(1 if FAILED else 0)
