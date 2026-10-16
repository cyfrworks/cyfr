#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The `cyfr` release, built as `Dockerfile` builds it (MIX_ENV=prod, the
# adapter chosen at compile time by CYFR_DATABASE, `mix release cyfr`),
# booted against a FRESH database of that adapter with auto-migration on
# (tests/release-boot/release.sh). Six cases, in order:
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
#            thread to the person's session, which the copy still honours:
#            an undeclared restore keeps the backup's authority, the stated
#            limit.
#
#   marked restore  the same copy, stopped and declared restored as
#            `cyfr restore` declares one (`bin/cyfr eval` of
#            `Cyfr.Release.mark_restore/0`), then booted: the boot consumes
#            the marker before its gate opens, so the pre-backup session is
#            refused, the person's vault entry answers `entry_unavailable`
#            to a host-side read, and the tincture's profile needs consent.
#
#   reserve  a cell whose storage reserve (`Cyfr.StorageReserve`) shares a
#            size-limited filesystem with its database: for SQLite the data
#            directory, which holds the database, the storage root and the
#            reserve's directory; for PostgreSQL a postgres server's data
#            directory beside the reserve's directory. The filesystem is a
#            tmpfs a container of this user's holds, since the host offers
#            no mount to an unprivileged user: the SQLite cell's server runs
#            in that container (the host's own `/usr` and this checkout's
#            release, so the same binaries), and the host reads and fills
#            the tmpfs through the container's root (`/proc/<pid>/root`).
#            The cell boots holding its reserve file, a person pairs a
#            device, and the filesystem is filled below the mark: the cell
#            latches `depleted` and frees the file, a note write is
#            refused, and the device's revocation is opened, read by its
#            request, proven and committed through the gate, and is still
#            there once the cell, still depleted, has restarted.
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
    for cell in "$RESERVE" "$COPY" "$ORIGIN" "$CELL"; do
      if [ -n "$cell" ] && [ -f "$cell/boot.log" ]; then
        log_tail "$cell"
        break
      fi
    done
  fi
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  # The reserve case's filesystem goes with the container that holds it.
  [ -z "$RESERVE_HOLDER" ] || docker rm -f "$RESERVE_HOLDER" >/dev/null 2>&1 || true
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
CELL="" ORIGIN="" COPY="" RESERVE="" RESERVE_HOLDER=""
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
# An entry of the person's, for the marked restore to block.
server_fixture "$ORIGIN" vault "$token" restore-proof api_key backup-proof-value >/dev/null ||
  fail "the fixture wrote no vault entry"
LOG_SECRETS+=("backup-proof-value")
athanor_id="$(field "$person" athanor_id)"
echo "the cell holds $tincture_path, $thread_id and the vault entry restore-proof"

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

# ---------------------------------------------------------------------------
# Case 4: the same backup, declared restored
# ---------------------------------------------------------------------------

# What `$1` answers to the person's pre-backup session over /mcp: the HTTP
# status of a `thread.messages` call.
mcp_status() {
  local body
  body="$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"thread","arguments":{"action":"messages","thread":"%s"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"release-boot","version":"0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' "$thread_id")"
  curl -sS -m 30 -o "$WORK/mcp" -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/mcp" \
    -H "authorization: Bearer $token" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' -H 'mcp-protocol-version: 2026-07-28' \
    -H 'mcp-method: tools/call' -H 'mcp-name: thread' -d "$body"
}

step "the copy, stopped, declared restored as cyfr restore declares one"
marked="$(cell_cyfr "$COPY" eval 'IO.puts("CYFR_RESTORE_ID=" <> Cyfr.Release.mark_restore())' |
  sed -n 's/^CYFR_RESTORE_ID=//p')"
[ -n "$marked" ] || fail "mark_restore/0 printed no restore id"
again="$(cell_cyfr "$COPY" eval 'IO.puts("CYFR_RESTORE_ID=" <> Cyfr.Release.mark_restore())' |
  sed -n 's/^CYFR_RESTORE_ID=//p')"
