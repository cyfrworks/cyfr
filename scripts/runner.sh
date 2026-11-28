#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Check, build or name the WASM runner's crate (apps/locus/runner):
#   scripts/runner.sh check   rustfmt's check, clippy with every warning an
#                             error, the crate's tests, and its formula
#                             tests again with each runner held to one
#                             processor (taskset), a runner's default
#   scripts/runner.sh build   the release binary and its stamp beside it,
#                             the pair; prints the binary's path
#   scripts/runner.sh stamp   prints the stamp of the checkout's sources
#   scripts/runner.sh pair    prints the binary's path when the pair is
#                             there and its stamp is the checkout's; exit
#                             1, saying why, when it is missing or stale
#
# The stamp is the one hash of everything the binary is built from: the
# SHA-256 of the list of SHA-256 sums of every file under apps/locus/runner
# but its tests (apps/locus/runner/tests), rust-toolchain.toml and wit/,
# sorted by path from the checkout's root.
# `build` writes it, as it stood when the build began, to cyfr-runner.stamp
# beside the binary, so a source changed during the build leaves the pair
# stale. stage-deps.sh builds a missing or stale pair before a test row,
# the test build's keeper (Locus.DirectLauncher.Runner) refuses one, and
# the island (scripts/locus-island.sh) copies the pair and this script.
#
# Every cargo step is --locked to the committed Cargo.lock, under the Rust
# release rust-toolchain.toml names, and builds into _build/runner (the
# crate's .cargo/config.toml) unless CARGO_TARGET_DIR names another. The crate's tests read
# the vector files under tests/fixtures. handoff's runner row
# (scripts/stages.tsv) runs check; test.yml's runner job runs check and
# its runner-build job build. tests/runner-pair-test.sh holds pair's
# refusals, run by its own handoff row and by the runner job.
#
# Exit 0 when every step passed, cargo's status at the first that failed,
# 1 for a pair missing or stale, 64 on usage, 69 without cargo, rustfmt,
# clippy or (for check) taskset, or (for stamp and pair) sha256sum.
set -uo pipefail

usage() { echo "usage: $0 check|build|stamp|pair" >&2; exit 64; }
[ "$#" -eq 1 ] || usage
root=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
release=${CARGO_TARGET_DIR:-$root/_build/runner}/release

stamp() {
  command -v sha256sum >/dev/null || { echo "runner: no sha256sum on PATH (coreutils)" >&2; return 69; }
  (cd "$root" && find apps/locus/runner rust-toolchain.toml wit -path apps/locus/runner/tests -prune -o -type f -print0 |
    LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

case "$1" in
  stamp) stamp; exit ;;
  pair)
    want=$(stamp) || exit
    [ -x "$release/cyfr-runner" ] || { echo "runner: $release/cyfr-runner is not built (scripts/runner.sh build)" >&2; exit 1; }
    [ "$(cat "$release/cyfr-runner.stamp" 2>/dev/null)" = "$want" ] ||
      { echo "runner: $release/cyfr-runner is stale: its stamp is not the checkout's (scripts/runner.sh build)" >&2; exit 1; }
    echo "$release/cyfr-runner"
    exit 0
    ;;
esac
cd "$root/apps/locus/runner" || exit 1
command -v cargo >/dev/null || { echo "runner: no cargo on PATH (CONTRIBUTING.md names the Rust toolchain)" >&2; exit 69; }

case "$1" in
  check)
    for tool in fmt clippy; do
      cargo "$tool" --version >/dev/null 2>&1 ||
        { echo "runner: cargo $tool is not installed for rust-toolchain.toml's release" >&2; exit 69; }
    done
    command -v taskset >/dev/null || { echo "runner: no taskset on PATH (util-linux)" >&2; exit 69; }
    cargo fmt --check || exit
    cargo clippy --locked --all-targets -- -D warnings || exit
    cargo test --locked || exit
    CYFR_TEST_RUNNER_CPUS=1 cargo test --locked --test formula
    ;;
  build)
    built=$(stamp) || exit
    cargo build --locked --release || exit
    printf '%s\n' "$built" > "$release/cyfr-runner.stamp" || exit
    echo "$release/cyfr-runner"
    ;;
  *) usage ;;
esac
