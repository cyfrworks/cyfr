#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The dependencies of a stage's build folders, which scripts/stage.sh runs
# from the worktree's root before any row that names a folder:
#   scripts/lib/stage-deps.sh FOLDER...
#
# FOLDER is dev, dev_pg, test or test_pg, the stage's build folders in the
# order its table first names them. A tree with no mix.lock has no
# dependencies to prepare, and the script does nothing there. It holds the
# worktree's lock (the file cyfr-deps.lock in the worktree's own Git
# directory) throughout, so two stages of one worktree take turns, and a
# stage of another worktree never waits for it. Under the lock:
#   1. The fetch. When deps/.cyfr-fetched does not hold mix.lock's Git
#      object id, the stamp goes before anything under deps/ changes, then
#      `mix deps.get`, then scripts/fetch-prebuilt-binaries.sh, contained
#      and held to 1800 s together, and the id is written there only once
#      both have passed: a fetch stopped or failed part way leaves no
#      stamp, so the next stage fetches again. The fetch takes no quarter
#      of the machine: it waits on the network, not the processors.
#   2. With two folders or more, the compile. Each folder whose stamp,
#      _build/<folder>/.cyfr-deps, does not hold that id, or is older than
#      an entry of deps/ or of a dependency's folder in it, has its
#      dependencies compiled (`mix deps.loadpaths` under the folder's build
#      path, adapter and MIX_ENV), in turn, whatever the one before ended
#      with, on one quarter (scripts/heavy-check.sh, running this
#      script with --compile), and its stamp is written once its compile
#      has passed. A dependency's
#      own compile writes under deps/, which every folder shares (erlex's
#      generated parser), so two cold builds started together race there.
#      One folder needs no turn: its first row compiles what it lacks.
#   3. With a test folder (test or test_pg), the runner. Those rows run
#      the runtime's suites, whose keeper runs the runner program this
#      checkout built and refuses a pair (the binary and its stamp) that
#      is missing or not the checkout's (scripts/runner.sh pair). Such a
#      pair is built (scripts/runner.sh build) on one quarter, held to
#      1800 s, before any row runs; one already current is kept. A host
#      without cargo builds none and says so, and those suites then refuse
#      to start. A tree without the runner's crate has no pair to prepare.
# Warm, it starts no BEAM and takes no quarter. A fetch run by hand changes
# deps/, so the stamps it leaves older send each folder through the compile
# again, which finds nothing to do. Its waits, for the worktree's lock and
# for a quarter, have no deadline, as the queue's waits have none; the
# work does: the fetch's hold and the compile's ticket's.
#
# Exits 0 when everything passed or there was nothing to prepare, 1 when
# the fetch, a compile or the runner's build failed, 124 when the fetch reached its hold, 64
# on usage, 69 without flock(1) or outside a Git checkout, and 130, 143
# and 129 on INT, TERM and HUP, once what it started has stopped.
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
[ -f mix.lock ] || { echo '==> no mix.lock: no dependencies to prepare'; exit 0; }
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
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=contain.sh
. "$here/contain.sh" || exit 69
compiling=
stop() {
  trap '' INT TERM HUP
  if [ -n "$compiling" ]; then kill -TERM "$compiling" 2>/dev/null; wait "$compiling" 2>/dev/null; fi
  contain_stop_all 30 || :
  exit "$1"
}
trap 'stop 130' INT
trap 'stop 143' TERM
trap 'stop 129' HUP
lock=$(git rev-parse --path-format=absolute --git-path cyfr-deps.lock 2>/dev/null) ||
  { echo 'stage-deps: this is not a Git checkout' >&2; exit 69; }
exec 9>>"$lock" || exit 69
flock 9 || exit 1

if [ "$(cat deps/.cyfr-fetched 2>/dev/null)" != "$id" ]; then
  echo '==> fetch'
  rm -f deps/.cyfr-fetched || exit 1
  contain_start bash -c 'mix deps.get && scripts/fetch-prebuilt-binaries.sh' </dev/null || exit 1
  contain_wait "$CONTAIN_PID" 1800 30
  s=$?
  [ "$s" != 124 ] || echo '==> the fetch reached its hold of 1800 s and was stopped'
  [ "$s" = 0 ] || exit "$s"
  printf '%s\n' "$id" >deps/.cyfr-fetched || exit 1
fi
for folder in "$@"; do
  [ -f apps/locus/runner/Cargo.toml ] || break
  case $folder in
    test | test_pg)
      if scripts/runner.sh pair >/dev/null 2>&1; then
        echo '==> runner: warm'
      elif ! PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH" command -v cargo >/dev/null 2>&1; then
        echo '==> runner: no cargo on PATH, so no pair is built; the runtime suites refuse to start without it'
      else
        echo '==> runner'
        # In the background, so a signal reaches its trap while it queues
        # or runs.
        scripts/heavy-check.sh -t 1800 -- env PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH" scripts/runner.sh build 9>&- &
        compiling=$!
        wait "$compiling" || exit 1
        compiling=
      fi
      break
      ;;
  esac
done
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
# In the background, so a signal reaches its trap while the compile
# queues or runs.
scripts/heavy-check.sh -t 1800 -- bash scripts/lib/stage-deps.sh --compile "${stale[@]}" 9>&- &
compiling=$!
wait "$compiling"
