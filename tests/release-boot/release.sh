# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The `cyfr` release as the release proofs start it, sourced by
# tests/release-boot/boot.sh and the browser harness's scripts: built as
# `Dockerfile` builds it (MIX_ENV=prod, the adapter chosen at compile time
# by CYFR_DATABASE, `mix release cyfr`), started with the environment
# `cyfr init` writes and nothing else of the caller's, and stopped by its
# own `stop`.
#
# The sourcing script sets ADAPTER (sqlite or postgres) and WORK (a scratch
# directory it owns) first. A cell is where one server keeps its state: a
# storage root, a seed tree, a deployment file (`.env`) and, for SQLite, a
# database file. Every function that starts, asks or stops a release names
# the cell it runs; the database of a PostgreSQL cell is the URL its
# deployment file holds, and the listener it answers on is the one its
# deployment file names.
#
# A cell answers on the default listeners under the node name NODE, one at
# a time. A cell given a hostname of its own (`cell_hostname`) answers as
# that name behind a TLS-terminating front, on listeners and under a node
# name of its own, so several such cells run at once.
#
# Environment: RELEASE_BOOT_PORT and RELEASE_BOOT_HOST_API_PORT choose the
# default listeners (4399 and 4398), RELEASE_BOOT_READY_TIMEOUT the seconds
# a boot has to answer readiness (180), and RELEASE_BOOT_SKIP_BUILD=1
# reuses the release a previous run built.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PORT="${RELEASE_BOOT_PORT:-4399}"
HOST_API_PORT="${RELEASE_BOOT_HOST_API_PORT:-4398}"
READY_TIMEOUT="${RELEASE_BOOT_READY_TIMEOUT:-180}"
BUILD_PATH="$ROOT/_build/prod_release_boot_$ADAPTER"
REL="$BUILD_PATH/rel/cyfr"
# Every server running, in the order started: SERVER_PIDS[i] is the
# background `start` of the cell SERVER_CELLS[i].
SERVER_PIDS=()
SERVER_CELLS=()

# A node name of this run's own. The release's default is `cyfr`, which a
# developer's release or the other adapter's leg may still hold on epmd — a
# clash that says nothing about the release.
NODE="cyfr-boot-$ADAPTER-$$"

step() { printf '\n=== %s\n' "$*"; }

