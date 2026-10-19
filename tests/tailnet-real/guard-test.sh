#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The verified-image guard (tests/tailnet-real/guard.sh) against scratch
# copies of docker-compose.yml and verified-image: the checkout's own pair
# passes, and a new digest under the same tag, another tag, a reference
# without a digest, a verified-image of two lines or with a stray byte, and
# a missing verified-image each fail, naming why.
#
# Usage: bash tests/tailnet-real/guard-test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/tests/tailnet-real/guard.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-guard-test.XXXXXX")" || {
  echo "FAIL: cannot create a temporary directory"
  exit 1
}
trap 'rm -rf "$scratch"' EXIT

failures=0
cases=0
image="$(cat "$root/tests/tailnet-real/verified-image")"
digest="${image##*@sha256:}"
other_digest="$(printf '%s' "$digest" | tr '0-9a-f' '1-9a-f0')"

# Runs the guard on the checkout's compose file with its tailscale image
# line replaced by `$1` and verified-image holding the bytes `$2`; `$3` is
# pass or fail, `$4` a text the failure must name, `$5` the case's name.
case_of() {
  local line="$1" recorded="$2" expect="$3" names="$4" what="$5" code
  cases=$((cases + 1))
  awk -v line="$line" '
    /^  tailscale:[[:space:]]*$/ { in_service = 1 }
    in_service && /^    image:/ && !done { print "    image: " line; done = 1; next }
    { print }
  ' "$root/docker-compose.yml" >"$scratch/compose.yml"
  printf '%b' "$recorded" >"$scratch/verified-image"
  bash "$guard" "$scratch/compose.yml" "$scratch/verified-image" >"$scratch/out" 2>&1
  code=$?
  if { [ "$expect" = pass ] && [ "$code" -eq 0 ]; } ||
    { [ "$expect" = fail ] && [ "$code" -eq 1 ] && grep -qF -- "$names" "$scratch/out"; }; then
    echo "PASS: $what"
  else
    echo "FAIL: $what (exit $code)"
    sed 's/^/  /' "$scratch/out"
    failures=$((failures + 1))
  fi
}

case_of "$image" "$image\n" pass "" "the checkout's compose file and verified-image agree"
case_of "${image%@sha256:*}@sha256:$other_digest" "$image\n" fail "but the reference a real tailnet last verified" \
  "a new digest under the same tag fails"
case_of "tailscale/tailscale:v9.9.9@sha256:$digest" "$image\n" fail "but the reference a real tailnet last verified" \
  "another tag fails"
case_of "${image%@sha256:*}" "${image%@sha256:*}\n" fail "is not a reference by tag and digest" \
  "a reference without a digest fails, even recorded as verified"
case_of "$image" "$image\n$image\n" fail "is not one line" "a verified-image of two lines fails"
case_of "$image" "$image \n" fail "but the reference a real tailnet last verified" "a stray byte in verified-image fails"
case_of "$image" "$image\r\n" fail "but the reference a real tailnet last verified" "a CRLF line end in verified-image fails"
case_of "$image" "$image" fail "is not one line" "a verified-image without its line end fails"

cases=$((cases + 1))
rm -f "$scratch/verified-image"
cp "$root/docker-compose.yml" "$scratch/compose.yml"
if bash "$guard" "$scratch/compose.yml" "$scratch/verified-image" >"$scratch/out" 2>&1; then
  echo "FAIL: a missing verified-image passed"
  failures=$((failures + 1))
elif grep -qF "no verified-image" "$scratch/out"; then
  echo "PASS: a missing verified-image fails"
else
  echo "FAIL: a missing verified-image failed without naming it"
  sed 's/^/  /' "$scratch/out"
  failures=$((failures + 1))
fi

echo "$cases cases, $failures failed"
[ "$failures" -eq 0 ]
