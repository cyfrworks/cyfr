#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# home.sh makes the client image once for all its scripts, and an archive
# that answers wrongly for a while fails none of them. home.sh, client.sh,
# image-release.sh, the scrub and scripts/ci/retry.sh run as they are, in
# a tree of this test's own with three scripts, one, three and two in
# home.sh's order. Stood in: every CYFR and front a script runs against
# (the tree's tests/release-boot/release.sh, whose steps do nothing), and
# docker, which keeps each container and image as the list of what was
# done in it. A container started from an image begins with that image's
# list, and a commit makes the container's list the image's. A
# `docker exec` of client.sh runs the real client.sh, whose apt-get,
# useradd, su, cp, install and update-ca-certificates are stood in and add
# to the list of that container. A script's run.sh, its proof, records the
# image its container was started from and that container's list.
# The archive fails the case's fetches with a 404 for a package its
# index names. Cases:
#   flaky    the first fetch fails, the second succeeds: one image is
#            made, the fetch on the host's network, the install with none,
#            once; every script's client starts from it, holding the
#            install and its own user and trust alone; the failed fetch is
#            named; the image is removed at the end
#   down     every fetch fails: the run fails naming the failed fetch,
#            after three tries, with nothing installed, no image made and
#            no script run, and the preparing container is removed
#   failing  the first script fails and the image's removal is refused:
#            the run fails, the other scripts still run, and the script's
#            failure is reported before the image left behind
#   kept     every script passes and the image's removal is refused: the
#            run fails naming the image
# Usage: tests/desktop-proof/client-image-test.sh
# It needs git, sha256sum, python3 and node.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-desktop-client-image-test.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT

TREE="$BASE/tree"
mkdir -p "$TREE/tests/desktop-proof" "$TREE/tests/release-boot" "$TREE/tests/browser" "$TREE/tests/identity-proof" \
  "$TREE/scripts/ci" "$BASE/bin" "$BASE/system"
cp "$HERE/home.sh" "$HERE/client.sh" "$HERE/image-release.sh" "$HERE/scrub-lines.mjs" "$HERE/scrub.mjs" \
  "$TREE/tests/desktop-proof/"
cp "$ROOT/scripts/ci/retry.sh" "$TREE/scripts/ci/"
for name in one two three; do
  mkdir -p "$TREE/tests/desktop-proof/$name"
  : >"$TREE/tests/desktop-proof/$name/run.sh"
