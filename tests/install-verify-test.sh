#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# Unit tests for scripts/install.sh verification behavior (fail-closed
# checksum, cosign signature policy, explicit skip escape hatch).
#
# Usage: sh tests/install-verify-test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_ROOT/scripts/install.sh"

failures=0

# Run a snippet in a subshell that sources install.sh in test mode.
# $1 = description, $2 = expected exit (0 or nonzero via "fail"), $3 = snippet
run_case() {
    desc="$1"
    expect="$2"
    snippet="$3"

    output="$(
        sh -c "
            CYFR_INSTALL_TEST=1
            export CYFR_INSTALL_TEST
            . '$INSTALL_SH'
            $snippet
        " 2>&1
    )"
    code=$?

    if [ "$expect" = "ok" ] && [ "$code" -eq 0 ]; then
        printf 'PASS: %s\n' "$desc"
    elif [ "$expect" = "fail" ] && [ "$code" -ne 0 ]; then
        printf 'PASS: %s\n' "$desc"
    else
        printf 'FAIL: %s (exit=%s, expected %s)\n' "$desc" "$code" "$expect"
        printf '%s\n' "$output" | sed 's/^/    /'
        failures=$((failures + 1))
    fi
}

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Build a valid fixture: archive + matching checksums.txt
printf 'binary-bytes-v1' > "$fixture/cyfr_test.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum "$fixture/cyfr_test.tar.gz" | awk '{print $1}')"
else
    sum="$(shasum -a 256 "$fixture/cyfr_test.tar.gz" | awk '{print $1}')"
fi
printf '%s  cyfr_test.tar.gz\n' "$sum" > "$fixture/checksums.txt"

run_case "valid checksum passes" ok \
    "verify_checksum '$fixture' 'cyfr_test.tar.gz'"

run_case "tampered archive fails closed" fail \
    "printf 'tampered' >> '$fixture/cyfr_test.tar.gz'
     verify_checksum '$fixture' 'cyfr_test.tar.gz'
     status=\$?
     # restore fixture for later cases regardless
     exit \$status"

# Restore the fixture after the tamper case
printf 'binary-bytes-v1' > "$fixture/cyfr_test.tar.gz"

run_case "missing checksum line fails closed" fail \
    "printf '%s  some-other-file.tar.gz\n' '$sum' > '$fixture/checksums.txt'
     verify_checksum '$fixture' 'cyfr_test.tar.gz'"

# Restore checksums.txt
printf '%s  cyfr_test.tar.gz\n' "$sum" > "$fixture/checksums.txt"

run_case "missing sha tool fails closed" fail \
    "PATH='/nonexistent'
     verify_checksum '$fixture' 'cyfr_test.tar.gz'"

run_case "CYFR_INSECURE_SKIP_VERIFY=1 bypasses with a warning" ok \
    "CYFR_INSECURE_SKIP_VERIFY=1
     export CYFR_INSECURE_SKIP_VERIFY
     printf 'garbage' > '$fixture/cyfr_test.tar.gz'
     verify_checksum '$fixture' 'cyfr_test.tar.gz'"

# Restore the fixture
printf 'binary-bytes-v1' > "$fixture/cyfr_test.tar.gz"

run_case "CYFR_REQUIRE_SIGNATURE=1 without cosign fails closed" fail \
    "CYFR_REQUIRE_SIGNATURE=1
     export CYFR_REQUIRE_SIGNATURE
     PATH='/nonexistent'
     verify_signature '$fixture' 'https://example.invalid/checksums.txt.sigstore.json'"

run_case "cosign absent without strict mode degrades to a notice" ok \
    "PATH='/nonexistent'
     verify_signature '$fixture' 'https://example.invalid/checksums.txt.sigstore.json'"

if [ "$failures" -gt 0 ]; then
    printf '\n%s test(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nAll install.sh verification tests passed\n'
