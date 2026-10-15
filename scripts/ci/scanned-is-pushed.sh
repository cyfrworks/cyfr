#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Proves that the image a release build loaded, and the scan read, is the
# image it pushed by digest.
#
# Usage: scripts/ci/scanned-is-pushed.sh LOADED REPOSITORY DIGEST
#
# LOADED is the image in the local Docker daemon; REPOSITORY@DIGEST is what
# the build pushed, a single-platform image or an index holding one
# platform image and its attestation manifest. The image IDs differ
# between Docker's image stores; the layer diff IDs do not, so equal
# layers prove one build result. An answer with no layers on either side
# is a failure, never a match.
#
# Exit status: 0 the same image, 1 a different or unreadable one, 64 usage,
# 69 docker buildx or jq missing.
set -euo pipefail

if [ "$#" -ne 3 ] || [ -z "$1" ] || [ -z "$2" ] || ! [[ "$3" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "usage: $0 LOADED REPOSITORY DIGEST" >&2
  exit 64
fi
loaded=$1
pushed="$2@$3"

command -v jq > /dev/null || { echo "$0: jq is required" >&2; exit 69; }
docker buildx version > /dev/null 2>&1 || { echo "$0: docker buildx is required" >&2; exit 69; }

# A list of one or more sha256 diff IDs, compact, or nothing.
layers() {
  jq -c 'if type == "array" and length > 0 and all(.[]; type == "string" and test("^sha256:[0-9a-f]{64}$"))
         then . else empty end'
}

scanned=$(docker image inspect --format '{{json .RootFS.Layers}}' "$loaded" | layers) || scanned=
# For an index of one platform image, .Image is that image's config; for
# more than one it is a map by platform, which has no rootfs and fails.
registry=$(docker buildx imagetools inspect "$pushed" --format '{{json .Image}}' |
  jq -c 'if type == "object" and (.rootfs | type) == "object" then .rootfs.diff_ids else null end' |
  layers) || registry=

if [ -z "$scanned" ]; then
  echo "$0: $loaded has no layers in the local daemon" >&2
  exit 1
fi
if [ -z "$registry" ]; then
  echo "$0: $pushed has no single image with layers in the registry" >&2
  exit 1
fi
if [ "$scanned" != "$registry" ]; then
  echo "$0: $pushed is not the scanned image $loaded" >&2
  echo "  scanned: $scanned" >&2
  echo "  pushed:  $registry" >&2
  exit 1
fi
