#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The installed CYFR app's update from release A to release B by its own
# cyfr, as a person runs `cyfr update`, on Linux (the DEB through apt, by
# the app's update service as root), macOS (the bundle in /Applications) and Windows (the MSI, for
# this account). Its cyfr is built with the releaseproof tag
# (apps/codex/cmd/release_proof.go), so the releases are read from a
# folder: each release's installer by its release name and its
# checksums.txt, unsigned. In two parts:
#
#   build DIR ARCH   cyfr and the app's package for A, B and U, U's
#                    checksums naming another sum than its installer's,
#                    into DIR (Go and the app's packages installed)
#   run DIR          A installed and opened, then the checks below
#
# Each check of `run` prints one PASS or FAIL line, and one FAIL fails it:
#
#   installed    A's package installs as a person installs it, and the
#                app's own cyfr answers A
#   opened       the app at A opens: the chooser answers on 127.0.0.1:7340
#   unverified   cyfr update --version U refuses, saying the app did not
#                verify, before anything closes: the same app still runs,
#                and its cyfr answers A; on Linux the update service's
#                refusal, said once, with no sudo run
#   update       cyfr update --version B, by the app's own cyfr in a folder
#                that holds no CYFR, ends 0 saying the app is release B; on
#                Linux through the app's update service, with a sudo on
#                PATH that records any run and runs nothing: none is run
#   answers      the app's own cyfr answers B
#   reopened     the app the update closed is gone and the app opens
#                again: a new process, whose chooser answers
#
# and on Linux, of the app's update service
# (apps/codex/cmd/app_service_linux.go):
#
#   service      A's package enabled its socket, root's and the sudo
#                group's alone
#   forward      asked straight at its socket for B (the release installed)
#                and for A (an older one), the service refuses each
#   outsider     an account outside the sudo group is refused at the socket,
#                and its cyfr update says so and takes the sudo road
#   bound        A back, an install of B hung past the request's bound
#                with the screen (a stand-in unit) stopped: the request
#                ends with no answer and the screen runs again
#   held         a request for B verified and held open while the package
#                is removed, then told go: nothing is installed
#   removed      the package removed, its socket, units and requests are
#                gone
#
# It installs software and leaves the app installed, so `run` refuses
# anywhere but a disposable machine: GitHub's own runner
# (GITHUB_ACTIONS=true, RUNNER_ENVIRONMENT=github-hosted) or a container
# (/.dockerenv). There the account administers the machine with sudo and no
# password (Linux), and 127.0.0.1:7340 is free. On Linux it needs systemd,
# a display and a session bus (dbus-run-session -- xvfb-run -a), curl,
# python3 and the package's dependencies, and DIR outside /home, /root,
# /tmp and /var/tmp: the service reads the releases there as root, and its
# unit sees none of those.
#
# Usage: bash tests/desktop-proof/native/update.sh build DIR amd64|arm64
#        bash tests/desktop-proof/native/update.sh run DIR
set -uo pipefail

A=0.0.1-proof B=0.0.2-proof U=0.0.3-proof
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
case "$(uname -s)" in
  Linux) OS=linux EXT=deb ;;
  Darwin) OS=darwin EXT=dmg ;;
  MINGW* | MSYS* | CYGWIN*) OS=windows EXT=msi ;;
  *) echo "update: $(uname -s) is not a platform the app ships for" >&2; exit 64 ;;
esac
EXE=
[ "$OS" != windows ] || EXE=.exe
# The path Go and the system's tools read: on Windows its own form.
native() { if [ "$OS" = windows ]; then cygpath -w "$1"; else echo "$1"; fi; }

# A checksums.txt line for FILE, as the release writes it.
sum() {
  if [ "$OS" = darwin ]; then shasum -a 256 "$1"; else sha256sum "$1" | tr -d '*'; fi
}

