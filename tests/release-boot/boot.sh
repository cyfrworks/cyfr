#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The `cyfr` release, built as `Dockerfile` builds it (MIX_ENV=prod, the
# adapter chosen at compile time by CYFR_DATABASE, `mix release cyfr`),
# booted against a FRESH database of that adapter with auto-migration on
# (tests/release-boot/release.sh). Three cases, in order:
#
#   boots    the environment `cyfr init` writes — the stack's keys, the
#            empty CORS allowlist, authentication configured,
#            CYFR_AUTO_MIGRATE=true. The release migrates the schema itself
#            (nothing else can: the database carries no schema before it
#            starts) and answers /api/health/ready, the readiness check the
#            image's HEALTHCHECK runs. A boot that raises, exits or never
#            answers fails here, with its whole log.
#
#   refuses  the same environment with the wildcard CORS allowlist, which a
#            release with authentication configured must refuse at boot.
#            The release must exit non-zero naming CORS: a boot that raises
#            is loud, never a container that looks started.
#
#   restores a cell's backup, which is four parts copied while the cell is
#            stopped: the database, the storage root, the keyring and the
#            deployment file. A cell of its own (its database, for
#            PostgreSQL, created beside the one the first case used) keeps
#            its keyring in a file apart from its deployment file, signs a
#            person in, holds a tincture and a thread, and is stopped; the
#            four parts are copied to a fresh location (for PostgreSQL, the
#            database dumped into another new one) and the copy booted with
#            auto-migration off. The copy must pass the schema fingerprint
#            (`Arca.SchemaFingerprint.verify!/0`) and the keyring
#            fingerprint its boot checks, and serve the tincture and the
#            thread to the person's session, which the copy still honours.
#
# Nothing else boots a release: the suite starts the application under its
# test configuration, which migrates nothing and reads no `.env`, so a boot
# that cannot migrate its database is invisible to it.
#
# Usage:  tests/release-boot/boot.sh <sqlite|postgres>
#
# Postgres needs CYFR_DATABASE_URL pointing at an EXISTING database with no
# schema in it, as a role that may create databases: the third case creates
# `<database>_cell` and `<database>_restore` beside it (dropping any left by
# an earlier run) and drops them when it ends. The dump and the restore run
# in the postgres:16 image, with this host's network. Set
# RELEASE_BOOT_SKIP_BUILD=1 to reuse the release a previous run built, and
# RELEASE_BOOT_KEEP=1 to keep the scratch directory and its logs.
set -euo pipefail

ADAPTER="${1:-}"
case "$ADAPTER" in
  sqlite | postgres) ;;
  *)
    echo "usage: $0 <sqlite|postgres>" >&2
    exit 2
    ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-release-boot-XXXXXX")"
# shellcheck source=release.sh
source "$(cd "$(dirname "$0")" && pwd)/release.sh"
cd "$ROOT"

# The PostgreSQL client the restore case runs, the server's own major.
PG_IMAGE="postgres:16"
CREATED_DATABASES=()

# A PostgreSQL client command in the postgres image, on this host's network.
pg() {
  docker run --rm --network host -e PGOPTIONS=--client-min-messages=warning "$PG_IMAGE" "$@"
}

# CYFR_DATABASE_URL with its database renamed to `$1`.
pg_url() {
  local base="${CYFR_DATABASE_URL%%\?*}" query=""
  [ "$base" = "$CYFR_DATABASE_URL" ] || query="?${CYFR_DATABASE_URL#*\?}"
  echo "${base%/*}/$1$query"
}

pg_fresh_database() {
  local name="$1"
  pg psql -v ON_ERROR_STOP=1 -q "$CYFR_DATABASE_URL" \
    -c "DROP DATABASE IF EXISTS \"$name\"" -c "CREATE DATABASE \"$name\"" \
    || fail "could not create the database $name beside the one CYFR_DATABASE_URL names"
  CREATED_DATABASES+=("$name")
}

