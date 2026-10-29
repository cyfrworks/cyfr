#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Process containment: the one place the harness starts, bounds and stops
# a command. Source it (Bash 3.2 or later); executed, it is a watchdog.
#
#   contain_start [-g GRACE_S] CMD...
#       Starts CMD, an executable (or `bash -c ...`, never a shell
#       function), as the leader of a new session and sets CONTAIN_PID,
#       which is also the session id, and CONTAIN_WATCHDOG, the pid of the
#       session's watchdog, which the watchdog reports itself once it
#       runs: a run is over only when its session is empty and that pid
#       has exited. Before the exec it closes the
#       descriptors in CONTAIN_CLOSE_FDS and every watchdog pipe. It also
#       starts a watchdog in a session of its own that ignores INT, TERM
#       and HUP, writes nothing, keeps the descriptors in CONTAIN_HOLD_FDS
#       open and reads a pipe whose only writer is the caller. When that
#       pipe closes without the caller having retired it, because the
#       caller exited or was killed, the watchdog runs contain_stop on the
#       session with GRACE_S (default 30); started from the registry's
#       owner, or a subshell of it, it then also runs
#       contain_sweep_registry with GRACE_S, but only once the owner shell
#       itself is gone, so a subshell that dies leaves the owner's other
#       sessions alone. Then it exits and releases the held descriptors.
#       The session id is appended to $CONTAIN_REGISTRY when that names a
#       file.
#       Returns 0; 64 on usage, a non-numeric descriptor list or no free
#       slot; 69 when neither setsid (util-linux) nor perl is on PATH, and
#       the caller then exits 69; 1 when the pipe cannot be opened or the
#       watchdog does not report its pid within 10 s.
#   contain_wait PID DEADLINE_S [GRACE_S]
#       Waits for the leader; a DEADLINE_S of 0 means no deadline. At the
#       deadline it runs contain_stop PID GRACE_S and returns 124.
#       Otherwise it reaps the leader, sweeps the session's leftovers with
#       contain_stop and returns the leader's status, whatever the sweep
#       found. Returns within DEADLINE_S + GRACE_S + 15 s.
#   contain_stop PID [GRACE_S]
#       TERM to the leader alone and up to GRACE_S (default 30) for it to
#       exit, so its own traps stop its dependents first; TERM to the rest
#       of the session and up to 5 s; KILL to the session; the leader
#       reaped. Returns 0 once no process remains in the session within
#       10 s, else 1, naming the survivors on stderr. Returns within
#       GRACE_S + 15 s.
#   contain_stop_all [GRACE_S]
#       Stops every session this shell started and has not yet seen
#       empty, all at once: one shared grace and the same phases as
#       contain_stop. Returns within GRACE_S + 15 s whatever the number of
#       sessions; 1 if any session keeps a survivor.
#   contain_sweep_registry [GRACE_S]
#       Stops every session listed in $CONTAIN_REGISTRY that still has a
#       process, as contain_stop_all does. Blank, malformed and repeated
#       lines and the sweeper's own session are skipped.
#   contain_registry_create
#       Creates the registry as a private file (mode 0600), exports
#       CONTAIN_REGISTRY and marks this shell, in a variable it does not
#       export, as the owner whose watchdogs sweep. The owner is the
#       shell's $$, so a wrapper calls it from its main shell, never from
#       a subshell. With CONTAIN_REGISTRY already set it does nothing and
#       returns 64: the shell is a nested wrapper, which appends to the
#       outer registry and never sweeps it.
#
# Every stop and wait function sets CONTAIN_SURVIVORS to the pids that
# outlived KILL, space-separated, and empty when the stop was clean.
# Callers read survivors from it, never from stderr; contain_wait's status
# stays the leader's. A PID, deadline or grace that is not a decimal number
# (and a PID of 0, which pgrep and pkill read as their own session) is
# refused with 64 before any signal. No function exits the calling shell.
#
# Stopped means the leader is reaped and no process remains in its
# session. A process that calls setsid() itself is outside every contained
# session and is never stopped.
#
# Watchdog pipes are FIFOs whose paths are removed once both ends are
# open. Each takes one slot of 64 fixed descriptors from CONTAIN_FD_BASE
# (default 20, so 20-83; at least 10); opening one also uses, for a
# moment, the first free descriptor above the range. A slot is freed once
# its session is confirmed empty, and then the caller retires its watchdog
# by writing `done` to the pipe and closing it, so no watchdog acts on a
# reused session id. Callers keep their own descriptors out of the range.
# A child the caller starts outside contain_start inherits the pipes, and
# while it lives a watchdog whose caller died cannot fire: a long-lived
# child is started with contain_start. The watchdog is not the caller's
# child; the leader is, so a bare `wait` waits for every live session.

