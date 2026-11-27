#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Check or build the WASM runner's crate (apps/locus/runner):
#   scripts/runner.sh check   rustfmt's check, clippy with every warning an
#                             error, and the crate's tests
#   scripts/runner.sh build   the release binary; prints its path
#
# Every cargo step is --locked to the committed Cargo.lock, under the Rust
# release rust-toolchain.toml names, and builds into the crate's target
# directory unless CARGO_TARGET_DIR names another. The crate's tests read
# the vector files under tests/fixtures. handoff's runner row
# (scripts/stages.tsv) runs check; test.yml's runner job runs check and
# build.
#
# Exit 0 when every step passed, cargo's status at the first that failed,
# 64 on usage, 69 without cargo, rustfmt or clippy.
set -uo pipefail

usage() { echo "usage: $0 check|build" >&2; exit 64; }
[ "$#" -eq 1 ] || usage
cd "$(dirname "$0")/../apps/locus/runner" || exit 1
command -v cargo >/dev/null || { echo "runner: no cargo on PATH (CONTRIBUTING.md names the Rust toolchain)" >&2; exit 69; }

case "$1" in
  check)
    for tool in fmt clippy; do
      cargo "$tool" --version >/dev/null 2>&1 ||
        { echo "runner: cargo $tool is not installed for rust-toolchain.toml's release" >&2; exit 69; }
    done
    cargo fmt --check || exit
    cargo clippy --locked --all-targets -- -D warnings || exit
    cargo test --locked
    ;;
  build)
    cargo build --locked --release || exit
    echo "${CARGO_TARGET_DIR:-$PWD/target}/release/cyfr-runner"
    ;;
  *) usage ;;
esac
