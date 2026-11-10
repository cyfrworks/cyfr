#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Runs a command against a PostgreSQL database of its own:
#   tests/load-check/fresh-database.sh URL COMMAND [ARGS...]
# It creates a database on the server URL names, as URL's role, which may
# create databases; names it cyfr_load_check_<pid>_<eight hex digits>;
# runs COMMAND with CYFR_DATABASE_URL naming it; and drops it, forced, on
# every exit, a signal included. tests/release-boot/boot.sh takes the
# database CYFR_DATABASE_URL names as the empty one it migrates and never
# drops it, so each of its runs is given a fresh one here. The client is
# psql in boot.sh's own PG_IMAGE, run as boot.sh runs it.
#
# Its messages name the database and the server without the URL's
# userinfo. Exits with COMMAND's status; 64 on usage; 69 without docker or
# boot.sh's PG_IMAGE line; 1 when the database cannot be created or
# dropped; 129, 130 and 143 on HUP, INT and TERM.
set -uo pipefail

[ "$#" -ge 2 ] || { echo "usage: $0 URL COMMAND [ARGS...]" >&2; exit 64; }
url=$1
shift
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
image=$(sed -n 's/^PG_IMAGE="\([^"]*\)"$/\1/p' "$root/tests/release-boot/boot.sh" 2>/dev/null)
[ -n "$image" ] || { echo 'fresh database: tests/release-boot/boot.sh names no PG_IMAGE' >&2; exit 69; }
command -v docker >/dev/null 2>&1 || { echo 'fresh database: docker is required' >&2; exit 69; }

name="cyfr_load_check_$$_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
base=${url%%\?*} query=
[ "$base" = "$url" ] || query="?${url#*\?}"
# The server as its messages name it: the URL's scheme, host and port,
# without its userinfo, which may hold a password.
server=$(printf '%s' "${base%/*}" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@#\1#')
psql() {
  docker run --rm ${PROOF_RUN_PREFIX:+--name "${PROOF_RUN_PREFIX}fresh-database-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"} \
    --network host -e PGOPTIONS=--client-min-messages=warning "$image" psql -v ON_ERROR_STOP=1 -q "$url" -c "$1"
}

created=false child=
finish() {
  local s=$?
  trap '' INT TERM HUP
  trap - EXIT
  if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi
  if $created && ! psql "DROP DATABASE IF EXISTS \"$name\" WITH (FORCE)" >/dev/null 2>&1; then
    echo "fresh database: could not drop $name on $server" >&2
    [ "$s" != 0 ] || s=1
  fi
  exit "$s"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# A stop during the create still drops it: the name is this run's alone.
created=true
psql "CREATE DATABASE \"$name\"" || { echo "fresh database: could not create $name on $server" >&2; exit 1; }
CYFR_DATABASE_URL="${base%/*}/$name$query" "$@" &
child=$!
status=0
wait "$child" || status=$?
child=
exit "$status"
