#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# home.sh makes the client image once for all its scripts, and an archive
# that answers wrongly for a while fails none of them: home.sh, client.sh
# and scripts/ci/retry.sh as they are, in a tree of this test's own whose
# three scripts' proofs are a stand-in (its tests/release-boot/release.sh,
# which records the client image a script is given and ends it), against
# a stand-in docker that records every call and whose fetch in the client
# answers as the case says:
#   flaky   the first fetch fails as today's archive did (a 404 for a
#           package its index names), the second succeeds: one image is
#           made, with one install, from which every script starts, and it
#           is removed at the end; the failed fetch is named
#   down    every fetch fails: the run fails naming the failed fetch, after
#           three tries, with nothing installed, no image made and no
#           script run, and the preparing container is removed
#   failing a script fails: the run fails and the image is still removed
# Usage: tests/desktop-proof/client-image-test.sh
# It needs git and sha256sum.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-desktop-client-image-test.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT

TREE="$BASE/tree"
mkdir -p "$TREE/tests/desktop-proof" "$TREE/tests/release-boot" "$TREE/scripts/ci" "$BASE/bin"
cp "$HERE/home.sh" "$HERE/client.sh" "$TREE/tests/desktop-proof/"
cp "$ROOT/scripts/ci/retry.sh" "$TREE/scripts/ci/"
for name in one two three; do
  mkdir -p "$TREE/tests/desktop-proof/$name"
  : >"$TREE/tests/desktop-proof/$name/run.sh"
done
# A script's proof, from the moment its CYFR would be made: it records the
# client image it was given and ends, failing for the case's script.
cat >"$TREE/tests/release-boot/release.sh" <<'STANDIN'
echo "$(basename "$(dirname "$SCRIPT")") $CLIENT_IMAGE" >>"$STANDIN_PROOFS"
[ "$(basename "$(dirname "$SCRIPT")")" != "${STANDIN_FAILS:-}" ] || exit 1
exit 0
STANDIN
git -C "$TREE" init -q && git -C "$TREE" add -A
printf 'Package: cyfr-desktop\nArchitecture: amd64\n' >"$BASE/app.deb"

cat >"$BASE/bin/docker" <<'STANDIN'
#!/bin/sh
echo "$*" >>"$STANDIN_CALLS"
case "$1 $*" in
  "image image inspect -f {{.Architecture}} cyfr:proof") echo amd64 ;;
  exec*"/client.sh fetch")
    n=$(($(cat "$STANDIN_FETCHES" 2>/dev/null || echo 0) + 1)); echo "$n" >"$STANDIN_FETCHES"
    if [ "$STANDIN_CASE" = down ] || [ "$n" = 1 ]; then
      echo "the archive's answer that failed:"
      echo "  E: Failed to fetch http://security.ubuntu.com/ubuntu/pool/main/t/tiff/libtiff6_4.5.1_amd64.deb  404  Not Found [IP: 91.189.91.81 80]"
      exit 1
    fi ;;
esac
exit 0
STANDIN
# retry.sh's pause, recorded and not waited.
printf '#!/bin/sh\necho "sleep $*" >>"$STANDIN_CALLS"\n' >"$BASE/bin/sleep"
# The package's architecture, as dpkg-deb reads it from the stand-in DEB.
printf '#!/bin/sh\nsed -n "s/^Architecture: //p" "$2"\n' >"$BASE/bin/dpkg-deb"
chmod +x "$BASE/bin/docker" "$BASE/bin/sleep" "$BASE/bin/dpkg-deb"

failures=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
calls() { grep -c -- "$2" "$BASE/$1/calls" || true; }
run_case() {
  mkdir -p "$BASE/$1/tmp"; : >"$BASE/$1/calls"; : >"$BASE/$1/proofs"
  set +e
  PATH="$BASE/bin:$PATH" STANDIN_CASE=$1 STANDIN_FAILS="${2:-}" STANDIN_CALLS="$BASE/$1/calls" \
    STANDIN_FETCHES="$BASE/$1/fetches" STANDIN_PROOFS="$BASE/$1/proofs" TMPDIR="$BASE/$1/tmp" PROOF_RUN_PREFIX= \
    bash "$TREE/tests/desktop-proof/home.sh" "$BASE/app.deb" cyfr:proof >"$BASE/$1/log" 2>&1
  status=$?
  set -e
  image="$(sed -n 's/^commit [^ ]* //p' "$BASE/$1/calls")"
  prep="$(sed -n 's/^run -d --name \([^ ]*\) .*/\1/p' "$BASE/$1/calls")"
}
digest="$(sha256sum "$BASE/app.deb" | cut -c1-12)"

run_case flaky
check "flaky: the run passes" '[ "$status" = 0 ]'
check "flaky: one image is made, named for the run and the package's digest" \
  '[ "$(calls flaky "^commit ")" = 1 ] && [[ "$image" =~ ^cyfr-desktop-client-[0-9]+:$digest$ ]]'
check "flaky: from one container of ubuntu:24.04, with the package" \
  '[ "$(calls flaky "^run ")" = 1 ] && grep -q "^run .*-v $BASE/app.deb:/deb/cyfr-desktop.deb:ro .*ubuntu:24.04 sleep infinity$" "$BASE/flaky/calls"'
check "flaky: the fetch is tried again after a pause, and the install runs once" \
  '[ "$(calls flaky "client.sh fetch$")" = 2 ] && [ "$(calls flaky "^sleep ")" = 1 ] && [ "$(calls flaky "client.sh install$")" = 1 ]'
check "flaky: the failed fetch is named" 'grep -q "libtiff6.* 404 " "$BASE/flaky/log"'
check "flaky: every script is given that image" \
  '[ "$(cat "$BASE/flaky/proofs")" = "$(printf "one %s\nthree %s\ntwo %s" "$image" "$image" "$image")" ]'
check "flaky: the image is removed once the scripts have run" \
  '[ "$(tail -n 1 "$BASE/flaky/calls")" = "image rm -f $image" ]'

run_case down
check "down: the run fails saying the packages could not be fetched" \
  '[ "$status" != 0 ] && grep -q "::error::the client.s packages could not be fetched from the archive in three tries" "$BASE/down/log"'
check "down: the failed fetch is named" 'grep -q "libtiff6.* 404 " "$BASE/down/log"'
check "down: three fetches, nothing installed, no image, no script" \
  '[ "$(calls down "client.sh fetch$")" = 3 ] && [ "$(calls down "client.sh install$")" = 0 ] && [ -z "$image" ] && [ ! -s "$BASE/down/proofs" ]'
check "down: the preparing container is removed" '[ -n "$prep" ] && [ "$(tail -n 2 "$BASE/down/calls" | head -n 1)" = "rm -f $prep" ]'

run_case failing two
check "failing: the run fails, the other scripts still run" \
  '[ "$status" != 0 ] && [ "$(cut -d" " -f1 "$BASE/failing/proofs" | tr "\n" " ")" = "one three two " ]'
check "failing: the image is removed" '[ -n "$image" ] && [ "$(tail -n 1 "$BASE/failing/calls")" = "image rm -f $image" ]'

[ "$failures" = 0 ] || for c in flaky down failing; do echo "--- $c"; cat "$BASE/$c/log" "$BASE/$c/calls"; done
exit "$((failures > 0))"
