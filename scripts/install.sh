#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -eu

# Install script for cyfr CLI
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh
#
# Environment variables:
#   CYFR_VERSION              - specific version to install (default: latest)
#   CYFR_INSTALL_DIR          - installation directory (default: /usr/local/bin or ~/.local/bin)
#   CYFR_REQUIRE_SIGNATURE    - set to 1 to REQUIRE cosign signature verification
#                               (fails if cosign is missing or the signature is invalid)
#   CYFR_INSECURE_SKIP_VERIFY - set to 1 to skip checksum/signature verification
#                               (NOT recommended; for airgapped/bootstrap edge cases)
#
# Integrity: the SHA-256 checksum of the downloaded archive is ALWAYS verified
# against the release's checksums.txt and the install fails on any mismatch or
# missing tooling (unless CYFR_INSECURE_SKIP_VERIFY=1). checksums.txt itself is
# signed with cosign (keyless, GitHub Actions OIDC); when cosign is on PATH the
# signature is verified strictly, otherwise a notice is printed.

GITHUB_REPO="cyfrworks/cyfr"
BINARY_NAME="cyfr"

main() {
    os="$(detect_os)"
    arch="$(detect_arch)"
    version="$(resolve_version)"

    if [ "$os" = "windows" ]; then
        ext="zip"
    else
        ext="tar.gz"
    fi

    archive="cyfr_${version}_${os}_${arch}.${ext}"
    url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${archive}"
    checksums_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/checksums.txt"
    sig_bundle_url="${checksums_url}.sigstore.json"

    install_dir="$(resolve_install_dir)"

    printf "Installing cyfr v%s (%s/%s) to %s\n" "$version" "$os" "$arch" "$install_dir"

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    printf "Downloading %s...\n" "$archive"
    download "$url" "$tmpdir/$archive"

    printf "Downloading checksums...\n"
    download "$checksums_url" "$tmpdir/checksums.txt"

    verify_signature "$tmpdir" "$sig_bundle_url"
    verify_checksum "$tmpdir" "$archive"

    printf "Extracting...\n"
    extract "$tmpdir/$archive" "$tmpdir" "$ext"

    binary="$BINARY_NAME"
    if [ "$os" = "windows" ]; then
        binary="${BINARY_NAME}.exe"
    fi

    install_binary "$tmpdir/$binary" "$install_dir/$binary"

    printf "\ncyfr v%s installed successfully to %s/%s\n" "$version" "$install_dir" "$binary"

    check_path "$install_dir"

    if [ "$os" = "darwin" ]; then
        printf "\nTip: You can also install via Homebrew:\n"
        printf "  brew tap cyfrworks/cyfr && brew install --cask cyfr\n"
    fi
}

detect_os() {
    case "$(uname -s)" in
        Linux*)   echo "linux" ;;
        Darwin*)  echo "darwin" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *)
            printf "Error: unsupported operating system: %s\n" "$(uname -s)" >&2
            exit 1
            ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *)
            printf "Error: unsupported architecture: %s\n" "$(uname -m)" >&2
            exit 1
            ;;
    esac
}

resolve_version() {
    if [ -n "${CYFR_VERSION:-}" ]; then
        echo "$CYFR_VERSION"
        return
    fi

    # List recent releases and pick the newest CLI release (a bare-semver tag,
    # e.g. `0.5.0`). Anything not starting with a digit (legacy `v*` releases or
    # `porta-v*` desktop releases) is skipped implicitly by the match below.
    api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=20"
    if command -v curl >/dev/null 2>&1; then
        response="$(curl -fsSL "$api_url")"
    elif command -v wget >/dev/null 2>&1; then
        response="$(wget -qO- "$api_url")"
    else
        printf "Error: curl or wget is required\n" >&2
        exit 1
    fi

    version=""
    for tag in $(printf '%s\n' "$response" | grep '"tag_name"' | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/'); do
        case "$tag" in
            [0-9]*)
                version="$tag"
                break
                ;;
        esac
    done

    if [ -z "$version" ]; then
        printf "Error: could not determine latest CLI version\n" >&2
        exit 1
    fi

    echo "$version"
}

download() {
    url="$1"
    dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        printf "Error: curl or wget is required\n" >&2
        exit 1
    fi
}

skip_verify() {
    [ "${CYFR_INSECURE_SKIP_VERIFY:-}" = "1" ]
}

