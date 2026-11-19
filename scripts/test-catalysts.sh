#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Test the model catalysts: scripts/test-catalysts.sh TARGET_DIR
#
# Each model catalyst's `model/chat@1` mapping (every
# seed/components/catalysts/local/*/*/src/src/chat.rs) runs its crate's
# `cargo test` on the host target, with the toolchain cargo picks there
# (rust-toolchain.toml); the shipped binaries are not rebuilt. test.yml's
# static job and handoff's catalysts row (scripts/stages.tsv) run this.
# TARGET_DIR is the one cargo target directory every crate builds into; the
# script removes it at exit.
#
# Every crate runs even after one fails. Exit 0 every crate passed, 1
# naming each that did not or when no crate matched (a glob that matches
# nothing would test nothing), 64 on usage, 69 without cargo.
set -uo pipefail

[ "$#" -eq 1 ] && [ -n "$1" ] || { echo "usage: $0 TARGET_DIR" >&2; exit 64; }
target=$1
cd "$(dirname "$0")/.." || exit 1
trap 'rm -rf "$target"' EXIT

command -v cargo >/dev/null || { echo "test-catalysts: no cargo on PATH (CONTRIBUTING.md names the Rust toolchain)" >&2; exit 69; }
shopt -s nullglob
chats=(seed/components/catalysts/local/*/*/src/src/chat.rs)
if [ "${#chats[@]}" -eq 0 ]; then
  echo "test-catalysts: no model catalyst source matched, so nothing would be tested" >&2
  exit 1
fi
failed=()
for chat in "${chats[@]}"; do
  src=$(dirname "$(dirname "$chat")")
  (cd "$src" && cargo test --quiet --target-dir "$target") || failed+=("$src")
done
if [ "${#failed[@]}" -gt 0 ]; then
  echo "test-catalysts: failed: ${failed[*]}" >&2
  exit 1
fi
