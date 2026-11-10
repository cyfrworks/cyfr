#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# A precondition of a row of tests/load-check/subjects.tsv, its needs
# column: tests/load-check/needs.sh WHAT [NAME]. Exits 0 when WHAT holds;
# otherwise prints why not on one line of stdout and exits 1.
#   postgres   the PostgreSQL server the test runs use accepts a
#              connection: the host and port of CYFR_DATABASE_URL, or of
#              the runner's default, postgres://cyfr:cyfr@localhost:5432
#              (scripts/test-partition-env.exs)
#   docker     a Docker daemon answers
#   env NAME   the environment variable NAME is set and not empty
# Anything else exits 64.
set -uo pipefail

case ${1:-} in
  postgres)
    url=${CYFR_DATABASE_URL:-postgres://cyfr:cyfr@localhost:5432/cyfr_test}
    python3 -I - "$url" <<'PY'
import socket, sys
from urllib.parse import urlsplit
url = urlsplit(sys.argv[1])
host, port = url.hostname or "localhost", url.port or 5432
try:
    socket.create_connection((host, port), timeout=5).close()
except OSError as error:
    print(f"no PostgreSQL server answers at {host}:{port} ({error.strerror or error})")
    sys.exit(1)
PY
    ;;
  docker)
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || { echo 'no Docker daemon answers (docker version)'; exit 1; }
    ;;
  env)
    [ "$#" = 2 ] && [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo 'usage: needs.sh env NAME' >&2; exit 64; }
    [ -n "${!2:-}" ] || { echo "$2 is not set"; exit 1; }
    ;;
  *) echo 'usage: needs.sh postgres | docker | env NAME' >&2; exit 64 ;;
esac
