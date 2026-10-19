#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Builds the Compose proof's Tailscale stand-in (main.go):
#
#   build.sh image TAG              the image, on the caddy service's image
#                                   docker-compose.yml pins
#   build.sh binary OUT [MUTATION]  the program alone, for Linux on the
#                                   Docker host's architecture; MUTATION is
#                                   one name `standin mutations` prints
#
# Go builds the program on this host (the module beside this file, which
# needs nothing outside the standard library), so the image adds no
# builder image to the ones the stack pins.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

fail() {
  echo "::error::$*" >&2
  exit 1
}

# The Docker host's architecture, as Go names it.
arch() {
  local arch
  arch="$(docker version --format '{{.Server.Arch}}')" || fail "docker answered no server architecture"
  case "$arch" in
    amd64 | arm64) printf '%s\n' "$arch" ;;
    x86_64) printf 'amd64\n' ;;
    aarch64) printf 'arm64\n' ;;
    *) fail "the stand-in is not built for a $arch Docker host" ;;
  esac
}

binary() {
  local out="$1" mutation="${2:-}" goarch
  goarch="$(arch)"
  CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" \
    go build -C "$here" -trimpath -ldflags "-s -w -X main.mutation=$mutation" -o "$out" . ||
    fail "the stand-in did not build${mutation:+ with the mutation $mutation}"
}

# The image docker-compose.yml's caddy service names: the first `image:`
# key inside that service.
base() {
  local image
  image="$(awk '
    /^  caddy:[[:space:]]*$/ { in_caddy = 1; next }
    in_caddy && /^  [^ #]/ { exit }
    in_caddy && /^    image:/ { print $2; exit }
  ' "$root/docker-compose.yml")"
  [ -n "$image" ] || fail "docker-compose.yml's caddy service names no image"
  printf '%s\n' "$image"
}

image() {
  local tag="$1" context
  context="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-tailscale-standin-XXXXXX")"
  trap 'rm -rf "$context"' RETURN
  binary "$context/standin"
  cp "$here/Dockerfile" "$context/Dockerfile"
  docker build --quiet --build-arg "BASE=$(base)" -t "$tag" "$context" >/dev/null ||
    fail "the stand-in's image $tag did not build"
}

case "${1:-}" in
  image)
    [ $# -eq 2 ] || fail "usage: $0 image TAG"
    image "$2"
    ;;
  binary)
    [ $# -ge 2 ] && [ $# -le 3 ] || fail "usage: $0 binary OUT [MUTATION]"
    binary "$2" "${3:-}"
    ;;
  *) fail "usage: $0 image TAG | binary OUT [MUTATION]" ;;
esac
