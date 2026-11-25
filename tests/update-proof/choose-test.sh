#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The update proof's choice of the release it updates from
# (tests/update-proof/choose.sh), on a scratch repository: both of its
# answers, a published release that shares head's schema and the schema's
# base when none does, so the branch the nightly takes on few nights is
# held every time this runs.
#
# Usage: bash tests/update-proof/choose-test.sh
# Exits 0 when every check passed, 1 otherwise.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/update-proof/choose.sh
. "$HERE/choose.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
failures=0
check() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: '$2', not '$3'"
    failures=$((failures + 1))
  fi
}

repo=$scratch/repo
git init -q -b main "$repo"
g() { git -C "$repo" -c user.name=proof -c user.email=proof@example.invalid "$@"; }
# commit MESSAGE [FILE CONTENT]: a commit on the checked-out branch,
# writing FILE under the migrations folder first when given.
commit() {
  if [ $# -ge 3 ]; then
    mkdir -p "$repo/$MIGRATIONS"
    printf '%s\n' "$3" >"$repo/$MIGRATIONS/$2"
    g add -A
  fi
  g commit -q --allow-empty -m "$1"
  g rev-parse HEAD
}

# The fingerprint is Arca.SchemaFingerprint's: each .exs file's name, a
# newline and its bytes, in name order; other files are not read.
c_root=$(commit root 0001_baseline.exs 'schema A')
want=$(printf '0001_baseline.exs\nschema A\n' | sha256sum | cut -c1-64)
check "the fingerprint digests each .exs file's name and bytes" "$(schema_of "$repo" "$c_root")" "$want"
c_readme=$(commit readme README.md 'not a migration')
check "a file that is not a .exs file leaves the fingerprint" "$(schema_of "$repo" "$c_readme")" "$want"

g tag v1 "$c_readme"
c_feature=$(commit feature)
# A side branch changes the schema; its merge is the first commit of
# main's first-parent line with the new schema.
g checkout -q -b side
commit 'schema B on a side branch' 0001_baseline.exs 'schema B' >/dev/null
commit 'more on the side branch' >/dev/null
g checkout -q main
commit 'main moves on' >/dev/null
g merge -q --no-ff -m 'merge side' side
c_merge=$(g rev-parse HEAD)
c_after=$(commit 'after the merge')
g tag v2 "$c_after"
c_head=$(commit 'head')

out=$(old_side "$repo" "$c_head" v2 v1)
check "a published release that shares head's schema is the old side" "$(head -n 1 <<<"$out")" "release v2"
check "the log's first line names it and why" "$(sed -n 2p <<<"$out")" \
  "the old side is release v2, the newest published release whose schema is head's ($(schema_of "$repo" "$c_head" | cut -c1-12))"

out=$(old_side "$repo" "$c_head" v1)
check "with no published release on head's schema, the old side is the merge that brought it to the first-parent line" \
  "$(head -n 1 <<<"$out")" "base $c_merge"
check "the log's first line names the base, head's schema and the newest release's" "$(sed -n 2p <<<"$out")" \
  "the old side is ${c_merge:0:12}, the oldest commit of head's first-parent line with head's schema ($(schema_of "$repo" "$c_head" | cut -c1-12)), since no published release shares it (v1, whose schema is ${want:0:12})"

out=$(old_side "$repo" "$c_head" gone v1)
check "a tag that names no commit here is passed over" "$(head -n 1 <<<"$out")" "base $c_merge"

out=$(old_side "$repo" "$c_head")
check "with no release published, the log says so" "$(sed -n 2p <<<"$out" | sed 's/.*(\(no release is published\))$/\1/')" "no release is published"

# The schema goes back to what an earlier commit had: the base is the
# commit that went back, never one before the change between.
commit 'schema A again' 0001_baseline.exs 'schema A' >/dev/null
c_back=$(g rev-parse HEAD)
c_head2=$(commit 'head again')
out=$(old_side "$repo" "$c_head2" v1)
check "a release on head's schema that an older change made is the old side" "$(head -n 1 <<<"$out")" "release v1"
out=$(old_side "$repo" "$c_head2")
check "the base is the commit the schema went back at, not one before the change between" "$(head -n 1 <<<"$out")" "base $c_back"
out=$(old_side "$repo" "$c_head2" v2 v1)
check "a newest release on another schema is passed over for an older one on head's" "$(head -n 1 <<<"$out")" "release v1"

out=$(old_side "$repo" "$c_feature")
check "a schema no commit of the line changed has the line's root as its base" "$(head -n 1 <<<"$out")" "base $c_root"

[ "$failures" = 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "every check passed"
