#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The pairing proof (README.md): a `cyfr` release started as the browser
# harness starts a home (tests/browser/harness.sh), the home home.test
# behind the harness's HTTPS front, its device certificates made short
# through the settings operation, and one person signed in twice — a
# desktop and a phone — driven in Chromium (proof.mjs) through pairing,
# confirmation on the glass, a sleep beyond the certificate's expiry and
# revocation, with the device-intent measurement.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-pairing-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
OUT="${PROOF_OUT:-$WORK/out}"
CERT_SECONDS="${PAIRING_PROOF_CERT_SECONDS:-20}"
PROOF_PID=""

# The proof's own container, found by the output directory only this run
# mounts: stopping the subshell that started it leaves `docker run` and its
# container behind.
stop_proof_container() {
  local ids
  ids="$(docker ps -q --filter "volume=$OUT" 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker stop -t 5 $ids >/dev/null 2>&1 || true
  fi
}

# The scratch directory holds the run's authority key, so it goes even
# when a stop fails.
cleanup() {
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  server_stop || :
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

field() { printf '%s' "$1" | python3 -c "import json, sys; print(json.load(sys.stdin)['$2'])"; }

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
# No desktop tincture runs: the shell draws its picker, so no safe mode
# waits in front of the prompts this proof drives.
browser_picker_layout "$CELL" "$desktop_token"

step "device certificates live $CERT_SECONDS seconds"
answer="$(server_fixture "$CELL" console "$desktop_token" settings/set \
  "{\"key\":\"device_cert_seconds\",\"value\":\"$CERT_SECONDS\"}")"
printf '%s' "$answer" | grep -q '"ok"' || fail "device_cert_seconds was not set: $answer"

# Each step the proof asks for, answered once.
answer_asks() {
  local ask id op answer arguments
  for ask in "$OUT"/ask-*.json; do
    [ -e "$ask" ] || continue
    id="${ask##*/ask-}"
    id="${id%.json}"
    [ -e "$OUT/answer-$id.json" ] && continue
    op="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['op'])" "$ask")"
    case "$op" in
      passkey_options)
        answer="$(server_fixture "$CELL" console "$phone_token" passkey/register '{}')"
        ;;
      passkey_register)
        arguments="$(python3 -c "import json, sys; print(json.dumps({'credential': json.load(open(sys.argv[1]))['credential']}))" "$ask")"
        answer="$(server_fixture "$CELL" console "$phone_token" passkey/register "$arguments")"
        ;;
      vault_names)
        answer="$(server_fixture "$CELL" console "$desktop_token" vault/list '{}' |
          python3 -c "import json, sys; a = json.load(sys.stdin); print(json.dumps({'names': sorted(e['name'] for e in a.get('ok', {}).get('entries', []))} if 'ok' in a else a))")"
        ;;
      *) fail "the proof asked for '$op', which this script does not do" ;;
    esac
    [ -n "$answer" ] || answer='{"error":"the fixture answered nothing"}'
    printf '%s\n' "$answer" >"$OUT/answer-$id.part"
    mv "$OUT/answer-$id.part" "$OUT/answer-$id.json"
  done
}

step "the pairing proof in Chromium, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run pairing-proof proof.mjs /authority/homes.json "$segment" "$desktop_cookie" "$phone_cookie" /out &
PROOF_PID=$!
while kill -0 "$PROOF_PID" 2>/dev/null; do
  answer_asks
  sleep 0.2
done
set +e
wait "$PROOF_PID"
status=$?
set -e
PROOF_PID=""

echo "the record: $OUT/pairing-proof.json and $OUT/pairing-proof.md"
exit "$status"
