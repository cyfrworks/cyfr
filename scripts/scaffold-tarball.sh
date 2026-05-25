#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
OUTPUT="${1:-cyfr-scaffold.tar.gz}"

ITEMS=(
  component-guide.md tincture-guide.md integration-guide.md
  LICENSE LICENSES/ FAIR_SOURCE.md
  wit/ components/ aqua/
  # Deploy files: `cyfr init` lays these down so `cyfr up` brings up the full
  # self-hosted stack (cyfr + porta + mcp-bridge, plus caddy in TLS mode).
  # They are the single source of truth — the codex binary no longer embeds
  # its own copies. Dockerfile.node builds the porta and mcp-bridge images;
  # apps/mcp-bridge/ is the Node source for the bridge.
  docker-compose.yml Caddyfile .env.example Dockerfile.node apps/mcp-bridge/
)
FOUND=()
for item in "${ITEMS[@]}"; do
  [ -e "$item" ] && FOUND+=("$item")
done

if [ ${#FOUND[@]} -eq 0 ]; then
  echo "Error: no scaffold items found" >&2
  exit 1
fi

tar czf "$OUTPUT" \
  --exclude='*/target/*' \
  --exclude='*/target' \
  "${FOUND[@]}"
echo "Created $OUTPUT ($(du -h "$OUTPUT" | cut -f1) compressed)"
