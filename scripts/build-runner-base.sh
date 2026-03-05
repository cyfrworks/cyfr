#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-0.21.1}"
IMAGE="ghcr.io/cyfrworks/cyfr-runner-base:${TAG}"

echo "Building and pushing multi-platform runner base image: ${IMAGE}"
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -f Dockerfile.runner-base \
    -t "${IMAGE}" \
    --push .

echo ""
echo "Pushed: ${IMAGE}"
