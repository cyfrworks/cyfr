#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Compose proof's teardown (tests/compose-proof/cleanup.sh) against
# stand-ins for docker and compose, with no Docker: a removal that keeps
# failing fails a run whose cases passed, naming the project it leaves,
# the run's Tailscale stand-in image among them; one that fails and then
# succeeds within its three attempts does not; the reach engine's join
# containers and its join network go too; a failed run keeps its own
# status; a clean run removes its scratch directory and exits 0.
#
# Usage: bash tests/compose-proof/cleanup-test.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/cyfr-compose-cleanup-test.XXXXXX") || {
  echo "FAIL: cannot create a temporary directory"
  exit 1
}
trap 'rm -rf "$scratch"' EXIT

failures=0
cases=0

# Runs one teardown: the run exits `$1` with its cleanup trapped, the
# compose stand-in failing its first `$2` calls and the docker stand-in its
# first `$3` of each kind (`docker image` its first `$4`, default `$3`);
# with `$5` set, the docker stand-in lists two join containers of the
# project. Leaves the status in $code, stderr in $scratch/err and every
# call in $scratch/calls.
teardown() {
  local status="$1" compose_fails="$2" docker_fails="$3" image_fails="${4:-$3}" joins="${5:-}"
  rm -rf "$scratch/work" "$scratch/calls" "$scratch/err"
  mkdir -p "$scratch/work"
  : >"$scratch/calls"
  COMPOSE_FAILS="$compose_fails" DOCKER_FAILS="$docker_fails" IMAGE_FAILS="$image_fails" JOINS="$joins" \
    CALLS="$scratch/calls" WORK="$scratch/work" CLEANUP="$here/cleanup.sh" STATUS="$status" COMPOSE_PROOF_CLEANUP_PAUSE=0 \
    bash -c '
      set -euo pipefail
      RUN=cyfr-compose-proof-test IMAGE=cyfr:compose-proof UPSTREAM=cyfr-compose-proof-test-upstream
      STANDIN_IMAGE=cyfr-tailscale-standin:cyfr-compose-proof-test
      # Each stand-in fails while fewer calls than its budget were made.
      stand_in() {
        local name="$1" budget="$2"
        echo "$name" >>"$CALLS"
        [ "$(grep -c "^$name\$" "$CALLS")" -gt "$budget" ] || { echo "$name: refused" >&2; return 1; }
      }
      compose() { [ "$1" = logs ] && return 0; stand_in "compose $1" "$COMPOSE_FAILS"; }
      docker() {
        case "$1" in
          image) stand_in "docker image" "$IMAGE_FAILS" ;;
          ps)
            echo "docker ps" >>"$CALLS"
            [ -z "$JOINS" ] || printf "join-one\njoin-two\n"
            ;;
          rm) stand_in "docker rm" "$DOCKER_FAILS" && echo "docker rm ${*: -1}" >>"$CALLS" ;;
          *) stand_in "docker $1" "$DOCKER_FAILS" ;;
        esac
      }
      . "$CLEANUP"
      trap cleanup EXIT
      exit "$STATUS"
    ' >/dev/null 2>"$scratch/err"
  code=$?
}

check() {
  cases=$((cases + 1))
  if [ "$2" = ok ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    echo "  exit: $code"
    sed 's/^/  call: /' "$scratch/calls"
    sed 's/^/  stderr: /' "$scratch/err"
    failures=$((failures + 1))
  fi
}

calls() { grep -c "^$1\$" "$scratch/calls"; }

teardown 0 99 0
if [ "$code" -ne 0 ] && [ "$(calls 'compose down')" = 3 ] &&
  grep -q 'docker compose down --volumes failed three times, leaving the project cyfr-compose-proof-test on this host: compose down: refused' "$scratch/err"; then
  check "a down that keeps failing fails a passed run after three attempts, naming the project" ok
else
  check "a down that keeps failing fails a passed run after three attempts, naming the project" no
fi

teardown 0 0 99
if [ "$code" -ne 0 ] && [ "$(calls 'docker rm')" = 3 ] &&
  grep -q 'docker rm --force cyfr-compose-proof-test-upstream failed three times, leaving the project cyfr-compose-proof-test' "$scratch/err"; then
  check "an upstream that cannot be removed fails a passed run, naming the project" ok
else
  check "an upstream that cannot be removed fails a passed run, naming the project" no
fi

teardown 0 2 1
if [ "$code" -eq 0 ] && [ "$(calls 'compose down')" = 3 ] && [ "$(calls 'docker rm')" = 2 ] &&
  [ ! -e "$scratch/work" ] && [ ! -s "$scratch/err" ]; then
  check "a removal that succeeds within its three attempts passes" ok
else
  check "a removal that succeeds within its three attempts passes" no
fi

teardown 3 99 0
if [ "$code" -eq 3 ] && grep -q 'leaving the project cyfr-compose-proof-test' "$scratch/err"; then
  check "a failed run keeps its own status and still names what it left" ok
else
  check "a failed run keeps its own status and still names what it left" no
fi

teardown 0 0 0
if [ "$code" -eq 0 ] && [ "$(calls 'compose down')" = 1 ] && [ "$(calls 'docker rm')" = 1 ] &&
  [ "$(calls 'docker run')" = 1 ] && [ "$(calls 'docker image')" = 1 ] && [ ! -e "$scratch/work" ]; then
  check "a clean run tears down once, its stand-in image with it, and removes its scratch directory" ok
else
  check "a clean run tears down once, its stand-in image with it, and removes its scratch directory" no
fi

teardown 0 0 0 99
if [ "$code" -ne 0 ] && [ "$(calls 'docker image')" = 3 ] &&
  grep -q 'docker image rm cyfr-tailscale-standin:cyfr-compose-proof-test failed three times, leaving the project cyfr-compose-proof-test' "$scratch/err"; then
  check "a stand-in image that cannot be removed fails a passed run, naming the project" ok
else
  check "a stand-in image that cannot be removed fails a passed run, naming the project" no
fi

teardown 0 0 0 0 joins
if [ "$code" -eq 0 ] && [ "$(calls 'docker rm join-one')" = 1 ] && [ "$(calls 'docker rm join-two')" = 1 ] &&
  [ "$(calls 'docker network')" -ge 1 ]; then
  check "the reach engine's join containers and its join network go with the project" ok
else
  check "the reach engine's join containers and its join network go with the project" no
fi

echo "$cases cases, $failures failed"
[ "$failures" -eq 0 ]
