#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Refuse a :cyfr configuration key read both at compile time and at runtime: scripts/ci/config-seam.sh
#
# A key read with `Application.compile_env(:cyfr, :key ...)` and also with
# `get_env`, `fetch_env`, `fetch_env!` or `put_env` keeps two values, one
# of which is stale. An intentional compile-time read is exempt only when
# `config:compile-runtime-ok` sits on that read's own line or in the
# comment block that ends on the line directly above it. A blank line or a
# line of code ends the block, so a marker elsewhere in the file exempts
# nothing, and of two reads on consecutive lines only the first is exempt.
#
# Exit 0 when clean, 1 naming each offending key with the file:line of its
# unexempt compile-time reads and its runtime reads on stderr, 64 when
# given any argument.
set -euo pipefail

usage() { echo "usage: $0" >&2; }

[ "$#" -eq 0 ] || { usage; exit 64; }

# The pathspecs are relative to the root, so a run from a subdirectory
# gives the root's result.
top=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "config-seam: not inside a git work tree" >&2
  exit 1
}
cd "$top"

marker='config:compile-runtime-ok'
sources=('apps/**/*.ex' 'apps/**/*.exs')

# git grep exits 1 when nothing matches; that is an answer, not a failure.
search() {
  git grep "$@" && return 0
  local status=$?
  [ "$status" -eq 1 ] && return 0
  echo "config-seam: git grep failed with status $status" >&2
  exit 1
}

keys=$(search -hoE 'compile_env\(:cyfr, *:[a-z_0-9]+' -- "${sources[@]}" | sed 's/.*:cyfr, *://' | sort -u)
# A scan that finds no compile-time key reads nothing; refuse it.
if [ -z "$keys" ]; then
  echo "::error::no compile_env reads matched — the scan would check nothing" >&2
  exit 1
fi

# Prints FILE:LINE for each listed line of FILE that is not exempt.
unexempt() {
  awk -v want="$2" -v marker="$marker" '
    BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) target[w[i]] = 1 }
    {
      if ((FNR "") in target && !index($0, marker) && !(inblock && marked)) print FILENAME ":" FNR
      if ($0 ~ /^[ \t]*#/) {
        if (!inblock) marked = 0
        inblock = 1
        if (index($0, marker)) marked = 1
      } else {
        inblock = 0
        marked = 0
      }
    }
  ' "$1"
}

failures=""
while IFS= read -r key; do
  reads=$(search -nE "compile_env\(:cyfr, *:${key}[^a-z_0-9]" -- "${sources[@]}" | cut -d: -f1-2)
  untagged=""
  while IFS= read -r file; do
    lines=$(printf '%s\n' "$reads" | awk -F: -v f="$file" '$1 == f { printf "%s ", $2 }')
    untagged="$untagged$(unexempt "$file" "$lines")"$'\n'
  done <<< "$(printf '%s\n' "$reads" | cut -d: -f1 | sort -u)"
  untagged=$(printf '%s' "$untagged" | sed '/^$/d')
  [ -n "$untagged" ] || continue

  runtime=$(search -nE "Application\.(get_env|fetch_env!?|put_env)\(:cyfr, *:${key}[^a-z_0-9]" -- "${sources[@]}" | cut -d: -f1-2)
  [ -n "$runtime" ] || continue

  failures="$failures::error::config key :${key} is read with compile_env AND at runtime — one of them will be stale"$'\n'
  failures="$failures$(printf '%s\n' "$untagged" | sed 's/$/: compile_env read with no exemption/')"$'\n'
  failures="$failures$(printf '%s\n' "$runtime" | sed 's/$/: runtime read/')"$'\n'
done <<< "$keys"

if [ -n "$failures" ]; then
  printf '%s' "$failures" >&2
  echo "Read the key one way, or mark each compile_env read of it with # config:compile-runtime-ok and the reason, on the read's line or in the comment block directly above it." >&2
  exit 1
fi
