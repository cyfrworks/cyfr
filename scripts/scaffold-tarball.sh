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
  # Package deployment files for cyfr init: the app, MCP bridge, TLS proxy
  # and optional builder profile. The bridge is built from the sources
  # shipped here; the app and builder images are pulled as published.
  docker-compose.yml Caddyfile .env.example Dockerfile.node apps/mcp-bridge/
  .env.builder.example .env.bridge.example
)
FOUND=()
for item in "${ITEMS[@]}"; do
  [ -e "$item" ] && FOUND+=("$item")
done

if [ ${#FOUND[@]} -eq 0 ]; then
  echo "Error: no scaffold items found" >&2
  exit 1
fi

# The AQUA template ships under its operator-project name `aqua/` (the
# codex scaffold contract) while living at seed/aqua in this repo.
[ -d seed/aqua ] || { echo "Error: seed/aqua missing" >&2; exit 1; }

tar czf "$OUTPUT" "${FOUND[@]}" -C seed aqua
echo "Created $OUTPUT ($(du -h "$OUTPUT" | cut -f1) compressed)"
