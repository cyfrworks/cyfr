#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build hog.wasm from hog.wat, in a scratch directory, with
# `_tools/wasm-tools` at the version scripts/wasm-tools.sh pins, and
# nothing else: the core module parsed and stripped of its custom
# sections, the catalyst world's WIT embedded and the component made. The
# component records the version of the tool that made it, so another
# version gives other bytes. memory.py holds hog.wat and hog.wasm to the
# digests this prints, so a source changed without a rebuild fails the
# suite.
#
# Usage, from anywhere in the repository:
#   build.sh            build, write hog.wasm, print the digests memory.py records
#   build.sh --check    build and compare with the checked-in hog.wasm
#
# Exit 0 built or identical; 1 hog.wasm differs; 2 usage; 69
# `_tools/wasm-tools` is missing or not the pinned version.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"

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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

"$wasm_tools" parse "$here/hog.wat" -o "$work/hog.parsed.wasm"
"$wasm_tools" strip --all "$work/hog.parsed.wasm" -o "$work/hog.core.wasm"
"$wasm_tools" component embed "$root/wit/catalyst" --world catalyst "$work/hog.core.wasm" \
  -o "$work/hog.embedded.wasm"
"$wasm_tools" component new "$work/hog.embedded.wasm" -o "$work/hog.wasm"

if [ "${1:-}" = --check ]; then
  if cmp -s "$work/hog.wasm" "$here/hog.wasm"; then
    echo "hog.wasm is byte-identical to a fresh build ($(digest "$work/hog.wasm"))"
  else
    echo "hog.wasm differs from a fresh build ($(digest "$work/hog.wasm"))" >&2
    exit 1
  fi
  exit 0
fi

cp "$work/hog.wasm" "$here/hog.wasm"
echo "hog.wat  sha256:$(digest "$here/hog.wat")"
echo "hog.wasm sha256:$(digest "$here/hog.wasm")"
