#!/bin/sh
set -eu

# Install script for cyfr CLI
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh
#
# Environment variables:
#   CYFR_VERSION      - specific version to install (default: latest)
#   CYFR_INSTALL_DIR  - installation directory (default: /usr/local/bin or ~/.local/bin)

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
    url="https://github.com/${GITHUB_REPO}/releases/download/v${version}/${archive}"
    checksums_url="https://github.com/${GITHUB_REPO}/releases/download/v${version}/checksums.txt"

    install_dir="$(resolve_install_dir)"

    printf "Installing cyfr v%s (%s/%s) to %s\n" "$version" "$os" "$arch" "$install_dir"

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    printf "Downloading %s...\n" "$archive"
    download "$url" "$tmpdir/$archive"

    printf "Downloading checksums...\n"
    download "$checksums_url" "$tmpdir/checksums.txt"

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

    api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    if command -v curl >/dev/null 2>&1; then
        response="$(curl -fsSL "$api_url")"
    elif command -v wget >/dev/null 2>&1; then
        response="$(wget -qO- "$api_url")"
    else
        printf "Error: curl or wget is required\n" >&2
        exit 1
    fi

    version="$(echo "$response" | grep '"tag_name"' | sed 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/')"

    if [ -z "$version" ]; then
        printf "Error: could not determine latest version\n" >&2
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

verify_checksum() {
    dir="$1"
    file="$2"

    expected="$(grep "$file" "$dir/checksums.txt" | awk '{print $1}')"
    if [ -z "$expected" ]; then
        printf "Warning: could not find checksum for %s, skipping verification\n" "$file" >&2
        return
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$dir/$file" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$dir/$file" | awk '{print $1}')"
    else
        printf "Warning: sha256sum or shasum not found, skipping checksum verification\n" >&2
        return
    fi

    if [ "$expected" != "$actual" ]; then
        printf "Error: checksum mismatch for %s\n" "$file" >&2
        printf "  expected: %s\n" "$expected" >&2
        printf "  actual:   %s\n" "$actual" >&2
        exit 1
    fi

    printf "Checksum verified.\n"
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

    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
        echo "/usr/local/bin"
    elif [ -w "/usr/local/bin" ] 2>/dev/null; then
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

main
