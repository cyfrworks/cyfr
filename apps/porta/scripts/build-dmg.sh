#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: build-dmg.sh <version>}"

cd "$(dirname "$0")/.."

APP_BUNDLE_DIR="target/release/bundle/macos"
APP_NAME="$(basename "$APP_BUNDLE_DIR"/*.app)"
DMG_DIR="target/release/bundle/dmg-custom"
DMG="$DMG_DIR/CYFR_${VERSION}_aarch64.dmg"

mkdir -p "$DMG_DIR"
rm -f "$DMG"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_BUNDLE_DIR/$APP_NAME" "$STAGE/"

create-dmg \
  --volname "CYFR" \
  --background "icons/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 96 \
  --icon "$APP_NAME" 180 170 \
  --app-drop-link 480 170 \
  --hdiutil-quiet \
  --no-internet-enable \
  "$DMG" \
  "$STAGE"

echo "Built: $DMG"
