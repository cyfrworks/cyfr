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
# does between its steps. Two launches:
#
#   first   missing_to_ready  with no Docker socket the setup screen says
#                             Docker does not answer and shows the commands;
#                             the socket given, Check again in the same
#                             window answers again
#           stale             that answer: Docker answers and Set up and
#                             start is offered, though the app's process
#                             lacks the docker group
#           downloading       Set up and start shows its steps up to the
#                             download, which this script holds
#           quit (here)       the person quits during the download: within
#                             15 s of the app's end nothing of setup's work
#                             runs and nothing of the stack, and .env is
#                             written; the held pull then released, no
#                             docker call follows it and nothing starts.
#                             The work is counted from /proc, zombies aside,
#                             by a shell that skips itself: its own command
#                             line names setup-project, which once counted
#                             it as setup's work
#   again   reshown           the chooser's renderer lost mid-run and shown
#                             again shows the progress, and once it is done
#                             offers Open CYFR, opening nothing by itself
#           partial           the folder's setup goes on from what is
#                             there: its one step is the start, .env as it
#                             was
#           first_person      Open CYFR opens the device's pages, and the
#                             first person's setup ends in Prism, live
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
# SETUP_PROOF_OUT (default: the run's scratch directory). The client, the
# stack and the scratch directory are removed when the run ends, whether it
# passes or fails. Locally it binds 127.0.0.1:7340 on the host's network:
# run it inside flock /var/tmp/cyfr/port-7340.lock.
set -euo pipefail
DEB=$(realpath "${1:?usage: app.sh DEB IMAGE}")
IMAGE=${2:?usage: app.sh DEB IMAGE}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-setup-app.XXXXXX")
OUT=${SETUP_PROOF_OUT:-$W/out}
RUN="${PROOF_RUN_PREFIX:-}cyfr-setup-app-$$"; D="$W/$RUN"; CLIENT="$RUN-client"
mkdir -p "$W/fixture/out" "$D" "$OUT"
compose() { (cd "$D" && docker compose --project-name "$RUN" --project-directory "$D" -f docker-compose.yml -f docker-compose.override.yml "$@"); }
cleanup() {
  code=$?; trap - EXIT
  # The answerer holds this script's output open: a run that fails before
  # it is stopped would otherwise never end for whoever reads that output.
  [ -z "${ANSWERER:-}" ] || kill "$ANSWERER" 2>/dev/null || true
  docker rm -f "$CLIENT" >/dev/null 2>&1 || true
  for s in ${SCRUBS:-}; do kill "$s" 2>/dev/null || true; done
  [ ! -f "$D/.env" ] || compose down -v --remove-orphans >/dev/null 2>&1 || true
  cp "$W"/fixture/out/* "$OUT/" 2>/dev/null || true
  # The stack's own files are root's: they are removed as root.
  docker run --rm --network none -v "$W:/w" ubuntu:24.04 find /w -mindepth 1 -not -path "/w/out*" -delete >/dev/null 2>&1 || true
  [ -n "${SETUP_PROOF_OUT:-}" ] && rm -rf "$W" || true
  echo "setup app proof: exit $code"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
failed() { echo "FAIL $1"; exit 1; }

# The folder as a release's download leaves it, but for the loaded image
# and no Locus: the candidate is a dev build, which downloads nothing.
PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
ADDR="http://localhost:$PORT"
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

GID=$(stat -c %g /var/run/docker.sock)
printf '{"home": "%s", "directory": "%s", "fronts": {}, "folder": "%s", "docker_gid": %s}\n' "$ADDR" "$ADDR" "$D" "$GID" >"$W/fixture/inputs.json"
node "$ROOT/tests/desktop-proof/pack.mjs" "$ROOT/tests/setup-proof/app/proof.js" "$W/fixture/proof.asar"

# The socket is mounted beside its place, which is empty until the proof
# asks for Docker. The docker the app finds holds a pull until released.
cat >"$W/fixture/wrap-docker" <<'WRAP'
#!/bin/sh
# Each call is logged; a pull is held until /tmp/pull-go, and says so if it
# is released rather than ended.
echo "$*" >>/tmp/docker-calls
case " $* " in *" pull "*) while [ ! -e /tmp/pull-go ]; do sleep 0.2; done; echo "released $*" >>/tmp/docker-calls; exit 1;; esac
exec /usr/bin/docker "$@"
WRAP
# --init: a process that ends in the client is reaped, so what is left of
# setup's work is what still runs.
docker run -d --init --name "$CLIENT" --network host --security-opt seccomp=unconfined -v "$W:$W" \
  -v "$DEB:/deb/app.deb:ro" -v /var/run/docker.sock:/hostrun/docker.sock ubuntu:26.04 sleep infinity >/dev/null
docker exec "$CLIENT" bash -c "set -e; export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends /deb/app.deb xvfb xauth dbus-x11 docker.io docker-compose-v2 util-linux-extra ca-certificates >/dev/null 2>&1
getent group docker >/dev/null || groupadd docker
groupmod -o -g $GID docker
other=\$(getent passwd $(id -u) | cut -d: -f1); [ -z \"\$other\" ] || userdel \"\$other\"
useradd -m -u $(id -u) proof; usermod -aG docker proof
install -m 0644 $W/fixture/proof.asar /opt/cyfr/resources/app.asar
mkdir -p /opt/wrap
install -m 755 $W/fixture/wrap-docker /opt/wrap/docker
: >/tmp/docker-calls; chmod 666 /tmp/docker-calls"
PG=$(docker exec "$CLIENT" id -g proof)
echo "client: $(docker exec "$CLIENT" sh -c '. /etc/os-release; echo $PRETTY_NAME'), the app's account in the docker group ($GID), its process launched without it"

mkfifo "$W/fixture/app-output"
# The proof's asks, answered as the host: the socket given.
answer() {
  while :; do
    if [ -e "$W/fixture/asked-give-docker" ] && [ ! -e "$W/fixture/done-give-docker" ]; then
      docker exec "$CLIENT" ln -sf /hostrun/docker.sock /var/run/docker.sock
      : >"$W/fixture/done-give-docker"
    fi
    sleep 0.2 # sleep-ok: polls the proof's asks
  done
}
answer & ANSWERER=$!
launch() {
  node "$ROOT/tests/desktop-proof/scrub-lines.mjs" <"$W/fixture/app-output" >"$OUT/app-$1.log" &
  local scrub=$!
  timeout 600 docker exec -u "$(id -u):$PG" -w /home/proof -e HOME=/home/proof "$CLIENT" bash -c "
    exec 9>$W/fixture/app-output
    dbus-run-session -- xvfb-run -a -s '-screen 0 1400x1000x24' bash -c 'exec env -i HOME=/home/proof USER=proof LOGNAME=proof PATH=/opt/wrap:/usr/bin:/bin LANG=C.UTF-8 DISPLAY=\$DISPLAY XAUTHORITY=\$XAUTHORITY DBUS_SESSION_BUS_ADDRESS=\$DBUS_SESSION_BUS_ADDRESS CYFR_DESKTOP_PROOF_FIXTURE=$W/fixture CYFR_DESKTOP_PROOF_PHASE=$1 /opt/cyfr/CYFR' >&9 2>&1" || echo "app exit $?"
  # A process the app left running still holds the output's write end, so
  # its reader is waited for with a bound and left reading after it: the
  # quit row then counts what is left, and cleanup ends the reader.
  for _ in $(seq 75); do kill -0 "$scrub" 2>/dev/null || break; sleep 0.2; done # sleep-ok: bounded wait (15 s) for the app's output to end
  kill -0 "$scrub" 2>/dev/null && SCRUBS="${SCRUBS:-} $scrub" || wait "$scrub" || true
  grep -E "^(PASS|FAIL)" "$W/fixture/out/setup.txt" | sed -n "$(( ${2:-0} + 1 )),\$p" || true
  grep -qx "RESULT $1 passed" "$W/fixture/out/setup.txt" || failed "$1: the launch did not pass"
}
launch first
kill "$ANSWERER" 2>/dev/null || true
# What is left of setup's work: the client's processes whose command line
# names setup-project and that still run (not a zombie), counted from /proc;
# the counting shell skips itself, since its own command line names what it
# counts.
work_left() { docker exec "$CLIENT" sh -c 'n=0; for p in /proc/[0-9]*; do [ "${p#/proc/}" = "$$" ] && continue
  read -r s <$p/stat 2>/dev/null || continue; s=${s##*) }; [ "${s%% *}" = Z ] && continue
  case "$(tr "\0" " " <$p/cmdline 2>/dev/null)" in *setup-project*) n=$((n+1));; esac; done; echo $n'; }
for _ in $(seq 75); do [ "$(work_left)" = 0 ] && break; sleep 0.2; done # sleep-ok: bounded wait (15 s) for setup's work to end
left=$(work_left); running=$(compose ps -aq 2>/dev/null | wc -l)
[ "$left" = 0 ] && [ "$running" = 0 ] && [ -f "$D/.env" ] ||
  failed "quit: within 15 s of the app's end, $left processes of setup's work and $running containers of the stack were there, .env $( [ -f "$D/.env" ] && echo written || echo missing)"
# The held pull released: the work, gone, takes nothing further.
calls=$(docker exec "$CLIENT" cat /tmp/docker-calls | wc -l)
docker exec "$CLIENT" touch /tmp/pull-go
sleep 10 # sleep-ok: the window in which a work still there would go on past its pull
log=$(docker exec "$CLIENT" cat /tmp/docker-calls)
after=$(printf '%s\n' "$log" | tail -n +"$((calls + 1))" | grep -c . || true)
last=$(printf '%s\n' "$log" | grep -v '^released ' | tail -1)
running=$(compose ps -aq 2>/dev/null | wc -l)
case "$last" in *" pull "*|"pull "*) ;; *) failed "quit: setup's last docker call was not its pull: $last" ;; esac
[ "$after" = 0 ] && [ "$running" = 0 ] ||
  failed "quit: once the held pull was released, $after docker calls followed and $running containers of the stack were there"
echo "PASS quit: the person quit during the download: within 15 s nothing of setup's work runs and nothing of the stack, .env is written, and the held pull, released, is taken by nothing"
launch again "$(grep -cE "^(PASS|FAIL)" "$W/fixture/out/setup.txt")"