[ "$again" = "$marked" ] || fail "a second mark declared another restore: $again, not $marked"
echo "declared restore $marked"

step "the marked copy boots, consuming the marker before its gate opens"
server_start "$COPY"
grep -q "declared restore $marked applied" "$COPY/boot.log" ||
  fail "the boot log does not report the declared restore applied"
echo "GET /api/health/ready -> 200 $(cat "$COPY/ready.json")"

status="$(mcp_status)" || fail "/mcp did not answer"
[ "$status" = 401 ] ||
  fail "the pre-backup session was not refused after a declared restore: $status $(head -c 300 "$WORK/mcp")"
echo "the pre-backup session: POST /mcp -> 401"

read_entry="$(cell_cyfr "$COPY" rpc \
  "IO.puts(\"VAULT=\" <> inspect(Sanctum.VaultReader.unseal_disclosed(\"$athanor_id\", \"restore-proof\")))" |
  sed -n 's/^VAULT=//p')"
[ "$read_entry" = '{:error, {:entry_unavailable, "needs_reauth"}}' ] ||
  fail "the vault entry was read after a declared restore: $read_entry"
echo "the vault entry restore-proof: $read_entry"

profiles="$(cell_cyfr "$COPY" rpc \
  'require Ecto.Query; IO.puts("PROFILES=" <> Enum.join(Arca.Repo.all(Ecto.Query.from(p in Arca.Schemas.Profile, select: p.status)), ","))' |
  sed -n 's/^PROFILES=//p')"
case "$profiles" in
  "" | *active*) fail "a profile stands after a declared restore: ${profiles:-none}" ;;
  *needs_consent*) echo "the tincture's profile: $profiles" ;;
  *) fail "no profile needs consent after a declared restore: $profiles" ;;
esac
server_stop

step "a second boot of the restored copy finds no marker and applies nothing"
# The server log grows across a cell's boots: only this boot's lines count.
seen="$(wc -l <"$COPY/boot.log")"
server_start "$COPY"
if tail -n +"$((seen + 1))" "$COPY/boot.log" | grep -q "declared restore"; then
  fail "the second boot applied a declared restore again"
fi
server_stop

# ---------------------------------------------------------------------------
# Case 6: the storage reserve, on a filesystem that fills
# ---------------------------------------------------------------------------

# The reserve's size and the limited filesystem's: room for the schema, a
# PostgreSQL server's WAL and the reserve, filled below the mark after.
RESERVE_BYTES=$((64 * 1024 * 1024))
RESERVE_FS_SIZE=512m

# The bytes an unprivileged writer may still use under `$1`, as the
# reserve reads them (statvfs's available blocks).
free_bytes() {
  local blocks size
  read -r blocks size < <(stat -f -c '%a %S' "$1") || fail "no free space reading for $1"
  echo $((blocks * size))
}

# A tmpfs of RESERVE_FS_SIZE owned by this user, held by a container of
# this user's whose root this user may enter: the container's id in
# RESERVE_HOLDER, which the cleanup removes, and the tmpfs's path from the
# host in LIMITED. `$1` is where it mounts the tmpfs, the rest the
# container's own arguments, its image among them.
reserve_holder() {
  local mount="$1" pid
  shift
  RESERVE_HOLDER="$(docker run -d --user "$(id -u):$(id -g)" \
    --tmpfs "$mount:size=$RESERVE_FS_SIZE,uid=$(id -u),gid=$(id -g),mode=0700" \
    "$@")" || fail "no container could hold the reserve case's filesystem"
  pid="$(docker inspect -f '{{.State.Pid}}' "$RESERVE_HOLDER")"
  [ -n "$pid" ] && [ "$pid" != 0 ] || fail "the reserve case's container is not running"
  LIMITED="/proc/$pid/root$mount"
  [ -w "$LIMITED" ] || fail "the reserve case's filesystem is not this user's to write: $LIMITED"
}

