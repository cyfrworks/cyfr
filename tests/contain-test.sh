#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/lib/contain.sh against commands that stand in for the harness's
# children. Each case runs its calling shell as a script of its own, with
# the containment variables cleared and under `set -eu`, as the wrappers
# run. Every process a case starts writes its own pid into the scratch
# directory, so the EXIT trap can stop whatever a failed case left.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
LIB="$root/scripts/lib/contain.sh"
S=$(mktemp -d /tmp/cyfr-contain-test.XXXXXX)
export LIB S
unset HEAVY_CHECK_HELD CONTAIN_REGISTRY CONTAIN_CLOSE_FDS CONTAIN_HOLD_FDS CONTAIN_FD_BASE

cleanup() {
  local f p
  for f in "$S"/*.registry; do
    [ -s "$f" ] && rm -f "$(cat "$f")"
  done
  for f in "$S"/*.caller; do
    [ -s "$f" ] || continue
    p=$(cat "$f")
    case $p in ''|0*|*[!0-9]*) continue ;; esac
    kill -KILL "$p" 2>/dev/null || :
    pkill -KILL -f "__contain_watchdog .* $p\$" 2>/dev/null || :
  done
  for f in "$S"/*.pid; do
    [ -s "$f" ] || continue
    p=$(cat "$f")
    case $p in ''|0*|*[!0-9]*) continue ;; esac
    pkill -KILL -s "$p" 2>/dev/null || :
    kill -KILL "$p" 2>/dev/null || :
  done
  rm -rf "$S"
}
trap 'cleanup 2>/dev/null' EXIT

case_name=
fail() { echo "FAIL: $case_name: $*" >&2; exit 1; }
begin() { case_name=$1; echo "case $case_name"; }

# A bounded wait on an observable condition: `until_true 10 test -e file`.
until_true() {
  local limit=$(( $1 * 10 )) n=0
  shift
  until "$@" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt "$limit" ] || return 1
    sleep 0.1
  done
}
# A process that exists and has not exited; a zombie has exited.
alive() {
  local s
  read -r s 2>/dev/null <"/proc/$1/stat" || return 1
  s=${s##*) }
  case $s in Z*|X*) return 1 ;; esac
}
dead() { ! alive "$1"; }
# Ends a process this shell started, and reaps it so Bash does not
# announce its death.
kill_child() { kill -KILL "$1" 2>/dev/null || :; wait "$1" 2>/dev/null || :; }
# The pid a process wrote into $S/$1.pid, once it is there.
pid_of() {
  until_true 20 test -s "$S/$1.pid" || fail "no pid in $1.pid"
  cat "$S/$1.pid"
}
sid_of() { ps -o sid= -p "$1" | tr -d ' '; }
watchdogs_of() { pgrep -f "__contain_watchdog .* $1\$" || :; }
no_watchdog_of() { [ -z "$(watchdogs_of "$1")" ]; }
session_empty() { ! pgrep -s "$1" >/dev/null; }

# Writes the calling shell $S/$1.sh from standard input, behind a prelude
# that records its pid and sources the library.
caller() {
  { printf '%s\n' 'set -eu' 'echo $$ > "$S/'"$1"'.caller"' '. "$LIB"'; cat; } >"$S/$1.sh"
}
clean_env=(env -u HEAVY_CHECK_HELD -u CONTAIN_REGISTRY -u CONTAIN_CLOSE_FDS -u CONTAIN_HOLD_FDS)
run() { "${clean_env[@]}" bash "$S/$1.sh"; }
run_bg() { "${clean_env[@]}" bash "$S/$1.sh" & bg=$!; }

# A command that writes its pid into $S/$1.pid and runs until stopped;
# with `ignore` as $2 it ignores TERM, and so do its children.
forever() {
  local trap_line=
  [ "${2:-}" = ignore ] && trap_line='trap "" TERM; '
  printf '%s' "bash -c '${trap_line}echo \$\$ > \"\$S/$1.pid\"; while :; do sleep 0.2; done'"
}

# --- 1: leftovers after a clean exit --------------------------------------
begin '1 exit 0 with a grandchild still running'
caller c1 <<'EOF'
contain_start -g 2 bash -c '
  (sh -c "echo \$\$ > \"\$S/c1.grandchild.pid\"; exec sleep 300" &)
  n=0; until [ -s "$S/c1.grandchild.pid" ] || [ $n -ge 100 ]; do sleep 0.1; n=$((n+1)); done
  kill -0 "$(cat "$S/c1.grandchild.pid")" && echo alive > "$S/c1.grandchild.seen"
  exit 0'
st=0; contain_wait "$CONTAIN_PID" 30 2 || st=$?
echo "$st" > "$S/c1.status"
echo "${CONTAIN_SURVIVORS:-}" > "$S/c1.survivors"
EOF
run c1
[ "$(cat "$S/c1.status")" = 0 ] || fail "contain_wait returned $(cat "$S/c1.status")"
[ "$(cat "$S/c1.grandchild.seen" 2>/dev/null)" = alive ] || fail 'the grandchild was not running when the command exited'
dead "$(pid_of c1.grandchild)" || fail 'the grandchild outlived contain_wait'
[ -z "$(cat "$S/c1.survivors")" ] || fail 'a clean stop reported survivors'
until_true 5 no_watchdog_of "$(cat "$S/c1.caller")" || fail 'the watchdog outlived a clean session'

# --- 2: a descendant in a process group of its own ------------------------
begin '2 exit 3 leaving a process group of its own'
caller c2 <<'EOF'
contain_start -g 2 bash -c '
  set -m
  sh -c "echo \$\$ > \"\$S/c2.desc.pid\"; exec sleep 300" &
  n=0; until [ -s "$S/c2.desc.pid" ] || [ $n -ge 100 ]; do sleep 0.1; n=$((n+1)); done
  d=$(cat "$S/c2.desc.pid")
  kill -0 "$d" && ps -o pgid= -p "$d" | tr -d " " > "$S/c2.desc.pgid"
  exit 3'
echo "$CONTAIN_PID" > "$S/c2.leader.pid"
st=0; contain_wait "$CONTAIN_PID" 30 2 || st=$?
echo "$st" > "$S/c2.status"
EOF
run c2
[ "$(cat "$S/c2.status")" = 3 ] || fail "contain_wait returned $(cat "$S/c2.status"), not the command's 3"
desc=$(pid_of c2.desc)
[ "$(cat "$S/c2.desc.pgid")" = "$desc" ] || fail 'the descendant did not lead a process group of its own'
[ "$desc" != "$(cat "$S/c2.leader.pid")" ] || fail 'the descendant was the leader'
dead "$desc" || fail 'the descendant outlived contain_wait'

# --- 3: the deadline -------------------------------------------------------
begin '3 past its deadline'
caller c3 <<'EOF'
contain_start -g 3 bash -c '
  sh -c "echo \$\$ > \"\$S/c3.child.pid\"; exec sleep 300" &
  echo $$ > "$S/c3.leader.pid"
  wait'
t=$SECONDS
st=0; contain_wait "$CONTAIN_PID" 2 3 || st=$?
echo "$st $((SECONDS - t)) $(pgrep -s "$CONTAIN_PID" | wc -l | tr -d ' ')" > "$S/c3.result"
EOF
run_bg c3
leader=$(pid_of c3.leader); child=$(pid_of c3.child)
alive "$leader" && alive "$child" || fail 'the command was not running before its deadline'
until_true 30 test -s "$S/c3.result" || fail 'contain_wait did not return'
read -r st took left <"$S/c3.result"
[ "$st" = 124 ] || fail "contain_wait returned $st, not 124"
[ "$took" -ge 1 ] && [ "$took" -le $((2 + 3 + 15)) ] || fail "it returned after ${took}s"
[ "$left" = 0 ] || fail "$left processes of the session were left when it returned"
dead "$leader" && dead "$child" || fail 'a process of the session outlived the deadline'

# --- 4: TERM ignored -------------------------------------------------------
begin '4 a command that ignores TERM'
caller c4 <<EOF
contain_start -g 2 $(forever c4.leader ignore)
until [ -s "\$S/c4.leader.pid" ]; do sleep 0.1; done
t=\$SECONDS
st=0; contain_stop "\$CONTAIN_PID" 2 || st=\$?
echo "\$st \$((SECONDS - t))" > "\$S/c4.result"
EOF
run_bg c4
leader=$(pid_of c4.leader)
alive "$leader" || fail 'the command was not running'
until_true 30 test -s "$S/c4.result" || fail 'contain_stop did not return'
read -r st took <"$S/c4.result"
[ "$st" = 0 ] || fail "contain_stop returned $st"
[ "$took" -ge 2 ] && [ "$took" -le $((2 + 15)) ] || fail "the KILL came after ${took}s, not after the 2 s grace"
dead "$leader" || fail 'the command outlived the KILL'

# --- 5: dependency order ---------------------------------------------------
begin '5 the leader stops its dependent before anything else is signaled'
# The dependent ignores nothing but records every TERM it gets; only the
# leader's trap may stop it. The trap looks for a TERM the dependent got
# within half a second of its own, then stops it with KILL and says so.
caller c5 <<'EOF'
contain_start -g 5 bash -c '
  bash -c "trap \"echo TERM >> \\\"\$S/c5.dep.signals\\\"\" TERM; echo \$\$ > \"\$S/c5.dep.pid\"; while :; do sleep 300 & wait \$! || :; done" &
  dep=$!
  on_term() {
    sleep 0.5
    if kill -0 "$dep" && [ ! -e "$S/c5.dep.signals" ]; then echo "alive unsignaled" > "$S/c5.order"
    else echo "dead or signaled" > "$S/c5.order"; fi
    kill -KILL "$dep"; wait "$dep" 2>/dev/null || :
    kill -0 "$dep" 2>/dev/null || echo stopped > "$S/c5.dep.stopped"
    exit 0
  }
  trap on_term TERM
  echo $$ > "$S/c5.leader.pid"
  while :; do sleep 300 & wait $! || :; done'
until [ -s "$S/c5.dep.pid" ] && [ -s "$S/c5.leader.pid" ]; do sleep 0.1; done
t=$SECONDS
st=0; contain_stop "$CONTAIN_PID" 5 || st=$?
echo "$st $((SECONDS - t))" > "$S/c5.result"
EOF
run_bg c5
dep=$(pid_of c5.dep); leader=$(pid_of c5.leader)
alive "$dep" && alive "$leader" || fail 'the leader and its dependent were not running'
until_true 30 test -s "$S/c5.result" || fail 'contain_stop did not return'
read -r st took <"$S/c5.result"
[ "$st" = 0 ] || fail "contain_stop returned $st"
[ "$(cat "$S/c5.order" 2>/dev/null)" = 'alive unsignaled' ] || fail "when the leader's trap ran the dependent was: $(cat "$S/c5.order" 2>/dev/null || echo 'never checked')"
[ "$(cat "$S/c5.dep.stopped" 2>/dev/null)" = stopped ] || fail "the leader's trap did not stop the dependent"
[ "$took" -lt 5 ] || fail "the leader took the whole grace (${took}s): its trap did not end it"
dead "$dep" && dead "$leader" || fail 'a process of the session survived'

# --- 6: the caller SIGKILLed ------------------------------------------------
begin '6 the calling shell SIGKILLed: its watchdogs stop both sessions'
# Two sessions: the second must not hold the first's pipe, or the first
# watchdog would wait for the second session to end before it starts.
caller c6 <<EOF
contain_start -g 10 $(forever c6.a ignore)
contain_start -g 10 bash -c 'trap "" TERM
  for f in /dev/fd/*; do n=\${f##*/}; [ "\$n" -ge 20 ] && [ "\$n" -le 83 ] && echo "\$n"; done > "\$S/c6.b.fds"
  echo \$\$ > "\$S/c6.b.pid"; while :; do sleep 0.2; done'