# The app in the Mac disk image DMG signed ad hoc where it is not signed at
# all: cyfr update installs only an app whose signature verifies, with the
# installed app's team (apps/codex/cmd/app_road_darwin.go sameSigner). A
# build with no identity is signed ad hoc on Apple silicon, as Electron's
# arm64 engine is, and not at all on Intel.
signed_ad_hoc() {
  local dmg=$1 work
  work=$(mktemp -d)
  mkdir "$work/mnt" "$work/stage"
  hdiutil attach -nobrowse -readonly -mountpoint "$work/mnt" "$dmg" >/dev/null
  cp -R "$work/mnt/CYFR.app" "$work/stage/"
  hdiutil detach "$work/mnt" >/dev/null
  if ! codesign --verify "$work/stage/CYFR.app" 2>/dev/null; then
    codesign --force --deep --sign - "$work/stage/CYFR.app"
    rm "$dmg"
    hdiutil create -quiet -volname CYFR -srcfolder "$work/stage" -format UDZO "$dmg"
  fi
  rm -rf "$work"
}

build() {
  local dir=$1 arch=$2 v
  set -e
  mkdir -p "$dir"
  dir=$(cd "$dir" && pwd)
  for v in $A $B; do
    mkdir -p "$dir/$v"
    (cd "$ROOT/apps/codex" && CGO_ENABLED=0 go build -mod=readonly -tags releaseproof \
      -ldflags "-X github.com/cyfr/codex/internal/version.Version=$v -X github.com/cyfr/codex/cmd.proofReleases=$(native "$dir")" \
      -o "$dir/cyfr-$v$EXE" .)
    (cd "$ROOT/apps/codex/desktop" && node scripts/build.mjs --cyfr "$dir/cyfr-$v$EXE" --version "$v" --arch "$arch" --out "$dir/build-$v")
    mv "$dir/build-$v/cyfr-desktop_${v}_${OS}_$arch.$EXT" "$dir/$v/"
    rm -rf "$dir/build-$v"
    [ "$OS" != darwin ] || signed_ad_hoc "$dir/$v/cyfr-desktop_${v}_${OS}_$arch.$EXT"
    (cd "$dir/$v" && sum "cyfr-desktop_${v}_${OS}_$arch.$EXT" >checksums.txt)
  done
  # U: B's installer under U's name, its checksums naming another sum.
  mkdir -p "$dir/$U"
  cp "$dir/$B/cyfr-desktop_${B}_${OS}_$arch.$EXT" "$dir/$U/cyfr-desktop_${U}_${OS}_$arch.$EXT"
  printf '%064d  cyfr-desktop_%s_%s_%s.%s\n' 0 "$U" "$OS" "$arch" "$EXT" >"$dir/$U/checksums.txt"
  echo "$arch" >"$dir/arch"
  echo "update: built $A, $B and $U in $dir"
}

FAILED=0 CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); echo "PASS $1: $2"; }
fail() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); echo "FAIL $1: $2"; }

# within SECONDS COMMAND...: polls COMMAND until it succeeds, 1 once
# SECONDS have passed.
within() {
  local until=$((SECONDS + $1))
  shift
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$until" ] || return 1
    sleep 0.5 # sleep-ok: the gap between two polls of an observable condition, bounded by SECONDS
  done
}
answers() { [ "$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:7340/bootstrap/)" = 200 ]; }

# The installed app's executable and its own cyfr, as cyfr reads them
# (apps/codex/cmd/installed_app_*.go).
case "$OS" in
  linux) APP=/opt/cyfr/CYFR CARRIED=/opt/cyfr/resources/cyfr ;;
  darwin) APP=/Applications/CYFR.app/Contents/MacOS/CYFR CARRIED=/Applications/CYFR.app/Contents/Resources/cyfr ;;
  windows)
    APP="$(cygpath -u "$LOCALAPPDATA")/Programs/cyfr-desktop/CYFR.exe"
    CARRIED="$(cygpath -u "$LOCALAPPDATA")/Programs/cyfr-desktop/resources/cyfr.exe" ;;
