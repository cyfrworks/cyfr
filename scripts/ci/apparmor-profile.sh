#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Load the AppArmor profile every Locus container runs under on a CI
# runner, as `cyfr init` and `cyfr update` load it on a host:
#   scripts/ci/apparmor-profile.sh
#
# It writes apps/codex/internal/apparmor/cyfr-locus to
# /etc/apparmor.d/cyfr-locus and loads it, through sudo. A runner whose
# kernel enforces no AppArmor needs nothing: Docker ignores the option
# there, and the script says so and changes nothing.
#
# Exit status: 0 once the profile is loaded or where AppArmor is off,
# sudo's or apparmor_parser's otherwise.
set -euo pipefail

cd "$(dirname "$0")/../.."
if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != Y ]; then
  echo "AppArmor is off on this runner: the profile cyfr-locus is not needed here"
  exit 0
fi
sudo install -m 0644 apps/codex/internal/apparmor/cyfr-locus /etc/apparmor.d/cyfr-locus
sudo apparmor_parser -r -W /etc/apparmor.d/cyfr-locus
echo "the AppArmor profile cyfr-locus is loaded"