contain_wait "\$CONTAIN_PID" 0
EOF
run_bg c6
a=$(pid_of c6.a); b=$(pid_of c6.b)
alive "$a" && alive "$b" || fail 'the sessions were not running'
[ ! -s "$S/c6.b.fds" ] || fail "the second command holds watchdog descriptors: $(tr '\n' ' ' <"$S/c6.b.fds")"
kill_child "$bg"
t=$SECONDS
until_true 40 eval 'dead "$a" && dead "$b"' || fail 'the sessions outlived their caller'
took=$((SECONDS - t))
[ "$took" -le $((10 + 15 + 2)) ] || fail "the watchdogs took ${took}s, more than one grace plus 15 s"
until_true 20 no_watchdog_of "$(cat "$S/c6.caller")" || fail 'a watchdog stayed after its session was stopped'

# --- 7: the held lock --------------------------------------------------------
begin '7 a held descriptor stays held until the session is gone'
caller c7 <<EOF
exec 9>>"\$S/c7.lock"
flock -x 9
CONTAIN_HOLD_FDS=9 CONTAIN_CLOSE_FDS=9
contain_start -g 3 bash -c 'trap "" TERM
  { [ -e /dev/fd/9 ] && echo 9; [ -e /dev/fd/20 ] && echo 20; } > "\$S/c7.fds" || :
  echo \$\$ > "\$S/c7.leader.pid"; while :; do sleep 0.2; done'
