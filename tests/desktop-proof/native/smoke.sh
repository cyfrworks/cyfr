#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The installed CYFR app, home-free: the production app as a person
# installed it, with no CYFR to reach and no signing credentials, on Linux,
# macOS and Windows (Git Bash). Each check prints one PASS or FAIL line, and
# one FAIL fails the run:
#
#   refused    each switch the app does not take, which would open a
#              debugging port, lift the renderers' sandbox or web security,
#              or trust any certificate (--remote-debugging-port, --inspect,
#              --no-sandbox, --disable-web-security,
#              --ignore-certificate-errors), ends the app with 2, naming
#              the switch
#   startup    the app says ready and the chooser answers 200 on
#              127.0.0.1:7340
#   sandbox    (Linux) every live renderer of the app runs under seccomp
#              mode 2, in a user namespace other than the app's
#   second     a second launch for the same account exits 0, saying the
#              first is shown instead, and the first still serves
#   renderer   with the content's renderer killed, the app shows the page
#              again in a renderer of its own, the chooser still answering,
#              and locks nothing
#   terminate  the app terminated (SIGTERM; on Windows the forced end Task
#              Manager's End task gives) ends, its cyfr with it, and 7340
#              stops answering
#   cyfr       with its cyfr killed, the app says cyfr ended, 7340 stops
#              answering and the app keeps running until it is terminated
#   port       with 127.0.0.1:7340 held by another listener, the app says
#              cyfr's sentence for it and ends when terminated
#
# Not checked here: they need a CYFR, a page that asks or the machine
# itself, and the app has no hook for them and gets none. Media denial in a
# page and its frames, the navigation limits, the computer's lock and sleep,
# and continued idle are covered by part D's real-home proof
# (tests/desktop-proof/connect/) and by a person at the machine.
#
# Usage: bash tests/desktop-proof/native/smoke.sh APP_EXECUTABLE
# APP_EXECUTABLE is the installed app's executable: /opt/cyfr/CYFR,
# CYFR.app/Contents/MacOS/CYFR or CYFR.exe. 127.0.0.1:7340 must be free and
# no other CYFR app may run for this account. On Linux the run needs a
# display and a session bus (dbus-run-session -- xvfb-run -a). It needs
# curl, and node for the listener that holds the port. The run takes a
# fresh HOME (on Windows a fresh USERPROFILE, APPDATA and LOCALAPPDATA too)
# and stops every process it started on every exit.
set -uo pipefail

APP=${1:-}
# Git Bash reads a Windows path too; the checks below want its own.
if [ -n "$APP" ] && command -v cygpath >/dev/null; then APP=$(cygpath -u "$APP"); fi
[ -n "$APP" ] && [ -x "$APP" ] || { echo "usage: bash $0 APP_EXECUTABLE (an installed CYFR app's executable)" >&2; exit 64; }
CHOOSER=http://127.0.0.1:7340/bootstrap/
case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=macos ;;
  MINGW* | MSYS* | CYGWIN*) OS=windows ;;
  *) echo "smoke: $(uname -s) is not a platform the app ships for" >&2; exit 64 ;;
esac
for tool in curl node; do
  command -v "$tool" >/dev/null || { echo "smoke: $tool is needed" >&2; exit 64; }
done

RUN=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-desktop-smoke.XXXXXX") || exit 1
mkdir -p "$RUN/home"
export HOME="$RUN/home"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME ELECTRON_RUN_AS_NODE ELECTRON_ENABLE_LOGGING NODE_OPTIONS
if [ "$OS" = windows ]; then
  mkdir -p "$RUN/home/AppData/Roaming" "$RUN/home/AppData/Local"
  USERPROFILE=$(cygpath -w "$RUN/home")
  APPDATA=$(cygpath -w "$RUN/home/AppData/Roaming")
  LOCALAPPDATA=$(cygpath -w "$RUN/home/AppData/Local")
  export USERPROFILE APPDATA LOCALAPPDATA
fi

FAILED=0
CHECKS=0
STARTED=() # the process id of each app and listener the run started
WHY=

pass() { CHECKS=$((CHECKS + 1)); echo "PASS $1${2:+: $2}"; }
fail() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); echo "FAIL $1: $2"; }

# Every running process as `PID PPID ARGS`, a line each; a zombie is none.
procs() {
  if [ "$OS" = windows ]; then
    powershell.exe -NoProfile -NonInteractive -Command \
      'Get-CimInstance Win32_Process | ForEach-Object { "{0} {1} {2}" -f $_.ProcessId, $_.ParentProcessId, $_.CommandLine }' | tr -d '\r'
  else
    ps -A -ww -o pid= -o ppid= -o stat= -o args= | awk '$3 !~ /^Z/ { $3 = ""; print }'
  fi
}

