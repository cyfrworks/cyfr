#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build nested_probe.wasm from src/lib.rs and Cargo.lock as the formula
# world's component, with apps/cyfr/test/support/test_wasm/build-fixture.sh
# (which says how).
#
# Usage, from anywhere in the repository:
#   build.sh            build, write nested_probe.wasm, print the digests
#                       README.md records
#   build.sh --check    build and compare with the checked-in binary
#
# Requires the toolchain README.md names.
here="$(dirname "$0")"
exec "$here/../../../../../support/test_wasm/build-fixture.sh" nested_probe formula "$here" "$@"
