#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# The console's JavaScript unit tests: Node's own runner, no dependency.
# Run from anywhere: apps/cyfr/assets/test/run.sh
set -euo pipefail

cd "$(dirname "$0")/.."
exec node --test test/sdk/*.test.mjs
