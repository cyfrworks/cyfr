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
#   scripts/cosign.sh check image IMAGE
#   scripts/cosign.sh check run TARGET RUNNER...
#                                   in a container of IMAGE the check starts
#                                   with a boot's environment, or in TARGET
#                                   as RUNNER... runs it (`docker compose run
#                                   --rm --no-deps -T` and the cyfr service);
#                                   either way through the image's
#                                   entrypoint, as its user, with its
#                                   environment: its cosign is the pinned
#                                   version, and the product's own
#                                   `Compendium.Cosign.verify/2`, through
#                                   `bin/cyfr eval` under the CYFR_COSIGN_*
#                                   settings an operator sets, verifies
#                                   upstream's own signed image of this
#                                   version keyed with upstream's release
#                                   key and keyless against its signer,
#                                   recording the key's fingerprint for the
#                                   one and no signer for the other, and
#                                   refuses it keyless against another
#                                   identity. Needs the network.
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

usage() { echo "usage: $0 install DIR | version | check image IMAGE | check run TARGET RUNNER..." >&2; exit 64; }

# Runs `$2...` in the check's target with the settings of the env file
# `$1` (NAME=value lines) and the key directory at /run/cosign-check.
# `check image` starts a container of the image of its own for each
# command, named under PROOF_RUN_PREFIX, with what a boot needs
# (CYFR_ACCESS and a fresh CYFR_SECRET_KEY_BASE); `check run` runs
# RUNNER... TARGET with each setting as an -e.
in_target() {
  local envfile=$1 line
  shift
  if [ "$mode" = image ]; then
    docker run --rm --name "${PROOF_RUN_PREFIX:-}cosign-check-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" \
      -e CYFR_ACCESS=local -e "CYFR_SECRET_KEY_BASE=$secret" --env-file "$envfile" -v "$key:/run/cosign-check:ro" \
      "$target" "$@"
  else
    local -a settings=()
    while IFS= read -r line; do settings+=(-e "$line"); done <"$envfile"
    "${runner[@]}" ${settings[@]+"${settings[@]}"} -v "$key:/run/cosign-check:ro" "$target" "$@"
  fi
}

# The line Compendium.Cosign.verify/2 of CHECK_IMAGE answers in the target
# under the CYFR_COSIGN_* settings `$@` (NAME=value words): VERIFIED and the
# recorded identity and issuer as Elixir terms, or REFUSED and the refusal.
module_verify() {
  printf '%s\n' "$@" >"$key/settings.env"
  in_target "$key/settings.env" /app/bin/cyfr eval "
    case Compendium.Cosign.verify(\"$CHECK_IMAGE\", \"${CHECK_IMAGE#*@}\") do
      {:ok, signer} -> IO.puts(\"VERIFIED #{inspect(signer.identity)} #{inspect(signer.issuer)}\")
      refused -> IO.puts(\"REFUSED #{inspect(refused)}\")
    end" 2>&1 | grep -E '^(VERIFIED|REFUSED) ' | tail -1
}

check() {
  local answer want
  key="$(mktemp -d)"
  trap 'rm -rf "$key"' RETURN
  # Readable by the image's user, whatever this process's umask.
  chmod 0755 "$key"
  : >"$key/none.env"
  answer="$(in_target "$key/none.env" cosign version --json 2>&1)" ||
    { echo "cosign: $target runs no cosign: $answer" >&2; return 1; }
  printf '%s' "$answer" | grep -q "\"gitVersion\": *\"v$VERSION\"" ||
    { echo "cosign: $target runs a cosign that is not $VERSION: $answer" >&2; return 1; }
  curl --proto '=https' --tlsv1.2 -sSfL --max-time 60 --connect-timeout 20 -o "$key/release-cosign.pub" \
    "https://github.com/sigstore/cosign/releases/download/v$VERSION/release-cosign.pub"
  echo "$RELEASE_KEY_SHA256  $key/release-cosign.pub" | sha256sum -c --quiet -
  chmod 0644 "$key/release-cosign.pub"
  answer="$(module_verify CYFR_COSIGN_KEY=/run/cosign-check/release-cosign.pub)"
  want="VERIFIED \"key:sha256:$RELEASE_KEY_SHA256\" \"key\""
  [ "$answer" = "$want" ] || { echo "cosign: $target's keyed verification of $CHECK_IMAGE answered '$answer', not '$want'" >&2; return 1; }
  echo "Compendium.Cosign in $target verified $CHECK_IMAGE keyed: $answer"
  answer="$(module_verify "CYFR_COSIGN_IDENTITY=$CHECK_IDENTITY" "CYFR_COSIGN_ISSUER=$CHECK_ISSUER")"
  want="VERIFIED nil nil"
  [ "$answer" = "$want" ] || { echo "cosign: $target's keyless verification of $CHECK_IMAGE answered '$answer', not '$want'" >&2; return 1; }
  echo "Compendium.Cosign in $target verified $CHECK_IMAGE keyless: $answer"
  answer="$(module_verify 'CYFR_COSIGN_IDENTITY=^release@example\.com$' "CYFR_COSIGN_ISSUER=$CHECK_ISSUER")"
  case "$answer" in
    "REFUSED {:error, {:rejected, "*) echo "Compendium.Cosign in $target refused $CHECK_IMAGE keyless for another identity" ;;
    *) echo "cosign: $target's keyless verification of $CHECK_IMAGE for another identity answered '$answer', not cosign's refusal" >&2; return 1 ;;
  esac
}

case "${1:-}" in
  version)
    echo "$VERSION"
    exit 0
    ;;
  check)
    case "${2:-}" in
      image)
        [ "$#" -eq 3 ] || usage
        mode=image target=$3 secret="$(openssl rand -hex 48)"
        ;;
      run)
        [ "$#" -ge 4 ] || usage
        mode=run target=$3
        runner=("${@:4}")
        ;;
      *) usage ;;
    esac
    check
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
