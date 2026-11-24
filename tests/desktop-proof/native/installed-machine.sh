#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Each executable an installed package put on the machine is built for the
# package's architecture, read from the file's own header and never by
# running it: an x64 app in an Arm package runs under Windows' or macOS'
# emulation and passes a smoke, and is refused here. ELF (Linux), Mach-O
# (macOS, one architecture a file) and PE (Windows) are read; any other
# file, a universal Mach-O among them, is refused. Release runs it on the
# app's executable and its bundled cyfr after each install, as Codex CI's
# desktop-native does.
#
# Usage: bash tests/desktop-proof/native/installed-machine.sh amd64|arm64 FILE...
set -euo pipefail

[ "$#" -ge 2 ] && { [ "$1" = amd64 ] || [ "$1" = arm64 ]; } || {
  echo "usage: bash $0 amd64|arm64 FILE..." >&2; exit 64; }
want=$1
shift

# The N bytes at OFFSET of FILE as one lowercase hex string, in file order.
bytes() { od -An -v -tx1 -j "$2" -N "$3" -- "$1" | tr -d ' \n'; }
# The little-endian number those bytes spell, as hex.
le() { local h=$1 out=""; while [ -n "$h" ]; do out="$out${h: -2}"; h=${h%??}; done; printf '%s' "$out"; }

machine() {
  local f=$1 magic
  magic=$(bytes "$f" 0 4)
  case "$magic" in
    7f454c46)
      case "$(le "$(bytes "$f" 18 2)")" in
        003e) echo amd64 ;; 00b7) echo arm64 ;; *) echo "ELF machine 0x$(le "$(bytes "$f" 18 2)")" ;;
      esac ;;
    cffaedfe)
      case "$(le "$(bytes "$f" 4 4)")" in
        01000007) echo amd64 ;; 0100000c) echo arm64 ;; *) echo "Mach-O CPU 0x$(le "$(bytes "$f" 4 4)")" ;;
      esac ;;
    4d5a*)
      local pe
      pe=$((16#$(le "$(bytes "$f" 60 4)")))
      if [ "$(bytes "$f" "$pe" 4)" != 50450000 ]; then echo "an MZ file with no PE header"; return; fi
      case "$(le "$(bytes "$f" $((pe + 4)) 2)")" in
        8664) echo amd64 ;; aa64) echo arm64 ;; *) echo "PE machine 0x$(le "$(bytes "$f" $((pe + 4)) 2)")" ;;
      esac ;;
    cafebabe | bebafeca) echo "a universal Mach-O" ;;
    *) echo "no executable header (${magic:-empty})" ;;
  esac
}

failed=0
for f in "$@"; do
  if [ ! -f "$f" ]; then
    echo "::error::$f is not a file"; failed=1; continue
  fi
  got=$(machine "$f")
  if [ "$got" = "$want" ]; then
    echo "$f is built for $want"
  else
    echo "::error::$f is built for $got, not $want"; failed=1
  fi
done
exit "$failed"
