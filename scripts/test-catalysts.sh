#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Test the model catalysts: scripts/test-catalysts.sh
#
# Each model catalyst's `model/chat@1` mapping (every
# seed/components/catalysts/local/*/*/src/src/chat.rs) runs its crate's
# `cargo test` on the host target, with the toolchain cargo picks there
# (rust-toolchain.toml); the shipped binaries are not rebuilt. test.yml's
# static job and handoff's catalysts row (scripts/stages.tsv) run this.
# Every crate builds into one cargo target directory the script makes
# under TMPDIR and removes at exit.
#
# It stops at the first crate that fails, with cargo's status, naming the
# crate. Exit 0 every crate passed, 1 when no crate matched (a glob that
# matches nothing would test nothing), 64 on usage, 69 without cargo.
set -uo pipefail

[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 64; }
cd "$(dirname "$0")/.." || exit 1
command -v cargo >/dev/null || { echo "test-catalysts: no cargo on PATH (CONTRIBUTING.md names the Rust toolchain)" >&2; exit 69; }

shopt -s nullglob
chats=(seed/components/catalysts/local/*/*/src/src/chat.rs)
if [ "${#chats[@]}" -eq 0 ]; then
  echo "test-catalysts: no model catalyst source matched, so nothing would be tested" >&2
  exit 1
fi
target=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-catalysts.XXXXXX") || exit 1
trap 'rm -rf "$target"' EXIT
for chat in "${chats[@]}"; do
  src=$(dirname "$(dirname "$chat")")
  status=0
  (cd "$src" && cargo test --quiet --target-dir "$target") || status=$?
  if [ "$status" -ne 0 ]; then
    echo "test-catalysts: $src failed" >&2
    exit "$status"
  fi
done
