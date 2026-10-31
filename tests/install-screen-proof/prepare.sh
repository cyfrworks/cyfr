#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Prepares the install-and-screen proof on this host outside any queue
# lane, so a run holding the proof lane neither downloads nor builds:
#
#   tests/install-screen-proof/prepare.sh             the base image, then the proof image
#   tests/install-screen-proof/prepare.sh --tag-only  prints the proof image's tag
#   tests/install-screen-proof/prepare.sh --use PID   prints it, recording PID's use
#
# Run it before tests/install-screen-proof/run.sh, which refuses (69)
# without the base image's cache or the proof image. It runs on the host
# itself and takes no lane: it downloads and builds, and every byte it
# keeps is verified or named by the hash of its inputs.
#
# The base image. It downloads the pinned release's SHA256SUMS and
# SHA256SUMS.gpg (base-image.sh) and verifies the signature with the
# host's Ubuntu cloud image keyring (gpgv); the sum the signed file gives
# the image must be the pinned one. Then the image, resumed across dropped
# connections and given up as stalled below 100 KiB/s for 60 s, each
# attempt retried from where it stopped, at most eight; its SHA-256 must
# be the pinned sum. Only then does the whole set move into BASE_DIR, by
# one rename. It writes only under BASE_CACHE, working in
# BASE_CACHE/.fetch-<pid>, which it removes on every exit; a .fetch-<pid>
# whose process is gone, left by a killed run of this script, is removed
# when it starts. A complete BASE_DIR is kept and not fetched again. Sets
# no worktree pins any more are scripts/janitor.sh's to remove (its rule
# 7), since the cache is every worktree's. A run never writes the cache:
# it mounts BASE_DIR read-only.
#
# The proof image, the VM host whose containers run QEMU (this directory's
# Dockerfile), is shared by every worktree at the same inputs, as
# scripts/image.sh's images are. Its tag is cyfr-install-screen:in-<h>,
# where <h> is the first 20 hex digits of the SHA-256 of: for each input
# in the byte order of its path relative to this directory (the
# Dockerfile and every file under guest/), the path and a newline, then
# its mode (755 when executable, else 644), a space, the SHA-256 of its
# content and a newline; then the Docker daemon's platform (os/arch) and a
# newline. The build's context is a tar of exactly those files, read once
# for both the hash and the tar, and the image is labelled
# works.cyfr.image-inputs=<h>. Its packages are the archive's of the day
# it was built; a change of input makes another tag. The tag is checked
# for, built when absent and a --use recorded under the image's lock,
# <h>.lock in scripts/image.sh's lock directory (scripts/image.sh
# --lock-dir), with the use in <h>.uses as image.sh records its own;
# scripts/janitor.sh removes the image under the same lock, by its rule
# 2, once no worktree's prepare.sh --tag-only produces the tag, no live
# use names it, no container uses it and it is a day old.
#
# --tag-only prints the tag and does nothing else. --use PID prints the
# tag when the image exists, after recording PID's use; without the image
# it exits 69, naming this script.
#
# Needs curl, gpgv, sha256sum, python3, flock, docker and
# /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg; --tag-only and --use
# need python3 and docker, --use flock too. Without an option, stdout is
# framed `_START=<pid>` first and `_EXIT=<pid> <status>` last. Exits 0
# with both in place; 1 when a download, a verification or the build
# failed; 64 on usage; 69 without a tool or a Docker daemon, with
# BASE_CACHE on a tmpfs, or for --use without the image.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
REPOSITORY=cyfr-install-screen

usage() { echo "usage: $0 [--tag-only | --use PID]"; }
MODE=prepare USE_PID=""
case $# in
  0) ;;
  1) [ "$1" = --tag-only ] || { usage >&2; exit 64; }; MODE=tag ;;
  2) [ "$1" = --use ] || { usage >&2; exit 64; }; MODE=use USE_PID=$2 ;;
  *) usage >&2; exit 64 ;;
esac
if [ "$MODE" = use ]; then
  case $USE_PID in '' | 0* | *[!0-9]*) echo "prepare: --use takes a pid, not '$USE_PID'" >&2; exit 64 ;; esac
fi

# The image's inputs, read once: prints <h>'s whole digest, and with a
# second argument writes the build's context there as a tar.
inputs_py=$(
  cat <<'PY'
import hashlib, io, os, stat, sys, tarfile

here, platform, tar_path = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else None)