# What the reserve case asks of the running cell, evaluated in it by
# `bin/cyfr rpc` (`cell_fixture`): the software passkey and the pairing
# ceremony are the suite's own (`Sanctum.TestContext`, loaded from the
# checkout), every change goes through the gate, and each command answers
# one `RESERVE=` line.
RESERVE_FIXTURE="$WORK/reserve.exs"
cat >"$RESERVE_FIXTURE" <<'ELIXIR'
fn args ->
  answer = fn map -> "RESERVE=" <> Jason.encode!(map) end
  call = fn ctx, tool, args -> Sanctum.Gate.call_external(tool, ctx, args) end

  # The session's person and their software passkey.
  person = fn root, token ->
    Code.require_file(Path.join(root, "apps/sanctum/test/support/test_context.ex"))
    {:ok, ctx} = Sanctum.Caller.establish({:session, token})
    {ctx, Sanctum.TestContext.Authenticator.for_person(ctx.user_id)}
  end

  case args do
    ["pair", root, token] ->
      {ctx, authenticator} = person.(root, token)

      # Their first passkey, under the first-method rule, on their own
      # session focused nowhere, as the console registers one.
      session = %{ctx | athanor_id: nil}
      {:ok, options} = Sanctum.Passkeys.register(session, %{})
      credential = Sanctum.TestContext.Authenticator.registration(authenticator, options)
      {:ok, %{status: "active"}} = Sanctum.Passkeys.register(session, %{credential: credential})

      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      digest = Prima.Device.key_digest(public)

      {:ok, %{invitation_secret: secret}} =
        Sanctum.TestContext.confirming(
          ctx,
          &call.(&1, "pairing", %{"action" => "begin", "key_digest" => digest})
        )

      glass = Sanctum.Context.build(%{authenticated: false, client_ip: "198.51.100.47"})

      submission = %{
        "action" => "complete",
        "invitation_secret" => secret,
        "device_key" => Prima.Identity.Encoding.b64(public),
        "key_digest" => digest
      }

      {:ok, %{challenge: challenge}} = call.(glass, "pairing", submission)
      {:ok, challenge} = Prima.DeviceCert.Challenge.decode(challenge)
      proof = Prima.DeviceCert.Proof.encode(Prima.DeviceCert.Proof.sign(challenge, private))

      {:ok, %{client_id: client_id}} =
        call.(glass, "pairing", Map.put(submission, "proof", proof))

      answer.(%{client_id: client_id})

    ["revoke", root, token, client_id] ->
      {ctx, authenticator} = person.(root, token)
      revoke = %{"action" => "revoke", "client_id" => client_id}

      {:error, {:confirmation_required, %{id: id}}} = call.(ctx, "pairing", revoke)
      ref = Prima.Confirmation.ref(id)

      {:error, %Prima.Refusal{reason: {:unavailable, :storage_reserve}}} =
        call.(ctx, "confirmation", %{"action" => "pending"})

      {:ok, %{confirmations: [entry]}} =
        call.(ctx, "confirmation", %{"action" => "pending", "request" => ref})

      {:ok, digest} = Prima.Identity.Encoding.unb64(entry.webauthn["challenge"], 32)
      assertion = Sanctum.TestContext.Authenticator.assertion(authenticator, digest)

      {:ok, %{state: "confirmed"}} =
        call.(ctx, "confirmation", %{"action" => "confirm", "ref" => ref, "assertion" => assertion})

      {:ok, %{standing: standing}} = call.(%{ctx | confirmation_id: id}, "pairing", revoke)
      answer.(%{standing: standing})

    ["note", token] ->
      {:ok, ctx} = Sanctum.Caller.establish({:session, token})

      case call.(ctx, "notes", %{"action" => "keep", "name" => "reserve", "content" => "a note"}) do
        {:ok, _kept} -> answer.(%{note: "kept"})
        {:error, %Prima.Refusal{reason: reason}} -> answer.(%{note: inspect(reason)})
        {:error, reason} -> answer.(%{note: inspect(reason)})
      end

    ["state"] ->
      answer.(%{state: Arca.StorageReserve.state()})

    ["standing", client_id] ->
      answer.(%{standing: Arca.Repo.get!(Arca.Schemas.PairedClient, client_id).standing})
  end
