#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The dependencies of a stage's build folders, which scripts/stage.sh runs
# from the worktree's root before any row that names a folder:
#   scripts/lib/stage-deps.sh FOLDER...
#
# FOLDER is dev, dev_pg, test or test_pg, the stage's build folders in the
# order its table first names them. It holds the worktree's lock (the file
# cyfr-deps.lock in the worktree's own Git directory) throughout, so two
# stages of one worktree take turns, and a stage of another worktree never
# waits for it. Under the lock:
#   1. The fetch. When deps/.cyfr-fetched does not hold mix.lock's Git
#      object id, `mix deps.get`, then scripts/fetch-prebuilt-binaries.sh,
#      then the id is written there. The fetch takes no quarter of the
#      machine: it waits on the network, not the processors.
#   2. With two folders or more, the compile. Each folder whose stamp,
#      _build/<folder>/.cyfr-deps, does not hold that id, or is older than
#      an entry of deps/ or of a dependency's folder in it, has its
#      dependencies compiled (`mix deps.loadpaths` under the folder's build
#      path, adapter and MIX_ENV), in turn, whatever the one before ended
#      with, on one quarter (scripts/heavy-check.sh -q 1, running this
#      script with --compile), and its stamp is written once its compile
#      has passed. A dependency's
#      own compile writes under deps/, which every folder shares (erlex's
#      generated parser), so two cold builds started together race there.
#      One folder needs no turn: its first row compiles what it lacks.
# Warm, it starts no BEAM and takes no quarter. A fetch run by hand changes
# deps/, so the stamps it leaves older send each folder through the compile
# again, which finds nothing to do.
#
# Exits 0 when everything passed, 1 when the fetch or a compile failed, 64
# on usage and 69 without mix.lock or flock(1), or outside a Git checkout.
set -uo pipefail

usage() { echo "usage: $0 [--compile] dev|dev_pg|test|test_pg..." >&2; exit 64; }
compile=false
if [ "${1:-}" = --compile ]; then compile=true; shift; fi
[ "$#" -ge 1 ] || usage
build_env() { # FOLDER: the env words of its build
  case $1 in
    dev) echo 'CYFR_DATABASE=sqlite MIX_ENV=dev' ;;
    dev_pg) echo 'MIX_BUILD_PATH=_build/dev_pg CYFR_DATABASE=postgres MIX_ENV=dev' ;;
    test) echo 'MIX_BUILD_PATH=_build/test CYFR_DATABASE=sqlite MIX_ENV=test' ;;
    test_pg) echo 'MIX_BUILD_PATH=_build/test_pg CYFR_DATABASE=postgres MIX_ENV=test' ;;
    *) return 1 ;;
  esac
}
for folder in "$@"; do build_env "$folder" >/dev/null || usage; done
[ -f mix.lock ] || { echo 'stage-deps: there is no mix.lock here' >&2; exit 69; }
id=$(git hash-object mix.lock) || { echo 'stage-deps: Git cannot read mix.lock' >&2; exit 69; }

if $compile; then
  # Each folder compiles whatever an earlier one ended with, and only one
  # that passed is stamped.
  s=0
  for folder in "$@"; do
    echo "==> $folder"
    # The build env words are this script's own, never a caller's.
    # shellcheck disable=SC2046
    if env $(build_env "$folder") mix deps.loadpaths; then
      mkdir -p "_build/$folder" && printf '%s\n' "$id" >"_build/$folder/.cyfr-deps" || s=1
    else
      s=1
    fi
  done
  exit "$s"
fi

command -v flock >/dev/null 2>&1 || { echo 'stage-deps: flock is required (util-linux; on macOS: brew install flock)' >&2; exit 69; }
lock=$(git rev-parse --path-format=absolute --git-path cyfr-deps.lock 2>/dev/null) ||
  { echo 'stage-deps: this is not a Git checkout' >&2; exit 69; }
exec 9>>"$lock" || exit 69
flock 9 || exit 1

if [ "$(cat deps/.cyfr-fetched 2>/dev/null)" != "$id" ]; then
  echo '==> fetch'
  mix deps.get && scripts/fetch-prebuilt-binaries.sh || exit 1
  printf '%s\n' "$id" >deps/.cyfr-fetched || exit 1
fi
[ "$#" -ge 2 ] || exit 0
stale=()
for folder in "$@"; do
  stamp=_build/$folder/.cyfr-deps
  if [ "$(cat "$stamp" 2>/dev/null)" = "$id" ] && [ -z "$(find deps -mindepth 1 -maxdepth 2 -newer "$stamp" -print -quit)" ]; then
    echo "==> $folder: warm"
  else
    stale+=("$folder")
  fi
done
[ "${#stale[@]}" -gt 0 ] || exit 0
scripts/heavy-check.sh -q 1 -t 1800 -- bash scripts/lib/stage-deps.sh --compile "${stale[@]}" 9>&-
