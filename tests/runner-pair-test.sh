#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/runner.sh pair, the real script over this checkout's sources,
# against pairs in a scratch target folder (CARGO_TARGET_DIR, which the
# script honours), never the checkout's own pair: a binary that is not
# there is refused as not built, one whose stamp is not the checkout's is
# refused as stale, and only one whose stamp is the checkout's is named.
# It needs sha256sum and no build: the binary is a stand-in, since the
# guard reads its mode and its stamp alone.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
S=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-runner-pair-test.XXXXXX") || exit 1
S=$(cd "$S" && pwd -P)
trap 'rm -rf "$S"' EXIT

release="$S/release"
mkdir -p "$release"

case_name=
fail() { echo "FAIL: $case_name: $*" >&2; exit 1; }
begin() { case_name=$1; echo "case $case_name"; }

# The script's answer for the scratch pair: its status, what it printed
# and what it said.
pair() {
  status=0
  out=$(CARGO_TARGET_DIR="$S" "$root/scripts/runner.sh" pair 2>"$S/said") || status=$?
  said=$(cat "$S/said")
}

want=$("$root/scripts/runner.sh" stamp) || { echo "FAIL: the checkout's stamp: $?" >&2; exit 1; }
[ "${#want}" = 64 ] || { echo "FAIL: the checkout's stamp is not a SHA-256: $want" >&2; exit 1; }

begin "a binary that is not there is not built"
pair
[ "$status" = 1 ] && [ -z "$out" ] || fail "status $status, printed '$out'"
[ "$said" = "runner: $release/cyfr-runner is not built (scripts/runner.sh build)" ] || fail "said: $said"

printf '#!/bin/sh\nexit 0\n' >"$release/cyfr-runner"
chmod 0755 "$release/cyfr-runner"

begin "a binary without its stamp is stale"
pair
[ "$status" = 1 ] && [ -z "$out" ] || fail "status $status, printed '$out'"
[ "$said" = "runner: $release/cyfr-runner is stale: its stamp is not the checkout's (scripts/runner.sh build)" ] ||
  fail "said: $said"

begin "a stamp one digit off the checkout's is stale"
printf '%s\n' "${want%?}$( [ "${want: -1}" = 0 ] && echo 1 || echo 0)" >"$release/cyfr-runner.stamp"
pair
[ "$status" = 1 ] && [ -z "$out" ] || fail "status $status, printed '$out'"
grep -qF "is stale: its stamp is not the checkout's" <<<"$said" || fail "said: $said"

begin "the checkout's stamp names the pair"
printf '%s\n' "$want" >"$release/cyfr-runner.stamp"
pair
[ "$status" = 0 ] && [ "$out" = "$release/cyfr-runner" ] && [ -z "$said" ] ||
  fail "status $status, printed '$out', said '$said'"

begin "a binary that is not executable is not built"
chmod 0644 "$release/cyfr-runner"
pair
[ "$status" = 1 ] && [ -z "$out" ] || fail "status $status, printed '$out'"
grep -qF "is not built" <<<"$said" || fail "said: $said"

echo "runner-pair-test: every case passed"
