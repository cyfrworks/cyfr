#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -euo pipefail

VERSION=""
PUSH=""
COMMIT_MSG=""
GATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH="--push"; shift ;;
    --message) COMMIT_MSG="$2"; shift 2 ;;
    --gate) GATE="--gate"; shift ;;
    -*) echo "Unknown flag: $1"; exit 1 ;;
    *) VERSION="$1"; shift ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version> [--push] [--message <msg>] [--gate]"
  echo "Example: $0 0.9.0 --push"
  echo "         $0 0.9.0-rc.1 --push"
  echo "         $0 0.9.0 --push --gate   # proves HEAD green here, offline, instead of by its run on GitHub"
  exit 1
fi

# The one rule for a release version, which the release workflow's version
# job holds the tag to (tests/fixtures/release_manifest.json's versions),
# matched byte by byte in a subshell of its own: under another locale
# [A-Za-z] can admit letters outside ASCII, and the release stage below runs
# under the caller's locale.
RELEASE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$'
if ! (LC_ALL=C; [[ "$VERSION" =~ $RELEASE ]]); then
  echo "Error: '$VERSION' is not a release version (MAJOR.MINOR.PATCH, or with a pre-release such as 0.9.0-rc.1)"
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
# scripts/ci/seed-guard.sh is the one check, run here against the last tag
# as the CI seed-guards job runs it against each change's base; it names
# every offending path on stderr.
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$LAST_TAG" ] && ! scripts/ci/seed-guard.sh "$LAST_TAG"; then
  echo "Error: files changed inside seed/components version directories shipped by $LAST_TAG (named above)."
  echo "Ship a new version directory instead."
  exit 1
fi

# Under --gate the proof is of the working tree's bytes, which the tag
# would not carry, so a tree with changes is refused there.
if [ -n "$GATE" ] && [ -n "$(git status --porcelain)" ]; then
  echo "Error: --gate proves the working tree, and it has uncommitted changes the tag would not carry:"
  git status --short
  echo "Commit or stash them first."
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

