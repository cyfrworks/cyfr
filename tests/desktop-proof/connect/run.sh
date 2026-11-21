#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The six-word road against a real CYFR (../README.md), run by home.sh in
# the client container as its user: the installed app, whose entry is
# this folder's proof.js, under a display and a session bus, with nothing
# of this environment but those, HOME and where the proof's inputs are.
# The proof writes one PASS or FAIL line a row to FIXTURE_DIR/out/connect.txt
# and its whole record to connect.json; one FAIL, or a proof that does not
# finish its record, fails the run.
#
# Usage: bash tests/desktop-proof/connect/run.sh APP_PATH HOME_ORIGIN FIXTURE_DIR
set -uo pipefail
APP="${1:?usage: run.sh APP_PATH HOME_ORIGIN FIXTURE_DIR}"
HOME_ORIGIN="${2:?}"
FIXTURE="${3:?}"
OUT="$FIXTURE/out"
mkdir -p "$OUT"
rm -f "$OUT/connect.txt" "$OUT/connect.json"

# The client has no Docker: no program and no socket.
if command -v docker >/dev/null 2>&1 || [ -e /var/run/docker.sock ]; then
  echo "FAIL docker_absent: this client can reach Docker"
  exit 1
fi
echo "PASS docker_absent: no docker program and no socket on the client"
grep -q "\"home\": \"$HOME_ORIGIN\"" "$FIXTURE/inputs.json" ||
  { echo "FAIL inputs: the proof's inputs name another CYFR than $HOME_ORIGIN"; exit 1; }

# The display and the bus are the ones xvfb-run and dbus-run-session give
# the command they run.
export APP FIXTURE
timeout 900 dbus-run-session -- xvfb-run -a -s "-screen 0 1400x1000x24" bash -c \
  'exec env -i HOME="$HOME" PATH=/usr/bin:/bin LANG=C.UTF-8 DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-}" \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" CYFR_DESKTOP_PROOF_FIXTURE="$FIXTURE" "$APP"' >"$OUT/app.log" 2>&1
code=$?
cat "$OUT/connect.txt" 2>/dev/null
if ! grep -qx 'RESULT [a-z]*' "$OUT/connect.txt" 2>/dev/null; then
  echo "FAIL proof: the proof did not finish (the app exited $code); the app's last lines:"
  tail -n 30 "$OUT/app.log"
  exit 1
fi
grep -qx 'RESULT passed' "$OUT/connect.txt"