esac
release_of() { "$CARRIED" --version 2>/dev/null | sed -n '1s/^cyfr version //p' | tr -d '\r'; }

# The installed app's main processes, by the system's own ids: its
# executable with no engine --type, which its helpers carry.
app_pids() {
  if [ "$OS" = windows ]; then
    pwsh -NoProfile -NonInteractive -Command \
      "Get-CimInstance Win32_Process -Filter \"Name='CYFR.exe'\" | Where-Object { \$_.ExecutablePath -eq '$(cygpath -w "$APP")' -and \$_.CommandLine -notmatch '--type=' } | ForEach-Object { \$_.ProcessId }" | tr -d '\r'
  else
    pgrep -x -f "$APP"
  fi
}
first_pid() { app_pids | sort -n | head -1; }
running() { [ -n "$(app_pids)" ]; }
alive() { app_pids | grep -qx "$1"; }
not_alive() { ! alive "$1"; }

install_package() {
  case "$OS" in
    linux) sudo apt-get install -y --allow-downgrades "$1" ;;
    darwin)
      local mount
      mount=$(mktemp -d)
      hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$1" &&
        rm -rf /Applications/CYFR.app && cp -R "$mount/CYFR.app" /Applications/ &&
        hdiutil detach "$mount" ;;
    windows)
      pwsh -NoProfile -NonInteractive -Command \
        "\$p = Start-Process msiexec.exe -ArgumentList '/i', '\"$(cygpath -w "$1")\"', '/qn', '/norestart' -Wait -PassThru; exit \$p.ExitCode" ;;
  esac
}

# Every app this account runs asked to end, as cyfr update asks.
quit_all() {
  [ -x "$APP" ] || return 0
  for _ in $(seq 1 80); do
    "$APP" --quit >/dev/null 2>&1 && return 0
    sleep 0.25 # sleep-ok: the pace cyfr update asks a running app at (askAppToQuit)
  done
  return 1
}

