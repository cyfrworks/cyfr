#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -e

# Seed /app/seed/aqua/ from /app/aqua-defaults/ on first start.
# /app/seed/aqua is the AQUA agent template every new athanor is given. We
# bake defaults into /app/aqua-defaults at image build time and copy them on
# first start so the directory always has working orchestrators — works
# whether /app/seed/aqua is the image filesystem or a host bind mount.
if [ -d /app/aqua-defaults ] && [ ! -f /app/seed/aqua/agent.json ]; then
    mkdir -p /app/seed/aqua
    cp -r /app/aqua-defaults/. /app/seed/aqua/
fi

# Fix ownership of bind-mounted data directories.
# No-op when using Docker named volumes; needed for host bind mounts on Linux.
chown -R app:app /app/data /app/seed/aqua 2>/dev/null || true

# Drop to non-root user and exec the release command
exec gosu app "$@"
