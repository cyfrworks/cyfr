#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The canvas proof (README.md), on SQLite: a `cyfr` release started as the
# browser harness starts one (tests/browser/harness.sh), holding the shipped
# canvas and the proof's tinctures (tinctures/), the canvases written for it
# with `canvas.write` and the feeds bound for them, and a signed-in person's
# layout placing them, driven in every browser of the harness's matrix at
# one viewport (proof.mjs).
#
# What the person does goes through the console's own path and the gate
# (the release fixture's `console`): the layout, `canvas.write`, `feed.bind`,
# `feed.remove` and `feed.press`. The feed's source, its profile and each
# fixed result the feeds show are the proof's own fixture (fixture.exs): no
# run executes, and no model or execution worker is started.
#
# The proof asks for its fixture actions mid-run through the output
# directory (`ask-N.json`, each the command and its non-secret arguments),
# and this script, which holds the session token, answers `answer-N.json`.
# Once the proof has written its record, this script looks for every
# credential the run held in it and removes a record that carries one. The
# scan runs, and then the asks and the answers go, on every exit path, an
# early one included.
#
# Usage: CANVAS_PROOF_VIEWPORT=desktop|720x720 \
#          [CANVAS_PROOF_HOST_CLASS=reference|github-hosted] tests/canvas-proof/run.sh
# `desktop` is the PC (1280x900, posture desk) and `720x720` the phone
# (posture hand). The host class chooses the budget the measurement is held
# to (proof.mjs BUDGET_MS); unset, it is `reference`, and any value but the
# two, an empty one included, fails before the cell starts. Writes
# canvas-proof.json and canvas-proof.md into PROOF_OUT (default: the scratch
# directory, kept with RELEASE_BOOT_KEEP=1) and prints the table. Set
# RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run built.
set -euo pipefail

VIEWPORT="${CANVAS_PROOF_VIEWPORT:-}"
case "$VIEWPORT" in
  desktop | 720x720) ;;
  *)
    echo "::error::CANVAS_PROOF_VIEWPORT is desktop or 720x720, not '$VIEWPORT'" >&2
    exit 64
    ;;
esac

HOST_CLASS="${CANVAS_PROOF_HOST_CLASS-reference}"
case "$HOST_CLASS" in
  reference | github-hosted) ;;
  *)
    echo "::error::CANVAS_PROOF_HOST_CLASS is reference or github-hosted, not '$HOST_CLASS'" >&2
    exit 64
    ;;
esac

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-canvas-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
HERE="$ROOT/tests/canvas-proof"
OUT="${PROOF_OUT:-$WORK/out}"
PROOF_PID=""

# The asks and answers this run wrote into the output directory. An answer
# may hold a bearer the fixture minted, so they go on every exit path, a
# kept output directory's included.
remove_asks() {
  rm -f "$OUT"/ask-* "$OUT"/answer-*
}

# The record carries no credential this run held: the session token, the
# browser's cookie, or a bearer the fixture minted, read from the answers,
# so this runs before they go. A record that carries one is removed, so
# no kept or uploaded output directory holds it, and so is every record
# when an answer cannot be read or parsed, since its bearer is then
# unknown; the answer is 1 if any was removed.
RECORDS_SCANNED=0
scan_records() {
  local record secret bearers found=0
  if ! bearers="$(python3 -c '
import glob, json, sys
for path in glob.glob(sys.argv[1] + "/answer-*.json"):
    answer = json.load(open(path))
    if isinstance(answer, dict) and isinstance(answer.get("bearer"), str):
        print(answer["bearer"])' "$OUT")"; then
    echo "::error::an answer could not be read or parsed, so its bearer is unknown; the records are removed" >&2
    rm -f "$OUT/canvas-proof.json" "$OUT/canvas-proof.md"
    RECORDS_SCANNED=1
    return 1
  fi
  for record in "$OUT/canvas-proof.json" "$OUT/canvas-proof.md"; do
    [ -s "$record" ] || continue
    while IFS= read -r secret; do
      if [ -n "$secret" ] && grep -qF -- "$secret" "$record"; then
        echo "::error::$record carries a credential this run held; it is removed" >&2
        rm -f "$record"
        found=1
        break
      fi
    done <<<"${TOKEN:-}
${cookie:-}
$bearers"
  done
  RECORDS_SCANNED=1
  return "$found"
}

