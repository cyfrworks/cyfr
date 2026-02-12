#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
PUSH="${2:-}"

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version> [--push]"
  echo "Example: $0 0.9.0 --push"
  exit 1
fi

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Error: '$VERSION' is not valid semver (expected: MAJOR.MINOR.PATCH)"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: working tree is dirty. Commit or stash changes first."
  exit 1
fi

echo "Bumping version to $VERSION..."

# Update root mix.exs
sed -i '' -E "s/version: \"[0-9]+\.[0-9]+\.[0-9]+\"/version: \"$VERSION\"/" mix.exs

# Update all app mix.exs files
for app in apps/*/mix.exs; do
  sed -i '' -E "s/version: \"[0-9]+\.[0-9]+\.[0-9]+\"/version: \"$VERSION\"/" "$app"
done

echo "Updated mix.exs files:"
grep -rn 'version:' mix.exs apps/*/mix.exs | grep "$VERSION"

git add mix.exs apps/*/mix.exs
git commit -m "v$VERSION"
git tag -a "v$VERSION" -m "Release v$VERSION"

echo ""
echo "Done! Version v$VERSION committed and tagged."

if [ "$PUSH" = "--push" ]; then
  echo "Pushing to origin..."
  git push -u origin main && git push origin "v$VERSION"
  echo "Pushed!"
else
  echo ""
  echo "To publish:"
  echo "  git push origin main && git push origin v$VERSION"
fi
