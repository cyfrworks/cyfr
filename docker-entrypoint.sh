#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -e

# Seed /app/seed/aqua from /app/aqua-defaults when the soul file is absent.
# This supports both image filesystems and host mounts. Preserve the mount
# on subsequent starts so operator edits remain intact.
if [ -d /app/aqua-defaults ] && [ ! -f /app/seed/aqua/aqua.md ]; then
    mkdir -p /app/seed/aqua
    cp -r /app/aqua-defaults/. /app/seed/aqua/
fi

# Fix ownership of bind-mounted data directories.
# No-op when using Docker named volumes; needed for host bind mounts on Linux.
chown -R app:app /app/data /app/seed/aqua 2>/dev/null || true

# Drop to the non-root user (util-linux's setpriv, part of the base image)
# and exec the release command.
exec setpriv --reuid=app --regid=app --init-groups "$@"
