#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-0.21.1}"
IMAGE="ghcr.io/cyfrworks/cyfr-runner-base:${TAG}"

echo "Building runner base image: ${IMAGE}"
docker build -f Dockerfile.runner-base -t "${IMAGE}" .

echo ""
echo "Built: ${IMAGE}"
echo ""
echo "To push:"
echo "  docker push ${IMAGE}"
