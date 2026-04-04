#!/usr/bin/env bash
set -euo pipefail

# Defaults
CARGO_VERSION="0.21.1"
NODE_VERSION="24.14.1"

usage() {
  echo "Usage: $0 <image-tag> [--cargo <version>] [--node <version>]"
  echo ""
  echo "Arguments:"
  echo "  <image-tag>   Image tag (required, e.g. 1.0.0)"
  echo ""
  echo "Options:"
  echo "  --cargo       cargo-component version (default: $CARGO_VERSION)"
  echo "  --node        Node.js version (default: $NODE_VERSION)"
  exit 1
}

if [[ $# -lt 1 || "$1" == -* ]]; then
  echo "Error: image tag is required as first argument"
  usage
fi

TAG="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cargo) CARGO_VERSION="$2"; shift 2 ;;
    --node)  NODE_VERSION="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

IMAGE="ghcr.io/cyfrworks/cyfr-runner-base:${TAG}"

echo "Building and pushing multi-platform runner base image: ${IMAGE}"
echo "  cargo-component: ${CARGO_VERSION}"
echo "  node: ${NODE_VERSION}"
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg CARGO_COMPONENT_VERSION="${CARGO_VERSION}" \
    --build-arg NODE_VERSION="${NODE_VERSION}" \
    -f Dockerfile.runner-base \
    -t "${IMAGE}" \
    --push .

echo ""
echo "Pushed: ${IMAGE}"
