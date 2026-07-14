#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
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
  echo "Example: $0 0.9.0 --push"
  exit 1
fi

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Error: '$VERSION' is not valid semver (expected: MAJOR.MINOR.PATCH)"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# Pre-flight checks
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "Error: tag $VERSION already exists"
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

echo "Bumping version to $VERSION..."

MIXFILES=(mix.exs apps/*/mix.exs)

# Update all mix.exs files
for f in "${MIXFILES[@]}"; do
  sedi -E "s/version: \"[0-9]+\.[0-9]+\.[0-9]+\"/version: \"$VERSION\"/" "$f"
done

# Verify all files were updated
echo "Updated mix.exs files:"
UPDATED=$(grep -n 'version:' "${MIXFILES[@]}" | grep "$VERSION" || true)
echo "$UPDATED"

EXPECTED=${#MIXFILES[@]}
ACTUAL=$(echo "$UPDATED" | grep -c "$VERSION" || true)
if [ "$ACTUAL" -ne "$EXPECTED" ]; then
  echo "Error: expected $EXPECTED files updated, but only $ACTUAL matched. Check mix.exs files."
  exit 1
fi

# Get commit message
if [ -z "$COMMIT_MSG" ]; then
  if [ -t 0 ]; then
    echo ""
    printf "Commit message: "
    read -r COMMIT_MSG
  fi
  if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="$VERSION"
  fi
fi

git add -A
git commit -m "$COMMIT_MSG"
git tag -a "$VERSION" -m "Release $VERSION"

echo ""
echo "Done! Version $VERSION committed and tagged."

if [ "$PUSH" = "--push" ]; then
  echo "Pushing to origin..."
  git push -u origin "$BRANCH" && git push origin "$VERSION"
  echo "Pushed!"
else
  echo ""
  echo "To publish:"
  echo "  git push origin $BRANCH && git push origin $VERSION"
fi
