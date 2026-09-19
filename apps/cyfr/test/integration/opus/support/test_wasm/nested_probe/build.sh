#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build nested_probe.wasm from src/lib.rs and Cargo.lock: the crate is laid
# out in a scratch directory with the canonical formula Cargo.toml
# (`Cyfr.CargoToml`) and the formula world's WIT (`wit/formula`), built
# `--locked`, and the scratch directory and the Cargo home are remapped out
# of the paths rustc embeds, so the bytes carry nothing of where they were
# built.
#
# Usage, from anywhere in the repository:
#   build.sh            build, write nested_probe.wasm, print the digests
#                       README.md records
#   build.sh --check    build and compare with the checked-in binary
#
# Requires the toolchain README.md names.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../../../../../../../.." && pwd -P)"
work="$(cd "$(mktemp -d)" && pwd -P)"
cargo_home="$(cd "${CARGO_HOME:-$HOME/.cargo}" && pwd -P)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/src"
cp "$here/src/lib.rs" "$work/src/lib.rs"
cp "$here/Cargo.lock" "$work/Cargo.lock"
cp -R "$root/wit/formula" "$work/wit"

(cd "$root" && CARGO_TOML="$work/Cargo.toml" MIX_ENV=test mix run --no-start -e \
  'File.write!(System.fetch_env!("CARGO_TOML"), Cyfr.CargoToml.template(:formula))' >&2)

(cd "$work" && RUSTFLAGS="--remap-path-prefix=$work=/nested-probe --remap-path-prefix=$cargo_home=/cargo" \
  cargo component build --release --target wasm32-wasip2 --locked >&2)

built="$work/target/wasm32-wasip2/release/cyfr_component.wasm"
digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

case "${1:-}" in
  --check)
    if cmp -s "$built" "$here/nested_probe.wasm"; then
      echo "nested_probe.wasm is byte-identical to a fresh build ($(digest "$built"))"
    else
      echo "nested_probe.wasm ($(digest "$here/nested_probe.wasm")) differs from a fresh build ($(digest "$built"))" >&2
      exit 1
    fi
    ;;
  "")
    cp "$built" "$here/nested_probe.wasm"
    echo "src/lib.rs        sha256:$(digest "$here/src/lib.rs")"
    echo "Cargo.lock        sha256:$(digest "$here/Cargo.lock")"
    echo "nested_probe.wasm sha256:$(digest "$here/nested_probe.wasm")"
    ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac
