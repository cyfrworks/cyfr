#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The CYFR app's Mac package, installed as a person installs it, CYFR.app
# dragged from the DMG into /Applications, and then smoked (smoke.sh).
# Codex CI runs it on the package a change builds and the Mac
# distribution (desktop-mac.yml) on the signed package a release
# publishes, each on a runner of the package's architecture. It leaves the
# app installed, so it runs on a disposable machine alone.
#
# Usage: bash tests/desktop-proof/native/mac.sh DMG
set -euo pipefail

[ "$#" -eq 1 ] && [ -f "$1" ] || { echo "usage: bash $0 DMG" >&2; exit 64; }
mount=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cyfr-dmg.XXXXXX")
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$1"
cp -R "$mount/CYFR.app" /Applications/
hdiutil detach "$mount"
bash "$(dirname "$0")/smoke.sh" /Applications/CYFR.app/Contents/MacOS/CYFR