contain_wait "\$CONTAIN_PID" 0
EOF
run_bg c7
leader=$(pid_of c7.leader)
alive "$leader" || fail 'the command was not running'
[ ! -s "$S/c7.fds" ] || fail "the command holds descriptors $(tr '\n' ' ' <"$S/c7.fds")"
! flock -n "$S/c7.lock" true || fail 'the lock was not held to begin with'
kill_child "$bg"
until_true 30 flock -n "$S/c7.lock" true || fail 'the lock was never released'
session_empty "$leader" || fail 'the lock was released while the session still ran'
dead "$leader" || fail 'the command outlived its caller'

# --- 8: the registry sweep -------------------------------------------------
begin '8 the registry sweep stops a session whose starter died'
for n in 1 2; do
  caller "c8.n$n" <<EOF
contain_start -g 600 $(forever "c8.leader$n" ignore)
contain_wait "\$CONTAIN_PID" 0
EOF
done
caller c8 <<'EOF'
contain_registry_create
echo "$CONTAIN_REGISTRY" > "$S/c8.registry"
(bash "$S/c8.n1.sh" &); (bash "$S/c8.n2.sh" &)
n=0; until [ "$(grep -c . "$CONTAIN_REGISTRY" || :)" = 2 ] || [ $n -ge 200 ]; do sleep 0.1; n=$((n+1)); done
cp "$CONTAIN_REGISTRY" "$S/c8.listed"
until [ -e "$S/c8.go" ]; do sleep 0.1; done
t=$SECONDS
st=0; contain_sweep_registry 2 || st=$?
echo "$st $((SECONDS - t)) ${CONTAIN_SURVIVORS:-}" > "$S/c8.result"
rm -f "$CONTAIN_REGISTRY"
EOF
run_bg c8
l1=$(pid_of c8.leader1); l2=$(pid_of c8.leader2)
until_true 20 test -s "$S/c8.listed" || fail 'the registry was not read'
[ "$(sort "$S/c8.listed" | tr '\n' ' ')" = "$(printf '%s\n' "$l1" "$l2" | sort | tr '\n' ' ')" ] \
  || fail "the registry lists $(tr '\n' ' ' <"$S/c8.listed"), not the two sessions $l1 $l2"
