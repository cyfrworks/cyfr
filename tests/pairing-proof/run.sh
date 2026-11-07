#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The pairing proof (README.md): `cyfr` releases started as the browser
# harness starts homes (tests/browser/harness.sh), each a SQLite cell on a
# `.test` name behind the harness's HTTPS front: the directory dir.test,
# which serves the account pages, and three CYFRs, x.test, y.test and
# z.test, which reach it through the identity proof's front
# (tests/identity-proof/front.sh and cells.sh). proof.mjs drives Chromium,
# test devices and the real `cyfr` binary, built here into the output
# directory, through devices added to the person's account by the page and
# by `cyfr device approve`, a confirmation from a device, a device's key
# removed and added again, a declared restore of x.test, and z.test set up
# from the terminal; this
# script answers its asks for the CYFRs' part (`ask-N.json`, answered
# `answer-N.json`).
#
# Usage: tests/pairing-proof/run.sh
# Writes pairing-proof.json and pairing-proof.md into PROOF_OUT (default:
# the scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints the
# table. Set RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run
# built; PAIRING_PROOF_FRESHNESS (20) is the CYFRs'
# identity_freshness_seconds.
#
# Everything it starts is removed when it ends, whether it succeeds or
# fails: the cells' servers, the directory's front container, the
# Playwright container, the command line built into the output directory,
# and the scratch directory with the run's authority key and the setup
# tokens.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-pairing-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
# shellcheck source=../identity-proof/front.sh
source "$ROOT/tests/identity-proof/front.sh"
# shellcheck source=../identity-proof/cells.sh
source "$ROOT/tests/identity-proof/cells.sh"
OUT="${PROOF_OUT:-$WORK/out}"
FRESH="${PAIRING_PROOF_FRESHNESS:-20}"
PROOF_PID=""
SECRETS="$WORK/secrets"
mkdir -p -m 700 "$SECRETS"

# The scratch directory holds the run's authority key and the setup
# tokens, so it goes even when a stop fails; the asks and answers that held
# a token go from PROOF_OUT too, and so does the command line. `server_stop`
# ends in `fail`, an `exit`, when a listener outlives its stop, so it runs
# in a subshell: the exit ends that subshell, never this trap, and the
# stop's failure still fails the run.
cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  identity_front_stop
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  rm -f "$OUT"/ask-* "$OUT"/answer-* 2>/dev/null || true
  rm -rf "$OUT/bin"
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
X="$WORK/x"
Y="$WORK/y"
Z="$WORK/z"
browser_home "$DIR" dir.test
browser_home "$X" x.test
browser_home "$Y" y.test
browser_home "$Z" z.test

identity_directory dir.test 127.77.0.1
identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
for cell in "$X" "$Y" "$Z"; do
  openssl rand -hex 32 | tr -d '\n' >"$SECRETS/setup-$(basename "$cell")"
  identity_reaches_directory "$cell" dir.test "CYFR_IDENTITY_FRESHNESS_SECONDS=$FRESH"
  identity_env "$cell" CYFR_REGISTRY_URL dir.test
  identity_env "$cell" CYFR_SETUP_TOKEN "$(cat "$SECRETS/setup-$(basename "$cell")")"
done

step "starting the directory, its front, and the CYFRs"
server_start "$DIR"
identity_front_start "$DIR"
for cell in "$X" "$Y" "$Z"; do identity_start "$cell"; done

# Each step the proof asks for (harness.sh `answer_asks`, which removes
# each ask before its answer appears).
answer_ask() {
  local ask="$1" op cell
  op="$(asked "$ask" op)"
  case "$op" in
    setup_token)
      cell="$(asked "$ask" cell)"
      [[ "$cell" =~ ^[xyz]$ ]] || fail "no CYFR named '$cell'"
      ANSWER="$(python3 -c "import json, sys; print(json.dumps({'token': open(sys.argv[1]).read().strip()}))" "$SECRETS/setup-$cell")"
      ;;
    people)
      cell="$(asked "$ask" cell)"
      [[ "$cell" =~ ^[xyz]$ ]] || fail "no CYFR named '$cell'"
      ANSWER="$(identity_fixture "$WORK/$cell" people)"
      ;;
    bound)
      ANSWER="{\"seconds\": $FRESH}"
      ;;
    restore)
      # The CYFR stopped, its restore declared as `cyfr restore` declares
      # one (tests/fixtures/restore_barrier.json), and started again, which
      # runs the restore's transition before anything is served.
      cell="$(asked "$ask" cell)"
      [[ "$cell" =~ ^[xyz]$ ]] || fail "no CYFR named '$cell'"
      barrier() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ROOT/tests/fixtures/restore_barrier.json" "$1"; }
      server_stop "$WORK/$cell"
      declared="$(cell_cyfr "$WORK/$cell" eval "$(barrier declare_expr)" | sed -n "s/^$(barrier declared_prefix)//p" | tail -1)"
      identity_start "$WORK/$cell"
      ANSWER="$(python3 -c 'import json, sys; print(json.dumps({"declared": sys.argv[1]}))' "$declared")"
      ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
}

step "the command line the proof runs"
mkdir -p "$OUT/bin"
( cd "$ROOT/apps/codex" && CGO_ENABLED=0 go build -trimpath -o "$OUT/bin/cyfr" . ) ||
  fail "the cyfr command line did not build"

step "the pairing proof in Chromium, in $PLAYWRIGHT_IMAGE"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run pairing-proof proof.mjs /authority/homes.json /out &
PROOF_PID=$!
proof_await answer_ask

echo "the record: $OUT/pairing-proof.json and $OUT/pairing-proof.md"
exit "$PROOF_STATUS"
