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
set -euo pipefail
cd "$(dirname "$0")/.."

mix hex.audit
mix deps.audit
