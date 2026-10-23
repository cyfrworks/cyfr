#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The `cyfr` release, built as `Dockerfile` builds it (MIX_ENV=prod, the
# adapter chosen at compile time by CYFR_DATABASE, `mix release cyfr`),
# booted against a FRESH database of that adapter with auto-migration on
# (tests/release-boot/release.sh). Six cases, in order:
#
#   boots    the deployment file `cyfr init` writes, a local home — the
#            stack's keys, the empty CORS allowlist, authentication
#            configured — with CYFR_AUTO_MIGRATE=on. The release migrates
#            the schema itself (nothing else can: the database carries no
#            schema before it starts) and answers /api/health/ready, the
#            readiness check the image's HEALTHCHECK runs. A boot that
#            raises, exits or never answers fails here, with its whole log.
#            `Cyfr.Release.live_slots/0`, the offline read `cyfr update`
#            makes before it snapshots a cell, run as the update runs it
#            (`bin/cyfr eval`, which starts no application), answers the
#            running cell's one slot under this release, and none once the
#            cell has stopped. Then a public home `cyfr init --access public
#            --domain cyfr.example.com` writes answers as https://cyfr.example.com
#            (`Sanctum.Person.home()`), with nothing written for it but the
#            test's ports, and its proxy listener answers readiness.
#
#   refuses  the same environment with the wildcard CORS allowlist, which a
#            release with authentication configured must refuse at boot.
#            The release must exit non-zero naming CORS: a boot that raises
#            is loud, never a container that looks started.
#
#   access   every boot refusal of tests/fixtures/access_modes.json's `boot`
#            vectors that a release can be given: the release exits
#            non-zero printing `[Cyfr] FATAL: <the vector's sentence>`. A
#            copy of the release, the run's own, reads the vector's `file`
#            as the .env at its root, where a release reads one, and the
#            vector's `process` reaches it as its environment, so the
#            source rules (an access setting .env and the environment assign
#            differently, the compose file's assertion from .env) are the
#            release's own read. Then the bare release in a network
#            namespace of its own (a container's, with no network, holding
#            172.16.230.2/24 on a dummy interface, the compose stack's
#            loopback-listener address) is refused that bind in `local`
#            without the compose file's assertion, while the same address
#            binds there and the same boot with the assertion in its
#            environment configures.
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
# schema in it, as a role that may create databases: the boots case's public
# home and the restores case create three databases beside it, named for
# this run (`pg_run_database`), and drop them when it ends; it drops no
# database it did not create, so runs that share one server and one URL
# leave each other's alone. A run killed before its cleanup leaves its three
# behind, under its own names. The dump and the
# restore run in the postgres:18.6 image, with this host's network. The
# cells' deployment files come from the `cyfr` command line, built from
# apps/codex with this host's go, whose access switch asks Docker for the
# project's containers. The access case's namespace is a debian:trixie-slim
# container with CAP_NET_ADMIN, on a kernel with the dummy network
# interface. Set RELEASE_BOOT_SKIP_BUILD=1 to reuse the release a previous
# run built, and RELEASE_BOOT_KEEP=1 to keep the scratch directory, its
# logs and the databases.

# The PostgreSQL client the restore case runs, the server's own major.
PG_IMAGE="postgres:18.6"
CREATED_DATABASES=()
# This run among the runs sharing a server: its process id and eight random
# hex digits.
RUN_ID="$$_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"

# A PostgreSQL client command in the postgres image, on this host's network,
# its container named after the run under PROOF_RUN_PREFIX, so one whose
# caller was killed is found by that name.
pg() {
  docker run --rm ${PROOF_RUN_PREFIX:+--name "${PROOF_RUN_PREFIX}cyfr-release-boot-$RUN_ID-pg-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"} \
    --network host -e PGOPTIONS=--client-min-messages=warning "$PG_IMAGE" "$@"
}

# CYFR_DATABASE_URL with its database renamed to `$1`.
pg_url() {
  local base="${CYFR_DATABASE_URL%%\?*}" query=""
  [ "$base" = "$CYFR_DATABASE_URL" ] || query="?${CYFR_DATABASE_URL#*\?}"
  echo "${base%/*}/$1$query"
}

# The name of this run's database for `$1` (address, cell, restore):
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

