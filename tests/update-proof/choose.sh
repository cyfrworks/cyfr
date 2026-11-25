# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# Which release the update proof (tests/update-proof/run.sh) updates from,
# sourced by it and by its test (tests/update-proof/choose-test.sh).
#
#   schema_of REPO COMMIT
#       The schema fingerprint the tree of COMMIT builds: the SHA-256, in
#       lowercase hex, of each apps/arca/priv/repo/migrations/*.exs in
#       name order, its name, a newline and its bytes, as
#       Arca.SchemaFingerprint digests them. A release runs only on a
#       database its own fingerprint built, so two trees share a schema
#       exactly when these are equal.
#   old_side REPO HEAD [TAG...]
#       The old side, given the published releases' tags newest first:
#       the newest of them whose schema is HEAD's (`release TAG`), else
#       the schema's base (`base COMMIT`), the oldest commit of HEAD's
#       first-parent line from which every commit to HEAD has HEAD's
#       schema: an install made on any commit of that line can update to
#       HEAD, and none made before it can. The first line printed is that
#       word and its name, the second the sentence the proof's log opens
#       with, saying which and why. A tag that names no commit here is
#       passed over.
#
# The run passes the 50 newest published releases (`gh release list
# --limit 50`): a release on head's schema older than those fifty is not
# found, and the base is the old side instead.

MIGRATIONS=apps/arca/priv/repo/migrations

schema_of() {
  python3 -I - "$1" "$2" "$MIGRATIONS" <<'PY'
import hashlib, subprocess, sys
repo, commit, folder = sys.argv[1:]
def git(*args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True).stdout
names = sorted(n for n in git("ls-tree", "--name-only", f"{commit}:{folder}").decode().splitlines() if n.endswith(".exs"))
digest = hashlib.sha256()
for name in names:
    digest.update(name.encode() + b"\n" + git("cat-file", "blob", f"{commit}:{folder}/{name}"))
print(digest.hexdigest())
PY
}

old_side() {
  local repo="$1" head="$2" schema tag commit newest="" changed parent base
  shift 2
  schema="$(schema_of "$repo" "$head")" || return 1
  for tag in "$@"; do
    commit="$(git -C "$repo" rev-parse -q --verify "refs/tags/$tag^{commit}")" || continue
    [ -n "$newest" ] || newest="$tag, whose schema is $(schema_of "$repo" "$commit" | cut -c1-12)"
    if [ "$(schema_of "$repo" "$commit")" = "$schema" ]; then
      echo "release $tag"
      echo "the old side is release $tag, the newest published release whose schema is head's (${schema:0:12})"
      return 0
    fi
  done
  base="$(git -C "$repo" rev-list --first-parent --max-parents=0 "$head")"
  while read -r changed; do
    [ -n "$changed" ] || continue
    parent="$(git -C "$repo" rev-parse -q --verify "$changed^1")" || break
    if [ "$(schema_of "$repo" "$parent")" != "$schema" ]; then
      base="$changed"
      break
    fi
  done < <(git -C "$repo" log --first-parent --format=%H "$head" -- "$MIGRATIONS")
  echo "base $base"
  echo "the old side is $(git -C "$repo" rev-parse --short=12 "$base"), the oldest commit of head's first-parent line with head's schema (${schema:0:12}), since no published release shares it (${newest:-no release is published})"
}
