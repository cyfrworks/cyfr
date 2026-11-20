#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Compile and test Locus from its declared apps alone: scripts/locus-island.sh
#
# Locus releases without the control plane: a checkout holding only the
# lock, the contracts, Locus, the fetched deps, the WIT tree (`Prima.WIT`
# embeds it; `Locus.Runtime.Engine` reads the same tree), the pinned
# wasm-tools (`_tools`), the vector files its wires', its runtime's and its
# keeper tests read (tests/fixtures) and the locus release's runtime
# configuration (config/locus_runtime.exs, which its config test evaluates)
# compiles every role with warnings as errors and runs its suite, against
# a scripted host and no database. Its vector tests fail rather than skip
# without the vector file. test.yml's locus-independence job and
# handoff's locus-alone row (scripts/stages.tsv) run this.
#
# The island is a directory the script makes under TMPDIR and removes at
# exit. Mix runs under MIX_ENV=test with its build lock off, as test.yml's
# environment sets them, and in the island's own build directory.
#
# Exit 0 passed, 1 the compile or a test failed, 64 on usage, 69 a path the
# island copies is missing (mix deps.get, scripts/fetch-prebuilt-binaries.sh
# and scripts/wasm-tools.sh install _tools make them).
set -euo pipefail

[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 64; }
cd "$(dirname "$0")/.."

for path in mix.lock apps/prima apps/locus deps wit _tools tests/fixtures config/locus_runtime.exs; do
  [ -e "$path" ] || { echo "locus-island: $path is missing" >&2; exit 69; }
done
island=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-locus-island.XXXXXX")
trap 'rm -rf "$island"' EXIT
mkdir -p "$island/apps" "$island/config" "$island/tests"
cp mix.lock "$island/"
cp -R apps/prima apps/locus "$island/apps/"
cp -R deps wit _tools "$island/"
cp -R tests/fixtures "$island/tests/"
cp config/locus_runtime.exs "$island/config/"
unset MIX_BUILD_PATH
export MIX_ENV=test MIX_OS_CONCURRENCY_LOCK=0
cd "$island/apps/locus"
mix compile --warnings-as-errors
mix test
