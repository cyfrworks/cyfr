#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build question_probe.wasm from src/lib.rs and Cargo.lock as the catalyst
# world's component, with apps/cyfr/test/support/test_wasm/build-fixture.sh
# (which says how).
#
# Usage, from anywhere in the repository:
#   build.sh            build, write question_probe.wasm, print the digests
#                       README.md records
#   build.sh --check    build and compare with the checked-in binary
#
# Requires the toolchain build-fixture.sh pins.
case "$#:${1:-}" in
  0: | 1:--check) ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac
here="$(dirname "$0")"
# The one recipe of the suites' Rust fixtures, beside CYFR's.
exec "$here/../../../../../../cyfr/test/support/test_wasm/build-fixture.sh" question_probe catalyst "$here" "$@"
