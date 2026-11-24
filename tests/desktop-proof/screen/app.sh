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
#   with the keyboard shown below it as the window appears; the page is
#   painted, and the window covers the output above the keyboard; a watch
#   lost closes the window that was shown, timed from the loss, and a new
#   one shows the shell's page (the app sits under the shell's watches);
#   the keyboard killed locks the screen in the same way and is shown
#   again; cyfr killed ends the app by its own SIGKILL (exit 137 to the
#   launcher), saying why and that it ended itself, and the launcher's
#   next start is locked again; the app killed ends its cyfr within 5 s,
#   and the next start is locked too, with one screen shell running; a
#   --screen-project that names no project explicitly is refused.
# Before the app starts, Gtk's image loader can start: glycin runs each
# loader under bwrap, and a loader that cannot start makes Gtk abort the
# app whenever it asks for an icon.
# Windows are told apart by labwc's own list of them (toplevels.py), and
# the keyboard is seen on the output's picture, not as a process.
#
# What it leaves: a tap typing and the five minutes with a video playing
# need a CYFR that answers, and are the installed box's
# (tests/install-screen-proof); this smoke has no CYFR.
#
# Usage: bash tests/desktop-proof/screen/app.sh DEB
# DEB is the cyfr-desktop package of this machine's architecture, which
# this machine has installed (tests/desktop-proof/native/linux.sh), so its
# AppArmor profile is loaded: this changes nothing of this machine's. It
# needs Ubuntu 26.04, Docker and Ubuntu's archive; it binds no port of
# this machine.
set -uo pipefail

