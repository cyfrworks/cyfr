#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The screen's idle lock against the engine that can hold it off: this
# tree's watches (apps/codex/cmd watchScreen, as TestScreenWatchHelper runs
# them) under Ubuntu 26.04's own labwc and swayidle, beside the screen's
# Chrome with the screen's flags, in a container with a headless output.
# Three cases, each in a compositor of its own:
#
#   still   the page plays nothing
#   page    the page plays video with sound, started by a tap
#   frame   a frame sandboxed as an app's is with nothing granted
#           (allow-scripts alone, an opaque origin, no autoplay) plays it,
#           started by a tap on it
#
# In each the watch must lock. Beside it runs the control, swayidle's
# ordinary timeout of the same length, which must fire on the still page
# and must not while either video plays: that is what shows the page held
# an idle inhibitor, without which the row would show nothing.
#
# The length is three seconds in place of five minutes, which
# apps/codex/cmd's tests hold to five. The tap is a virtual pointer's
# (tap.py), real input to labwc: Chrome takes no inhibitor for playback
# that no input started. The container has no logind, so a suspend is not
# shown here.
#
# Usage: bash tests/desktop-proof/screen/idle.sh
# It needs Docker, Go, linux/amd64 (Chrome's package), Ubuntu's archive and
# Google's Chrome download. It binds no port of this machine. Each check
# prints one PASS or FAIL line and one FAIL fails the run.
set -uo pipefail

AFTER=3

# ---- inside the container, as root ----
if [ "${1:-}" = --inside ]; then
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update -qq
  apt-get -o Acquire::Retries=3 install -y -qq --no-install-recommends \
    labwc swayidle wlrctl dbus procps python3 curl ca-certificates fonts-dejavu-core >/dev/null
  curl -fsSL --retry 5 --retry-all-errors -o /tmp/chrome.deb \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get -o Acquire::Retries=3 install -y -qq /tmp/chrome.deb >/dev/null
  useradd -m proof
  exit 0
fi

# ---- inside the container, as the screen's account: one case ----
if [ "${1:-}" = --case ]; then
  export CASE=$2 OUT=/tmp/case-$2
  export XDG_RUNTIME_DIR=$OUT/run XDG_SESSION_TYPE=tty
  export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
  mkdir -p -m 700 "$OUT" "$XDG_RUNTIME_DIR" "$OUT/labwc" "$OUT/site"
  cp /fixture/rc.xml /fixture/menu.xml "$OUT/labwc/"
  cp /fixture/site.py /fixture/tap.py "$OUT/site/"
  timeout 120 dbus-run-session labwc -C "$OUT/labwc" -s "bash /fixture/idle.sh --session" >"$OUT/labwc.log" 2>&1
  cat "$OUT/verdict" 2>/dev/null || echo "FAIL $CASE: the case did not finish"
  exit 0
fi

