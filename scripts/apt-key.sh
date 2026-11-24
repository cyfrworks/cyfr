#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The key of Debian's archive as both images' upgrade layer reads it
# (APT_REFRESH in Dockerfile and Dockerfile.locus):
#   scripts/apt-key.sh                 read the archive, print its key
#   scripts/apt-key.sh --of FILE...    print the key of saved InRelease files
#   scripts/apt-key.sh --update KEY    inside the build: apt-get update, and
#                                      hold apt's lists to KEY
#
# The images build on debian:trixie-slim, whose sources are the suites
# trixie and trixie-updates of deb.debian.org/debian and trixie-security
# of deb.debian.org/debian-security. The key is the SHA-256 of, for each
# of those suites in that order, its codename and a newline, then the
# lines of its InRelease's SHA256 field, each with its newline. Those
# lines name every index of the suite with its hash, so the key moves
# exactly when a package in the archive does, a published fix among them,
# and not when Debian signs the same indexes again with a new Date and
# Valid-Until (trixie-updates is signed again every six hours). Each
# file is told by its Codename field, in any order; a missing suite, one
# given twice, another suite and a SHA256 field with no lines are refused.
#
# The key is the layer's cache key: a build whose key the layer cache
# holds reuses the layer, and one whose key moved builds it again on what
# the archive holds. Reading the archive takes up to five tries per file
# with curl's waits between them; one that fails names the file and exits
# 69, and there is no other key to fall back to.
#
# --update is the layer's guard, so no layer is cached under a key its
# lists were not: Debian's archive is served by a content delivery
# network, and the lists apt fetches a moment after the key was read can
# be older or newer than the key's. It runs apt-get update and compares
# the key of the lists apt fetched (APT_KEY_LISTS, by default
# /var/lib/apt/lists) with KEY, up to three times with APT_KEY_WAIT
# seconds (default 20) between, as an edge that served an old copy
# catches up, and fails naming both keys when they never agree. A KEY
# that is not 64 hexadecimal digits (0, which a local build leaves, or a
# date) is a plain cache buster: apt-get update runs once, unchecked.
#
# Exits 0; 1 when apt's lists never match KEY; 64 on usage; 65 for files
# that are not the three suites; 69 when the archive cannot be read; apt's
# own status when apt-get update fails.
set -euo pipefail

SUITES=(trixie trixie-updates trixie-security)
url_of() {
  case $1 in
    trixie-security) echo "https://deb.debian.org/debian-security/dists/$1/InRelease" ;;
    *) echo "https://deb.debian.org/debian/dists/$1/InRelease" ;;
  esac
}

usage() {
  echo "usage: $0" >&2
  echo "       $0 --of FILE..." >&2
  echo "       $0 --update KEY" >&2
  exit 64
}

# key_of FILE...: the key of the three suites' InRelease files.
key_of() {
  local file codename suite lines
  declare -A seen=()
  for file in "$@"; do
    codename=$(sed -n 's/^Codename: *//p' "$file" | head -n 1)
    case " ${SUITES[*]} " in
      *" $codename "*) ;;
      *) echo "apt-key: $file is the suite '${codename}', not one of ${SUITES[*]}" >&2; return 65 ;;
    esac
    [ -z "${seen[$codename]:-}" ] || { echo "apt-key: the suite $codename is given twice: ${seen[$codename]} and $file" >&2; return 65; }
    seen[$codename]=$file
  done
  {
    for suite in "${SUITES[@]}"; do
      [ -n "${seen[$suite]:-}" ] || { echo "apt-key: no InRelease of the suite $suite is given" >&2; return 65; }
      lines=$(sed -n '/^SHA256:/,/^[^ ]/{/^ /p}' "${seen[$suite]}")
      [ -n "$lines" ] || { echo "apt-key: ${seen[$suite]} has no SHA256 lines" >&2; return 65; }
      printf '%s\n%s\n' "$suite" "$lines"
    done
  } > "$work/keyed"
  sha256sum "$work/keyed" | cut -d' ' -f1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/apt-key.XXXXXX")
trap 'rm -rf "$work"' EXIT

case ${1:-} in
  "")
    [ "$#" -eq 0 ] || usage
    files=()
    for suite in "${SUITES[@]}"; do
      url=$(url_of "$suite")
      curl -fsS --retry 4 --retry-all-errors --retry-delay 10 --connect-timeout 20 --max-time 60 \
        -o "$work/$suite" "$url" ||
        { echo "apt-key: could not read $url from Debian's archive" >&2; exit 69; }
      files+=("$work/$suite")
    done
    key_of "${files[@]}"
    ;;
  --of)
    shift
    [ "$#" -gt 0 ] || usage
    key_of "$@"
    ;;
  --update)
    [ "$#" -eq 2 ] || usage
    want=$2
    if ! [[ $want =~ ^[0-9a-f]{64}$ ]]; then
      apt-get update
      exit 0
    fi
    lists=${APT_KEY_LISTS:-/var/lib/apt/lists}
    for try in 1 2 3; do
      apt-get update
      shopt -s nullglob
      fetched=("$lists"/*_InRelease)
      shopt -u nullglob
      got=$(key_of "${fetched[@]}") || exit $?
      [ "$got" != "$want" ] || exit 0
      echo "apt-key: apt fetched the lists of key $got, not $want (try $try of 3)" >&2
      [ "$try" = 3 ] || sleep "${APT_KEY_WAIT:-20}"
    done
    echo "apt-key: the lists apt fetched are not the ones the key $want was read from; the layer is not built on them" >&2
    exit 1
    ;;
  *) usage ;;
esac
