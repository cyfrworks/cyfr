#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Installs trivy VERSION into DIR/trivy, as the commit gate's close runs it:
#
#   scripts/lib/trivy-install.sh VERSION DIR
#
# VERSION is the one the workflows' aquasecurity/trivy-action steps pin
# (`v0.75.0` or `0.75.0`). The release archive for this machine comes from
# the trivy release on GitHub that trivy-action installs from, and is
# checked against the sha256 that release's checksums file records. A
# DIR/trivy already at VERSION is kept.
set -euo pipefail

usage() { echo "usage: $0 VERSION DIR" >&2; exit 64; }
[ "$#" -eq 2 ] || usage
version=${1#v} dir=$2
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "trivy-install: $1 is no release version" >&2; exit 64; }

case "$(uname -s):$(uname -m)" in
  Linux:x86_64 | Linux:amd64) platform=Linux-64bit ;;
  Linux:aarch64 | Linux:arm64) platform=Linux-ARM64 ;;
  Darwin:x86_64) platform=macOS-64bit ;;
  Darwin:arm64) platform=macOS-ARM64 ;;
  *) echo "trivy-install: no trivy release for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

have=
[ ! -x "$dir/trivy" ] || have=$("$dir/trivy" --version 2>/dev/null) || have=
case $'\n'"$have"$'\n' in *$'\n'"Version: $version"$'\n'*) exit 0 ;; esac

name="trivy_${version}_$platform.tar.gz"
base="https://github.com/aquasecurity/trivy/releases/download/v$version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fetch() {
  curl --proto '=https' --tlsv1.2 -sSfL --max-time 300 --connect-timeout 20 -o "$work/$1" "$base/$1"
}
fetch "$name"
fetch "trivy_${version}_checksums.txt"
sha=$(awk -v n="$name" '$2 == n { print $1 }' "$work/trivy_${version}_checksums.txt")
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "trivy-install: the release's checksums name no sha256 for $name" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  echo "$sha  $work/$name" | sha256sum -c --quiet -
else
  echo "$sha  $work/$name" | shasum -a 256 -c --quiet -
fi
tar -xzf "$work/$name" -C "$work" trivy
mkdir -p "$dir"
install -m 0755 "$work/trivy" "$dir/trivy"
"$dir/trivy" --version | head -n 1
