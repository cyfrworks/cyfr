#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The screen's watches against the engine and the programs they rest on:
# this tree's (apps/codex/cmd screenWatches, as TestScreenWatchHelper keeps
# them) under Ubuntu 26.04's own labwc and swayidle, beside the screen's
# Chrome with the screen's flags, in a container with a headless output and
# a stand-in logind on its system bus (login1.py). Five cases, each in a
# compositor of its own:
#
#   still    the page plays nothing: the watch locks, and the control fires
#   page     the page plays a video, started by a tap
#   frame    a frame sandboxed as an app's is with nothing granted
#            (allow-scripts alone, an opaque origin, no autoplay) plays it,
#            started by a tap on it
#   suspend  the account has a swayidle configuration naming a command of
#            its own for sleep: the sleep still locks, that command never
#            runs, and the screen is watched again at the waking
#   unheard  swayidle runs with no subscription to sleep (no system bus):
#            the screen is never watched and says why
#
# The control is swayidle's ordinary timeout of the watch's own length.
# With a video: it starts once Chrome asked the compositor for an idle
# inhibitor (its Wayland requests, WAYLAND_DEBUG), is seen registered,
# stays silent and alive while the watch locks, and the same process must
# fire once a second tap has ended the playback. A control that never
# registered, exited or cannot fire fails the row, as does a page that held
# nothing.
#
# The length is three seconds in place of five minutes, which
# apps/codex/cmd's tests hold to five. The taps are a virtual pointer's
# (tap.py), real input to labwc: Chrome takes no inhibitor for playback
# that no input started. The stand-in is no logind: that a real sleep
# reaches swayidle is logind's and the kernel's, and that one it did not
# report locks at the waking is apps/codex/cmd's tests', on stand-in clocks.
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
    labwc swayidle wlrctl dbus procps python3 python3-gi gir1.2-glib-2.0 curl ca-certificates fonts-dejavu-core >/dev/null
  curl -fsSL --retry 5 --retry-all-errors -o /tmp/chrome.deb \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get -o Acquire::Retries=3 install -y -qq /tmp/chrome.deb >/dev/null
  useradd -m proof
  install -m 0644 /fixture/login1.conf /etc/dbus-1/system.d/cyfr-proof-login1.conf
  mkdir -p /run/dbus
  dbus-daemon --system --fork --nopidfile
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
    echo "DONE $CASE" >>"$OUT/verdict"
    # shellcheck disable=SC2046 # one pid a word
    kill $(jobs -p) 2>/dev/null
    pkill -x labwc
    exit 0
  }
  # within SECONDS COMMAND...: whether COMMAND came true within SECONDS.
  within() {
    local closes=$((SECONDS + $1))
    shift
    until "$@"; do
      [ "$SECONDS" -lt "$closes" ] || return 1
      sleep 0.2 # sleep-ok: polls a condition, bounded
    done
  }
  said() { grep -qxF "$1" "$OUT/watch"; }
  watched_again() { [ "$(grep -cxF watching "$OUT/watch")" -ge 2 ]; }
  watch() {
    CYFR_SCREEN_WATCH_AFTER=$1 /fixture/cmd.test -test.run '^TestScreenWatchHelper$' -test.v >"$OUT/watch" 2>&1 &
  }
  SLEEP_LOST='unwatched: This screen stays locked because it cannot tell when this device goes to sleep.'

  if [ "$CASE" = suspend ]; then
    export XDG_CONFIG_HOME=$OUT/config
    mkdir -p "$XDG_CONFIG_HOME/swayidle"
    echo "before-sleep 'touch $OUT/replaced'" >"$XDG_CONFIG_HOME/swayidle/config"
    watch 1h
    within 30 said watching || { verdict FAIL "the screen was never watched: $(tr '\n' ' ' <"$OUT/watch")"; finish; }
    pkill -USR1 -f '^python3 -s /fixture/login1.py'
    if within 15 said 'locked: Locked as this device went to sleep.' && within 15 said "$SLEEP_LOST"; then
      verdict PASS "the sleep locked, and the screen is not watched until the waking"
    else
      verdict FAIL "the sleep did not lock: $(tr '\n' ' ' <"$OUT/watch")"
    fi
    pkill -USR2 -f '^python3 -s /fixture/login1.py'
    if within 15 watched_again; then verdict PASS "the screen is watched again at the waking"; else verdict FAIL "the waking left it unwatched"; fi
    if [ -e "$OUT/replaced" ]; then verdict FAIL "the account's configuration replaced the screen's command"; else verdict PASS "the account's configuration was not read"; fi
    finish
  fi

  if [ "$CASE" = unheard ]; then
    export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$OUT/no-bus
    watch 1h
    if within 10 pgrep -u proof -x swayidle >/dev/null; then verdict PASS "swayidle runs"; else verdict FAIL "swayidle never ran, so the row shows nothing"; fi
    if within 20 said "$SLEEP_LOST" && ! said watching; then
      verdict PASS "running with no subscription, it is never a watch, and the screen says why"
    else
      verdict FAIL "a swayidle with no subscription was taken for a watch: $(tr '\n' ' ' <"$OUT/watch")"
    fi
    finish
  fi

  python3 -I "$OUT/site/site.py" >"$OUT/address" 2>"$OUT/site.log" &
  within 10 test -s "$OUT/address" || { verdict FAIL "the pages were never served"; finish; }
  address=$(cat "$OUT/address")
  WAYLAND_DEBUG=client google-chrome-stable --no-first-run --no-default-browser-check --disable-extensions \
    --ozone-platform=wayland --user-data-dir="$OUT/chrome" \
    --app="$address/$CASE" >"$OUT/chrome.log" 2>&1 &
  stands() { wlrctl toplevel find "title:cyfr-proof-$CASE-$1"; }
  tap() { python3 -I "$OUT/site/tap.py" 320 180 >>"$OUT/tap.log" 2>&1; }
  within 60 stands waiting || { verdict FAIL "the page never loaded"; finish; }
  for _ in 1 2 3 4 5; do
    tap
    stands waiting || break
  done
  within 30 stands started || { verdict FAIL "the tap started nothing"; finish; }
  inhibited() { grep -qa 'zwp_idle_inhibit_manager_v1.*create_inhibitor' "$OUT/chrome.log"; }
  if [ "$CASE" != still ]; then
    within 30 inhibited || { verdict FAIL "Chrome took no idle inhibitor, so the row shows nothing"; finish; }
  fi

  swayidle -d -w -C /dev/null timeout "$AFTER" "touch $OUT/control" >"$OUT/control.log" 2>&1 &
  control=$!
  registered() { grep -qa "Register with timeout: $((AFTER * 1000))\$" "$OUT/control.log"; }
  within 10 registered || { verdict FAIL "the control never registered, so the row shows nothing"; finish; }
  watch "${AFTER}s"
  within 30 said watching || { verdict FAIL "the screen was never watched: $(tr '\n' ' ' <"$OUT/watch")"; finish; }
  sleep $((AFTER * 4)) # sleep-ok: the time without input under test, four times over

  if said 'locked: Locked after five minutes without use.'; then
    verdict PASS "the screen's watch locked"
  else
    verdict FAIL "the screen's watch did not lock: $(tr '\n' ' ' <"$OUT/watch")"
  fi
  if [ "$CASE" = still ]; then
    if [ -e "$OUT/control" ]; then verdict PASS "the control fired"; else verdict FAIL "the control never fired, so it shows nothing"; fi
    finish
  fi
  if [ -e "$OUT/control" ]; then
    verdict FAIL "the control fired, so nothing held the screen awake and the row shows nothing"
    finish
  fi
  kill -0 "$control" 2>/dev/null || { verdict FAIL "the control exited, so its silence shows nothing"; finish; }
  verdict PASS "the control was held off"
  for _ in 1 2 3 4 5; do
    tap
    stands started || break
  done
  within 15 stands stopped || { verdict FAIL "the second tap did not end the playback"; finish; }
  if within 30 test -e "$OUT/control" && kill -0 "$control" 2>/dev/null; then
    verdict PASS "that same control fired once the playback ended"
  else
    verdict FAIL "the control did not fire once the playback ended, so its silence shows nothing"
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
cp "$HERE/idle.sh" "$HERE/site.py" "$HERE/tap.py" "$HERE/login1.py" "$HERE/login1.conf" "$ROOT/apps/codex/cmd/screen/rc.xml" "$ROOT/apps/codex/cmd/screen/menu.xml" "$WORK/fixture/" || exit 1
chmod 755 "$WORK" "$WORK/fixture" "$WORK/fixture/cmd.test"
chmod 644 "$WORK/fixture/login1.py" "$WORK/fixture/login1.conf" "$WORK/fixture/idle.sh" "$WORK/fixture/site.py" "$WORK/fixture/tap.py" "$WORK/fixture/rc.xml" "$WORK/fixture/menu.xml"

