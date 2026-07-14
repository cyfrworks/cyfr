#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -e

# Seed /app/aqua/ from /app/aqua-defaults/ on first start.
# Compendium.MCP reads aqua/agent.json from /app/aqua at runtime. We bake
# defaults into /app/aqua-defaults at image build time and copy them on
# first start so the directory always has working orchestrators — works
# whether /app/aqua is the image filesystem or a host bind mount.
if [ -d /app/aqua-defaults ] && [ ! -f /app/aqua/agent.json ]; then
    mkdir -p /app/aqua
    cp -r /app/aqua-defaults/. /app/aqua/
fi

# Fix ownership of bind-mounted data directories.
# No-op when using Docker named volumes; needed for host bind mounts on Linux.
chown -R app:app /app/data /app/components /app/aqua 2>/dev/null || true

# Drop to non-root user and exec the release command
exec gosu app "$@"
