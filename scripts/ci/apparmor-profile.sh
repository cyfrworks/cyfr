#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Load the AppArmor profile every Locus container runs under on a CI
# runner, as `cyfr init` and `cyfr update` load it on a host:
#   scripts/ci/apparmor-profile.sh
#
# The profile is apps/codex/internal/apparmor/cyfr-locus under the name the
# file name beside it holds, which carries its content (cyfr's package
# apparmor) and which compose reads from CYFR_LOCUS_APPARMOR. The script
# writes the profile, its name in the placeholder's place, to
# /etc/apparmor.d/<name> and loads it, through sudo. A runner whose kernel
# enforces no AppArmor needs nothing: Docker ignores the option there, and
# the script says so and changes nothing.
#
# Exit status: 0 once the profile is loaded or where AppArmor is off,
# sudo's or apparmor_parser's otherwise.
set -euo pipefail

cd "$(dirname "$0")/../.."
if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != Y ]; then
  echo "AppArmor is off on this runner: no profile is needed here"
  exit 0
fi
name="$(cat apps/codex/internal/apparmor/name)"
sed "s/cyfr-locus-000000000000/$name/g" apps/codex/internal/apparmor/cyfr-locus |
  sudo sh -c "cat > /etc/apparmor.d/$name && apparmor_parser -r -W /etc/apparmor.d/$name"
echo "the AppArmor profile $name is loaded"