# The scratch directory holds the cell's keys and its database, so it goes
# even when a stop fails. `server_stop` ends in `fail`, an `exit`, when a
# listener outlives its stop, and an exit inside this trap would end it
# before the removal, so the stop runs in a subshell, whose exit ends only
# that subshell; the stop's failure still fails the run. Once the proof's
# container is stopped and can write no more, a record an early exit left
# unscanned is scanned, and then the asks and answers go.
cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  if [ "$RECORDS_SCANNED" = 0 ] && ! scan_records; then
    [ "$code" -ne 0 ] || code=1
  fi
  remove_asks
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT
# An interrupt or a stop (heavy-check's deadline among them) ends the run
# through the same cleanup.
trap 'exit 130' INT
trap 'exit 143' TERM

# The proof's own fixture (fixture.exs) inside the server running on CELL,
# as `bin/cyfr rpc`: `$@` are its arguments, and its one JSON line is the
# answer.
# A fixture rpc that never fails the script: a raise answers nothing, and
# the caller sees an empty answer rather than the run exiting (set -e).
canvas_fixture() {
  cell_fixture "$CELL" "$HERE/fixture.exs" CANVAS "$@" 2>>"$CELL/fixture.log" || :
}

# A console call for the person, its answer as the release fixture gives it.
console() { server_fixture "$CELL" console "$TOKEN" "$1" "$2"; }

release_build
CELL="$WORK/cell"
browser_cell "$CELL"

step "starting the release on a fresh SQLite cell, as https://cyfr.test"
server_start "$CELL"

step "the person, the proof's tinctures and the feed's source"
person="$(server_fixture "$CELL" person operator@example.com canvas-proof)"
[ -n "$person" ] || fail "the fixture signed nobody in"
user_id="$(field "$person" user_id)"
segment="$(field "$person" segment)"
TOKEN="$(field "$person" token)"
cookie="$(browser_cookie "$CELL" "$TOKEN")"

# canvas-probe's version also holds canvas-neighbour's shared.js, as the
# sibling file its module imports statically: the same bytes load from the
# probe's own prefix and are refused from the neighbour's.
cp -R "$HERE/tinctures/canvas-probe" "$WORK/canvas-probe"
cp "$HERE/tinctures/canvas-neighbour/shared.js" "$WORK/canvas-probe/shared.js"
for published in \
  "$HERE/tinctures/canvas-full canvas-full" \
  "$HERE/tinctures/canvas-neighbour canvas-neighbour" \
  "$HERE/tinctures/canvas-broken canvas-broken" \
  "$WORK/canvas-probe canvas-probe"; do
  read -r dir name <<<"$published"
  answer="$(server_fixture "$CELL" tincture "$user_id" "$dir" "$name" private)"
  printf '%s' "$answer" | grep -q '"component":"' || fail "$name was not published: $answer"
  # A tincture's frame, a canvas's among them, opens only under the
  # person's grant.
  server_fixture "$CELL" grant "$TOKEN" "$name" >/dev/null
done

source_answer="$(canvas_fixture source "$TOKEN" candles)"
[ -n "$source_answer" ] || fail "the feed's source was not published"
SOURCE="$(field "$source_answer" reference)"
PROFILE="$(field "$source_answer" profile_id)"

# The person's feeds, by name: name -> binding id. Binding ids name no
# credential; the proof names a feed by its name, or a binding the fixture
# answered it.
declare -A FEEDS=()

# Bind feed `$1` of the source at interval `$2` with args `$3` and actions
# `$4`, through the console. Answers the console's answer.
bind_feed() {
  console feed/bind "{\"name\":\"$1\",\"label\":\"$5\",\"reference\":\"$SOURCE\",\"profile_id\":\"$PROFILE\",\"operation\":\"quote\",\"args\":$3,\"interval_minutes\":$2,\"actions\":$4}"
}

