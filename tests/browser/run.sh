#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The browser harness: the `cyfr` release started as tests/release-boot/
# starts one (tests/release-boot/release.sh), on SQLite, under the name
# cyfr.test (tests/browser/harness.sh), with the two tinctures of
# tests/browser/tinctures/ published publicly in a signed-in person's
# athanor, and the frame-facts experiment (frame-facts.mjs) run against it
# in every browser the official Playwright image ships: the person opens
# frame-probe from the Prism shell, which creates its frame.
#
# Usage: tests/browser/run.sh
# Writes frame-facts.json and frame-facts.md into BROWSER_OUT (default: the
# scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints the table.
# Set RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run built.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-browser-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=harness.sh
source "$ROOT/tests/browser/harness.sh"
HERE="$ROOT/tests/browser"
OUT="${BROWSER_OUT:-$WORK/out}"

# The scratch directory holds the run's keys, so it goes even when a stop
# fails. `server_stop` ends in `fail`, an `exit`, when a listener outlives
# its stop, and an exit inside this trap would end it before the removal,
# so the stop runs in a subshell, whose exit ends only that subshell; the
# stop's failure still fails the run.
cleanup() {
  local code=$?
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

release_build
CELL="$WORK/cell"
browser_cell "$CELL"

step "starting the release on a fresh SQLite cell, as cyfr.test"
server_start "$CELL"

step "publishing frame-probe and frame-neighbour, public, in a signed-in person's athanor"
person="$(server_fixture "$CELL" person operator@example.com browser-harness)"
[ -n "$person" ] || fail "the fixture signed nobody in"
field() { printf '%s' "$person" | python3 -c "import json, sys; print(json.load(sys.stdin)['$1'])"; }
user_id="$(field user_id)"
segment="$(field segment)"
cookie="$(browser_cookie "$CELL" "$(field token)")"
browser_picker_layout "$CELL" "$(field token)"
server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/frame-neighbour" frame-neighbour public >/dev/null
probe="$(server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/frame-probe" frame-probe public)"
probe_path="$(printf '%s' "$probe" | python3 -c 'import json, sys; print(json.load(sys.stdin)["path"])')"
status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$probe_path")"
[ "$status" = 200 ] || fail "the public page $probe_path answered $status"
echo "serving $probe_path"

step "the frame-facts experiment in $PLAYWRIGHT_IMAGE"
playwright_run browser frame-facts.mjs "http://127.0.0.1:$PORT" "$probe_path" "$segment" "$cookie" /out

echo "the record: $OUT/frame-facts.json and $OUT/frame-facts.md"
