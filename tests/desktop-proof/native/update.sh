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
# Then A again, and the same update by the app's own window, as a person
# makes it: a click on the rail's foot, Update CYFR, opens its window, and
# Return presses its focused button (xdotool on Linux, System Events and
# CoreGraphics on macOS, user32 on Windows). The newest
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
#                      docker was called, and on Linux, through the update
#                      service, no sudo either
#   window_record      Close on that window (Escape) leaves the record,
#                      the last update's, as it was
#
# What Update CYFR says is read from its window's title, which its page
# sets from what it was served (internal/desktop/assets/update.js): what
# the page was given, not what a person saw drawn.
#   window_terminal    (Linux) where the update service's socket does not
#                      answer (stopped for the row) and sudo would ask for a
#                      password, Update CYFR offers no yes but the line to
#                      run in a terminal, the app running on and no update
#                      begun
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
# xdotool, python3 and the package's dependencies, and DIR outside /home,
# /root, /tmp and /var/tmp: the service reads the releases there as root,
# and its unit sees none of those.
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

# Before a press on Windows, every visible window on the runner's desktop
# that is not the app's is minimised, each said: whatever window a runner
# shows (its consoles, wsl.exe's among them, whose input no other process
# may join) then neither covers the app nor holds the keys. Two windows of
# Windows itself a minimise does not put aside, measured: the first-run
# privacy page of the Arm runner image, "Microsoft account", over the whole
# screen above any topmost window, and Search, whose flyout keeps the keys
# and takes the rail's click. Their processes are ended first, on this
# disposable machine, each said.
aside() {
  pwsh -NoProfile -NonInteractive -Command '
    Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class A {
  public delegate bool F(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(F f, IntPtr p);
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int c);
  public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static List<string> Aside() {
    var said = new List<string>();
    EnumWindows((h, p) => {
      var s = new StringBuilder(512);
      if (!IsWindowVisible(h) || IsIconic(h) || GetWindowText(h, s, 512) == 0) return true;
      uint pid = Pid(h); string name = "none";
      try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch {}
      if (name != "CYFR") { ShowWindowAsync(h, 6); said.Add("\"" + s + "\" (" + name + ", " + pid + ")"); }
      return true;
    }, IntPtr.Zero);
    return said;
  }
}
"@
    for ($i = 0; $i -lt 5; $i++) {
      $o = [A]::FindWindow([NullString]::Value, "Microsoft account"); if ($o -eq [IntPtr]::Zero) { break }
      $owner = [A]::Pid($o); $name = (Get-Process -Id $owner -ErrorAction SilentlyContinue).ProcessName
      Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
      [Console]::Error.WriteLine("update: the first-run page of Windows ($name, $owner) ended: " + $?)
      [void][A]::ShowWindow($o, 0); Start-Sleep -Milliseconds 300
    }
    $holder = Get-Process -Id ([A]::Pid([A]::GetForegroundWindow())) -ErrorAction SilentlyContinue
    if ($holder.ProcessName -eq "SearchHost") {
      Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
      [Console]::Error.WriteLine("update: the Search of Windows (SearchHost, $($holder.Id)) held the keys and was ended: " + $?)
    }
    $said = [A]::Aside()
    if ($said.Count -gt 0) { [Console]::Error.WriteLine("update: minimised " + ($said -join ", ")) }'
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
      aside
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
      # The key goes to the foreground window: every other window is
      # minimised (aside), Update CYFR is made the foreground window and the
      # key sent only once it is, within 10 s, or nothing is sent and the
      # press fails naming the window that holds the keys. A background
      # process may not hand the foreground on by itself: it joins the
      # input of the foreground window's thread to do it.
      local vk=13
      [ "$1" = Escape ] && vk=27
      aside
      VK=$vk pwsh -NoProfile -NonInteractive -Command '
        Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class K {
  public delegate bool F(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(F f, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, UIntPtr e);
  public static IntPtr Find(string prefix) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, p) => {
      var s = new StringBuilder(512);
      if (IsWindowVisible(h) && GetWindowText(h, s, 512) > 0 && s.ToString().StartsWith(prefix)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static string Said(IntPtr h) {
    var s = new StringBuilder(512); GetWindowText(h, s, 512);
    uint p; GetWindowThreadProcessId(h, out p); string n = "none";
    try { n = System.Diagnostics.Process.GetProcessById((int)p).ProcessName; } catch {}
    return "\"" + s + "\" (" + n + ", " + p + ")";
  }
  public static bool Front(IntPtr t) {
    IntPtr fg = GetForegroundWindow();
    if (fg == t) return true;
    uint pid; uint them = GetWindowThreadProcessId(fg, out pid); uint me = GetCurrentThreadId();
    bool joined = them != 0 && them != me && AttachThreadInput(me, them, true);
    BringWindowToTop(t); SetForegroundWindow(t);
    if (joined) AttachThreadInput(me, them, false);
    return GetForegroundWindow() == t;
  }
}
"@
        $t = [K]::Find("Update CYFR")
        if ($t -eq [IntPtr]::Zero) { [Console]::Error.WriteLine("update: no Update CYFR window to press a key in"); exit 1 }
        $until = (Get-Date).AddSeconds(10)
        while (-not [K]::Front($t)) {
          if ((Get-Date) -gt $until) {
            [Console]::Error.WriteLine("update: Update CYFR did not take the keys in 10 s; the window that holds them is " + [K]::Said([K]::GetForegroundWindow()))
            exit 1
          }
          Start-Sleep -Milliseconds 200
        }
        [K]::keybd_event([byte]$env:VK, 0, 0, [UIntPtr]::Zero); [K]::keybd_event([byte]$env:VK, 0, 2, [UIntPtr]::Zero)' ;;
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

  window "$dir" "$arch"
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
  # On Linux the sudo that records each run and runs nothing is on the
  # app's PATH too: the window's update goes through the update service.
  local path="$LOGS/bin:$PATH"
  [ "$OS" != linux ] || path="$LOGS/bin:$LOGS/nosudo:$PATH"
  (cd "$LOGS/empty" && PATH="$path" "$APP" >"$LOGS/app-window.log" 2>&1 &)
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
  if within 120 titled "did not verify" && within 60 titled "release $U" && alive "$before" && answers && [ "$(release_of)" = "$A" ] &&
    { [ "$OS" != linux ] || [ ! -s "$LOGS/sudo-runs" ]; }; then
    pass window_unverified "the yes refused U before anything closed: the app at $A ($before) runs on, answering, and offers U again"
  else
    fail window_unverified "the app $(alive "$before" && echo still || echo 'no longer') runs, its cyfr answers '$(release_of)', sudo ran '$(cat "$LOGS/sudo-runs" 2>/dev/null)'; the record: $(tail -5 "$RECORD" 2>/dev/null)"
  fi

  # Close (Escape), then B the newest, Update CYFR again.
  local step=closed
  if key Escape && within 20 untitled "Update CYFR" && echo "$B" >"$dir/latest" &&
    step=opened && opens_update "release $B" &&
    step=pressed && key Return &&
    step=closed-by-update && within 60 not_alive "$before" &&
    step=reopened && within 120 running && within 60 answers && [ "$(release_of)" = "$B" ] &&
    step=record && within 60 titled "The CYFR app is release $B" &&
    step=docker && [ ! -s "$docker" ] &&
    step=sudo && { [ "$OS" != linux ] || [ ! -s "$LOGS/sudo-runs" ]; }; then
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
  # Where the update service's socket does not answer (stopped for this
  # row) and sudo asks while any rule that matches the account wants a
  # password (sudo -v); the drop-in's command is no other, so sudo -n
  # removes it.
  sudo -n systemctl stop cyfr-update.socket
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
  sudo -n systemctl start cyfr-update.socket
}

case "${1:-}" in
  build) [ "$#" = 3 ] && [[ "$3" =~ ^(amd64|arm64)$ ]] || { echo "usage: bash $0 build DIR amd64|arm64" >&2; exit 64; }; build "$2" "$3" ;;
  run) [ "$#" = 2 ] && [ -d "$2" ] || { echo "usage: bash $0 run DIR" >&2; exit 64; }; run "$2" ;;
  *) echo "usage: bash $0 build DIR amd64|arm64 | run DIR" >&2; exit 64 ;;
esac