fail() {
  echo "::error::$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# The release
# ---------------------------------------------------------------------------

# Building the release runs `mix assets.deploy`, as the image's builder
# stage does, so it leaves digested assets under apps/cyfr/priv/static/ —
# build output of a prod build, not of these proofs.
release_build() {
  if [ "${RELEASE_BOOT_SKIP_BUILD:-}" = "1" ] && [ -x "$REL/bin/cyfr" ]; then
    step "reusing the $ADAPTER release at $REL"
  else
    step "building the cyfr release for $ADAPTER (MIX_ENV=prod, as Dockerfile builds it)"
    (
      cd "$ROOT" || exit 1
      export MIX_ENV=prod MIX_BUILD_PATH="$BUILD_PATH" CYFR_DATABASE="$ADAPTER"
      mix deps.get --only prod &&
        mix compile &&
        mix assets.deploy &&
        mix release cyfr --overwrite
    ) || fail "the $ADAPTER release did not build"
  fi

  [ -x "$REL/bin/cyfr" ] || fail "no release at $REL/bin/cyfr"
}

# ---------------------------------------------------------------------------
# Cells
# ---------------------------------------------------------------------------

# A new cell at `$1`: an empty storage root, a copy of the repository's
# seed tree, and a deployment file holding the environment `cyfr init`
# writes into `.env` — the stack's keys minted for this cell alone as `cyfr
# init` mints them (32 random bytes as 64 hexadecimal digits, and a key
# base), an explicit empty CORS allowlist, authentication configured (the
# client id `.env.example` ships), builds on with their URL and key
# together, and auto-migration on. CYFR_DATABASE is the adapter the release
# was COMPILED for; runtime.exs refuses a disagreement. `$2` is the
# PostgreSQL URL of the cell's database, ignored for SQLite.
cell_new() {
  local cell="$1" url="${2:-}"
  mkdir -p "$cell/data" "$cell/home"
  cp -R "$ROOT/seed" "$cell/seed"

  {
    echo "CYFR_DATABASE=$ADAPTER"
    echo "CYFR_AUTO_MIGRATE=true"
    echo "CYFR_PORT=$PORT"
    echo "CYFR_BIND_ADDRESS=127.0.0.1"
    echo "CYFR_HOST=localhost"
    echo "CYFR_HOST_API_BIND=127.0.0.1"
    echo "CYFR_HOST_API_PORT=$HOST_API_PORT"
    echo "CYFR_CORS_ALLOWED_ORIGINS="
    echo "CYFR_SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')"
    echo "CYFR_LOCUS_BACKENDS_KEY=$(openssl rand -hex 32)"
    echo "CYFR_OPUS_KEY=$(openssl rand -hex 32)"
    echo "OPUS_SERVICE_ID=wrk_opus"
    echo "CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100"
    echo "CYFR_LOCUS_BUILDS_KEY=$(openssl rand -hex 32)"
    echo "CYFR_GITHUB_CLIENT_ID=Ov23lib66tiIwXkgUpwm"
    echo "CYFR_PLATFORM_ADMIN_EMAILS=operator@example.com"
    echo "CYFR_BEHIND_PROXY=false"
    echo "CYFR_PRIVATE_EGRESS_TARGETS=locus-backends"
    if [ "$ADAPTER" = postgres ]; then echo "CYFR_DATABASE_URL=$url"; fi
  } >"$cell/.env"
}

# Cell `$1` answers as the hostname `$2`, on the listener port `$3` and the
# host API port `$4`, as a TLS deployment behind the stack's Caddy answers
# (`cyfr init`'s TLS answer): CYFR_HOST names it, CYFR_PUBLIC_URL is
# https://`$2`, the origin every policy of the server is derived for
# (`Sanctum.origin/0`), and CYFR_BEHIND_PROXY=true, since the front that
# terminates TLS for it (tests/browser/lib.mjs) forwards as Caddy does. Its
# node name is its own (`$cell/node`), so it runs beside the other cells
# of the run.
cell_hostname() {
  local cell="$1" host="$2" port="$3" api="$4"
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ||
    fail "not a lowercase dotted hostname: '$host'"
  [[ "$port" =~ ^[0-9]+$ && "$api" =~ ^[0-9]+$ && "$port" != "$api" ]] ||
    fail "cell $cell needs two distinct listener ports, not '$port' and '$api'"
  sed -i \
    -e "s/^CYFR_HOST=.*/CYFR_HOST=$host/" \
    -e "s/^CYFR_PORT=.*/CYFR_PORT=$port/" \
    -e "s/^CYFR_HOST_API_PORT=.*/CYFR_HOST_API_PORT=$api/" \
    -e "s/^CYFR_BEHIND_PROXY=.*/CYFR_BEHIND_PROXY=true/" \
    -e "/^CYFR_PUBLIC_URL=/d" \
    "$cell/.env"
  echo "CYFR_PUBLIC_URL=https://$host" >>"$cell/.env"
  grep -qx "CYFR_HOST=$host" "$cell/.env" || fail "cell $cell does not name $host"
  printf 'cyfr-%s-%s-%s\n' "${host//./-}" "$ADAPTER" "$$" >"$cell/node"
}

# The port cell `$1` answers on: the one its deployment file names.
cell_port() {
  sed -n 's/^CYFR_PORT=//p' "$1/.env" | tail -1
}

# The node name cell `$1`'s server runs under: its own when it has a
# hostname (`cell_hostname`), NODE otherwise.
cell_node() {
  if [ -f "$1/node" ]; then cat "$1/node"; else printf '%s\n' "$NODE"; fi
}

# Run a command with the cell's environment and nothing else of the
# caller's that could steer the release (a CYFR_* left over from a shell, a
# DATABASE_URL): its deployment file, its paths, its keyring file when it
# keeps one apart (`$cell/keyring.json`, exported as CYFR_CRYPTO_KEYRING),
# and `$@`'s leading NAME=value words after that. From the cell, so a crash
# dump or anything else the release writes beside itself lands there, and
# with crash dumps off, so a boot that raises dies at once instead of
# spending its ready window writing one (`ERL_CRASH_DUMP_SECONDS=0`, as the
# workflows set for every Elixir job).
cell_env() {
  local cell="$1"
  shift

  local -a assignments=()
  while IFS= read -r line; do
    [ -n "$line" ] && assignments+=("$line")
  done <"$cell/.env"

  assignments+=(
    "CYFR_DATA_PATH=$cell/data"
    "CYFR_SEED_PATH=$cell/seed"
  )
  if [ "$ADAPTER" = sqlite ] && [ -d "$cell/db" ]; then
    assignments+=("CYFR_DATABASE_PATH=$cell/db/cyfr.db")
  fi
  if [ -f "$cell/keyring.json" ]; then
    assignments+=("CYFR_CRYPTO_KEYRING=$(cat "$cell/keyring.json")")
  fi

  while [ $# -gt 0 ] && [[ "$1" == [A-Z]*=* ]]; do
    assignments+=("$1")
    shift
  done

  local node
  node="$(cell_node "$cell")"
  (
    cd "$cell" || exit 1
    env -i \
      HOME="$cell/home" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" TERM="${TERM:-dumb}" \
      ERL_CRASH_DUMP_SECONDS=0 \
      RELEASE_NODE="$node" \
      "${assignments[@]}" \
      "$@"
  )
}

# The release's own command (`bin/cyfr ...`) in the cell's environment,
# after any leading NAME=value words, which override it.
cell_cyfr() {
  local cell="$1"
  shift
  local -a overrides=()
  while [ $# -gt 0 ] && [[ "$1" == [A-Z]*=* ]]; do
    overrides+=("$1")
    shift
  done
  cell_env "$cell" ${overrides[@]+"${overrides[@]}"} "$REL/bin/cyfr" "$@"
}

# How many migrations the cell's database has not run, as the release
# itself reports them (`Cyfr.Release.pending/0`): the one number that says
# whether a schema is there, whoever put it there.
cell_pending() {
  cell_cyfr "$1" eval \
    'IO.puts("PENDING=" <> Integer.to_string(length(Cyfr.Release.pending())))' \
    | sed -n 's/^PENDING=//p' | tail -1
}

# ---------------------------------------------------------------------------
# A server
# ---------------------------------------------------------------------------

# Start the release on the cell in the background and wait for it to answer
# /api/health/ready on the cell's own listener, the readiness check the
# image's HEALTHCHECK runs; the log is `$cell/boot.log` (appended). A boot
# that raises, exits or never answers fails here, naming the cell, with its
# whole log, and leaves no server behind.
server_start() {
  local cell="$1" port
  port="$(cell_port "$cell")"
  [ -n "$port" ] || fail "cell $cell names no CYFR_PORT"

  # A server left from another run would answer the readiness check below
  # while this boot failed on its ports, and pass for it.
  if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$port/api/health" 2>/dev/null; then
    fail "something already answers on 127.0.0.1:$port — stop it before this proof"
  fi

  local log="$cell/boot.log"
  local mark
  mark="$( [ -f "$log" ] && wc -l <"$log" || echo 0)"
  cell_cyfr "$cell" start >>"$log" 2>&1 &
  SERVER_PIDS+=("$!")
  SERVER_CELLS+=("$cell")

  local ready="" died=""
  for _ in $(seq 1 "$READY_TIMEOUT"); do
    if curl -fsS -o "$cell/ready.json" "http://127.0.0.1:$port/api/health/ready" 2>/dev/null; then
      ready=yes
      break
    fi
    # A boot that raised says so in its log and never answers. `kill -0` on
    # the background job cannot tell: a child that has exited stays a zombie
    # until it is waited for, and `start` runs the VM below a wrapper of its
    # own, so a raise would otherwise cost the whole ready window and be
    # reported as a boot that was merely slow.
    if tail -n "+$((mark + 1))" "$log" | grep -q "Kernel pid terminated\|Application cyfr exited\|application_start_failure"; then
      died=yes
      break
    fi
    sleep 1
  done

  if [ "$ready" != yes ]; then
    echo "----- boot log of cell $cell -----" >&2
    tail -n "+$((mark + 1))" "$log" >&2
    if [ -n "$died" ]; then
      echo "::error::the $ADAPTER release of cell $cell exited while booting, without answering /api/health/ready on 127.0.0.1:$port" >&2
    else
      echo "::error::the $ADAPTER release of cell $cell did not answer /api/health/ready on 127.0.0.1:$port within ${READY_TIMEOUT}s" >&2
    fi
    # A boot that is still going when the window closes is stopped too, so
    # no VM outlives the run that gave up on it.
    server_stop "$cell"
    exit 1
  fi
}

# Stop the server of cell `$1`, or, with no cell, every server running, the
# last started first. `bin/cyfr start` runs the BEAM as a CHILD of the shell
# it starts, so signalling that shell leaves a listening server behind.
# Stopping is the release's own stop; whatever survives it is signalled by
# the cell's node name. Each listener is gone before the next boot asks its
# port; a server whose listener outlives its stop fails the run, named.
server_stop() {
  local only="${1:-}" i outlived=""
  local -a pids=() cells=()
  for ((i = ${#SERVER_CELLS[@]} - 1; i >= 0; i--)); do
    if [ -n "$only" ] && [ "${SERVER_CELLS[i]}" != "$only" ]; then
      pids=("${SERVER_PIDS[i]}" ${pids[@]+"${pids[@]}"})
      cells=("${SERVER_CELLS[i]}" ${cells[@]+"${cells[@]}"})
    elif ! server_halt "${SERVER_PIDS[i]}" "${SERVER_CELLS[i]}"; then
      outlived="${outlived:+$outlived, }cell ${SERVER_CELLS[i]} on 127.0.0.1:$(cell_port "${SERVER_CELLS[i]}")"
    fi
  done
  SERVER_PIDS=(${pids[@]+"${pids[@]}"})
  SERVER_CELLS=(${cells[@]+"${cells[@]}"})
  [ -z "$outlived" ] || fail "the server of $outlived outlived its stop"
}

# Stop the server `start`ed as the background job `$1` on cell `$2`, and
# answer whether its listener is gone.
server_halt() {
  local pid="$1" cell="$2" node port
  node="$(cell_node "$cell")"
  port="$(cell_port "$cell")"
  cell_cyfr "$cell" stop >/dev/null 2>&1 || true
  # A VM that refused the stop, or was still booting and could not take
  # it, would hold the job forever; it gets its window, then the signal.
  # A job that has exited is a zombie until it is waited for.
  for _ in $(seq 1 30); do
    case "$(ps -o stat= -p "$pid" 2>/dev/null)" in '' | Z*) break ;; esac
    sleep 1
  done
  # The node name ends there: another cell's name may begin with this one.
  pkill -f "sname $node( |\$)" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    curl -fsS -m 1 -o /dev/null "http://127.0.0.1:$port/api/health" 2>/dev/null || return 0
    sleep 1
  done
  return 1
}

# Evaluate the fixture (tests/release-boot/fixture.exs) inside the running
# server, as `bin/cyfr rpc`: `$2...` are its arguments, and its one JSON
# line is the answer.
server_fixture() {
  local cell="$1"
  shift
  local args="" arg
  for arg in "$@"; do
    args="$args\"$(printf '%s' "$arg" | sed 's/[\\"]/\\&/g')\","
  done
  cell_cyfr "$cell" rpc \
    "{answer, _} = Code.eval_file(\"$ROOT/tests/release-boot/fixture.exs\"); IO.puts(answer.([${args%,}]))" \
    | sed -n 's/^FIXTURE=//p' | tail -1
}