def encode(path):
    return path.encode("utf-8", "surrogateescape")


paths = ["Dockerfile"]
for directory, subdirectories, files in os.walk(os.path.join(here, "guest")):
    subdirectories.sort()
    paths += [os.path.relpath(os.path.join(directory, name), here) for name in files]
entries = []
for path in sorted(paths, key=encode):
    info = os.lstat(os.path.join(here, path))
    if not stat.S_ISREG(info.st_mode):
        sys.exit(f"prepare: {path} is not a regular file")
    with open(os.path.join(here, path), "rb") as handle:
        content = handle.read()
    entries.append((path, "755" if info.st_mode & 0o111 else "644", content))
digest = hashlib.sha256()
for path, mode, content in entries:
    digest.update(encode(path) + b"\n" + f"{mode} {hashlib.sha256(content).hexdigest()}\n".encode())
digest.update(platform.encode() + b"\n")
if tar_path:
    with tarfile.open(tar_path, "w", format=tarfile.PAX_FORMAT) as tar:
        for path, mode, content in entries:
            member = tarfile.TarInfo(path)
            member.mtime, member.mode, member.size = 0, int(mode, 8), len(content)
            tar.addfile(member, io.BytesIO(content))
print(digest.hexdigest())
PY
)

for tool in python3 docker; do
  command -v "$tool" >/dev/null 2>&1 || { echo "prepare: $tool is required" >&2; exit 69; }
