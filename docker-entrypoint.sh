#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -e

# `cyfr restore` sets CYFR_RESTORE_INCOMPLETE in .env, which the cyfr
# service reads, from before the first part of a snapshot lands until the
# restore is declared; until then the database may be the snapshot's with
# nothing to suspend the authority it carried, so nothing runs. The
# restore's own offline evals set it empty. The name and the exit are
# tests/fixtures/restore_barrier.json's, which the CLI's tests and the
# Compose proof's restore case hold this test to.
if [ -n "${CYFR_RESTORE_INCOMPLETE:-}" ]; then
    echo "cyfr: the restore of ${CYFR_RESTORE_INCOMPLETE} has not been declared (CYFR_RESTORE_INCOMPLETE is set in .env); refusing to start. Run 'cyfr restore ${CYFR_RESTORE_INCOMPLETE}' again." >&2
    exit 78
fi

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