# The access case's vectors: every refused vector of the boot vectors `$1`
# a release can be given, one directory each under `$2`, and the count on
# stdout. Each holds `name`, `sentence`, `file.env` (the vector's file,
# each value single-quoted, so the release's reader takes it literally;
# absent when the vector reads no .env) and `process` (NUL-terminated
# NAME=value words that make the environment merged over that file the
# vector's process: each it assigns that the file does not, or assigns
# otherwise), and, where the vector names no builds URL, an empty builds
# key, which the release would refuse without one. `$2/strip` lists every
# name a vector assigns and the compose file's assertion: the settings a
# vector's boot starts from hold none of them (`access_settings`).
access_vectors() {
  python3 -I - "$1" "$2" <<'PY'
import json, os, sys
vectors, out = json.load(open(sys.argv[1]))["boot"], sys.argv[2]
names = {"CYFR_LOCAL_INGRESS_ASSERTED"}
for v in vectors:
    for side in ("file", "process"):
        names |= set((v["input"].get(side) or {}).keys())
open(os.path.join(out, "strip"), "w").write("\n".join(sorted(names)) + "\n")
n = 0
for v in vectors:
    if not v["input"]["release?"] or "refusal" not in v:
        continue
    file, process = v["input"]["file"], v["input"]["process"]
    # A merged environment holds every name .env assigns; a blank one the
    # vector's process may leave out, since blank counts as unset.
    for key, val in (file or {}).items():
        if key not in process and val.strip() != "":
            sys.exit(f"the vector {v['name']!r} assigns {key} in .env alone, which no merged environment does")
    words = [f"{k}={val}" for k, val in sorted(process.items()) if file is None or file.get(k) != val]
    if (process.get("CYFR_LOCUS_BUILDS_URL") or "") == "":
        words.append("CYFR_LOCUS_BUILDS_KEY=")
    n += 1
    d = os.path.join(out, f"{n:03d}")
    os.mkdir(d)
    open(os.path.join(d, "name"), "w").write(v["name"])
    open(os.path.join(d, "sentence"), "w").write(v["refusal"]["sentence"])
    open(os.path.join(d, "process"), "wb").write(b"".join(w.encode() + b"\0" for w in words))
    if file is not None:
        lines = []
        for k, val in sorted(file.items()):
            if "'" in val or "\n" in val:
                sys.exit(f"the vector {v['name']!r}'s .env value of {k} cannot be written single-quoted")
            lines.append(f"{k}='{val}'\n")
        open(os.path.join(d, "file.env"), "w").write("".join(lines))
print(n)
PY
}

# The deployment file `$1` without any name `$2` (a `strip` list) lists.
access_settings() {
  grep -v -E "^($(paste -sd '|' "$2"))=" "$1" || true
}

# A refused boot's deadline: `timeout -k BOOT_KILL_AFTER BOOT_DEADLINE`,
# whose exit is 124 when the release ended at TERM and 137 when it had to
# be killed.
BOOT_DEADLINE="${BOOT_DEADLINE:-120}"
BOOT_KILL_AFTER="${BOOT_KILL_AFTER:-10}"

# Whether a boot that exited `$1`, its output in `$2`, refused with
# `[Cyfr] FATAL: $3`: a non-zero exit of its own, never the deadline's
# (124, or 137 for a release killed after it), and the sentence in its
# output. A release that prints the sentence and then hangs is no refusal.
boot_refused() {
  local status="$1" log="$2" sentence="$3"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$status" -ne 137 ] &&
    grep -qF -- "[Cyfr] FATAL: $sentence" "$log"
}

# The boot of vector `$1` by the release copy `$2` on cell `$3`: the
# vector's file as the .env at the copy's root, or none, and the cell's
# settings with the vector's process words over them; the boot's output
# on stdout and its exit status the boot's, ended at the deadline.
access_vector_boot() {
  local vector="$1" release="$2" cell="$3"
  local -a words=()
  rm -f "$release/.env"
  [ ! -f "$vector/file.env" ] || cp "$vector/file.env" "$release/.env"
  mapfile -d '' -t words <"$vector/process"
  cell_env "$cell" ${words[@]+"${words[@]}"} timeout -k "$BOOT_KILL_AFTER" "$BOOT_DEADLINE" "$release/bin/cyfr" start
}

