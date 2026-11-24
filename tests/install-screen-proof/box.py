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
#       guest. It records as well each API key CYFR sends the screen
#       (cyfr_sk_ and 32 characters, in one segment of what port 4000
#       sends), since Prism shows a key once, to the person, and the proof
#       has no other way to it; and, once, whether the first WebSocket text
#       frame CYFR sent was compressed (its RSV1 bit), which would hide a
#       key from this reading
#   box.py key RECORD FILE
#       writes to FILE (mode 600) the last API key RECORD saw, and prints
#       its digest; exits 1 with none
#   box.py canvas KEYFILE DIR
#       as the person whose API key KEYFILE holds, over CYFR's /mcp: writes
#       DIR's files (index.html, app.js) as the canvas proof-video and puts
#       it first among the person's canvases, so Prism shows it; the key
#       is used for these calls alone. Prints the canvas's reference
#   box.py framed RECORD
#       prints whether the first WebSocket text frame CYFR sent was
#       compressed, plain, or none was seen
#   box.py header RECORD SINCE FILE
#       writes to FILE (mode 600) a Cookie header of the last session cookie
#       the screen sent CYFR at or after SINCE (Unix seconds), and prints
#       its digest; exits 1 with none
#   box.py visits RECORD SINCE PORT TEXT
#       prints each request target the screen asked of PORT at or after
#       SINCE that holds TEXT, one per line
#   box.py confirmation DATABASE REF
#       prints, as JSON, the state and confirming client of the pending
#       confirmation REF in CYFR's SQLite database DATABASE
#   box.py athanors DATABASE
#       prints, as JSON, each athanor of CYFR's SQLite database DATABASE
#       with how its fill ended: when it was provisioned, or the failure
#       recorded on it
#   box.py renderers
#       prints the process id of the screen's CYFR app (its main process,
#       /opt/cyfr/CYFR --screen-project=...), then of each renderer below it,
#       on one line
#   box.py stored DIR
#       prints how many rows of CYFR's session cookie (by its name, never
#       its value) the cookie stores (files named Cookies) under DIR hold,
#       each read as SQLite holds it, its write-ahead log and journal
#       included, from a copy of the three taken as they stood (the same
#       bytes twice running), as its engine may hold it open; exits 1 on a
#       store that does not hold still. The engine keeps a cookie's value
#       encrypted there, so no search for the value finds it
import hashlib
import json
import os
import re
import socket
import sqlite3
import sys
import time

COOKIE = "_cyfr_key"
PORTS = (4000, 7340)
ETH_P_ALL = 0x0003
PACKET_OUTGOING = 4
KEY = re.compile(rb"cyfr_sk_[A-Za-z0-9_-]{32}")
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
    framed = False
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
        if len(tcp) < 20:
            continue
        payload = tcp[(tcp[12] >> 4) * 4:]
        if int.from_bytes(tcp[0:2], "big") == 4000 and payload:
            if not framed and payload[0] & 0x8F == 0x81:
                framed = True
                os.write(fd, (json.dumps({"t": time.time(), "ws_compressed": bool(payload[0] & 0x40)}) + "\n").encode())
            for key in KEY.findall(payload):
                os.write(fd, (json.dumps({"t": time.time(), "key": key.decode()}) + "\n").encode())
            continue
        if int.from_bytes(tcp[2:4], "big") not in PORTS:
            continue
        found = head(payload)
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
            if "line" in e and e["t"] >= since and not e["curl"]:
                yield e


def found(record, field):
    """Each value of field the record holds, in order: an API key, or
    whether the first WebSocket frame was compressed."""
    with open(record) as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if field in e:
                yield e[field]


def key(record, path):
    keys = list(found(record, "key"))
    if not keys:
        sys.exit("box.py: CYFR sent the screen no API key")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, keys[-1].encode())
    os.close(fd)
    return hashlib.sha256(keys[-1].encode()).hexdigest()[:16]


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


MCP = "http://localhost:4000/mcp"


def call(token, tool, arguments):
    """One tools/call over CYFR's /mcp with the API key token, its answer."""
    import urllib.request
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
        "name": tool, "arguments": arguments, "_meta": {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": {"name": "install-screen-proof", "version": "0"},
            "io.modelcontextprotocol/clientCapabilities": {}}}}).encode()
    request = urllib.request.Request(MCP, data=body, method="POST", headers={
        "authorization": f"Bearer {token}", "content-type": "application/json",
        "accept": "application/json, text/event-stream", "mcp-protocol-version": "2026-07-28",
        "mcp-method": "tools/call", "mcp-name": tool})
    with urllib.request.urlopen(request, timeout=60) as response:
        result = json.load(response)["result"]
    if result.get("isError"):
        sys.exit(f"box.py: {tool} {arguments.get('action')} refused: {result['content'][0]['text']}")
    return json.loads(result["content"][0]["text"])


