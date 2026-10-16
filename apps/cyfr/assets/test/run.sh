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
set -euo pipefail

cd "$(dirname "$0")/.."
if [ "${CYFR_COVERAGE:-}" != 1 ]; then
  exec node --test test/*/*.test.mjs
fi

reports=$(mktemp -d)
trap 'rm -rf "$reports"' EXIT
node_modules/.bin/c8 --all --src=js --include='js/**' --reporter=text-summary \
  --reports-dir="$reports" --temp-directory="$reports/tmp" \
  node --test test/*/*.test.mjs
