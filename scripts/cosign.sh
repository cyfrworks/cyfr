#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The one pin of the cosign the app image carries, which
# `Compendium.Cosign` runs from PATH to verify a pulled component's
# signature (CYFR_COSIGN_KEY, CYFR_COSIGN_IDENTITY and CYFR_COSIGN_ISSUER;
# CYFR_REQUIRE_SIGNED_PULLS refuses a pull it cannot verify), and its
# installer:
#
#   scripts/cosign.sh install DIR   install DIR/cosign: the pinned release
#                                   for this machine's architecture, checked
#                                   against the pinned sha256, then stripped
#                                   of its symbols; a DIR/cosign already at
#                                   the pinned version is kept
#   scripts/cosign.sh version       print the pinned version
#   scripts/cosign.sh check TARGET RUNNER...
#                                   run cosign as RUNNER... TARGET runs it
#                                   (`docker run --rm` and an image, or
#                                   `docker compose run --rm --no-deps -T` and
#                                   the cyfr service: through the image's
#                                   entrypoint, as its user, with its
#                                   environment) and hold it to a real
#                                   verification each way Compendium.Cosign
#                                   asks for one, with Compendium.Cosign's
#                                   arguments: upstream's own signed image of
#                                   this version, keyed with upstream's
#                                   release key and keyless against its
#                                   signer, each answer naming the digest
#                                   asked about; and the version the pinned
#                                   one. Needs the network.
#
# The version is the one the release workflow signs with
# (sigstore/cosign-installer's default in .github/workflows/release.yml).
# The checksums are upstream's cosign_checksums.txt lines for the two
# binaries, which GitHub's recorded sha256 for each release asset matches,
# and the release key's is the sha256 of release-cosign.pub as that
# release publishes it. The check's image is upstream's image index of
# this version, signed in the new bundle format both ways.
set -euo pipefail

VERSION=3.1.4
SHA256_AMD64=424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa
SHA256_ARM64=ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2
RELEASE_KEY_SHA256=f4cea466e5e887a45da5031757fa1d32655d83420639dc1758749b744179f126
CHECK_IMAGE=ghcr.io/sigstore/cosign/cosign@sha256:0f06154836d2de34f887a5c273506d52ca43edaa1d9e53e6510fa78a48f69c2d
CHECK_IDENTITY='^keyless@projectsigstore\.iam\.gserviceaccount\.com$'
CHECK_ISSUER='^https://accounts\.google\.com$'

usage() { echo "usage: $0 install DIR | version | check TARGET RUNNER..." >&2; exit 64; }

# The digest the first entry of cosign's JSON answer `$1` names.
answered_digest() {
  printf '%s' "$1" | python3 -I -c '
import json, sys
print(json.load(sys.stdin)[0]["critical"]["image"]["docker-manifest-digest"])' 2>/dev/null
}

check() {
  local target=$1 key answer how
  shift
  answer="$("$@" "$target" cosign version --json 2>&1)" || { echo "cosign: $target runs no cosign: $answer" >&2; return 1; }
  printf '%s' "$answer" | grep -q "\"gitVersion\": *\"v$VERSION\"" ||
    { echo "cosign: $target runs a cosign that is not $VERSION: $answer" >&2; return 1; }
  key="$(mktemp -d)"
  trap 'rm -rf "$key"' RETURN
  curl --proto '=https' --tlsv1.2 -sSfL --max-time 60 --connect-timeout 20 -o "$key/release-cosign.pub" \
    "https://github.com/sigstore/cosign/releases/download/v$VERSION/release-cosign.pub"
  echo "$RELEASE_KEY_SHA256  $key/release-cosign.pub" | sha256sum -c --quiet -
  # Readable by the image's user, whatever this process's umask.
  chmod 0755 "$key"
  chmod 0644 "$key/release-cosign.pub"
  for how in keyed keyless; do
    # The JSON answer is stdout alone; cosign says what it checked on stderr.
    if [ "$how" = keyed ]; then
      answer="$("$@" -v "$key:/run/cosign-check:ro" "$target" cosign verify \
        --key /run/cosign-check/release-cosign.pub --output json -- "$CHECK_IMAGE" 2>"$key/stderr")" || answer=""
    else
      answer="$("$@" "$target" cosign verify --certificate-identity-regexp "$CHECK_IDENTITY" \
        --certificate-oidc-issuer-regexp "$CHECK_ISSUER" --output json -- "$CHECK_IMAGE" 2>"$key/stderr")" || answer=""
    fi
    [ "$(answered_digest "$answer")" = "${CHECK_IMAGE#*@}" ] ||
      { echo "cosign: $target's $how verification of $CHECK_IMAGE did not pass: ${answer:0:400} $(tail -c 800 "$key/stderr")" >&2; return 1; }
    echo "cosign $VERSION in $target verified $CHECK_IMAGE $how"
  done
}

case "${1:-}" in
  version)
    echo "$VERSION"
    exit 0
    ;;
  check)
    [ "$#" -ge 3 ] || usage
    shift
    check "$@"
    exit
    ;;
  install)
    [ "$#" -eq 2 ] || usage
    dir=$2
    ;;
  *) usage ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64; sha=$SHA256_AMD64 ;;
  aarch64 | arm64) arch=arm64; sha=$SHA256_ARM64 ;;
  *) echo "cosign: no pinned release for $(uname -m)" >&2; exit 1 ;;
esac

if [ -x "$dir/cosign" ] &&
  "$dir/cosign" version --json 2>/dev/null | grep -q "\"gitVersion\": *\"v$VERSION\""; then
  exit 0
fi

name="cosign-linux-$arch"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl --proto '=https' --tlsv1.2 -sSfL --max-time 300 --connect-timeout 20 -o "$work/$name" \
  "https://github.com/sigstore/cosign/releases/download/v$VERSION/$name"
echo "$sha  $work/$name" | sha256sum -c --quiet -
# The symbols go once the checksum has held the download to upstream's
# bytes: they are a third of the binary and nothing at run time reads them.
strip "$work/$name"
mkdir -p "$dir"
# Into place by a rename: two installs into one DIR at once, or a reader
# running the tool meanwhile, never see a file half written.
trap 'rm -rf "$work" "$dir/.cosign.$$"' EXIT
install -m 0755 "$work/$name" "$dir/.cosign.$$"
mv -f "$dir/.cosign.$$" "$dir/cosign"
"$dir/cosign" version --json >/dev/null
echo "cosign $VERSION"
