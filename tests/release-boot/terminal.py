# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A person at a terminal, for the release boot's headless case.

    python3 -I terminal.py PASSPHRASE_FILE TRANSCRIPT CYFR [ARG...]

Runs CYFR ARG... on a pseudo-terminal of its own, as an ssh session runs a
command, in this process's environment, and answers it as its person does:
a six-digit PIN where it offers this machine's chip, which the release
boot runs only where the chip cannot take it (boot.sh), so the passphrase
follows; the six-word passphrase cyfr login draws and shows once ("Write
it down:")
is kept in PASSPHRASE_FILE (mode 0600) and typed back each time a
passphrase is asked; a passphrase already in PASSPHRASE_FILE is typed
when an unlock asks for it; Enter is pressed once the recovery code is
shown. Nothing else is typed. What the terminal showed is TRANSCRIPT,
without carriage returns. Exits with the command's status, or 124 when it
runs past five minutes, killing it.
"""

import os
import pty
import re
import select
import signal
import sys
import time

DEADLINE = 300
PASSPHRASE = re.compile(rb"Write it down:\s+([a-z]+(?: [a-z]+){5})\s")
ASKED = re.compile(rb"passphrase(?: again)?: $")
# A machine whose chip the command line cannot use still offers it: the
# PIN typed there is refused by the chip, and the passphrase drawn next.
PIN_ASKED = re.compile(rb"(PIN: |The same PIN again: )$")
PIN = b"258046"
ENTER = b"Press Enter once you saved it. "


def main():
    keep, transcript, command = sys.argv[1], sys.argv[2], sys.argv[3:]
    passphrase = None
    if os.path.exists(keep):
        with open(keep, "rb") as f:
            passphrase = f.read().strip() or None

    pid, fd = pty.fork()
    if pid == 0:
        os.execv(command[0], command)

    shown, answered, deadline = b"", 0, time.monotonic() + DEADLINE
    status = None
    while status is None:
        if time.monotonic() > deadline:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            status = 124
            break
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                chunk = b""
            if not chunk:
                _, code = os.waitpid(pid, 0)
                status = os.waitstatus_to_exitcode(code)
                break
            shown += chunk
        if passphrase is None:
            drawn = PASSPHRASE.search(shown)
            if drawn:
                passphrase = drawn.group(1)
                fd_keep = os.open(keep, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                os.write(fd_keep, passphrase)
                os.close(fd_keep)
        pending = shown[answered:]
        if passphrase is not None and ASKED.search(pending):
            os.write(fd, passphrase + b"\n")
            answered = len(shown)
        elif PIN_ASKED.search(pending) and b"Choose a six-digit PIN" in shown:
            os.write(fd, PIN + b"\n")
            answered = len(shown)
        elif pending.endswith(ENTER):
            os.write(fd, b"\n")
            answered = len(shown)
        if not ready:
            done, code = os.waitpid(pid, os.WNOHANG)
            if done:
                # Whatever the terminal still holds, then the status.
                try:
                    while True:
                        chunk = os.read(fd, 4096)
                        if not chunk:
                            break
                        shown += chunk
                except OSError:
                    pass
                status = os.waitstatus_to_exitcode(code)

    with open(transcript, "wb") as f:
        f.write(shown.replace(b"\r", b""))
    sys.exit(status)


if __name__ == "__main__":
    main()
