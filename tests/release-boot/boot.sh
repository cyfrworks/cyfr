#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The `cyfr` release, built as `Dockerfile` builds it (MIX_ENV=prod, the
# adapter chosen at compile time by CYFR_DATABASE, `mix release cyfr`),
# booted against a FRESH database of that adapter with auto-migration on
# (tests/release-boot/release.sh). Four cases, in order:
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
#   live slots  `Cyfr.Release.live_slots/0`, the offline read `cyfr update`
#            makes before it snapshots a cell, run as the update runs it
#            (`bin/cyfr eval`, which starts no application): against the
#            running cell of the first case it answers that cell's one
#            slot under this release, and once the cell has stopped it
#            answers none.
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
# two databases beside it, named for this run (`pg_run_database`), and drops
# them when it ends; it drops no database it did not create, so runs that
# share one server and one URL leave each other's alone. A run killed before
# its cleanup leaves its two behind, under its own names. The dump and the
# restore run in the postgres:18.6 image, with this host's network. Set
# RELEASE_BOOT_SKIP_BUILD=1 to reuse the release a previous run built, and
# RELEASE_BOOT_KEEP=1 to keep the scratch directory, its logs and the
# databases.

# The PostgreSQL client the restore case runs, the server's own major.
PG_IMAGE="postgres:18.6"
CREATED_DATABASES=()
# This run among the runs sharing a server: its process id and eight random
# hex digits.
RUN_ID="$$_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"

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

# The name of this run's database for `$1` (cell, restore):
# `<database>_<run>_$1`, the name CYFR_DATABASE_URL holds cut so the whole
# fits in 63 bytes. PostgreSQL truncates a longer identifier without an
# error, which could make two of this run's names, or another run's, one.
pg_run_database() {
  local LC_ALL=C base suffix="_${RUN_ID}_$1"
  base="$(basename "${CYFR_DATABASE_URL%%\?*}")"
  echo "${base:0:$((63 - ${#suffix}))}$suffix"
}

# Creates the database `$1` and records it as this run's. CREATE fails on a
# name that exists, so the run never takes over, and never drops, a
# database it did not create.
pg_fresh_database() {
  local name="$1"
  pg psql -v ON_ERROR_STOP=1 -q "$CYFR_DATABASE_URL" -c "CREATE DATABASE \"$name\"" \
    || fail "could not create the database $name beside the one CYFR_DATABASE_URL names"
  CREATED_DATABASES+=("$name")
}

# Drops the databases this run created. The drop is forced: a server that
# outlived its stop still holds its database, and forcing ends that
# server's sessions, which only this run has.
pg_drop_created() {
  local name
  for name in ${CREATED_DATABASES[@]+"${CREATED_DATABASES[@]}"}; do
    pg psql -q "$CYFR_DATABASE_URL" -c "DROP DATABASE IF EXISTS \"$name\" WITH (FORCE)" >/dev/null 2>&1 || true
  done
}

# Sourced (tests/release-boot/names-test.sh), the script defines the
# functions above and runs nothing.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

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

