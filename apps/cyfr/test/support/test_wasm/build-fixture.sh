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
# Requires the toolchain below, the one pin of it, and refuses a missing
# or other one by name. Exit 0 built or identical; 1 the
# binary differs; 2 usage; 69 the toolchain is missing or not the pinned
# one.
set -euo pipefail

rustc_version=1.93.0
cargo_component_version=0.21.1
target=wasm32-wasip2

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

refuse() { echo "build-fixture.sh needs $1" >&2; exit 69; }
command -v mix >/dev/null || refuse "mix, which writes the canonical Cargo.toml"
case "$(rustc --version 2>/dev/null)" in
  "rustc $rustc_version "*) ;;
  *) refuse "rustc $rustc_version" ;;
esac
case "$(cargo component --version 2>/dev/null)" in
  "cargo-component"*" $cargo_component_version" | "cargo-component"*" $cargo_component_version "*) ;;
  *) refuse "cargo-component $cargo_component_version" ;;
esac
[ -d "$(rustc --print sysroot)/lib/rustlib/$target" ] || refuse "rustc's $target target"

cargo_home="$(cd "${CARGO_HOME:-$HOME/.cargo}" 2>/dev/null && pwd -P)" ||
  refuse "a Cargo home at ${CARGO_HOME:-$HOME/.cargo}"

out="$(cd "$3" && pwd -P)"
root="$(cd "$(dirname "$0")/../../../../.." && pwd -P)"
# The trap is in place before the scratch directory exists, so no exit
# after mktemp leaves it behind.
work=""
trap '[ -z "$work" ] || rm -rf "$work"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
work="$(mktemp -d)"
work="$(cd "$work" && pwd -P)"

mkdir -p "$work/src"
cp "$out/src/lib.rs" "$work/src/lib.rs"
cp "$out/Cargo.lock" "$work/Cargo.lock"
cp -R "$root/wit/$kind" "$work/wit"

(cd "$root" && CARGO_TOML="$work/Cargo.toml" MIX_ENV=test mix run --no-start -e \
  "File.write!(System.fetch_env!(\"CARGO_TOML\"), Prima.CargoToml.template(:$kind))" >&2)

(cd "$work" && RUSTFLAGS="--remap-path-prefix=$work=/${name//_/-} --remap-path-prefix=$cargo_home=/cargo" \
  cargo component build --release --target "$target" --locked >&2)

built="$work/target/$target/release/cyfr_component.wasm"
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
