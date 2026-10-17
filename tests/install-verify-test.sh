#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# Unit tests for scripts/install.sh verification behavior (fail-closed
# checksum, the release workflow's cosign signature required unless
# CYFR_ALLOW_UNVERIFIED=1, explicit skip escape hatch).
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

bundle_url='https://example.invalid/checksums.txt.sigstore.json'

run_case "cosign absent refuses" fail \
    "PATH='/nonexistent'
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "cosign is required"

run_case "cosign absent with CYFR_ALLOW_UNVERIFIED=1 installs on the checksum, with a warning" ok \
    "CYFR_ALLOW_UNVERIFIED=1
     PATH='/nonexistent'
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "signature is NOT verified"

run_case "CYFR_ALLOW_UNVERIFIED set to anything but 1 still refuses" fail \
    "CYFR_ALLOW_UNVERIFIED=yes
     PATH='/nonexistent'
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "cosign is required"

run_case "CYFR_INSECURE_SKIP_VERIFY=1 skips the signature with a warning" ok \
    "CYFR_INSECURE_SKIP_VERIFY=1
     PATH='/nonexistent'
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "signature verification SKIPPED"

# A cosign on PATH that writes its arguments one per line to cosign.args and
# exits with the status in cosign.exit (0 when absent). The bundle downloads
# through an override of download, so no case reaches the network.
cosign_bin="$fixture/cosign-bin"
mkdir "$cosign_bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/cosign.args"\nexit "$(cat "%s/cosign.exit" 2>/dev/null || echo 0)"\n' \
    "$fixture" "$fixture" > "$cosign_bin/cosign"
chmod +x "$cosign_bin/cosign"
with_cosign="PATH='$cosign_bin:$PATH'"
bundle_ok='download() { printf bundle > "$2"; }'
bundle_missing='download() { return 22; }'

run_case "the release workflow's signature for the version passes" ok \
    "$with_cosign
     $bundle_ok
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "Signature verified (the release workflow of 1.2.3"

# The identity cosign was given is exactly the release workflow's at the
# version's tag, under GitHub Actions' issuer; no regexp admits another.
desc="cosign verifies the exact identity release.yml@refs/tags/<version>"
args="$(cat "$fixture/cosign.args" 2>/dev/null)"
expected_args="verify-blob
--bundle
$fixture/checksums.txt.sigstore.json
--certificate-identity
https://github.com/cyfrworks/cyfr/.github/workflows/release.yml@refs/tags/1.2.3
--certificate-oidc-issuer
https://token.actions.githubusercontent.com
$fixture/checksums.txt"
if [ "$args" = "$expected_args" ]; then
    printf 'PASS: %s\n' "$desc"
else
    printf 'FAIL: %s\n' "$desc"
    printf '%s\n' "$args" | sed 's/^/    /'
    failures=$((failures + 1))
fi

printf '1' > "$fixture/cosign.exit"
run_case "a signature cosign refuses fails closed" fail \
    "$with_cosign
     $bundle_ok
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "verification FAILED"
rm -f "$fixture/cosign.exit"

run_case "a signature bundle that does not download refuses" fail \
    "$with_cosign
     $bundle_missing
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "could not be downloaded"

run_case "a missing bundle with CYFR_ALLOW_UNVERIFIED=1 installs on the checksum, with a warning" ok \
    "CYFR_ALLOW_UNVERIFIED=1
     $with_cosign
     $bundle_missing
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "signature is NOT verified"

# resolve_version reads the releases API through a curl on PATH that prints
# a fixture: the newest release is the greatest bare MAJOR.MINOR.PATCH by
# number, whatever the listing's order; drafts, pre-releases and tags that
# are no bare version are skipped, and a release body quoting the keys is
# only text.
api_bin="$fixture/api-bin"
mkdir "$api_bin"
cat > "$fixture/releases.json" <<'JSON'
[
  {
    "url": "https://api.github.com/repos/cyfrworks/cyfr/releases/1",
    "author": {"login": "release-bot", "type": "Bot", "site_admin": false},
    "tag_name": "0.5.12",
    "name": "0.5.12",
    "draft": false,
    "prerelease": false,
    "body": "Backport. Not \"tag_name\": \"9.9.9\", \"draft\": false, \"prerelease\": false."
  },
  {"tag_name": "0.11.0", "draft": true, "prerelease": false, "assets": [{"name": "cyfr_0.11.0_linux_amd64.tar.gz", "state": "uploaded"}]},
  {"tag_name": "0.10.0", "draft": false, "prerelease": true},
  {"tag_name": "porta-v1.2.0", "draft": false, "prerelease": false},
  {"tag_name": "v0.20.0", "draft": false, "prerelease": false},
  {"tag_name": "0.9.1-rc1", "draft": false, "prerelease": false},
  {"tag_name": "0.9.1", "draft": false, "prerelease": false},
  {"tag_name": "0.6.3", "draft": false, "prerelease": false}
]
JSON
printf '#!/bin/sh\ncat "%s"\n' "$fixture/releases.json" > "$api_bin/curl"
chmod +x "$api_bin/curl"

run_case "the newest release is the greatest bare version, drafts and pre-releases skipped" ok \
    "PATH='$api_bin:$PATH'
     unset CYFR_VERSION
     version=\$(resolve_version) || exit 1
     printf 'resolved %s\n' \"\$version\"
     [ \"\$version\" = 0.9.1 ]" \
    "resolved 0.9.1"

tr -d '\n ' < "$fixture/releases.json" > "$fixture/releases.min.json"
printf '#!/bin/sh\ncat "%s"\n' "$fixture/releases.min.json" > "$api_bin/curl"
run_case "the API's minified answer resolves the same release" ok \
    "PATH='$api_bin:$PATH'
     unset CYFR_VERSION
     version=\$(resolve_version) || exit 1
     printf 'resolved %s\n' \"\$version\"
     [ \"\$version\" = 0.9.1 ]" \
    "resolved 0.9.1"

printf '[{"tag_name": "1.0.0", "draft": true, "prerelease": false}, {"tag_name": "porta-v2.0.0", "draft": false, "prerelease": false}]' > "$fixture/releases.none.json"
printf '#!/bin/sh\ncat "%s"\n' "$fixture/releases.none.json" > "$api_bin/curl"
run_case "no released bare version refuses" fail \
    "PATH='$api_bin:$PATH'
     unset CYFR_VERSION
     resolve_version" \
    "could not determine latest CLI version"

if [ "$failures" -gt 0 ]; then
    printf '\n%s test(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nAll install.sh verification tests passed\n'
