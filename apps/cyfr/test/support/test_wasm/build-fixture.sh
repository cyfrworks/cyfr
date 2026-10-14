#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Build a Rust test fixture, NAME.wasm in OUT_DIR, from OUT_DIR's
# src/lib.rs and Cargo.lock: the crate is laid out in a scratch directory
# with the canonical WIT_KIND Cargo.toml (`Prima.CargoToml`) and that
# world's WIT (`wit/WIT_KIND`), built `--locked`, and the scratch directory
# and the Cargo home are remapped out of the paths rustc embeds, so the
# bytes carry nothing of where they were built.
#
# Usage, from anywhere in the repository; each fixture's build.sh calls it
# with its own NAME, WIT_KIND and directory:
#   build-fixture.sh NAME WIT_KIND OUT_DIR            build, write NAME.wasm,
#                                                     print the digests the
#                                                     fixture's README.md
#                                                     records
#   build-fixture.sh NAME WIT_KIND OUT_DIR --check    build and compare with
#                                                     the checked-in binary
#
# Requires the toolchain the fixture's README.md names.
set -euo pipefail

usage() { echo "usage: $0 NAME WIT_KIND OUT_DIR [--check]" >&2; exit 2; }

[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage
name=$1
kind=$2
# The kind is spliced into the Elixir below and the name into a path, so
# each is a bare word.
[[ "$name" =~ ^[a-z_]+$ && "$kind" =~ ^[a-z]+$ ]] || usage
case "${4:-}" in
  --check | "") ;;
  *) usage ;;
esac

out="$(cd "$3" && pwd -P)"
root="$(cd "$(dirname "$0")/../../../../.." && pwd -P)"
work="$(cd "$(mktemp -d)" && pwd -P)"
cargo_home="$(cd "${CARGO_HOME:-$HOME/.cargo}" && pwd -P)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/src"
cp "$out/src/lib.rs" "$work/src/lib.rs"
cp "$out/Cargo.lock" "$work/Cargo.lock"
cp -R "$root/wit/$kind" "$work/wit"

(cd "$root" && CARGO_TOML="$work/Cargo.toml" MIX_ENV=test mix run --no-start -e \
  "File.write!(System.fetch_env!(\"CARGO_TOML\"), Prima.CargoToml.template(:$kind))" >&2)

(cd "$work" && RUSTFLAGS="--remap-path-prefix=$work=/${name//_/-} --remap-path-prefix=$cargo_home=/cargo" \
  cargo component build --release --target wasm32-wasip2 --locked >&2)

built="$work/target/wasm32-wasip2/release/cyfr_component.wasm"
digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ "${4:-}" = --check ]; then
  if cmp -s "$built" "$out/$name.wasm"; then
    echo "$name.wasm is byte-identical to a fresh build ($(digest "$built"))"
  else
    echo "$name.wasm ($(digest "$out/$name.wasm")) differs from a fresh build ($(digest "$built"))" >&2
    exit 1
  fi
  exit 0
fi

cp "$built" "$out/$name.wasm"
width=$((${#name} + 5))
printf '%-*s sha256:%s\n' "$width" src/lib.rs "$(digest "$out/src/lib.rs")"
printf '%-*s sha256:%s\n' "$width" Cargo.lock "$(digest "$out/Cargo.lock")"
printf '%-*s sha256:%s\n' "$width" "$name.wasm" "$(digest "$out/$name.wasm")"
