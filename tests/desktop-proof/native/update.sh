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
# Then A again, and the same update by the app's own window, as a person
# makes it: a click on the rail's foot, Update CYFR, opens its window, and
# Return presses its focused button (xdotool on Linux, System Events and
# CoreGraphics on macOS, user32 and SendKeys on Windows). The newest
# release is the folder's file latest. A docker that records each call is
# first on the app's PATH:
#
#   window_opened      the rail's foot opens Update CYFR, offering the
#                      newest release, U
#   window_unverified  its yes runs the update, which refuses before
#                      anything closes: Update CYFR says U did not verify,
#                      the same app runs at A and answers, and Update CYFR
#                      offers U again
#   window_update      with B the newest, its yes closes the app, which
#                      opens again at B, a new process, with Update CYFR
#                      open by itself saying the app is release B, as its
#                      page read from the record of the update to B; no
#                      docker was called
#   window_record      Close on that window (Escape) leaves the record,
#                      the last update's, as it was
#
# What Update CYFR says is read from its window's title, which its page
# sets from what it was served (internal/desktop/assets/update.js): what
# the page was given, not what a person saw drawn.
#   window_terminal    (Linux) where sudo would ask for a password, Update
#                      CYFR offers no yes but the line to run in a terminal,
#                      the app running on and no update begun
#
# It installs software and leaves the app installed, so `run` refuses
# anywhere but a disposable machine: GitHub's own runner
# (GITHUB_ACTIONS=true, RUNNER_ENVIRONMENT=github-hosted) or a container
# (/.dockerenv). There the account administers the machine with sudo and no
# password (Linux), and 127.0.0.1:7340 is free. On Linux it needs a display
# and a session bus (dbus-run-session -- xvfb-run -a), curl, xdotool and
# the package's dependencies.
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
# executable with no engine --type, which its helpers carry, alone or with
# --updated, as the update Update CYFR started opens it again.
app_pids() {
  if [ "$OS" = windows ]; then
    pwsh -NoProfile -NonInteractive -Command \
      "Get-CimInstance Win32_Process -Filter \"Name='CYFR.exe'\" | Where-Object { \$_.ExecutablePath -eq '$(cygpath -w "$APP")' -and \$_.CommandLine -notmatch '--type=' } | ForEach-Object { \$_.ProcessId }" | tr -d '\r'
  else
    pgrep -x -f "$APP( --updated)?"
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

# The record of an update Update CYFR started (cmd/desktop.go): in the
# device's folder.
case "$OS" in
  windows) RECORD="$(cygpath -u "$USERPROFILE")/.cyfr/device/update.log" ;;
  *) RECORD="$HOME/.cyfr/device/update.log" ;;
esac

# Whether a window of the app's has a title holding TEXT.
titled() {
  case "$OS" in
    linux) xdotool search --name "$(printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|]/\\&/g')" >/dev/null 2>&1 ;;
    darwin) osascript -e 'tell application "System Events" to get name of every window of (every process whose name is "CYFR")' 2>/dev/null | grep -qF "$1" ;;
    windows) windows_titles | grep -qF "$1" ;;
  esac
}
untitled() { ! titled "$1"; }

# Every visible window's title and rectangle on Windows, owned ones such as
# Update CYFR's among them, which UI Automation lists under their owner.
windows_titles() {
  pwsh -NoProfile -NonInteractive -Command '
    Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class W {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
  public delegate bool F(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(F f, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  public static List<string> All() {
    var all = new List<string>();
    EnumWindows((h, p) => {
      var s = new StringBuilder(4096);
      if (IsWindowVisible(h) && GetWindowText(h, s, 4096) > 0) { R r; GetWindowRect(h, out r); all.Add(s + " " + r.L + "," + r.T + "," + r.Rt + "," + r.B); }
      return true;
    }, IntPtr.Zero);
    return all;
  }
}
"@
    [W]::All()' | tr -d '\r'
}

# What the app's windows are, for a row that failed: each one's title,
# place and size.
windows_said() {
  case "$OS" in
    linux)
      local w
      for w in $(xdotool search --name 'CYFR' 2>/dev/null); do
        echo "$(xdotool getwindowname "$w") $(xdotool getwindowgeometry "$w" | tr '\n' ' ')"
      done ;;
    darwin) osascript -e 'tell application "System Events" to tell process "CYFR" to get {name, position, size} of every window' 2>&1 ;;
    windows) windows_titles ;;
  esac
}

