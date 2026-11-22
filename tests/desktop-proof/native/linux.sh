#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The CYFR app's Linux package, installed as a person installs it and then
# smoked (smoke.sh). Codex CI runs it on the package a change builds and
# Release on the package a tag publishes, each on a runner of the package's
# architecture. The DEB installs at /opt/cyfr and loads its sandbox's
# AppArmor profile; Xvfb and a session bus give the app a display and a
# bus. It installs with sudo and leaves the package installed, so it runs
# on a disposable machine alone.
#
# Usage: bash tests/desktop-proof/native/linux.sh DEB
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: bash $0 DEB" >&2; exit 64; }
DEB=$(realpath -e "$1")
sudo apt-get update
sudo apt-get install -y --no-install-recommends "$DEB" xvfb xauth dbus-x11
dbus-run-session -- xvfb-run -a bash "$(dirname "$0")/smoke.sh" /opt/cyfr/CYFR
