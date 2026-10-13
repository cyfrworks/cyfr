#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Refuse changes inside a seed component version that already ships: scripts/ci/seed-guard.sh BASE
#
# A shipped version directory (the first six segments of a path under
# seed/components) is immutable between BASE and HEAD. A file in it that
# is modified (M) or changes type (T, such as a file replaced by a
# symlink) is refused; so is a file deleted from a version that HEAD still
# has, and a file added to a version that BASE already had. A whole new
# version passes, and so does retiring a whole version.
#
# Exit 0 when clean, 1 with each offending path on stderr, 64 on a usage
# error (no BASE, a BASE that is not a commit, extra arguments).
set -euo pipefail

usage() { echo "usage: $0 BASE" >&2; }

[ "$#" -eq 1 ] || { usage; exit 64; }

# Pathspecs and tree lookups are relative to the root, so a run from a
# subdirectory gives the root's result.
top=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "seed-guard: not inside a git work tree" >&2
  exit 1
}
cd "$top"

base=$(git rev-parse --verify --quiet --end-of-options "$1^{commit}") || {
  echo "seed-guard: $1 is not a commit" >&2
  usage
  exit 64
}

# A diff of a tree that is not there is empty; refuse it.
if [ -z "$(git ls-tree -r --name-only HEAD -- seed/components | head -n 1)" ]; then
  echo "::error::seed/components holds no tracked file — the check would compare nothing" >&2
  exit 1
fi

# The version directory of a path: its first six segments, or the whole
# path when it has fewer. Bash's regex matches a newline in a name too.
version_dir() {
  if [[ $1 =~ ^([^/]*/){5}[^/]* ]]; then
    printf '%s' "${BASH_REMATCH[0]}"
  else
    printf '%s' "$1"
  fi
}

# Reads `git diff --name-status -z` and prints each offending path.
classify() {
  local status path vdir
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    vdir=$(version_dir "$path")
    case "$status" in
      M | T) printf '%s\n' "$path" ;;
      # A deletion inside a version directory that still ships is a
      # mutation too; retiring the WHOLE directory is a release decision.
      D)
        if [ "$(git cat-file -t "HEAD:$vdir" 2>/dev/null)" = tree ]; then
          printf '%s\n' "$path"
        fi
        ;;
      A)
        if git rev-parse --verify --quiet "$base:$vdir" > /dev/null 2>&1; then
          printf '%s\n' "$path"
        fi
        ;;
      # No other status is expected without rename or copy detection;
      # one that appears is refused rather than passed unread.
      *) printf '%s\n' "$path" ;;
    esac
  done
}

# The rule is about paths, not file identity: the diff runs with
# --no-renames. Rename detection reports a rename under its DESTINATION
# path, so shipping a new version by copying the last one would read as
# "files removed from the version that still ships", and an in-place edit
# paired with a deletion elsewhere would read as R and escape the M rule.
# -z keeps a name git would otherwise quote (any byte outside ASCII) from
# reaching the version-directory lookups in its quoted form.
bad=$(git -c core.quotePath=false diff --no-renames --name-status -z "$base" HEAD -- 'seed/components/**' | classify) || {
  echo "seed-guard: git diff $base HEAD failed" >&2
  exit 1
}

if [ -n "$bad" ]; then
  echo "::error::files changed inside existing seed/components version directories — ship a new version instead" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi
