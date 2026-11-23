# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Every window labwc shows, as its own list of them tells its clients
(zwlr_foreign_toplevel_manager_v1), until labwc ends: one line for each
window that opens and each that closes, `open ID SECONDS` and
`closed ID SECONDS`, the time this machine's clock read as the event
arrived. A window's ID is labwc's handle for it, which no other window
takes while this client runs, so a window closed and one opened after it
are told apart, which a title or a picture cannot."""

import os
import socket
import struct
import sys
import time

DISPLAY, REGISTRY, LISTED, MANAGER = 1, 2, 3, 4
MANAGER_NAME = "zwlr_foreign_toplevel_manager_v1"
TOPLEVEL, CLOSED = 0, 6

compositor = socket.socket(socket.AF_UNIX)
compositor.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ["WAYLAND_DISPLAY"]))


def send(target, opcode, body=b""):
    compositor.sendall(struct.pack("=II", target, (8 + len(body)) << 16 | opcode) + body)


def exactly(size):
    read = b""
    while len(read) < size:
        more = compositor.recv(size - len(read))
        if not more:
            sys.exit(0)
        read += more
    return read


def text(value):
    raw = value.encode() + b"\0"
    return struct.pack("=I", len(raw)) + raw + b"\0" * (-len(raw) % 4)


def event():
    target, sized = struct.unpack("=II", exactly(8))
    return target, sized & 0xFFFF, exactly((sized >> 16) - 8)


send(DISPLAY, 1, struct.pack("=I", REGISTRY))
send(DISPLAY, 0, struct.pack("=I", LISTED))
name = None
while True:
    target, opcode, body = event()
    if target == LISTED:
        break
    if target == REGISTRY and opcode == 0:
        number, length = struct.unpack("=II", body[:8])
        if body[8:8 + length - 1].decode() == MANAGER_NAME:
            name = number
if name is None:
    sys.exit("toplevels: labwc offers no list of its windows")

send(REGISTRY, 0, struct.pack("=I", name) + text(MANAGER_NAME) + struct.pack("=II", 1, MANAGER))
handles = set()
while True:
    target, opcode, body = event()
    if target == MANAGER and opcode == TOPLEVEL:
        handle = struct.unpack("=I", body[:4])[0]
        handles.add(handle)
        print(f"open {handle} {time.time():.3f}", flush=True)
    elif target in handles and opcode == CLOSED:
        handles.discard(target)
        print(f"closed {target} {time.time():.3f}", flush=True)
