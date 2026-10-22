#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Check that every test WASM fixture is its source's build:
#   scripts/check-test-wasm.sh [--wat-only]
#
# Each recipe's build.sh --check builds its fixtures afresh and compares
# them byte for byte with the checked-in binaries: Locus's math, echo and
# spin, the hostile guests, CYFR's guests, the runtime image suite's hog,
# and the Rust fixtures. Every checked-in .wasm outside seed/ is one of a
# recipe's, or the check fails naming it. --wat-only skips
# building the Rust fixtures, for a host without their toolchain, and names
# them.
#
# Every recipe runs even after one fails. Exit 0 when every fixture
# checked is its source's build; 1 naming each recipe a binary of which is
# not; 2 on a usage error; 69 naming each recipe refused because its
# toolchain is missing or not the pinned one (its own message names the
# tool), whatever else failed.
set -uo pipefail

usage() { echo "usage: $0 [--wat-only]" >&2; exit 2; }

wat_only=false
case "$#:${1:-}" in
  0:) ;;
  1:--wat-only) wat_only=true ;;
  *) usage ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root" || exit 1

locus=apps/locus/test/support/runtime/test_wasm
cyfr=apps/cyfr/test/support/test_wasm
wat="$locus $locus/hostile $cyfr/guests tests/locus-runtime-image"
rust="$cyfr/chat_fixture $cyfr/step_stub apps/cyfr/test/integration/runtime/support/test_wasm/nested_probe"

differs=()
refused=()

# Every checked-in binary a recipe builds. Locus's two recipes and CYFR's
# guests' refuse a binary in their directory that is none of their own.
built="tests/locus-runtime-image/hog.wasm"
for dir in "$locus" "$locus/hostile" "$cyfr/guests"; do
  for wasm in "$dir"/*.wasm; do built="$built $wasm"; done
done
for dir in $rust; do built="$built $dir/$(basename "$dir").wasm"; done

if ! tracked="$(git ls-files -- '*.wasm' ':!:seed/**')"; then
  echo "the checked-in binaries could not be listed (git ls-files)" >&2
  exit 1
fi
for wasm in $tracked; do
  case " $built " in
    *" $wasm "*) ;;
    *)
      echo "$wasm is a test WASM fixture no recipe builds" >&2
      differs+=("$wasm")
      ;;
  esac
done

# A recipe runs as a child the check stops, and waits for, on TERM or
# INT; the recipe removes its scratch directory as it exits.
child=""
stop() {
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null && wait "$child"
  exit "$1"
}
trap 'stop 143' TERM
trap 'stop 130' INT

check() {
  "$1/build.sh" --check &
  child=$!
  wait "$child"
  local status=$?
  child=""
  case $status in
    0) ;;
    69) refused+=("$1") ;;
    *) differs+=("$1") ;;
  esac
}

for dir in $wat; do check "$dir"; done
if [ "$wat_only" = true ]; then
  echo "check-test-wasm: the Rust fixtures are not built (--wat-only): $rust"
else
  for dir in $rust; do check "$dir"; done
fi

status=0
if [ "${#differs[@]}" -gt 0 ]; then
  echo "check-test-wasm: not their sources' builds: ${differs[*]}" >&2
  status=1
fi
if [ "${#refused[@]}" -gt 0 ]; then
  echo "check-test-wasm: refused for a missing or unpinned toolchain: ${refused[*]}" >&2
  status=69
fi
[ "$status" = 0 ] && echo "check-test-wasm: every fixture checked is its source's build"
exit "$status"
