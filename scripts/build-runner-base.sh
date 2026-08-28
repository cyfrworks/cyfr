#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# MANUAL-ONLY maintenance script: builds and pushes the cyfr-runner-base image
# consumed by Dockerfile's ARG RUNNER_BASE. No CI workflow rebuilds it — bump
# versions and run this by hand when the base image needs updating.
#
# The base carries runtime libraries only. Toolchains (rustup/cargo-component,
# Node) live in the builder container (Dockerfile.builder), which vendors its
# own pinned versions — the app image structurally cannot run builds.
set -euo pipefail

usage() {
  echo "Usage: $0 <image-tag>"
  echo ""
  echo "Arguments:"
  echo "  <image-tag>   Image tag (required, e.g. 2.0.0)"
  exit 1
}

if [[ $# -lt 1 || "$1" == -* ]]; then
  echo "Error: image tag is required as first argument"
  usage
fi

TAG="$1"; shift

if [[ $# -gt 0 ]]; then
  echo "Unknown option: $1"
  usage
fi

IMAGE="ghcr.io/cyfrworks/cyfr-runner-base:${TAG}"

echo "Building and pushing multi-platform runner base image: ${IMAGE}"
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -f Dockerfile.runner-base \
    -t "${IMAGE}" \
    --push .

echo ""
echo "Pushed: ${IMAGE}"
