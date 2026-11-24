#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The setup proof in the installed app: the candidate DEB in a client
# container of Ubuntu 26.04 on this host's network, with this host's Docker
# behind its socket, run as an account in the docker group whose app
# process lacks that group (a stale group: setup's work goes through the
# real sg), sets CYFR up in a folder seeded as a release's download would
# leave it, with the loaded app image, and opens it. app/proof.js drives
# the app from inside its main process; this script does what the host
# does between its steps. Three launches:
#
#   first   missing_to_ready  with no Docker socket the setup screen says
#                             Docker does not answer and shows the commands;
#                             the socket given, Check again in the same
#                             window answers again
#           stale             that answer: Docker answers and Set up and
#                             start is offered, though the app's process
#                             lacks the docker group
#           downloading       Set up and start shows each of its steps as
#                             it begins, in order, up to the download, which
#                             this script holds
#           quit (here)       the person quits during the download: 15 s
#                             after the app's end, counted once from its
#                             exit as observed here, nothing of setup's work
#                             runs or holds the app's output, nothing of the
#                             stack is there, and .env is written; the held
#                             pull then released, no docker call follows it
#                             and nothing starts.
#                             The work is counted from /proc, zombies aside,
#                             by a shell that skips itself: its own command
#                             line names setup-project, which once counted
#                             it as setup's work
#   again   reshown           the chooser's renderer lost mid-run: the page
#                             shown in its place shows the progress while
#                             the start is held, and once it is released
#                             and done offers Open CYFR, opening nothing by
#                             itself
#           partial           the folder's setup goes on from what is
#                             there: its one step is the start, .env as it
#                             was
#           first_person      Open CYFR opens the device's pages, and the
#                             first person's setup ends in Prism, live
#   passkey first_passkey     on the passkey road, as on macOS and Windows,
#                             in a second folder (the first CYFR taken
#                             down): the CYFR set up opens at its setup
#                             page, whose Create your account makes the
#                             account with a passkey in the account window,
#                             and that account is its first person, in
#                             Prism, live. The setup token spends itself
#                             when the first person is made; until then it
#                             is in no address the app sent, no header, no
#                             line it or the proof printed, nothing the run
#                             keeps and no file of the app's after it quit.
#                             The setup page hands it to its own CYFR over
#                             that CYFR's socket, which is what it is for:
#                             a message to another origin is the policy's
#                             to refuse (its tests), not this row's to read
#
# No lock is a row: on a desktop nothing locks while no CYFR is open, so a
# lock during a setup is held by the app's Go and JS tests, and the chooser
# shown anew mid-run is the renderer lost. The system's folder dialog is
# stood in for (app/proof.js); the real one is a person's to check.
#
# Usage: tests/setup-proof/app.sh DEB IMAGE
#   DEB    the candidate cyfr-desktop package for this host's architecture
#   IMAGE  the app image, loaded
# It needs Docker, node and npm's install of apps/codex/desktop (pack.mjs
# bundles with its esbuild), and python3. The rows land in
# SETUP_PROOF_OUT (default: the run's scratch directory). It removes only
# what it made: the client by the id its own create returned, the stack of
# its own Compose project, its scratch directory; each Docker call there has
# a bound, and a removal that fails fails the run, naming what is left and
# keeping the scratch directory a retry needs. Everything it starts carries
# the run's prefixed name. Locally it binds 127.0.0.1:7340 on the host's
# network: run it inside flock /var/tmp/cyfr/port-7340.lock.
set -euo pipefail
DEB=$(realpath "${1:?usage: app.sh DEB IMAGE}")
IMAGE=${2:?usage: app.sh DEB IMAGE}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-desktop-proof-setup-XXXXXX")
OUT=${SETUP_PROOF_OUT:-$W/out}
RUN="${PROOF_RUN_PREFIX:-}cyfr-setup-app-$$"; D="$W/$RUN"; CLIENT="$RUN-client"
mkdir -p "$W/fixture/out" "$D" "$OUT"
: >"$W/fixture/withheld"
# compose_in NAME DIR ARGS: the Compose project NAME in DIR, bounded.
compose_in() { (cd "$2" && timeout 300 docker compose --project-name "$1" --project-directory "$2" -f docker-compose.yml -f docker-compose.override.yml "${@:3}"); }
compose() { compose_in "$RUN" "$D" "$@"; }
# The run's Compose projects, NAME:DIR each, the passkey launch's second
# among them once it is made.
PROJECTS="$RUN:$D"
CLIENT_ID=
cleanup() {
  code=$?; trap - EXIT
  local left=""
  # The answerer holds this script's output open: a run that fails before
  # it is stopped would otherwise never end for whoever reads that output.
  [ -z "${ANSWERER:-}" ] || kill "$ANSWERER" 2>/dev/null || true
  if [ -n "$CLIENT_ID" ]; then
    # A failed call's error text is kept but for a line carrying a value
    # of a folder's .env, which is dropped: compose can quote what it read.
    timeout 30 docker exec "$CLIENT_ID" cat /tmp/docker-times 2>/dev/null | python3 -I -c '
import sys
values = set()
for f in sys.argv[1:]:
    try:
        lines = open(f).read().splitlines()
    except OSError:
        values = None
        break
    for line in lines:
        v = line.partition("=")[2].strip().strip(chr(34) + chr(39))
        if len(v) >= 8:
            values.add(v)
for line in sys.stdin:
    if line.startswith("    ") and (values is None or any(v in line for v in values)):
        print("    (a line carrying a value of .env, dropped)" if values is not None else "    (a .env unread: its error text dropped)")
        continue
    sys.stdout.write(line)
' $(find "$W" -mindepth 2 -maxdepth 2 -name .env 2>/dev/null) >"$OUT/docker-calls.txt" 2>/dev/null || true
    timeout 60 docker rm -f "$CLIENT_ID" >/dev/null 2>&1 || left="$left the client container $CLIENT_ID;"
  fi
  for s in ${SCRUBS:-}; do kill "$s" 2>/dev/null || true; done
  local p
  for p in $PROJECTS; do
    [ ! -f "${p#*:}/.env" ] || compose_in "${p%%:*}" "${p#*:}" down -v --remove-orphans >/dev/null 2>&1 ||
      left="$left the Compose project ${p%%:*}, whose files are in ${p#*:};"
  done
  cp "$W"/fixture/out/* "$OUT/" 2>/dev/null || true
  # The stack's own files are root's: they are removed as root.
  if [ -z "$left" ]; then
    timeout 120 docker run --rm --name "$RUN-clean" --network none -v "$W:/w" ubuntu:24.04 find /w -mindepth 1 -not -path "/w/out*" -delete >/dev/null 2>&1 ||
      left="$left the scratch directory's files;"
  fi
  if [ -n "$left" ]; then
    echo "FAIL cleanup: could not remove$left $W is kept for a retry"
    [ "$code" != 0 ] || code=1
  elif [ -n "${SETUP_PROOF_OUT:-}" ]; then
    rm -rf "$W"
  fi
  echo "setup app proof: exit $code"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
failed() { echo "FAIL $1"; exit 1; }

# seed DIR PORT: the folder as a release's download leaves it, but for the
# loaded image and no Locus (the candidate is a dev build, which downloads
# nothing), for a CYFR at PORT serving its own accounts.
free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
seed() {
local D=$1 PORT=$2 ADDR="http://localhost:$2"
cp "$ROOT/docker-compose.yml" "$ROOT/Caddyfile" "$D/"
cp "$ROOT/apps/locus/keeper/seccomp/keeper.json" "$D/keeper.seccomp.json"
cat >"$D/docker-compose.override.yml" <<Y
services:
  cyfr:
    image: $IMAGE
    pull_policy: never
    container_name: !reset null
  locus-runtime:
    profiles: ["proof-never"]
  locus-backends:
    profiles: ["proof-never"]
  locus-backends-guard:
    profiles: ["proof-never"]
Y
sed -e "s|^CYFR_PORT=.*|CYFR_PORT=$PORT|" -e 's|^CYFR_LOCUS_BUILDS_URL=.*|CYFR_LOCUS_BUILDS_URL=|' \
  -e '/^CYFR_DIRECTORY_SERVE=/d;/^CYFR_DIRECTORY_URL=/d;/^CYFR_REGISTRY_URL=/d;/^CYFR_PRIVATE_EGRESS_TARGETS=/d' "$ROOT/.env.example" >"$D/.env.example"
printf '%s\n' "" CYFR_AUTO_MIGRATE=on CYFR_DIRECTORY_SERVE=writer "CYFR_DIRECTORY_URL=$ADDR" "CYFR_REGISTRY_URL=localhost:$PORT" \
  CYFR_PRIVATE_EGRESS_TARGETS=locus-backends,127.0.0.1 >>"$D/.env.example"
}
# The proof's inputs for a launch: the CYFR at ADDR in folder DIR.
inputs() { printf '{"home": "%s", "directory": "%s", "fronts": {}, "folder": "%s", "docker_gid": %s}\n' "$1" "$1" "$2" "$GID" >"$W/fixture/inputs.json"; }
PORT=$(free_port); ADDR="http://localhost:$PORT"
seed "$D" "$PORT"
GID=$(stat -c %g /var/run/docker.sock)
inputs "$ADDR" "$D"
node "$ROOT/tests/desktop-proof/pack.mjs" "$ROOT/tests/setup-proof/app/proof.js" "$W/fixture/proof.asar"

# The socket is mounted beside its place, which is empty until the proof
# asks for Docker. The docker the app finds holds a pull until released,
# and a start until the proof releases it (its reshown row).
cat >"$W/fixture/wrap-docker" <<'WRAP'
#!/bin/bash
# Each call is logged; a pull is held until /tmp/pull-go, and says so if it
# is released rather than ended, or once /tmp/pull-done is there ends at
# once; a start is held until /tmp/up-go. Each call is also timed in
# /tmp/docker-times, which the run keeps, with its exit status and, for a
# call that failed, the last 40 lines of its standard error: its arguments
# are paths and names alone, and its standard error names files,
# services, containers and variables, and can quote what compose read,
# so the copy the run keeps drops a line that carries a value of a
# folder's .env (a resolved compose file and the services' logs are
# standard output, passed on and never kept). Docker runs as this
# script's child, in the process group cyfr kills to end a call.
echo "$*" >>/tmp/docker-calls
echo "$(date -u +%H:%M:%S.%3N) $*" >>/tmp/docker-times
ended() { printf '%s\n' "$(date -u +%H:%M:%S.%3N) exit $1 $2" >>/tmp/docker-times; }
case " $* " in
  *" pull "*) [ ! -e /tmp/pull-done ] || { ended 0 "$*"; exit 0; } # the passkey launch's: every image is here, from the first folder's start
    while [ ! -e /tmp/pull-go ]; do sleep 0.2; done; echo "released $*" >>/tmp/docker-calls; ended 1 "$*"; exit 1;;
  *" up "*) while [ ! -e /tmp/up-go ]; do sleep 0.2; done;;
esac
err=$(mktemp /tmp/docker-err.XXXXXX)
{ /usr/bin/docker "$@" 2>&1 1>&3 3>&- | tee "$err" >&2 3>&-; } 3>&1
rc=${PIPESTATUS[0]}
if [ "$rc" = 0 ]; then
  ended 0 "$*"
else
  printf '%s\n%s\n' "$(date -u +%H:%M:%S.%3N) exit $rc $*" "$(tail -n 40 "$err" | sed 's/^/    /')" >>/tmp/docker-times
fi
rm -f "$err"
exit "$rc"
WRAP
# --init: a process that ends in the client is reaped, so what is left of
# setup's work is what still runs.
# The client is removed by the id its create returned: a create that failed,
# a name taken by another among them, made nothing of this run's.
CLIENT_ID=$(docker run -d --init --name "$CLIENT" --network host --security-opt seccomp=unconfined -v "$W:$W" \
  -v "$DEB:/deb/app.deb:ro" -v /var/run/docker.sock:/hostrun/docker.sock ubuntu:26.04 sleep infinity) ||
  failed "the client $CLIENT could not be made (docker run failed): nothing of this run's was made in its name"
docker exec "$CLIENT_ID" bash -c "set -e; export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends /deb/app.deb xvfb xauth dbus-x11 docker.io docker-compose-v2 util-linux-extra ca-certificates >/dev/null 2>&1
getent group docker >/dev/null || groupadd docker
groupmod -o -g $GID docker
other=\$(getent passwd $(id -u) | cut -d: -f1); [ -z \"\$other\" ] || userdel \"\$other\"
useradd -m -u $(id -u) proof; usermod -aG docker proof
install -m 0644 $W/fixture/proof.asar /opt/cyfr/resources/app.asar
mkdir -p /opt/wrap
install -m 755 $W/fixture/wrap-docker /opt/wrap/docker
: >/tmp/docker-calls; : >/tmp/docker-times; chmod 666 /tmp/docker-calls /tmp/docker-times"
PG=$(docker exec "$CLIENT_ID" id -g proof)
echo "client: $(docker exec "$CLIENT_ID" sh -c '. /etc/os-release; echo $PRETTY_NAME'), the app's account in the docker group ($GID), its process launched without it"

mkfifo "$W/fixture/app-output"
# The proof's asks, answered as the host: the socket given.
answer() {
  while :; do
    if [ -e "$W/fixture/asked-give-docker" ] && [ ! -e "$W/fixture/done-give-docker" ]; then
      docker exec "$CLIENT_ID" ln -sf /hostrun/docker.sock /var/run/docker.sock
      : >"$W/fixture/done-give-docker"
    fi
    sleep 0.2 # sleep-ok: polls the proof's asks
  done
}
answer & ANSWERER=$!
# What is left of setup's work, read within $1 seconds: the client's
# processes whose command line names setup-project and that still run (not
# a zombie), counted from /proc; the counting shell skips itself, since its
# own command line names what it counts.
work_left() { timeout "$1" docker exec "$CLIENT_ID" sh -c 'n=0; for p in /proc/[0-9]*; do [ "${p#/proc/}" = "$$" ] && continue
  read -r s <$p/stat 2>/dev/null || continue; s=${s##*) }; [ "${s%% *}" = Z ] && continue
  case "$(tr "\0" " " <$p/cmdline 2>/dev/null)" in *setup-project*) n=$((n+1));; esac; done; echo $n'; }
# The stack's containers there, read within $1 seconds.
stack_left() { (cd "$D" && timeout "$1" docker compose --project-name "$RUN" --project-directory "$D" -f docker-compose.yml -f docker-compose.override.yml ps -aq) | wc -l; }
# The setup token of each folder set up so far, which the one scrub
# withholds from all the run writes (tests/desktop-proof/scrub.mjs), the
# app's output too: added before each launch, and by the passkey launch's
# proof as soon as it reads its folder's.
withhold() {
  local e
  for e in "$W"/*/.env; do [ ! -f "$e" ] || sed -n 's/^CYFR_SETUP_TOKEN=//p' "$e"; done >>"$W/fixture/withheld"
}
# One launch, one verdict: it failed if the app's exit status is not 0, past
# its 600 s limit among them, if its output is still open 15 s after it
# ended, if its log's scrub failed, or if it did not write that it passed,
# whatever it printed first. The 15 s are counted once, from the app's
# exit as observed here; for the first launch they are the quit row's, in
# which setup's work and the stack must be gone too. An observation counts
# only if it was finished before that deadline: OPEN, LEFT and RUNNING start
# unread, each pass bounds its readings by the time left, and a pass that
# ends past the deadline changes nothing.
launch() {
  withhold
  CYFR_PROOF_WITHHELD="$W/fixture/withheld" node "$ROOT/tests/desktop-proof/scrub-lines.mjs" <"$W/fixture/app-output" >"$OUT/app-$1.log" &
  local scrub=$! status=0
  SCRUBS="${SCRUBS:-} $scrub"
  timeout 600 docker exec -u "$(id -u):$PG" -w /home/proof -e HOME=/home/proof "$CLIENT_ID" bash -c "
    exec 9>$W/fixture/app-output
    dbus-run-session -- xvfb-run -a -s '-screen 0 1400x1000x24' bash -c 'exec env -i HOME=/home/proof USER=proof LOGNAME=proof PATH=/opt/wrap:/usr/bin:/bin LANG=C.UTF-8 DISPLAY=\$DISPLAY XAUTHORITY=\$XAUTHORITY DBUS_SESSION_BUS_ADDRESS=\$DBUS_SESSION_BUS_ADDRESS CYFR_DESKTOP_PROOF_FIXTURE=$W/fixture CYFR_DESKTOP_PROOF_PHASE=$1 CYFR_PROOF_WITHHELD=$W/fixture/withheld /opt/cyfr/CYFR' >&9 2>&1" || status=$?
  local deadline=$(( $(date +%s%N) + 15000000000 ))
  grep -E "^(PASS|FAIL)" "$W/fixture/out/setup.txt" 2>/dev/null | sed -n "$(( ${2:-0} + 1 )),\$p" || true
  [ "$status" = 0 ] || failed "$1: the app ended with status $status$( [ "$status" != 124 ] || echo ", at its 600 s limit")"
  # A process the app left running holds its output's write end.
  OPEN=unread LEFT=unread RUNNING=unread
  local now bound o l r
  while now=$(date +%s%N); [ "$now" -lt "$deadline" ]; do
    # In ms, at least 1: timeout reads a bound of 0 as none.
    bound=$(( (deadline - now) / 1000000 )); [ "$bound" -ge 1 ] || bound=1
    bound=$(printf '%d.%03d' $(( bound / 1000 )) $(( bound % 1000 )))
    o=0; kill -0 "$scrub" 2>/dev/null && o=1
    l=0 r=0
    if [ "$1" = first ]; then
      l=$(work_left "$bound" 2>/dev/null) || l=
      r=$(stack_left "$bound" 2>/dev/null) || r=
    fi
    [ "$(date +%s%N)" -lt "$deadline" ] || break
    OPEN=$o; [ -z "$l" ] || LEFT=$l; [ -z "$r" ] || RUNNING=$r
    [ "$OPEN$LEFT$RUNNING" = 000 ] && break
    sleep 0.2 # sleep-ok: polls up to the one deadline, 15 s from the app's exit
  done
  if [ "$OPEN" = 0 ]; then
    wait "$scrub" || failed "$1: the app's log could not be scrubbed clean (scrub-lines ended $?)"
  elif [ "$1" != first ]; then
    failed "$1: 15 s after the app ended, its output was still held open"
  fi
  grep -qx "RESULT $1 passed" "$W/fixture/out/setup.txt" || failed "$1: the launch did not pass"
}
launch first
kill "$ANSWERER" 2>/dev/null || true
[ "$LEFT" = 0 ] && [ "$OPEN" = 0 ] && [ "$RUNNING" = 0 ] && [ -f "$D/.env" ] ||
  failed "quit: 15 s after the app's end, as last read in time: setup's work's processes $LEFT, the app's output $(case $OPEN in 0) echo closed;; 1) echo "still held open";; *) echo unread;; esac), the stack's containers $RUNNING, .env $( [ -f "$D/.env" ] && echo written || echo missing) (unread: not read within the 15 s)"
