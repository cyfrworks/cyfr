#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The `cyfr` release, built as `Dockerfile` builds it (MIX_ENV=prod, the
# adapter chosen at compile time by CYFR_DATABASE, `mix release cyfr`),
# booted against a FRESH database of that adapter with auto-migration on.
# Two cases, in order:
#
#   boots   the environment `cyfr init` writes — the stack's keys, the empty
#           CORS allowlist, authentication configured, CYFR_AUTO_MIGRATE=true.
#           The release migrates the schema itself (nothing else can: the
#           database carries no schema before it starts) and answers
#           /api/health/ready, the readiness check the image's HEALTHCHECK
#           runs. A boot that raises, exits or never answers fails here, with
#           its whole log.
#
#   refuses the same environment with the wildcard CORS allowlist, which a
#           release with authentication configured must refuse at boot. The
#           release must exit non-zero naming CORS: a boot that raises is
#           loud, never a container that looks started.
#
# Nothing else boots a release: the suite starts the application under its
# test configuration, which migrates nothing and reads no `.env`, so a boot
# that cannot migrate its database is invisible to it.
#
# Usage:  tests/release-boot/boot.sh <sqlite|postgres>
#
# Building the release runs `mix assets.deploy`, as the image's builder
# stage does, so it leaves digested assets under apps/cyfr/priv/static/ —
# build output of a prod build, not of this proof.
#
# Postgres needs CYFR_DATABASE_URL pointing at an EXISTING database with no
# schema in it; this script never creates or drops one. Set
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

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PORT="${RELEASE_BOOT_PORT:-4399}"
HOST_API_PORT="${RELEASE_BOOT_HOST_API_PORT:-4398}"
READY_TIMEOUT="${RELEASE_BOOT_READY_TIMEOUT:-180}"
BUILD_PATH="$ROOT/_build/prod_release_boot_$ADAPTER"
REL="$BUILD_PATH/rel/cyfr"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-release-boot-XXXXXX")"
DATA="$WORK/data"
SEED="$WORK/seed"
SERVER_PID=""

# A node name of this run's own. The release's default is `cyfr`, which a
# developer's release or the other adapter's leg may still hold on epmd — a
# clash that says nothing about the release.
NODE="cyfr-boot-$ADAPTER-$$"

step() { printf '\n=== %s\n' "$*"; }

# `bin/cyfr start` runs the BEAM as a CHILD of the shell it starts, so
# signalling that shell leaves a listening server behind. Stopping is the
# release's own stop; whatever survives it is signalled by node name.
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  with_env "$DATA" "$SEED" "" "$REL/bin/cyfr" stop >/dev/null 2>&1 || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  pkill -f "sname $NODE" 2>/dev/null || true
}

