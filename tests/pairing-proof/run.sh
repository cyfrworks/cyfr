#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The pairing proof (README.md): a `cyfr` release started as the browser
# harness starts a home (tests/browser/harness.sh), the home home.test
# behind the harness's HTTPS front, its device certificates made short
# through the settings operation, and one person signed in twice — a
# desktop and a phone — driven in Chromium (proof.mjs) through pairing,
# confirmation on the glass, a command line signed in by approval, a sleep
# beyond the certificate's expiry and revocation, with the device-intent
# measurement. The command line is the real cyfr binary, built here into
# the output directory, where the proof runs it.
#
# The proof asks the server for its part through the output directory
# (`ask-N.json`), and this script answers each (`answer-N.json`): the
# phone's passkey registration, begun and completed through the console's
# adapter under the phone's session (`passkey_options`,
# `passkey_register`), and the names of the person's vault entries
# (`vault_names`).
#
# Usage: tests/pairing-proof/run.sh
# Writes pairing-proof.json and pairing-proof.md into PROOF_OUT (default:
# the scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints the
# table. Set RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run
# built, and PAIRING_PROOF_CERT_SECONDS for the certificates' life (20).
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-pairing-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
OUT="${PROOF_OUT:-$WORK/out}"
CERT_SECONDS="${PAIRING_PROOF_CERT_SECONDS:-20}"
PROOF_PID=""

# The scratch directory holds the run's authority key, so it goes even
# when a stop fails. `server_stop` ends in `fail`, an `exit`, when a
# listener outlives its stop, and an exit inside this trap would end it
# before the removal, so the stop runs in a subshell, whose exit ends only
# that subshell; the stop's failure still fails the run. The asks and
# answers go on every exit, a kept or outside PROOF_OUT included; the
# record stays.
cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  rm -f "$OUT"/ask-* "$OUT"/answer-*
  rm -rf "$OUT/bin"
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

release_build

step "the run's authority and the home home.test"
browser_authority
CELL="$WORK/home"
browser_home "$CELL" home.test

step "starting home.test on a fresh SQLite cell"
server_start "$CELL"

step "one person, signed in twice: the desktop and the phone"
desktop="$(server_fixture "$CELL" person operator@example.com pairing-proof)"
phone="$(server_fixture "$CELL" person operator@example.com pairing-proof)"
[ -n "$desktop" ] && [ -n "$phone" ] || fail "the fixture signed nobody in"
segment="$(field "$desktop" segment)"
desktop_token="$(field "$desktop" token)"
phone_token="$(field "$phone" token)"
desktop_cookie="$(browser_cookie "$CELL" "$desktop_token")"
phone_cookie="$(browser_cookie "$CELL" "$phone_token")"
# No canvas runs: the shell draws its picker, so no safe mode waits in
# front of the prompts this proof drives.
browser_picker_layout "$CELL" "$desktop_token"

step "device certificates live $CERT_SECONDS seconds"
answer="$(server_fixture "$CELL" console "$desktop_token" settings/set \
  "{\"key\":\"device_cert_seconds\",\"value\":\"$CERT_SECONDS\"}")"
printf '%s' "$answer" | grep -q '"ok"' || fail "device_cert_seconds was not set: $answer"

# Each step the proof asks for (harness.sh `answer_asks`).
answer_ask() {
  local ask="$1" op arguments
  op="$(asked "$ask" op)"
  case "$op" in
    passkey_options)
      ANSWER="$(server_fixture "$CELL" console "$phone_token" passkey/register '{}')"
      ;;
    passkey_register)
      arguments="$(python3 -c "import json, sys; print(json.dumps({'credential': json.load(open(sys.argv[1]))['credential']}))" "$ask")"
      ANSWER="$(server_fixture "$CELL" console "$phone_token" passkey/register "$arguments")"
      ;;
    vault_names)
      ANSWER="$(server_fixture "$CELL" console "$desktop_token" vault/list '{}' |
        python3 -c "import json, sys; a = json.load(sys.stdin); print(json.dumps({'names': sorted(e['name'] for e in a.get('ok', {}).get('entries', []))} if 'ok' in a else a))")"
      ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
}

step "the command line the proof runs"
mkdir -p "$OUT/bin"
( cd "$ROOT/apps/codex" && CGO_ENABLED=0 go build -trimpath -o "$OUT/bin/cyfr" . ) ||
  fail "the cyfr command line did not build"

step "the pairing proof in Chromium, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run pairing-proof proof.mjs /authority/homes.json "$segment" "$desktop_cookie" "$phone_cookie" /out &
PROOF_PID=$!
proof_await answer_ask

echo "the record: $OUT/pairing-proof.json and $OUT/pairing-proof.md"
exit "$PROOF_STATUS"
