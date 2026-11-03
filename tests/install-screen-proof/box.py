#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the install-screen proof reads on the box under proof, copied into
# the guest by tests/install-screen-proof/lib.sh and run there with the
# guest's own python3 -I:
#   box.py cookie PROFILE HOST NAME
#       prints the value of the cookie NAME that the Chrome profile
#       directory PROFILE holds for HOST, as Chrome sends it
#   box.py visits PROFILE SINCE TEXT
#       prints each page the profile's history visited after SINCE (Unix
#       seconds) whose address holds TEXT, one per line
#   box.py confirmation DATABASE REF
#       prints, as JSON, the state and confirming client of the pending
#       confirmation REF in CYFR's SQLite database DATABASE
# Chrome keeps its profile's databases locked while it runs, so each is
# read from a copy, as anyone who copies the profile reads it. Chrome on
# Linux without a keyring (the screen's labwc session has none) encrypts a
# cookie under its fixed basic key, v10 (or v11 under an empty keyring
# secret), and newer profiles prefix the value with the SHA-256 of its
# host. A cookie that is absent, or that decrypts under neither key, exits
# 1 with the reason on stderr.
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

# Microseconds from 1601-01-01, Chrome's epoch, to 1970-01-01.
CHROME_EPOCH_US = 11644473600 * 1_000_000


def copied(path):
    """A connection to a copy of the SQLite database at path."""
    if not os.path.exists(path):
        sys.exit(f"box.py: {path} does not exist")
    work = tempfile.mkdtemp(prefix="box-")
    for suffix in ("", "-journal", "-wal"):
        if os.path.exists(path + suffix):
            shutil.copyfile(path + suffix, os.path.join(work, "db" + suffix))
    return sqlite3.connect(os.path.join(work, "db"))


def profile_file(profile, *names):
    for name in names:
        path = os.path.join(profile, "Default", name)
        if os.path.exists(path):
            return path
    sys.exit(f"box.py: {profile} holds none of {', '.join(names)}")


def decrypt(blob, host):
    key_secrets = {b"v10": b"peanuts", b"v11": b""}
    secret = key_secrets.get(blob[:3])
    if secret is None:
        raise ValueError(f"a cookie under an unknown scheme {blob[:3]!r}")
    key = hashlib.pbkdf2_hmac("sha1", secret, b"saltysalt", 1, 16)
    out = subprocess.run(
        ["openssl", "enc", "-d", "-aes-128-cbc", "-nopad", "-K", key.hex(), "-iv", "20" * 16],
        input=blob[3:], capture_output=True, check=True,
    ).stdout
    pad = out[-1] if out else 0
    if not 1 <= pad <= 16 or out[-pad:] != bytes([pad]) * pad:
        raise ValueError("a cookie that does not decrypt under the basic key")
    out = out[:-pad]
    if out[:32] == hashlib.sha256(host.encode()).digest():
        out = out[32:]
    text = out.decode("ascii")
    if not text.isprintable():
        raise ValueError("a cookie that does not decrypt to text")
    return text


def cookie(profile, host, name):
    db = copied(profile_file(profile, "Network/Cookies", "Cookies"))
    row = db.execute(
        "SELECT value, encrypted_value FROM cookies WHERE host_key = ? AND name = ?", (host, name)
    ).fetchone()
    if row is None:
        sys.exit(f"box.py: the profile holds no cookie {name} for {host}")
    value, blob = row
    if value:
        return value
    try:
        return decrypt(bytes(blob), host)
    except (ValueError, UnicodeDecodeError, subprocess.CalledProcessError) as error:
        sys.exit(f"box.py: {error}")


def visits(profile, since, text):
    db = copied(profile_file(profile, "History"))
    rows = db.execute(
        "SELECT urls.url FROM visits JOIN urls ON visits.url = urls.id"
        " WHERE visits.visit_time > ? AND instr(urls.url, ?) > 0 ORDER BY visits.visit_time",
        (since * 1_000_000 + CHROME_EPOCH_US, text),
    ).fetchall()
    return [url for (url,) in rows]


def confirmation(database, ref):
    db = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    row = db.execute(
        "SELECT state, confirmed_client_id, proof FROM pending_confirmations WHERE ref = ?", (ref,)
    ).fetchone()
    if row is None:
        return {"ref": ref, "state": None}
    return {"ref": ref, "state": row[0], "confirmed_client_id": row[1], "proof": row[2]}


def main(argv):
    if len(argv) == 5 and argv[1] == "cookie":
        print(cookie(argv[2], argv[3], argv[4]))
    elif len(argv) == 5 and argv[1] == "visits":
        for url in visits(argv[2], int(argv[3]), argv[4]):
            print(url)
    elif len(argv) == 4 and argv[1] == "confirmation":
        print(json.dumps(confirmation(argv[2], argv[3])))
    else:
        print("usage: box.py cookie PROFILE HOST NAME | visits PROFILE SINCE TEXT | confirmation DATABASE REF",
              file=sys.stderr)
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