# A click on the rail's foot, Update CYFR, once the app's window is placed
# at the screen's corner at 1000 by 700, which a runner's screen holds
# whole: 36 points from its left, 45 from its content's bottom.
press_rail_update() {
  case "$OS" in
    linux)
      local W X Y WIDTH HEIGHT SCREEN
      # The app's window is the visible one: the engine keeps a hidden one
      # of the same title.
      W=$(xdotool search --onlyvisible --name '^CYFR$' | tail -1)
      [ -n "$W" ] || return 1
      xdotool windowmove --sync "$W" 0 0 && xdotool windowsize --sync "$W" 1000 700 || return 1
      eval "$(xdotool getwindowgeometry --shell "$W")"
      xdotool mousemove --sync $((X + 36)) $((Y + HEIGHT - 45)) click 1 ;;
    darwin)
      local at
      at=$(osascript -e 'tell application "System Events" to tell process "CYFR"
        set frontmost to true
        set position of window "CYFR" to {0, 30}
        set size of window "CYFR" to {1000, 700}
        delay 1
        set {x, y} to position of window "CYFR"
        set {w, h} to size of window "CYFR"
        return ((x + 36) as text) & " " & ((y + h - 45) as text)
      end tell') || return 1
      osascript -l JavaScript -e "ObjC.import('CoreGraphics'); const p = \$.CGPointMake(${at% *}, ${at#* });
        for (const t of [\$.kCGEventLeftMouseDown, \$.kCGEventLeftMouseUp]) {
          \$.CGEventPost(\$.kCGHIDEventTap, \$.CGEventCreateMouseEvent(null, t, p, \$.kCGMouseButtonLeft)); delay(0.1) }" ;;
    windows)
      pwsh -NoProfile -NonInteractive -Command '
        Add-Type @"
using System; using System.Runtime.InteropServices;
public static class U {
  [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref P p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
}
"@
        # The Arm runner image shows the first-run privacy page of Windows,
        # "Microsoft account", over the whole screen, above any topmost
        # window: its process is ended first, on this disposable machine.
        Get-Process | Where-Object { $_.MainWindowTitle -eq "Microsoft account" } | Stop-Process -Force -ErrorAction SilentlyContinue
        $h = [U]::FindWindow([NullString]::Value, "CYFR"); if ($h -eq [IntPtr]::Zero) { exit 1 }
        # Above every other window, the runner agent window among them, which
        # a background process may not bring forward (SetForegroundWindow).
        [void][U]::SetWindowPos($h, [IntPtr](-1), 0, 0, 1000, 700, 0x40); Start-Sleep -Milliseconds 500
        [void][U]::SetForegroundWindow($h); $r = New-Object U+R; [void][U]::GetClientRect($h, [ref]$r)
        $p = New-Object U+P; $p.X = 36; $p.Y = $r.B - 45; [void][U]::ClientToScreen($h, [ref]$p)
        [void][U]::SetCursorPos($p.X, $p.Y); Start-Sleep -Milliseconds 100
        [U]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 50; [U]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)' ;;
  esac
}

# Update CYFR opened from the rail's foot, its title holding TEXT: pressed
# again until it shows, as a person presses again a press the app missed
# while its rail was still loading.
opens_update() {
  local tries
  for tries in 1 2 3 4 5 6; do
    press_rail_update && within 10 titled "$1" && return 0
  done
  return 1
}

