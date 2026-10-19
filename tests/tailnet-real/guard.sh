#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The verified-image guard. tests/tailnet-real/verified-image is one line:
# the exact tailscale image reference, tag and digest, that a pass of the
# real-tailnet run (tests/tailnet-real/run.sh) verified and wrote. This
# fails while docker-compose.yml's tailscale service names any other
# reference: another tag, or another digest under the same tag, which
# `cyfr update` and Dependabot can write. The Compose proof's stand-in
# certifies no Tailscale binary, so only a real-tailnet pass against the
# new reference, which rewrites verified-image, lets a new one through.
#
# The reference is the first `image:` key inside the tailscale service, as
# written, and it must name a digest (`<repository>:<tag>@sha256:<64 hex>`);
# verified-image must hold exactly that and a line end, nothing else.
#
# Usage: tests/tailnet-real/guard.sh [COMPOSE_FILE [VERIFIED_IMAGE_FILE]]
# (default docker-compose.yml and tests/tailnet-real/verified-image of this
# checkout). Exits 0 when they agree, 1 naming the difference otherwise.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
compose="${1:-$root/docker-compose.yml}"
verified="${2:-$root/tests/tailnet-real/verified-image}"
[ $# -le 2 ] || {
  echo "usage: $0 [COMPOSE_FILE [VERIFIED_IMAGE_FILE]]" >&2
  exit 2
}

fail() {
  echo "::error::$*" >&2
  exit 1
}

[ -f "$compose" ] || fail "no compose file at $compose"
[ -f "$verified" ] || fail "no verified-image at $verified: run tests/tailnet-real/run.sh against a real tailnet to write it"

image="$(awk '
  /^  tailscale:[[:space:]]*$/ { in_service = 1; next }
  in_service && /^  [^ #]/ { exit }
  in_service && /^    image:/ { sub(/^    image:[[:space:]]*/, ""); print; exit }
' "$compose")"
[ -n "$image" ] || fail "$compose's tailscale service names no image"
[[ "$image" =~ ^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]] ||
  fail "$compose's tailscale image '$image' is not a reference by tag and digest (<repository>:<tag>@sha256:<64 hex>)"

# One line: the reference and its line end are every byte of the file.
recorded="$(cat "$verified")"
[ -n "$recorded" ] && [ "$(wc -l <"$verified")" -eq 1 ] &&
  [ "$(printf '%s\n' "$recorded" | LC_ALL=C wc -c)" -eq "$(LC_ALL=C wc -c <"$verified")" ] ||
  fail "$verified is not one line holding an image reference"

if [ "$recorded" != "$image" ]; then
  fail "docker-compose.yml's tailscale image is $image, but the reference a real tailnet last verified (tests/tailnet-real/verified-image) is $recorded. The Compose proof's stand-in certifies no Tailscale binary: run tests/tailnet-real/run.sh against a real tailnet with this image, which writes verified-image on a pass, or keep the verified reference."
fi
echo "ok: the tailscale image docker-compose.yml names is the one a real tailnet verified: $image"
