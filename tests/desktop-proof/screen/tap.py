# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""One tap at X Y of a 1280x720 output, by a virtual pointer of labwc's
(zwlr_virtual_pointer_v1): input as a person's is, which Chrome asks of
playback before it holds the screen awake. The pointer stays until the tap
is taken, which wlrctl's does not."""

import os
import socket
import struct
import sys
import time

DISPLAY, REGISTRY, LISTED, MANAGER, POINTER = 1, 2, 3, 4, 5
MANAGER_NAME = "zwlr_virtual_pointer_manager_v1"
LEFT_BUTTON = 272

x, y = int(sys.argv[1]), int(sys.argv[2])
compositor = socket.socket(socket.AF_UNIX)
compositor.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ["WAYLAND_DISPLAY"]))


def send(target, opcode, body=b""):
    compositor.sendall(struct.pack("=II", target, (8 + len(body)) << 16 | opcode) + body)


def exactly(size):
    read = b""
    while len(read) < size:
        more = compositor.recv(size - len(read))
        if not more:
            sys.exit("tap: labwc closed the connection")
        read += more
    return read


def text(value):
    raw = value.encode() + b"\0"
    return struct.pack("=I", len(raw)) + raw + b"\0" * (-len(raw) % 4)


def motion(at_x):
    send(POINTER, 1, struct.pack("=IIIII", 0, at_x, y, 1280, 720))
    send(POINTER, 4)


send(DISPLAY, 1, struct.pack("=I", REGISTRY))
send(DISPLAY, 0, struct.pack("=I", LISTED))
name = None
while True:
    target, sized = struct.unpack("=II", exactly(8))
    body = exactly((sized >> 16) - 8)
    if target == LISTED:
        break
    if target == REGISTRY and sized & 0xFFFF == 0:
        number, length = struct.unpack("=II", body[:8])
        if body[8:8 + length - 1].decode() == MANAGER_NAME:
            name = number
if name is None:
    sys.exit("tap: labwc offers no virtual pointer")

send(REGISTRY, 0, struct.pack("=I", name) + text(MANAGER_NAME) + struct.pack("=II", 1, MANAGER))
send(MANAGER, 0, struct.pack("=II", 0, POINTER))
time.sleep(1)  # sleep-ok: the seat tells its clients of a pointer, which answers nothing to wait on
motion(x + 2)
motion(x)
time.sleep(0.3)  # sleep-ok: the pointer enters the window before it presses
for pressed in (1, 0):
    send(POINTER, 2, struct.pack("=III", 0, LEFT_BUTTON, pressed))
    send(POINTER, 4)
    time.sleep(0.1)  # sleep-ok: the length of a tap
time.sleep(0.7)  # sleep-ok: the tap is taken before its pointer goes with this connection