# A key, Return or Escape, pressed in Update CYFR's window.
key() {
  case "$OS" in
    linux)
      local W
      W=$(xdotool search --onlyvisible --name '^Update CYFR' | tail -1)
      [ -n "$W" ] || return 1
      xdotool windowfocus --sync "$W" && xdotool key --clearmodifiers "$1" ;;
    darwin)
      local code=36
      [ "$1" = Escape ] && code=53
      osascript -e "tell application \"System Events\" to tell process \"CYFR\"
        set frontmost to true
        perform action \"AXRaise\" of (first window whose name starts with \"Update CYFR\")
        key code $code
      end tell" ;;
    windows)
      local send='~'
      [ "$1" = Escape ] && send='{ESC}'
      pwsh -NoProfile -NonInteractive -Command \
        "\$s = New-Object -ComObject WScript.Shell; if (-not \$s.AppActivate('Update CYFR')) { exit 1 }; Start-Sleep -Milliseconds 300; \$s.SendKeys('$send')" ;;
  esac
}

# A release installed whichever is: B's own uninstall first on Windows,
# whose installer refuses an older release over a newer one.
reinstall() {
  if [ "$OS" = windows ] && [ -n "${2:-}" ]; then
    pwsh -NoProfile -NonInteractive -Command \
      "\$p = Start-Process msiexec.exe -ArgumentList '/x', '\"$(cygpath -w "$2")\"', '/qn', '/norestart' -Wait -PassThru; exit \$p.ExitCode" || return 1
  fi
  install_package "$1"
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
  if [ "$OS" = linux ] && ! id -nG "$(id -un)" | tr ' ' '\n' | grep -qxE 'sudo|admin'; then
    sudo usermod -aG sudo "$(id -un)" || { echo "update: this account could not join the sudo group" >&2; exit 1; }
    sudo sed -i 's/^%sudo\(\s\+\)ALL=(ALL:ALL) ALL$/%sudo\1ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers && sudo visudo -c >/dev/null
  fi
  if [ "$OS" = linux ] && ! sudo -n -v 2>/dev/null; then
    echo "update: sudo -v asks this account for a password, so cyfr update would refuse with no terminal" >&2
    exit 1
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

  window "$dir" "$arch"

  echo "update: $CHECKS checks, $FAILED failed"
  [ "$FAILED" = 0 ]
}