def canvas(keyfile, folder):
    with open(keyfile) as f:
        token = f.read().strip()
    files = {name: open(os.path.join(folder, name)).read() for name in ("index.html", "app.js")}
    written = call(token, "canvas", {"action": "write", "name": "proof-video", "template": "vanilla", "files": files})
    reference = written["reference"].rsplit(":", 1)[0]
    held = call(token, "layout", {"action": "get"})
    document = held["document"]
    document["canvases"] = [{"id": "video", "tincture": reference, "postures": {}}] + \
        [c for c in document["canvases"] if c["id"] != "video"][:7]
    call(token, "layout", {"action": "edit", "document": document, "revision": held["revision"]})
    return reference


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


def renderers():
    procs = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            # A process of the engine's may write its title over its
            # arguments, spaces for their separators, as ps shows them.
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                args = f.read().replace(b"\0", b" ")
            with open(f"/proc/{pid}/stat") as f:
                parent = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, IndexError, ValueError):
            continue
        procs[int(pid)] = (parent, args)
    apps = [p for p, (_, args) in procs.items() if args.startswith(b"/opt/cyfr/CYFR --screen-project=")]
    if len(apps) != 1:
        raise RuntimeError(f"{len(apps)} screen apps run")
    app = apps[0]

    def below(p):
        for _ in range(64):
            p = procs.get(p, (0,))[0]
            if p == app:
                return True
            if p <= 1:
                return False
        return False
    return [app] + sorted(p for p, (_, args) in procs.items() if b" --type=renderer" in args and below(p))


STORE = ("Cookies", "Cookies-wal", "Cookies-journal")


def store_as_it_stood(root):
    """The cookie store in root, its write-ahead log and journal with it,
    read until two reads running are the same bytes."""
    last = None
    for _ in range(25):
        now = {}
        for name in STORE:
            try:
                with open(os.path.join(root, name), "rb") as f:
                    now[name] = f.read()
            except FileNotFoundError:
                pass
        if now == last:
            return now
        last = now
        time.sleep(0.2)
    raise RuntimeError(f"the cookie store in {root} did not hold still")


def stored(folder):
    import tempfile
    count = 0
    for root, _, files in os.walk(folder):
        if "Cookies" in files:
            held = store_as_it_stood(root)
            with tempfile.TemporaryDirectory() as d:
                for name, data in held.items():
                    with open(os.path.join(d, name), "wb") as f:
                        f.write(data)
                # Opening the copy reads its log, and rolls back an
                # unfinished transaction its journal holds, as SQLite
                # reads the store itself.
                db = sqlite3.connect(os.path.join(d, "Cookies"))
                count += db.execute("SELECT count(*) FROM cookies WHERE name = ?", (COOKIE,)).fetchone()[0]
                db.close()
    return count


def main(argv):
    if len(argv) == 3 and argv[1] == "observe":
        observe(argv[2])
    elif len(argv) == 5 and argv[1] == "header":
        print(header(argv[2], float(argv[3]), argv[4]))
    elif len(argv) == 6 and argv[1] == "visits":
        for target in visits(argv[2], float(argv[3]), int(argv[4]), argv[5]):
            print(target)
    elif len(argv) == 4 and argv[1] == "key":
        print(key(argv[2], argv[3]))
    elif len(argv) == 4 and argv[1] == "canvas":
        print(canvas(argv[2], argv[3]))
    elif len(argv) == 3 and argv[1] == "framed":
        first = next(found(argv[2], "ws_compressed"), None)
        print("none" if first is None else "compressed" if first else "plain")
    elif len(argv) == 4 and argv[1] == "confirmation":
        print(json.dumps(confirmation(argv[2], argv[3])))
    elif len(argv) == 3 and argv[1] == "athanors":
        print(json.dumps(athanors(argv[2])))
    elif len(argv) == 2 and argv[1] == "renderers":
        print(" ".join(str(p) for p in renderers()))
    elif len(argv) == 3 and argv[1] == "stored":
        print(stored(argv[2]))
    else:
        print("usage: box.py observe RECORD | header RECORD SINCE FILE | visits RECORD SINCE PORT TEXT | key RECORD FILE"
              " | canvas KEYFILE DIR | framed RECORD"
              " | confirmation DATABASE REF | athanors DATABASE | renderers | stored DIR", file=sys.stderr)
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