cleanup() {
  stop_server
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# The release's own environment, the shape `cyfr init` writes into `.env`:
# the stack's keys, an explicit empty CORS allowlist, authentication
# configured (the client id `.env.example` ships), builds on with their URL
# and key together, and auto-migration on. CYFR_DATABASE is the adapter this
# release was COMPILED for; runtime.exs refuses a disagreement.
release_env() {
  local data="$1"
  local seed="$2"
  local cors="$3"

  cat <<ENV
CYFR_DATABASE=$ADAPTER
CYFR_AUTO_MIGRATE=true
CYFR_DATA_PATH=$data
CYFR_SEED_PATH=$seed
CYFR_PORT=$PORT
CYFR_BIND_ADDRESS=127.0.0.1
CYFR_HOST=localhost
CYFR_HOST_API_BIND=127.0.0.1
CYFR_HOST_API_PORT=$HOST_API_PORT
CYFR_CORS_ALLOWED_ORIGINS=$cors
CYFR_SECRET_KEY_BASE=$SECRET_KEY_BASE
CYFR_MCP_BRIDGE_KEY=$BRIDGE_KEY
CYFR_OPUS_KEY=$WORKER_KEY
OPUS_SERVICE_ID=wrk_opus
CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100
CYFR_LOCUS_BUILDS_KEY=$BUILDS_KEY
CYFR_GITHUB_CLIENT_ID=Ov23lib66tiIwXkgUpwm
CYFR_PLATFORM_ADMIN_EMAILS=operator@example.com
CYFR_BEHIND_PROXY=false
CYFR_PRIVATE_EGRESS_TARGETS=mcp-bridge
ENV
}

# Run a command with that environment and nothing else of the caller's that
# could steer the release (a CYFR_* left over from a shell, a DATABASE_URL).
with_env() {
  local data="$1" seed="$2" cors="$3"
  shift 3

  local -a assignments=()
  while IFS= read -r line; do
    [ -n "$line" ] && assignments+=("$line")
  done <<<"$(release_env "$data" "$seed" "$cors")"

  if [ "$ADAPTER" = postgres ]; then
    assignments+=("CYFR_DATABASE_URL=$CYFR_DATABASE_URL")
  fi

  # From the scratch directory, so a crash dump or anything else the
  # release writes beside itself lands there and not in the checkout, and
  # with crash dumps off, so a boot that raises dies at once instead of
  # spending its ready window writing one (`ERL_CRASH_DUMP_SECONDS=0`, as
  # the workflows set for every Elixir job).
  (
    cd "$WORK" || exit 1
    env -i \
      HOME="$WORK/home" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" TERM="${TERM:-dumb}" \
      ERL_CRASH_DUMP_SECONDS=0 \
      RELEASE_NODE="$NODE" \
      "${assignments[@]}" \
      "$@"
  )
}

# How many migrations the database has not run, as the release itself
# reports them (`Cyfr.Release.pending/0`): the one number that says whether
# a schema is there, whoever put it there.
pending_count() {
  with_env "$DATA" "$SEED" "" "$REL/bin/cyfr" eval \
    'IO.puts("PENDING=" <> Integer.to_string(length(Cyfr.Release.pending())))' \
    | sed -n 's/^PENDING=//p' | tail -1
}

# ---------------------------------------------------------------------------
# Build the release the way the image builds it
# ---------------------------------------------------------------------------

if [ "${RELEASE_BOOT_SKIP_BUILD:-}" = "1" ] && [ -x "$REL/bin/cyfr" ]; then
  step "reusing the $ADAPTER release at $REL"
else
  step "building the cyfr release for $ADAPTER (MIX_ENV=prod, as Dockerfile builds it)"
  export MIX_ENV=prod
  export MIX_BUILD_PATH="$BUILD_PATH"
  export CYFR_DATABASE="$ADAPTER"
  mix deps.get --only prod
  mix compile
  mix assets.deploy
  mix release cyfr --overwrite
  unset MIX_ENV MIX_BUILD_PATH CYFR_DATABASE
fi

[ -x "$REL/bin/cyfr" ] || {
  echo "::error::no release at $REL/bin/cyfr" >&2
  exit 1
}

# The keys the stack runs on, minted for this run alone, as `cyfr init`
# mints them: 32 random bytes as 64 hexadecimal digits, and a key base.
WORKER_KEY="$(openssl rand -hex 32)"
BRIDGE_KEY="$(openssl rand -hex 32)"
BUILDS_KEY="$(openssl rand -hex 32)"
SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')"

mkdir -p "$WORK/home" "$DATA"
cp -R "$ROOT/seed" "$SEED"

# ---------------------------------------------------------------------------
# Case 1: a fresh database, migrated by the boot, answering its health check
# ---------------------------------------------------------------------------

step "the $ADAPTER database carries no schema before the release starts"
before="$(pending_count)"
if [ "${before:-0}" -lt 1 ]; then
  echo "::error::the $ADAPTER database is not fresh: it reports $before pending migrations" >&2
  echo "Point CYFR_DATABASE_URL at an empty database (or remove the SQLite file)." >&2
  exit 1
fi
echo "pending migrations before the boot: $before"

# A server left from another run would answer the readiness check below
# while this boot failed on its ports, and pass for it.
if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/health" 2>/dev/null; then
  echo "::error::something already answers on 127.0.0.1:$PORT — stop it before this proof" >&2
  exit 1
fi

step "booting the release against a fresh $ADAPTER database with auto-migration on"
LOG="$WORK/boot.log"
with_env "$DATA" "$SEED" "" "$REL/bin/cyfr" start >"$LOG" 2>&1 &
SERVER_PID=$!

ready=""
died=""
for _ in $(seq 1 "$READY_TIMEOUT"); do
  if curl -fsS -o "$WORK/ready.json" "http://127.0.0.1:$PORT/api/health/ready" 2>/dev/null; then
    ready=yes
    break
  fi
  # A boot that raised says so in its log and never answers. `kill -0` on
  # the background job cannot tell: a child that has exited stays a zombie
  # until it is waited for, and `start` runs the VM below a wrapper of its
  # own, so a raise would otherwise cost the whole ready window and be
  # reported as a boot that was merely slow.
  if grep -q "Kernel pid terminated\|Application cyfr exited\|application_start_failure" "$LOG"; then
    died=yes
    break
  fi
  sleep 1
done

if [ "$ready" != yes ]; then
  if [ -n "$died" ]; then
    echo "::error::the $ADAPTER release exited while booting, without answering /api/health/ready" >&2
  else
    echo "::error::the $ADAPTER release did not answer /api/health/ready within ${READY_TIMEOUT}s" >&2
  fi

  wait "$SERVER_PID" 2>/dev/null || true
  echo "----- boot log -----" >&2
  cat "$LOG" >&2
  exit 1
fi

echo "GET /api/health/ready -> 200 $(cat "$WORK/ready.json")"

step "the boot migrated the schema itself"
if ! grep -q "== Migrated" "$LOG"; then
  echo "::error::the boot log does not report a migration it ran" >&2
  cat "$LOG" >&2
  exit 1
fi
grep -E "== (Running|Migrated)" "$LOG"

# Liveness beside readiness, so a half-open server cannot pass as a boot.
curl -fsS "http://127.0.0.1:$PORT/api/health" >"$WORK/health.json"
echo "GET /api/health -> 200 $(cat "$WORK/health.json")"

stop_server

after="$(pending_count)"
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
with_env "$DATA" "$SEED" "*" "$REL/bin/cyfr" start >"$REFUSAL_LOG" 2>&1
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

step "the cyfr release boots on $ADAPTER, migrates itself, and refuses loudly"
