#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Run a fetch from a registry, up to three times: scripts/ci/retry.sh CMD [ARGS...]
#
# A registry that answers 500 or 503 usually answers again within the
# minute. Only for a command that is safe to repeat. The gap is
# RETRY_GAP_S seconds, default 30.
#
# Exit status is CMD's last, 64 with no command.
set -uo pipefail

[ "$#" -gt 0 ] || { echo "usage: $0 CMD [ARGS...]" >&2; exit 64; }

for attempt in 1 2; do
  "$@" && exit 0
  echo "==> $1 failed (attempt $attempt of 3), trying again in ${RETRY_GAP_S:-30} s" >&2
  sleep "${RETRY_GAP_S:-30}"
done
exec "$@"
