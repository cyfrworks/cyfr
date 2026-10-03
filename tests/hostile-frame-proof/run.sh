#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The frame sandbox containment proof (README.md): the proof's tinctures
# (tinctures/) published into a signed-in person's athanor of a `cyfr`
# release started as the browser harness starts one
# (tests/browser/harness.sh), and the probe opened from the Prism shell in
# every browser of the harness's matrix (proof.mjs), once as a private
# tincture and once as a public one.
#
# The proof's prompts over a malicious fullscreen frame ask the server for
# their part through the output directory (`ask-N.json`): this script
# floats a tincture waiting for its grant in the person's layout (`grant`),
# has another session of the person ask for a sensitive change
# (`confirmation`), or puts the picker layout back (`reset`), and answers
# `answer-N.json`.
#
# Usage: tests/hostile-frame-proof/run.sh
# Writes containment-proof.json and containment-proof.md into PROOF_OUT
# (default: the scratch directory, kept with RELEASE_BOOT_KEEP=1). Set
# RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run built.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-containment-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
HERE="$ROOT/tests/hostile-frame-proof"
OUT="${PROOF_OUT:-$WORK/out}"
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

cleanup() {
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  server_stop
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

release_build
CELL="$WORK/cell"
browser_cell "$CELL"

step "starting the release on a fresh SQLite cell, as cyfr.test"
server_start "$CELL"

step "publishing the probe (private, and a public copy), its private neighbour and the public neighbour"
person="$(server_fixture "$CELL" person operator@example.com containment-proof)"
[ -n "$person" ] || fail "the fixture signed nobody in"
field() { printf '%s' "$person" | python3 -c "import json, sys; print(json.load(sys.stdin)['$1'])"; }
user_id="$(field user_id)"
segment="$(field segment)"
cookie="$(browser_cookie "$CELL" "$(field token)")"
browser_picker_layout "$CELL" "$(field token)"

# The public copy is the same bundle under another name.
cp -R "$HERE/tinctures/containment-probe" "$WORK/containment-probe-public"
sed -i 's/"name": "containment-probe"/"name": "containment-probe-public"/' \
  "$WORK/containment-probe-public/cyfr-manifest.json"

server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/containment-probe" containment-probe private >/dev/null
server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/containment-neighbour" containment-neighbour private >/dev/null
server_fixture "$CELL" tincture "$user_id" "$WORK/containment-probe-public" containment-probe-public public >/dev/null
neighbour="$(server_fixture "$CELL" tincture "$user_id" "$ROOT/tests/browser/tinctures/frame-neighbour" frame-neighbour public)"
neighbour_path="$(printf '%s' "$neighbour" | python3 -c 'import json, sys; print(json.load(sys.stdin)["path"])')"

status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/t/$segment/local/containment-probe")"
[ "$status" = 404 ] || fail "the private probe's public address answered $status"
status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$neighbour_path/neighbour.js")"
[ "$status" = 200 ] || fail "the public neighbour's script answered $status"

step "the malicious fullscreen frame, and a tincture waiting for its grant"
server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/fullscreen-probe" fullscreen-probe private >/dev/null
server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/ungranted-probe" ungranted-probe private >/dev/null
ungranted="$(cell_cyfr "$CELL" rpc \
  "{answer, _} = Code.eval_file(\"$HERE/ungranted.exs\"); IO.puts(answer.([\"$user_id\", \"ungranted-probe\"]))" |
  sed -n 's/^UNGRANTED=//p' | tail -1)"
[ -n "$ungranted" ] || fail "the waiting tincture's profile was not written"
# Another session of the same person: the client that asks for a change.
other="$(server_fixture "$CELL" person operator@example.com containment-proof)"
other_token="$(printf '%s' "$other" | python3 -c "import json, sys; print(json.load(sys.stdin)['token'])")"
[ -n "$other_token" ] || fail "the fixture opened no second session"

# The person's layout: the picker alone (revision 1, as published above),
# or with the waiting tincture floating over it.
LAYOUT_REVISION=1
none='{"desktop":"tincture:local.no-desktop","slots":[],"floating":[]}'
float='{"desktop":"tincture:local.no-desktop","slots":[],"floating":[{"tincture":"tincture:local.ungranted-probe","position":{"x":6000,"y":6000}}]}'
publish_layout() {
  browser_layout "$CELL" "$(field token)" "{\"version\":1,\"postures\":{\"desk\":$1,\"hand\":$1}}" "$LAYOUT_REVISION"
  LAYOUT_REVISION=$((LAYOUT_REVISION + 1))
}

# Each step the proof asks for, answered once.
answer_asks() {
  local ask id op answer
  for ask in "$OUT"/ask-*.json; do
    [ -e "$ask" ] || continue
    id="${ask##*/ask-}"
    id="${id%.json}"
    [ -e "$OUT/answer-$id.json" ] && continue
    op="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['op'])" "$ask")"
    case "$op" in
      grant)
        publish_layout "$float"
        answer='{"ok":"floated"}'
        ;;
      reset)
        publish_layout "$none"
        answer='{"ok":"picker"}'
        ;;
      confirmation)
        answer="$(server_fixture "$CELL" console "$other_token" vault/create \
          "{\"name\":\"asked-over-a-frame-$id\",\"kind\":\"api_key\",\"fields\":{\"API_KEY\":\"not-shown-$id\"},\"destination\":{\"hosts\":[\"fixture.test\"]}}")"
        printf '%s' "$answer" | grep -q confirmation_required ||
          fail "the second session's change did not wait for a confirmation: $answer"
        answer='{"ok":"asked"}'
        ;;
      *) fail "the proof asked for '$op', which this script does not do" ;;
    esac
    printf '%s\n' "$answer" >"$OUT/answer-$id.part"
    mv "$OUT/answer-$id.part" "$OUT/answer-$id.json"
  done
}

step "the containment proof in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run hostile-frame-proof proof.mjs "http://127.0.0.1:$PORT" "$segment" "$cookie" /out "$neighbour_path" &
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

echo "the record: $OUT/containment-proof.json and $OUT/containment-proof.md"
exit "$status"
