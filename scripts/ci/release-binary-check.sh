#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Refuses a cyfr command line binary the release would publish that was
# built with a build tag, holds the release proof
# (apps/codex/cmd/release_proof.go, which reads releases from a local
# folder, unsigned) or holds the tests' cheap key derivation
# (apps/codex/internal/holder/cheap.go):
#
#   scripts/ci/release-binary-check.sh BINARY
#
# It reads the file and never runs it, so it checks a binary of any
# target: the build settings Go recorded in it (`go version -m`), where a
# `-tags` setting refuses, and its bytes, where either marker refuses
# (release_proof.go's releaseProofMarker and cheap.go's
# cheapDerivationMarker, each a string no other source holds, read from
# its file at each run). The linker keeps cheap.go's only in a binary
# where something calls that function. .goreleaser.yml runs it as each
# build's post hook, so a refused binary fails the release before any
# archive is made or anything is published. tests/ci-guards-test.sh holds
# it to real builds of the command line.
#
# Exit status: 0 the binary passes; 1 it is refused, or Go cannot read
# its build settings; 64 usage; 69 go is missing or either file names no
# marker.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 BINARY" >&2
  exit 64
fi
command -v go >/dev/null || { echo "$0: go is required to read the build settings" >&2; exit 69; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
marker="$(sed -n 's/^const releaseProofMarker = "\(.*\)"$/\1/p' "$root/apps/codex/cmd/release_proof.go")"
[ -n "$marker" ] || { echo "$0: apps/codex/cmd/release_proof.go names no releaseProofMarker" >&2; exit 69; }
cheap="$(sed -n 's/^const cheapDerivationMarker = "\(.*\)"$/\1/p' "$root/apps/codex/internal/holder/cheap.go")"
[ -n "$cheap" ] || { echo "$0: apps/codex/internal/holder/cheap.go names no cheapDerivationMarker" >&2; exit 69; }

info="$(go version -m "$1" 2>&1)" || { echo "$0: Go cannot read the build settings of $1: $info" >&2; exit 1; }
if tags="$(printf '%s\n' "$info" | grep -E '^[[:space:]]+build[[:space:]]+-tags=')"; then
  echo "$0: $1 was built with build tags: $(printf '%s' "$tags" | tr -s '[:space:]' ' ')" >&2
  exit 1
fi
if grep -qaF -- "$marker" "$1"; then
  echo "$0: $1 holds the release proof ($marker)" >&2
  exit 1
fi
if grep -qaF -- "$cheap" "$1"; then
  echo "$0: $1 holds the tests' cheap key derivation ($cheap)" >&2
  exit 1
fi
echo "release binary ok: $1 has no build tag, no release proof and no cheap key derivation"
