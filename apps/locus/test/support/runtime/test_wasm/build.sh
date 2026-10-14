#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build math, echo and spin from their .wat, in a scratch directory, with
# `_tools/wasm-tools` at the version scripts/wasm-tools.sh pins, and
# nothing else: each core module parsed and stripped of its custom
# sections; math kept a core module, echo and spin given the reagent
# world's WIT and made components, which record the version of the tool
# that made them. CYFR's suite holds a byte copy of math.wasm, written and
# compared with Locus's.
#
# Usage, from anywhere in the repository:
#   build.sh            build and write each .wasm and CYFR's copy
#   build.sh --check    build and compare with the checked-in binaries
#
# Exit 0 built or identical; 1 a binary differs; 2 usage; 69
# `_tools/wasm-tools` is missing or not the pinned version.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../../../../../.." && pwd -P)"
copy="$root/apps/cyfr/test/support/test_wasm/math.wasm"

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

# Each fixture and the world it is a component of, or `core`.
fixtures="math:core echo:reagent spin:reagent"

# Every source and binary here is a fixture's, so none goes unbuilt.
for file in "$here"/*.wat "$here"/*.wasm; do
  base="$(basename "$file")"
  case " $fixtures " in
    *" ${base%.*}:"*) ;;
    *)
      echo "$base is no fixture's of build.sh" >&2
      exit 1
      ;;
  esac
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

for entry in $fixtures; do
  name="${entry%%:*}"
  world="${entry##*:}"
  "$wasm_tools" parse "$here/$name.wat" -o "$work/$name.parsed.wasm"
  if [ "$world" = core ]; then
    "$wasm_tools" strip --all "$work/$name.parsed.wasm" -o "$work/$name.wasm"
    continue
  fi
  "$wasm_tools" strip --all "$work/$name.parsed.wasm" -o "$work/$name.core.wasm"
  "$wasm_tools" component embed "$root/wit/$world" --world "$world" "$work/$name.core.wasm" \
    -o "$work/$name.embedded.wasm"
  "$wasm_tools" component new "$work/$name.embedded.wasm" -o "$work/$name.wasm"
done

if [ "${1:-}" = --check ]; then
  status=0
  for entry in $fixtures; do
    name="${entry%%:*}"
    if cmp -s "$work/$name.wasm" "$here/$name.wasm"; then
      echo "$name.wasm is byte-identical to a fresh build"
    else
      echo "$name.wasm differs from a fresh build" >&2
      status=1
    fi
  done
  if cmp -s "$work/math.wasm" "$copy"; then
    echo "CYFR's math.wasm is byte-identical to a fresh build"
  else
    echo "CYFR's math.wasm ($copy) differs from a fresh build" >&2
    status=1
  fi
  exit "$status"
fi

for entry in $fixtures; do
  name="${entry%%:*}"
  cp "$work/$name.wasm" "$here/$name.wasm"
done
cp "$work/math.wasm" "$copy"
