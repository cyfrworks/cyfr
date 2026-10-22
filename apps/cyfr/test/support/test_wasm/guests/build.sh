#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build the reagent, the catalyst and the formula guest from their .wat, in
# a scratch directory, with `_tools/wasm-tools` at the version
# scripts/wasm-tools.sh pins, and nothing else: each core module parsed and
# stripped of its custom sections, its world's WIT from wit/ embedded and
# the component made, which records the version of the tool that made it.
#
# Usage, from anywhere in the repository:
#   build.sh            build and write each .wasm
#   build.sh --check    build and compare with the checked-in binaries
#
# Exit 0 built or identical; 1 a binary differs; 2 usage; 69
# `_tools/wasm-tools` is missing or not the pinned version.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../../../../../.." && pwd -P)"

case "${1:-}" in
  --check | "") ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

# The legacy text syntax stays refused whatever the caller exported.
unset WAST_STRICT_COMPONENT_INDICES
wasm_tools="$root/_tools/wasm-tools"
pinned="$("$root/scripts/wasm-tools.sh" version)"
case "$("$wasm_tools" --version 2>/dev/null)" in
  "wasm-tools $pinned "*) ;;
  *)
    echo "$wasm_tools is not wasm-tools $pinned, the version scripts/wasm-tools.sh pins: run scripts/wasm-tools.sh install _tools" >&2
    exit 69
    ;;
esac

# Each guest is named for the world it is a component of.
guests="reagent catalyst formula"

# Every source and binary here is a guest's, so none goes unbuilt.
for file in "$here"/*.wat "$here"/*.wasm; do
  [ -e "$file" ] || continue
  base="$(basename "$file")"
  case " $guests " in
    *" ${base%.*} "*) ;;
    *)
      echo "$base is no guest's of build.sh" >&2
      exit 1
      ;;
  esac
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

for world in $guests; do
  "$wasm_tools" parse "$here/$world.wat" -o "$work/$world.parsed.wasm"
  "$wasm_tools" strip --all "$work/$world.parsed.wasm" -o "$work/$world.core.wasm"
  "$wasm_tools" component embed "$root/wit/$world" --world "$world" "$work/$world.core.wasm" \
    -o "$work/$world.embedded.wasm"
  "$wasm_tools" component new "$work/$world.embedded.wasm" -o "$work/$world.wasm"
done

if [ "${1:-}" = --check ]; then
  status=0
  for world in $guests; do
    if cmp -s "$work/$world.wasm" "$here/$world.wasm"; then
      echo "$world.wasm is byte-identical to a fresh build"
    else
      echo "$world.wasm differs from a fresh build" >&2
      status=1
    fi
  done
  exit "$status"
fi

for world in $guests; do
  cp "$work/$world.wasm" "$here/$world.wasm"
done