end
ELIXIR

reserve() { cell_fixture "$RESERVE" "$RESERVE_FIXTURE" RESERVE "$@"; }

# The latch as the running cell reads it, waited for to read `$1` across
# the monitor's 5 s polls.
reserve_awaits() {
  local want="$1" state="" closes=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$closes" ]; do
    state="$(field "$(reserve state)" state)" || state=""
    [ "$state" = "$want" ] && return 0
    sleep 2
  done
  fail "the storage reserve did not read $want within 60 s: ${state:-no answer}"
}

# Start and stop the reserve case's cell: a PostgreSQL cell on the host
# as every other cell; a SQLite cell in the container holding its data
# directory, under the environment the host's would run with, its
# database moved onto that directory's filesystem, where the reserve's
# directory defaults to.
reserve_start() {
  if [ "$ADAPTER" = postgres ]; then
    server_start "$RESERVE"
    return
  fi
  local mark closes
  mark="$( [ -f "$RESERVE/boot.log" ] && wc -l <"$RESERVE/boot.log" || echo 0)"
  cell_env "$RESERVE" CYFR_DATABASE_PATH="$RESERVE/data/cyfr.db" RELEASE_TMP="$RESERVE/tmp" \
    env >"$RESERVE/container.env"
  docker exec -d -w "$RESERVE" --env-file "$RESERVE/container.env" "$RESERVE_HOLDER" \
    bash -c 'exec "$0" start >>"$1" 2>&1' "$REL/bin/cyfr" "$RESERVE/boot.log" ||
    fail "the reserve case's cell could not be started in its container"
  closes=$((SECONDS + READY_TIMEOUT))
  until curl -fsS -m 5 -o "$RESERVE/ready.json" "http://127.0.0.1:$PORT/api/health/ready" 2>/dev/null; do
    if tail -n "+$((mark + 1))" "$RESERVE/boot.log" | grep -q "Kernel pid terminated\|Application cyfr exited\|application_start_failure"; then
      fail "the reserve case's cell exited while booting"
    fi
    [ "$SECONDS" -lt "$closes" ] || fail "the reserve case's cell did not answer readiness within $READY_TIMEOUT s"
    sleep 1
  done
}

reserve_stop() {
  if [ "$ADAPTER" = postgres ]; then
    server_stop
    return
  fi
  local closes=$((SECONDS + 60))
  cell_cyfr "$RESERVE" stop >/dev/null 2>&1 || fail "the reserve case's cell did not take its stop"
  while curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/health" 2>/dev/null; do
    [ "$SECONDS" -lt "$closes" ] || fail "the reserve case's cell outlived its stop"
    sleep 1
  done
}

step "the storage reserve: a $ADAPTER cell on a size-limited filesystem"
RESERVE="$WORK/reserve"
if [ "$ADAPTER" = postgres ]; then
  # The server's data directory and the reserve's directory on one tmpfs.
  reserve_holder /var/lib/postgresql \
    -e POSTGRES_PASSWORD=reserve -e POSTGRES_DB=reserve -p 127.0.0.1::5432 "$PG_IMAGE"
  RESERVE_PG_PORT="$(docker port "$RESERVE_HOLDER" 5432/tcp | sed -n 's/^127\.0\.0\.1://p' | head -1)"
  [ -n "$RESERVE_PG_PORT" ] || fail "the reserve case's postgres server publishes no port"
  closes=$((SECONDS + 60))
  until docker exec "$RESERVE_HOLDER" pg_isready -q -h 127.0.0.1 -U postgres; do
    [ "$SECONDS" -lt "$closes" ] || fail "the reserve case's postgres server did not start"
    sleep 1
  done
  LOG_SECRETS+=("reserve")
  cell_new "$RESERVE" "postgres://postgres:reserve@127.0.0.1:$RESERVE_PG_PORT/reserve"
  mkdir "$LIMITED/reserve"
  echo "CYFR_STORAGE_RESERVE_PATH=$LIMITED/reserve" >>"$RESERVE/.env"
  RESERVE_DIR="$LIMITED/reserve"