run() {
  local dir arch out status before='' after
  if ! dir=$(cd "$1" && pwd) || ! arch=$(cat "$dir/arch"); then
    echo "update: $1 holds no releases built by this script" >&2
    exit 64
  fi
  if ! { [ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ]; } && [ ! -e /.dockerenv ]; then
    echo "update: run installs the CYFR app and leaves it installed: it runs on GitHub's own runners or in a container alone" >&2
    exit 64
  fi
  # cyfr runs root's commands for an account of the sudo or admin group
  # alone (apps/codex/cmd/prerequisites.go mayAdminister), as the system's
  # group list says, and with no terminal only where sudo -v asks for no
  # password, which sudo-rs asks while any rule that matches the account
  # does: on this disposable machine the sudo group's own rule asks none.
  # The update service's socket is the sudo group's: the account joins it,
  # and the run goes on in that group, as a person's session in it does.
  if [ "$OS" = linux ] && ! id -nG "$(id -un)" | tr ' ' '\n' | grep -qx sudo; then
    sudo usermod -aG sudo "$(id -un)" || { echo "update: this account could not join the sudo group" >&2; exit 1; }
    sudo sed -i 's/^%sudo\(\s\+\)ALL=(ALL:ALL) ALL$/%sudo\1ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers && sudo visudo -c >/dev/null
  fi
  if [ "$OS" = linux ] && ! id -nG | tr ' ' '\n' | grep -qx sudo; then
    command -v sg >/dev/null || sudo apt-get install -y util-linux-extra >/dev/null
    exec sg sudo -c "$(printf '%q ' bash "${BASH_SOURCE[0]}" run "$dir")"
  fi
  if [ "$OS" = linux ] && ! sudo -n -v 2>/dev/null; then
    echo "update: sudo -v asks this account for a password, so cyfr update would refuse with no terminal" >&2
    exit 1
  fi
  if [ "$OS" = linux ] && [[ "$dir" =~ ^/(home|root|tmp|var/tmp)(/|$) ]]; then
    echo "update: $dir is where the update service's unit sees nothing: build the releases elsewhere" >&2
    exit 64
  fi
  LOGS=$(mktemp -d)
  trap 'quit_all; rm -rf "$LOGS"' EXIT
  # A sudo that records each run and runs nothing, first on PATH where an
  # update must not reach sudo.
  mkdir -p "$LOGS/nosudo"
  printf '#!/bin/sh\necho "$*" >>%q\nexit 1\n' "$LOGS/sudo-runs" >"$LOGS/nosudo/sudo"
  chmod 755 "$LOGS/nosudo/sudo"

  quit_all
  if install_package "$dir/$A/cyfr-desktop_${A}_${OS}_$arch.$EXT" >"$LOGS/install.log" 2>&1 && [ "$(release_of)" = "$A" ]; then
    pass installed "the app's own cyfr answers $A"
  else
    fail installed "the app's own cyfr answers '$(release_of)', not $A: $(tail -5 "$LOGS/install.log")"
    echo "update: $CHECKS checks, $FAILED failed"
    exit 1
  fi

  if [ "$OS" = linux ]; then
    if systemctl is-active --quiet cyfr-update.socket && [ "$(stat -c '%U:%G %a' /run/cyfr-update.sock 2>&1)" = "root:sudo 660" ]; then
      pass service "the update service's socket listens, root:sudo 660"
    else
      fail service "the socket is $(systemctl is-active cyfr-update.socket), $(stat -c '%U:%G %a' /run/cyfr-update.sock 2>&1)"
    fi
  fi

  "$APP" >"$LOGS/app-a.log" 2>&1 &
  if within 60 answers && within 10 running; then
    before=$(first_pid)
    pass opened "the app at $A runs ($before) and its chooser answers"
  else
    fail opened "the app at $A did not open within 60 s: $(tail -5 "$LOGS/app-a.log")"
  fi

  # In a folder of its own that holds no CYFR, so the update stops after
  # the program.
  mkdir -p "$LOGS/empty"
  if [ "$OS" = linux ]; then
    out=$(cd "$LOGS/empty" && PATH="$LOGS/nosudo:$PATH" "$CARRIED" update --version "$U" --yes 2>&1)
  else
    out=$(cd "$LOGS/empty" && "$CARRIED" update --version "$U" --yes 2>&1)
  fi
  status=$?
  if [ "$status" != 0 ] && [ "$(grep -cF "The CYFR app of release $U did not verify" <<<"$out")" = 1 ] &&
    { [ "$OS" != linux ] || { grep -qF "Asking CYFR's update service" <<<"$out" && [ ! -s "$LOGS/sudo-runs" ]; }; } &&
    alive "$before" && answers && [ "$(release_of)" = "$A" ]; then
    pass unverified "refused, the app at $A still running and answering"
  else
    fail unverified "exit $status, the app $(alive "$before" && echo still || echo no longer) runs, its cyfr answers '$(release_of)': $out"
  fi

  if [ "$OS" = linux ]; then
    out=$(cd "$LOGS/empty" && PATH="$LOGS/nosudo:$PATH" "$CARRIED" update --version "$B" --yes 2>&1)
  else
    out=$(cd "$LOGS/empty" && "$CARRIED" update --version "$B" --yes 2>&1)
  fi
  status=$?
  if [ "$status" = 0 ] && grep -qF "The CYFR app is release $B." <<<"$out" &&
    { [ "$OS" != linux ] || { grep -qF "Asking CYFR's update service" <<<"$out" && [ ! -s "$LOGS/sudo-runs" ]; }; }; then
    pass update "exit 0, the app is release $B"
  else
    fail update "exit $status, sudo run as '$(cat "$LOGS/sudo-runs" 2>/dev/null)': $out"
  fi

  if [ "$(release_of)" = "$B" ]; then
    pass answers "the app's own cyfr answers $B"
  else
    fail answers "the app's own cyfr answers '$(release_of)', not $B"
  fi

  if [ -n "$before" ] && within 30 not_alive "$before" && within 60 running && within 60 answers; then
    after=$(first_pid)
    pass reopened "the app the update closed ($before) is gone, and the app runs again ($after), its chooser answering"
  else
    fail reopened "the app the update closed ($before) $(alive "$before" && echo 'still runs' || echo 'is gone'), and $(running && echo 'one runs' || echo 'none runs') whose chooser $(answers && echo answers || echo 'does not answer')"
  fi

  [ "$OS" != linux ] || service_checks

  echo "update: $CHECKS checks, $FAILED failed"
  [ "$FAILED" = 0 ]
}

