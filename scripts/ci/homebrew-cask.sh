#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Writes the Homebrew cask that installs the CYFR app: CYFR.app from the
# release's Mac DMG, for Apple silicon alone (brew refuses an Intel Mac,
# in its own words), with the app's bundled cyfr linked as brew's cyfr.
# The DMG's sha256 is read from its own bytes in PACKAGES_DIR, so the cask
# can name no other file:
#
#   scripts/ci/homebrew-cask.sh VERSION PACKAGES_DIR URL_BASE > cyfr.rb
#
# URL_BASE is the folder the DMG is downloaded from, without a trailing
# slash, written into the cask as it is given: the release's download
# folder, https://github.com/cyfrworks/cyfr/releases/download/#{version},
# for a release (release.yml), a file:// URL for the local tap's proof
# (tests/desktop-proof/native/brew-tap.sh). The release checks what this
# writes against the same files before anything is published
# (tests/ci-release-graph.py --installers).
#
# Exit status: 0 the cask is written; 1 the DMG is missing or cannot be read;
# 64 usage.
set -euo pipefail

if [ "$#" -ne 3 ] || [ -z "$1" ] || [ ! -d "$2" ] || [ -z "$3" ]; then
  echo "usage: $0 VERSION PACKAGES_DIR URL_BASE" >&2
  exit 64
fi
version=$1 dir=$2 base=${3%/}

dmg="$dir/cyfr-desktop_${version}_darwin_arm64.dmg"
[ -f "$dmg" ] || { echo "$0: no $dmg" >&2; exit 1; }
out=$(sha256sum "$dmg" 2>/dev/null || shasum -a 256 "$dmg") || { echo "$0: cannot read $dmg" >&2; exit 1; }
sum=${out%% *}

cat <<EOF
cask "cyfr" do
  version "$version"
  sha256 "$sum"

  url "$base/cyfr-desktop_#{version}_darwin_arm64.dmg"
  name "CYFR"
  desc "App and CLI for the CYFR sandboxed runtime"
  homepage "https://cyfr.run/"

  depends_on arch: :arm64
  depends_on :macos

  app "CYFR.app"
  binary "#{appdir}/CYFR.app/Contents/Resources/cyfr"
end
EOF
