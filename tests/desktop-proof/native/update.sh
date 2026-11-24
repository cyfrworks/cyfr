#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The installed CYFR app's update from release A to release B by its own
# cyfr, as a person runs `cyfr update`, on Linux (the DEB through apt and
# sudo), macOS (the bundle in /Applications) and Windows (the MSI, for
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
#                and its cyfr answers A
#   update       cyfr update --version B, by the app's own cyfr in a folder
#                that holds no CYFR, ends 0 saying the app is release B
#   answers      the app's own cyfr answers B
#   reopened     the app the update closed is gone and the app opens
#                again: a new process, whose chooser answers
#
# It installs software and leaves the app installed, so `run` refuses
# anywhere but a disposable machine: GitHub's own runner
# (GITHUB_ACTIONS=true, RUNNER_ENVIRONMENT=github-hosted) or a container
# (/.dockerenv). There the account administers the machine with sudo and no
# password (Linux), and 127.0.0.1:7340 is free. On Linux it needs a display
# and a session bus (dbus-run-session -- xvfb-run -a), curl and the
# package's dependencies.
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
  local dir arch out status before= after
  dir=$(cd "$1" && pwd) && arch=$(cat "$dir/arch") || { echo "update: $1 holds no releases built by this script" >&2; exit 64; }
  if ! { [ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ]; } && [ ! -e /.dockerenv ]; then
    echo "update: run installs the CYFR app and leaves it installed: it runs on GitHub's own runners or in a container alone" >&2
    exit 64
  fi
  # cyfr runs root's commands for an account of the sudo or admin group
  # alone (apps/codex/cmd/prerequisites.go mayAdminister).
  if [ "$OS" = linux ] && ! id -nG | tr ' ' '\n' | grep -qxE 'sudo|admin'; then
    sudo usermod -aG sudo "$(id -un)" || { echo "update: this account could not join the sudo group" >&2; exit 1; }
  fi
  LOGS=$(mktemp -d)
  trap 'quit_all; rm -rf "$LOGS"' EXIT

  quit_all
  if install_package "$dir/$A/cyfr-desktop_${A}_${OS}_$arch.$EXT" >"$LOGS/install.log" 2>&1 && [ "$(release_of)" = "$A" ]; then
    pass installed "the app's own cyfr answers $A"
  else
    fail installed "the app's own cyfr answers '$(release_of)', not $A: $(tail -5 "$LOGS/install.log")"
    echo "update: $CHECKS checks, $FAILED failed"
    exit 1
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
  out=$(cd "$LOGS/empty" && "$CARRIED" update --version "$U" --yes 2>&1)
  status=$?
  if [ "$status" != 0 ] && grep -qF "The CYFR app of release $U did not verify" <<<"$out" &&
    alive "$before" && answers && [ "$(release_of)" = "$A" ]; then
    pass unverified "refused, the app at $A still running and answering"
  else
    fail unverified "exit $status, the app $(alive "$before" && echo still || echo no longer) runs, its cyfr answers '$(release_of)': $out"
  fi

  out=$(cd "$LOGS/empty" && "$CARRIED" update --version "$B" --yes 2>&1)
  status=$?
  if [ "$status" = 0 ] && grep -qF "The CYFR app is release $B." <<<"$out"; then
    pass update "exit 0, the app is release $B"
  else
    fail update "exit $status: $out"
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

  echo "update: $CHECKS checks, $FAILED failed"
  [ "$FAILED" = 0 ]
}

case "${1:-}" in
  build) [ "$#" = 3 ] && [[ "$3" =~ ^(amd64|arm64)$ ]] || { echo "usage: bash $0 build DIR amd64|arm64" >&2; exit 64; }; build "$2" "$3" ;;
  run) [ "$#" = 2 ] && [ -d "$2" ] || { echo "usage: bash $0 run DIR" >&2; exit 64; }; run "$2" ;;
  *) echo "usage: bash $0 build DIR amd64|arm64 | run DIR" >&2; exit 64 ;;
esac
