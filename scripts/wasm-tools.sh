#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The one pin of wasm-tools, the validator every component passes before it
# is stored or compiled (`Prima.ComponentFeatures`), and the one installer
# every site runs: both images, CI and a checkout's own `_tools`.
#
#   scripts/wasm-tools.sh install DIR   install DIR/wasm-tools: the pinned
#                                       release for this machine's
#                                       architecture, its archive checked
#                                       against the pinned sha256; a
#                                       DIR/wasm-tools already at the pinned
#                                       version is kept
#   scripts/wasm-tools.sh version       print the pinned version
#
# The checksums are the sha256 GitHub records for upstream's release
# archives on the release page the download below names,
# which the archives downloaded from it hash to.
set -euo pipefail

VERSION=1.261.0
SHA256_X86_64=ad62b2176037e93e1348cb65d6212d128ca9f097b63d155569f25215818ff7b1
SHA256_AARCH64=6f19389a69e21c7dbd2a4e7ae72f807dc999988b48782c706c4102bad3e44487

usage() { echo "usage: $0 install DIR | version" >&2; exit 64; }

case "${1:-}" in
  version)
    echo "$VERSION"
    exit 0
    ;;
  install)
    [ "$#" -eq 2 ] || usage
    dir=$2
    ;;
  *) usage ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64; sha=$SHA256_X86_64 ;;
  aarch64 | arm64) arch=aarch64; sha=$SHA256_AARCH64 ;;
  *) echo "wasm-tools: no pinned release for $(uname -m)" >&2; exit 1 ;;
esac

if [ -x "$dir/wasm-tools" ] &&
  "$dir/wasm-tools" --version 2>/dev/null | grep -q "^wasm-tools $VERSION "; then
  exit 0
fi

name="wasm-tools-$VERSION-$arch-linux"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl --proto '=https' --tlsv1.2 -sSfL --max-time 120 --connect-timeout 20 -o "$work/$name.tar.gz" \
  "https://github.com/bytecodealliance/wasm-tools/releases/download/v$VERSION/$name.tar.gz"
echo "$sha  $work/$name.tar.gz" | sha256sum -c --quiet -
tar -xzf "$work/$name.tar.gz" -C "$work"
mkdir -p "$dir"
install -m 0755 "$work/$name/wasm-tools" "$dir/wasm-tools"
"$dir/wasm-tools" --version
