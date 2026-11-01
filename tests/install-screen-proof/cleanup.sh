# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# The install-and-screen proof's ownership, exit traps and teardown,
# sourced by tests/install-screen-proof/run.sh, after
# scripts/lib/run-names.sh. It reads PROOF_PREFIX, which starts as
# PROOF_RUN_PREFIX, and PROOF_WORK, and calls docker.
#
# Every name the run gives Docker begins with PROOF_PREFIX, which must be a
# whole prefix of RUN_NAMES_PATTERN (cyfr-<seed>-<pid>-), so janitor rule 1
# removes what a killed run leaves; it is assigned from PROOF_RUN_PREFIX
# alone, so the commit gate's container-name check
# (tests/commit-gate-test.sh) traces each --name made from it to the run
# prefix. proof_own records a container or volume before it is made, and
# refuses, recording nothing, without such a prefix or for a name outside
# it; proof_watch records a background process. The
# teardown removes what was recorded and nothing else: not another run's
# names, nor a name the run did not record, nor the proof image the
# containers run, which every run shares (prepare.sh).
#
# Every long command runs through proof_fg, and every container whose first
# process is a script runs with --init, which passes TERM on: a docker
# client in the foreground would hold the run's trap until its container
# ended, and a script as a container's first process ignores TERM.
#
# proof_traps sets the EXIT, INT, TERM and HUP traps. Every exit then runs
# the teardown and writes `_EXIT=<pid> <status>` last on stdout: 130, 143
# or 129 after a signal, else the run's own status, made 1 when the run
# passed but the teardown left something. A signal the run started with
# ignored stays ignored, since a shell cannot trap it: a non-interactive
# shell starts every asynchronous command with INT and QUIT ignored, and
# heavy-check's contain.sh starts its command so. heavy-check stops a run
# with TERM, which such a run still traps. The teardown goes in
# dependency order and ignores further signals: the watchers stop; each
# guest's shared SSH connection (PROOF_SSH_CONTROLS, a control socket)
# ends; each guest stops (QEMU quits through QMP, then its container
# stops), and its /case evidence and QEMU's log are copied to the
# directory recorded with it; then the containers go, then the volume they
# mounted, each removal tried three times PROOF_CLEANUP_PAUSE seconds
# apart (default 3), one that still fails named on stderr; then
# PROOF_WORK, the run's scratch directory. Evidence directories stay.

PROOF_PREFIX=${PROOF_RUN_PREFIX:-}
PROOF_WORK=${PROOF_WORK:-}
PROOF_QMP_SOCKET=/run/proof/qmp.sock
PROOF_CONTAINERS=() PROOF_VOLUMES=() PROOF_WATCHERS=() PROOF_SSH_CONTROLS=()
declare -A PROOF_EVIDENCE=() PROOF_STOPPED=()

# Whether $1 is a whole run prefix: cyfr-<seed>-<pid>-.
proof_prefix_valid() {
  [[ ${1:-} =~ ${RUN_NAMES_PATTERN}$ ]]
}

# Records the container or volume ($1) named $2 as the run's, before it is
# made; a container's evidence goes to the directory $3.
proof_own() {
  local kind=$1 name=$2
  if ! proof_prefix_valid "$PROOF_PREFIX"; then
    echo "::error::install-screen proof: '$PROOF_PREFIX' is no run prefix (cyfr-<seed>-<pid>-); $kind $name is not made" >&2
    return 1
  fi
  case $name in
    "$PROOF_PREFIX"?*) ;;
    *)
      echo "::error::install-screen proof: $kind $name is outside the run's prefix $PROOF_PREFIX" >&2
      return 1
      ;;
  esac
  case $kind in
    container)
      PROOF_CONTAINERS+=("$name")
      [ -z "${3:-}" ] || PROOF_EVIDENCE[$name]=$3
      ;;
    volume) PROOF_VOLUMES+=("$name") ;;
    *)
      echo "::error::install-screen proof: no kind $kind" >&2
      return 1
      ;;
  esac
}

# Records the background process $1, stopped before any guest.
proof_watch() {
  PROOF_WATCHERS+=("$1")
}

# Runs "$@" as a background job, its standard input the caller's, and
# waits for it: a signal then runs the run's trap at once, where a
# foreground command would hold the trap until it ended, and heavy-check's
# KILL would come first. The job is a watcher until it ends, so the
# teardown stops it before any guest. Answers the command's status.
proof_fg() {
  local pid status kept=() w
  "$@" 0<&0 &
  pid=$!
  PROOF_WATCHERS+=("$pid")
  wait "$pid"
  status=$?
  for w in ${PROOF_WATCHERS[@]+"${PROOF_WATCHERS[@]}"}; do
    [ "$w" = "$pid" ] || kept+=("$w")
  done
  PROOF_WATCHERS=(${kept[@]+"${kept[@]}"})
  return "$status"
}

