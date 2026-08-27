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

# Shipped seed versions are immutable: the overlay serves unmaterialized
# units straight from seed/, so changed bytes under a version directory an
# earlier release shipped silently repatch every athanor. New bytes mean a
# NEW version directory. Retiring a WHOLE version directory is allowed.
# This mirrors the CI seed-guards job, which only sees pull requests.
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$LAST_TAG" ]; then
  SEED_BAD="$(git diff --name-only --diff-filter=M "$LAST_TAG"..HEAD -- 'seed/components/' || true)"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    vdir="$(printf '%s\n' "$f" | cut -d/ -f1-6)"
    if [ -d "$vdir" ]; then SEED_BAD="$SEED_BAD"$'\n'"$f"; fi
  done <<< "$(git diff --name-only --diff-filter=DR "$LAST_TAG"..HEAD -- 'seed/components/' || true)"
  SEED_BAD="$(printf '%s\n' "$SEED_BAD" | sed '/^$/d')"
  if [ -n "$SEED_BAD" ]; then
    echo "Error: files changed inside seed/components version directories shipped by $LAST_TAG:"
    echo "$SEED_BAD"
    echo "Ship a new version directory instead."
    exit 1
  fi
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

# A release tag must never point at a red commit: run the full suite and
# credo before touching versions. Skip with --skip-tests only when the same
# tree already passed locally moments ago.
if [ "${SKIP_TESTS:-}" != "1" ]; then
  echo "Running full test suite (set SKIP_TESTS=1 to skip)..."
  mix test
  mix credo --only=warning
  echo "Suite green."
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