done
cat >"$TREE/tests/release-boot/release.sh" <<'STANDIN'
# The CYFRs and fronts a script runs against, stood in: no step does anything.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_SECRETS=()
declare -A IDENTITY_FRONTS=()
step() { printf '\n=== %s\n' "$*"; }
fail() { echo "::error::$*" >&2; exit 1; }
server_start() { :; }
server_stop() { :; }
cell_pick_port() { printf -v "$1" '%s' 20001; }
browser_authority() { BROWSER_AUTHORITY="$WORK/authority"; mkdir -p "$BROWSER_AUTHORITY"; echo pem >"$BROWSER_AUTHORITY/authority.pem"; }
browser_home() { mkdir -p "$1"; }
identity_directory() { IDENTITY_FRONTS[$1]="127.0.0.$((${#IDENTITY_FRONTS[@]} + 2))"; }
identity_env() { :; }
identity_reaches_directory() { :; }
identity_start() { :; }
identity_front_start() { :; }
identity_front_stop() { :; }
identity_front_control() { echo http://127.0.0.1:9; }
STANDIN
for f in tests/browser/harness.sh tests/identity-proof/front.sh tests/identity-proof/cells.sh; do
  echo "# Stood in by tests/release-boot/release.sh." >"$TREE/$f"
done
git -C "$TREE" init -q && git -C "$TREE" add -A
printf 'Package: cyfr-desktop\nArchitecture: amd64\n' >"$BASE/app.deb"

cat >"$BASE/bin/docker" <<'STANDIN'
#!/usr/bin/env bash
# Docker, stood in: a container or image is the file of what was done in it.
set -u
echo "$*" >>"$STANDIN_CALLS"
images="$STANDIN_STATE/images" containers="$STANDIN_STATE/containers"
mkdir -p "$images" "$containers"
key() { printf '%s' "$1" | tr '/:' '__'; }
case "$1" in
  image)
    case "$2" in
      inspect) echo amd64 ;;
      rm)
        if [ "$STANDIN_RM" = refuse ]; then echo "Error response from daemon: conflict: unable to delete" >&2; exit 1; fi
        rm -f "$images/$(key "${*: -1}")" ;;
    esac ;;
  run)
    shift; name="" network=default
    while [ "$#" -gt 3 ]; do
      case "$1" in
        --name) name=$2; shift 2 ;;
        --network) network=$2; shift 2 ;;
        -v | --add-host | --security-opt) shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$1" = ubuntu:24.04 ]; then : >"$containers/$name"
    elif [ -f "$images/$(key "$1")" ]; then cp "$images/$(key "$1")" "$containers/$name"
    else echo "Unable to find image '$1' locally" >&2; exit 125; fi
    printf 'network %s\nfrom %s\n' "$network" "$1" >"$containers/$name.run"
    echo c0ffee ;;
  commit) cp "$containers/$2" "$images/$(key "$3")" ;;
  rm) rm -f "$containers/${*: -1}" "$containers/${*: -1}.run" ;;
  exec)
    shift; user=root
    while case "$1" in -u) user=$2 ;; -e | -w) ;; *) false ;; esac do shift 2; done
    c=$1
    [ -f "$containers/$c" ] || { echo "Error response from daemon: No such container: $c" >&2; exit 1; }
    script=${3#/proof/}
    if [ "$user" = proof ]; then
      proof=$(dirname "$script")
      echo "$proof from $(sed -n 's/^from //p' "$containers/$c.run"): $(paste -sd '|' "$containers/$c")" >>"$STANDIN_PROOFS"
      [ "$proof" != "$STANDIN_FAILS" ]; exit
    fi
    STANDIN_CONTAINER="$containers/$c" PATH="$STANDIN_SYSTEM:$PATH" exec bash "$STANDIN_TREE/tests/desktop-proof/$script" "${@:4}" ;;
esac
exit 0
STANDIN
# The archive, through apt in a container: an index, then the packages,
# with the case's failures; an install takes only what a fetch left.
cat >"$BASE/system/apt-get" <<'STANDIN'
#!/usr/bin/env bash
network=$(sed -n 's/^network //p' "$STANDIN_CONTAINER.run")
case " $* " in
  *" update "*)
    [ "$network" != none ] || { echo "E: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/noble/InRelease  Temporary failure resolving 'archive.ubuntu.com'"; exit 100; }
    echo index >>"$STANDIN_CONTAINER" ;;
  *" --download-only "*)
    n=$(($(cat "$STANDIN_FETCHES" 2>/dev/null || echo 0) + 1)); echo "$n" >"$STANDIN_FETCHES"
    if [ "$STANDIN_CASE" = down ] || [ "$n" = 1 ]; then
      echo "E: Failed to fetch http://security.ubuntu.com/ubuntu/pool/main/t/tiff/libtiff6_4.5.1_amd64.deb  404  Not Found [IP: 91.189.91.81 80]"
      exit 100
    fi
    echo "fetched ${*: -6}" >>"$STANDIN_CONTAINER" ;;
  *" install "*)
    grep -qx "fetched ${*: -6}" "$STANDIN_CONTAINER" || { echo "E: Unable to fetch some archives"; exit 100; }
    echo "installed ${*: -6} on the network $network" >>"$STANDIN_CONTAINER" ;;
esac
STANDIN
for cmd in useradd cp install update-ca-certificates; do
  printf '#!/bin/sh\necho "%s $*" >>"$STANDIN_CONTAINER"\n' "$cmd" >"$BASE/system/$cmd"
done
# su's command, the user's own NSS store, as the user it runs as.
printf '#!/bin/sh\necho "su $1" >>"$STANDIN_CONTAINER"\n' >"$BASE/system/su"
# retry.sh's pause, recorded and not waited.
printf '#!/bin/sh\necho "sleep $*" >>"$STANDIN_CALLS"\n' >"$BASE/bin/sleep"
# The package's architecture, as dpkg-deb reads it from the stand-in DEB.
printf '#!/bin/sh\nsed -n "s/^Architecture: //p" "$2"\n' >"$BASE/bin/dpkg-deb"
chmod +x "$BASE/bin/"* "$BASE/system/"*

