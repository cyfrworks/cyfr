#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build each guest of this directory from its .wat, in a scratch
# directory, with the pinned `_tools/wasm-tools` alone (installed first by
# scripts/wasm-tools.sh): a core module parsed and stripped of its custom
# sections, its world's WIT embedded and the component made; or, for a
# guest whose `.wat` is a whole component (`text`), parsed as it stands.
# The component records the version of the tool that made it, so the
# pinned version gives the same bytes on every host.
#
# Usage, from anywhere in the repository:
#   build.sh            build, write each .wasm, print the digests README.md
#                       records
#   build.sh --check    build and compare with the checked-in binaries
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../../../../../../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

case "${1:-}" in
  --check | "") ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

"$root/scripts/wasm-tools.sh" install "$root/_tools"
wasm_tools="$root/_tools/wasm-tools"

# Each guest and the world it is a component of, or `text`.
guests="extra_memory:reagent wide_table:reagent grower:reagent vault_probe:catalyst attached_header_probe:catalyst credential_canary:catalyst trapper:reagent async_lift:text sync_lift:text gc_alloc:text exception_throw:text externref_table:text"

digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Every source and binary here is a guest's, so none goes unbuilt.
for file in "$here"/*.wat "$here"/*.wasm; do
  base="$(basename "$file")"
  case " $guests " in
    *" ${base%.*}:"*) ;;
    *)
      echo "$base is no guest's of build.sh" >&2
      exit 1
      ;;
  esac
done

for entry in $guests; do
  name="${entry%%:*}"
  world="${entry##*:}"
  if [ "$world" = text ]; then
    "$wasm_tools" parse "$here/$name.wat" -o "$work/$name.wasm"
    continue
  fi
  "$wasm_tools" parse "$here/$name.wat" -o "$work/$name.parsed.wasm"
  "$wasm_tools" strip --all "$work/$name.parsed.wasm" -o "$work/$name.core.wasm"
  "$wasm_tools" component embed "$root/wit/$world" --world "$world" "$work/$name.core.wasm" \
    -o "$work/$name.embedded.wasm"
  "$wasm_tools" component new "$work/$name.embedded.wasm" -o "$work/$name.wasm"
done

if [ "${1:-}" = --check ]; then
  status=0
  for entry in $guests; do
    name="${entry%%:*}"
    if cmp -s "$work/$name.wasm" "$here/$name.wasm"; then
      echo "$name.wasm is byte-identical to a fresh build ($(digest "$work/$name.wasm"))"
    else
      echo "$name.wasm differs from a fresh build ($(digest "$work/$name.wasm"))" >&2
      status=1
    fi
  done
  exit "$status"
fi

for entry in $guests; do
  name="${entry%%:*}"
  cp "$work/$name.wasm" "$here/$name.wasm"
  printf '%-26s sha256:%s\n' "$name.wat" "$(digest "$here/$name.wat")"
  printf '%-26s sha256:%s\n' "$name.wasm" "$(digest "$here/$name.wasm")"
done