# The scratch directory holds the cells' keys and databases, and the
# PostgreSQL databases the run created sit beside the one CYFR_DATABASE_URL
# names, so both go even when a stop fails. `server_stop` ends in `fail`,
# an `exit`, when a listener outlives its stop, and an exit inside this
# trap would end it before the removals, so the stop runs in a subshell,
# whose exit ends only that subshell; the stop's failure still fails the
# run.
cleanup() {
  local code=$?
  # The cell started last is the one a failed step was asking.
  if [ "$code" -ne 0 ]; then
    local cell
    for cell in "$COPY" "$ORIGIN" "$CELL"; do
      if [ -n "$cell" ] && [ -f "$cell/boot.log" ]; then
        log_tail "$cell"
        break
      fi
    done
  fi
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  [ "${RELEASE_BOOT_KEEP:-}" = 1 ] || pg_drop_created
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
# The cells whose log a failed run prints, named before the trap reads
# them.
CELL="" ORIGIN="" COPY=""
trap cleanup EXIT

# How many of a server's last log lines a failed run prints.
LOG_TAIL_LINES=200

# The last LOG_TAIL_LINES lines of cell `$1`'s server log on stderr, for a
# run that failed, so the failure carries what the server said, redacted
# (`redact_log`).
log_tail() {
  local cell="$1"
  echo "----- the last $LOG_TAIL_LINES lines of $cell/boot.log -----" >&2
  tail -n "$LOG_TAIL_LINES" "$cell/boot.log" | redact_log "$cell" >&2 ||
    echo "(the log could not be redacted, so it is not printed)" >&2
}

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
  redact_log "$CELL" <"$CELL/boot.log" >&2 || echo "(the log could not be redacted, so it is not printed)" >&2
  exit 1
fi
grep -E "== (Running|Migrated)" "$CELL/boot.log"

# Liveness beside readiness, so a half-open server cannot pass as a boot.
curl -fsS -m 10 "http://127.0.0.1:$PORT/api/health" >"$CELL/health.json"
echo "GET /api/health -> 200 $(cat "$CELL/health.json")"

# The cell's live slots as `cyfr update` reads them, by the expression it
# runs: the one `CYFR_LIVE_SLOTS=` line, holding this release and the
# slots. A run that prints no such line, or two, fails the case.
live_slots() {
  local out
  out="$(cell_cyfr "$1" eval \
    'IO.puts("CYFR_LIVE_SLOTS=" <> JSON.encode!(%{release: Prima.Version.current(), slots: Cyfr.Release.live_slots()}))' \
    | grep '^CYFR_LIVE_SLOTS=')" || fail "live_slots/0 printed no answer"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "live_slots/0 answered twice: $out"
  printf '%s\n' "${out#CYFR_LIVE_SLOTS=}"
}

step "live slots: the running cell's one slot, under this release"
VERSION="$(sed -n 's/^ *version: "\([0-9][0-9.]*\)",$/\1/p' "$ROOT/apps/prima/mix.exs")"
running="$(live_slots "$CELL")"
printf '%s' "$running" | python3 -c '
import json, sys
answer = json.load(sys.stdin)
node_prefix, version = sys.argv[1] + "@", sys.argv[2]
slots = answer["slots"]
ok = (answer["release"] == version and len(slots) == 1
      and slots[0]["node"].startswith(node_prefix) and slots[0]["release"] == version)
sys.exit(0 if ok else 1)' "$(cell_node "$CELL")" "$VERSION" ||
  fail "live slots of the running cell were not its one slot under $VERSION: $running"
echo "the running cell: $running"

server_stop

step "live slots: none once the cell has stopped"
stopped="$(live_slots "$CELL")"
printf '%s' "$stopped" | python3 -c '
import json, sys
sys.exit(0 if json.load(sys.stdin)["slots"] == [] else 1)' ||
  fail "live slots of the stopped cell were not empty: $stopped"
echo "the stopped cell: $stopped"

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
  redact_log "$CELL" <"$REFUSAL_LOG" >&2 || echo "(the log could not be redacted, so it is not printed)" >&2
  exit 1
fi

if ! grep -q "CORS wildcard" "$REFUSAL_LOG"; then
  echo "::error::the refused boot did not name the CORS wildcard" >&2
  redact_log "$CELL" <"$REFUSAL_LOG" >&2 || echo "(the log could not be redacted, so it is not printed)" >&2
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
  ORIGIN_DB="$(pg_run_database cell)"
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
user_id="$(field "$person" user_id)"
token="$(field "$person" token)"
LOG_SECRETS+=("$token")

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
  local page status
  status="$(curl -sS -m 30 -o "$WORK/page" -w '%{http_code}' -H "authorization: Bearer $token" "http://127.0.0.1:$PORT$tincture_path")" ||
    fail "$what: $tincture_path did not answer"
  # A refusal's body is the error's JSON, its code and message.
  [ "$status" = 200 ] ||
    fail "$what: $tincture_path was not served to the person: $status $(head -c 300 "$WORK/page")"
  page="$(cat "$WORK/page")"
  case "$page" in
    *"the backup proof tincture"*) echo "$what: GET $tincture_path -> the tincture's page" ;;
    *) fail "$what: $tincture_path answered without the tincture's page" ;;
  esac

  local body answer
  body="$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"thread","arguments":{"action":"messages","thread":"%s"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"release-boot","version":"0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' "$thread_id")"
  answer="$(curl -fsS -m 30 -X POST "http://127.0.0.1:$PORT/mcp" \
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
  RESTORE_DB="$(pg_run_database restore)"
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
