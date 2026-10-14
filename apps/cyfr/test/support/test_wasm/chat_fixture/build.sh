#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build chat_fixture.wasm from src/lib.rs and Cargo.lock as the catalyst
# world's component, with ../build-fixture.sh (which says how).
#
# Usage, from anywhere in the repository:
#   build.sh            build, write chat_fixture.wasm, print the digests
#                       README.md records
#   build.sh --check    build and compare with the checked-in binary
#
# Requires the toolchain README.md names.
here="$(dirname "$0")"
exec "$here/../build-fixture.sh" chat_fixture catalyst "$here" "$@"
