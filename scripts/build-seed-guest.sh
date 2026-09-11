#!/usr/bin/env bash
# Build a seed WASM component from its tracked source and write
# src/build.stamp with the source and binary digests plus toolchain
# versions, so a source edit without a rebuild fails CI.
#
# Usage: scripts/build-seed-guest.sh <version-dir> [--check | --rebuild-check]
#   <version-dir>: a seed component version directory, e.g.
#                  seed/components/formulas/local/aqua/1.0.8 or
#                  seed/components/catalysts/local/claude/1.2.0
#   --check: verify digests against the stamp without a toolchain.
#   --rebuild-check: rebuild and compare bytes using the recorded toolchain.
#
# Requires Rust with wasm32-wasip2 and cargo-component:
#   rustup target add wasm32-wasip2
#   cargo install cargo-component
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <version-dir> [--check | --rebuild-check]" >&2; exit 2; }

dir="$(cd "$1" && pwd)"
src="$dir/src"
stamp="$src/build.stamp"

# The one artifact a version directory ships, named by its component type:
# seed/components/<type>s/<publisher>/<name>/<version>/<type>.wasm.
type_plural="$(basename "$(dirname "$(dirname "$(dirname "$dir")")")")"
artifact="${type_plural%s}.wasm"
shipped="$dir/$artifact"

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
  [ -f "$stamp" ] || { echo "no build stamp at $stamp — run $0 $1" >&2; exit 1; }
  local want_source want_wasm have_source have_wasm
  want_source="$(stamped source)"; want_wasm="$(stamped wasm)"
  have_source="$(source_digest)"; have_wasm="$(file_digest "$shipped")"
  if [ "$want_source" != "$have_source" ]; then
    echo "the guest source changed since $artifact was built — run $0 $1" >&2
    exit 1
  fi
  if [ "$want_wasm" != "$have_wasm" ]; then
    echo "$artifact is not the binary the build script wrote — run $0 $1" >&2
    exit 1
  fi
  echo "$artifact is the reviewed source's build ($(basename "$(dirname "$dir")") $(basename "$dir"))"
}

build() {
  echo "building $(basename "$(dirname "$dir")") $(basename "$dir") from $src"
  (cd "$src" && cargo component build --release --target wasm32-wasip2 --quiet)
  built="$(ls "$src"/target/wasm32-wasip2/release/*.wasm | head -1)"
}

case "${2:-}" in
  --check)
    check "$1"
    ;;
  --rebuild-check)
    build
    if cmp -s "$built" "$shipped"; then
      echo "$artifact is byte-identical to a fresh build"
    else
      echo "$artifact differs from what the source builds here — run $0 $1" >&2
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
    echo "usage: $0 <version-dir> [--check | --rebuild-check]" >&2
    exit 2
    ;;
esac
