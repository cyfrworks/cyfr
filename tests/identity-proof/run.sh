#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The identity proof (README.md): `cyfr` releases started as the browser
# harness starts homes (tests/browser/harness.sh), each a SQLite cell on a
# `.test` name behind the harness's HTTPS front: the directory dir.test,
# which serves the account pages and the names beside its log, and a.test,
# a CYFR that relies on it, with the directory reached by A through a
# front of this proof's own (front.sh, cells.sh). proof.mjs drives
# Chromium through an account made at the pages, its sign-in at A, a
# second recovery code, a key removed and the account replaced with a
# code, and the account gone; this script answers its asks for the
# servers' part (`ask-N.json`, answered `answer-N.json`): A's setup token,
# what A holds, the directory down on purpose and the tombstone.
#
# Usage: tests/identity-proof/run.sh
# Writes identity-proof.json and identity-proof.md into PROOF_OUT (default:
# the scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints the
# table. Set RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run
# built; IDENTITY_PROOF_FRESHNESS (20) is A's identity_freshness_seconds.
#
# Everything it starts is removed when it ends, whether it succeeds or
# fails: the cells' servers, the directory's front container, the
# Playwright container, and the scratch directory with the run's authority
# key and A's setup token.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-identity-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
# shellcheck source=front.sh
source "$ROOT/tests/identity-proof/front.sh"
# shellcheck source=cells.sh
source "$ROOT/tests/identity-proof/cells.sh"
OUT="${PROOF_OUT:-$WORK/out}"
FRESH="${IDENTITY_PROOF_FRESHNESS:-20}"
PROOF_PID=""
SECRETS="$WORK/secrets"
mkdir -p -m 700 "$SECRETS"

# The scratch directory holds the run's authority key and the setup token,
# so it goes even when a stop fails; the asks and answers that held the
# token go from PROOF_OUT too. `server_stop` ends in `fail`, an `exit`,
# when a listener outlives its stop, so it runs in a subshell: the exit
# ends that subshell, never this trap before the removals below, and the
# stop's failure still fails the run.
cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  identity_front_stop
  jobs -p | xargs -r kill 2>/dev/null || true
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  rm -f "$OUT"/ask-* "$OUT"/answer-* 2>/dev/null || true
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

release_build

step "the run's authority and the cells"
browser_authority
DIR="$WORK/dir"
A="$WORK/a"
browser_home "$DIR" dir.test
browser_home "$A" a.test
openssl rand -hex 32 | tr -d '\n' >"$SECRETS/setup-a"

identity_directory dir.test 127.77.0.1
identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
identity_reaches_directory "$A" dir.test "CYFR_IDENTITY_FRESHNESS_SECONDS=$FRESH"
identity_env "$A" CYFR_REGISTRY_URL dir.test
identity_env "$A" CYFR_SETUP_TOKEN "$(cat "$SECRETS/setup-a")"

step "starting the directory, its front, and A"
server_start "$DIR"
identity_front_start "$DIR"
identity_start "$A"

# Each step the proof asks for (harness.sh `answer_asks`, which removes
# each ask before its answer appears).
answer_ask() {
  local ask="$1" op
  op="$(asked "$ask" op)"
  case "$op" in
    setup_token)
      ANSWER="$(python3 -c "import json, sys; print(json.dumps({'token': open(sys.argv[1]).read().strip()}))" "$SECRETS/setup-a")"
      ;;
    bound)
      ANSWER="{\"seconds\": $FRESH}"
      ;;
    people)
      ANSWER="$(identity_fixture "$A" people)"
      ;;
    head | resolve | fresh)
      ANSWER="$(identity_fixture "$A" "$op" "$(asked "$ask" identifier)")"
      ;;
    directory)
      identity_front_fault dir.test "$(asked "$ask" mode)"
      ANSWER="{\"mode\": \"$(asked "$ask" mode)\"}"
      ;;
    tombstone)
      ANSWER="$(identity_fixture "$DIR" tombstone "$(asked "$ask" identifier)")"
      ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
}

step "the identity proof in Chromium, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run identity-proof proof.mjs /authority/homes.json /out &
PROOF_PID=$!
proof_await answer_ask

echo "the record: $OUT/identity-proof.json and $OUT/identity-proof.md"
exit "$PROOF_STATUS"
