#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The dependency audits: scripts/dependency-audit.sh
#
# `mix hex.audit` (retired and advised packages, from Hex's feed) and
# `mix deps.audit` (vulnerable packages, from mix_audit's database), each
# passing only when it exits 0. Both compare mix.lock with feeds that
# change independently of the tree, so a tree that passed can fail later
# with no change of its own: security.yml's elixir-audit job runs this on
# every change, blocking unless scripts/ci/world-checks.sh says otherwise,
# the commit gate replays that job, and scripts/release.sh runs it again
# right before it tags.
#
# Suppressed: the advisories with no fixed release, all in packages that
# are test-only here. cowlib 2.21.0 and cowboy 2.20.0 are the newest and
# still carry CVE-2026-43966 and CVE-2026-113431 (cowlib) and
# CVE-2026-115701 (cowboy). They arrive through `bypass` (`only: :test`)
# and the server speaks HTTP through Bandit, so no cowboy code ships. That
# holds only while the production tree, the one the images fetch
# (`mix deps.get --only prod` under MIX_ENV=prod), carries none of cowboy,
# cowlib or ranch, so the script reads that tree first and fails naming
# each one it finds; a tree it cannot read, or reads as empty, fails too.
# Remove the suppressions when cowlib and cowboy publish fixes, or when
# `bypass` no longer pulls them.
set -euo pipefail
cd "$(dirname "$0")/.."

prod_deps=$(MIX_ENV=prod mix deps.tree --only prod --format plain |
  sed -n -E 's/^[|` ]*[|`]-- ([a-z0-9_]+) .*/\1/p' | sort -u)
[ -n "$prod_deps" ] || { echo "the production dependency tree read as empty" >&2; exit 1; }
shipped=0
for name in cowboy cowlib ranch; do
  if grep -qx "$name" <<<"$prod_deps"; then
    echo "$name is in the production dependency tree, so its suppressed advisories would ship" >&2
    shipped=1
  fi
done
[ "$shipped" -eq 0 ] || exit 1

HEX_IGNORE_ADVISORIES="CVE-2026-43966,CVE-2026-113431,CVE-2026-115701" mix hex.audit
mix deps.audit
