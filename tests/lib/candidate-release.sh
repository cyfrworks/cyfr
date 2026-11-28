# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# Releases made from a tree as release.yml makes one, left unsigned, for
# the proofs that run `cyfr update` between them: the Compose proof's
# update cases (tests/compose-proof/run.sh) and the update proof
# (tests/update-proof/run.sh). A candidate has no release on GitHub, so its
# images are tagged under the shipped repositories in the local image store
# and its manifest, scaffold and command line read from a folder of the
# run's own (apps/codex/cmd/release_proof.go).
#
# The caller defines `fail` (prints its words and exits non-zero), sets RUN
# (the run's name, which every container name a function here gives Docker
# begins with when PROOF_RUN_PREFIX is set) and an array RELEASE_IMAGES,
# to which every tag or image made here is added for the caller's
# teardown to remove.
#
#   candidate_versions TREE_VERSION NAME
#       Prints the two versions an update moves between, OLD then NEW: the
#       next patch after TREE_VERSION under the pre-release NAME.1 and
#       NAME.2, so no two runs that name themselves apart share a tag.
#   release_name_free REF, release_tag REF SOURCE, release_build REF
#       A tag the run is to make is refused when the store holds it
#       already, since the run takes no name it did not make; SOURCE tagged
#       REF; an image REF built from the Dockerfile on stdin.
#   store_digest REF
#       The digest the containerd image store names REF by, its
#       repository's repository digest.
#   pinned_digest NAME COMPOSE
#       The digest the managed image line of NAME (cyfr, caddy,
#       tailscale/tailscale) pins in COMPOSE.
#   release_schema REF
#       The schema fingerprint the app image REF answers, read as
#       release.yml reads it from the image it publishes.
#   release_manifest FOLDER VERSION CYFR LOCUS CADDY TAILSCALE SCHEMA
#       FOLDER/release.json for VERSION, the images' digests, the scaffold
#       FOLDER/cyfr-scaffold.tar.gz holds and the schema fingerprint.
#   release_cli CODEX VERSION RELEASES OUT
#       The command line of the tree whose apps/codex is CODEX, built with
#       the releaseproof tag at VERSION into OUT, reading its releases from
#       the folder RELEASES alone.

candidate_versions() {
  python3 -I -c '
import re, sys
m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?", sys.argv[1])
assert m, sys.argv[1]
base = "%s.%s.%d-%s" % (m.group(1), m.group(2), int(m.group(3)) + 1, sys.argv[2])
print(base + ".1", base + ".2")' "$1" "$2" || fail "no release version to make candidates from: '$1'"
}

release_name_free() {
  ! docker image inspect "$1" >/dev/null 2>&1 || fail "the image store holds $1 already, which this run did not make"
}

release_tag() {
  release_name_free "$1"
  docker tag "$2" "$1" || fail "docker tag $2 $1 failed"
  RELEASE_IMAGES+=("$1")
}

release_build() {
  local log
  release_name_free "$1"
  log="$(mktemp)"
  if ! docker build --quiet --tag "$1" - >"$log" 2>&1; then
    tail -n 20 "$log" >&2
    rm -f "$log"
    fail "the image $1 did not build"
  fi
  rm -f "$log"
  RELEASE_IMAGES+=("$1")
}

store_digest() {
  local repository="${1%:*}" digest
  digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$1" |
    sed -n "s|^$repository@\(sha256:[0-9a-f]\{64\}\)\$|\1|p" | head -n 1)"
  [ -n "$digest" ] || fail "the image store names $1 by no digest; a candidate release needs the containerd image store (scripts/ci/containerd-image-store.sh --check)"
  printf '%s\n' "$digest"
}

pinned_digest() {
  sed -nE "s|^[[:space:]]*image:[[:space:]]*$1:[^@[:space:]]*@(sha256:[0-9a-f]{64})[[:space:]]*\$|\1|p" "$2" | head -n 1
}

release_schema() {
  local schema
  schema="$(docker run --rm ${PROOF_RUN_PREFIX:+--name "$RUN-schema-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"} \
    -e CYFR_BROWSER=none -e "CYFR_SECRET_KEY_BASE=$(od -An -N48 -tx1 /dev/urandom | tr -d ' \n')" \
    -e "CYFR_LINK_PUBLIC=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')" \
    "$1" bin/cyfr eval 'IO.puts("CYFR_SCHEMA=" <> Arca.SchemaFingerprint.current())' | sed -n 's/^CYFR_SCHEMA=//p')"
  [[ "$schema" =~ ^[0-9a-f]{64}$ ]] || fail "the image $1 answered no schema fingerprint: '$schema'"
  printf '%s\n' "$schema"
}

release_manifest() {
  python3 -I - "$@" <<'PY' || fail "release.json of $2 was not written"
import hashlib, json, os, sys
folder, version, cyfr, locus, caddy, tailscale, schema = sys.argv[1:]
scaffold = hashlib.sha256(open(os.path.join(folder, "cyfr-scaffold.tar.gz"), "rb").read()).hexdigest()
manifest = {"version": version, "images": {"cyfr": cyfr, "cyfr_locus": locus, "caddy": caddy, "tailscale": tailscale},
            "scaffold": "sha256:" + scaffold, "schema_fingerprint": schema}
json.dump(manifest, open(os.path.join(folder, "release.json"), "w"), indent=2)
PY
}

release_cli() {
  (cd "$1" && CGO_ENABLED=0 go build -mod=readonly -tags releaseproof \
    -ldflags "-X github.com/cyfr/codex/internal/version.Version=$2 -X github.com/cyfr/codex/cmd.proofReleases=$3" \
    -o "$4" .) || fail "the command line of release $2 did not build"
}
