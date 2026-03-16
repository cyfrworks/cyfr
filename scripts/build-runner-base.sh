#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.21.1}"
IMAGE="ghcr.io/cyfrworks/cyfr-runner-base:${VERSION}"

echo "Building and pushing multi-platform runner base image: ${IMAGE}"
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg CARGO_COMPONENT_VERSION="${VERSION}" \
    -f Dockerfile.runner-base \
    -t "${IMAGE}" \
    --push .

echo ""
echo "Pushed: ${IMAGE}"