CANDLE_ACTIONS='[{"name":"buy","label":"Buy","kind":"run","operation":"order","args":{"side":"buy"}},{"name":"refresh","label":"Refresh","kind":"refresh"}]'

bound() {
  local answer="$1" name="$2"
  printf '%s' "$answer" | grep -q '"ok"' || fail "feed $name was not bound: $answer"
  printf '%s' "$answer" | python3 -c 'import json, sys; print(json.load(sys.stdin)["ok"]["binding"])'
}

mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-* "$OUT/canvas-proof.json" "$OUT/canvas-proof.md"

step "the feeds the canvases read, bound through the console"
FEEDS[candles]="$(bound "$(bind_feed candles 60 '{"symbol":"BTC"}' "$CANDLE_ACTIONS" Candles)" candles)"
FEEDS[broken-die]="$(bound "$(bind_feed broken-die 60 '{"symbol":"DIE"}' '[]' 'Broken, dies')" broken-die)"
FEEDS[broken-crash]="$(bound "$(bind_feed broken-crash 60 '{"symbol":"CRASH"}' '[]' 'Broken, crashes')" broken-crash)"

# A fixed result as the proof gives one: `$1` a feed's name, `$2` its data.
accept_fixed() {
  canvas_fixture accept "$TOKEN" "${FEEDS[$1]}" "$2"
}

candles() {
  python3 - "$1" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
symbol = sys.argv[1]
now = datetime.now(timezone.utc).replace(microsecond=0)
candles = []
price = 42000.0
for i in range(6):
    o = price
    c = price + (35.5 if i % 2 == 0 else -20.25)
    candles.append({"t": (now - timedelta(hours=6 - i)).isoformat().replace("+00:00", "Z"),
                    "o": o, "h": max(o, c) + 12.0, "l": min(o, c) - 9.5, "c": c})
    price = c
print(json.dumps({"symbol": symbol, "price": price, "change": None,
                  "at": now.isoformat().replace("+00:00", "Z"), "candles": candles}))
PY
}

for feed in candles broken-crash; do
  accepted="$(accept_fixed "$feed" "$(candles BTC)")"
  printf '%s' "$accepted" | grep -q '"revision"' || fail "no fixed result was accepted for $feed: $accepted"
done

step "the written canvases, through canvas.write"
READS_CANDLES='[{"name":"feed.results","subject":"candles"}]'
for written in "markets $READS_CANDLES" "labels $READS_CANDLES" "measure []"; do
  read -r canvas streams <<<"$written"
  answer="$(canvas_fixture write "$TOKEN" "$canvas" "$canvas" "$streams")"
  printf '%s' "$answer" | grep -q '"ok"' || fail "canvas $canvas was not written: $answer"
  server_fixture "$CELL" grant "$TOKEN" "$canvas" "$(field "$answer" ok version)" >/dev/null
done

# The person's layout, version 2, published through the console at the
# revision this script last published; the console's answer is left in
# LAYOUT_ANSWER. It runs in this shell, never a command substitution's, so
# the revision it counts is the one the next publication reads. The proof
# chooses each layout.
LAYOUT_REVISION=0
LAYOUT_ANSWER=""
publish_layout() {
  LAYOUT_ANSWER="$(console layout/edit "{\"document\":$1,\"revision\":$LAYOUT_REVISION}")"
  if printf '%s' "$LAYOUT_ANSWER" | grep -q '"ok"'; then LAYOUT_REVISION=$((LAYOUT_REVISION + 1)); fi
}

binding_of() { python3 -c 'import json, sys; print(json.load(sys.stdin)["ok"]["binding"])'; }

