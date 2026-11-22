#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# One proof against a real CYFR, as a script's run.sh starts it in the
# client container as its user (README.md): the installed app, whose
# entry is that folder's proof.js, under a display and a session bus,
# with nothing of this environment but those, HOME and where the proof's
# inputs are. The app is launched once for each PHASE, in order. Each
# launch appends one PASS or FAIL line a row to FIXTURE_DIR/out/NAME.txt
# and its RESULT line, and writes its record to NAME-PHASE.json; one FAIL,
# or a launch that does not finish its record, fails the run. The app's own
# output goes to FIXTURE_DIR/app-output alone, a pipe home.sh reads: it is
# scrubbed there before any of it is written.
#
# Usage: bash tests/desktop-proof/launch.sh NAME APP_PATH HOME_ORIGIN FIXTURE_DIR PHASE...
set -uo pipefail
NAME="${1:?usage: launch.sh NAME APP_PATH HOME_ORIGIN FIXTURE_DIR PHASE...}"
APP="${2:?}"
HOME_ORIGIN="${3:?}"
FIXTURE="${4:?}"
shift 4
[ "$#" -gt 0 ] || { echo "launch.sh: no phase"; exit 64; }
OUT="$FIXTURE/out"
mkdir -p "$OUT"
rm -f "$OUT/$NAME.txt" "$OUT/$NAME"-*.json

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
[ -p "$FIXTURE/app-output" ] || { echo "FAIL output: no pipe takes the app's output"; exit 1; }
exec 9>"$FIXTURE/app-output"
for phase in "$@"; do
  echo "=== $phase" >&9
  # The last launch's cyfr leaves 127.0.0.1:7340 as it ends.
  for _ in $(seq 100); do
    (exec 3<>/dev/tcp/127.0.0.1/7340) 2>/dev/null || break
    sleep 0.1 # sleep-ok: polls the port the last launch's cyfr releases as it ends
  done
  export PHASE="$phase"
  timeout 900 dbus-run-session -- xvfb-run -a -s "-screen 0 1400x1000x24" bash -c \
    'exec env -i HOME="$HOME" PATH=/usr/bin:/bin LANG=C.UTF-8 DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-}" \
      DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" CYFR_DESKTOP_PROOF_FIXTURE="$FIXTURE" \
      CYFR_DESKTOP_PROOF_PHASE="$PHASE" "$APP"' >&9 2>&1
  code=$?
  if ! grep -qx "RESULT $phase [a-z]*" "$OUT/$NAME.txt" 2>/dev/null; then
    cat "$OUT/$NAME.txt" 2>/dev/null
    echo "FAIL proof: the $phase launch did not finish (the app exited $code); the app's last lines follow"
    exit 1
  fi
  if ! grep -qx "RESULT $phase passed" "$OUT/$NAME.txt"; then
    cat "$OUT/$NAME.txt"
    exit 1
  fi
done
cat "$OUT/$NAME.txt"
