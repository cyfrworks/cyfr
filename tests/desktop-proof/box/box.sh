#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The box's screen with two CYFRs that answer: the CYFR app from its
# package as the box's screen (`cyfr screen app`, the launcher's command),
# under Ubuntu 26.04's own labwc on a headless output, as the box's
# account, with the screen's keyboard (wvkbd), its watches (swayidle on a
# stand-in logind, ../screen/login1.py) and a loop standing in for the
# screen's launcher. Its folder's CYFR, This box, runs on this machine's
# Docker, set up by the box's account with `cyfr init` and setup's own
# start; the CYFR elsewhere, x.test, is a public home behind a TLS front,
# a release of the same image. Both read their people's accounts at the
# account service dir.test, a third release. Every press is a person's,
# where the output shows what is pressed (screen.py: tesseract on grim's
# picture, tap.py's virtual pointer, wtype's virtual keyboard), and what
# each CYFR holds is read at that CYFR (fixture.exs). Before the rows the
# box's account is made on This box's own setup page, This box's first
# person, and This box is locked by Prism's Lock. Then, each row a PASS
# or FAIL line, a wait that runs out failing its row by name:
#
#   1 locked, x.test pressed on the rail opens its lock page and nothing
#     else: x.test holds no client and no session of the box's account
#   2 the box's six words typed there open x.test's Prism by x.test's own
#     admission: it holds the box's key as an active client and a session
#     of that key
#   3 Prism's Lock there closes the window shown within the lock's bound
#     (2 s, labwc's own list of windows, as the screen step's rows), and
#     x.test holds no session of the box's account any more
#   5 x.test stopped, This box pressed on the rail shows This box's lock
#     page, and the six words open This box's Prism there: This box holds
#     a session of the box's key again
#
# No idle row: the idle lock reaches the same lock entry Prism's Lock does
# (internal/desktop.Service.lockStep; TestEveryLockOnABoxIsOneStep moves
# the epoch by either alike at a CYFR elsewhere), and the idle trigger
# itself is the screen step's (../screen/app.sh) and the installed box's.
# What stays the installed box's (tests/install-screen-proof) and a
# person's: sleep and wake, a reboot, a real touch panel, the chip (this
# client has none, so its key is under six words and not a PIN), the
# screen's real unit and logind.
#
# Stand-ins: x.test's people are made by admission alone, so the box's
# account is made x.test's first person by x.test's own setup token
# through its fixture (fixture.exs admit), a stand-in for an invitation;
# the box's device then reaches x.test by its own hello and the door's
# verdict. This box reaches dir.test as a cell does (tests/identity-
# proof/cells.sh): a resolver file naming dir.test's front, that address
# among its private egress targets, and the run's authority loaded into
# its node, the file and the authority mounted into its cyfr. dir.test's
# front stands on the gateway address of This box's own Docker network,
# which the compose file fixes, so This box's container reaches it there
# as everyone on this machine's network does; x.test's front stands on a
# loopback address of the run's own (tests/identity-proof/front.sh).
#
# Usage: bash tests/desktop-proof/box/box.sh DEB IMAGE
#   DEB    the cyfr-desktop package of this machine's architecture, which
#          this machine has installed, so its AppArmor profile is loaded
#   IMAGE  the app image, loaded, of the same architecture
# It runs on a disposable machine alone: the client is given this
# machine's Docker socket and This box's folder, and This box's stack
# holds the compose file's fixed container names and subnets. It needs
# Ubuntu 26.04 (the screen step's reasons, ../screen/app.sh), Docker, Go
# (the cells' command line), python3, openssl, node and Ubuntu's archive;
# it binds 127.0.0.1:7340 and This box's port. What it keeps (its rows and
# the app's output) lands in PROOF_OUT/box (default: the run's scratch
# directory); every container, front, stack and the scratch directory,
# with the run's authority key and the setup tokens, are removed as it
# ends, whether it passes or fails.
set -uo pipefail

