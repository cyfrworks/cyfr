#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The one pin of the cosign the app image carries, which
# `Compendium.Cosign` runs from PATH to verify a pulled component's
# signature (CYFR_COSIGN_KEY, CYFR_COSIGN_IDENTITY and CYFR_COSIGN_ISSUER;
# CYFR_REQUIRE_SIGNED_PULLS refuses a pull it cannot verify), and its
# installer:
#
#   scripts/cosign.sh install DIR   install DIR/cosign: the pinned release
#                                   for this machine's architecture, checked
#                                   against the pinned sha256; a DIR/cosign
#                                   already at the pinned version is kept
#   scripts/cosign.sh version       print the pinned version
#
# The version is the one the release workflow signs with
# (sigstore/cosign-installer's default in .github/workflows/release.yml).
# The checksums are upstream's cosign_checksums.txt lines for the two
# binaries, which GitHub's recorded sha256 for each release asset matches.
set -euo pipefail

VERSION=3.1.4
SHA256_AMD64=424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa
SHA256_ARM64=ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2

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
  x86_64 | amd64) arch=amd64; sha=$SHA256_AMD64 ;;
  aarch64 | arm64) arch=arm64; sha=$SHA256_ARM64 ;;
  *) echo "cosign: no pinned release for $(uname -m)" >&2; exit 1 ;;
esac

if [ -x "$dir/cosign" ] &&
  "$dir/cosign" version --json 2>/dev/null | grep -q "\"gitVersion\": *\"v$VERSION\""; then
  exit 0
fi

name="cosign-linux-$arch"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl --proto '=https' --tlsv1.2 -sSfL --max-time 300 --connect-timeout 20 -o "$work/$name" \
  "https://github.com/sigstore/cosign/releases/download/v$VERSION/$name"
echo "$sha  $work/$name" | sha256sum -c --quiet -
mkdir -p "$dir"
# Into place by a rename: two installs into one DIR at once, or a reader
# running the tool meanwhile, never see a file half written.
trap 'rm -rf "$work" "$dir/.cosign.$$"' EXIT
install -m 0755 "$work/$name" "$dir/.cosign.$$"
mv -f "$dir/.cosign.$$" "$dir/cosign"
"$dir/cosign" version --json >/dev/null
echo "cosign $VERSION"
