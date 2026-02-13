#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
OUTPUT="${1:-cyfr-scaffold.tar.gz}"
tar czf "$OUTPUT" \
  --exclude='*/target/*' \
  --exclude='*/target' \
  component-guide.md \
  integration-guide.md \
  wit/ \
  components/
echo "Created $OUTPUT ($(du -h "$OUTPUT" | cut -f1) compressed)"
