#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The bridge spawns operator-supplied shell commands by design, so it must
# not run as root. /data is a host bind mount that docker may have created
# root-owned on first run; take ownership while still root, then drop to
# the unprivileged node user for the actual process.
set -eu

if [ "$(id -u)" = "0" ]; then
  mkdir -p /data
  chown -R node:node /data
  exec su-exec node "$@"
fi

exec "$@"