# ---- inside the container, as root ----
if [ "${1:-}" = --inside ]; then
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update -qq
  apt-get -o Acquire::Retries=3 install -y -qq --no-install-recommends \
    /fixture/app.deb labwc wvkbd swayidle wlrctl wlr-randr grim dbus procps python3 python3-gi gir1.2-glib-2.0 fonts-dejavu-core >/dev/null
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
  # The app is ended at its main process alone, which ends its helpers:
  # signalled with them (pkill -f of the program's path), main outlives its
  # GPU and zygote helpers and ends on Electron's own "GPU process isn't
  # usable", a trap (exit 133), which is the smoke's doing and no fault.
  app=^/opt/cyfr/CYFR\ --screen-project=
  finish() {
    touch "$OUT/stop"
    pkill -f -- "$app" 2>/dev/null
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
  # grep -c prints 0 and fails on a log with no such line, and prints
  # nothing on no log.
  starts() { local n; n=$(grep -c '^CYFR: ready$' "$OUT/app.log" 2>/dev/null); echo "${n:-0}"; }
  started() { [ "$(starts)" -ge "$1" ]; }
  window() { wlrctl toplevel find title:CYFR; }
  shells() { pgrep -u proof -c -f -- '^/opt/cyfr/resources/cyfr screen shell$'; }
  # The windows labwc shows now, by its handles, and whether one closed.
  shown() { awk '$1 == "open" { w[$2] = 1 } $1 == "closed" { delete w[$2] } END { for (h in w) print h }' "$OUT/toplevels"; }
  closedAt() { awk -v h="$1" '$1 == "closed" && $2 == h { print $3; exit }' "$OUT/toplevels"; }
  closed() { [ -n "$(closedAt "$1")" ]; }
  # What the screen's account runs and what labwc shows, for a row whose
  # end did not come: each process with its state and where it waits.
  held() {
    echo "processes: $(ps -u proof -o pid=,ppid=,stat=,wchan:24=,args= | cut -c 1-200 | tr '\n' '|')"
    echo "windows shown: $(shown | tr '\n' ' ')$(wlrctl toplevel find title:CYFR >/dev/null 2>&1 && echo '(one titled CYFR)')"
  }
  # cyfr killed, the Nth time: the app says cyfr ended and that it ends
  # itself, and ends by its own SIGKILL (app.js: the screen's app does not
  # quit), which the launcher sees as 137; its next start shows the locked
  # screen. An end that has not come 3 s after the kill is held: what holds
  # it is read then, while it still does, and printed beside the verdict.
  cyfr_killed() {
    local n=$1 why itself end
    pkill -u proof -f -- '^/opt/cyfr/resources/cyfr screen shell$'
    rm -f "$OUT/held"
    within 3 sh -c "[ \$(grep -c '^ended' $OUT/launches) -ge $n ]" || held >"$OUT/held"
    if within 30 sh -c "[ \$(grep -c '^ended' $OUT/launches) -ge $n ]" && within 60 started $((n + 1)) && within 30 window; then
      why=$(grep '^CYFR: cyfr ended: ' "$OUT/app.log" | sed -n "${n}p" | cut -c 7-)
      itself=$(grep "^CYFR: ended: the app's process ends itself" "$OUT/app.log" | sed -n "${n}p" | cut -c 7-)
      end=$(grep '^ended' "$OUT/launches" | sed -n "${n}p")
      if [ "$end" = "ended 137" ] && [ -n "$why" ] && [ -n "$itself" ]; then
        verdict PASS "cyfr killed ($n) ends the app ($end; it said: $why; $itself), and the next start shows the locked screen again"
      else
        verdict FAIL "cyfr killed ($n) ended the app as $end, saying ${why:-nothing}${itself:+; $itself}: it must end 137 by itself, saying cyfr ended and that it ends itself: $(tail -n 5 "$OUT/app.log" | tr '\n' ' ') $(held | tr '\n' ' ')"
      fi
    else
      verdict FAIL "cyfr killed ($n) did not end the app, or it did not start again: $(tail -n 5 "$OUT/app.log" | tr '\n' ' ') $(held | tr '\n' ' ')"
    fi
    [ ! -s "$OUT/held" ] || echo "HELD cyfr killed ($n): the end had not come 3 s after the kill: $(tr '\n' ' ' <"$OUT/held")" >>"$OUT/verdict"
  }
  newer() { awk -v h="$1" '$1 == "open" && $2 > h { found = 1 } END { exit !found }' "$OUT/toplevels"; }
  # A lock the shell made: the window shown closes within HIDE_MS of SINCE
  # (this machine's clock), and a newer window shows the shell's page,
  # painted. The hide waits on nothing (shell.Shell.Lock): measured, 6 to
  # 727 ms from the cause; a hide that waits on telling a silent CYFR takes
  # 10 s (the installed box's hide row), past the bound.
  HIDE_MS=2000
  hidden() {
    local was=$1 since=$2 at
    within 20 closed "$was" || return 1
    at=$(closedAt "$was")
    python3 -I -c 'import sys; print(round((float(sys.argv[1]) - float(sys.argv[2])) * 1000))' "$at" "$since" >"$OUT/took"
    [ "$(cat "$OUT/took")" -lt "$HIDE_MS" ] && within 30 newer "$was" && within 30 painted
  }
  # The output's picture: the page's background (#0b1418) at both top
  # corners, so the window covers the output's whole width, and more than
  # one colour above the keyboard, so the page is painted. Whether the
  # window has a frame the screen's labwc does not show (no decorations):
  # the app's tests hold it.
  painted() {
    grim -t ppm "$OUT/screen.ppm" 2>/dev/null && python3 -I - "$OUT/screen.ppm" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
head, rest = data.split(b"\n", 3)[:3], data.split(b"\n", 3)[3]
w, h = map(int, head[1].split())
if (w, h) != (1600, 900):
    sys.exit(1)
px = lambda x, y: tuple(rest[(y * w + x) * 3:(y * w + x) * 3 + 3])
page = (11, 20, 24)
corners = px(4, 4) == page and px(w - 5, 4) == page
colours = {px(x, y) for y in range(0, h // 2, 7) for x in range(0, w, 7)}
sys.exit(0 if corners and len(colours) > 2 else 1)
PY
  }
  # The keyboard as the output shows it: the bottom of the output is not
  # the page's but the keyboard's, the window maximized above it, in more
  # than two colours. A keyboard process that shows no surface fails.
  keyboard() {
    grim -t ppm "$OUT/keyboard.ppm" 2>/dev/null && python3 -I - "$OUT/keyboard.ppm" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
head, rest = data.split(b"\n", 3)[:3], data.split(b"\n", 3)[3]
w, h = map(int, head[1].split())
px = lambda x, y: tuple(rest[(y * w + x) * 3:(y * w + x) * 3 + 3])
band = [px(x, y) for y in range(h - 60, h - 2, 3) for x in range(0, w, 5)]
page = (11, 20, 24)
sys.exit(0 if sum(p != page for p in band) > 0.9 * len(band) and len(set(band)) > 2 else 1)
PY
  }

  # An output larger than the app's own window (1280x860), so only a
  # window made to cover it does.
  wlr-randr --output HEADLESS-1 --custom-mode 1600x900 >>"$OUT/randr.log" 2>&1 ||
    { verdict FAIL "the output's size was not set: $(tr '\n' ' ' <"$OUT/randr.log")"; finish; }

  # glycin's own test of its sandbox (glycin/src/sandbox.rs).
  if bwrap --unshare-all --die-with-parent --ro-bind /usr /usr --symlink usr/lib /lib --symlink usr/lib64 /lib64 /usr/bin/true >"$OUT/bwrap.log" 2>&1; then
    verdict PASS "Gtk's image loader can start: bwrap runs glycin's test of its sandbox"
  else
    verdict FAIL "Gtk's image loader cannot start, so Gtk aborts the app on an icon: bwrap said $(tr '\n' ' ' <"$OUT/bwrap.log")"
  fi

  python3 -I /fixture/toplevels.py >"$OUT/toplevels" 2>"$OUT/toplevels.err" &

  # The stand-in for the screen's launcher: the app again whenever it ends.
  (while [ ! -e "$OUT/stop" ]; do
    /opt/cyfr/resources/cyfr screen app "$PROJECT" >>"$OUT/app.log" 2>&1
    echo "ended $?" >>"$OUT/launches"
    sleep 1 # sleep-ok: the launcher's pause between starts
  done) &

  if within 60 started 1 && within 30 window; then
    verdict PASS "the app runs the screen shell in its folder and shows its page"
  else
    verdict FAIL "the app never showed the screen's page: $(tail -n 5 "$OUT/app.log" | tr '\n' ' ')"
    finish
  fi
  if within 10 keyboard; then verdict PASS "the keyboard is shown below the window as it appears"; else verdict FAIL "no keyboard shown as the window appeared"; fi
  if within 30 painted; then
    verdict PASS "the page is painted, and the window covers the output"
  else
    verdict FAIL "the page is not painted, or the window does not cover the output"
  fi

  # A watch lost: the shell hides what is on the screen, so the window shown
  # closes, and the app shows the shell's page again in a new one.
  was=$(shown | head -n 1)
  since=$(date +%s.%N)
  pkill -u proof -x swayidle
  if [ -n "$was" ] && hidden "$was" "$since"; then
    verdict PASS "a watch lost closes the window shown $(cat "$OUT/took") ms after the loss, and a new one shows the shell's page"
    echo "watch lost to window closed: $(cat "$OUT/took") ms" >>"$OUT/timing"
  else
    verdict FAIL "a watch lost did not close the window shown (${was:-none}) within $HIDE_MS ms (it took $(cat "$OUT/took" 2>/dev/null || echo more)): $(tail -n 5 "$OUT/app.log" | tr '\n' ' ')"
  fi

  # The keyboard killed: watched as the watches are, it locks the screen in
  # the same way and is shown again.
  within 30 keyboard
  was=$(shown | head -n 1)
  since=$(date +%s.%N)
  pkill -u proof -x wvkbd-mobintl
  if [ -n "$was" ] && hidden "$was" "$since" && within 30 keyboard; then
    verdict PASS "the keyboard killed closes the window shown $(cat "$OUT/took") ms after, and the keyboard is shown again"
  else
    verdict FAIL "the keyboard killed: the window shown (${was:-none}) $(closed "${was:-none}" && echo "closed after $(cat "$OUT/took") ms, the bound $HIDE_MS" || echo 'did not close'), the keyboard $(keyboard && echo shown || echo 'not shown'), $(pgrep -c -u proof -x wvkbd-mobintl) running: $(grep -a 'keyboard' "$OUT/app.log" | tail -n 3 | tr '\n' ' ')"
  fi

  cyfr_killed 1

  shell=$(pgrep -u proof -f -- '^/opt/cyfr/resources/cyfr screen shell$')
  pkill -KILL -u proof -o -f -- '^/opt/cyfr/CYFR --screen-project='
  if within 5 sh -c "! kill -0 $shell 2>/dev/null" && within 60 started 3 && within 30 window && within 30 sh -c '[ "$(pgrep -u proof -c -f -- "^/opt/cyfr/resources/cyfr screen shell\$")" = 1 ]'; then
    verdict PASS "the app killed ends its cyfr within 5 s, and the next start is locked, with one screen shell"
  else
    verdict FAIL "after the app was killed: its cyfr $(kill -0 "$shell" 2>/dev/null && echo 'still runs' || echo ended), $(shells) screen shells, $(starts) starts"
  fi

  touch "$OUT/stop"
  pkill -f -- "$app" 2>/dev/null
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
  cp "$HERE/app.sh" "$HERE/toplevels.py" "$HERE/login1.py" "$HERE/login1.conf" "$ROOT/apps/codex/cmd/screen/rc.xml" "$ROOT/apps/codex/cmd/screen/menu.xml" "$WORK/fixture/" || exit 1
chmod 755 "$WORK" "$WORK/fixture"
chmod 644 "$WORK"/fixture/*

# The engine's sandbox makes namespaces of its own inside the container, as
# in tests/desktop-proof/home.sh's client, and so does glycin's bwrap.
# Docker's AppArmor profile refuses bwrap's mounts ("Failed to make /
# slave"), so the container runs unconfined, and the app and bwrap each
# run under their own profile as on the box: the package's, which the
# package's install on this machine loaded, and for bwrap the host's,
# which Ubuntu 26.04 holds and 24.04 does not. Unconfined without the
# package's, the host's kernel refuses the engine's namespaces
# (apparmor_restrict_unprivileged_userns). The loaded profiles' names are
# read where any account may read them; nothing is loaded or removed.
dpkg-deb --fsys-tarfile "$DEB" | tar -xO ./opt/cyfr/resources/apparmor-profile >"$WORK/apparmor-profile" ||
  { echo "screen app: the package holds no AppArmor profile" >&2; exit 1; }
profile=$(sed -n 's/^profile "\([^"]*\)".*/\1/p' "$WORK/apparmor-profile")
# grep reads to the end: under pipefail, grep -q's early exit would fail
# the pipe by cat's SIGPIPE.
cat /sys/kernel/security/apparmor/policy/profiles/*/name 2>/dev/null | grep -xF -- "$profile" >/dev/null ||
  { echo "FAIL the package's AppArmor profile $profile is not loaded on this machine: install the package here first (tests/desktop-proof/native/linux.sh)"; exit 1; }
docker run -d --init --name "$BOX" ${HEAVY_CHECK_CPUS:+--cpuset-cpus "$HEAVY_CHECK_CPUS"} \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined --shm-size 512m \
  -v "$WORK/fixture:/fixture:ro" "$IMAGE" sleep infinity >/dev/null || exit 1
docker exec "$BOX" bash /fixture/app.sh --inside >"$WORK/prepare.log" 2>&1 ||
  { tail -n 30 "$WORK/prepare.log"; echo "FAIL prepare: the package, labwc, wvkbd or swayidle was not installed"; exit 1; }
docker exec -d -u proof "$BOX" python3 -s /fixture/login1.py || exit 1

said=$(docker exec -u proof -e HOME=/home/proof "$BOX" bash /fixture/app.sh --case)
echo "$said"
# The app's output whole, on a pass too, so a red elsewhere can be told
# from what a green run says; the GPU's render node lines say nothing.
echo "==== the app's output"
docker exec "$BOX" sh -c 'grep -v drm_render_node /tmp/screen-app/app.log | cut -c 1-400; echo "launches: $(tr "\n" " " </tmp/screen-app/launches)"' 2>&1
if ! grep -qx DONE <<<"$said" || grep -q '^FAIL ' <<<"$said"; then
  docker exec "$BOX" sh -c 'tail -n 25 /tmp/screen-app/labwc.log' 2>/dev/null
  exit 1
fi