kill -KILL "$(cat "$S/c8.n1.caller")"
until_true 10 eval '! alive "$(cat "$S/c8.n1.caller")"' || fail 'the first starter did not die'
alive "$l1" || fail 'the dead starter took its session with it before the sweep'
touch "$S/c8.go"
until_true 30 test -s "$S/c8.result" || fail 'the sweep did not return'
read -r st took survivors <"$S/c8.result" || :
[ "$st" = 0 ] || fail "the sweep returned $st"
[ "$took" -le $((2 + 15)) ] || fail "the sweep took ${took}s"
[ -z "${survivors:-}" ] || fail "the sweep reported survivors: $survivors"
dead "$l1" && dead "$l2" || fail 'a registered session outlived the sweep'

# --- 9: a daemon is outside -----------------------------------------------
begin '9 a daemon that calls setsid survives'
caller c9 <<'EOF'
contain_start -g 2 bash -c '
  setsid sh -c "echo \$\$ > \"\$S/c9.daemon.pid\"; exec sleep 300" </dev/null >/dev/null 2>&1 &
  n=0; until [ -s "$S/c9.daemon.pid" ] || [ $n -ge 100 ]; do sleep 0.1; n=$((n+1)); done
  exit 0'
echo "$CONTAIN_PID" > "$S/c9.leader.pid"
st=0; contain_wait "$CONTAIN_PID" 30 2 || st=$?
echo "$st" > "$S/c9.status"
EOF
run c9
daemon=$(pid_of c9.daemon)
[ "$(cat "$S/c9.status")" = 0 ] || fail "contain_wait returned $(cat "$S/c9.status")"
alive "$daemon" || fail 'the daemon was stopped'
[ "$(sid_of "$daemon")" = "$daemon" ] || fail 'the daemon did not lead a session of its own'
kill -KILL "$daemon"
until_true 5 dead "$daemon" || fail 'the daemon would not stop'

# --- 10: stopping many at once --------------------------------------------
begin '10 contain_stop_all over eight TERM-ignoring sessions'
{
  for n in 1 2 3 4 5 6 7 8; do echo "contain_start -g 600 $(forever "c10.l$n" ignore)"; done
  cat <<'EOF'
for n in 1 2 3 4 5 6 7 8; do until [ -s "$S/c10.l$n.pid" ]; do sleep 0.1; done; done
touch "$S/c10.started"
t=$SECONDS
st=0; contain_stop_all 5 || st=$?
echo "$st $((SECONDS - t)) ${CONTAIN_SURVIVORS:-}" > "$S/c10.result"
EOF
} | caller c10
run_bg c10
until_true 30 test -e "$S/c10.started" || fail 'the sessions did not start'
leaders=
for n in 1 2 3 4 5 6 7 8; do
  p=$(pid_of "c10.l$n"); leaders="$leaders $p"
  alive "$p" || fail "session $n was not running"
