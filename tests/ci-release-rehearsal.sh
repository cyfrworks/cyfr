#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# GoReleaser's release, run on .goreleaser.yml as the tag's run runs it
# and publishing nothing: a snapshot at a version of its own, with
# stand-ins for the five installers in RELEASE_PACKAGES_DIR, for the
# scaffold and for the signed manifest, and no signature made. Each check
# prints one PASS or FAIL line, and one FAIL fails the run:
#
#   summed   checksums.txt names exactly the CLI's five archives (none for
#            an Intel Mac), the scaffold and the five installers, each by
#            its file's digest
#   missing  with one installer missing, GoReleaser fails naming it, and
#            writes no checksums.txt: the release stops before any upload
#   nocask   GoReleaser writes no Homebrew cask (the release workflow
#            writes it from the DMG, scripts/ci/homebrew-cask.sh)
#
# The attachments are the same globs as the checksums, which
# tests/ci-release-graph.py holds; GoReleaser reads them only when it
# publishes. Needs goreleaser (the version release.yml pins) and go on
# PATH. It writes apps/codex/cyfr-scaffold.tar.gz and apps/codex/dist,
# which git ignores, and removes them.
#
# Usage: bash tests/ci-release-rehearsal.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CODEX=$ROOT/apps/codex
command -v goreleaser >/dev/null || { echo "rehearsal: goreleaser is not on PATH" >&2; exit 69; }
[ ! -e "$CODEX/cyfr-scaffold.tar.gz" ] && [ ! -e "$CODEX/dist" ] || {
  echo "rehearsal: refused: apps/codex already holds cyfr-scaffold.tar.gz or dist" >&2; exit 64; }
RUN=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cyfr-release-rehearsal.XXXXXX") || exit 1
trap 'rm -rf "$RUN" "$CODEX/cyfr-scaffold.tar.gz" "$CODEX/dist"' EXIT
VERSION=0.0.0-rehearsal
failed=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; failed=1; }

# The release's own configuration at a fixed snapshot version.
cp "$CODEX/.goreleaser.yml" "$RUN/goreleaser.yml"
printf '\nsnapshot:\n  version_template: "%s"\n' "$VERSION" >> "$RUN/goreleaser.yml"
mkdir -p "$RUN/packages" "$RUN/manifest"
installers=()
# Linux's and Windows' for amd64 and arm64, the Mac's for Apple silicon
# alone.
for target in linux:deb:amd64 linux:deb:arm64 darwin:dmg:arm64 windows:msi:amd64 windows:msi:arm64; do
  IFS=: read -r os kind arch <<< "$target"
  name="cyfr-desktop_${VERSION}_${os}_${arch}.${kind}"
  printf 'the %s stand-in\n' "$name" > "$RUN/packages/$name"
  installers+=("$name")
done
printf 'the scaffold stand-in\n' > "$CODEX/cyfr-scaffold.tar.gz"
printf '{}\n' > "$RUN/manifest/release.json"
printf '{}\n' > "$RUN/manifest/release.json.sigstore.json"

release() {
  (cd "$CODEX" && RELEASE_PACKAGES_DIR="$1" RELEASE_MANIFEST_DIR="$RUN/manifest" GITHUB_TOKEN=unused \
    goreleaser release --config "$RUN/goreleaser.yml" --snapshot --clean --skip=sign 2>&1)
}

if ! out=$(release "$RUN/packages"); then
  fail "summed: GoReleaser failed: ${out: -2000}"
else
  want=$( {
    for arch in amd64 arm64; do echo "cyfr_${VERSION}_linux_${arch}.tar.gz"; done
    echo "cyfr_${VERSION}_darwin_arm64.tar.gz"
    for arch in amd64 arm64; do echo "cyfr_${VERSION}_windows_${arch}.zip"; done
    echo cyfr-scaffold.tar.gz
    printf '%s\n' "${installers[@]}"
  } | sort)
  got=$(awk '{print $2}' "$CODEX/dist/checksums.txt" | sort)
  if [ "$got" != "$want" ]; then
    fail "summed: checksums.txt names [$(echo $got)], not [$(echo $want)]"
  else
    wrong=""
    for name in "${installers[@]}"; do
      sum=$(sha256sum "$RUN/packages/$name" | cut -d' ' -f1)
      grep -qx "$sum  $name" "$CODEX/dist/checksums.txt" || wrong="$wrong $name"
    done
    if [ -n "$wrong" ]; then fail "summed: checksums.txt's digests are not the files' for:$wrong"
    else pass "summed: checksums.txt names the five archives, the scaffold and the five installers by their digests"; fi
  fi
  if find "$CODEX/dist" -name '*.rb' | grep -q .; then fail "nocask: GoReleaser wrote $(find "$CODEX/dist" -name '*.rb')"
  else pass "nocask: GoReleaser writes no Homebrew cask"; fi
fi

missing=${installers[4]}
cp -R "$RUN/packages" "$RUN/short"
rm "$RUN/short/$missing"
if out=$(release "$RUN/short"); then
  fail "missing: GoReleaser succeeded without $missing"
elif [ -e "$CODEX/dist/checksums.txt" ]; then
  fail "missing: GoReleaser failed and still wrote checksums.txt"
elif ! grep -qF "$missing" <<<"$out"; then
  fail "missing: GoReleaser failed without naming $missing: ${out: -1000}"
else
  pass "missing: without $missing GoReleaser fails naming it, writing no checksums.txt"
fi

exit "$failed"
