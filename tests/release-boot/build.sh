#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The `cyfr` release for one adapter, built as the release proofs build it
# (release.sh `release_build`), for a run whose first proof only reuses
# one (RELEASE_BOOT_SKIP_BUILD=1), as the approval proof does:
#
#   tests/release-boot/build.sh sqlite|postgres
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
release_build