verify_checksum() {
    dir="$1"
    file="$2"

    if skip_verify; then
        printf "WARNING: CYFR_INSECURE_SKIP_VERIFY=1 — checksum verification SKIPPED.\n" >&2
        printf "         The downloaded binary has NOT been verified.\n" >&2
        return
    fi

    expected="$(grep "$file" "$dir/checksums.txt" | awk '{print $1}')"
    if [ -z "$expected" ]; then
        printf "Error: no checksum found for %s in checksums.txt — refusing to install.\n" "$file" >&2
        printf "Set CYFR_INSECURE_SKIP_VERIFY=1 to bypass (NOT recommended).\n" >&2
        exit 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$dir/$file" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$dir/$file" | awk '{print $1}')"
    else
        printf "Error: sha256sum or shasum is required for checksum verification — refusing to install.\n" >&2
        printf "Install one of them, or set CYFR_INSECURE_SKIP_VERIFY=1 to bypass (NOT recommended).\n" >&2
        exit 1
    fi

    if [ "$expected" != "$actual" ]; then
        printf "Error: checksum mismatch for %s\n" "$file" >&2
        printf "  expected: %s\n" "$expected" >&2
        printf "  actual:   %s\n" "$actual" >&2
        exit 1
    fi

    printf "Checksum verified.\n"
}

# Verify the cosign keyless signature over checksums.txt. The bundle is
# produced by the release workflow (GitHub Actions OIDC identity), so a valid
# signature proves checksums.txt came from this repo's release pipeline.
# Strict when cosign is available or CYFR_REQUIRE_SIGNATURE=1; a notice
# otherwise (curl|sh users typically don't have cosign installed).
verify_signature() {
    dir="$1"
    bundle_url="$2"

    if skip_verify; then
        printf "WARNING: CYFR_INSECURE_SKIP_VERIFY=1 — signature verification SKIPPED.\n" >&2
        return
    fi

    if ! command -v cosign >/dev/null 2>&1; then
        if [ "${CYFR_REQUIRE_SIGNATURE:-}" = "1" ]; then
            printf "Error: CYFR_REQUIRE_SIGNATURE=1 but cosign is not installed — refusing to install.\n" >&2
            exit 1
        fi
        printf "Notice: cosign not found — checksums will be verified, but the checksum file's\n" >&2
        printf "        signature will NOT be. Install cosign for full supply-chain verification.\n" >&2
        return
    fi

    if ! download "$bundle_url" "$dir/checksums.txt.sigstore.json"; then
        if [ "${CYFR_REQUIRE_SIGNATURE:-}" = "1" ]; then
            printf "Error: CYFR_REQUIRE_SIGNATURE=1 but the signature bundle could not be downloaded.\n" >&2
            exit 1
        fi
        printf "Notice: signature bundle not available for this release — skipping signature check.\n" >&2
        return
    fi

    if cosign verify-blob \
        --bundle "$dir/checksums.txt.sigstore.json" \
        --certificate-identity-regexp "^https://github.com/${GITHUB_REPO}/" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        "$dir/checksums.txt" >/dev/null 2>&1; then
        printf "Signature verified (cosign keyless, GitHub Actions OIDC).\n"
    else
        printf "Error: cosign signature verification FAILED for checksums.txt — refusing to install.\n" >&2
        printf "The release may have been tampered with.\n" >&2
        exit 1
    fi
}

extract() {
    archive="$1"
    dest="$2"
    ext="$3"

    case "$ext" in
        tar.gz) tar -xzf "$archive" -C "$dest" ;;
        zip)    unzip -qo "$archive" -d "$dest" ;;
        *)
            printf "Error: unsupported archive format: %s\n" "$ext" >&2
            exit 1
            ;;
    esac
}

resolve_install_dir() {
    if [ -n "${CYFR_INSTALL_DIR:-}" ]; then
        mkdir -p "$CYFR_INSTALL_DIR"
        echo "$CYFR_INSTALL_DIR"
        return
    fi

    # Apple Silicon Homebrew prefix
    if [ -d "/opt/homebrew/bin" ] && [ -w "/opt/homebrew/bin" ]; then
        echo "/opt/homebrew/bin"
    elif [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
        echo "/usr/local/bin"
    else
        dir="${HOME}/.local/bin"
        mkdir -p "$dir"
        echo "$dir"
    fi
}

install_binary() {
    src="$1"
    dest="$2"
    dest_dir="$(dirname "$dest")"

    if [ -w "$dest_dir" ]; then
        cp "$src" "$dest"
        chmod +x "$dest"
    elif command -v sudo >/dev/null 2>&1; then
        printf "Elevated permissions required to install to %s\n" "$dest_dir"
        sudo cp "$src" "$dest"
        sudo chmod +x "$dest"
    else
        printf "Error: cannot write to %s and sudo is not available\n" "$dest_dir" >&2
        printf "Set CYFR_INSTALL_DIR to a writable directory and try again.\n" >&2
        exit 1
    fi
}

check_path() {
    dir="$1"
    case ":${PATH}:" in
        *":${dir}:"*) ;;
        *)
            printf "\nNote: %s is not in your PATH.\n" "$dir"
            printf "Add it by running:\n"
            printf "  export PATH=\"%s:\$PATH\"\n" "$dir"
            ;;
    esac
}

# Test harness sources this file to unit-test the verification functions;
# only run the installer when executed directly.
if [ "${CYFR_INSTALL_TEST:-}" != "1" ]; then
    main
fi
