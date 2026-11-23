#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The CYFR app as the box's screen (`--screen-project`), from its package,
# under Ubuntu 26.04's own labwc on a headless output, as the screen's
# account, natively on Wayland, with the screen's keyboard (wvkbd), its
# idle and sleep watches (swayidle on a stand-in logind, login1.py) and a
# loop standing in for the screen's launcher, which starts the app again
# whenever it ends. The project folder names a CYFR on this computer that
# does not run: no page of the screen waits on it, and every page is the
# screen shell's own. Each check prints one PASS or FAIL line:
#
#   the app runs the screen shell in that folder and shows its page,
#   with the keyboard up as the window appears; the page is painted, and
#   the window has no frame and covers the output; a watch lost hides the
#   page and shows the shell's page again (the app sits under the shell's
#   watches); cyfr killed ends the app, and the launcher's next start is
#   locked again; the app killed ends its cyfr, and the next start is too,
#   with one screen shell running; a --screen-project that names no
#   project explicitly is refused.
#
# What it leaves: a tap typing and the five minutes with a video playing
# need a CYFR that answers, and are the installed box's
# (tests/install-screen-proof); this smoke has no CYFR.
#
# Usage: bash tests/desktop-proof/screen/app.sh DEB
# DEB is the cyfr-desktop package of this machine's architecture. It needs
# Docker and Ubuntu's archive, and binds no port of this machine.
set -uo pipefail

# ---- inside the container, as root ----
if [ "${1:-}" = --inside ]; then
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update -qq
  apt-get -o Acquire::Retries=3 install -y -qq --no-install-recommends \
    /fixture/app.deb labwc wvkbd swayidle wlrctl grim dbus procps python3 python3-gi gir1.2-glib-2.0 fonts-dejavu-core >/dev/null
  useradd -m proof
  install -d -o proof -m 700 /home/proof/cyfr
  printf 'services: {}\n' >/home/proof/cyfr/docker-compose.yml
  printf 'CYFR_ACCESS=local\nCYFR_PORT=4321\n' >/home/proof/cyfr/.env
  chown proof /home/proof/cyfr/docker-compose.yml /home/proof/cyfr/.env
  install -m 0644 /fixture/login1.conf /etc/dbus-1/system.d/cyfr-proof-login1.conf
  mkdir -p /run/dbus
  dbus-daemon --system --fork --nopidfile
  exit 0
fi

# ---- inside the container, as the screen's account ----
if [ "${1:-}" = --case ]; then
  export OUT=/tmp/screen-app
  export XDG_RUNTIME_DIR=$OUT/run XDG_SESSION_TYPE=wayland
  export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
  mkdir -p -m 700 "$OUT" "$XDG_RUNTIME_DIR" "$OUT/labwc"
  cp /fixture/rc.xml /fixture/menu.xml "$OUT/labwc/"
  timeout 240 dbus-run-session labwc -C "$OUT/labwc" -s "bash /fixture/app.sh --session" >"$OUT/labwc.log" 2>&1
  cat "$OUT/verdict" 2>/dev/null || echo "FAIL the smoke did not finish"
  exit 0
fi

