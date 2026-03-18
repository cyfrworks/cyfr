#!/bin/sh
set -e

# Fix ownership of bind-mounted data directories.
# No-op when using Docker named volumes; needed for host bind mounts on Linux.
chown -R app:app /app/data /app/components 2>/dev/null || true

# Drop to non-root user and exec the release command
exec gosu app "$@"
