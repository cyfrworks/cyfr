#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# A QMP client for the install-and-screen proof's guests, run inside the
# QEMU container (tests/install-screen-proof/Dockerfile):
#   qmp.py SOCKET COMMAND [ARGUMENTS-JSON]
#       runs one QMP command and prints its return value as JSON
#   qmp.py SOCKET type
#       types standard input's text on the guest's keyboard, one key
#       (with shift where the character needs it) per character
# It connects within QMP_WAIT seconds (default 30), retrying while QEMU
# starts, negotiates capabilities and skips events. A QMP error, or a
# character with no key, exits 1 with the reason on stderr.
import json
import os
import socket
import sys
import time

# The qcode of each character typed without shift, then of each typed
# with it, on a US layout, which is the guest console's default.
PLAIN = {
    " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal",
    "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
    ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
    ",": "comma", ".": "dot", "/": "slash",
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right", "|": "backslash",
    ":": "semicolon", '"': "apostrophe", "~": "grave_accent",
    "<": "comma", ">": "dot", "?": "slash",
}


class QmpError(Exception):
    pass


def keys_for(char):
    if char.isascii() and (char.islower() or char.isdigit()):
        return [char]
    if char.isascii() and char.isupper():
        return ["shift", char.lower()]
    if char in PLAIN:
        return [PLAIN[char]]
    if char in SHIFTED:
        return ["shift", SHIFTED[char]]
    raise QmpError(f"no key types {char!r}")


class Qmp:
    def __init__(self, path, wait):
        deadline = time.monotonic() + wait
        while True:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(path)
                break
            except OSError:
                sock.close()
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.2)
        sock.settimeout(60)
        self.sock = sock
        self.reader = sock.makefile("rb")
        if "QMP" not in self._read():
            raise QmpError("the socket did not greet as QMP")
        self.call("qmp_capabilities")

    def _read(self):
        line = self.reader.readline()
        if not line:
            raise QmpError("QMP closed the connection")
        return json.loads(line)

    def call(self, command, arguments=None):
        message = {"execute": command}
        if arguments is not None:
            message["arguments"] = arguments
        self.sock.sendall(json.dumps(message).encode() + b"\n")
        while True:
            reply = self._read()
            if "return" in reply:
                return reply["return"]
            if "error" in reply:
                raise QmpError(f"{command}: {reply['error'].get('desc', reply['error'])}")


def main(argv):
    if len(argv) < 3:
        print("usage: qmp.py SOCKET COMMAND [ARGUMENTS-JSON] | qmp.py SOCKET type", file=sys.stderr)
        return 64
    path, command = argv[1], argv[2]
    try:
        qmp = Qmp(path, float(os.environ.get("QMP_WAIT", "30")))
        if command == "type":
            for char in sys.stdin.read():
                keys = [{"type": "qcode", "data": key} for key in keys_for(char)]
                qmp.call("send-key", {"keys": keys, "hold-time": 40})
                time.sleep(0.03)
            return 0
        arguments = json.loads(argv[3]) if len(argv) > 3 else None
        print(json.dumps(qmp.call(command, arguments)))
        return 0
    except (OSError, QmpError, ValueError) as error:
        print(f"qmp.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
