#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The scaffold `cyfr init` extracts: scripts/scaffold-tarball.sh OUTPUT [VERSION CYFR_DIGEST LOCUS_DIGEST]
#
# With OUTPUT alone (default cyfr-scaffold.tar.gz) the tarball carries the
# repository's docker-compose.yml as it is. A release passes the version
# and the merged multi-arch digests of the two images it published: the
# tarball's docker-compose.yml then names every cyfr image as
# ghcr.io/cyfrworks/cyfr:VERSION@CYFR_DIGEST and every cyfr-locus image as
# ghcr.io/cyfrworks/cyfr-locus:VERSION@LOCUS_DIGEST, and the script fails
# unless every image line of it names a digest, so a project pulls exactly
# the images its release published and signed in release.json. The
# substitution works on a staged copy; the repository's file is never
# modified. VERSION is a release version by the one rule
# tests/fixtures/release_manifest.json's versions hold (MAJOR.MINOR.PATCH,
# or with a SemVer pre-release such as 0.6.0-alpha.1) and each digest
# sha256:<64 lowercase hex>; any other argument form is refused with 64
# before anything is written.
set -euo pipefail
# Byte by byte: under another locale [A-Za-z] can admit letters outside
# ASCII.
export LC_ALL=C
RELEASE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$'

usage() {
  echo "usage: $0 OUTPUT [VERSION CYFR_DIGEST LOCUS_DIGEST]" >&2
  exit 64
}

VERSION="" CYFR_DIGEST="" LOCUS_DIGEST=""
case "$#" in
  0 | 1) ;;
  4)
    VERSION=$2 CYFR_DIGEST=$3 LOCUS_DIGEST=$4
    [[ "$1" != "" ]] || usage
    [[ "$VERSION" =~ $RELEASE ]] || usage
    [[ "$CYFR_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
    [[ "$LOCUS_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
    ;;
  *) usage ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
OUTPUT="${1:-cyfr-scaffold.tar.gz}"

ITEMS=(
  configuration-guide.md component-guide.md tincture-guide.md integration-guide.md
  identity-guide.md devices-guide.md
  LICENSE LICENSES/ FAIR_SOURCE.md
  wit/
  # Package deployment files for cyfr init: the app, the runtime, the
  # backends service, TLS proxy and optional builds profile. Every image is
  # pulled as published.
  docker-compose.yml Caddyfile .env.example
  # One example per env file docker-compose.yml names beside .env.
  .env.locus.example
)
# The keeper's seccomp profile, which docker-compose.yml's locus-runtime service
# names as ./keeper.seccomp.json, ships beside it under that name.
PROFILE=apps/locus/keeper/seccomp/keeper.json
PROFILE_NAME=keeper.seccomp.json
# Every item is shipped or the script fails: a file renamed or removed
# without this list following must not leave the tarball quietly short.
MISSING=()
for item in "${ITEMS[@]}" "$PROFILE"; do
  [ -e "$item" ] || MISSING+=("$item")
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: scaffold items missing: ${MISSING[*]}" >&2
  exit 1
fi

# The AQUA template ships under its operator-project name `aqua/` (the
# codex scaffold contract) while living at seed/aqua in this repo.
[ -d seed/aqua ] || { echo "Error: seed/aqua missing" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$PROFILE" "$STAGE/$PROFILE_NAME"

TAR_ITEMS=("${ITEMS[@]}")
if [ -n "$VERSION" ]; then
  # The repository match is exact: `cyfr:` is never read as a prefix of
  # `cyfr-locus:`, and whatever tag or digest a line names is replaced.
  awk -v version="$VERSION" -v cyfr="$CYFR_DIGEST" -v locus="$LOCUS_DIGEST" \
    -v counts="$STAGE/counts" '
    match($0, /^[[:space:]]*image:[[:space:]]*/) {
      lead = substr($0, 1, RLENGTH)
      ref = substr($0, RLENGTH + 1)
      if (ref ~ /^ghcr\.io\/cyfrworks\/cyfr:[^[:space:]]+[[:space:]]*$/) {
        $0 = lead "ghcr.io/cyfrworks/cyfr:" version "@" cyfr
        substituted_cyfr++
      } else if (ref ~ /^ghcr\.io\/cyfrworks\/cyfr-locus:[^[:space:]]+[[:space:]]*$/) {
        $0 = lead "ghcr.io/cyfrworks/cyfr-locus:" version "@" locus
        substituted_locus++
      }
    }
    { print }
    END { print substituted_cyfr + 0, substituted_locus + 0 > counts }
  ' docker-compose.yml > "$STAGE/docker-compose.yml"
  read -r substituted_cyfr substituted_locus < "$STAGE/counts"
  if [ "$substituted_cyfr" -lt 1 ] || [ "$substituted_locus" -lt 1 ]; then
    echo "Error: docker-compose.yml names $substituted_cyfr cyfr and $substituted_locus cyfr-locus images, not at least one of each" >&2
    exit 1
  fi
  # Every image the scaffold's compose pulls is pinned: the two substituted
  # here, and the third-party ones by the digest the repository names.
  UNPINNED="$(grep -nE '^[[:space:]]*image:' "$STAGE/docker-compose.yml" |
    grep -vE '@sha256:[0-9a-f]{64}[[:space:]]*$' || true)"
  if [ -n "$UNPINNED" ]; then
    echo "Error: the scaffold's docker-compose.yml names images without a digest:" >&2
    echo "$UNPINNED" >&2
    exit 1
  fi
  # The staged copy takes the repository file's place in the archive, at
  # the root under the same name and in the same order.
  TAR_ITEMS=()
  for item in "${ITEMS[@]}"; do
    if [ "$item" = docker-compose.yml ]; then
      TAR_ITEMS+=(-C "$STAGE" docker-compose.yml -C "$REPO_ROOT")
    else
      TAR_ITEMS+=("$item")
    fi
  done
fi

tar czf "$OUTPUT" "${TAR_ITEMS[@]}" -C seed aqua -C "$STAGE" "$PROFILE_NAME"
echo "Created $OUTPUT ($(du -h "$OUTPUT" | cut -f1) compressed)"