if ! declare -F contain_start >/dev/null 2>&1; then
  case ${BASH_SOURCE[0]} in
    /*) _contain_lib=${BASH_SOURCE[0]} ;;
    *) _contain_lib=$PWD/${BASH_SOURCE[0]} ;;
  esac
  _contain_slot_pid=()
  _contain_slot_fd=()
  _contain_registry_owner=
  CONTAIN_SURVIVORS=
fi

# --- helpers ---------------------------------------------------------------

# A pid the functions accept: decimal and never 0.
_contain_pid_ok() {
  case ${1:-} in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 10 ]
}

# Seconds: decimal, at most six digits. Sets _contain_v to the value.
_contain_secs_ok() {
  case ${1:-} in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 6 ] || return 1
  _contain_v=$((10#$1))
}

# The clock, in deciseconds. /proc/uptime only moves forward; SECONDS is
# the whole-second fallback.
_contain_now() {
  local up rest
  if read -r up rest 2>/dev/null </proc/uptime; then
    case $up in
      *.*) rest=${up#*.}; _contain_t=$((10#${up%%.*} * 10 + 10#${rest:0:1})); return 0 ;;
    esac
  fi
  _contain_t=$((SECONDS * 10))
}

# Whether a process exists and has not exited; a zombie has exited.
_contain_alive() {
  local s
  if [ -r /proc/self/stat ]; then
    read -r s 2>/dev/null <"/proc/$1/stat" || return 1
    s=${s##*) }
    case $s in Z*|X*|x*) return 1 ;; esac
    return 0
  fi
  s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  s=${s// /}
  case $s in ''|Z*|X*) return 1 ;; esac
  return 0
}

# Sets _contain_m to the live processes of session $1, space-separated.
# pgrep and pkill are called by name, never through `command`: under
# set -e Bash 3.2 exits when `command` runs a program that fails, even
# inside `|| :`.
_contain_members() {
  local out p IFS=$' \t\n'
  _contain_m=
  out=$(pgrep -s "$1" 2>/dev/null) || :
  for p in $out; do
    case $p in ''|*[!0-9]*) continue ;; esac
    if _contain_alive "$p"; then _contain_m="$_contain_m $p"; fi
  done
  _contain_m=${_contain_m# }
}

_contain_leaders_gone() {
  local p
  for p in "$@"; do
    if _contain_alive "$p"; then return 1; fi
  done
  return 0
}

_contain_sessions_empty() {
  local p
  for p in "$@"; do
    _contain_members "$p"
    [ -z "$_contain_m" ] || return 1
  done
  return 0
}

# Polls CONDITION ARGS... every 0.1 s until it holds; 1 once the clock
# reaches END (deciseconds).
_contain_poll_until() {
  local end=$1
  shift
  while ! "$@"; do
    _contain_now
    [ "$_contain_t" -lt "$end" ] || return 1
    sleep 0.1
  done
}

# Reaps each leader that has exited, if it is this shell's child.
_contain_reap() {
  local p
  for p in "$@"; do
    if ! _contain_alive "$p"; then wait "$p" 2>/dev/null || :; fi
  done
}

# Frees the slot of session $1 and retires its watchdog. Only called once
# the session is confirmed empty.
_contain_retire() {
  local i=0 fd
  while [ "$i" -lt 64 ]; do
    if [ "${_contain_slot_pid[$i]:-}" = "$1" ]; then
      fd=${_contain_slot_fd[$i]:-}
      case $fd in ''|*[!0-9]*) ;; *)
        eval "printf 'done\n' >&$fd" 2>/dev/null || :
        eval "exec $fd>&-" 2>/dev/null || :
      esac
      _contain_slot_pid[$i]=
      _contain_slot_fd[$i]=
      return 0
    fi
    i=$((i + 1))
  done
}

# The phases of a stop of the sessions led by $2..., with the shared
# grace $1. Every phase deadline counts from the start, so the whole stop
# ends within the grace plus 15 s. Its caller discards its standard error,
# where Bash would announce each leader a signal ended.
_contain_stop_phases() {
  local grace=$1 p t0 end any
  shift
  _contain_now
  t0=$_contain_t

  any=
  for p in "$@"; do
    if _contain_alive "$p"; then
      kill -TERM "$p" 2>/dev/null || :
      any=1
    fi
  done
  if [ -n "$any" ]; then
    _contain_poll_until $((t0 + grace * 10)) _contain_leaders_gone "$@" || :
  fi
  _contain_reap "$@"

  any=
  for p in "$@"; do
    _contain_members "$p"
    if [ -n "$_contain_m" ]; then
      pkill -TERM -s "$p" 2>/dev/null || :
      any=1
    fi
  done
  if [ -n "$any" ]; then
    _contain_now
    end=$((_contain_t + 50))
    [ "$end" -le $((t0 + grace * 10 + 50)) ] || end=$((t0 + grace * 10 + 50))
    _contain_poll_until "$end" _contain_sessions_empty "$@" || :
  fi

  any=
  for p in "$@"; do
    _contain_members "$p"
    if [ -n "$_contain_m" ]; then
      pkill -KILL -s "$p" 2>/dev/null || :
      any=1
    fi
  done
  _contain_reap "$@"
  if [ -n "$any" ]; then
    _contain_poll_until $((t0 + grace * 10 + 150)) _contain_sessions_empty "$@" || :
  fi
  _contain_reap "$@"
}

# Stops the sessions led by $2... together, with the shared grace $1, and
# sets CONTAIN_SURVIVORS.
_contain_stop_set() {
  local p survivors= status=0
  _contain_stop_phases "$@" 2>/dev/null
  shift
  for p in "$@"; do
    _contain_members "$p"
    if [ -n "$_contain_m" ]; then
      echo "contain: session $p keeps $_contain_m after KILL" >&2
      survivors="$survivors $_contain_m"
      status=1
    else
      _contain_retire "$p"
    fi
  done
  CONTAIN_SURVIVORS=${survivors# }
  return "$status"
}

# Sets _contain_sid to the session id of this shell.
_contain_own_sid() {
  local s IFS=$' \t\n'
  _contain_sid=
  if read -r s 2>/dev/null <"/proc/$$/stat"; then
    s=${s##*) }
    set -- $s
    _contain_sid=${4:-}
  else
    s=$(ps -o sid= -p "$$" 2>/dev/null) || :
    _contain_sid=${s// /}
  fi
}

# The child side of contain_start: close what CMD must not hold, become a
# session leader, write the session id into this session's watchdog pipe
# ($1), close it, and exec CMD.
_contain_child() {
  local fd=$1 n i=0 IFS=$' \t\n'
  shift
  for n in ${CONTAIN_CLOSE_FDS:-}; do eval "exec $n>&-" 2>/dev/null || :; done
  while [ "$i" -lt 64 ]; do
    n=$((_contain_b + i))
    [ "$n" = "$fd" ] || eval "exec $n>&-" 2>/dev/null || :
    i=$((i + 1))
  done
  # --posix keeps BASH_ENV from running in the leader.
  exec "${_contain_setsid[@]}" "$BASH" --posix -c \
    'printf "%s\n" "$$" >&'"$fd"'; exec '"$fd"'>&-; exec "$@"' contain-leader "$@"
}

# Starts the watchdog of slot descriptor $1 and sets CONTAIN_WATCHDOG to
# its pid. The pipe is a FIFO: Bash 3.2 leaves an open descriptor
# unchanged under `exec N> >(...)`. The caller opens it read-write, so the
# open never blocks and the read end opened next finds a writer at once;
# the path is gone before the watchdog runs, and the caller's descriptor
# is its only writer. The watchdog is a grandchild, so a bare `wait` in
# the caller never waits for it, and its pid is known only from the
# watchdog itself, which writes it on a second FIFO, its standard output,
# before anything else (setsid may fork, so no pid seen here would do).
_contain_open_pipe() {
  local fd=$1 dir tmp report pid=
  CONTAIN_WATCHDOG=
  dir=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/contain.XXXXXX" 2>/dev/null) || return 1
  if ! mkfifo "$dir/w" "$dir/r" 2>/dev/null || ! eval "exec $fd<>\"\$dir/w\""; then
    rm -rf "$dir"
    return 1
  fi
  report=$((_contain_b + 64))
  while [ -e "/dev/fd/$report" ] && [ "$report" -lt $((_contain_b + 320)) ]; do report=$((report + 1)); done
  if [ -e "/dev/fd/$report" ] || ! eval "exec $report<>\"\$dir/r\""; then
    eval "exec $fd>&-" 2>/dev/null || :
    rm -rf "$dir"
    return 1
  fi
  tmp=$((report + 1))
  while [ -e "/dev/fd/$tmp" ] && [ "$tmp" -lt $((_contain_b + 320)) ]; do tmp=$((tmp + 1)); done
  if [ -e "/dev/fd/$tmp" ] || ! eval "exec $tmp<\"\$dir/w\""; then
    eval "exec $fd>&- $report>&-" 2>/dev/null || :
    rm -rf "$dir"
    return 1
  fi
  rm -rf "$dir"
  eval "(_contain_watchdog_exec 0<&$tmp 1>&$report $report>&- &)"
  eval "exec $tmp<&-"
  eval "IFS= read -r -t 10 pid <&$report" 2>/dev/null || pid=
  eval "exec $report>&-"
  if ! _contain_pid_ok "$pid"; then
    eval "exec $fd>&-" 2>/dev/null || :
    return 1
  fi
  CONTAIN_WATCHDOG=$pid
}

# The watchdog's exec; its standard input is the read end of the pipe.
_contain_watchdog_exec() {
  exec "${_contain_setsid[@]}" "$BASH" --posix "$_contain_lib" __contain_watchdog \
    "$_contain_w_grace" "$_contain_w_owner" "$_contain_b" "${CONTAIN_HOLD_FDS:-}" \
    "${CONTAIN_REGISTRY:-}" "$$" 2>/dev/null
}

# The watchdog: GRACE OWNER BASE HOLD_FDS REGISTRY CALLER, where OWNER is
# the registry owner's pid when the caller is that shell or a subshell of
# it, else 0. It holds only the read end of its pipe and the held
# descriptors. The first line is the session id the leader wrote; `done`
# retires it; end of file after the id means the caller is gone. It sweeps
# the registry only once the owner itself is gone too: a subshell of the
# owner that dies leaves the owner's other sessions to the owner.
_contain_watch() {
  local grace=$1 owner=$2 base=$3 hold=$4 registry=$5 f n sid= line
  trap '' INT TERM HUP
  for f in /dev/fd/*; do
    n=${f##*/}
    case $n in ''|*[!0-9]*|0|1|2) continue ;; esac
    if [ "$n" -lt "$base" ] || [ "$n" -gt $((base + 63)) ]; then
      case " $hold " in *" $n "*) continue ;; esac
    fi
    eval "exec $n>&-" 2>/dev/null || :
  done
  IFS= read -r sid || return 0
  _contain_pid_ok "$sid" || return 0
  while IFS= read -r line; do
    [ "$line" != done ] || return 0
  done
  contain_stop "$sid" "$grace" || :
  if _contain_pid_ok "$owner" && [ -n "$registry" ] && ! _contain_alive "$owner"; then
    CONTAIN_REGISTRY=$registry contain_sweep_registry "$grace" || :
  fi
  return 0
}