# Sourced (tests/release-boot/names-test.sh, access-test.sh), the script
# defines the functions above and runs nothing.
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-release-boot-XXXXXX")"
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
    for cell in "$RESERVE" "$COPY" "$ORIGIN" "$ADDRESS" "$CELL"; do
      if [ -n "$cell" ] && [ -f "$cell/boot.log" ]; then
        log_tail "$cell"
        break
      fi
    done
  fi
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  # The reserve case's filesystem goes with the container that holds it,
  # and the access case's namespace with its own.
  [ -z "$RESERVE_HOLDER" ] || docker rm -f "$RESERVE_HOLDER" >/dev/null 2>&1 || true
  [ -z "$NS_HOLDER" ] || docker rm -f "$NS_HOLDER" >/dev/null 2>&1 || true
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
CELL="" ADDRESS="" ORIGIN="" COPY="" RESERVE="" RESERVE_HOLDER="" NS_HOLDER=""
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
VERSION="$(sed -n 's/^ *version: "\([^"]*\)",$/\1/p' "$ROOT/apps/prima/mix.exs")"
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

step "a home given a public name answers at the https origin that name implies"
ADDRESS="$WORK/address"
ADDRESS_URL=""
if [ "$ADAPTER" = postgres ]; then
  ADDRESS_DB="$(pg_run_database address)"
  pg_fresh_database "$ADDRESS_DB"
  ADDRESS_URL="$(pg_url "$ADDRESS_DB")"
fi
cell_new "$ADDRESS" "$ADDRESS_URL" cyfr.example.com
cell_hostname "$ADDRESS" cyfr.example.com "$((PORT + 10))"
server_start "$ADDRESS"
home="$(cell_cyfr "$ADDRESS" rpc 'IO.puts("CYFR_HOME=" <> Sanctum.Person.home())' | sed -n 's/^CYFR_HOME=//p' | tail -1)"
[ "$home" = "https://cyfr.example.com" ] ||
  fail "the home given cyfr.example.com answers as '$home', not https://cyfr.example.com"
echo "Sanctum.Person.home() -> $home"
# The listener its TLS front forwards to, as a front forwards.
proxied="$(curl -sS -m 10 -o "$ADDRESS/proxied.json" -w '%{http_code}' \
  -H 'host: cyfr.example.com' -H 'x-forwarded-proto: https' -H 'x-forwarded-for: 127.0.0.1' \
  "http://127.0.0.1:$(cell_proxy_port "$ADDRESS")/api/health/ready")" || proxied="none"
[ "$proxied" = 200 ] || fail "the public home's proxy listener answered readiness with $proxied, not 200"
echo "its proxy listener on 127.0.0.1:$(cell_proxy_port "$ADDRESS"): GET /api/health/ready -> 200 $(cat "$ADDRESS/proxied.json")"
server_stop "$ADDRESS"

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
# Case 3: every boot refusal of the access vectors, and the bind a namespace
# shows the release refusing
# ---------------------------------------------------------------------------

ACCESS="$WORK/access"
ACCESS_REL="$WORK/access-release"
ACCESS_VECTORS="$ACCESS/vectors"

step "access: the release's own copy, which reads a vector's .env at its root"
# A release reads .env only at its own root (RELEASE_ROOT, which the
# release's script computes and no caller sets), so each vector's file is
# written into a copy of this run's own, never into the release the other
# cases and proofs share.
cp -a "$REL" "$ACCESS_REL"
mkdir -p "$ACCESS/home" "$ACCESS_VECTORS"
cp -R "$CELL/data" "$ACCESS/data"
cp -R "$ROOT/seed" "$ACCESS/seed"
echo "copied $REL to $ACCESS_REL"

ACCESS_COUNT="$(access_vectors "$ROOT/tests/fixtures/access_modes.json" "$ACCESS_VECTORS")"
[ "$ACCESS_COUNT" -gt 0 ] || fail "the access vectors hold no boot refusal a release can be given"
access_settings "$CELL/.env" "$ACCESS_VECTORS/strip" >"$ACCESS/.env"
grep -q '^CYFR_SECRET_KEY_BASE=.' "$ACCESS/.env" || fail "the access cell's settings lost the cell's key base"

step "access: $ACCESS_COUNT boot refusals, each the vector's FATAL sentence and a non-zero exit"
for vector in "$ACCESS_VECTORS"/*/; do
  vector="${vector%/}"
  name="$(cat "$vector/name")"
  sentence="$(cat "$vector/sentence")"
  set +e
  access_vector_boot "$vector" "$ACCESS_REL" "$ACCESS" >"$vector/boot.log" 2>&1
  status=$?
  set -e
  if ! boot_refused "$status" "$vector/boot.log" "$sentence"; then
    echo "----- the boot log of the vector '$name' -----" >&2
    redact_log "$ACCESS" <"$vector/boot.log" >&2 || echo "(the log could not be redacted, so it is not printed)" >&2
    fail "the vector '$name' did not refuse the boot with exit non-zero and '[Cyfr] FATAL: $sentence' (exit $status)"
  fi
  echo "refused, exit $status: $name"
done
rm -f "$ACCESS_REL/.env"

step "access: in a network namespace holding 172.16.230.2, a local release without the assertion is refused that bind"
# The namespace is a container's of this run's own, with no network and
# CAP_NET_ADMIN, which adds a dummy interface holding the compose stack's
# loopback-listener address: unshare -r's uid map is what the host's
# AppArmor restriction on unprivileged user namespaces refuses, here and
# on the runner, and it stays as the host sets it. The release, this
# checkout's, runs in it as this user on the host's own /usr.
NS_ADDRESS=172.16.230.2
NS="$WORK/ns"
mkdir -p "$NS/home" "$NS/tmp"
cp "$ACCESS/.env" "$NS/.env"
cp -R "$CELL/data" "$NS/data"
cp -R "$ROOT/seed" "$NS/seed"
NS_HOLDER="$(docker run -d ${PROOF_RUN_PREFIX:+--name "${PROOF_RUN_PREFIX}cyfr-release-boot-$RUN_ID-ns"} --network none --cap-add NET_ADMIN --user 0 --hostname "$(hostname)" \
  -v /usr:/usr:ro -v /etc/ld.so.cache:/etc/ld.so.cache:ro -v "$ROOT:$ROOT:ro" -v "$WORK:$WORK" \
  debian:trixie-slim sleep infinity)" || fail "no container could hold the namespace"
docker exec "$NS_HOLDER" sh -c "ip link add cyfrdummy0 type dummy && ip addr add $NS_ADDRESS/24 dev cyfrdummy0 &&
  ip link set cyfrdummy0 up && ip link set lo up" ||
  fail "no dummy interface could hold $NS_ADDRESS in the namespace (the kernel's dummy network interface is needed)"
docker exec "$NS_HOLDER" ip -4 -o addr show dev cyfrdummy0 | grep -q " $NS_ADDRESS/24 " ||
  fail "the namespace's dummy interface does not hold $NS_ADDRESS"
docker exec -u "$(id -u):$(id -g)" "$NS_HOLDER" python3 -I -c '
import socket, sys
s = socket.socket()
s.bind((sys.argv[1], int(sys.argv[2])))
s.listen()
print("bound", s.getsockname())' "$NS_ADDRESS" "$PORT" ||
  fail "this user cannot bind $NS_ADDRESS:$PORT in the namespace, so a refusal there would prove nothing"
echo "the namespace holds $NS_ADDRESS on a dummy interface, which this user binds"

# The bind's sentence, the vectors' own.
NS_SENTENCE="$(python3 -I -c '
import json, sys
for v in json.load(open(sys.argv[1]))["boot"]:
    r = v.get("refusal")
    if r and r["code"] == "access_bind_not_loopback" and r["payload"].get("address") == sys.argv[2]:
        print(r["sentence"]); break' "$ROOT/tests/fixtures/access_modes.json" "$NS_ADDRESS")"
[ -n "$NS_SENTENCE" ] || fail "the access vectors hold no refusal of a bind to $NS_ADDRESS"

# The release in the namespace: cell `$NS`'s environment, a local home
# with builds off binding the namespace's address, and `$@`'s NAME=value
# words, then the release's command; its output on stdout.
ns_cyfr() {
  local words=()
  while [ $# -gt 0 ] && [[ "$1" == [A-Z]*=* ]]; do
    words+=("$1")
    shift
  done
  cell_env "$NS" CYFR_ACCESS=local CYFR_BIND_ADDRESS="$NS_ADDRESS" CYFR_LOCUS_BUILDS_KEY= \
    RELEASE_TMP="$NS/tmp" RELEASE_DISTRIBUTION=none \
    ${words[@]+"${words[@]}"} env >"$NS/container.env"
  docker exec -u "$(id -u):$(id -g)" -w "$NS" --env-file "$NS/container.env" "$NS_HOLDER" \
    timeout -k "$BOOT_KILL_AFTER" "$BOOT_DEADLINE" "$REL/bin/cyfr" "$@"
}

set +e
ns_cyfr start >"$NS/refused.log" 2>&1
status=$?
set -e
if ! boot_refused "$status" "$NS/refused.log" "$NS_SENTENCE"; then
  redact_log "$NS" <"$NS/refused.log" >&2 || echo "(the log could not be redacted, so it is not printed)" >&2
  fail "the release bound $NS_ADDRESS in local without the assertion, or refused it otherwise (exit $status)"
fi
echo "refused, exit $status: $(grep -oF -- "[Cyfr] FATAL: $NS_SENTENCE" "$NS/refused.log" | head -1)"

set +e
ns_cyfr CYFR_LOCAL_INGRESS_ASSERTED=true eval 'IO.puts("CYFR_ACCESS_CONFIGURED")' >"$NS/asserted.log" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ] || ! grep -qx 'CYFR_ACCESS_CONFIGURED' "$NS/asserted.log"; then
  redact_log "$NS" <"$NS/asserted.log" >&2 || echo "(the log could not be redacted, so it is not printed)" >&2
  fail "with the compose file's assertion in its environment, the release in the namespace did not configure (exit $status)"
fi
echo "with CYFR_LOCAL_INGRESS_ASSERTED=true in its environment, the same release configures for $NS_ADDRESS"
docker rm -f "$NS_HOLDER" >/dev/null
NS_HOLDER=""

# ---------------------------------------------------------------------------
# Case 4: a backup of the four parts, restored and booted elsewhere
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
# events over /mcp, as the person's client replays them.
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
  body="$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"thread","arguments":{"action":"events","thread":"%s"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"release-boot","version":"0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' "$thread_id")"
  answer="$(curl -fsS -m 30 -X POST "http://127.0.0.1:$PORT/mcp" \
    -H "authorization: Bearer $token" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' -H 'mcp-protocol-version: 2026-07-28' \
    -H 'mcp-method: tools/call' -H 'mcp-name: thread' -d "$body")" ||
    fail "$what: the thread was not served over /mcp"
  # The replay from the start: the thread's one message, and the cursor
  # at its seq.
  if printf '%s' "$answer" | python3 -c '
import json, sys
result = json.load(sys.stdin)["result"]
events = json.loads(result["content"][0]["text"])
messages = events["messages"]
sys.exit(0 if not result["isError"] and events["thread"] == sys.argv[1]
         and [m["content"] for m in messages] == ["the backup proof thread"]
         and events["cursor"] == messages[-1]["seq"] else 1)' "$thread_id"; then
    echo "$what: thread.events -> the thread's message"
  else
    fail "$what: thread.events answered without the message: $answer"
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
  docker run --rm -i ${PROOF_RUN_PREFIX:+--name "${PROOF_RUN_PREFIX}cyfr-release-boot-$RUN_ID-restore"} \
    --network host "$PG_IMAGE" pg_restore --no-owner --exit-on-error -d "$(pg_url "$RESTORE_DB")" <"$WORK/cell.dump" ||
    fail "the dump did not restore into $RESTORE_DB"
  sed -i "s|^CYFR_DATABASE_URL=.*|CYFR_DATABASE_URL=$(pg_url "$RESTORE_DB")|" "$COPY/.env"
  # The origin's database goes, so a copy that still reached it could not pass.
  pg psql -q "$CYFR_DATABASE_URL" -c "DROP DATABASE \"$ORIGIN_DB\"" || fail "could not drop $ORIGIN_DB"
fi
# The origin's storage root goes too, for the same reason.
rm -rf "$ORIGIN"
sed -i 's/^CYFR_AUTO_MIGRATE=.*/CYFR_AUTO_MIGRATE=off/' "$COPY/.env"
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
# Case 5: the same backup, declared restored
# ---------------------------------------------------------------------------

# What `$1` answers to the person's pre-backup session over /mcp: the HTTP
# status of a `thread.events` call.
mcp_status() {
  local body
  body="$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"thread","arguments":{"action":"events","thread":"%s"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"release-boot","version":"0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' "$thread_id")"
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
  RESERVE_HOLDER="$(docker run -d ${PROOF_RUN_PREFIX:+--name "${PROOF_RUN_PREFIX}cyfr-release-boot-$RUN_ID-reserve"} --user "$(id -u):$(id -g)" \
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

      # The list answers only records of an authority-reducing change.
      {:ok, %{confirmations: [%{ref: ^ref}]}} =
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

step "the cyfr release boots on $ADAPTER, migrates itself, answers at the address its access mode implies, refuses loudly, refuses every access setting the vectors refuse and a bind no assertion covers, restores from its backup, consumes a declared restore and keeps its storage reserve"
