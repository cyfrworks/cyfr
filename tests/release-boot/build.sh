#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The `cyfr` release for one adapter, built as the release proofs build it
# (release.sh `release_build`), for a run whose first proof only reuses
# one (RELEASE_BOOT_SKIP_BUILD=1), as the approval proof does:
#
#   tests/release-boot/build.sh sqlite|postgres
#
# With RELEASE_BOOT_SKIP_BUILD=1 a release built from this tree is kept,
# and one built from another, or none at all, is refused without a build:
# the commit gate's close runs a shard of one viewport on the release the
# shard before it built.
set -euo pipefail
case "${1:-}" in
  sqlite | postgres) ADAPTER=$1 ;;
  *)
    echo "::error::usage: $0 sqlite|postgres" >&2
    exit 64
    ;;
esac
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-release-build-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=release.sh
source "$(cd "$(dirname "$0")" && pwd)/release.sh"
if [ "${RELEASE_BOOT_SKIP_BUILD:-}" = 1 ] && [ ! -x "$REL/bin/cyfr" ]; then
  fail "no $ADAPTER release to reuse at $REL (RELEASE_BOOT_SKIP_BUILD=1): build one first, as a run without RELEASE_BOOT_SKIP_BUILD=1 does"
fi
release_build
