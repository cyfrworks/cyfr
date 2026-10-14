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
# $1 = description, $2 = expected exit (0 or nonzero via "fail"), $3 = snippet,
# $4 = optional text the output must contain, which pins the refusal reached
run_case() {
    desc="$1"
    expect="$2"
    snippet="$3"
    message="${4:-}"

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
        reason=""
    elif [ "$expect" = "fail" ] && [ "$code" -ne 0 ]; then
        reason=""
    else
        reason="exit=$code, expected $expect"
    fi

    if [ -z "$reason" ] && [ -n "$message" ]; then
        case "$output" in
            *"$message"*) ;;
            *) reason="output lacks \"$message\"" ;;
        esac
    fi

    if [ -z "$reason" ]; then
        printf 'PASS: %s\n' "$desc"
    else
        printf 'FAIL: %s (%s)\n' "$desc" "$reason"
        printf '%s\n' "$output" | sed 's/^/    /'
        failures=$((failures + 1))
    fi
}

# Print the first executable named $1 on PATH. `command -v` would name a
# shell builtin such as printf instead of its file.
find_tool() {
    saved_ifs="$IFS"
    IFS=:
    for dir in $PATH; do
        if [ -n "$dir" ] && [ -f "$dir/$1" ] && [ -x "$dir/$1" ]; then
            IFS="$saved_ifs"
            printf '%s\n' "$dir/$1"
            return 0
        fi
    done
    IFS="$saved_ifs"
    return 1
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

# verify_checksum reads checksums.txt with grep and awk before it looks for a
# sha tool, so this case's PATH keeps those and lacks only sha256sum and
# shasum; an empty PATH would stop at "no checksum found" instead.
no_sha_path="$fixture/no-sha-path"
mkdir "$no_sha_path"
for tool in sh grep awk cat printf; do
    if ! tool_file="$(find_tool "$tool")"; then
        printf 'install-verify-test: %s is not on PATH\n' "$tool" >&2
        exit 1
    fi
    ln -s "$tool_file" "$no_sha_path/$tool"
done

run_case "missing sha tool fails closed" fail \
    "PATH='$no_sha_path'
     verify_checksum '$fixture' 'cyfr_test.tar.gz'" \
    "sha256sum or shasum is required"

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
