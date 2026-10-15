#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Publishes one release's multi-arch manifest from the digests its own run
# pushed, never from a tag another run can move.
#
# Usage: scripts/ci/merge-image.sh IMAGE VERSION DIGEST DIGEST
#
# Each DIGEST is one platform's build as pushed: an index holding the
# platform image and its provenance attestation, or a bare image manifest.
# Together they must be exactly one linux/amd64 and one linux/arm64 image.
# The script creates IMAGE:VERSION alone from IMAGE@DIGEST for both and
# reads it back through that tag, never :latest, which a later release
# moves. The manifests the index lists, with their platforms, must be
# exactly the ones the given digests hold: one missing, added or moved to
# another platform fails the script, prints nothing and leaves :latest
# where it was. Only the verified index moves :latest, by its digest, and
# its digest is printed on stdout, the one the attestation names.
#
# Exit status: 0 published, 1 the platforms, the published manifest or
# :latest are not the ones given, 64 usage, 69 docker buildx or jq missing.
set -euo pipefail

usage() {
  echo "usage: $0 IMAGE VERSION DIGEST DIGEST" >&2
  exit 64
}

[ "$#" -eq 4 ] || usage
image=$1
version=$2
shift 2

# IMAGE is a repository: no tag on its last component, no digest.
case "$image" in
  '' | *[[:space:]]* | *@* ) usage ;;
esac
case "${image##*/}" in
  *:* ) usage ;;
esac
# The version tag is the attested name; it is never the moving one.
if ! [[ "$version" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || [ "$version" = latest ]; then
  usage
fi
for digest in "$@"; do
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
done

command -v jq > /dev/null || { echo "$0: jq is required" >&2; exit 69; }
docker buildx version > /dev/null 2>&1 || { echo "$0: docker buildx is required" >&2; exit 69; }

# A descriptor's platform as os/architecture[/variant].
platform='"\(.os)/\(.architecture)" + (if .variant then "/\(.variant)" else "" end)'

# The manifests the new index must list, each with its platform: an
# index's own entries, or a bare manifest with its config's platform.
given=$(
  for digest in "$@"; do
    raw=$(docker buildx imagetools inspect --raw "$image@$digest")
    if jq -e '.manifests | type == "array"' <<< "$raw" > /dev/null; then
      jq -r ".manifests[] | \"\\(.digest) \\(.platform | $platform)\"" <<< "$raw"
    else
      config=$(docker buildx imagetools inspect "$image@$digest" --format '{{json .Image}}')
      jq -r "\"$digest \\($platform)\"" <<< "$config"
    fi
  done | sort -u
)

platforms=$(awk '$2 != "unknown/unknown" { print $2 }' <<< "$given" | sort | tr '\n' ' ')
if [ "$platforms" != "linux/amd64 linux/arm64 " ]; then
  echo "$0: the digests given hold the platforms [ $platforms], not one linux/amd64 and one linux/arm64" >&2
  exit 1
fi

sources=()
for digest in "$@"; do sources+=("$image@$digest"); done
docker buildx imagetools create --tag "$image:$version" "${sources[@]}" >&2

# One read gives both the digest printed and the list checked, so they
# describe the same manifest.
manifest=$(docker buildx imagetools inspect "$image:$version" --format '{{json .Manifest}}')
published=$(jq -r '.digest' <<< "$manifest")
listed=$(jq -r ".manifests[]? | \"\\(.digest) \\(.platform | $platform)\"" <<< "$manifest" | sort -u)

if ! [[ "$published" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "$0: $image:$version has no manifest digest" >&2
  exit 1
fi
if [ "$listed" != "$given" ]; then
  echo "$0: $image:$version ($published) is not the manifest of the digests given" >&2
  echo "  given:" $given >&2
  echo "  listed:" $listed >&2
  exit 1
fi

# By digest, so :latest names the index just verified whatever the version
# tag names by now.
docker buildx imagetools create --tag "$image:latest" "$image@$published" >&2
latest=$(docker buildx imagetools inspect "$image:latest" --format '{{json .Manifest}}' | jq -r '.digest')
if [ "$latest" != "$published" ]; then
  echo "$0: $image:latest names $latest, not the published $published" >&2
  exit 1
fi

echo "$published"