# ---- inside labwc ----
if [ "${1:-}" = --session ]; then
  verdict() { echo "$1 $CASE: $2" >>"$OUT/verdict"; }
  finish() {
    # shellcheck disable=SC2046 # one pid a word
    kill $(jobs -p) 2>/dev/null
    pkill -x labwc
    exit 0
  }
  python3 -I "$OUT/site/site.py" >"$OUT/address" 2>"$OUT/site.log" &
  for _ in $(seq 100); do
    [ -s "$OUT/address" ] && break
    sleep 0.1 # sleep-ok: polls the page server's address
  done
  address=$(cat "$OUT/address")
  google-chrome-stable --no-first-run --no-default-browser-check --disable-extensions \
    --ozone-platform=wayland --user-data-dir="$OUT/chrome" \
    --app="$address/$CASE" >"$OUT/chrome.log" 2>&1 &
  stands() { wlrctl toplevel find "title:cyfr-proof-$CASE-$1"; }
  for _ in $(seq 120); do
    stands waiting && break
    sleep 0.5 # sleep-ok: polls the window's title, which the page sets as it loads
  done
  stands waiting || { verdict FAIL "the page never loaded"; finish; }
  for _ in 1 2 3 4 5; do
    python3 -I "$OUT/site/tap.py" 320 180 >>"$OUT/tap.log" 2>&1
    stands waiting || break
  done
  for _ in $(seq 60); do
    stands ready && break
    sleep 0.5 # sleep-ok: polls the window's title, which the page sets once it has played
  done
  stands ready || { verdict FAIL "the tap started nothing"; finish; }

  CYFR_SCREEN_WATCH_AFTER=${AFTER}s /fixture/cmd.test -test.run '^TestScreenWatchHelper$' -test.v >"$OUT/watch" 2>&1 &
  for _ in $(seq 100); do
    grep -q '^watching$' "$OUT/watch" && break
    sleep 0.1 # sleep-ok: polls the watch's start
  done
  swayidle -w timeout "$AFTER" "touch $OUT/control" >"$OUT/control.log" 2>&1 &
  sleep $((AFTER * 4)) # sleep-ok: the time without input under test, four times over
  if grep -q '^locked: Locked after five minutes without use\.$' "$OUT/watch"; then
    verdict PASS "the screen's watch locked"
  else
    verdict FAIL "the screen's watch did not lock: $(tr '\n' ' ' <"$OUT/watch")"
  fi
  if [ "$CASE" = still ]; then
    if [ -e "$OUT/control" ]; then verdict PASS "the control fired"; else verdict FAIL "the control never fired, so it shows nothing"; fi
  else
    if [ -e "$OUT/control" ]; then verdict FAIL "the control fired, so nothing held the screen awake and the row shows nothing"; else verdict PASS "the control was held off"; fi
  fi
  finish
fi

# ---- on this machine ----
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
IMAGE=ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
for tool in docker go; do
  command -v "$tool" >/dev/null || { echo "idle: $tool is needed" >&2; exit 69; }
done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-screen-idle.XXXXXX") || exit 1
BOX="${PROOF_RUN_PREFIX:-}cyfr-screen-idle-$$"
cleanup() {
  local code=$?
  docker rm -f "$BOX" >/dev/null 2>&1
  rm -rf "$WORK"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$WORK/fixture" || exit 1
(cd "$ROOT/apps/codex" && CGO_ENABLED=0 go test -c -o "$WORK/fixture/cmd.test" ./cmd) ||
  { echo "FAIL build: the screen's watches did not build"; exit 1; }
cp "$HERE/idle.sh" "$HERE/site.py" "$HERE/tap.py" "$ROOT/apps/codex/cmd/screen/rc.xml" "$ROOT/apps/codex/cmd/screen/menu.xml" "$WORK/fixture/" || exit 1
chmod 755 "$WORK" "$WORK/fixture" "$WORK/fixture/cmd.test"
chmod 644 "$WORK/fixture/idle.sh" "$WORK/fixture/site.py" "$WORK/fixture/tap.py" "$WORK/fixture/rc.xml" "$WORK/fixture/menu.xml"

# Chrome's sandbox makes namespaces of its own inside the container, as in
# tests/desktop-proof/home.sh's client.
docker run -d --init --name "$BOX" ${HEAVY_CHECK_CPUS:+--cpuset-cpus "$HEAVY_CHECK_CPUS"} \
  --security-opt seccomp=unconfined --shm-size 512m \
  -v "$WORK/fixture:/fixture:ro" "$IMAGE" sleep infinity >/dev/null || exit 1
docker exec "$BOX" bash /fixture/idle.sh --inside >"$WORK/prepare.log" 2>&1 ||
  { tail -n 30 "$WORK/prepare.log"; echo "FAIL prepare: labwc, swayidle or Chrome was not installed"; exit 1; }
docker exec "$BOX" sh -c 'google-chrome-stable --version; dpkg-query -W labwc swayidle'

failed=0
for case in still page frame; do
  said=$(docker exec -u proof -e HOME=/home/proof "$BOX" bash /fixture/idle.sh --case "$case")
  echo "$said"
  if [ "$(grep -c '^PASS ' <<<"$said")" != 2 ] || grep -q '^FAIL ' <<<"$said"; then
    failed=1
    docker exec "$BOX" sh -c "tail -n 15 /tmp/case-$case/chrome.log /tmp/case-$case/labwc.log" 2>/dev/null
  fi
done
exit "$failed"