done
until_true 60 test -s "$S/c10.result" || fail 'contain_stop_all did not return'
read -r st took survivors <"$S/c10.result" || :
[ "$st" = 0 ] || fail "contain_stop_all returned $st"
[ "$took" -le 25 ] || fail "contain_stop_all took ${took}s over eight sessions"
[ -z "${survivors:-}" ] || fail "it reported survivors: $survivors"
for p in $leaders; do dead "$p" || fail "leader $p survived"; done

# --- 11: neither setsid nor perl ----------------------------------------------
begin '11 no setsid and no perl: 69, and the caller lives on'
mkdir "$S/bin11"
for tool in bash sleep pgrep pkill kill cat; do ln -s "$(type -P "$tool")" "$S/bin11/$tool"; done
caller c11 <<'EOF'
hash -r
st=0; contain_start sleep 30 || st=$?
echo "$st alive" > "$S/c11.result"
EOF
"${clean_env[@]}" PATH="$S/bin11" "$(type -P bash)" "$S/c11.sh"
[ "$(cat "$S/c11.result")" = '69 alive' ] || fail "got '$(cat "$S/c11.result")', not '69 alive'"

# --- 12: descriptor lists ------------------------------------------------
begin '12 a descriptor list that is not decimal: 64, and nothing runs'
caller c12 <<'EOF'
st=0; CONTAIN_HOLD_FDS=abc contain_start touch "$S/c12.ran" || st=$?
st2=0; CONTAIN_HOLD_FDS="9;touch $S/c12.injected" contain_start touch "$S/c12.ran" || st2=$?
st3=0; CONTAIN_CLOSE_FDS='9 $(touch "$S/c12.injected")' contain_start touch "$S/c12.ran" || st3=$?
echo "$st $st2 $st3" > "$S/c12.result"
EOF
run c12
[ "$(cat "$S/c12.result")" = '64 64 64' ] || fail "got $(cat "$S/c12.result"), not 64 for each list"
[ ! -e "$S/c12.ran" ] && [ ! -e "$S/c12.injected" ] || fail 'a refused start ran something'
no_watchdog_of "$(cat "$S/c12.caller")" || fail 'a refused start left a watchdog'

# --- 13: the session id under job control -----------------------------------
begin '13 CONTAIN_PID is the session id when the caller has set -m'
caller c13 <<'EOF'
set -m
contain_start -g 2 bash -c 'echo $$ > "$S/c13.leader.pid"; exec sleep 300'
case $- in *m*) echo on ;; *) echo off ;; esac > "$S/c13.jobcontrol"
echo "$CONTAIN_PID" > "$S/c13.contain_pid"
until [ -s "$S/c13.leader.pid" ]; do sleep 0.1; done
ps -o sid= -p "$CONTAIN_PID" | tr -d ' ' > "$S/c13.sid"
contain_stop "$CONTAIN_PID" 2
EOF
run c13
cp=$(cat "$S/c13.contain_pid")
[ "$(cat "$S/c13.leader.pid")" = "$cp" ] || fail "CONTAIN_PID $cp is not the command, $(cat "$S/c13.leader.pid")"
[ "$(cat "$S/c13.sid")" = "$cp" ] || fail "the command's session is $(cat "$S/c13.sid"), not CONTAIN_PID $cp"
[ "$(cat "$S/c13.jobcontrol")" = on ] || fail "the caller's job control was not restored"
dead "$cp" || fail 'the command outlived contain_stop'

# --- 14: bad pids ----------------------------------------------------------
begin '14 a bad pid is refused with 64 before any signal'
caller c14 <<'EOF'
r=
for v in '' 0 abc; do
  st=0; contain_stop "$v" 1 || st=$?; r="$r stop[$v]=$st"
  st=0; contain_wait "$v" 1 1 || st=$?; r="$r wait[$v]=$st"
