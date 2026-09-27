#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The canvas proof (README.md): a `cyfr` release started as the browser
# harness starts one (tests/browser/harness.sh), holding the shipped desktop
# and vault and the proof's tinctures (tinctures/), with a signed-in
# person's layout placing them, driven in every browser of the harness's
# matrix (proof.mjs). The proof asks for the release to be gone under its
# open tabs (`stop-server` in the output directory), and this script kills it
# and answers `server-stopped`.
#
# The vault page's operations are also measured inside the server
# (measure.exs), on this SQLite cell and, when CANVAS_PROOF_PG_URL names an
# existing PostgreSQL database as a role that may create databases, on a
# PostgreSQL cell of a release built for PostgreSQL.
#
# Usage: tests/canvas-proof/run.sh
# Writes canvas-proof.json and canvas-proof.md into PROOF_OUT (default: the
# scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints the table. Set
# RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run built, and
# CANVAS_PROOF_BROWSERS (e.g. `chromium`) to narrow the browsers.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-canvas-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
HERE="$ROOT/tests/canvas-proof"
OUT="${PROOF_OUT:-$WORK/out}"
CALLS=200
CONCURRENCY=16
PROOF_PID=""

cleanup() {
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  server_stop
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

mkdir -p "$OUT"
rm -f "$OUT/stop-server" "$OUT/server-stopped" "$OUT"/server-measurements-*

field() { printf '%s' "$1" | python3 -c "import json, sys; print(json.load(sys.stdin)['$2'])"; }

# A person's vault, as the console fills it: ten entries, each holding a
# value no page may show.
seed_vault() {
  local cell="$1" token="$2" n answer
  for n in $(seq -w 1 10); do
    answer="$(server_fixture "$cell" console "$token" vault/create \
      "{\"name\":\"seeded-$n\",\"kind\":\"api_key\",\"fields\":{\"API_KEY\":\"seeded-value-$n-not-shown\"}}")"
    printf '%s' "$answer" | grep -q '"ok"' || fail "seeded-$n was not created: $answer"
  done
  answer="$(server_fixture "$cell" console "$token" vault/create \
    '{"name":"seeded-api","kind":"api_key","fields":{"API_KEY":"seeded-api-value-not-shown"}}')"
  printf '%s' "$answer" | grep -q '"ok"' || fail "seeded-api was not created: $answer"
}

# vault.list and vault.status measured in the server running on cell `$1`
# for the session token `$2`, written to `$3`.
measure_in_server() {
  local measured
  measured="$(cell_cyfr "$1" rpc \
    "{answer, _} = Code.eval_file(\"$HERE/measure.exs\"); IO.puts(answer.([\"$2\", \"$CALLS\", \"$CONCURRENCY\"]))" \
    | sed -n 's/^MEASURE=//p' | tail -1)"
  [ -n "$measured" ] || fail "the in-server measurement answered nothing"
  printf '%s\n' "$measured" >"$3"
}

# ---------------------------------------------------------------------------
# PostgreSQL: the in-server measurement on a cell of its own, when asked
# ---------------------------------------------------------------------------

if [ -n "${CANVAS_PROOF_PG_URL:-}" ]; then
  step "the vault's operations on a PostgreSQL cell"
  (
    set -euo pipefail
    ADAPTER=postgres
    RELEASE_BOOT_PORT="${CANVAS_PROOF_PG_PORT:-4397}"
    RELEASE_BOOT_HOST_API_PORT="${CANVAS_PROOF_PG_HOST_API_PORT:-4396}"
    # shellcheck source=../release-boot/release.sh
    source "$ROOT/tests/release-boot/release.sh"
    pg() { docker run --rm --network host -e PGOPTIONS=--client-min-messages=warning postgres:16 "$@"; }
    base="${CANVAS_PROOF_PG_URL%%\?*}"
    db="canvas_proof_$$"
    url="${base%/*}/$db"
    pg psql -v ON_ERROR_STOP=1 -q "$CANVAS_PROOF_PG_URL" -c "DROP DATABASE IF EXISTS \"$db\"" -c "CREATE DATABASE \"$db\"" \
      || fail "could not create $db beside the database CANVAS_PROOF_PG_URL names"
    trap 'server_stop; pg psql -q "$CANVAS_PROOF_PG_URL" -c "DROP DATABASE IF EXISTS \"$db\"" >/dev/null 2>&1 || true' EXIT
    release_build
    cell_new "$WORK/pg-cell" "$url"
    server_start "$WORK/pg-cell"
    person="$(server_fixture "$WORK/pg-cell" person operator@example.com canvas-proof-pg)"
    [ -n "$person" ] || fail "the fixture signed nobody in on PostgreSQL"
    seed_vault "$WORK/pg-cell" "$(field "$person" token)"
    measure_in_server "$WORK/pg-cell" "$(field "$person" token)" "$OUT/server-measurements-postgres.json"
  ) || fail "the PostgreSQL measurement did not complete"
else
  echo "CANVAS_PROOF_PG_URL is not set: no PostgreSQL cell is started" >"$OUT/server-measurements-postgres.skipped"
fi

# ---------------------------------------------------------------------------
# The SQLite cell the browsers drive
# ---------------------------------------------------------------------------

release_build
CELL="$WORK/cell"
browser_cell "$CELL"
# Every measured call is a frame's request; the frame's invocation rate is
# lifted so the measurement is not the limit's.
echo "CYFR_FRAME_INVOCATION_MAX=100000" >>"$CELL/.env"

step "starting the release on a fresh SQLite cell, as cyfr.test"
server_start "$CELL"

step "publishing the proof's tinctures, private, and the person's layout and vault"
person="$(server_fixture "$CELL" person operator@example.com canvas-proof)"
[ -n "$person" ] || fail "the fixture signed nobody in"
user_id="$(field "$person" user_id)"
segment="$(field "$person" segment)"
token="$(field "$person" token)"
cookie="$(browser_cookie "$CELL" "$token")"
for name in canvas-card canvas-full canvas-stall; do
  published="$(server_fixture "$CELL" tincture "$user_id" "$HERE/tinctures/$name" "$name" private)"
  [ -n "$published" ] || fail "$name was not published"
done

slot() { printf '{"id":"%s","tincture":"%s","size":"%s","order":%s}' "$@"; }
vault_slot() { slot vault tincture:local.vault icon "$1"; }
card_slot() { slot card tincture:local.canvas-card card "$1"; }
full_slot() { slot full-app tincture:local.canvas-full icon "$1"; }
desk="{\"desktop\":\"tincture:local.desktop\",\"floating\":[],\"slots\":[$(vault_slot 0),$(card_slot 1),$(full_slot 2)]}"
hand="{\"desktop\":\"tincture:local.desktop\",\"floating\":[],\"slots\":[$(card_slot 0),$(vault_slot 1),$(full_slot 2)]}"
browser_layout "$CELL" "$token" "{\"version\":1,\"postures\":{\"desk\":$desk,\"hand\":$hand}}"
seed_vault "$CELL" "$token"

step "the vault's operations in the server, SQLite"
measure_in_server "$CELL" "$token" "$OUT/server-measurements-sqlite.json"

# The measurement's burst can starve the member's lease renewal on
# SQLite, so the member loses its slot and every page answers 503 until
# it wins the claim back: the proof starts once the release is ready again.
step "waiting for the release to hold its control plane again"
for _ in $(seq 1 60); do
  curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/health/ready" 2>/dev/null && break
  sleep 1
done
curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/health/ready" || fail "the release is not ready after the measurement"

step "the canvas proof in $PLAYWRIGHT_IMAGE"
playwright_run canvas-proof proof.mjs "http://127.0.0.1:$PORT" "$segment" "$cookie" /out \
  "${CANVAS_PROOF_BROWSERS:-}" &
PROOF_PID=$!

# The proof's last section asks for the release to be gone under its open
# tabs; nothing else stops it before the proof ends. The release is killed:
# a graceful stop drains every socket while the listener still accepts, so
# a tab may join again during the drain and be drawn anew by a server that
# is about to go, which is not the case this section proves.
server_kill() {
  pkill -9 -f "sname $NODE" 2>/dev/null || true
  for _ in $(seq 1 30); do
    curl -fsS -m 1 -o /dev/null "http://127.0.0.1:$PORT/api/health" 2>/dev/null || return 0
    sleep 1
  done
  fail "the release on 127.0.0.1:$PORT outlived its kill"
}

while kill -0 "$PROOF_PID" 2>/dev/null; do
  if [ -f "$OUT/stop-server" ] && [ ! -f "$OUT/server-stopped" ]; then
    step "killing the release under the proof's open tabs"
    server_kill
    touch "$OUT/server-stopped"
  fi
  sleep 1
done
set +e
wait "$PROOF_PID"
status=$?
set -e
PROOF_PID=""

echo "the record: $OUT/canvas-proof.json and $OUT/canvas-proof.md"
exit "$status"
