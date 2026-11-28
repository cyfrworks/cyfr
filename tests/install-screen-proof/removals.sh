# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# The install proof's reading of what `cyfr uninstall` prints for a person
# to run (run.sh's uninstall step; removals-test.sh holds it to made-up
# transcripts):
#
#   printed_removals TRANSCRIPT PROFILE
#       Whether the commands TRANSCRIPT prints, its only lines indented
#       four spaces, are exactly two, each once: the removal of the stack's
#       volumes, every name quoted alone, and the removal of the AppArmor
#       profile PROFILE, whose name is the product's shape (cyfr-locus- and
#       twelve hex digits), which cyfr init installed as root under
#       /etc/apparmor.d. No printed command removes a file or a folder of
#       the person's, however it is written (rm, find -delete, unlink,
#       shred), since no other printed command is allowed.

printed_removals() {
  local transcript=$1 profile=$2 printed target
  [[ "$profile" =~ ^cyfr-locus-[0-9a-f]{12}$ ]] || return 1
  target="/etc/apparmor.d/$profile"
  printed=$(grep -E '^    [^ ]' "$transcript") || return 1
  [ "$(printf '%s\n' "$printed" | wc -l)" = 2 ] &&
    [ "$(printf '%s\n' "$printed" | grep -cE "^    docker volume rm '[A-Za-z0-9_.-]+'( '[A-Za-z0-9_.-]+')*$")" = 1 ] &&
    [ "$(printf '%s\n' "$printed" | grep -cxF -- "    sudo sh -c 'apparmor_parser -R $target && rm $target'")" = 1 ]
}
