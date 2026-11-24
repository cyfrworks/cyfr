#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Homebrew cask the release writes (scripts/ci/homebrew-cask.sh),
# installed, upgraded and removed through a local tap as a person runs brew,
# from two packages of this Mac's architecture, A and B, each the CYFR app's
# DMG at its version. The other architecture's DMG is a stand-in, which
# brew never fetches here. Each check prints one PASS or FAIL line, and one
# FAIL fails the run:
#
#   style      brew style accepts the cask
#   install    brew installs A: CYFR.app in /Applications at A's version,
#              and brew's cyfr a link to the app's bundled cyfr, which a
#              fresh login shell finds first and which answers --version
#   upgrade    brew upgrades to B: the app at B's version, the link the
#              same, and brew records B
#   uninstall  brew removes the app and the link
#
# Brew's quarantine of what it downloads, and Gatekeeper's first launch of
# a notarised app, are a person's Mac's: GitHub's runner launches a
# quarantined app all the same.
#
# Usage: bash tests/desktop-proof/native/brew-tap.sh ARCH A_VERSION A_DMG B_VERSION B_DMG
# It runs on a disposable macOS runner with no CYFR.app in /Applications.
set -uo pipefail

[ "$#" -eq 5 ] && [ -f "$3" ] && [ -f "$5" ] || {
  echo "usage: bash $0 ARCH A_VERSION A_DMG B_VERSION B_DMG" >&2; exit 64; }
ARCH=$1
case "$ARCH" in arm64) OTHER=amd64 ;; amd64) OTHER=arm64 ;; *) echo "brew-tap: ARCH is arm64 or amd64" >&2; exit 64 ;; esac
[ ! -e /Applications/CYFR.app ] || { echo "brew-tap: refused: /Applications/CYFR.app is already there" >&2; exit 64; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
RUN=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cyfr-brew-tap.XXXXXX") || exit 1
PREFIX=$(brew --prefix) || exit 1
APP=/Applications/CYFR.app
LINK=$PREFIX/bin/cyfr
failed=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; failed=1; }

brew tap-new --no-git cyfrproof/local >/dev/null || { echo "brew-tap: brew tap-new failed" >&2; exit 1; }
TAP=$(brew --repository)/Library/Taps/cyfrproof/homebrew-local
mkdir -p "$TAP/Casks"
# Homebrew loads a cask of another's tap for style and lookups only once
# the tap is trusted; installing a cask by its tap's name trusts that cask.
brew trust cyfrproof/local >/dev/null || { echo "brew-tap: brew trust failed" >&2; exit 1; }

# The cask for VERSION from its DMG, beside a stand-in for the other
# architecture, served from the folder they are in.
cask() {
  local dir="$RUN/$1"
  mkdir -p "$dir"
  cp "$2" "$dir/cyfr-desktop_$1_darwin_${ARCH}.dmg"
  printf 'the %s stand-in\n' "$OTHER" > "$dir/cyfr-desktop_$1_darwin_${OTHER}.dmg"
  bash "$ROOT/scripts/ci/homebrew-cask.sh" "$1" "$dir" "file://$dir" > "$TAP/Casks/cyfr.rb"
}
version_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null; }
linked() { [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$APP/Contents/Resources/cyfr" ]; }

cask "$2" "$3" || { echo "brew-tap: the cask for $2 was not written" >&2; exit 1; }
if out=$(brew style "$TAP/Casks/cyfr.rb" 2>&1); then pass "style: brew style accepts the cask"
else fail "style: $out"; fi

if ! out=$(brew install --cask cyfrproof/local/cyfr 2>&1); then
  fail "install: brew install failed: $out"
else
  found=$(env -i HOME="$HOME" PATH="$PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" bash -lc 'command -v cyfr' 2>/dev/null)
  if [ "$(version_of)" != "$2" ]; then fail "install: the app is at [$(version_of)], not $2"
  elif ! linked; then fail "install: $LINK is not a link to $APP/Contents/Resources/cyfr"
  elif [ "$found" != "$LINK" ]; then fail "install: a fresh login shell finds cyfr at [$found], not $LINK"
  elif ! "$LINK" --version >/dev/null; then fail "install: $LINK --version failed"
  else pass "install: $APP at $2, $LINK its cyfr"; fi
fi

cask "$4" "$5" || { echo "brew-tap: the cask for $4 was not written" >&2; exit 1; }
if ! out=$(brew upgrade --cask cyfrproof/local/cyfr 2>&1); then
  fail "upgrade: brew upgrade failed: $out"
else
  recorded=$(brew list --cask --versions cyfr 2>&1)
  if [ "$(version_of)" != "$4" ]; then fail "upgrade: the app is at [$(version_of)], not $4"
  elif ! linked; then fail "upgrade: $LINK is not a link to $APP/Contents/Resources/cyfr"
  elif [ "$recorded" != "cyfr $4" ]; then fail "upgrade: brew records [$recorded], not cyfr $4"
  else pass "upgrade: $APP at $4, $LINK its cyfr"; fi
fi

if ! out=$(brew uninstall --cask cyfr 2>&1); then fail "uninstall: brew uninstall failed: $out"
elif [ -e "$APP" ] || [ -e "$LINK" ] || [ -L "$LINK" ]; then fail "uninstall: $APP or $LINK is still there"
else pass "uninstall: $APP and $LINK are gone"; fi

exit "$failed"