done
for v in '' abc; do st=0; contain_stop_all "$v" || st=$?; r="$r stop_all[$v]=$st"; done
st=0; contain_wait 12345 || st=$?; r="$r wait-no-deadline=$st"
echo "$r survived" > "$S/c14.result"
EOF
# Its own session: pkill -s 0 or pgrep -s '' would end it.
"${clean_env[@]}" setsid bash "$S/c14.sh" || :
want=' stop[]=64 wait[]=64 stop[0]=64 wait[0]=64 stop[abc]=64 wait[abc]=64 stop_all[]=64 stop_all[abc]=64 wait-no-deadline=64 survived'
[ "$(cat "$S/c14.result" 2>/dev/null)" = "$want" ] || fail "got '$(cat "$S/c14.result" 2>/dev/null || echo 'nothing: the shell was killed')'"

# --- 15: set -eu -------------------------------------------------------------
begin '15 the library runs sourced under set -eu'
out=$("${clean_env[@]}" bash -eu -o pipefail -c '. "$LIB"; contain_start true; contain_wait $CONTAIN_PID 5; contain_stop_all 1; contain_sweep_registry 1; echo reached') || :
[ "$out" = reached ] || fail "got '$out'"

# --- 16: the perl fallback ----------------------------------------------------
begin '16 without setsid, perl starts the session leader and the watchdog'
mkdir "$S/bin16"
for tool in bash sleep pgrep pkill kill cat perl ps tr mktemp mkfifo rm; do ln -s "$(type -P "$tool")" "$S/bin16/$tool"; done
caller c16 <<EOF
hash -r
contain_start -g 2 $(forever c16.leader ignore)
echo "\$CONTAIN_PID" > "\$S/c16.contain_pid"
contain_wait "\$CONTAIN_PID" 0
EOF
"${clean_env[@]}" PATH="$S/bin16" "$(type -P bash)" "$S/c16.sh" &
bg=$!
leader=$(pid_of c16.leader)
until_true 10 test -s "$S/c16.contain_pid" || fail 'contain_start did not return'
[ "$(cat "$S/c16.contain_pid")" = "$leader" ] || fail 'CONTAIN_PID is not the command'
[ "$(sid_of "$leader")" = "$leader" ] || fail 'the command does not lead its own session'
[ -n "$(watchdogs_of "$(cat "$S/c16.caller")")" ] || fail 'no watchdog runs'
kill_child "$bg"
until_true $((2 + 15 + 2)) dead "$leader" || fail "perl's watchdog did not stop the session"

# --- 17: the owner's watchdog sweeps ----------------------------------------
begin "17 an owner's watchdog sweeps the registry"
caller c17.nested <<EOF
contain_start -g 600 $(forever c17.leader ignore)
contain_wait "\$CONTAIN_PID" 0
EOF
caller c17 <<'EOF'
contain_registry_create
echo "$CONTAIN_REGISTRY" > "$S/c17.registry"
contain_start -g 2 bash "$S/c17.nested.sh"
contain_wait "$CONTAIN_PID" 0
EOF
run_bg c17
leader=$(pid_of c17.leader)
until_true 10 eval '[ "$(grep -c . "$(cat "$S/c17.registry")")" = 2 ]' || fail 'the registry does not list both sessions'
alive "$leader" || fail 'the nested session was not running'
kill_child "$bg"
t=$SECONDS
until_true $((2 + 15 + 2)) dead "$leader" || fail "the owner's watchdog did not sweep the nested session"
[ $((SECONDS - t)) -le $((2 + 15)) ] || fail "the sweep took $((SECONDS - t))s"
rm -f "$(cat "$S/c17.registry")"

# --- 18: a non-owner's watchdog does not -------------------------------------
begin "18 a non-owner's watchdog leaves the registry alone"
caller c18.nested <<EOF
contain_start -g 2 $(forever c18.own)
contain_wait "\$CONTAIN_PID" 0
EOF
caller c18 <<EOF
contain_registry_create
echo "\$CONTAIN_REGISTRY" > "\$S/c18.registry"
contain_start -g 2 $(forever c18.sibling)
contain_start -g 2 bash "\$S/c18.nested.sh"
# The nested shell's death is announced here unless standard error is
# elsewhere: it is this shell's child.
until [ -e "\$S/c18.go" ]; do sleep 0.1; done 2>/dev/null
contain_stop_all 2
rm -f "\$CONTAIN_REGISTRY"
EOF
run_bg c18
sibling=$(pid_of c18.sibling); own=$(pid_of c18.own)
until_true 10 eval '[ "$(grep -c . "$(cat "$S/c18.registry")")" = 3 ]' || fail 'the registry does not list the three sessions'
nested=$(cat "$S/c18.nested.caller")
kill -KILL "$nested"
until_true $((2 + 15 + 2)) dead "$own" || fail "the nested shell's watchdog did not stop its session"
until_true 20 no_watchdog_of "$nested" || fail "the nested shell's watchdog did not exit"
alive "$sibling" || fail "the nested shell's watchdog swept its sibling"
touch "$S/c18.go"
until_true 30 dead "$sibling" || fail 'the owner did not stop its sibling session'

