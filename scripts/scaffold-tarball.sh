#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
OUTPUT="${1:-cyfr-scaffold.tar.gz}"

ITEMS=(component-guide.md tincture-guide.md integration-guide.md wit/ components/ aqua/)
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