# Whether the process $1 has not exited; a zombie has.
proof_alive() {
  local stat
  stat=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  case $stat in '' | *Z*) return 1 ;; esac
}

# Stops the guest of the container $1 if it runs, QEMU first through QMP
# and then the container, each within 30 s; with $2, then copies the
# container's /case and QEMU's log into $2. A stopped guest is not stopped
# again.
proof_guest_stop() {
  local name=$1 dir=${2:-}
  [ -z "${PROOF_STOPPED[$name]:-}" ] || return 0
  if [ "$(docker container inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" = true ]; then
    timeout 30 docker exec "$name" python3 /proof/qmp.py "$PROOF_QMP_SOCKET" quit >/dev/null 2>&1 || true
    timeout 30 docker stop --time 15 "$name" >/dev/null 2>&1 || true
  fi
  if [ -n "$dir" ] && docker container inspect "$name" >/dev/null 2>&1; then
    mkdir -p "$dir"
    docker cp "$name:/case/." "$dir/" >/dev/null 2>&1 ||
      echo "install-screen proof: the evidence of $name was not copied to $dir" >&2
    docker logs "$name" >"$dir/qemu.log" 2>&1 || true
  fi
  PROOF_STOPPED[$name]=1
}

# Removes the container or volume ($1) named $2, or finds it gone. Each
# kind's inspection and removal is spelled out, so no docker command takes
# its verb from a variable.
proof_gone() {
  local kind=$1 name=$2 attempt err=""
  case $name in
    "$PROOF_PREFIX"?*) ;;
    *)
      echo "::error::install-screen proof cleanup: $kind $name is outside the run's prefix; it stays" >&2
      return 1
      ;;
  esac
  for attempt in 1 2 3; do
    case $kind in
      container)
        err=$(docker container inspect "$name" 2>&1 >/dev/null) || case $err in *"No such"* | *"no such"*) return 0 ;; esac
        err=$(docker container rm --force "$name" 2>&1 >/dev/null) && return 0
        ;;
      volume)
        err=$(docker volume inspect "$name" 2>&1 >/dev/null) || case $err in *"No such"* | *"no such"*) return 0 ;; esac
        err=$(docker volume rm "$name" 2>&1 >/dev/null) && return 0
        ;;
    esac
    [ "$attempt" = 3 ] || sleep "${PROOF_CLEANUP_PAUSE:-3}"
  done
  echo "::error::install-screen proof cleanup: the $kind $name is left on this host: ${err:0:400}" >&2
  return 1
}

# The teardown; answers 1 when something it owns is left.
proof_cleanup() {
  local failed="" pid name i closes
  for pid in ${PROOF_WATCHERS[@]+"${PROOF_WATCHERS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in ${PROOF_WATCHERS[@]+"${PROOF_WATCHERS[@]}"}; do
    closes=$((SECONDS + 10))
    while proof_alive "$pid" && [ "$SECONDS" -lt "$closes" ]; do
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  PROOF_WATCHERS=()
  # Each guest's shared SSH connection ends before its guest stops.
  for name in ${PROOF_SSH_CONTROLS[@]+"${PROOF_SSH_CONTROLS[@]}"}; do
    [ -S "$name" ] && timeout 10 ssh -F /dev/null -o "ControlPath=$name" -O exit proof-guest >/dev/null 2>&1 || true
  done
  PROOF_SSH_CONTROLS=()
  for ((i = ${#PROOF_CONTAINERS[@]} - 1; i >= 0; i--)); do
    name=${PROOF_CONTAINERS[i]}
    proof_guest_stop "$name" "${PROOF_EVIDENCE[$name]:-}"
  done
  for name in ${PROOF_CONTAINERS[@]+"${PROOF_CONTAINERS[@]}"}; do
    proof_gone container "$name" || failed=1
  done
  for name in ${PROOF_VOLUMES[@]+"${PROOF_VOLUMES[@]}"}; do
    proof_gone volume "$name" || failed=1
  done
  if [ -n "$PROOF_WORK" ]; then
    rm -rf -- "$PROOF_WORK" || failed=1
  fi
  [ -z "$failed" ]
}

proof_finish() {
  local status=$?
  trap - EXIT
  trap '' INT TERM HUP
  if ! proof_cleanup && [ "$status" -eq 0 ]; then
    status=1
  fi
  printf '_EXIT=%s %s\n' "$$" "$status"
  exit "$status"
}

proof_traps() {
  trap proof_finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}