# --- 19: slots -----------------------------------------------------------------
begin '19 a freed slot is reused, and the 65th live session is refused'
caller c19 <<'EOF'
n=0
while [ $n -lt 65 ]; do
  contain_start true
  contain_wait "$CONTAIN_PID" 10 1
  n=$((n + 1))
done
echo "$n" > "$S/c19.sequential"
n=0
while [ $n -lt 64 ]; do
  contain_start bash -c 'echo $$ >> "$S/c19.leaders"; exec sleep 300' 2>>"$S/c19.stderr"
  n=$((n + 1))
done
last=$CONTAIN_PID
st=0; contain_start touch "$S/c19.ran" 2>>"$S/c19.refused" || st=$?
same=no; [ "$CONTAIN_PID" = "$last" ] && same=yes
touch "$S/c19.started"
until [ -e "$S/c19.go" ]; do sleep 0.1; done
contain_stop_all 2
echo "$st $same" > "$S/c19.result"
EOF
run_bg c19
until_true 120 test -e "$S/c19.started" || fail 'the sessions did not start'
c19=$(cat "$S/c19.caller")
# A leader appends its pid after it has written its session id into its
# watchdog's pipe, so once all 64 have, any lost pipe has shown itself.
until_true 30 eval '[ "$(grep -c . "$S/c19.leaders")" = 64 ]' || fail 'the 64 commands did not all run'
[ ! -s "$S/c19.stderr" ] || fail "starting the 64 sessions said: $(cat "$S/c19.stderr")"
until_true 20 eval '[ "$(watchdogs_of "$c19" | wc -l)" = 64 ]' || fail "$(watchdogs_of "$c19" | wc -l) watchdogs for 64 live sessions"
touch "$S/c19.go"
until_true 60 test -s "$S/c19.result" || fail 'contain_stop_all did not return'
[ "$(cat "$S/c19.sequential")" = 65 ] || fail 'sixty-five sequential sessions did not all start'
[ "$(cat "$S/c19.result")" = '64 yes' ] || fail "the 65th live session got '$(cat "$S/c19.result")', not 64"
[ ! -e "$S/c19.ran" ] || fail 'the refused 65th command ran'
until_true 20 no_watchdog_of "$(cat "$S/c19.caller")" || fail 'watchdogs stayed after contain_stop_all'

# --- 20: survivors -------------------------------------------------------------
begin '20 CONTAIN_SURVIVORS names a process pgrep keeps listing'
sh -c 'echo $$ > "$S/c20.fake.pid"; exec sleep 300' &
fake=$(pid_of c20.fake)
mkdir "$S/bin20"
printf '#!/bin/sh\n%s "$@"\necho %s\nexit 0\n' "$(type -P pgrep)" "$fake" >"$S/bin20/pgrep"
chmod +x "$S/bin20/pgrep"
caller c20 <<EOF
real_path=\$PATH
PATH="\$S/bin20:\$PATH"; hash -r
contain_start -g 1 $(forever c20.leader)
until [ -s "\$S/c20.leader.pid" ]; do sleep 0.1; done
st=0; contain_stop "\$CONTAIN_PID" 0 2>"\$S/c20.stderr" || st=\$?
echo "\$st [\$CONTAIN_SURVIVORS]" > "\$S/c20.first"
until [ -e "\$S/c20.go" ]; do sleep 0.1; done
PATH=\$real_path; hash -r
st=0; contain_stop_all 0 || st=\$?
echo "\$st [\$CONTAIN_SURVIVORS]" > "\$S/c20.second"
EOF
run_bg c20
leader=$(pid_of c20.leader)
until_true 30 test -s "$S/c20.first" || fail 'contain_stop did not return'
[ "$(cat "$S/c20.first")" = "1 [$fake]" ] || fail "got '$(cat "$S/c20.first")', not '1 [$fake]'"
grep -q "$fake" "$S/c20.stderr" || fail 'the survivor was not named on stderr'
dead "$leader" || fail 'the real session was not stopped'
[ -n "$(watchdogs_of "$(cat "$S/c20.caller")")" ] || fail 'the watchdog of a session with a survivor was retired'
touch "$S/c20.go"
until_true 30 test -s "$S/c20.second" || fail 'contain_stop_all did not return'
[ "$(cat "$S/c20.second")" = '0 []' ] || fail "a clean stop after it got '$(cat "$S/c20.second")', not '0 []'"
until_true 10 no_watchdog_of "$(cat "$S/c20.caller")" || fail 'the watchdog stayed after a clean stop'
kill_child "$fake"

