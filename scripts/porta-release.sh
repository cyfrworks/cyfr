#!/usr/bin/env bash
set -euo pipefail

VERSION=""
PUSH=""
COMMIT_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH="--push"; shift ;;
    --message) COMMIT_MSG="$2"; shift 2 ;;
    -*) echo "Unknown flag: $1"; exit 1 ;;
    *) VERSION="$1"; shift ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version> [--push] [--message <msg>]"
  echo "Example: $0 0.1.0 --push"
  exit 1
fi

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Error: '$VERSION' is not valid semver (expected: MAJOR.MINOR.PATCH)"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
TAG="porta-v$VERSION"

# Pre-flight checks
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: tag $TAG already exists"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Warning: working tree has uncommitted changes:"
  git status --short
  echo ""
  printf "Continue anyway? [y/N] "
  if [ -t 0 ]; then
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 1
    fi
  else
    echo "Non-interactive mode — aborting. Commit or stash changes first."
    exit 1
  fi
fi

# Portable in-place sed (macOS requires -i '', Linux requires -i)
sedi() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

echo "Bumping CYFR Porta version to $VERSION..."

# Update Cargo.toml
sedi -E "s/^version = \"[0-9]+\.[0-9]+\.[0-9]+\"/version = \"$VERSION\"/" apps/porta/Cargo.toml

# Update tauri.conf.json
sedi -E "s/\"version\": \"[0-9]+\.[0-9]+\.[0-9]+\"/\"version\": \"$VERSION\"/" apps/porta/tauri.conf.json

# Update Cargo.lock
echo "Updating Cargo.lock..."
(cd apps/porta && cargo check --quiet 2>/dev/null || true)

# Verify
echo "Updated files:"
grep -n 'version' apps/porta/Cargo.toml | head -1
grep -n 'version' apps/porta/tauri.conf.json | head -1

git add apps/porta/Cargo.toml apps/porta/tauri.conf.json apps/porta/Cargo.lock

if git diff --cached --quiet; then
  echo "Version already at $VERSION — skipping commit."
else
  # Get commit message
  if [ -z "$COMMIT_MSG" ]; then
    if [ -t 0 ]; then
      echo ""
      printf "Commit message: "
      read -r COMMIT_MSG
    fi
    if [ -z "$COMMIT_MSG" ]; then
      COMMIT_MSG="CYFR Porta $TAG"
    fi
  fi
  git commit -m "$COMMIT_MSG"
fi

git tag -a "$TAG" -m "CYFR Porta v$VERSION"

echo ""
echo "Done! CYFR Porta v$VERSION committed and tagged."

if [ "$PUSH" = "--push" ]; then
  echo "Pushing to origin..."
  git push -u origin "$BRANCH" && git push origin "$TAG"
  echo "Pushed!"
else
  echo ""
  echo "To publish:"
  echo "  git push origin $BRANCH && git push origin $TAG"
fi
