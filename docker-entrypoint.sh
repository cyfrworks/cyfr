#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -e

# Seed /app/aqua/ from /app/aqua-defaults/ on first start.
# /app/aqua is the AQUA agent template every new athanor is given. We bake
# defaults into /app/aqua-defaults at image build time and copy them on
# first start so the directory always has working orchestrators — works
# whether /app/aqua is the image filesystem or a host bind mount.
if [ -d /app/aqua-defaults ] && [ ! -f /app/aqua/agent.json ]; then
    mkdir -p /app/aqua
    cp -r /app/aqua-defaults/. /app/aqua/
fi

# Seed /app/components/_bundle/ from /app/components-defaults/ on first start.
# The bundle is what every athanor is provisioned from; without it Home
# cannot be provisioned at boot. Same shape as the AQUA template above:
# an empty (or absent) components dir gets the baked copy, a pre-populated
# bind mount is left alone.
if [ -d /app/components-defaults/_bundle ] && [ ! -d /app/components/_bundle ]; then
    mkdir -p /app/components
    cp -r /app/components-defaults/. /app/components/
fi

# Fix ownership of bind-mounted data directories.
# No-op when using Docker named volumes; needed for host bind mounts on Linux.
chown -R app:app /app/data /app/components /app/aqua 2>/dev/null || true

# Drop to non-root user and exec the release command
exec gosu app "$@"