else
  # The data directory on the tmpfs, in the container the cell runs in.
  cell_new "$RESERVE"
  mkdir -p "$RESERVE/tmp"
  reserve_holder "$RESERVE/data" --hostname "$(hostname)" --network host \
    -v /usr:/usr:ro -v /etc/ld.so.cache:/etc/ld.so.cache:ro \
    -v "$ROOT:$ROOT:ro" -v "$WORK:$WORK" debian:trixie-slim sleep infinity
  RESERVE_DIR="$LIMITED"
fi
echo "CYFR_STORAGE_RESERVE_BYTES=$RESERVE_BYTES" >>"$RESERVE/.env"

reserve_start
[ "$(field "$(reserve state)" state)" = ok ] || fail "the cell did not boot holding its reserve"
[ "$(stat -c %s "$RESERVE_DIR/cyfr-storage-reserve")" = "$RESERVE_BYTES" ] ||
  fail "the cell did not preallocate its reserve file of $RESERVE_BYTES bytes"
echo "booted ok, holding a reserve file of $RESERVE_BYTES bytes"

reserve_person="$(server_fixture "$RESERVE" person operator@example.com release-boot-reserve)"
[ -n "$reserve_person" ] || fail "the fixture signed nobody in"
reserve_token="$(field "$reserve_person" token)"
LOG_SECRETS+=("$reserve_token")
client_id="$(field "$(reserve pair "$ROOT" "$reserve_token")" client_id)" ||
  fail "the person paired no device"
echo "the person paired $client_id"

step "the filesystem filled below the mark: the cell latches depleted and frees its reserve"
free="$(free_bytes "$LIMITED")"
fill=$((free - RESERVE_BYTES + 8 * 1024 * 1024))
[ "$fill" -gt 0 ] || fail "the limited filesystem is already below the mark: $free bytes free"
fallocate -l "$fill" "$LIMITED/filler" || fail "the limited filesystem could not be filled"
echo "free before the fill: $free bytes; after: $(free_bytes "$LIMITED") bytes"
reserve_awaits depleted
[ ! -e "$RESERVE_DIR/cyfr-storage-reserve" ] || fail "the depleted cell kept its reserve file"
before="$(free_bytes "$LIMITED")"
echo "depleted, the reserve file freed: $before bytes free"

note="$(field "$(reserve note "$reserve_token")" note)"
[ "$note" = "{:unavailable, :storage_reserve}" ] || fail "a note write was not refused: $note"
echo "notes.keep -> $note"

standing="$(field "$(reserve revoke "$ROOT" "$reserve_token" "$client_id")" standing)" ||
  fail "the device's revocation did not complete while depleted"
[ "$standing" = revoked ] || fail "the revocation answered $standing"
after="$(free_bytes "$LIMITED")"
echo "pairing.revoke, confirmed by its request -> $standing; it spent $((before - after)) bytes of the reserve"

step "the depleted cell restarted: still depleted, the revocation still there"
reserve_stop
reserve_start
[ "$(field "$(reserve state)" state)" = depleted ] || fail "the restart reopened ordinary admission"
[ "$(field "$(reserve standing "$client_id")" standing)" = revoked ] ||
  fail "the revocation is not there after the restart"
echo "restarted depleted; $client_id is revoked"
reserve_stop
docker rm -f "$RESERVE_HOLDER" >/dev/null
RESERVE_HOLDER=""

step "the cyfr release boots on $ADAPTER, migrates itself, refuses loudly, restores from its backup, consumes a declared restore and keeps its storage reserve"
