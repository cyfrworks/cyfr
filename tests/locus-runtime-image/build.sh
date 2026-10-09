#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build hog.wasm from hog.wat: the core module with wabt's wat2wasm 1.0.41,
# the catalyst world's WIT embedded and the component made with wasm-tools
# 1.244.0 (the component carries the latter's version, so another version
# gives other bytes), in a scratch directory. memory.py holds hog.wat and
# hog.wasm to the digests this prints, so a source changed without a
# rebuild fails the suite.
#
# Usage, from anywhere in the repository:
#   build.sh            build, write hog.wasm, print the digests memory.py records
#   build.sh --check    build and compare with the checked-in hog.wasm
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

wat2wasm "$here/hog.wat" -o "$work/hog.core.wasm"
wasm-tools component embed "$root/wit/catalyst" --world catalyst "$work/hog.core.wasm" \
  -o "$work/hog.embedded.wasm"
wasm-tools component new "$work/hog.embedded.wasm" -o "$work/hog.wasm"

case "${1:-}" in
  --check)
    if cmp -s "$work/hog.wasm" "$here/hog.wasm"; then
      echo "hog.wasm is byte-identical to a fresh build ($(digest "$work/hog.wasm"))"
    else
      echo "hog.wasm differs from a fresh build ($(digest "$work/hog.wasm"))" >&2
      exit 1
    fi
    ;;
  "")
    cp "$work/hog.wasm" "$here/hog.wasm"
    echo "hog.wat  sha256:$(digest "$here/hog.wat")"
    echo "hog.wasm sha256:$(digest "$here/hog.wasm")"
    ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac
