#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -eu

# Install script for cyfr CLI
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh
#
# Environment variables:
#   CYFR_VERSION              - the exact version to install, a pre-release
#                               such as 0.6.0-alpha.1 included (default: the
#                               latest release that is not a pre-release)
#   CYFR_INSTALL_DIR          - installation directory (default: /usr/local/bin or ~/.local/bin)
#   CYFR_ALLOW_UNVERIFIED     - set to 1 to install without cosign, or without the
#                               release's signature bundle: checksums.txt's
#                               signature is then NOT verified (the checksum is)
#   CYFR_INSECURE_SKIP_VERIFY - set to 1 to skip checksum/signature verification
#                               (NOT recommended; for airgapped/bootstrap edge cases)
#
# Integrity: checksums.txt must carry the release workflow's keyless cosign
# signature for the version installed (the certificate identity exactly
# https://github.com/cyfrworks/cyfr/.github/workflows/release.yml@refs/tags/<version>,
# GitHub Actions' OIDC issuer), as `cyfr update` verifies it in process;
# without cosign or the signature the install refuses unless
# CYFR_ALLOW_UNVERIFIED=1. The archive's SHA-256 checksum is then verified
# against checksums.txt, and the install fails on any mismatch or missing
# tooling. CYFR_INSECURE_SKIP_VERIFY=1 skips both.

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

    verify_signature "$tmpdir" "$sig_bundle_url" "$version"
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
        homebrew_tip "$version"
    fi
}

# macOS's closing tip for the version $1 installed. The Homebrew cask
# installs the latest release that is not a pre-release, so it is offered
# for a bare version alone; a pre-release (0.6.0-alpha.1, a version with a
# pre-release part) is told the cask follows the first such release.
homebrew_tip() {
    case "$1" in
        *-*)
            printf "\nThe Homebrew cask follows the first release that is not a pre-release; v%s is a pre-release, installed by this script alone.\n" "$1"
            ;;
        *)
            printf "\nTip: You can also install via Homebrew:\n"
            printf "  brew tap cyfrworks/cyfr && brew install --cask cyfr\n"
            ;;
    esac
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

    # List recent releases and pick the newest CLI release, as `cyfr update`
    # does (internal/release.Latest): the greatest bare MAJOR.MINOR.PATCH tag
    # without leading zeros, compared numerically, whatever order the API
    # lists them in. Drafts, releases GitHub marks as pre-releases and tags
    # outside the bare release-version grammar are skipped.
    # Each release's tag_name, draft and prerelease are its own top-level
    # keys, tag_name first; a string value cannot hold an unescaped quote, so
    # no release body matches them. A release whose flags are not both read
    # is skipped.
    api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=20"
    if command -v curl >/dev/null 2>&1; then
        response="$(curl -fsSL "$api_url")"
    elif command -v wget >/dev/null 2>&1; then
        response="$(wget -qO- "$api_url")"
    else
        printf "Error: curl or wget is required\n" >&2
        exit 1
    fi

    version="$(printf '%s\n' "$response" | tr -d '\n' |
        grep -oE '"(tag_name|draft|prerelease)":[[:space:]]*("[^"]*"|true|false)' |
        awk '
            function newer(a, b,    x, y, i) {
                split(a, x, ".")
                split(b, y, ".")
                for (i = 1; i <= 3; i++)
                    if (x[i] + 0 != y[i] + 0) return x[i] + 0 > y[i] + 0
                return 0
            }
            function flush() {
                if (tag ~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ && draft == "false" && pre == "false" && (best == "" || newer(tag, best)))
                    best = tag
                tag = ""; draft = ""; pre = ""
            }
            {
                key = $0; sub(/":.*/, "", key); sub(/^"/, "", key)
                value = $0; sub(/^[^:]*:[[:space:]]*/, "", value); gsub(/"/, "", value)
            }
            key == "tag_name" { flush(); tag = value }
            key == "draft" { draft = value }
            key == "prerelease" { pre = value }
            END { flush(); print best }
        ')"

    # The sentence internal/release.ErrNoRelease begins: CYFR_VERSION alone
    # installs a pre-release.
    if [ -z "$version" ]; then
        printf "Error: no CYFR release is published yet apart from pre-releases; set CYFR_VERSION to the version to install (https://github.com/%s/releases lists them)\n" "$GITHUB_REPO" >&2
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

allow_unverified() {
    [ "${CYFR_ALLOW_UNVERIFIED:-}" = "1" ]
}

verify_checksum() {
    dir="$1"
    file="$2"

    if skip_verify; then
        printf "WARNING: CYFR_INSECURE_SKIP_VERIFY=1 — checksum verification SKIPPED.\n" >&2
        printf "         The downloaded binary has NOT been verified.\n" >&2
        return
    fi

    # -F: the filename is a literal, not a regex — its dots would otherwise
    # match any character, and the version comes from user-settable input.
    expected="$(grep -F "$file" "$dir/checksums.txt" | awk '{print $1}')"
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

# On Ubuntu 26.04 at a terminal, offers to install cosign from Ubuntu's
# archive, once. The script itself may be on a pipe, so the question goes to
# the terminal.
offer_cosign() {
    grep -qx 'ID=ubuntu' /etc/os-release 2>/dev/null || return 0
    grep -qx 'VERSION_ID="26.04"' /etc/os-release || return 0
    { : </dev/tty; } 2>/dev/null || return 0
    printf 'cosign verifies this release, and this machine lacks it. These commands install it:\n  sudo apt-get update\n  sudo apt-get install -y cosign\nInstall cosign? [y/N] ' >/dev/tty
    read -r answer </dev/tty || return 0
    case "$answer" in
        y | Y | yes | YES) sudo apt-get update </dev/tty && sudo apt-get install -y cosign </dev/tty ;;
    esac
}

# Verify the cosign keyless signature over checksums.txt as the release
# workflow's for this version: the certificate identity is exactly
# release.yml at the version's tag, under GitHub Actions' OIDC issuer — the
# identity `cyfr init` and `cyfr update` verify (internal/release). Without
# cosign or the bundle the install refuses unless CYFR_ALLOW_UNVERIFIED=1,
# which installs on the checksum alone.
verify_signature() {
    dir="$1"
    bundle_url="$2"
    version="$3"

    if skip_verify; then
        printf "WARNING: CYFR_INSECURE_SKIP_VERIFY=1 — signature verification SKIPPED.\n" >&2
        return
    fi

    command -v cosign >/dev/null 2>&1 || offer_cosign
    if ! command -v cosign >/dev/null 2>&1; then
        if allow_unverified; then
            printf "WARNING: CYFR_ALLOW_UNVERIFIED=1 and cosign is not installed — checksums.txt's\n" >&2
            printf "         signature is NOT verified; only the archive's checksum is.\n" >&2
            return
        fi
        printf "Error: cosign is required to verify that checksums.txt is the release workflow's — refusing to install.\n" >&2
        printf "Install cosign (https://docs.sigstore.dev/cosign/system_config/installation/), or set\n" >&2
        printf "CYFR_ALLOW_UNVERIFIED=1 to install on the checksum alone.\n" >&2
        exit 1
    fi

    if ! download "$bundle_url" "$dir/checksums.txt.sigstore.json"; then
        if allow_unverified; then
            printf "WARNING: CYFR_ALLOW_UNVERIFIED=1 and the signature bundle could not be downloaded —\n" >&2
            printf "         checksums.txt's signature is NOT verified; only the archive's checksum is.\n" >&2
            return
        fi
        printf "Error: the signature bundle for checksums.txt could not be downloaded — refusing to install.\n" >&2
        printf "Set CYFR_ALLOW_UNVERIFIED=1 to install on the checksum alone.\n" >&2
        exit 1
    fi

    if cosign verify-blob \
        --bundle "$dir/checksums.txt.sigstore.json" \
        --certificate-identity "https://github.com/${GITHUB_REPO}/.github/workflows/release.yml@refs/tags/${version}" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        "$dir/checksums.txt" >/dev/null 2>&1; then
        printf "Signature verified (the release workflow of %s, cosign keyless).\n" "$version"
    else
        printf "Error: cosign signature verification FAILED for checksums.txt — refusing to install.\n" >&2
        printf "It is not signed by the release workflow of %s; the release may have been tampered with.\n" "$version" >&2
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
