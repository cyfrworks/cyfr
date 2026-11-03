#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Review regressions for the headless boot's credential claims."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument("--root", type=Path, required=True)
args, rest = parser.parse_known_args()
ROOT = args.root.resolve()
SOURCE = (ROOT / "tests/release-boot/boot.sh").read_text()


class CredentialEvidence(unittest.TestCase):
    def test_silent_admission_refuses_a_leftover_session(self):
        check = re.search(r"silent=\"\$\(python3 .*?<<'PY'\n(.*?)\nPY\n", SOURCE, re.S).group(1)
        person = "person-1"
        state = {
            "people": [{"id": person, "admission": "setup", "name": None, "admin": True}],
            "sessions": 0,
            "devices": [{"user_id": person, "holder_kind": "software", "standing": "active"}],
            "identities": [{"user_id": person, "identifier": None, "enrollment": "pending"}],
            "attempts": [{"user_id": person, "kind": "enrollment", "phase": "submitted", "name": "proof",
                          "identifier": "per_" + "ab" * 32, "directory": "https://directory.invalid"}],
        }

        def run():
            return subprocess.run([sys.executable, "-I", "-c", check, json.dumps(state)],
                                  capture_output=True, text=True, timeout=10)

        self.assertEqual(run().returncode, 0, "the valid waiting admission must pass")
        state["sessions"] = 1
        self.assertNotEqual(run().returncode, 0, "the boot accepted an authority-bearing session while the name waits")

    def test_first_unlock_rejects_echoed_passphrase_input(self):
        check = re.search(r'(?ms)^\[ -s "\$HEADLESS/passphrase".*?(?=^# CYFR holds)', SOURCE).group(0)
        unlocked = re.search(r'^SAY_UNLOCKED="(.*?)"$', SOURCE, re.M).group(1)
        with tempfile.TemporaryDirectory(prefix="cyfr-credential-evidence-") as scratch:
            cell = Path(scratch)
            command = cell / "cyfr"
            command.write_text(
                "#!/usr/bin/env python3\n"
                "import sys, termios\n"
                "p = 'alpha bravo charlie delta echo foxtrot'\n"
                "print('Write it down: ' + p, flush=True)\n"
                "if sys.argv[1] == 'quiet':\n"
                "    mode = termios.tcgetattr(0)\n"
                "    mode[3] &= ~termios.ECHO\n"
                "    termios.tcsetattr(0, termios.TCSANOW, mode)\n"
                "input('Your passphrase: ')\n"
                "input('Your passphrase again: ')\n"
                "input('Press Enter once you saved it. ')\n"
                f"print({unlocked!r}, flush=True)\n"
            )
            command.chmod(0o700)

            def run(mode):
                phrase, transcript = cell / "passphrase", cell / "login.log"
                phrase.unlink(missing_ok=True)
                result = subprocess.run([sys.executable, "-I", str(ROOT / "tests/release-boot/terminal.py"),
                                         str(phrase), str(transcript), str(command), mode],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                copies = transcript.read_text().count(phrase.read_text())
                self.assertEqual(copies, 1 if mode == "quiet" else 3)
                return subprocess.run(["bash", "-c", 'set -euo pipefail\nHEADLESS=$1\nSAY_UNLOCKED=$2\n'
                                       'headless_failed() { exit 1; }\n' + check,
                                       "check", str(cell), unlocked], capture_output=True, text=True, timeout=10)

            self.assertEqual(run("quiet").returncode, 0, "showing the drawn passphrase once is allowed")
            self.assertNotEqual(run("echo").returncode, 0, "the boot accepted both secret responses echoed to the terminal")


unittest.main(argv=[sys.argv[0], *rest])
