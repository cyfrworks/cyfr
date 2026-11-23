#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# box.py's readings off the guest, run as the proof runs it there, at its
# command line, against stand-ins: the cookie store read as SQLite holds
# it, a cookie committed to its write-ahead log alone among them, and the
# scrub, which refuses a key it knows from the wire and one of a key's
# shape it never saw.
#   python3 -I tests/install-screen-proof/box_test.py
import io
import json
import os
import sqlite3
import subprocess
import sys
import tarfile
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


def archive(files):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w") as tar:
        for name, body in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(body)
            tar.addfile(info, io.BytesIO(body))
    return data.getvalue()


def test_scrub():
    wire = "cyfr_sk_" + "w" * 32
    never = "cyfr_sk_" + "n" * 32
    with tempfile.TemporaryDirectory() as d:
        record = os.path.join(d, "record.jsonl")
        with open(record, "w") as f:
            f.write(json.dumps({"t": 1, "port": 4000, "line": "GET / HTTP/1.1", "curl": False, "cookie": "the-session"}) + "\n")
            f.write(json.dumps({"t": 2, "key": wire}) + "\n")
        cases = {
            "evidence holding none passes": ({"clean/a.txt": b"nothing here"}, 0, []),
            "a cookie the wire carried is refused": ({"clean/a.txt": b"x the-session x"}, 1, ["clean/a.txt"]),
            "a key the wire carried is refused": ({"clean/b.html": wire.encode()}, 1, ["clean/b.html"]),
            "a key the wire never carried is refused by its shape": ({"clean/c.txt": b"seen " + never.encode()}, 1, ["clean/c.txt"]),
        }
        for what, (files, status, named) in cases.items():
            tar = os.path.join(d, "evidence.tar")
            with open(tar, "wb") as f:
                f.write(archive(files))
            said = box("scrub", record, tar)
            lines = said.stdout.splitlines()
            check(what, said.returncode == status and lines[1:] == named, said.stdout + said.stderr)
        empty = os.path.join(d, "empty.jsonl")
        open(empty, "w").close()
        with open(tar, "wb") as f:
            f.write(archive({"clean/a.txt": b"nothing here"}))
        said = box("scrub", empty, tar)
        check("a scrub that looked for nothing passes nothing", said.returncode == 1, said.stdout)


test_stored()
test_scrub()
sys.exit(1 if FAILED else 0)