cleanup() {
  server_stop || true
  if [ "${RELEASE_BOOT_KEEP:-}" != 1 ]; then
    for name in ${CREATED_DATABASES[@]+"${CREATED_DATABASES[@]}"}; do
      pg psql -q "$CYFR_DATABASE_URL" -c "DROP DATABASE IF EXISTS \"$name\"" >/dev/null 2>&1 || true
    done
  fi
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

release_build

# ---------------------------------------------------------------------------
# Case 1: a fresh database, migrated by the boot, answering its health check
# ---------------------------------------------------------------------------

CELL="$WORK/cell"
cell_new "$CELL" "${CYFR_DATABASE_URL:-}"

step "the $ADAPTER database carries no schema before the release starts"
before="$(cell_pending "$CELL")"
if [ "${before:-0}" -lt 1 ]; then
  echo "::error::the $ADAPTER database is not fresh: it reports $before pending migrations" >&2
  echo "Point CYFR_DATABASE_URL at an empty database (or remove the SQLite file)." >&2
  exit 1
fi
echo "pending migrations before the boot: $before"

step "booting the release against a fresh $ADAPTER database with auto-migration on"
server_start "$CELL"
echo "GET /api/health/ready -> 200 $(cat "$CELL/ready.json")"

step "the boot migrated the schema itself"
if ! grep -q "== Migrated" "$CELL/boot.log"; then
  echo "::error::the boot log does not report a migration it ran" >&2
  cat "$CELL/boot.log" >&2
  exit 1
fi
grep -E "== (Running|Migrated)" "$CELL/boot.log"

# Liveness beside readiness, so a half-open server cannot pass as a boot.
curl -fsS "http://127.0.0.1:$PORT/api/health" >"$CELL/health.json"
echo "GET /api/health -> 200 $(cat "$CELL/health.json")"

server_stop

after="$(cell_pending "$CELL")"
if [ "${after:-1}" -ne 0 ]; then
  echo "::error::the $ADAPTER database still reports $after pending migrations after the boot" >&2
  exit 1
fi
echo "pending migrations after the boot: $after"

# ---------------------------------------------------------------------------
# Case 2: a boot that raises is loud
# ---------------------------------------------------------------------------

step "a boot that raises exits non-zero and says why (the wildcard CORS allowlist)"
REFUSAL_LOG="$WORK/refusal.log"
set +e
cell_cyfr "$CELL" "CYFR_CORS_ALLOWED_ORIGINS=*" start >"$REFUSAL_LOG" 2>&1
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "::error::the release booted with the wildcard CORS allowlist and authentication configured" >&2
  cat "$REFUSAL_LOG" >&2
  exit 1
fi

if ! grep -q "CORS wildcard" "$REFUSAL_LOG"; then
  echo "::error::the refused boot did not name the CORS wildcard" >&2
  cat "$REFUSAL_LOG" >&2
  exit 1
fi

echo "the boot exited $status, naming the wildcard:"
grep -o "FATAL: CORS wildcard.*" "$REFUSAL_LOG" | head -1

# ---------------------------------------------------------------------------
# Case 3: a backup of the four parts, restored and booted elsewhere
# ---------------------------------------------------------------------------

step "a cell of its own, with its keyring kept apart from its deployment file"
ORIGIN="$WORK/origin"
ORIGIN_URL=""
if [ "$ADAPTER" = postgres ]; then
  ORIGIN_DB="$(basename "${CYFR_DATABASE_URL%%\?*}")_cell"
  pg_fresh_database "$ORIGIN_DB"
  ORIGIN_URL="$(pg_url "$ORIGIN_DB")"
fi
cell_new "$ORIGIN" "$ORIGIN_URL"
# The SQLite database in a directory of its own, so it is a part apart
# from the storage root.
[ "$ADAPTER" = sqlite ] && mkdir -p "$ORIGIN/db"
printf '{"primary":"k1","keys":{"k1":"%s"}}' "$(openssl rand -base64 32 | tr -d '\n')" >"$ORIGIN/keyring.json"

server_start "$ORIGIN"
# The first boot of a database records its keyring's fingerprint; the
# copy's boot must match it rather than record one.
grep -q "Recorded the crypto keyring fingerprint" "$ORIGIN/boot.log" ||
  fail "the cell's first boot did not record its keyring fingerprint"
person="$(server_fixture "$ORIGIN" person operator@example.com release-boot-backup)"
[ -n "$person" ] || fail "the fixture signed nobody in"
field() { printf '%s' "$1" | python3 -c "import json, sys; print(json.load(sys.stdin)['$2'])"; }
user_id="$(field "$person" user_id)"
token="$(field "$person" token)"

TINCTURE_DIR="$WORK/tincture"
mkdir -p "$TINCTURE_DIR"
cat >"$TINCTURE_DIR/cyfr-manifest.json" <<'JSON'
{"name": "backup-proof", "type": "tincture", "version": "1.0.0", "publisher": "local",
 "tincture": {"entry": "index.html"}}
JSON
echo '<!doctype html><html><head></head><body>the backup proof tincture</body></html>' >"$TINCTURE_DIR/index.html"
tincture="$(server_fixture "$ORIGIN" tincture "$user_id" "$TINCTURE_DIR" backup-proof public)"
tincture_path="$(field "$tincture" path)"
thread_id="$(field "$(server_fixture "$ORIGIN" thread "$user_id" "the backup proof thread")" thread_id)"
echo "the cell holds $tincture_path and $thread_id"

# The tincture page as the person's session fetches it, and the thread's
# messages over /mcp, as the person's client reads them.
serves() {
  local what="$1"
  local page
  page="$(curl -fsS -H "authorization: Bearer $token" "http://127.0.0.1:$PORT$tincture_path")" ||
    fail "$what: $tincture_path was not served to the person"
  case "$page" in
    *"the backup proof tincture"*) echo "$what: GET $tincture_path -> the tincture's page" ;;
    *) fail "$what: $tincture_path answered without the tincture's page" ;;
  esac

  local body answer
  body="$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"thread","arguments":{"action":"messages","thread":"%s"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"release-boot","version":"0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' "$thread_id")"
  answer="$(curl -fsS -X POST "http://127.0.0.1:$PORT/mcp" \
    -H "authorization: Bearer $token" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' -H 'mcp-protocol-version: 2026-07-28' \
    -H 'mcp-method: tools/call' -H 'mcp-name: thread' -d "$body")" ||
    fail "$what: the thread was not served over /mcp"
  if printf '%s' "$answer" | python3 -c '