# ask ACCOUNT LINE: LINE sent straight to the update service's socket as
# ACCOUNT, printing the service's first answer, or the connection's
# refusal. systemd drops a connection made while the request before it
# still ends (MaxConnections=1): one dropped is made again, within 10 s.
ask() {
  sudo -u "$1" python3 -I -c '
import socket, sys, time
until = time.monotonic() + 10
while True:
    s = socket.socket(socket.AF_UNIX)
    try:
        s.connect("/run/cyfr-update.sock")
    except OSError as e:
        print("refused at the socket:", e.strerror); sys.exit()
    try:
        s.sendall(sys.argv[1].encode() + b"\n")
        for line in s.makefile(errors="replace"):
            if line.startswith("\x1e"):
                print(line[1:].strip()); sys.exit()
    except OSError:
        pass
    s.close()
    if time.monotonic() > until:
        print("no answer"); sys.exit()
    time.sleep(0.25)  # sleep-ok: the request before it ending, bounded by until
' "$2"
}

service_checks() {
  local said outsider=cyfr-proof-outsider
  said="$(ask "$(id -un)" "$B") / $(ask "$(id -un)" "$A")"
  if [ "$said" = "refused CYFR's update service installs only a release newer than the installed CYFR app's $B, and $B is not; nothing was changed / refused CYFR's update service installs only a release newer than the installed CYFR app's $B, and $A is not; nothing was changed" ]; then
    pass forward "the same release and an older one refused"
  else
    fail forward "the service answered: $said"
  fi

  id "$outsider" >/dev/null 2>&1 || sudo useradd -M -s /usr/sbin/nologin "$outsider"
  mkdir -p "$LOGS/outsider" && chmod 755 "$LOGS" "$LOGS/outsider"
  said=$(ask "$outsider" "$U")
  out=$(cd "$LOGS/outsider" && sudo -u "$outsider" env HOME="$LOGS/outsider" "$CARRIED" update --version "$U" --yes 2>&1)
  status=$?
  if [ "$said" = "refused at the socket: Permission denied" ] && [ "$status" != 0 ] &&
    grep -qF "CYFR's update service serves the sudo group's accounts alone, so the update goes through sudo instead." <<<"$out" &&
    [ "$(release_of)" = "$B" ]; then
    pass outsider "refused at the socket; its update says so and takes the sudo road"
  else
    fail outsider "the socket answered '$said'; exit $status, the app's cyfr answers '$(release_of)': $out"
  fi

  # A back at release A, so B is a newer release the service takes.
  quit_all
  sudo apt-get install -y --allow-downgrades "$dir/$A/cyfr-desktop_${A}_${OS}_$arch.$EXT" >"$LOGS/back-to-a.log" 2>&1

  # An install that hangs (apt held in a hook before dpkg) on a machine
  # whose screen runs (a stand-in screen unit), under a bound of 20 s.
  sudo tee /etc/systemd/system/cyfr-screen.service >/dev/null <<<$'[Service]\nExecStart=/bin/sleep infinity'
  sudo mkdir -p /etc/systemd/system/cyfr-update@.service.d
  sudo tee /etc/systemd/system/cyfr-update@.service.d/proof-bound.conf >/dev/null <<<$'[Service]\nRuntimeMaxSec=20'
  sudo tee /etc/apt/apt.conf.d/99cyfr-proof-hang >/dev/null <<<'DPkg::Pre-Invoke {"sleep 300";};'
  sudo systemctl daemon-reload && sudo systemctl start cyfr-screen
  local screen_run
  screen_run=$(systemctl show --property InvocationID --value cyfr-screen)
  said=$(request "$(id -un)" "$B")
  if [ "$said" = "closed" ] && within 30 systemctl is-active --quiet cyfr-screen &&
    [ "$(systemctl show --property InvocationID --value cyfr-screen)" != "$screen_run" ] && [ "$(release_of)" = "$A" ]; then
    pass bound "the bound ended the hung install with no answer, and the screen it stopped runs again"
  else
    fail bound "the service answered '$said', the screen is $(systemctl is-active cyfr-screen), the app's cyfr answers '$(release_of)'"
  fi
  sudo rm -f /etc/apt/apt.conf.d/99cyfr-proof-hang /etc/systemd/system/cyfr-update@.service.d/proof-bound.conf
  sudo systemctl stop cyfr-screen && sudo rm -f /etc/systemd/system/cyfr-screen.service && sudo systemctl daemon-reload

  # A request verified, held open while the package is removed, then told
  # go.
  said=$(request "$(id -un)" "$B" "sudo apt-get remove -y cyfr-desktop")
  if [ "$said" != "installed $B" ] && ! dpkg-query --show --showformat '${Status}' cyfr-desktop 2>/dev/null | grep -qx 'install ok installed'; then
    pass held "a request held across the removal installed nothing ($said)"
  else
    fail held "the service answered '$said', and dpkg says '$(dpkg-query --show --showformat '${Status} ${Version}' cyfr-desktop 2>&1)'"
  fi

  if ! dpkg-query --show --showformat '${Status}' cyfr-desktop 2>/dev/null | grep -qx 'install ok installed' &&
    ! systemctl is-active --quiet cyfr-update.socket && [ ! -e /run/cyfr-update.sock ] &&
    ! systemctl cat cyfr-update.socket cyfr-update@.service >/dev/null 2>&1 && [ -z "$(systemctl list-units --no-legend 'cyfr-update@*')" ]; then
    pass removed "the socket, its units and every request went with the package"
  else
    fail removed "the socket is $(systemctl is-active cyfr-update.socket), $(ls -l /run/cyfr-update.sock 2>&1); requests: $(systemctl list-units --no-legend 'cyfr-update@*')"
  fi
}