MIXFILES=(mix.exs apps/*/mix.exs)

# The version files are HEAD's: the tag names a commit, so a version edited
# and not committed, which the prompt above lets through, would be tagged
# on a commit that declares another. A bump starts from HEAD's versions
# too.
if [ -n "$(git status --porcelain -- "${MIXFILES[@]}")" ]; then
  echo "Error: the mix.exs files differ from HEAD:"
  git status --short -- "${MIXFILES[@]}"
  echo "Commit or undo those changes first, so the tag names a commit that declares the version it names."
  exit 1
fi

# A release tag never points at a tree that is not proved green. The tag
# names HEAD, or HEAD plus the bump below, whose only change is the
# version line of each mix.exs; the proof is of HEAD's tree, and the tag's
# own workflow runs every gating workflow on the tagged commit before it
# publishes anything (release.yml), so a bump that broke a check would
# publish nothing. The proof is HEAD's run on GitHub, as every change's
# check is its pull request's run there (CONTRIBUTING.md): the latest run
# of every check GitHub ran for HEAD has completed and none failed, and
# among them the Test workflow's latest run on HEAD completed green, read
# through `gh`, which refuses a HEAD that is not pushed, still running or
# unchecked. Another workflow whose path filter kept it from running for
# HEAD is not among them, and runs at the tag; a HEAD the Test workflow's
# path filter skipped has no proof there. --gate proves HEAD here instead,
# for a release cut offline or a HEAD GitHub has not run: the release
# stage (scripts/stage.sh release, the gate's close as scripts/stages.tsv
# holds it), CI's checks and the full suite on both database adapters, the
# cluster suite and every island, queued on the verification host as any
# exclusive check is and holding the host for over an hour. Its
# PostgreSQL legs use the database config/test.exs names for each
# partition on the host's fixture server, localhost:5432, so the release
# names none, and its logs stay in a fresh directory named before it
# starts and again when it ends, /tmp/cyfr-stage.release.*, the stage's
# own log name (scripts/stage.sh), which the janitor keeps seven days. RELEASE_UNPROVEN=1 skips the proof, for a
# disposable repository that has no run on GitHub
# (tests/ci-release-graph.py); no release is cut under it.
HEAD_SHA="$(git rev-parse HEAD)"
if [ "${RELEASE_UNPROVEN:-}" = "1" ]; then
  echo "Warning: RELEASE_UNPROVEN=1: HEAD $HEAD_SHA is tagged without a proof that it is green."
elif [ -n "$GATE" ]; then
  GATE_LOGS="$(mktemp -d /tmp/cyfr-stage.release.XXXXXX)"
  echo "Running the release stage on HEAD $HEAD_SHA; its logs go to $GATE_LOGS"
  if ! scripts/stage.sh -l "$GATE_LOGS" release; then
    echo "Error: the release stage failed; its logs are in $GATE_LOGS"
    exit 1
  fi
  echo "The release stage passed; its logs are in $GATE_LOGS"
else
  echo "Reading HEAD's check runs on GitHub ($HEAD_SHA)..."
  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh is not installed, and the proof that HEAD is green is its run on GitHub, read through gh."
    echo "Install gh and sign in, or prove HEAD here with --gate."
    exit 1
  fi
  if ! RUNS="$(gh api "repos/{owner}/{repo}/commits/$HEAD_SHA/check-runs?per_page=100" --paginate \
      -q '.check_runs[] | "\(.status) \(.conclusion // "-") \(.name)"' 2>&1)"; then
    echo "Error: HEAD's check runs could not be read: $RUNS"
    echo "Push HEAD and let its run finish, sign gh in, or prove HEAD here with --gate."
    exit 1
  fi
  if [ -z "$RUNS" ]; then
    echo "Error: GitHub holds no check run for HEAD $HEAD_SHA: it is unchecked."
    echo "Push HEAD and let its run finish, or prove HEAD here with --gate."
    exit 1
  fi
  NOT_GREEN="$(grep -v -E '^completed (success|skipped|neutral) ' <<< "$RUNS" || true)"
  if [ -n "$NOT_GREEN" ]; then
    echo "Error: HEAD $HEAD_SHA is not proved green on GitHub; a release tag never points at a red, running or unchecked commit:"
    sed 's/^/  /' <<< "$NOT_GREEN"
    echo "Wait for green, fix what is red, or prove HEAD here with --gate."
    exit 1
  fi
  # The suites are the Test workflow's: its latest run on HEAD, of any
  # event, is the one that must be green.
  if ! TEST_RUN="$(gh api "repos/{owner}/{repo}/actions/runs?head_sha=$HEAD_SHA&per_page=100" \
      -q '[.workflow_runs[] | select(.path == ".github/workflows/test.yml")] | sort_by(.created_at) | last
          | if . == null then "none" else "\(.status) \(.conclusion // "-")" end' 2>&1)"; then
    echo "Error: HEAD's workflow runs could not be read: $TEST_RUN"
    echo "Sign gh in, or prove HEAD here with --gate."
    exit 1
  fi
  if [ "$TEST_RUN" != "completed success" ]; then
    if [ "$TEST_RUN" = none ]; then
      echo "Error: the Test workflow has no run on HEAD $HEAD_SHA (its path filter skipped it): HEAD's suites are unproved."
    else
      echo "Error: the Test workflow's latest run on HEAD $HEAD_SHA is $TEST_RUN, not completed success."
    fi
    echo "Wait for green, fix what is red, or prove HEAD here with --gate."
    exit 1
  fi
  echo "HEAD's tree is proved green on GitHub: $(wc -l <<< "$RUNS") check runs completed, none failed, the Test workflow's among them."
fi

# The dependency audits compare mix.lock with advisory feeds that change
# independently of the tree, so the proof's audit, run when HEAD's run
# began, can be stale by the time the tag is cut: an advisory published in
# between fails the tag's own run, which then publishes nothing, and the
# tag names a version that never shipped. The audits run here again, the
# same ones security.yml's elixir-audit job runs
# (scripts/dependency-audit.sh), right before the tag. RELEASE_UNPROVEN=1
# skips them with the proof.
if [ "${RELEASE_UNPROVEN:-}" != "1" ]; then
  echo "Running the dependency audits against the advisories published since HEAD's run..."
  # The locked dependencies first, as security.yml's job fetches them before
  # it audits: `mix deps.audit` loads the project, which refuses a deps/ that
  # lags mix.lock, and this checkout may not have fetched since the lock
  # changed. Fetching changes nothing in the tree; the lock is HEAD's.
  if ! mix deps.get; then
    echo "Error: the locked dependencies could not be fetched (above), so the audits cannot run."
    exit 1
  fi
  if ! scripts/dependency-audit.sh; then
    echo "Error: the dependency audits failed (above); the tag's own run would fail the same way and publish nothing."
    echo "Update the dependency, prove the change by its pull request, and cut the release from that."
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

# Whether commit $2 is commit $1 with nothing changed but version lines
# of the mix.exs files: every file it changes is one of them, modified in
# place with its mode kept, and every line it removes or adds is a
# `version: "..."` line.
version_only() {
  local raw names lines
  raw=$(git diff-tree -r --no-renames "$1" "$2") || return 1
  [ -z "$(awk '!(substr($1, 2) == $2 && $5 == "M")' <<< "$raw")" ] || return 1
  names=$(git diff --no-ext-diff --name-only "$1" "$2") || return 1
  [ -n "$names" ] || return 1
  [ -z "$(grep -vxF -f <(printf '%s\n' "${MIXFILES[@]}") <<< "$names")" ] || return 1
  lines=$(git diff --no-ext-diff --no-color -U0 "$1" "$2" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ') || return 1
  ! grep -qvE '^[+-][[:space:]]*version: "[^"]*",?[[:space:]]*$' <<< "$lines"
}

# Whether every mix.exs declares VERSION and no other version, in commit
# $1 when one is given, else in the working tree. The comparison is of
# whole strings, so VERSION's dots are no wildcards and 0.9.0 is not
# 0.9.0-rc.1.
all_declare() {
  local f found
  for f in "${MIXFILES[@]}"; do
    if [ "$#" -gt 0 ]; then
      found=$(git show "$1:$f" | grep -oE 'version: "[^"]*"' || true)
    else
      found=$(grep -oE 'version: "[^"]*"' "$f" || true)
    fi
    [ -n "$found" ] || return 1
    [ -z "$(grep -vxF "version: \"$VERSION\"" <<< "$found")" ] || return 1
  done
}

# The tag and the bump go on the proved commit alone: a HEAD that another
# agent sharing this checkout moved during the proof is refused before
# anything is made, whatever the move changed.
if [ "$(git rev-parse HEAD)" != "$HEAD_SHA" ]; then
  echo "Error: HEAD moved from the proved $HEAD_SHA to $(git rev-parse HEAD) during the proof; nothing was committed or tagged."
  exit 1
fi

if all_declare "$HEAD_SHA"; then
  # The proved commit already bumped every mix.exs: the tag names it and
  # no commit is made.
  echo "Every mix.exs declares $VERSION already:"
  grep -nF "version: \"$VERSION\"" "${MIXFILES[@]}"
  git tag -a "$VERSION" "$HEAD_SHA" -m "Release $VERSION"
  echo ""
  echo "Done! Version $VERSION tagged at $(git rev-parse --short "$HEAD_SHA")."
else
  echo "Bumping version to $VERSION..."

  # Every declared version, a pre-release's included, becomes VERSION.
  for f in "${MIXFILES[@]}"; do
    sedi -E "s/version: \"[^\"]*\"/version: \"$VERSION\"/" "$f"
  done

  # Verify all files were updated
  echo "Updated mix.exs files:"
  grep -nF "version: \"$VERSION\"" "${MIXFILES[@]}" || true
  if ! all_declare; then
    echo "Error: not every one of the ${#MIXFILES[@]} mix.exs files declares $VERSION alone. Check mix.exs files."
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

  # The bump commit holds the version lines and nothing else, so the
  # tagged tree is the proved one plus them: the commit takes the mix.exs
  # files from the working tree and disregards whatever else is staged
  # (`git commit --only -- <paths>`), where `git add -A` or a plain
  # `git commit` would have swept other changes, unstaged or staged, into
  # the release. The commit is then held, before the tag, to the proved
  # commit as its parent, to version lines of those files alone (a file
  # already at VERSION is not among them) and to every one declaring
  # VERSION as committed, so a hook cannot change what is tagged; the tag
  # names it.
  git commit --only -m "$COMMIT_MSG" -- "${MIXFILES[@]}"
  BUMP="$(git rev-parse HEAD)"
  if [ "$(git rev-parse "$BUMP^")" != "$HEAD_SHA" ] || ! version_only "$HEAD_SHA" "$BUMP" || ! all_declare "$BUMP"; then
    echo "Error: the bump commit $BUMP is not the proved $HEAD_SHA plus version lines of the mix.exs files declaring $VERSION:"
    git diff --no-ext-diff --stat "$HEAD_SHA" "$BUMP" | sed 's/^/  /'
    if [ "$(git rev-parse "$BUMP^")" = "$HEAD_SHA" ]; then
      git reset --soft HEAD~1
      echo "The commit was undone, its changes left staged; nothing was tagged."
    else
      echo "The commit was left as it is; nothing was tagged."
    fi
    exit 1
  fi
  git tag -a "$VERSION" "$BUMP" -m "Release $VERSION"

  echo ""
  echo "Done! Version $VERSION committed and tagged at $(git rev-parse --short "$BUMP"): the proved tree $(git rev-parse --short "$HEAD_SHA") plus the version lines; the tag's workflow checks it again before it publishes."
fi

if [ "$PUSH" = "--push" ]; then
  echo "Pushing to origin..."
  if ! git push -u origin "$BRANCH"; then
    echo "Error: the push of $BRANCH failed (above); the tag $VERSION was not pushed."
    exit 1
  fi
  if ! git push origin "$VERSION"; then
    echo "Error: $BRANCH was pushed and the push of the tag $VERSION failed (above); push it with: git push origin $VERSION"
    exit 1
  fi
  echo "Pushed!"
else
  echo ""
  echo "To publish:"
  echo "  git push origin $BRANCH && git push origin $VERSION"
fi
