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
#
# Every query runs with --no-renames. Rename detection reports a rename under
# its DESTINATION path, so shipping a new version by copying the last one read
# as "files removed from the version that still ships" and refused the release
# this guard exists to allow. It also hid an in-place edit whenever git paired
# the file with a deletion elsewhere: that pair is R, which the modified-file
# query does not select.
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$LAST_TAG" ]; then
  SEED_BAD="$(git diff --no-renames --name-only --diff-filter=M "$LAST_TAG"..HEAD -- 'seed/components/' || true)"
  # A deletion inside a version directory that still ships is a mutation too;
  # retiring the WHOLE directory is a release decision and passes.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    vdir="$(printf '%s\n' "$f" | cut -d/ -f1-6)"
    if [ -d "$vdir" ]; then SEED_BAD="$SEED_BAD"$'\n'"$f"; fi
  done <<< "$(git diff --no-renames --name-only --diff-filter=D "$LAST_TAG"..HEAD -- 'seed/components/' || true)"
  # Adding a file to a version directory that already shipped mutates it.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    vdir="$(printf '%s\n' "$f" | cut -d/ -f1-6)"
    if git rev-parse --verify --quiet "$LAST_TAG:$vdir" >/dev/null 2>&1; then
      SEED_BAD="$SEED_BAD"$'\n'"$f"
    fi
  done <<< "$(git diff --no-renames --name-only --diff-filter=A "$LAST_TAG"..HEAD -- 'seed/components/' || true)"
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

# A release tag must never point at a red commit: run the full suite on BOTH
# database adapters and credo before touching versions. The adapter is chosen
# at compile time, so Postgres is a build of its own (MIX_BUILD_PATH) against
# its own database: a tag that ran SQLite alone said nothing about the half of
# the shipped product that runs on Postgres. Point CYFR_POSTGRES_TEST_URL at a
# database this may create, migrate and write to; without one the Postgres leg
# is refused, not skipped. Skip both with SKIP_TESTS=1 only when the same tree
# already passed locally moments ago.
if [ "${SKIP_TESTS:-}" != "1" ]; then
  echo "Running the full test suite on SQLite (set SKIP_TESTS=1 to skip)..."
  CYFR_DATABASE=sqlite mix test

  if [ -z "${CYFR_POSTGRES_TEST_URL:-}" ]; then
    echo "Error: CYFR_POSTGRES_TEST_URL is not set, so the Postgres suite cannot run."
    echo "Set it to a disposable Postgres database (e.g."
    echo "  postgres://cyfr:cyfr@localhost:5432/cyfr_test)"
    echo "or set SKIP_TESTS=1 if this tree just passed on both adapters."
    exit 1
  fi

  echo "Running the full test suite on Postgres..."
  CYFR_DATABASE=postgres \
    MIX_BUILD_PATH="$REPO_ROOT/_build/test_pg" \
    CYFR_DATABASE_URL="$CYFR_POSTGRES_TEST_URL" \
    mix test

  mix credo --only=warning
  echo "Suite green on both adapters."
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

# The bridge stamps its package.json version on every MCP response, so it
# releases in lockstep with the tree — it sat at 1.0.0 while the stack
# moved to 0.5.x. The lockfile's two root version fields live in its first
# lines; the line range keeps the sed away from any dependency that
# happens to share the version string.
sedi -E "s/\"version\": \"[0-9]+\.[0-9]+\.[0-9]+\"/\"version\": \"$VERSION\"/" apps/mcp-bridge/package.json
sedi -E "1,12s/\"version\": \"[0-9]+\.[0-9]+\.[0-9]+\"/\"version\": \"$VERSION\"/" apps/mcp-bridge/package-lock.json

for f in apps/mcp-bridge/package.json apps/mcp-bridge/package-lock.json; do
  if ! grep -q "\"version\": \"$VERSION\"" "$f"; then
    echo "Error: $f was not updated to $VERSION."
    exit 1
  fi
done

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