# The processes below PID, as `PID ARGS`, a line each.
descendants() {
  procs | awk -v root="$1" '
    { pid = $1; parent[pid] = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); args[pid] = $0 }
    END {
      for (p in parent) {
        q = p
        for (i = 0; i < 64 && (q in parent); i++) {
          q = parent[q]
          if (q == root) { print p, args[p]; break }
        }
      }
    }'
}
renderers() { descendants "$1" | awk '/--type=renderer/ { print $1 }'; }
cyfr_of() { descendants "$1" | awk '/desktop-serve/ { print $1; exit }'; }

# 0 when any of PIDS (process ids, as procs reads them) still runs.
any_alive() { procs | awk -v want=" $* " 'index(want, " " $1 " ") { found = 1 } END { exit !found }'; }
none_alive() { ! any_alive "$@"; }

# The system's id of the shell's child PID, which on Windows is not the
# shell's own.
ospid() { if [ "$OS" = windows ]; then cat "/proc/$1/winpid"; else echo "$1"; fi; }
oskill() {
  if [ "$OS" = windows ]; then taskkill //F //PID "$1" >/dev/null 2>&1; else kill -KILL "$1" 2>/dev/null; fi
}
# How a person's system ends the app: SIGTERM, or on Windows the forced end
# Task Manager's End task gives.
terminate() {
  if [ "$OS" = windows ]; then taskkill //F //PID "$2" >/dev/null 2>&1; else kill -TERM "$1" 2>/dev/null; fi
}

# within_from CAUSE SECONDS COMMAND...: polls COMMAND until it succeeds, 1
# unless it had SECONDS or fewer after CAUSE, a reading of the shell's
# clock taken as the cause was done.
within_from() {
  local until=$(($1 + $2))
  shift 2
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$until" ] || return 1
    sleep 0.2 # sleep-ok: the gap between two polls of an observable condition, bounded by SECONDS
  done
  [ "$SECONDS" -le "$until" ]
}
# within SECONDS COMMAND...: the same, from now.
within() { within_from "$SECONDS" "$@"; }
gone() { ! kill -0 "$1" 2>/dev/null; }
has_renderer() { [ -n "$(renderers "$1")" ]; }
said() { grep -qF -- "$2" "$RUN/$1.log" 2>/dev/null; }
answers() {
  [ "$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "$CHOOSER")" = 200 ]
}
# Nothing answers on 7340 at all.
silent() { ! curl -s --noproxy '*' --max-time 5 -o /dev/null "$CHOOSER"; }
# exit_of PID: CODE is the status the shell's child PID, which has ended,
# exited with. It runs in this shell, never in a command substitution,
# whose subshell has no children to wait for.
exit_of() { CODE=0; wait "$1" || CODE=$?; }

# launch NAME ARGS...: starts the app with ARGS, its output in
# $RUN/NAME.log; LAUNCHED is the shell's child and LAUNCHED_OS its system id.
launch() {
  local name=$1
  shift
  "$APP" "$@" >"$RUN/$name.log" 2>&1 &
  LAUNCHED=$!
  LAUNCHED_OS=$(ospid "$LAUNCHED")
  STARTED+=("$LAUNCHED_OS")
}

# ready NAME PID: the app launched as NAME says ready and its chooser
# answers; WHY says what it did instead.
ready_or_gone() { said "$1" 'CYFR: ready' || gone "$2"; }
ready() {
  within 60 ready_or_gone "$1" "$2"
  if ! said "$1" 'CYFR: ready'; then
    if gone "$2"; then exit_of "$2"; WHY="it exited $CODE before it said ready"; else WHY="it did not say ready within 60 s"; fi
    return 1
  fi
  within 20 answers || { WHY="it said ready, and $CHOOSER did not answer 200 within 20 s"; return 1; }
}

# ends NAME PID OSPID: the app terminated ends within 30 s, every process
# below it with it, and 7340 stops answering; WHY says what stayed.
ends() {
  local below ended
  below=$(descendants "$3" | awk '{ print $1 }' | tr '\n' ' ')
  ended=$SECONDS
  terminate "$2" "$3"
  within 30 gone "$2" || { WHY="the app still ran 30 s after it was terminated"; return 1; }
  # shellcheck disable=SC2086 # the process ids, one word each
  if [ -n "$below" ] && ! within 30 none_alive $below; then
    WHY="a process it started still ran 30 s after it ended: $(procs | awk -v want=" $below " 'index(want, " " $1 " ")')"
    return 1
  fi
  within_from "$ended" 20 silent || { WHY="127.0.0.1:7340 was not seen free within 20 s of the app being terminated"; return 1; }
}