# The held pull released: the work, gone, takes nothing further.
calls=$(docker exec "$CLIENT_ID" cat /tmp/docker-calls | wc -l)
docker exec "$CLIENT_ID" touch /tmp/pull-go
sleep 10 # sleep-ok: the window in which a work still there would go on past its pull
log=$(docker exec "$CLIENT_ID" cat /tmp/docker-calls)
after=$(printf '%s\n' "$log" | tail -n +"$((calls + 1))" | grep -c . || true)
last=$(printf '%s\n' "$log" | grep -v '^released ' | tail -1)
running=$(compose ps -aq 2>/dev/null | wc -l)
case "$last" in *" pull "*|"pull "*) ;; *) failed "quit: setup's last docker call was not its pull: $last" ;; esac
[ "$after" = 0 ] && [ "$running" = 0 ] ||
  failed "quit: once the held pull was released, $after docker calls followed and $running containers of the stack were there"
echo "PASS quit: the person quit during the download: 15 s after the app's end nothing of setup's work runs and nothing of the stack, .env is written, and the held pull, released, is taken by nothing"
launch again "$(grep -cE "^(PASS|FAIL)" "$W/fixture/out/setup.txt")"
# The passkey road, as on macOS and Windows, on a second folder seeded as
# the first: the first CYFR taken down, its own port and Compose project.
compose down -v --remove-orphans >/dev/null 2>&1 || failed "first_passkey: the first folder's CYFR could not be taken down"
PORT2=$(free_port); ADDR2="http://localhost:$PORT2"; RUN2="$RUN-2"; D2="$W/$RUN2"
mkdir -p "$D2"; PROJECTS="$PROJECTS $RUN2:$D2"
seed "$D2" "$PORT2"
inputs "$ADDR2" "$D2"
docker exec "$CLIENT_ID" touch /tmp/pull-done
launch passkey "$(grep -cE "^(PASS|FAIL)" "$W/fixture/out/setup.txt")"
# first_passkey, once the app has quit: what the person saw (the launch's
# part), then the setup token nowhere it must not be. It spends itself when
# the first person is made; until then it is in the folder's .env, the
# setup page's own address (the engine's own record of a request keeps
# that address too) and the message that page sends its own CYFR over its
# socket: in no request line or header the app sent, a referrer among them
# (the record names the setup page's own request), no line the app or the
# proof printed (the part's), nothing the run keeps for upload (the one
# scrub withholds it), and no file of the app's account here, its profile
# included, nor of /tmp but this run's own scratch, wherever TMPDIR puts it.
TOKEN=$(cat "$W/fixture/setup-token" 2>/dev/null) || failed "first_passkey: the passkey launch read no setup token"
part=$(cat "$W/fixture/first-passkey.json" 2>/dev/null || echo '{"ok": false, "threw": "no part written"}')
# What the engine sent: each request line and its headers, as the network
# service's record has them; the setup page's own request among them.
read -r requests recorded < <(python3 -I - "$TOKEN" "$W"/fixture/netlog-*.json <<'PY' || echo "unread unread"
import json, sys
token, carrying, setup = sys.argv[1], 0, 0
for f in sys.argv[2:]:
    d = json.load(open(f))
    types = {v: k for k, v in d["constants"]["logEventTypes"].items()}
    for ev in d["events"]:
        t = types.get(ev["type"], "")
        if "SEND" in t and "HEADERS" in t:
            sent = json.dumps(ev.get("params", {}))
            carrying += token in sent
            setup += '"GET /setup HTTP/1.1' in sent
print(carrying, setup)
PY
)
kept=$( { grep -rlaF -f "$W/fixture/withheld" "$OUT" "$W/fixture/out" 2>/dev/null || true; } | wc -l)
files=$(timeout 120 docker exec "$CLIENT_ID" sh -c "find /home/proof /tmp -path '$W' -prune -o -type f -print0 2>/dev/null |
  xargs -0 -r grep -laF -- '$TOKEN' 2>/dev/null; true")
profile=$(timeout 60 docker exec "$CLIENT_ID" sh -c 'find /home/proof/.config -mindepth 1 2>/dev/null | wc -l')
if python3 -I -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get("ok") is True else 1)' "$part" &&
  [ "$requests" = 0 ] && [ "$recorded" -gt 0 ] && [ "$kept" = 0 ] && [ -z "$files" ] && [ "$profile" -gt 0 ]; then
  echo "PASS first_passkey: on the passkey road the CYFR set up opens at its setup page, whose Create your account makes the account with a passkey in the account window, and that account is its first person, in Prism, live; its setup token is in no address or header sent, no printed line, nothing the run keeps and no file of the app's"
else
  failed "first_passkey: $part; requests sent carrying the token $requests (of them, $recorded the setup page's own), files the run keeps carrying a setup token $kept, files of the app's account or /tmp: ${files:-none} (its profile holds $profile entries)"
fi
