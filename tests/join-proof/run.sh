#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The join proof (README.md): `cyfr` releases started as the browser
# harness starts homes (tests/browser/harness.sh), each a SQLite cell on a
# `.test` name behind the harness's HTTPS front: the directory dir.test,
# which serves the account pages and the names beside its log, and h.test,
# the CYFR people join, which reaches the directory through the identity
# proof's front (tests/identity-proof/front.sh and cells.sh). proof.mjs
# drives Chromium and a test device through H's setup by its operator,
# invitations redeemed by an account in the browser and by a device's
# hello, and a change confirmed at H by passkey; this script answers its
# asks for H's part (`ask-N.json`, answered `answer-N.json`).
#
# Usage: tests/join-proof/run.sh
# Writes join-proof.json and join-proof.md into PROOF_OUT (default: the
# scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints the table.
# RELEASE_BOOT_SKIP_BUILD=1 reuses a release a previous run built.
#
# Everything it starts is removed when it ends, whether it succeeds or
# fails: the cells' servers, the directory's front container, the
# Playwright container, and the scratch directory with the run's authority
# key and H's setup token.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-join-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
# shellcheck source=../identity-proof/front.sh
source "$ROOT/tests/identity-proof/front.sh"
# shellcheck source=../identity-proof/cells.sh
source "$ROOT/tests/identity-proof/cells.sh"
OUT="${PROOF_OUT:-$WORK/out}"
PROOF_PID=""
SECRETS="$WORK/secrets"
mkdir -p -m 700 "$SECRETS"

# The scratch directory holds the run's authority key and the setup token,
# so it goes even when a stop fails; the asks and answers that held the
# token go from PROOF_OUT too. `server_stop` ends in `fail`, an `exit`,
# when a listener outlives its stop, so it runs in a subshell: the exit
# ends that subshell, never this trap, and the stop's failure still fails
# the run.
cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  identity_front_stop
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
H="$WORK/h"
browser_home "$DIR" dir.test
browser_home "$H" h.test
openssl rand -hex 32 | tr -d '\n' >"$SECRETS/setup-h"

identity_directory dir.test
identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
identity_reaches_directory "$H" dir.test
identity_env "$H" CYFR_REGISTRY_URL dir.test
identity_env "$H" CYFR_SETUP_TOKEN "$(cat "$SECRETS/setup-h")"

step "starting the directory, its front, and H"
server_start "$DIR"
identity_front_start "$DIR"
identity_start "$H"

# Each step the proof asks for (harness.sh `answer_asks`, which removes
# each ask before its answer appears).
answer_ask() {
  local ask="$1" op
  op="$(asked "$ask" op)"
  case "$op" in
    setup_token)
      ANSWER="$(python3 -c "import json, sys; print(json.dumps({'token': open(sys.argv[1]).read().strip()}))" "$SECRETS/setup-h")"
      ;;
    people)
      ANSWER="$(identity_fixture "$H" people)"
      ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
}

step "the join proof in Chromium, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run join-proof proof.mjs /authority/homes.json /out &
PROOF_PID=$!
proof_await answer_ask

echo "the record: $OUT/join-proof.json and $OUT/join-proof.md"
exit "$PROOF_STATUS"
