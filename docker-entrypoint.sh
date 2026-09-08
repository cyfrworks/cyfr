#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -e

# Seed /app/seed/aqua/ from /app/aqua-defaults/ on first start.
# /app/seed/aqua is the AQUA tree every new athanor reads — the soul, its
# roles and its scrolls. We bake defaults into /app/aqua-defaults at image
# build time and copy them on first start so the directory always has a
# working soul and roles — works whether /app/seed/aqua is the image
# filesystem or a host bind mount.
#
# FIRST start only: the mount is the operator's to edit, so a copy that ran
# every boot would revert their changes to the shipped files. The guard is
# the soul file, the one thing every shipped tree has. It used to be
# agent.json, which is the v2 shape Compendium.AquaTemplate.seed_check/0
# rejects — never present, so the condition was always true and every
# restart overwrote the mount. The copy is additive: a mount still shaped
# around an older agents/ directory gets the shipped tree beside it and
# nothing removed.
if [ -d /app/aqua-defaults ] && [ ! -f /app/seed/aqua/aqua.md ]; then
    mkdir -p /app/seed/aqua
    cp -r /app/aqua-defaults/. /app/seed/aqua/
fi

# Fix ownership of bind-mounted data directories.
# No-op when using Docker named volumes; needed for host bind mounts on Linux.
chown -R app:app /app/data /app/seed/aqua 2>/dev/null || true

# Drop to non-root user and exec the release command
exec gosu app "$@"