# The update by Update CYFR, the app's own window, from A again.
window() {
  local dir=$1 arch=$2 before='' after='' docker
  quit_all
  if ! reinstall "$dir/$A/cyfr-desktop_${A}_${OS}_$arch.$EXT" "$dir/$B/cyfr-desktop_${B}_${OS}_$arch.$EXT" >"$LOGS/reinstall.log" 2>&1 ||
    [ "$(release_of)" != "$A" ]; then
    fail window_opened "A could not be installed again: $(tail -5 "$LOGS/reinstall.log")"
    return
  fi
  rm -f "$RECORD"
  # A docker that records each call, first on the app's PATH.
  mkdir -p "$LOGS/bin"
  docker="$LOGS/docker.log"
  : >"$docker"
  if [ "$OS" = windows ]; then
    printf '@echo %%*>>"%s"\r\n' "$(cygpath -w "$docker")" >"$LOGS/bin/docker.cmd"
  else
    printf '#!/bin/sh\necho "$*" >>"%s"\n' "$docker" >"$LOGS/bin/docker"
    chmod 755 "$LOGS/bin/docker"
  fi
  echo "$U" >"$dir/latest"
  (cd "$LOGS/empty" && PATH="$LOGS/bin:$PATH" "$APP" >"$LOGS/app-window.log" 2>&1 &)
  if within 60 answers && within 10 running; then
    before=$(first_pid)
  fi
  if [ -n "$before" ] && opens_update "release $U"; then
    pass window_opened "the rail's foot opened Update CYFR offering $U"
  else
    fail window_opened "no Update CYFR offering $U opened; the app's windows: $(windows_said | tr '\n' ';')"
    return
  fi

  key Return
  if within 120 titled "did not verify" && within 60 titled "release $U" && alive "$before" && answers && [ "$(release_of)" = "$A" ]; then
    pass window_unverified "the yes refused U before anything closed: the app at $A ($before) runs on, answering, and offers U again"
  else
    fail window_unverified "the app $(alive "$before" && echo still || echo 'no longer') runs, its cyfr answers '$(release_of)'; the record: $(tail -5 "$RECORD" 2>/dev/null)"
  fi

  # Close (Escape), then B the newest, Update CYFR again.
  local step=closed
  if key Escape && within 20 untitled "Update CYFR" && echo "$B" >"$dir/latest" &&
    step=opened && opens_update "release $B" &&
    step=pressed && key Return &&
    step=closed-by-update && within 60 not_alive "$before" &&
    step=reopened && within 120 running && within 60 answers && [ "$(release_of)" = "$B" ] &&
    step=record && within 60 titled "The CYFR app is release $B" &&
    step=docker && [ ! -s "$docker" ]; then
    after=$(first_pid)
    pass window_update "the app at $A ($before) closed and opened again at $B ($after), Update CYFR open on the record; no docker call"
  else
    fail window_update "not $step: the app $(alive "$before" && echo 'still runs' || echo 'is gone'), its cyfr answers '$(release_of)', docker heard '$(cat "$docker")'; the windows: $(windows_said | tr '\n' ';'); the record: $(tail -8 "$RECORD" 2>/dev/null | tr '\n' ';')"
    return
  fi

  local kept
  kept=$(sum "$RECORD" 2>/dev/null)
  if [ -n "$kept" ] && key Escape && within 20 untitled "Update CYFR" && [ "$(sum "$RECORD" 2>/dev/null)" = "$kept" ]; then
    pass window_record "Close left the record of the update to $B as it was"
  else
    fail window_record "the record $([ -e "$RECORD" ] && echo 'is there' || echo 'is gone'), Update CYFR $(titled "Update CYFR" && echo 'still shows' || echo closed)"
  fi

  [ "$OS" = linux ] || return
  # sudo asks while any rule that matches the account wants a password
  # (sudo -v); the drop-in's command is no other, so sudo -n removes it.
  local asks=/etc/sudoers.d/zz-cyfr-update-proof
  echo "$(id -un) ALL=(ALL) /usr/bin/false" | sudo -n tee "$asks" >/dev/null && sudo -n chmod 0440 "$asks"
  echo "$U" >"$dir/latest"
  if sudo -n -v 2>/dev/null; then
    fail window_terminal "sudo -v still asks this account for no password"
  elif opens_update "needs a terminal" && alive "$after" && [ "$(sum "$RECORD" 2>/dev/null)" = "$kept" ]; then
    pass window_terminal "Update CYFR offers no yes but the line to run in a terminal; the app ($after) runs on, no update begun"
  else
    fail window_terminal "the app $(alive "$after" && echo 'runs' || echo 'is gone'), the record $([ "$(sum "$RECORD" 2>/dev/null)" = "$kept" ] && echo 'as it was' || echo 'changed'): $(tail -5 "$LOGS/app-window.log")"
  fi
  sudo -n rm -f "$asks"
}

case "${1:-}" in
  build) [ "$#" = 3 ] && [[ "$3" =~ ^(amd64|arm64)$ ]] || { echo "usage: bash $0 build DIR amd64|arm64" >&2; exit 64; }; build "$2" "$3" ;;
  run) [ "$#" = 2 ] && [ -d "$2" ] || { echo "usage: bash $0 run DIR" >&2; exit 64; }; run "$2" ;;
  *) echo "usage: bash $0 build DIR amd64|arm64 | run DIR" >&2; exit 64 ;;
esac
