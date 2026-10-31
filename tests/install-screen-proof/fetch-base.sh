#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Fetches the install-and-screen proof's base image onto this host's disk,
# outside any queue lane, so a run holding the proof lane never waits on
# the network:
#
#   tests/install-screen-proof/fetch-base.sh
#
# Run it before tests/install-screen-proof/run.sh, which refuses (69)
# without the cache. It runs on the host itself, not in a container, and
# takes no lane: it is a download, and every byte it keeps is verified.
#
# It downloads the pinned release's SHA256SUMS and SHA256SUMS.gpg and
# verifies the signature with the host's Ubuntu cloud image keyring
# (gpgv); the sum the signed file gives the image must be the pinned one.
# Then the image, resumed across dropped connections and given up as
# stalled below 100 KiB/s for 60 s, each attempt retried from where it
# stopped, at most eight; its SHA-256 must be the pinned sum. Only then
# does the whole set move into BASE_DIR (base-image.sh), by one rename.
#
# Cleanup rules: it writes only under BASE_CACHE. It works in
# BASE_CACHE/.fetch-<pid>, removed on every exit; a .fetch-<pid> whose
# process is gone, left by a killed fetch, is removed when it starts. A
# complete BASE_DIR is kept and not fetched again; any other entry of
# BASE_CACHE, the set of a sum no longer pinned, is removed once the
# pinned one is in place. A run never writes the cache: it mounts BASE_DIR
# read-only.
#
# Needs curl, gpgv, sha256sum and /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg.
# Stdout is framed `_START=<pid>` first and `_EXIT=<pid> <status>` last.
# Exits 0 with the set in place; 1 when a download or a verification
# failed; 69 without a tool, or with BASE_CACHE on a tmpfs.
set -uo pipefail

printf '_START=%s\n' "$$"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=base-image.sh
. "$HERE/base-image.sh"

KEYRING=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
WORK=""

finish() {
  local status=$?
  trap - EXIT
  trap '' INT TERM HUP
  if [ -n "$WORK" ]; then rm -rf -- "$WORK"; fi
  printf '_EXIT=%s %s\n' "$$" "$status"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() {
  echo "::error::fetch-base: $*" >&2
  exit 1
}

for tool in curl gpgv sha256sum stat; do
  command -v "$tool" >/dev/null 2>&1 || { echo "fetch-base: $tool is required" >&2; exit 69; }
done
[ -r "$KEYRING" ] || { echo "fetch-base: $KEYRING is required (package ubuntu-cloudimage-keyring)" >&2; exit 69; }

mkdir -p "$BASE_CACHE" || fail "$BASE_CACHE was not made"
if [ "$(stat -f -c %T "$BASE_CACHE")" = tmpfs ]; then
  echo "fetch-base: $BASE_CACHE is on a tmpfs; set CYFR_PROOF_CACHE to a directory on disk" >&2
  exit 69
fi

# What a killed fetch left.
for dir in "$BASE_CACHE"/.fetch-*; do
  [ -d "$dir" ] || continue
  pid=${dir##*/.fetch-}
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && continue
  rm -rf -- "$dir"
done

# Whether the directory $1 holds the pinned set, verified.
verified() {
  local dir=$1 signed actual
  [ -f "$dir/SHA256SUMS" ] && [ -f "$dir/SHA256SUMS.gpg" ] && [ -f "$dir/$CLOUD_IMAGE" ] || return 1
  gpgv --keyring "$KEYRING" "$dir/SHA256SUMS.gpg" "$dir/SHA256SUMS" 2>"$dir.gpgv.log" || return 1
  signed=$(awk -v name="$CLOUD_IMAGE" '$2 == name || $2 == "*" name { print $1 }' "$dir/SHA256SUMS")
  [ "$signed" = "$CLOUD_IMAGE_SHA256" ] || { echo "fetch-base: the signed SHA256SUMS gives $CLOUD_IMAGE the sum ${signed:-(none)}, not the pinned one" >&2; return 1; }
  actual=$(sha256sum "$dir/$CLOUD_IMAGE" | cut -d ' ' -f 1)
  [ "$actual" = "$CLOUD_IMAGE_SHA256" ] || { echo "fetch-base: $dir/$CLOUD_IMAGE has the sum $actual, not the pinned one" >&2; return 1; }
}

# get URL FILE: one file, resumed across dropped or stalled connections.
get() {
  local url=$1 file=$2 attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    if curl -fsS --continue-at - --speed-limit 102400 --speed-time 60 --connect-timeout 20 \
      -w "fetch-base: %{url_effective} from %{remote_ip}: %{size_download} bytes at %{speed_download} B/s\n" \
      -o "$file" "$url"; then
      return 0
    fi
    echo "fetch-base: attempt $attempt of 8 stopped at $(stat -c %s "$file" 2>/dev/null || echo 0) bytes; resuming"
    sleep 3
  done
  return 1
}

if [ -d "$BASE_DIR" ] && verified "$BASE_DIR"; then
  echo "fetch-base: $BASE_DIR holds the verified set already"
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

# Sets of sums no longer pinned.
for entry in "$BASE_CACHE"/* "$BASE_CACHE"/.[!.]*; do
  [ -e "$entry" ] || continue
  [ "$entry" = "$BASE_DIR" ] && continue
  case ${entry##*/} in .fetch-*) continue ;; esac
  chmod -R u+w -- "$entry" 2>/dev/null
  rm -rf -- "$entry" && echo "fetch-base: removed $entry, a set no longer pinned"
done
echo "fetch-base: $BASE_DIR: $CLOUD_IMAGE verified, sum $CLOUD_IMAGE_SHA256"
