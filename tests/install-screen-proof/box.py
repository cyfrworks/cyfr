#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the install-screen proof reads on the box under proof, copied into
# the guest by tests/install-screen-proof/lib.sh and run there with the
# guest's own python3 -I:
#   box.py observe RECORD
#       as root, appends to RECORD (mode 600) one JSON line for each plain
#       HTTP request head the guest's loopback carries to CYFR (port 4000)
#       or to the screen's shell (7340): its time, port, request line,
#       whether a curl sent it, and the session cookie it carries, until it
#       is stopped. The app on the screen talks to both over loopback in
#       the clear, so this is what it sends, read where it goes, never
#       from the app's insides; the record is root's and never leaves the
#       guest
#   box.py header RECORD SINCE FILE
#       writes to FILE (mode 600) a Cookie header of the last session cookie
#       the screen sent CYFR at or after SINCE (Unix seconds), and prints
#       its digest; exits 1 with none
#   box.py visits RECORD SINCE PORT TEXT
#       prints each request target the screen asked of PORT at or after
#       SINCE that holds TEXT, one per line
#   box.py scrub RECORD TAR
#       exits 0 when no file of the tar archive TAR holds a session cookie
#       value RECORD saw, printing how many it looked for; else 1, naming
#       the files
#   box.py confirmation DATABASE REF
#       prints, as JSON, the state and confirming client of the pending
#       confirmation REF in CYFR's SQLite database DATABASE
#   box.py athanors DATABASE
#       prints, as JSON, each athanor of CYFR's SQLite database DATABASE
#       with how its fill ended: when it was provisioned, or the failure
#       recorded on it
import hashlib
import json
import os
import socket
import sqlite3
import sys
import tarfile
import time

COOKIE = "_cyfr_key"
PORTS = (4000, 7340)
ETH_P_ALL = 0x0003
PACKET_OUTGOING = 4
METHODS = (b"GET ", b"POST ", b"PUT ", b"PATCH ", b"DELETE ", b"HEAD ", b"OPTIONS ")


def head(payload):
    """The request line and headers of a payload that begins a request."""
    if not payload.startswith(METHODS):
        return None
    lines = payload.split(b"\r\n\r\n", 1)[0].decode("latin-1").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers.setdefault(name.strip().lower(), value.strip())
    return lines[0], headers


def cookie_of(headers):
    for part in headers.get("cookie", "").split(";"):
        name, _, value = part.strip().partition("=")
        if name == COOKIE and value:
            return value
    return None


def observe(record):
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    sock.bind(("lo", ETH_P_ALL))
    fd = os.open(record, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    os.fchmod(fd, 0o600)
    while True:
        frame, address = sock.recvfrom(262144)
        if address[2] == PACKET_OUTGOING or len(frame) < 14:
            continue
        kind, ip = int.from_bytes(frame[12:14], "big"), frame[14:]
        if kind == 0x0800 and len(ip) >= 20 and ip[9] == 6:
            tcp = ip[(ip[0] & 0x0F) * 4:]
        elif kind == 0x86DD and len(ip) >= 40 and ip[6] == 6:
            tcp = ip[40:]
        else:
            continue
        if len(tcp) < 20 or int.from_bytes(tcp[2:4], "big") not in PORTS:
            continue
        found = head(tcp[(tcp[12] >> 4) * 4:])
        if found is None:
            continue
        line, headers = found
        entry = {"t": time.time(), "port": int.from_bytes(tcp[2:4], "big"), "line": line,
                 "curl": headers.get("user-agent", "").startswith("curl/"), "cookie": cookie_of(headers)}
        os.write(fd, (json.dumps(entry) + "\n").encode())


def entries(record, since=0):
    with open(record) as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e["t"] >= since and not e["curl"]:
                yield e


def header(record, since, path):
    values = [e["cookie"] for e in entries(record, since) if e["port"] == 4000 and e["cookie"]]
    if not values:
        sys.exit("box.py: the screen sent CYFR no session cookie since then")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, f"Cookie: {COOKIE}={values[-1]}\n".encode())
    os.close(fd)
    return hashlib.sha256(values[-1].encode()).hexdigest()[:16]


def visits(record, since, port, text):
    return [e["line"].split(" ")[1] for e in entries(record, since)
            if e["port"] == port and len(e["line"].split(" ")) > 1 and text in e["line"].split(" ")[1]]


def scrub(record, archive):
    values = {e["cookie"] for e in entries(record) if e["cookie"]}
    holding = []
    with tarfile.open(archive) as tar:
        for member in tar:
            if member.isfile():
                data = tar.extractfile(member).read()
                if any(v.encode() in data for v in values):
                    holding.append(member.name)
    return len(values), holding


def confirmation(database, ref):
    db = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    row = db.execute(
        "SELECT state, confirmed_client_id, proof FROM pending_confirmations WHERE ref = ?", (ref,)
    ).fetchone()
    if row is None:
        return {"ref": ref, "state": None}
    return {"ref": ref, "state": row[0], "confirmed_client_id": row[1], "proof": row[2]}


def athanors(database):
    db = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    rows = db.execute("SELECT id, provisioned_at, provisioning_failure FROM athanors ORDER BY id").fetchall()
    return [{"id": i, "provisioned_at": at, "provisioning_failure": failure} for i, at, failure in rows]


def main(argv):
    if len(argv) == 3 and argv[1] == "observe":
        observe(argv[2])
    elif len(argv) == 5 and argv[1] == "header":
        print(header(argv[2], float(argv[3]), argv[4]))
    elif len(argv) == 6 and argv[1] == "visits":
        for target in visits(argv[2], float(argv[3]), int(argv[4]), argv[5]):
            print(target)
    elif len(argv) == 4 and argv[1] == "scrub":
        looked, holding = scrub(argv[2], argv[3])
        print(f"{looked} session cookies looked for, {len(holding)} files hold one")
        for name in holding:
            print(name)
        return 0 if looked and not holding else 1
    elif len(argv) == 4 and argv[1] == "confirmation":
        print(json.dumps(confirmation(argv[2], argv[3])))
    elif len(argv) == 3 and argv[1] == "athanors":
        print(json.dumps(athanors(argv[2])))
    else:
        print("usage: box.py observe RECORD | header RECORD SINCE FILE | visits RECORD SINCE PORT TEXT | scrub RECORD TAR"
              " | confirmation DATABASE REF | athanors DATABASE", file=sys.stderr)
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
