#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build each guest of this directory from its .wat: the core module with
# wabt's wat2wasm, its world's WIT embedded and the component made with
# wasm-tools, in a scratch directory. The tools and versions README.md
# names give the same bytes on every host.
#
# Usage, from anywhere in the repository:
#   build.sh            build, write each .wasm, print the digests README.md
#                       records
#   build.sh --check    build and compare with the checked-in binaries
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../../../../../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Each guest and the world it is a component of.
guests="extra_memory:reagent wide_table:reagent grower:reagent"

digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

for entry in $guests; do
  name="${entry%%:*}"
  world="${entry##*:}"
  wat2wasm --enable-multi-memory "$here/$name.wat" -o "$work/$name.core.wasm"
  wasm-tools component embed "$root/wit/$world" --world "$world" "$work/$name.core.wasm" \
    -o "$work/$name.embedded.wasm"
  wasm-tools component new "$work/$name.embedded.wasm" -o "$work/$name.wasm"
done

case "${1:-}" in
  --check)
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
    ;;
  "")
    for entry in $guests; do
      name="${entry%%:*}"
      cp "$work/$name.wasm" "$here/$name.wasm"
      printf '%-17s sha256:%s\n' "$name.wat" "$(digest "$here/$name.wat")"
      printf '%-17s sha256:%s\n' "$name.wasm" "$(digest "$here/$name.wasm")"
    done
    ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac
