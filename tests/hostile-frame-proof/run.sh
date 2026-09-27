#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The frame sandbox containment proof (README.md): the proof's tinctures
# (tinctures/) published into a signed-in person's athanor of a `cyfr`
# release started as the browser harness starts one
# (tests/browser/harness.sh), and the probe opened from the Prism shell in
# every browser of the harness's matrix (proof.mjs), once as a private
# tincture and once as a public one.
#
# Usage: tests/hostile-frame-proof/run.sh
# Writes containment-proof.json and containment-proof.md into PROOF_OUT
# (default: the scratch directory, kept with RELEASE_BOOT_KEEP=1). Set
# RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run built.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-containment-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
HERE="$ROOT/tests/hostile-frame-proof"
OUT="${PROOF_OUT:-$WORK/out}"

cleanup() {
  server_stop
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

release_build
CELL="$WORK/cell"
browser_cell "$CELL"

step "starting the release on a fresh SQLite cell, as cyfr.test"
server_start "$CELL"

step "publishing the probe (private, and a public copy), its private neighbour and the public neighbour"
person="$(server_fixture "$CELL" person operator@example.com containment-proof)"
[ -n "$person" ] || fail "the fixture signed nobody in"
field() { printf '%s' "$person" | python3 -c "import json, sys; print(json.load(sys.stdin)['$1'])"; }
user_id="$(field user_id)"
segment="$(field segment)"
cookie="$(browser_cookie "$CELL" "$(field token)")"
browser_picker_layout "$CELL" "$(field token)"

# The public copy is the same bundle under another name.
cp -R "$HERE/tinctures/containment-probe" "$WORK/containment-probe-public"
sed -i 's/"name": "containment-probe"/"name": "containment-probe-public"/' \
  "$WORK/containment-probe-public/cyfr-manifest.json"

server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/containment-probe" containment-probe private >/dev/null
server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/containment-neighbour" containment-neighbour private >/dev/null
server_fixture "$CELL" tincture "$user_id" "$WORK/containment-probe-public" containment-probe-public public >/dev/null
neighbour="$(server_fixture "$CELL" tincture "$user_id" "$ROOT/tests/browser/tinctures/frame-neighbour" frame-neighbour public)"
neighbour_path="$(printf '%s' "$neighbour" | python3 -c 'import json, sys; print(json.load(sys.stdin)["path"])')"

status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/t/$segment/local/containment-probe")"
[ "$status" = 404 ] || fail "the private probe's public address answered $status"
status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$neighbour_path/neighbour.js")"
[ "$status" = 200 ] || fail "the public neighbour's script answered $status"

step "the containment proof in $PLAYWRIGHT_IMAGE"
playwright_run hostile-frame-proof proof.mjs "http://127.0.0.1:$PORT" "$segment" "$cookie" /out "$neighbour_path"

echo "the record: $OUT/containment-proof.json and $OUT/containment-proof.md"