# request ACCOUNT VERSION [COMMAND]: VERSION asked of the update service as
# ACCOUNT; once verified, COMMAND runs (as this account), then go is sent.
# It prints the service's last answer, or closed for a connection that
# ended without one, within 90 s.
request() {
  sudo -u "$1" python3 -I -c '
import socket, subprocess, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(90)
s.connect("/run/cyfr-update.sock")
s.sendall(sys.argv[1].encode() + b"\n")
answers = s.makefile("rb")
said = "closed"
try:
    for line in answers:
        if line.startswith(b"\x1e"):
            said = line[1:].decode().strip()
            break
    if said.startswith("verified"):
        if len(sys.argv) > 2:
            subprocess.run(sys.argv[2], shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        said = "closed"
        s.sendall(b"go\n")
        for line in answers:
            if line.startswith(b"\x1e"):
                said = line[1:].decode().strip()
                break
except OSError:
    pass
print(said)
' "$2" ${3:+"$3"}
}

case "${1:-}" in
  build) [ "$#" = 3 ] && [[ "$3" =~ ^(amd64|arm64)$ ]] || { echo "usage: bash $0 build DIR amd64|arm64" >&2; exit 64; }; build "$2" "$3" ;;
  run) [ "$#" = 2 ] && [ -d "$2" ] || { echo "usage: bash $0 run DIR" >&2; exit 64; }; run "$2" ;;
  *) echo "usage: bash $0 build DIR amd64|arm64 | run DIR" >&2; exit 64 ;;
esac