# Each step the proof asks for (harness.sh `answer_asks`, with `null` for
# an answer the fixture left empty). A request carries the command and its
# non-secret arguments; the answer is the fixture's or the console's, which
# name no credential but the bearer `bearer` mints for the exits step,
# which the proof keeps out of its record.
# Answering an ask never fails the run: errexit is off for the body, so a
# refused console call or a parse error leaves an error answer, not an exit.
answer_ask() {
  local ask="$1" op arg binding old removed rebound fired restore
  case $- in *e*) restore=1 ;; *) restore=0 ;; esac
  set +e
  op="$(asked "$ask" op)"
  case "$op" in
    write)
      # The written version granted as the person grants it from the
      # shell's prompt, before the proof shows it: a write whose version is
      # left ungranted answers the grant's failure instead.
      arg="$(asked "$ask" canvas)"
      ANSWER="$(canvas_fixture write "$TOKEN" "$arg" "$(asked "$ask" module)" "$(asked "$ask" streams)")"
      if printf '%s' "$ANSWER" | grep -q '"ok"' &&
        ! server_fixture "$CELL" grant "$TOKEN" "$arg" "$(field "$ANSWER" ok version)" >/dev/null; then
        ANSWER="{\"error\":\"the written version of $arg was not granted\"}"
      fi
      ;;
    versions)
      ANSWER="$(console canvas/versions "{\"canvas\":\"$(asked "$ask" canvas)\"}")"
      ;;
    layout)
      publish_layout "$(asked "$ask" document)"
      ANSWER="$LAYOUT_ANSWER"
      ;;
    accept)
      ANSWER="$(accept_fixed "$(asked "$ask" feed)" "$(asked "$ask" data)")"
      ;;
    state)
      ANSWER="$(canvas_fixture state "$TOKEN" "${FEEDS[$(asked "$ask" feed)]}")"
      ;;
    state_of)
      ANSWER="$(canvas_fixture state "$TOKEN" "$(asked "$ask" binding)")"
      ;;
    press)
      ANSWER="$(console feed/press "{\"binding\":\"$(asked "$ask" binding)\",\"action_name\":\"$(asked "$ask" action)\"}")"
      ;;
    bearer)
      ANSWER="$(canvas_fixture bearer "$TOKEN" "$(asked "$ask" reference)")"
      ;;
    rebind)
      arg="$(asked "$ask" feed)"
      old="${FEEDS[$arg]}"
      removed="$(console feed/remove "{\"binding\":\"$old\"}")"
      rebound="$(bind_feed "$arg" 60 "$(asked "$ask" args)" "$CANDLE_ACTIONS" Candles)"
      if printf '%s' "$rebound" | grep -q '"ok"'; then FEEDS[$arg]="$(printf '%s' "$rebound" | binding_of)"; fi
      ANSWER="{\"old\":\"$old\",\"removed\":${removed:-null},\"bound\":${rebound:-null}}"
      ;;
    failed_fire)
      rebound="$(bind_feed fire-check 1 '{"symbol":"FIRE"}' '[]' 'Fire check')"
      if printf '%s' "$rebound" | grep -q '"ok"'; then
        binding="$(printf '%s' "$rebound" | binding_of)"
        fired="$(canvas_fixture failed_fire "$TOKEN" "$binding")"
        removed="$(console feed/remove "{\"binding\":\"$binding\"}")"
        ANSWER="{\"bound\":$rebound,\"fire\":${fired:-null},\"removed\":${removed:-null}}"
      else
        ANSWER="{\"bound\":${rebound:-null}}"
      fi
      ;;
    *) ANSWER="{\"error\":\"run.sh does not do $op\"}" ;;
  esac
  [ "$restore" = 1 ] && set -e
  return 0
}

step "the canvas proof at $VIEWPORT on the $HOST_CLASS host class in $PLAYWRIGHT_IMAGE"
# CANVAS_PROOF_DEV narrows a local run (browsers=…;steps=…;measure=0); its
# record says it is narrowed and never passes. A full run leaves it unset.
playwright_run canvas-proof proof.mjs "$segment" "$cookie" /out "$VIEWPORT" "${CANVAS_PROOF_DEV:-}" "$HOST_CLASS" &
PROOF_PID=$!
proof_await answer_ask null
status="$PROOF_STATUS"

# Once the record is checked the answers, the one place a minted bearer
# was kept, go.
step "the record's credentials"
for record in "$OUT/canvas-proof.json" "$OUT/canvas-proof.md"; do
  if [ ! -s "$record" ]; then
    echo "::error::the proof wrote no $record" >&2
    status=1
  fi
done
scan_records || status=1
remove_asks

echo "the record: $OUT/canvas-proof.json and $OUT/canvas-proof.md"
exit "$status"
