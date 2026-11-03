#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The release proof's headless_cli runs cyfr on a terminal.

    python3 -I tests/release-boot/headless-setup-transport-test.py --root ROOT

cyfr login unlocks a command line only on a terminal, and refuses any
other input; the release boot's headless case drives it as a person at an
ssh session does. This takes boot.sh's headless_cli helper as it is and
runs it over a stand-in cyfr that says whether its standard input and
output are a terminal, refusing as cyfr login refuses when they are not:
the helper must reach the stand-in on a terminal, answering its refusal
never. No release, server or Go toolchain is needed.
"""

import argparse
import re
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True, type=Path)
args = parser.parse_args()
source = (args.root / "tests/release-boot/boot.sh").read_text()
helper = re.search(r"(?ms)^CLI_STATUS=0\nheadless_cli\(\) \{\n.*?^\}\n", source)
assert helper, "the release proof's headless_cli helper was not found"
REFUSAL = "cyfr login unlocks this command line on a terminal. Unattended work uses an API key (--token or CYFR_TOKEN)."

with tempfile.TemporaryDirectory(prefix="cyfr-headless-transport-") as scratch:
    work = Path(scratch)
    (work / "cell").mkdir()
    (work / "cell/.env").write_text("CYFR_SETUP_TOKEN=" + "ab" * 32 + "\n")
    stand_in = work / "cyfr"
    stand_in.write_text(
        "#!/bin/sh\n"
        'if [ -t 0 ] && [ -t 1 ]; then echo "on a terminal: $*"; exit 0; fi\n'
        f'echo "Error: {REFUSAL}"; exit 1\n'
    )
    stand_in.chmod(0o700)
    driver = work / "driver.sh"
    driver.write_text(
        "set -euo pipefail\nROOT=$1\nWORK=$2\nCELL_CLI=$3\nLOG_SECRETS=()\n"
        "cell_cli_build() { :; }\n" + helper.group(0) +
        'headless_cli "$WORK/cell" /bin/true --url http://127.0.0.1:1 login --setup --name proof\n'
        'echo "status $CLI_STATUS"\n'
        'cat "$WORK/cell/login.log"\n'
    )
    result = subprocess.run(
        ["bash", str(driver), str(args.root.resolve()), str(work), str(stand_in)],
        capture_output=True, text=True, timeout=60,
    )
    out = result.stdout + result.stderr
    if result.returncode != 0 or REFUSAL in out or "status 0" not in out or \
            "on a terminal: --url http://127.0.0.1:1 login --setup --name proof" not in out:
        print(out, end="")
        raise SystemExit("FAIL: the release proof's headless_cli does not run cyfr on a terminal")
    print("ok: the release proof's headless_cli runs cyfr login on a terminal, as a person at an ssh session does")
