#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Compile and test Locus from its declared apps alone: scripts/locus-island.sh
#
# Locus releases without the control plane: a checkout holding only the
# lock, the contracts, Locus, the fetched deps, the WIT tree (`Prima.WIT`
# embeds it), the vector files its wires', its runtime's and its keeper
# tests read (tests/fixtures), the locus release's runtime configuration
# (config/locus_runtime.exs, which its config test evaluates) and the
# runner program built from the checkout, its pair (the binary and its
# stamp, with scripts/runner.sh, which names it, and rust-toolchain.toml,
# which the stamp covers beside the crate and the WIT tree) compiles every
# role with warnings as errors and runs its suite, against a scripted host
# and no database, its runners the pair's binary. Its vector tests fail
# rather than skip without the vector file. test.yml's locus-independence
# job and handoff's locus-alone row (scripts/stages.tsv) run this.
#
# The island is a directory the script makes under TMPDIR and removes at
# exit. Mix runs under MIX_ENV=test with its build lock off, as test.yml's
# environment sets them, and in the island's own build directory.
#
# Exit 0 passed, 1 the compile or a test failed, 64 on usage, 69 a path the
# island copies is missing (mix deps.get and scripts/fetch-prebuilt-binaries.sh
# make them) or the runner's pair is missing or stale (scripts/runner.sh
# build makes it).
set -euo pipefail

[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 64; }
cd "$(dirname "$0")/.."

for path in mix.lock apps/prima apps/locus deps wit tests/fixtures config/locus_runtime.exs rust-toolchain.toml; do
  [ -e "$path" ] || { echo "locus-island: $path is missing" >&2; exit 69; }
done
runner=$(scripts/runner.sh pair) || { echo "locus-island: the runner's pair is not the checkout's" >&2; exit 69; }
island=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-locus-island.XXXXXX")
trap 'rm -rf "$island"' EXIT
mkdir -p "$island/apps" "$island/config" "$island/tests" "$island/scripts" "$island/_build/runner/release"
cp mix.lock rust-toolchain.toml "$island/"
cp -R apps/prima apps/locus "$island/apps/"
cp -R deps wit "$island/"
cp -R tests/fixtures "$island/tests/"
cp config/locus_runtime.exs "$island/config/"
cp scripts/runner.sh "$island/scripts/"
cp -p "$runner" "$runner.stamp" "$island/_build/runner/release/"
# The pair is the island's own, wherever this checkout keeps its build.
unset CARGO_TARGET_DIR
unset MIX_BUILD_PATH
export MIX_ENV=test MIX_OS_CONCURRENCY_LOCK=0
cd "$island/apps/locus"
mix compile --warnings-as-errors
mix test