# ---- inside the client, as root ----
if [ "${1:-}" = --inside ]; then
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update -qq
  apt-get -o Acquire::Retries=3 install -y -qq --no-install-recommends \
    /deb/app.deb labwc wvkbd swayidle wlrctl wlr-randr grim wtype tesseract-ocr python3-pil dbus procps python3 \
    python3-gi gir1.2-glib-2.0 fonts-dejavu-core docker.io docker-compose-v2 libnss3-tools ca-certificates >/dev/null
  cp "$FIX/authority.pem" /usr/local/share/ca-certificates/cyfr-proof.crt
  update-ca-certificates >/dev/null
  # The box's account is this machine's user by id, so This box's folder
  # is its own here and there, and in the docker group by the socket's.
  getent group docker >/dev/null || groupadd docker
  groupmod -o -g "$DOCKER_GID" docker
  other=$(getent passwd "$PROOF_UID" | cut -d: -f1)
  [ -z "$other" ] || userdel "$other" || true
  useradd -m -u "$PROOF_UID" proof
  usermod -aG docker proof
  su proof -c 'mkdir -p ~/.pki/nssdb && certutil -d sql:$HOME/.pki/nssdb -N --empty-password &&
    certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "cyfr proof run" -i '"$FIX"'/authority.pem'
  # The list keeps x.test beside This box, whose entry the first start
  # makes, as a CYFR connected to before.
  install -d -o proof -m 700 /home/proof/.cyfr /home/proof/.cyfr/device
  printf '{"version":1,"homes":{"https://x.test":{"directory":"https://dir.test","generation":1}},"generations":1}\n' \
    >/home/proof/.cyfr/device/homes.json
  chown proof /home/proof/.cyfr/device/homes.json
  chmod 600 /home/proof/.cyfr/device/homes.json
  install -m 0644 "$FIX/login1.conf" /etc/dbus-1/system.d/cyfr-proof-login1.conf
  mkdir -p /run/dbus
  dbus-daemon --system --fork --nopidfile
  exit 0
fi

# ---- inside the client, as the box's account ----
if [ "${1:-}" = --case ]; then
  export OUT=/tmp/box-proof
  export XDG_RUNTIME_DIR=$OUT/run XDG_SESSION_TYPE=wayland
  export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
  mkdir -p -m 700 "$OUT" "$XDG_RUNTIME_DIR" "$OUT/labwc"
  cp "$FIX/rc.xml" "$FIX/menu.xml" "$OUT/labwc/"
  timeout 900 dbus-run-session labwc -C "$OUT/labwc" -s "bash $FIX/box.sh --session" >"$OUT/labwc.log" 2>&1
  cat "$FIX/verdict" 2>/dev/null || echo "FAIL the rows did not finish"
  grep -v drm_render_node "$OUT/app.log" 2>/dev/null | cut -c 1-400 >"$FIX/out/app.log"
  exit 0
fi

