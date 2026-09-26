#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The browser harness: the `cyfr` release started as tests/release-boot/
# starts one (tests/release-boot/release.sh), on SQLite, with the two
# tinctures of tests/browser/tinctures/ published publicly in a signed-in
# person's athanor, and the frame-facts experiment (frame-facts.mjs) run
# against it in every browser the official Playwright image ships.
#
# The browsers are the image's own, pinned by digest below, so no browser
# binary is fetched at test time; Playwright's library is `playwright-core`
# at the version the image ships, installed from package-lock.json with its
# integrity hash and no install scripts — JavaScript only. The container
# shares this host's network, so it reaches the server on loopback.
#
# Usage: tests/browser/run.sh
# Writes frame-facts.json and frame-facts.md into BROWSER_OUT (default: the
# scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints the table.
# Set RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run built.
set -euo pipefail

# mcr.microsoft.com/playwright:v1.63.0-noble
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27"

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-browser-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
HERE="$ROOT/tests/browser"
OUT="${BROWSER_OUT:-$WORK/out}"

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
cell_new "$CELL"

step "starting the release on a fresh SQLite cell"
server_start "$CELL"

step "publishing frame-probe and frame-neighbour, public, in a signed-in person's athanor"
person="$(server_fixture "$CELL" person operator@example.com browser-harness)"
[ -n "$person" ] || fail "the fixture signed nobody in"
user_id="$(printf '%s' "$person" | python3 -c 'import json, sys; print(json.load(sys.stdin)["user_id"])')"
server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/frame-neighbour" frame-neighbour public >/dev/null
probe="$(server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/frame-probe" frame-probe public)"
probe_path="$(printf '%s' "$probe" | python3 -c 'import json, sys; print(json.load(sys.stdin)["path"])')"
status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$probe_path")"
[ "$status" = 200 ] || fail "the public page $probe_path answered $status"
echo "serving $probe_path"

step "the frame-facts experiment in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
docker run --rm --network host --ipc=host \
  -u "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_update_notifier=false \
  -v "$HERE:/harness:ro" -v "$OUT:/out" \
  "$PLAYWRIGHT_IMAGE" \
  sh -c 'cp -R /harness /tmp/harness && cd /tmp/harness &&
         npm ci --ignore-scripts --no-audit --no-fund --loglevel=error &&
         node frame-facts.mjs "$0" "$1" /out' \
  "http://127.0.0.1:$PORT" "$probe_path"

echo "the record: $OUT/frame-facts.json and $OUT/frame-facts.md"
