#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The guests' base, verified again inside the container before any guest
# boots from it, with no network:
#   verify-base.sh IMAGE SHA256
# /base is the host's cache directory for the pinned sum
# (tests/install-screen-proof/fetch-base.sh), mounted read-only. Its
# SHA256SUMS must carry a good signature of Ubuntu's cloud image keyring,
# the sum it gives IMAGE must be SHA256, and so must the SHA-256 of
# /base/IMAGE itself.
set -eu
image=$1 pinned=$2
keyring=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
cd /base
echo "keyring: $keyring"
gpgv --status-fd 1 --keyring "$keyring" SHA256SUMS.gpg SHA256SUMS
signed=$(awk -v name="$image" '$2 == name || $2 == "*" name { print $1 }' SHA256SUMS)
echo "signed sum: $signed"
echo "pinned sum: $pinned"
if [ "$signed" != "$pinned" ]; then
  echo "the signed SHA256SUMS gives $image the sum ${signed:-(none)}, not the pinned $pinned" >&2
  exit 1
fi
actual=$(sha256sum "$image" | cut -d ' ' -f 1)
echo "cached sum: $actual"
if [ "$actual" != "$pinned" ]; then
  echo "the cached $image has the sum $actual, not the pinned $pinned" >&2
  exit 1
fi
qemu-img info "/base/$image"