_contain_base_ok() {
  local b=${CONTAIN_FD_BASE:-20}
  case $b in ''|*[!0-9]*) ;; *)
    if [ "${#b}" -le 4 ] && [ "$((10#$b))" -ge 10 ]; then
      _contain_b=$((10#$b))
      return 0
    fi ;;
  esac
  echo "contain_start: CONTAIN_FD_BASE is a decimal descriptor of 10 or more: $b" >&2
  return 1
}

# --- the functions ---------------------------------------------------------

contain_start() {
  local grace=30 i=0 fd m= IFS=$' \t\n'
  if [ "${1:-}" = -g ]; then
    [ "$#" -ge 2 ] || { echo 'usage: contain_start [-g GRACE_S] CMD...' >&2; return 64; }
    grace=$2
    shift 2
  fi
  _contain_secs_ok "$grace" || { echo "contain_start: the grace is decimal seconds: $grace" >&2; return 64; }
  grace=$_contain_v
  [ "$#" -ge 1 ] || { echo 'usage: contain_start [-g GRACE_S] CMD...' >&2; return 64; }
  # The lists pass through eval: digits and spaces only.
  case ${CONTAIN_CLOSE_FDS:-} in *[!0-9\ ]*)
    echo "contain_start: CONTAIN_CLOSE_FDS is not a list of descriptors: $CONTAIN_CLOSE_FDS" >&2
    return 64 ;;
  esac
  case ${CONTAIN_HOLD_FDS:-} in *[!0-9\ ]*)
    echo "contain_start: CONTAIN_HOLD_FDS is not a list of descriptors: $CONTAIN_HOLD_FDS" >&2
    return 64 ;;
  esac
  _contain_base_ok || return 64
  if command -v setsid >/dev/null 2>&1; then
    _contain_setsid=(setsid)
  elif command -v perl >/dev/null 2>&1; then
    _contain_setsid=(perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec @ARGV or die "exec $ARGV[0]: $!\n"')
  else
    echo 'contain_start: needs setsid (util-linux) or perl' >&2
    return 69
  fi
  while [ "$i" -lt 64 ] && [ -n "${_contain_slot_pid[$i]:-}" ]; do i=$((i + 1)); done
  if [ "$i" -ge 64 ]; then
    echo "contain_start: all 64 watchdog descriptors from $_contain_b are in use" >&2
    return 64
  fi
  fd=$((_contain_b + i))
  _contain_w_grace=$grace
  _contain_w_owner=0
  if [ -n "${_contain_registry_owner:-}" ] && [ -n "${CONTAIN_REGISTRY:-}" ]; then
    _contain_w_owner=$_contain_registry_owner
  fi

  # With job control on, the child would lead a process group of its own
  # and setsid would fork, so the pid known here would not be the session.
  case $- in *m*) m=1; set +m ;; esac
  if ! _contain_open_pipe "$fd"; then
    if [ -n "$m" ]; then set -m; fi
    echo 'contain_start: could not start the watchdog' >&2
    return 1
  fi
  # An asynchronous command reads /dev/null unless told otherwise.
  if { true <&0; } 2>/dev/null; then
    _contain_child "$fd" "$@" <&0 &
  else
    _contain_child "$fd" "$@" &
  fi
  CONTAIN_PID=$!
  if [ -n "$m" ]; then set -m; fi
  _contain_slot_pid[$i]=$CONTAIN_PID
  _contain_slot_fd[$i]=$fd
  if [ -n "${CONTAIN_REGISTRY:-}" ] && [ -f "$CONTAIN_REGISTRY" ]; then
    printf '%s\n' "$CONTAIN_PID" >>"$CONTAIN_REGISTRY" 2>/dev/null || :
  fi
  return 0
}

