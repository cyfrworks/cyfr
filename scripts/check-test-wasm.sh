#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Check that every test WASM fixture is its source's build:
#   scripts/check-test-wasm.sh [--wat-only]
#
# Each fixture is built afresh in a scratch directory and compared byte
# for byte with the checked-in binary: the hostile guests through their
# build.sh --check, Locus's math, echo and spin here, the Rust fixtures
# through their build.sh --check, and CYFR's math.wasm against Locus's, of
# which it is a byte copy. Every checked-in .wasm outside seed/ is one of
# these, or the check fails naming it. --wat-only skips building the Rust
# fixtures, for a host without cargo and cargo-component.
#
# Exit 0 when every fixture checked is its source's build; 1 naming each
# that is not; 2 on a usage error.
set -uo pipefail

usage() { echo "usage: $0 [--wat-only]" >&2; exit 2; }

wat_only=false
case "$#:${1:-}" in
  0:) ;;
  1:--wat-only) wat_only=true ;;
  *) usage ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root" || exit 1
work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT

failed=()

locus=apps/locus/test/support/runtime/test_wasm
cyfr=apps/cyfr/test/support/test_wasm
hostile=$locus/hostile
rust="$cyfr/chat_fixture $cyfr/step_stub apps/cyfr/test/integration/runtime/support/test_wasm/nested_probe"

# Every checked-in binary one of the checks below builds or compares;
# hostile/build.sh refuses a binary in its directory that is no guest's.
checked="$cyfr/math.wasm $locus/math.wasm $locus/echo.wasm $locus/spin.wasm"
for wasm in "$hostile"/*.wasm; do checked="$checked $wasm"; done
for dir in $rust; do checked="$checked $dir/$(basename "$dir").wasm"; done
# Checked-in binaries no check builds, each with its reason. hog.wasm
# records the wit-component version that made it, 0.244.0, which the
# pinned wasm-tools cannot reproduce, and memory.py pins its digest.
unbuilt="tests/locus-runtime-image/hog.wasm"

if ! tracked="$(git ls-files -- '*.wasm' ':!:seed/**')"; then
  echo "the checked-in binaries could not be listed (git ls-files)" >&2
  exit 1
fi
for wasm in $tracked; do
  case " $checked $unbuilt " in
    *" $wasm "*) ;;
    *)
      echo "$wasm is a test WASM fixture no check builds" >&2
      failed+=("$wasm")
      ;;
  esac
done

if ! scripts/wasm-tools.sh install _tools; then
  echo "the pinned wasm-tools could not be installed" >&2
  exit 1
fi
wasm_tools="$root/_tools/wasm-tools"

# A core module from its .wat, stripped of its custom sections, as
# hostile/build.sh builds its guests' cores.
core() {
  "$wasm_tools" parse "$1" -o "$work/$2.parsed.wasm" &&
    "$wasm_tools" strip --all "$work/$2.parsed.wasm" -o "$work/$2.wasm"
}

# Compare a fresh build with the checked-in binary, naming a difference.
compare() {
  if cmp -s "$1" "$2"; then
    echo "$2 is byte-identical to a fresh build"
  else
    echo "$2 differs from a fresh build" >&2
    failed+=("$2")
  fi
}

if ! "$hostile/build.sh" --check; then
  failed+=("$hostile")
fi

if core "$locus/math.wat" math; then
  compare "$work/math.wasm" "$locus/math.wasm"
else
  failed+=("$locus/math.wasm")
fi

for name in echo spin; do
  if core "$locus/$name.wat" "$name.core" &&
    "$wasm_tools" component embed wit/reagent --world reagent "$work/$name.core.wasm" \
      -o "$work/$name.embedded.wasm" &&
    "$wasm_tools" component new "$work/$name.embedded.wasm" -o "$work/$name.wasm"; then
    compare "$work/$name.wasm" "$locus/$name.wasm"
  else
    failed+=("$locus/$name.wasm")
  fi
done

if cmp -s "$cyfr/math.wasm" "$locus/math.wasm"; then
  echo "$cyfr/math.wasm is a byte copy of $locus/math.wasm"
else
  echo "$cyfr/math.wasm is not a byte copy of $locus/math.wasm" >&2
  failed+=("$cyfr/math.wasm")
fi

if [ "$wat_only" = true ]; then
  echo "the Rust fixtures are not built (--wat-only): $rust"
else
  for dir in $rust; do
    if ! "$dir/build.sh" --check; then
      failed+=("$dir")
    fi
  done
fi

if [ "${#failed[@]}" -gt 0 ]; then
  echo "check-test-wasm: not their sources' builds: ${failed[*]}" >&2
  exit 1
fi
echo "check-test-wasm: every fixture checked is its source's build"
