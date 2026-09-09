#!/usr/bin/env bash
# Rebuild the shipped AQUA formula guest and write build.stamp with
# source and binary digests plus toolchain versions.
#
# Usage: scripts/build-aqua-guest.sh [--check | --rebuild-check]
#   --check: verify digests against the stamp without a toolchain.
#   --rebuild-check: rebuild and compare bytes using the recorded toolchain.
#
# Requires Rust with wasm32-wasip2 and cargo-component:
#   rustup target add wasm32-wasip2
#   cargo install cargo-component
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
formula_dir="$(ls -d "$root"/seed/components/formulas/local/aqua/*/ | sort -V | tail -1)"
formula_dir="${formula_dir%/}"
src="$formula_dir/src"
shipped="$formula_dir/formula.wasm"
stamp="$src/build.stamp"

# The source tree the guest is built from: the crate's sources, its WIT,
# and the manifests that pin its dependencies — by relative path, so the
# digest is the tree's, not the machine's.
source_digest() {
  (
    cd "$src"
    find src wit Cargo.toml Cargo.lock -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s  ' "$(shasum -a 256 "$f" | cut -d' ' -f1)"
      printf '%s\n' "$f"
    done | shasum -a 256 | cut -d' ' -f1
  )
}

file_digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

stamped() { grep "^$1 " "$stamp" | cut -d' ' -f2-; }

check() {
  [ -f "$stamp" ] || { echo "no build stamp at $stamp — run scripts/build-aqua-guest.sh" >&2; exit 1; }
  local want_source want_wasm have_source have_wasm
  want_source="$(stamped source)"; want_wasm="$(stamped wasm)"
  have_source="$(source_digest)"; have_wasm="$(file_digest "$shipped")"
  if [ "$want_source" != "$have_source" ]; then
    echo "the guest source changed since formula.wasm was built — run scripts/build-aqua-guest.sh" >&2
    exit 1
  fi
  if [ "$want_wasm" != "$have_wasm" ]; then
    echo "formula.wasm is not the binary the build script wrote — run scripts/build-aqua-guest.sh" >&2
    exit 1
  fi
  echo "formula.wasm is the reviewed source's build ($(basename "$formula_dir"))"
}

build() {
  echo "building $(basename "$formula_dir") from $src"
  (cd "$src" && cargo component build --release --target wasm32-wasip2 --quiet)
  built="$(ls "$src"/target/wasm32-wasip2/release/*.wasm | head -1)"
}

case "${1:-}" in
  --check)
    check
    ;;
  --rebuild-check)
    build
    if cmp -s "$built" "$shipped"; then
      echo "formula.wasm is byte-identical to a fresh build"
    else
      echo "formula.wasm differs from what the source builds here — run scripts/build-aqua-guest.sh" >&2
      (cd "$src" && cargo clean --quiet)
      exit 1
    fi
    (cd "$src" && cargo clean --quiet)
    ;;
  "")
    build
    cp "$built" "$shipped"
    {
      echo "source $(source_digest)"
      echo "wasm $(file_digest "$shipped")"
      echo "rustc $(rustc --version | cut -d' ' -f2-)"
      echo "cargo-component $(cargo component --version | awk '{print $NF}')"
    } > "$stamp"
    echo "wrote $shipped ($(stat -f '%z' "$shipped" 2>/dev/null || stat -c '%s' "$shipped") bytes)"
    echo "stamped $stamp"
    (cd "$src" && cargo clean --quiet)
    ;;
  *)
    echo "usage: $0 [--check | --rebuild-check]" >&2
    exit 2
    ;;
esac