# Chrome's sandbox makes namespaces of its own inside the container, as in
# tests/desktop-proof/home.sh's client.
docker run -d --init --name "$BOX" ${HEAVY_CHECK_CPUS:+--cpuset-cpus "$HEAVY_CHECK_CPUS"} \
  --security-opt seccomp=unconfined --shm-size 512m \
  -v "$WORK/fixture:/fixture:ro" "$IMAGE" sleep infinity >/dev/null || exit 1
docker exec "$BOX" bash /fixture/idle.sh --inside >"$WORK/prepare.log" 2>&1 ||
  { tail -n 30 "$WORK/prepare.log"; echo "FAIL prepare: labwc, swayidle or Chrome was not installed"; exit 1; }
docker exec "$BOX" sh -c 'google-chrome-stable --version; dpkg-query -W labwc swayidle'

# -s keeps the account's own modules out; -I would hide Ubuntu's gi.
docker exec -d -u proof "$BOX" python3 -s /fixture/login1.py || exit 1

failed=0
for case in still page frame suspend unheard; do
  said=$(docker exec -u proof -e HOME=/home/proof "$BOX" bash /fixture/idle.sh --case "$case")
  echo "$said"
  if ! grep -qx "DONE $case" <<<"$said" || grep -q '^FAIL ' <<<"$said"; then
    failed=1
    docker exec "$BOX" sh -c "tail -n 15 /tmp/case-$case/watch /tmp/case-$case/control.log /tmp/case-$case/labwc.log" 2>/dev/null
  fi
done
exit "$failed"