contain_wait() {
  local pid=${1:-} deadline grace=30 status=0
  CONTAIN_SURVIVORS=
  if [ "$#" -ge 3 ]; then grace=$3; fi
  if ! _contain_pid_ok "$pid" || [ "$#" -lt 2 ] || ! _contain_secs_ok "$2"; then
    echo 'usage: contain_wait PID DEADLINE_S [GRACE_S]' >&2
    return 64
  fi
  deadline=$_contain_v
  _contain_secs_ok "$grace" || { echo 'usage: contain_wait PID DEADLINE_S [GRACE_S]' >&2; return 64; }
  grace=$_contain_v
  if ! _contain_await_leader "$pid" "$deadline" 2>/dev/null; then
    contain_stop "$pid" "$grace" || :
    return 124
  fi
  wait "$pid" 2>/dev/null || status=$?
  contain_stop "$pid" "$grace" || :
  return "$status"
}

# Polls until leader $1 has exited; 1 at the deadline of $2 seconds (0:
# none). Its caller discards its standard error, as for the stop phases.
_contain_await_leader() {
  local t0
  _contain_now
  t0=$_contain_t
  while _contain_alive "$1"; do
    if [ "$2" -gt 0 ]; then
      _contain_now
      [ "$_contain_t" -lt $((t0 + $2 * 10)) ] || return 1
    fi
    sleep 0.1
  done
}

