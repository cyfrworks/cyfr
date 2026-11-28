#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# removals.sh's printed_removals over made-up uninstall transcripts: the
# product's two printed commands pass, and any other printed removal,
# however written, a command twice, one missing, or a profile of another
# shape fails. Exits 0 when every case is read as it should be.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=removals.sh
. "$HERE/removals.sh"
P=cyfr-locus-0123456789ab
VOL="    docker volume rm 'cyfr_guard-control' 'cyfr_guest' 'cyfr_homes'"
AA="    sudo sh -c 'apparmor_parser -R /etc/apparmor.d/$P && rm /etc/apparmor.d/$P'"
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
failed=0
# expect pass|fail NAME PROFILE LINE...: the transcript is uninstall's
# words around LINE..., each printed command among them.
expect() {
  local want=$1 name=$2 profile=$3 got
  shift 3
  printf '%s\n' "cyfr uninstall removes:" "  the CYFR app, the package cyfr-desktop" "CYFR is uninstalled. Left as they were:" \
    "  the stack's volumes, which this command removes:" "$@" >"$dir/transcript"
  if printed_removals "$dir/transcript" "$profile"; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then echo "ok: $name ($got)"; else echo "FAIL: $name: read $got, want $want"; failed=1; fi
}
expect pass "the product's two lines" "$P" "$VOL" "$AA"
expect fail "+ rm -rf the folder" "$P" "$VOL" "$AA" "    rm -rf /home/proof/cyfr"
expect fail "+ sudo rm of the device key in a variable" "$P" "$VOL" "$AA" '    sudo rm -r "$HOME/.cyfr/device"'
expect fail "+ find -delete of the folder" "$P" "$VOL" "$AA" "    find /home/proof/cyfr -delete"
expect fail "+ unlink the settings" "$P" "$VOL" "$AA" "    unlink /home/proof/.cyfr/config.json"
expect fail "+ shred -u the device key" "$P" "$VOL" "$AA" "    shred -u /home/proof/.cyfr/device/key"
expect fail "+ rm -rf appended to the volumes' line" "$P" "$VOL && rm -rf /home/proof/cyfr" "$AA"
expect fail "+ rm -rf appended to the profile's line" "$P" "$VOL" "$AA; rm -rf /home/proof/cyfr"
expect fail "the volumes' line twice" "$P" "$VOL" "$VOL" "$AA"
expect fail "the profile's line twice" "$P" "$VOL" "$AA" "$AA"
expect fail "no profile line" "$P" "$VOL"
expect fail "no volumes' line" "$P" "$AA"
expect fail "a profile .env names outside the product's shape" "../../home/proof" "$VOL" \
  "    sudo sh -c 'apparmor_parser -R /etc/apparmor.d/../../home/proof && rm /etc/apparmor.d/../../home/proof'"
expect fail "an empty profile" "" "$VOL" "$AA"
exit "$failed"