failures=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
calls() { grep -c -- "$2" "$BASE/$1/calls" || true; }
run_case() {
  mkdir -p "$BASE/$1/tmp" "$BASE/$1/state"; : >"$BASE/$1/calls"; : >"$BASE/$1/proofs"
  set +e
  PATH="$BASE/bin:$PATH" STANDIN_CASE=$1 STANDIN_FAILS="${2:-}" STANDIN_RM="${3:-}" STANDIN_CALLS="$BASE/$1/calls" \
    STANDIN_STATE="$BASE/$1/state" STANDIN_FETCHES="$BASE/$1/fetches" STANDIN_PROOFS="$BASE/$1/proofs" \
    STANDIN_TREE="$TREE" STANDIN_SYSTEM="$BASE/system" TMPDIR="$BASE/$1/tmp" PROOF_RUN_PREFIX= \
    bash "$TREE/tests/desktop-proof/home.sh" "$BASE/app.deb" cyfr:proof >"$BASE/$1/log" 2>&1
  status=$?
  set -e
  image="$(sed -n 's/^commit [^ ]* //p' "$BASE/$1/calls" | sort -u)"
  prep="$(sed -n 's/^run -d --name \([^ ]*-prep-[0-9]*\) .*ubuntu:24.04 sleep infinity$/\1/p' "$BASE/$1/calls")"
}
digest="$(sha256sum "$BASE/app.deb" | cut -c1-12)"
packages="/deb/cyfr-desktop.deb xvfb xauth dbus-x11 libnss3-tools ca-certificates"
# A script's client as its proof saw it: two indexes, one a try's that
# failed, the install, then its own user and trust.
client="index|index|fetched $packages|installed $packages on the network none|cp /fixture/authority.pem /usr/local/share/ca-certificates/cyfr-proof.crt|update-ca-certificates |useradd -m proof|su proof"

run_case flaky
check "flaky: the run passes" '[ "$status" = 0 ]'
check "flaky: one image is made, named for the run and the package's digest" \
  '[[ "$image" =~ ^cyfr-desktop-client-[0-9]+:$digest$ ]]'
check "flaky: the fetch from ubuntu:24.04 on the host's network, with the package" \
  '[ -n "$prep" ] && grep -qx "run -d --name $prep --network host -v $BASE/app.deb:/deb/cyfr-desktop.deb:ro .* ubuntu:24.04 sleep infinity" "$BASE/flaky/calls"'
check "flaky: the fetch is tried again after a pause, and the install runs once, with no network" \
  '[ "$(calls flaky "client.sh fetch$")" = 2 ] && [ "$(calls flaky "^sleep ")" = 1 ] && [ "$(calls flaky "client.sh install$")" = 1 ] &&
   grep -qx "run -d --name $prep --network none -v $BASE/app.deb:/deb/cyfr-desktop.deb:ro .* $image sleep infinity" "$BASE/flaky/calls"'
check "flaky: the failed fetch is named" \
  'grep -q "the archive.s answer that failed" "$BASE/flaky/log" && grep -q "^  E: .*libtiff6.* 404 " "$BASE/flaky/log"'
check "flaky: every script's client starts from that image, with the install and its own user and trust alone" \
  '[ "$(cat "$BASE/flaky/proofs")" = "$(for p in one three two; do echo "$p from $image: ${client}"; done)" ]'
check "flaky: the image is removed once the scripts have run" \
  '[ "$(tail -n 1 "$BASE/flaky/calls")" = "image rm -f $image" ]'

run_case down
check "down: the run fails saying the packages could not be fetched" \
  '[ "$status" != 0 ] && grep -q "::error::the client.s packages could not be fetched from the archive in three tries" "$BASE/down/log"'
check "down: the failed fetch is named" 'grep -q "^  E: .*libtiff6.* 404 " "$BASE/down/log"'
check "down: three fetches, nothing installed, no image, no script" \
  '[ "$(calls down "client.sh fetch$")" = 3 ] && [ "$(calls down "client.sh install$")" = 0 ] && [ -z "$image" ] && [ ! -s "$BASE/down/proofs" ]'
check "down: the preparing container is removed" '[ -n "$prep" ] && [ "$(tail -n 1 "$BASE/down/calls")" = "rm -f $prep" ]'

run_case failing one refuse
check "failing: the run fails, and the scripts after the failed one still run" \
  '[ "$status" != 0 ] && [ "$(cut -d" " -f1 "$BASE/failing/proofs" | paste -sd " ")" = "one three two" ]'
check "failing: the script's failure is reported, then the image left behind" \
  '[ "$(grep "^::error::" "$BASE/failing/log")" = "$(printf "::error::tests/desktop-proof/one/run.sh failed\n::error::could not remove the client image %s" "$image")" ]'

run_case kept "" refuse
check "kept: every script passes, and the run fails naming the image left behind" \
  '[ "$status" != 0 ] && [ "$(wc -l <"$BASE/kept/proofs")" = 3 ] && [ "$(grep "^::error::" "$BASE/kept/log")" = "::error::could not remove the client image $image" ]'

[ "$failures" = 0 ] || for c in flaky down failing kept; do echo "--- $c"; cat "$BASE/$c/log" "$BASE/$c/calls" "$BASE/$c/proofs"; done
exit "$((failures > 0))"
