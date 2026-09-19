#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
OUTPUT="${1:-cyfr-scaffold.tar.gz}"

ITEMS=(
  component-guide.md tincture-guide.md integration-guide.md
  LICENSE LICENSES/ FAIR_SOURCE.md
  wit/
  # Package deployment files for cyfr init: the app, the execution worker,
  # MCP bridge, TLS proxy and optional builds profile. The bridge and its
  # process helper are built from the sources shipped here; the app, worker
  # and builder images are pulled as published.
  docker-compose.yml Caddyfile .env.example Dockerfile.node apps/mcp-bridge/ apps/spawn/
  # One example per env file docker-compose.yml names beside .env.
  .env.locus.example .env.opus.example .env.bridge.example
)
# Every item is shipped or the script fails: a file renamed or removed
# without this list following must not leave the tarball quietly short.
MISSING=()
for item in "${ITEMS[@]}"; do
  [ -e "$item" ] || MISSING+=("$item")
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: scaffold items missing: ${MISSING[*]}" >&2
  exit 1
fi

# The AQUA template ships under its operator-project name `aqua/` (the
# codex scaffold contract) while living at seed/aqua in this repo.
[ -d seed/aqua ] || { echo "Error: seed/aqua missing" >&2; exit 1; }

tar czf "$OUTPUT" "${ITEMS[@]}" -C seed aqua
echo "Created $OUTPUT ($(du -h "$OUTPUT" | cut -f1) compressed)"
