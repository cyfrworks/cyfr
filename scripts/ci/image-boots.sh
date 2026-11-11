#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Proves that an image a release build loaded starts on this runner's
# architecture and answers its own health probe, before release.yml hands
# its digest to the merge: the arm64 build runs on an arm64 runner, so an
# arm64 image nothing could start never reaches a version tag.
#
# Usage: scripts/ci/image-boots.sh cyfr|cyfr-locus LOADED
#
#   cyfr        the app image with only what a boot needs (CYFR_ACCESS and a
#               fresh CYFR_SECRET_KEY_BASE), healthy by the image's own
#               HEALTHCHECK (readiness: database, cache and registries up);
#               then the cosign on its PATH, the one `Compendium.Cosign`
#               runs, run through the image's entrypoint as its user, is the
#               pinned version, and Compendium.Cosign verifies with it keyed
#               and keyless and refuses another signer (scripts/cosign.sh
#               check)
#   cyfr-locus  the Locus image as docker-compose.yml's locus-builds service
#               runs it (x-locus-role's capabilities, options and tmpfs
#               mounts) with a fresh builds key, healthy by the image's own
#               HEALTHCHECK (the builds wire's health operation)
#
# The container is the script's own and is removed however it ends; on a
# failure its log's last lines are printed. Exit status: 0 healthy, 1 not
# healthy within the bound or the check after it failed, 64 usage.
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$2" ]; then
  echo "usage: $0 cyfr|cyfr-locus LOADED" >&2
  exit 64
fi
kind=$1
image=$2
root="$(cd "$(dirname "$0")/../.." && pwd)"
name="image-boots-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT

case "$kind" in
  cyfr)
    docker run --detach --name "$name" \
      -e CYFR_ACCESS=local -e "CYFR_SECRET_KEY_BASE=$(openssl rand -hex 48)" \
      "$image" >/dev/null
    ;;
  cyfr-locus)
    docker run --detach --name "$name" --init \
      --cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add KILL \
      --security-opt no-new-privileges:true --security-opt writable-cgroups=true \
      --read-only --ipc none \
      --tmpfs /var/lib/locus/homes:mode=1733,exec,size=256m \
      --tmpfs /run/locus:uid=10001,gid=10001,mode=0700,size=16m \
      -e "LOCUS_BUILDS_KEY=$(openssl rand -hex 32)" \
      "$image" >/dev/null
    ;;
  *)
    echo "usage: $0 cyfr|cyfr-locus LOADED" >&2
    exit 64
    ;;
esac

failed() {
  echo "::error::$image ($kind) $*" >&2
  docker logs --tail 40 "$name" >&2 2>&1 || true
  exit 1
}

# The app image's start period is 60 s with a 10 s interval: healthy comes
# within a minute of a good boot; three minutes bound a slow runner.
health="" closes=$((SECONDS + 180))
while [ "$SECONDS" -lt "$closes" ]; do
  read -r state health <<<"$(docker inspect --format '{{.State.Status}} {{.State.Health.Status}}' "$name")"
  [ "$state" = running ] || failed "stopped ($state) before it was healthy"
  [ "$health" = healthy ] && break
  sleep 2
done
[ "$health" = healthy ] || failed "is ${health:-without health} after 180 s"
echo "$image ($kind) started on $(uname -m) and is healthy"

if [ "$kind" = cyfr ]; then
  "$root/scripts/cosign.sh" check "$image" docker run --rm \
    -e CYFR_ACCESS=local -e "CYFR_SECRET_KEY_BASE=$(openssl rand -hex 48)" || failed "does not verify with its cosign"
fi