cleanup() {
  local p q below
  trap - EXIT INT TERM HUP
  for p in ${STARTED[@]+"${STARTED[@]}"}; do
    below=$(descendants "$p" | awk '{ print $1 }')
    oskill "$p"
    for q in $below; do oskill "$q"; done
  done
  if [ "$FAILED" -gt 0 ] || [ "$CHECKS" = 0 ]; then
    for p in "$RUN"/*.log; do
      [ -e "$p" ] || continue
      echo "--- $(basename "$p")"
      cat "$p"
    done >&2
  fi
  rm -rf "$RUN" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# macOS keeps the key of the app's on-disk session in the default keychain,
# found under HOME, and a fresh HOME has none: the app would wait on the
# system's "Keychain Not Found" dialog, showing no window and not ending.
# HOME is the run's by now, so security changes the run's keychain list
# and never the account's own. create-keychain leaves the keychain unlocked,
# and unlock-keychain refuses that passphrase for one named login.
if [ "$OS" = macos ]; then
  KEYCHAIN="$RUN/home/Library/Keychains/login.keychain-db"
  if ! { mkdir -p "${KEYCHAIN%/*}" "$RUN/home/Library/Preferences" &&
    security create-keychain -p smoke "$KEYCHAIN" &&
    security list-keychains -d user -s "$KEYCHAIN" &&
    security default-keychain -d user -s "$KEYCHAIN"; }; then
    echo "smoke: the run's HOME could not be given a keychain" >&2
    exit 1
  fi
fi

if ! silent; then
  echo "smoke: $CHOOSER already answers: another program, or another CYFR app, holds 127.0.0.1:7340" >&2
  exit 1
fi

# ---- refused: each a launch of its own, which ends before anything else ----

for switch in --remote-debugging-port=9229 --inspect=9229 --no-sandbox --disable-web-security --ignore-certificate-errors; do
  name=${switch%%=*}
  name=${name#--}
  launch "refused-$name" "$switch"
  if ! within 60 gone "$LAUNCHED"; then
    fail "refused $switch" "the app still ran after 60 s"
    continue
  fi
  exit_of "$LAUNCHED"
  if [ "$CODE" = 2 ] && said "refused-$name" "CYFR: refused: --$name is not taken"; then
    pass "refused $switch" "exit 2"
  else
    fail "refused $switch" "exit $CODE, and the app's output $(said "refused-$name" "CYFR: refused: --$name is not taken" || echo 'does not ')names the switch"
  fi
done

# ---- one app: startup, sandbox, second launch, renderer lost, terminated ----

launch first
FIRST=$LAUNCHED FIRST_OS=$LAUNCHED_OS
if ready first "$FIRST"; then
  pass startup "ready, and $CHOOSER answers 200"

  if [ "$OS" = linux ]; then
    app_ns=$(readlink "/proc/$FIRST_OS/ns/user") || app_ns=
    # The chooser answers on 7340 before its window's renderer need run.
    within 30 has_renderer "$FIRST_OS" || true
    list=$(renderers "$FIRST_OS")
    bad= n=0
    for r in $list; do
      n=$((n + 1))
      seccomp=$(awk '$1 == "Seccomp:" { print $2 }' "/proc/$r/status" 2>/dev/null) || seccomp=
      ns=$(readlink "/proc/$r/ns/user" 2>/dev/null) || ns=
      [ "$seccomp" = 2 ] || bad+="renderer $r has seccomp mode '${seccomp:-unreadable}'; "
      [ -n "$ns" ] && [ "$ns" != "$app_ns" ] || bad+="renderer $r is in user namespace '${ns:-unreadable}', the app's is '${app_ns:-unreadable}'; "
    done
    if [ "$n" = 0 ]; then
      fail sandbox "the app has no live renderer"
    elif [ -z "$app_ns" ]; then
      fail sandbox "the app's own user namespace is unreadable"
    elif [ -n "$bad" ]; then
      fail sandbox "$bad"
    else
      pass sandbox "$n renderer(s), each under seccomp mode 2 in a user namespace other than the app's $app_ns"
    fi
  fi

  launch second
  if ! within 60 gone "$LAUNCHED"; then
    fail second "the second launch still ran after 60 s"
  else
    exit_of "$LAUNCHED"
    if [ "$CODE" != 0 ] || ! said second 'CYFR: another CYFR app runs for this account: it is shown instead'; then
      fail second "the second launch exited $CODE without saying the first is shown instead"
    elif gone "$FIRST" || ! answers; then
      fail second "the first app stopped serving after the second launch"
    else
      pass second "exit 0, the first shown instead and still serving"
    fi
  fi

  old=$(renderers "$FIRST_OS" | tr '\n' ' ')
  fresh() { [ -n "$(renderers "$FIRST_OS" | awk -v old=" $old " '!index(old, " " $1 " ")')" ]; }
  if [ -z "$old" ]; then
    fail renderer "the app has no live renderer to lose"
  else
    for r in $old; do oskill "$r"; done
    if ! within 30 fresh; then
      fail renderer "no new renderer showed the page again within 30 s of its renderer's end$(said first 'CYFR: cyfr ended: ' && echo ": its cyfr ended meanwhile")"
    elif said first 'CYFR: locked:'; then
      fail renderer "the app locked as its renderer ended: $(grep -F 'CYFR: locked:' "$RUN/first.log" | head -1)"
    elif ! within 20 answers; then
      fail renderer "the page was shown again, and $CHOOSER did not answer 200"
    else
      pass renderer "a new renderer shows the page again, the app locked nothing and the chooser answers"
    fi
  fi

  if ends first "$FIRST" "$FIRST_OS"; then
    pass terminate "the app, its cyfr and every process it started ended, and 7340 is free"
  else
    fail terminate "$WHY"
  fi
else
  fail startup "$WHY"
  for check in sandbox second renderer terminate; do
    [ "$check" != sandbox ] || [ "$OS" = linux ] || continue
    fail "$check" "not run: the app did not start"
  done
  oskill "$FIRST_OS"
  within 30 gone "$FIRST"
fi

# ---- cyfr lost: the app keeps running without it ----

launch lost
LOST=$LAUNCHED LOST_OS=$LAUNCHED_OS
if ! ready lost "$LOST"; then
  fail cyfr "not run: the app did not start: $WHY"
else
  child=$(cyfr_of "$LOST_OS")
  if [ -z "$child" ]; then
    fail cyfr "no cyfr desktop-serve runs below the app"
  else
    killed=$SECONDS
    oskill "$child"
    if ! within 30 said lost 'CYFR: cyfr ended: '; then
      fail cyfr "the app did not say 'cyfr ended' within 30 s of its cyfr's end"
    elif ! within_from "$killed" 20 silent; then
      fail cyfr "127.0.0.1:7340 was not seen free within 20 s of cyfr's kill"
    elif gone "$LOST"; then
      exit_of "$LOST"
      fail cyfr "the app ended with its cyfr: exit $CODE"
    elif ! ends lost "$LOST" "$LOST_OS"; then
      fail cyfr "the app kept running without its cyfr, and then: $WHY"
    else
      pass cyfr "$(grep -F 'CYFR: cyfr ended: ' "$RUN/lost.log" | head -1); the app kept running until it was terminated"
    fi
  fi
fi

# ---- the port held by another listener ----

node -e "require('net').createServer().listen(7340, '127.0.0.1', () => console.log('holding 7340'))" >"$RUN/holder.log" 2>&1 &
HOLDER=$!
STARTED+=("$(ospid "$HOLDER")")
# Its end, by the cleanup's kill, is not news.
disown "$HOLDER"
if ! within 20 said holder 'holding 7340'; then
  fail port "not run: the listener did not take 127.0.0.1:7340"
else
  launch occupied
  OCC=$LAUNCHED OCC_OS=$LAUNCHED_OS
  sentence='CYFR: cyfr ended: another program holds 127.0.0.1:7340: close the app using port 7340, then open CYFR again'
  if ! within 60 said occupied "$sentence"; then
    fail port "the app did not say '$sentence' within 60 s"
  elif gone "$OCC"; then
    exit_of "$OCC"
    fail port "the app ended with its cyfr: exit $CODE"
  else
    terminate "$OCC" "$OCC_OS"
    if within 30 gone "$OCC"; then pass port "$sentence"; else fail port "the app still ran 30 s after it was terminated"; fi
  fi
fi

echo "smoke: $CHECKS checks, $FAILED failed"
[ "$FAILED" = 0 ]