# ---- inside labwc ----
if [ "${1:-}" = --session ]; then
  PROJECT=/home/proof/cyfr
  verdict() { echo "$1 $2" >>"$OUT/verdict"; }
  finish() {
    touch "$OUT/stop"
    pkill -f -- '^/opt/cyfr/CYFR' 2>/dev/null
    echo DONE >>"$OUT/verdict"
    pkill -x labwc
    exit 0
  }
  within() {
    local closes=$((SECONDS + $1))
    shift
    until "$@"; do
      [ "$SECONDS" -lt "$closes" ] || return 1
      sleep 0.2 # sleep-ok: polls a condition, bounded
    done
  }
  starts() { grep -c '^CYFR: ready$' "$OUT/app.log" 2>/dev/null || echo 0; }
  started() { [ "$(starts)" -ge "$1" ]; }
  window() { wlrctl toplevel find title:CYFR; }
  keyboard() { pgrep -u proof -x wvkbd-mobintl >/dev/null; }
  shells() { pgrep -u proof -c -f -- '^/opt/cyfr/resources/cyfr screen shell --app$'; }
  # The output's picture: the page's background (#0b1418) at both top
  # corners, so no frame and the whole width, and more than one colour
  # above the keyboard, so the page is painted.
  painted() {
    grim -t ppm "$OUT/screen.ppm" 2>/dev/null && python3 -I - "$OUT/screen.ppm" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
head, rest = data.split(b"\n", 3)[:3], data.split(b"\n", 3)[3]
w, h = map(int, head[1].split())
px = lambda x, y: tuple(rest[(y * w + x) * 3:(y * w + x) * 3 + 3])
page = (11, 20, 24)
corners = px(4, 4) == page and px(w - 5, 4) == page
colours = {px(x, y) for y in range(0, h // 2, 7) for x in range(0, w, 7)}
sys.exit(0 if corners and len(colours) > 2 else 1)
PY
  }

  # The stand-in for the screen's launcher: the app again whenever it ends.
  (while [ ! -e "$OUT/stop" ]; do
    /opt/cyfr/CYFR --screen-project="$PROJECT" >>"$OUT/app.log" 2>&1
    echo "ended $?" >>"$OUT/launches"
    sleep 1 # sleep-ok: the launcher's pause between starts
  done) &

  if within 60 started 1 && within 30 window; then
    verdict PASS "the app runs the screen shell in its folder and shows its page"
  else
    verdict FAIL "the app never showed the screen's page: $(tail -n 5 "$OUT/app.log" | tr '\n' ' ')"
    finish
  fi
  if keyboard; then verdict PASS "the keyboard is up as the window appears"; else verdict FAIL "no keyboard as the window appeared"; fi
  if within 30 painted; then
    verdict PASS "the page is painted, and the window has no frame and covers the output"
  else
    verdict FAIL "the page is not painted, or has a frame, or does not cover the output"
  fi

  # A watch lost: the shell hides what is on the screen, and the app shows
  # the shell's page again, in a new window.
  before=$(grep -c 'locked: the device locked' "$OUT/app.log")
  pkill -u proof -x swayidle
  if within 20 sh -c "[ \$(grep -c 'locked: the device locked' '$OUT/app.log') -gt $before ]" && within 30 window && within 30 painted; then
    verdict PASS "a watch lost hides the page, and the shell's page shows again"
  else
    verdict FAIL "a watch lost did not hide the page: $(tail -n 5 "$OUT/app.log" | tr '\n' ' ')"
  fi

  pkill -u proof -f -- '^/opt/cyfr/resources/cyfr screen shell --app$'
  if within 30 grep -q '^ended' "$OUT/launches" && within 60 started 2 && within 30 window; then
    verdict PASS "cyfr killed ends the app, and the next start shows the locked screen again"
  else
    verdict FAIL "cyfr killed did not end the app, or it did not start again: $(tail -n 5 "$OUT/app.log" | tr '\n' ' ')"
  fi

  pkill -KILL -u proof -o -f -- '^/opt/cyfr/CYFR --screen-project='
  if within 60 started 3 && within 30 window && within 30 sh -c '[ "$(pgrep -u proof -c -f -- "^/opt/cyfr/resources/cyfr screen shell --app\$")" = 1 ]'; then
    verdict PASS "the app killed ends its cyfr, and the next start is locked, with one screen shell"
  else
    verdict FAIL "after the app was killed: $(shells) screen shells, $(starts) starts"
  fi

  touch "$OUT/stop"
  pkill -f -- '^/opt/cyfr/CYFR' 2>/dev/null
  within 30 sh -c '! pgrep -u proof -f -- "^/opt/cyfr/CYFR" >/dev/null'
  /opt/cyfr/CYFR --screen-project=cyfr >"$OUT/refused.log" 2>&1
  refused=$?
  if [ "$refused" = 2 ] && grep -q 'refused: --screen-project' "$OUT/refused.log"; then
    verdict PASS "a --screen-project that names no project explicitly is refused"
  else
    verdict FAIL "a relative --screen-project exited $refused: $(head -n 3 "$OUT/refused.log" | tr '\n' ' ')"
  fi
  finish
fi

# ---- on this machine ----
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
IMAGE=ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
[ "$#" -eq 1 ] || { echo "usage: bash $0 DEB" >&2; exit 64; }
DEB=$(realpath -e "$1") || exit 64
command -v docker >/dev/null || { echo "screen app: docker is needed" >&2; exit 69; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-screen-app.XXXXXX") || exit 1
BOX="${PROOF_RUN_PREFIX:-}cyfr-screen-app-$$"
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
cp "$DEB" "$WORK/fixture/app.deb" &&
  cp "$HERE/app.sh" "$HERE/login1.py" "$HERE/login1.conf" "$ROOT/apps/codex/cmd/screen/rc.xml" "$ROOT/apps/codex/cmd/screen/menu.xml" "$WORK/fixture/" || exit 1
chmod 755 "$WORK" "$WORK/fixture"
chmod 644 "$WORK"/fixture/*

# The engine's sandbox makes namespaces of its own inside the container, as
# in tests/desktop-proof/home.sh's client.
docker run -d --init --name "$BOX" ${HEAVY_CHECK_CPUS:+--cpuset-cpus "$HEAVY_CHECK_CPUS"} \
  --security-opt seccomp=unconfined --shm-size 512m \
  -v "$WORK/fixture:/fixture:ro" "$IMAGE" sleep infinity >/dev/null || exit 1
docker exec "$BOX" bash /fixture/app.sh --inside >"$WORK/prepare.log" 2>&1 ||
  { tail -n 30 "$WORK/prepare.log"; echo "FAIL prepare: the package, labwc, wvkbd or swayidle was not installed"; exit 1; }
docker exec -d -u proof "$BOX" python3 -s /fixture/login1.py || exit 1

said=$(docker exec -u proof -e HOME=/home/proof "$BOX" bash /fixture/app.sh --case)
echo "$said"
if ! grep -qx DONE <<<"$said" || grep -q '^FAIL ' <<<"$said"; then
  docker exec "$BOX" sh -c 'tail -n 25 /tmp/screen-app/app.log /tmp/screen-app/labwc.log /tmp/screen-app/launches' 2>/dev/null
  exit 1
fi