# --- 21: a bare stop under set -eu ---------------------------------------------
begin '21 a bare contain_stop_all of a live TERM-ignoring session under set -eu reaches its next line'
out=$("${clean_env[@]}" bash -eu -o pipefail -c '. "$LIB"
  contain_start -g 1 bash -c '"'"'trap "" TERM; echo $$ > "$S/c21.leader.pid"; while :; do sleep 0.2; done'"'"'
  until [ -s "$S/c21.leader.pid" ]; do sleep 0.1; done
  kill -0 "$(cat "$S/c21.leader.pid")" && echo alive > "$S/c21.seen"
  contain_stop_all 1
  echo reached') || :
[ "$(cat "$S/c21.seen" 2>/dev/null)" = alive ] || fail 'the session was not running when it was stopped'
[ "$out" = reached ] || fail "got '$out'"
dead "$(pid_of c21.leader)" || fail 'the session outlived contain_stop_all'

# --- 22: a second registry ---------------------------------------------------
begin '22 a second contain_registry_create returns 64 and changes nothing'
mkdir "$S/tmp22"
caller c22 <<'EOF'
TMPDIR=$S/tmp22
contain_registry_create
first=$CONTAIN_REGISTRY
echo 12345 >> "$first"
st=0; contain_registry_create || st=$?
nested=$(bash -c '. "$LIB"; st=0; contain_registry_create || st=$?; echo "$st $CONTAIN_REGISTRY"')
mark=$(bash -c 'echo "${_contain_registry_owner:-unexported}"')
echo "$st $([ "$CONTAIN_REGISTRY" = "$first" ] && echo same || echo changed) $(stat -c %a "$first") $(cat "$first")" > "$S/c22.result"
echo "$nested" > "$S/c22.nested"
echo "$mark" > "$S/c22.mark"
ls "$S/tmp22" | wc -l | tr -d ' ' > "$S/c22.files"
echo "$first" > "$S/c22.registry"
EOF
run c22
[ "$(cat "$S/c22.result")" = '64 same 600 12345' ] || fail "the owner's second call got '$(cat "$S/c22.result")', not '64 same 600 12345'"
[ "$(cat "$S/c22.nested")" = "64 $(cat "$S/c22.registry")" ] || fail "a nested shell's call got '$(cat "$S/c22.nested")'"
[ "$(cat "$S/c22.mark")" = unexported ] || fail 'the owner mark reached a child process'
[ "$(cat "$S/c22.files")" = 1 ] || fail "$(cat "$S/c22.files") registries were created, not 1"

# --- 23: a subshell of the owner ---------------------------------------------
begin "23 a subshell of the owner that dies leaves the owner's live sessions alone"
caller c23 <<'EOF'
contain_registry_create
echo "$CONTAIN_REGISTRY" > "$S/c23.registry"
contain_start -g 1 bash -c 'trap "" TERM; echo $$ > "$S/c23.sibling.pid"; while :; do sleep 0.2; done'
(
  contain_start -g 1 bash -c 'echo $$ > "$S/c23.sub.pid"; exec sleep 300'
  until [ -s "$S/c23.sub.pid" ]; do sleep 0.1; done
  read -r me _ </proc/self/stat
  kill -KILL "$me"
) || :
until [ -e "$S/c23.go" ]; do sleep 0.1; done 2>/dev/null
contain_stop_all 1
rm -f "$CONTAIN_REGISTRY"
EOF
run_bg c23
sibling=$(pid_of c23.sibling); sub=$(pid_of c23.sub)
owner=$(cat "$S/c23.caller")
alive "$sibling" || fail "the owner's session was not running"
until_true $((1 + 15 + 2)) dead "$sub" || fail "the subshell's watchdog did not stop the subshell's session"
# The subshell's watchdog has finished once only the sibling's remains.
until_true 30 eval '[ "$(watchdogs_of "$owner" | wc -l)" = 1 ]' || fail "the subshell's watchdog did not exit"
alive "$owner" || fail 'the owner died'
alive "$sibling" || fail "the subshell's watchdog swept the live owner's registry"
touch "$S/c23.go"
until_true 30 dead "$sibling" || fail 'the owner did not stop its session'

echo 'contain tests passed'