contain_stop() {
  local pid=${1:-} grace=30
  CONTAIN_SURVIVORS=
  if [ "$#" -ge 2 ]; then grace=$2; fi
  if ! _contain_pid_ok "$pid" || ! _contain_secs_ok "$grace"; then
    echo 'usage: contain_stop PID [GRACE_S]' >&2
    return 64
  fi
  _contain_stop_set "$_contain_v" "$pid"
}

contain_stop_all() {
  local grace=30 pids= i=0 IFS=$' \t\n'
  CONTAIN_SURVIVORS=
  if [ "$#" -ge 1 ]; then grace=$1; fi
  _contain_secs_ok "$grace" || { echo 'usage: contain_stop_all [GRACE_S]' >&2; return 64; }
  grace=$_contain_v
  while [ "$i" -lt 64 ]; do
    if [ -n "${_contain_slot_pid[$i]:-}" ]; then pids="$pids ${_contain_slot_pid[$i]}"; fi
    i=$((i + 1))
  done
  [ -n "$pids" ] || return 0
  _contain_stop_set "$grace" $pids
}

contain_sweep_registry() {
  local grace=30 line pids= IFS=$' \t\n'
  CONTAIN_SURVIVORS=
  if [ "$#" -ge 1 ]; then grace=$1; fi
  _contain_secs_ok "$grace" || { echo 'usage: contain_sweep_registry [GRACE_S]' >&2; return 64; }
  grace=$_contain_v
  if [ -z "${CONTAIN_REGISTRY:-}" ] || [ ! -f "$CONTAIN_REGISTRY" ]; then return 0; fi
  _contain_own_sid
  while IFS= read -r line || [ -n "$line" ]; do
    _contain_pid_ok "$line" || continue
    [ "$line" != "$_contain_sid" ] || continue
    case " $pids " in *" $line "*) continue ;; esac
    _contain_members "$line"
    [ -n "$_contain_m" ] || continue
    pids="$pids $line"
  done <"$CONTAIN_REGISTRY"
  [ -n "$pids" ] || return 0
  _contain_stop_set "$grace" $pids
}

contain_registry_create() {
  local file
  if [ -n "${CONTAIN_REGISTRY:-}" ]; then
    echo 'contain_registry_create: CONTAIN_REGISTRY is already set, so this shell is a nested wrapper' >&2
    return 64
  fi
  file=$(umask 077 && mktemp "${TMPDIR:-/tmp}/contain-registry.XXXXXX") || return 1
  chmod 600 "$file" || { rm -f "$file"; return 1; }
  CONTAIN_REGISTRY=$file
  export CONTAIN_REGISTRY
  _contain_registry_owner=$$
  export -n _contain_registry_owner 2>/dev/null || :
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = __contain_watchdog ]; then
    shift
    # Its pid to the caller (contain_start's CONTAIN_WATCHDOG), then
    # nothing more: the watchdog writes nothing else.
    printf '%s\n' "$$"
    exec >/dev/null
    _contain_watch "$@"
    exit 0
  fi
  echo 'scripts/lib/contain.sh is sourced: . scripts/lib/contain.sh' >&2
  exit 64
fi