# ---- inside labwc ----
if [ "${1:-}" = --session ]; then
  BOX_HOME="http://localhost:$BOX_PORT" X_HOME=https://x.test
  verdict() { echo "$1 $2" >>"$FIX/verdict"; }
  app=^/opt/cyfr/CYFR\ --screen-project=
  finish() {
    touch "$OUT/stop"
    pkill -f -- "$app" 2>/dev/null
    echo DONE >>"$FIX/verdict"
    pkill -x labwc
    exit 0
  }
  # A step before the rows that fails ends the run, naming the step. The
  # output is kept as a picture only once the setup page, which shows the
  # six words and the recovery code, is gone (SHOWN).
  SHOWN=""
  broke() {
    verdict FAIL "$1: $(tail -n 5 "$OUT/app.log" | tr '\n' ' ')"
    [ -z "$SHOWN" ] || grim -t png "$FIX/out/failed.png" 2>/dev/null
    finish
  }
  # A row's failure names the row and what it waited for.
  failed() {
    verdict FAIL "row $1: $2: $(tail -n 3 "$OUT/app.log" | tr '\n' ' ')"
    grim -t png "$FIX/out/row-$1.png" 2>/dev/null
    return 1
  }
  within() {
    local closes=$((SECONDS + $1))
    shift
    until "$@"; do
      [ "$SECONDS" -lt "$closes" ] || return 1
      sleep 0.5 # sleep-ok: polls a condition, bounded
    done
  }
  starts() { local n; n=$(grep -c '^CYFR: ready$' "$OUT/app.log" 2>/dev/null); echo "${n:-0}"; }
  started() { [ "$(starts)" -ge "$1" ]; }
  window() { wlrctl toplevel find title:CYFR; }
  proposals() { local n; n=$(grep -c -x -F "CYFR: home: $1" "$OUT/app.log" 2>/dev/null); echo "${n:-0}"; }
  proposed() { [ "$(proposals "$1")" -gt "$2" ]; }
  shown() { awk '$1 == "open" { w[$2] = 1 } $1 == "closed" { delete w[$2] } END { for (h in w) print h }' "$OUT/toplevels"; }
  closedAt() { awk -v h="$1" '$1 == "closed" && $2 == h { print $3; exit }' "$OUT/toplevels"; }
  closed() { [ -n "$(closedAt "$1")" ]; }
  ms() { python3 -I -c 'import sys; print(round((float(sys.argv[1]) - float(sys.argv[2])) * 1000))' "$1" "$2"; }
  screen() { python3 -I "$FIX/screen.py" "$@" 2>>"$OUT/screen.err"; }
  sees() { screen shows "$1"; }
  unseen() { ! screen shows "$1"; }
  # A press of what the output shows, or of the rail at X Y of the output
  # (1600x900; tap.py takes 1280x720), its time kept in $OUT/pressed.
  push() { TAP_AT="$OUT/pressed" screen press "$1" >>"$OUT/presses"; }
  rail() { TAP_AT="$OUT/pressed" python3 -I "$FIX/tap.py" $(($1 * 1280 / 1600)) $(($2 * 720 / 900)) 2>>"$OUT/tap.log"; }
  typed() { wtype -- "$1"; }
  key() { wtype -k "$1"; }
  # What the run's host answers (box.sh's dispatch): one ask written
  # whole, its answer read once within 120 s.
  ASKS=0
  ask() {
    ASKS=$((ASKS + 1))
    printf '%s\n' "$1" >"$FIX/ask-$ASKS.part" && mv "$FIX/ask-$ASKS.part" "$FIX/ask-$ASKS.json"
    local closes=$((SECONDS + 120))
    until [ -s "$FIX/answer-$ASKS.json" ]; do
      [ "$SECONDS" -lt "$closes" ] || return 1
      sleep 0.2 # sleep-ok: polls the host's answer, bounded
    done
    cat "$FIX/answer-$ASKS.json"
    rm -f "$FIX/answer-$ASKS.json"
  }
  # py JSON EXPRESSION [WORD...]: EXPRESSION of the JSON document d, the
  # words after it in sys.argv from 3 on.
  py() { python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@" 2>/dev/null; }
  # What the CYFR at $1 (x or box) holds of the box's account, kept in
  # $OUT/held-$1.
  held() { ask "{\"ask\": \"sessions-$1\", \"identifier\": \"$ID\"}" >"$OUT/held-$1"; }
  live() { held "$1" && [ "$(py "$(cat "$OUT/held-$1")" 'len(d["live"])')" "$2" "$3" ]; }

  # An output larger than the app's own window, as the screen step's.
  wlr-randr --output HEADLESS-1 --custom-mode 1600x900 >>"$OUT/randr.log" 2>&1 || broke "the output's size was not set"
  python3 -I "$FIX/toplevels.py" >"$OUT/toplevels" 2>"$OUT/toplevels.err" &
  (while [ ! -e "$OUT/stop" ]; do
    /opt/cyfr/resources/cyfr screen app "$BOXDIR" >>"$OUT/app.log" 2>&1
    echo "ended $?" >>"$OUT/launches"
    sleep 1 # sleep-ok: the launcher's pause between starts
  done) &

  # ---- before the rows: the box's account, This box's first person ----
  within 90 started 1 && within 30 window || broke "the app never showed the box's screen"
  within 90 sees "Show the passphrase" || broke "This box's setup page did not offer its passphrase"
  push "Show the passphrase" || broke "Show the passphrase could not be pressed"
  within 30 sh -c "python3 -I '$FIX/screen.py' words '$FIX/bip39.txt' >'$OUT/six' 2>>'$OUT/screen.err'" ||
    broke "no six words of the passphrase list were shown"
  WORDS=$(cat "$OUT/six")
  rm -f "$OUT/six"
  push "Your name, yours for life" || broke "the setup page's name could not be pressed"
  typed boxperson && key Tab && typed "$WORDS" && key Tab && typed "$WORDS" && key Return || broke "wtype did not type"
  within 60 sees "I saved it" || broke "the setup page did not show the recovery code"
  push "I saved it" || broke "I saved it could not be pressed"
  within 60 sh -c 'python3 -I -c "import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get(\"identifier\") else 1)" ~/.cyfr/device/holder.json 2>/dev/null' ||
    broke "the box's key names no account"
  ID=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identifier"])' ~/.cyfr/device/holder.json)
  within 90 live box -ge 1 || broke "This box holds no session of its first person: $(cat "$OUT/held-box" 2>/dev/null)"
  SHOWN=yes
  verdict PASS "before the rows: the box's account made on This box's setup page, This box's first person, its Prism open"
  said=$(ask "{\"ask\": \"admit\", \"identifier\": \"$ID\"}")
  [ -n "$(py "$said" 'd.get("admitted") or ""')" ] || broke "x.test did not make the box's account its first person: $said"
  within 60 sees "Lock" || broke "This box's Prism shows no Lock"
  push "Lock" || broke "This box's Lock could not be pressed"
  within 30 sees "CYFR is locked" || broke "Prism's Lock did not lock This box"
  within 30 live box -eq 0 || broke "This box still holds a session after its Lock: $(cat "$OUT/held-box")"
  verdict PASS "before the rows: x.test made the box's account its first person (the stand-in for an invitation), and This box locked by its Prism's Lock"

  # ---- 1: x.test pressed while locked opens nothing ----
  row1() {
    local before
    before=$(proposals "$X_HOME")
    rail 36 142
    within 30 proposed "$X_HOME" "$before" || { failed 1 "x.test was not proposed after its row was pressed"; return; }
    within 60 sees "CYFR is locked" || { failed 1 "x.test's lock page did not show"; return; }
    # Whatever the press would open has had its time.
    sleep 5 # sleep-ok: the window in which a session x.test admitted would be there
    held x || { failed 1 "x.test did not answer what it holds"; return; }
    if [ "$(py "$(cat "$OUT/held-x")" 'd["person"] and not d["clients"] and not d["live"] and d["reserved"] == 0')" = True ]; then
      verdict PASS "row 1: locked, x.test pressed on the rail shows its lock page and opens nothing: x.test holds no client and no session of the box's account"
    else
      failed 1 "x.test holds something of the box's account: $(cat "$OUT/held-x")"
    fi
  }
  # ---- 2: the six words open x.test by its own admission ----
  row2() {
    push "Passphrase" || { failed 2 "x.test's lock page offers no passphrase"; return; }
    typed "$WORDS" && key Return || { failed 2 "wtype did not type"; return; }
    within 60 live x -ge 1 || { failed 2 "x.test holds no session of the box's account: $(cat "$OUT/held-x" 2>/dev/null)"; return; }
    within 30 unseen "CYFR is locked" || { failed 2 "the lock page still shows"; return; }
    if [ "$(py "$(cat "$OUT/held-x")" 'len(d["clients"]) == 1 and d["clients"][0]["standing"] == "active" and all(s["kid"] == d["clients"][0]["kid"] for s in d["live"])')" = True ]; then
      KID=$(py "$(cat "$OUT/held-x")" 'd["clients"][0]["kid"]')
      verdict PASS "row 2: the six words open x.test by its own admission: it holds the box's key ($KID) as its one active client and $(py "$(cat "$OUT/held-x")" 'len(d["live"])') session(s) of it"
    else
      failed 2 "x.test's admission is not the box's key alone: $(cat "$OUT/held-x")"
    fi
  }
  # ---- 3: Prism's Lock there hides within the bound and ends its sessions ----
  HIDE_MS=2000
  row3() {
    local was took
    within 60 sees "Lock" || { failed 3 "x.test's Prism shows no Lock"; return; }
    was=$(shown | head -n 1)
    push "Lock" || { failed 3 "x.test's Lock could not be pressed"; return; }
    within 20 closed "$was" || { failed 3 "the window shown ($was) did not close"; return; }
    took=$(ms "$(closedAt "$was")" "$(cat "$OUT/pressed")")
    [ "$took" -lt "$HIDE_MS" ] || { failed 3 "the window shown closed $took ms after the press, past the bound of $HIDE_MS ms"; return; }
    within 20 live x -eq 0 || { failed 3 "x.test still holds a session of the box's account: $(cat "$OUT/held-x")"; return; }
    within 30 sees "CYFR is locked" || { failed 3 "no lock page showed again"; return; }
    verdict PASS "row 3: Prism's Lock at x.test closed the window shown $took ms after the press, confirmed by labwc's list, and x.test holds no session of the box's account"
  }
  # ---- 5: x.test stopped, This box opens and unlocks ----
  row5() {
    local before said took
    said=$(ask '{"ask": "stop-x"}')
    [ "$(py "$said" 'd.get("stopped")')" = True ] || { failed 5 "x.test could not be stopped: $said"; return; }
    before=$(proposals "$BOX_HOME")
    rail 36 66
    within 30 proposed "$BOX_HOME" "$before" || { failed 5 "This box was not proposed after its row was pressed"; return; }
    within 60 sees "CYFR is locked" || { failed 5 "This box's lock page did not show"; return; }
    took=$(ms "$(date +%s.%N)" "$(cat "$OUT/pressed")")
    push "Passphrase" || { failed 5 "This box's lock page offers no passphrase"; return; }
    typed "$WORDS" && key Return || { failed 5 "wtype did not type"; return; }
    within 60 live box -ge 1 || { failed 5 "This box holds no session of the box's account: $(cat "$OUT/held-box" 2>/dev/null)"; return; }
    if [ "$(py "$(cat "$OUT/held-box")" 'bool(d["live"]) and (not sys.argv[3] or all(s["kid"] == sys.argv[3] for s in d["live"]))' "${KID:-}")" = True ]; then
      verdict PASS "row 5: x.test stopped, This box pressed on the rail showed its lock page within $took ms of the press, and the six words opened This box's Prism there: it holds $(py "$(cat "$OUT/held-box")" 'len(d["live"])') session(s) of the box's key"
    else
      failed 5 "This box's sessions are not of the box's key: $(cat "$OUT/held-box")"
    fi
  }
  row1
  row2
  row3
  row5
  finish
fi

# ---- on this machine ----
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$#" -eq 2 ] || { echo "usage: bash tests/desktop-proof/box/box.sh DEB IMAGE" >&2; exit 64; }
DEB="$(realpath -e "$1")"
IMAGE="$2"
CLIENT_IMAGE=ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-box-proof-XXXXXX")"
# shellcheck source=../../release-boot/release.sh
source "$HERE/../../release-boot/release.sh"
# shellcheck source=../../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
# shellcheck source=../../identity-proof/front.sh
source "$ROOT/tests/identity-proof/front.sh"
# shellcheck source=../../identity-proof/cells.sh
source "$ROOT/tests/identity-proof/cells.sh"
# shellcheck source=../image-release.sh
source "$ROOT/tests/desktop-proof/image-release.sh"
# shellcheck source=../../setup-proof/folder.sh
source "$ROOT/tests/setup-proof/folder.sh"
KEEP="${PROOF_OUT:-$WORK/out}/box"
FIX="$WORK/fixture"
RUN="${PROOF_RUN_PREFIX:-}cyfr-box-$$"
CLIENT="$RUN-client"
CELLS="$RUN-cell"
BOXDIR="$WORK/$RUN"
# The gateway of This box's default network (docker-compose.yml fixes its
# subnet), where dir.test's front stands.
GATEWAY=172.16.230.1
mkdir -p "$FIX/out" "$KEEP" "$BOXDIR"

compose_box() { (cd "$BOXDIR" && timeout 300 docker compose --project-name "$(basename "$BOXDIR")" --project-directory "$BOXDIR" \
  -f docker-compose.yml -f docker-compose.override.yml "$@"); }
box_cyfr() { docker ps -q --filter "label=com.docker.compose.project.working_dir=$BOXDIR" --filter label=com.docker.compose.service=cyfr | head -n 1; }
cleanup() {
  local code=$? left=""
  trap - EXIT
  [ -z "${PROOF_PID:-}" ] || kill "$PROOF_PID" 2>/dev/null || true
  docker rm -f "$CLIENT" >/dev/null 2>&1 || true
  if [ -f "$BOXDIR/.env" ]; then compose_box down -v --remove-orphans >/dev/null 2>&1 || left="$left This box's stack;"; fi
  identity_front_stop
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  docker ps -aq --filter "name=^$CELLS-" | xargs -r docker rm -f >/dev/null 2>&1 || true
  cp -R "$FIX/out/." "$KEEP/" 2>/dev/null || true
  # This box's files are its container's as well as this user's.
  if [ -z "$left" ]; then
    timeout 120 docker run --rm --network none -v "$WORK:/w" ubuntu:24.04 find /w -mindepth 1 -not -path "/w/out*" -delete >/dev/null 2>&1 ||
      left="$left the scratch directory's files;"
  fi
  if [ -n "$left" ]; then
    echo "::error::could not remove$left $WORK is kept"
    [ "$code" -ne 0 ] || code=1
  elif [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

step "the package's AppArmor profile and the image"
dpkg-deb --fsys-tarfile "$DEB" | tar -xO ./opt/cyfr/resources/apparmor-profile >"$WORK/apparmor-profile" ||
  fail "the package holds no AppArmor profile"
profile=$(sed -n 's/^profile "\([^"]*\)".*/\1/p' "$WORK/apparmor-profile")
cat /sys/kernel/security/apparmor/policy/profiles/*/name 2>/dev/null | grep -xF -- "$profile" >/dev/null ||
  fail "the package's AppArmor profile $profile is not loaded on this machine: install the package here first"
[ "$(dpkg-deb -f "$DEB" Architecture)" = "$(docker image inspect -f '{{.Architecture}}' "$IMAGE")" ] ||
  fail "the package and the image $IMAGE are of other architectures"
image_release "$IMAGE" "$CELLS"

step "the account service dir.test and the CYFR elsewhere x.test, from $IMAGE"
browser_authority
identity_directory dir.test
IDENTITY_FRONTS[dir.test]="$GATEWAY"
identity_directory x.test
DIR="$WORK/dir"
X="$WORK/x"
browser_home "$DIR" dir.test
identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
browser_home "$X" x.test
identity_reaches_directory "$X" dir.test
identity_env "$X" CYFR_REGISTRY_URL dir.test
X_TOKEN="$(openssl rand -hex 32)"
LOG_SECRETS+=("$X_TOKEN")
identity_env "$X" CYFR_SETUP_TOKEN "$X_TOKEN"
server_start "$DIR"
identity_start "$X"
identity_front_start "$X"

step "This box's folder, and the client"
cp "$BROWSER_AUTHORITY/authority.pem" "$FIX/authority.pem"
printf '{host, {%s}, ["dir.test"]}.\n{lookup, [file, native]}.\n' "${GATEWAY//./,}" >"$FIX/inetrc"
cp "$HERE/box.sh" "$HERE/screen.py" "$HERE/../screen/tap.py" "$HERE/../screen/toplevels.py" "$HERE/../screen/login1.py" \
  "$HERE/../screen/login1.conf" "$ROOT/apps/codex/cmd/screen/rc.xml" "$ROOT/apps/codex/cmd/screen/menu.xml" "$FIX/"
cp "$ROOT/apps/codex/internal/holder/bip39_english.txt" "$FIX/bip39.txt"
chmod -R a+rX "$FIX"
BOX_PORT="$(free_port)"
SEED_MOUNTS="$FIX/authority.pem:/run/cyfr-proof/authority.pem:ro $FIX/inetrc:/run/cyfr-proof/inetrc:ro" \
  seed "$BOXDIR" "$BOX_PORT" CYFR_DIRECTORY_URL=https://dir.test CYFR_REGISTRY_URL=dir.test \
  ERL_INETRC=/run/cyfr-proof/inetrc "CYFR_PRIVATE_EGRESS_TARGETS=locus-backends,$GATEWAY"
docker rm -f "$CLIENT" >/dev/null 2>&1 || true
# The engine's sandbox and glycin's bwrap make namespaces of their own, so
# the client runs unconfined and the app under its package's profile, as
# the screen step's (../screen/app.sh).
docker run -d --init --name "$CLIENT" --network host ${HEAVY_CHECK_CPUS:+--cpuset-cpus "$HEAVY_CHECK_CPUS"} \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined --shm-size 512m \
  --add-host "x.test:${IDENTITY_FRONTS[x.test]}" --add-host "dir.test:$GATEWAY" \
  -v "$DEB:/deb/app.deb:ro" -v "$WORK:$WORK" -v /var/run/docker.sock:/var/run/docker.sock \
  "$CLIENT_IMAGE" sleep infinity >/dev/null
docker exec -e FIX="$FIX" -e PROOF_UID="$(id -u)" -e DOCKER_GID="$(stat -c %g /var/run/docker.sock)" "$CLIENT" \
  bash "$FIX/box.sh" --inside >"$WORK/prepare.log" 2>&1 || { tail -n 30 "$WORK/prepare.log" >&2; fail "the client could not be prepared"; }

step "This box set up by the box's account: cyfr init, then setup's start"
as_box() { docker exec -u proof -w "$BOXDIR" -e HOME=/home/proof "$CLIENT" "$@"; }
as_box timeout 300 /opt/cyfr/resources/cyfr init --no-interactive --no-pull >"$WORK/init.log" 2>&1 ||
  { tail -n 30 "$WORK/init.log" >&2; fail "cyfr init failed in This box's folder"; }
# setup's work ends at the end of its stdin, which a pipe held open here keeps.
as_box timeout 600 bash -c 'mkfifo /tmp/held && exec 3<>/tmp/held && exec /opt/cyfr/resources/cyfr internal setup-project run "$PWD" <&3' \
  >"$WORK/setup.log" 2>&1 || true
grep -q '"type":"done"' "$WORK/setup.log" || { tail -n 30 "$WORK/setup.log" >&2; fail "setup's start of This box did not finish"; }
closes=$((SECONDS + 180))
until curl -fsS -m 5 -o /dev/null "http://127.0.0.1:$BOX_PORT/api/health/ready"; do
  [ "$SECONDS" -lt "$closes" ] || fail "This box did not answer on 127.0.0.1:$BOX_PORT"
  sleep 2
done
CID="$(box_cyfr)"
[ -n "$CID" ] || fail "no container of This box's stack serves it"
trusted="$(docker exec -u app "$CID" /app/bin/cyfr rpc ':public_key.cacerts_load("/run/cyfr-proof/authority.pem"); IO.puts("TRUST=ok")' | sed -n 's/^TRUST=//p' | tail -1)"
[ "$trusted" = ok ] || fail "This box did not take the run's authority"
identity_front_start "$DIR"
echo "This box answers at http://localhost:$BOX_PORT; dir.test's front at $GATEWAY, x.test's at ${IDENTITY_FRONTS[x.test]}"

# What This box holds, asked inside its container (fixture.exs).
box_fixture() {
  local code args="" arg
  code="$(base64 -w0 "$HERE/fixture.exs")"
  for arg in "$@"; do args="$args\"$arg\","; done
  docker exec -u app "$CID" /app/bin/cyfr rpc \
    "{answer, _} = Code.eval_string(Base.decode64!(\"$code\")); IO.puts(answer.([${args%,}]))" | sed -n 's/^FIXTURE=//p' | tail -1
}
# The rows' asks (box.sh --session's ask), answered here.
dispatch() {
  local ask="$1" what id
  what="$(asked "$ask" ask)"
  id="$(asked "$ask" identifier 2>/dev/null || true)"
  [[ "$id" =~ ^[A-Za-z0-9_.:-]*$ ]] || { ANSWER='{"error":"no identifier this fixture reads"}'; return; }
  case "$what" in
    admit) ANSWER="$(cell_fixture "$X" "$HERE/fixture.exs" FIXTURE admit "$id")" ;;
    sessions-x) ANSWER="$(cell_fixture "$X" "$HERE/fixture.exs" FIXTURE sessions "$id")" ;;
    sessions-box) ANSWER="$(box_fixture sessions "$id")" ;;
    stop-x)
      # A server that outlives its stop fails the run (server_stop).
      server_stop "$X" >>"$WORK/stop.log" 2>&1
      ANSWER='{"stopped": true}'
      ;;
  esac
}

step "the rows"
docker exec -d "$CLIENT" python3 -I -c 'import os, socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.bind("/dev/log")
os.chmod("/dev/log", 0o666)
with open("/run/syslog.txt", "ab", 0) as f:
    while True:
        f.write(s.recv(65536) + b"\n")'
docker exec -d -u proof "$CLIENT" python3 -s "$FIX/login1.py"
docker exec -u proof -e HOME=/home/proof -e FIX="$FIX" -e BOXDIR="$BOXDIR" -e BOX_PORT="$BOX_PORT" "$CLIENT" \
  bash "$FIX/box.sh" --case >"$WORK/said" 2>&1 &
PROOF_PID=$!
OUT="$FIX" proof_await dispatch
cat "$WORK/said"
echo "==== the app's output"
cat "$FIX/out/app.log" 2>/dev/null || true
cp "$WORK/said" "$FIX/out/rows.txt"
grep -qx DONE "$WORK/said" && ! grep -q '^FAIL ' "$WORK/said"
