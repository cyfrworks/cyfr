#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Decide whether this run's world checks are informational: scripts/ci/world-checks.sh
#
# The dependency audit and the image scans compare the tree with advisory
# feeds that change on their own, so they can fail a pull request for
# nothing it did. On a pull request that changes no dependency file this
# writes informational=true to GITHUB_OUTPUT, which those steps feed to
# continue-on-error. Everywhere else it writes nothing and they block: a
# push to main, a release (test.yml and security.yml called from
# release.yml carry the tag push's event), the commit gate, and a diff that
# cannot be read.
#
# It compares the merge commit a pull request's run checks out with that
# commit's first parent, the base, so the job's checkout takes
# fetch-depth: 2.
#
# Exit 0 with or without the output, 64 when given any argument.
set -euo pipefail

[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 64; }

[ "${GITHUB_EVENT_NAME:-}" = pull_request ] || exit 0

if git diff --quiet HEAD^1 HEAD -- mix.lock ':(glob)**/package-lock.json' \
  ':(glob)**/Dockerfile*' ':(glob)**/docker-compose*'; then
  echo informational=true >>"$GITHUB_OUTPUT"
fi