done
platform=$(docker version -f '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null) || platform=
[[ $platform =~ ^[a-z0-9]+/[a-z0-9_]+$ ]] || { echo 'prepare: no Docker daemon answers (docker version)' >&2; exit 69; }

if [ "$MODE" = tag ]; then
  digest=$(python3 -I -c "$inputs_py" "$HERE" "$platform") || exit 1
  printf '%s:in-%s\n' "$REPOSITORY" "${digest:0:20}"
  exit 0
fi

command -v flock >/dev/null 2>&1 || { echo 'prepare: flock is required (util-linux)' >&2; exit 69; }
state=$("$ROOT/scripts/image.sh" --lock-dir) || exit 69
mkdir -p -m 700 "$state" || { echo "prepare: cannot make $state" >&2; exit 69; }
[ -O "$state" ] || { echo "prepare: $state belongs to another user" >&2; exit 69; }

if [ "$MODE" = use ]; then
  digest=$(python3 -I -c "$inputs_py" "$HERE" "$platform") || exit 1
  h=${digest:0:20}
  tag="$REPOSITORY:in-$h"
  exec 9>>"$state/$h.lock"
  flock 9
  if [ "$(docker image inspect -f '{{index .Config.Labels "works.cyfr.image-inputs"}}' "$tag" 2>/dev/null)" != "$h" ]; then
    echo "install-screen proof: the proof image $tag is not built; run tests/install-screen-proof/prepare.sh first, outside any lane" >&2
    exit 69
  fi
  printf '%s\n' "$USE_PID" >>"$state/$h.uses"
  exec 9>&-
  printf '%s\n' "$tag"
  exit 0
fi

printf '_START=%s\n' "$$"
# shellcheck source=base-image.sh
. "$HERE/base-image.sh"

KEYRING=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
WORK="" CONTEXT=""

finish() {
  local status=$?
  trap - EXIT
  trap '' INT TERM HUP
  if [ -n "$WORK" ]; then rm -rf -- "$WORK"; fi
  if [ -n "$CONTEXT" ]; then rm -rf -- "$CONTEXT"; fi
  printf '_EXIT=%s %s\n' "$$" "$status"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() {
  echo "::error::prepare: $*" >&2
  exit 1
}

for tool in curl gpgv sha256sum stat; do
  command -v "$tool" >/dev/null 2>&1 || { echo "prepare: $tool is required" >&2; exit 69; }
done
[ -r "$KEYRING" ] || { echo "prepare: $KEYRING is required (package ubuntu-cloudimage-keyring)" >&2; exit 69; }

mkdir -p "$BASE_CACHE" || fail "$BASE_CACHE was not made"
if [ "$(stat -f -c %T "$BASE_CACHE")" = tmpfs ]; then
  echo "prepare: $BASE_CACHE is on a tmpfs; set CYFR_PROOF_CACHE to a directory on disk" >&2
  exit 69
fi

# What a killed run of this script left.
for dir in "$BASE_CACHE"/.fetch-*; do
  [ -e "$dir" ] || continue
  pid=${dir##*/.fetch-}
  pid=${pid%.gpgv.log}
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && continue
  rm -rf -- "$dir"
done

# Whether the directory $1 holds the pinned set, verified.
verified() {
  local dir=$1 signed actual
  [ -f "$dir/SHA256SUMS" ] && [ -f "$dir/SHA256SUMS.gpg" ] && [ -f "$dir/$CLOUD_IMAGE" ] || return 1
  gpgv --keyring "$KEYRING" "$dir/SHA256SUMS.gpg" "$dir/SHA256SUMS" 2>"$dir.gpgv.log" || return 1
  signed=$(awk -v name="$CLOUD_IMAGE" '$2 == name || $2 == "*" name { print $1 }' "$dir/SHA256SUMS")
  [ "$signed" = "$CLOUD_IMAGE_SHA256" ] || { echo "prepare: the signed SHA256SUMS gives $CLOUD_IMAGE the sum ${signed:-(none)}, not the pinned one" >&2; return 1; }
  actual=$(sha256sum "$dir/$CLOUD_IMAGE" | cut -d ' ' -f 1)
  [ "$actual" = "$CLOUD_IMAGE_SHA256" ] || { echo "prepare: $dir/$CLOUD_IMAGE has the sum $actual, not the pinned one" >&2; return 1; }
}

# get URL FILE: one file, resumed across dropped or stalled connections.
get() {
  local url=$1 file=$2 attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    if curl -fsS --continue-at - --speed-limit 102400 --speed-time 60 --connect-timeout 20 \
      -w "prepare: %{url_effective} from %{remote_ip}: %{size_download} bytes at %{speed_download} B/s\n" \
      -o "$file" "$url"; then
      return 0
    fi
    echo "prepare: attempt $attempt of 8 stopped at $(stat -c %s "$file" 2>/dev/null || echo 0) bytes; resuming"
    sleep 3
  done
  return 1
}

if [ -d "$BASE_DIR" ] && verified "$BASE_DIR"; then
  echo "prepare: $BASE_DIR holds the verified set already"
else
  WORK="$BASE_CACHE/.fetch-$$"
  mkdir "$WORK" || fail "$WORK was not made"
  get "$CLOUD_RELEASE/SHA256SUMS" "$WORK/SHA256SUMS" || fail "SHA256SUMS was not downloaded"
  get "$CLOUD_RELEASE/SHA256SUMS.gpg" "$WORK/SHA256SUMS.gpg" || fail "SHA256SUMS.gpg was not downloaded"
  gpgv --keyring "$KEYRING" "$WORK/SHA256SUMS.gpg" "$WORK/SHA256SUMS" || fail "SHA256SUMS is not signed by Ubuntu's cloud image key"
  get "$CLOUD_RELEASE/$CLOUD_IMAGE" "$WORK/$CLOUD_IMAGE" || fail "$CLOUD_IMAGE was not downloaded"
  verified "$WORK" || fail "the downloaded set did not verify"
  chmod 0444 "$WORK"/*
  rm -f "$WORK.gpgv.log"
  if [ -e "$BASE_DIR" ]; then chmod -R u+w -- "$BASE_DIR"; rm -rf -- "$BASE_DIR"; fi
  mv -T "$WORK" "$BASE_DIR" || fail "the verified set was not moved to $BASE_DIR"
  WORK=""
  chmod 0555 "$BASE_DIR"
fi
rm -f "$BASE_DIR.gpgv.log"
echo "prepare: $BASE_DIR: $CLOUD_IMAGE verified, sum $CLOUD_IMAGE_SHA256"

CONTEXT=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-install-screen-context.XXXXXX") || fail "no context directory"
digest=$(python3 -I -c "$inputs_py" "$HERE" "$platform" "$CONTEXT/context.tar") || fail "the proof image's inputs were not read"
h=${digest:0:20}
tag="$REPOSITORY:in-$h"
exec 9>>"$state/$h.lock"
flock 9
if [ "$(docker image inspect -f '{{index .Config.Labels "works.cyfr.image-inputs"}}' "$tag" 2>/dev/null)" = "$h" ]; then
  said=reused
else
  docker build --platform "$platform" --label "works.cyfr.image-inputs=$h" --tag "$tag" - <"$CONTEXT/context.tar" ||
    fail "the proof image $tag did not build"
  said=built
fi
exec 9>&-
echo "prepare: $said the proof image $tag"
