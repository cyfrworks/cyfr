#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The release's written note: the message of the annotated tag TAG beneath
# its subject, which scripts/release.sh writes from its --notes file. It is
# written to OUT, the text GoReleaser publishes as the release's notes in
# place of a list of commits. A tag that is not annotated, whose message
# carries no note, or that does not name COMMIT, the commit the workflow
# run is for, is refused with an ::error:: line and OUT is not written: a
# tag moved after the push that started the run publishes nothing.
#
# The tag is fetched from origin first: a checkout of a tag push may hold it
# as a lightweight tag naming the commit, without its message.
#
# Usage: scripts/ci/release-note.sh TAG COMMIT OUT
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 TAG COMMIT OUT" >&2
  exit 64
fi
tag=$1 commit=$2 out=$3

git fetch --quiet --force --no-tags origin "refs/tags/$tag:refs/tags/$tag"
if [ "$(git rev-parse "refs/tags/$tag^{commit}")" != "$commit" ]; then
  echo "::error::the tag $tag names $(git rev-parse "refs/tags/$tag^{commit}") on origin, not $commit, the commit this run is for; a tag moved after its push publishes nothing"
  exit 1
fi
if [ "$(git cat-file -t "refs/tags/$tag")" != tag ]; then
  echo "::error::the tag $tag is not annotated, so it carries no release note; scripts/release.sh tags with the note its --notes file holds"
  exit 1
fi
note=$(git for-each-ref --format='%(contents:body)' "refs/tags/$tag")
if ! grep -q '[^[:space:]]' <<<"$note"; then
  echo "::error::the tag $tag carries no release note beneath its subject; scripts/release.sh tags with the note its --notes file holds"
  exit 1
fi
printf '%s\n' "$note" >"$out"
echo "The tag $tag carries its release note ($(wc -l <"$out") lines)."
