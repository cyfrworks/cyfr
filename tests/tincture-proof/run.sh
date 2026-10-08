#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The tincture proof (README.md): proof-game (game/), built from its
# lockfile in the Locus builds image (build.py), published private through
# the publish check into a signed-in person's athanor of a `cyfr` release
# started as the browser harness starts one (tests/browser/harness.sh), and
# opened from the Prism shell in every browser of the harness's matrix
# (proof.mjs).
#
# Usage: tests/tincture-proof/run.sh LOCUS_IMAGE [OPENS]
# LOCUS_IMAGE is an image built from Dockerfile.locus; OPENS (default 50)
# the warm and the cold opens measured per browser. Writes
# tincture-proof.json and tincture-proof.md into PROOF_OUT (default: the
# scratch directory, kept with RELEASE_BOOT_KEEP=1). Set
# RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run built.
set -euo pipefail

LOCUS_IMAGE="${1:?usage: tests/tincture-proof/run.sh LOCUS_IMAGE [OPENS]}"
OPENS="${2:-50}"

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-tincture-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
HERE="$ROOT/tests/tincture-proof"
OUT="${PROOF_OUT:-$WORK/out}"

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

step "building proof-game in $LOCUS_IMAGE"
python3 "$HERE/build.py" "$LOCUS_IMAGE" "$WORK/proof-game" || fail "proof-game did not build"

release_build
CELL="$WORK/cell"
browser_cell "$CELL"

step "starting the release on a fresh SQLite cell, as cyfr.test"
server_start "$CELL"

step "publishing proof-game, private, through the publish check"
person="$(server_fixture "$CELL" person operator@example.com tincture-proof)"
[ -n "$person" ] || fail "the fixture signed nobody in"
field() { printf '%s' "$person" | python3 -c "import json, sys; print(json.load(sys.stdin)['$1'])"; }
cookie="$(browser_cookie "$CELL" "$(field token)")"
browser_picker_layout "$CELL" "$(field token)"
published="$(server_fixture "$CELL" tincture "$(field user_id)" "$WORK/proof-game" proof-game private)"
[ -n "$published" ] || fail "proof-game was not published"
status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/t/$(field segment)/local/proof-game")"
[ "$status" = 404 ] || fail "the private tincture's public address answered $status"

step "the tincture proof in $PLAYWRIGHT_IMAGE, $OPENS opens each way"
playwright_run tincture-proof proof.mjs "http://127.0.0.1:$PORT" "$(field segment)" "$cookie" /out "$OPENS"

echo "the record: $OUT/tincture-proof.json and $OUT/tincture-proof.md"
