#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# The console's JavaScript unit tests, one directory per concern under
# test/: Node's own runner, no dependency.
# Run from anywhere: apps/cyfr/assets/test/run.sh
#
# CYFR_COVERAGE=1 runs them under c8 (after `npm ci` here) and prints a
# summary of js/'s coverage. The figure is reported, never a floor: the run
# fails only when a test does. c8's reports go to a directory of the run's
# own, removed when it ends.
#
# CYFR_TEST_CORES, which scripts/heavy-check.sh sets to a scoped slot's
# share of the cores, bounds how many test files Node runs at once
# (--test-concurrency); unset, Node's own default stands.
set -euo pipefail

cd "$(dirname "$0")/.."
concurrency=()
if [ -n "${CYFR_TEST_CORES:-}" ]; then
  case "$CYFR_TEST_CORES" in *[!0-9]*|0*) echo 'CYFR_TEST_CORES must be a positive decimal integer' >&2; exit 64 ;; esac
  concurrency=(--test-concurrency="$CYFR_TEST_CORES")
fi
if [ "${CYFR_COVERAGE:-}" != 1 ]; then
  exec node --test ${concurrency[@]+"${concurrency[@]}"} test/*/*.test.mjs
fi

reports=$(mktemp -d)
trap 'rm -rf "$reports"' EXIT
node_modules/.bin/c8 --all --src=js --include='js/**' --reporter=text-summary \
  --reports-dir="$reports" --temp-directory="$reports/tmp" \
  node --test ${concurrency[@]+"${concurrency[@]}"} test/*/*.test.mjs