import json, sys
result = json.load(sys.stdin)["result"]
messages = json.loads(result["content"][0]["text"])["messages"]
sys.exit(0 if not result["isError"] and [m["content"] for m in messages] == ["the backup proof thread"] else 1)'; then
    echo "$what: thread.messages -> the thread's message"
  else
    fail "$what: thread.messages answered without the message: $answer"
  fi
}
serves "the cell"

step "the cell stopped, its four parts copied to a fresh location"
server_stop
COPY="$WORK/copy"
mkdir -p "$COPY/home"
cp -R "$ORIGIN/data" "$COPY/data"
cp "$ORIGIN/keyring.json" "$COPY/keyring.json"
cp "$ORIGIN/.env" "$COPY/.env"
# The seed tree is install media, not the cell's: the copy gets the release's.
cp -R "$ROOT/seed" "$COPY/seed"
if [ "$ADAPTER" = sqlite ]; then
  cp -R "$ORIGIN/db" "$COPY/db"
else
  RESTORE_DB="$(basename "${CYFR_DATABASE_URL%%\?*}")_restore"
  pg_fresh_database "$RESTORE_DB"
  pg pg_dump --format=custom --no-owner "$ORIGIN_URL" >"$WORK/cell.dump" ||
    fail "the cell's database did not dump"
  docker run --rm -i --network host "$PG_IMAGE" \
    pg_restore --no-owner --exit-on-error -d "$(pg_url "$RESTORE_DB")" <"$WORK/cell.dump" ||
    fail "the dump did not restore into $RESTORE_DB"
  sed -i "s|^CYFR_DATABASE_URL=.*|CYFR_DATABASE_URL=$(pg_url "$RESTORE_DB")|" "$COPY/.env"
  # The origin's database goes, so a copy that still reached it could not pass.
  pg psql -q "$CYFR_DATABASE_URL" -c "DROP DATABASE \"$ORIGIN_DB\"" || fail "could not drop $ORIGIN_DB"
fi
# The origin's storage root goes too, for the same reason.
rm -rf "$ORIGIN"
sed -i 's/^CYFR_AUTO_MIGRATE=.*/CYFR_AUTO_MIGRATE=false/' "$COPY/.env"
echo "copied: the database, the storage root, keyring.json and .env"

step "the copy boots with nothing to migrate and passes both fingerprints"
restored_pending="$(cell_pending "$COPY")"
[ "${restored_pending:-1}" -eq 0 ] || fail "the copy reports $restored_pending pending migrations"
verified="$(cell_cyfr "$COPY" eval \
  '_ = Cyfr.Release.pending(); {:ok, :ok, _} = Ecto.Migrator.with_repo(Arca.Repo, fn _ -> Arca.SchemaFingerprint.verify!() end); IO.puts("SCHEMA_FINGERPRINT=ok")' \
  | grep -c '^SCHEMA_FINGERPRINT=ok' || true)"
[ "$verified" = 1 ] || fail "the copy's schema fingerprint did not verify"
echo "the schema fingerprint verified"

server_start "$COPY"
if grep -q "Recorded the crypto keyring fingerprint\|Accepted a different crypto keyring" "$COPY/boot.log"; then
  fail "the copy's boot recorded a keyring fingerprint anew instead of matching the one the cell recorded"
fi
echo "GET /api/health/ready -> 200 $(cat "$COPY/ready.json")"
serves "the copy"
server_stop

step "the cyfr release boots on $ADAPTER, migrates itself, refuses loudly and restores from its backup"
