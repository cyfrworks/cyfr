#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The install-and-screen proof's teardown (tests/install-screen-proof/
# cleanup.sh) against a stand-in for docker, with no Docker and no VM. A
# driver sources the teardown as run.sh does, records and makes the image,
# the disk volume, a running guest, a stopped guest and a container it
# records but never makes, starts a watcher, and then exits 0, exits 1, or
# waits for INT, TERM or HUP. Each way, the teardown must end the watcher,
# stop the running guest through QMP before its container goes, copy its
# evidence out, remove the containers before the volume they mount and the
# volume before the image, remove the scratch directory, keep the evidence
# directory, keep the run's status and frame stdout; and it must leave every
# other run's names and every unrelated name alone, including those the
# driver asks to own. TERM while a long docker command runs that TERM does
# not end, as a foreground `docker run` of a container whose first process
# ignores it, still tears the run down at once. A removal that keeps
# failing fails a passed run,
# naming what it leaves; one that succeeds within three attempts does not.
# run.sh refuses an empty or malformed PROOF_RUN_PREFIX before it makes
# anything.
#
# Usage: bash tests/install-screen-proof/cleanup-test.sh
# Env: INSTALL_SCREEN_CLEANUP, a teardown to test in place of cleanup.sh,
# which is how a deliberately broken one is shown failing here.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
teardown=${INSTALL_SCREEN_CLEANUP:-$here/cleanup.sh}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-install-screen-cleanup-test.XXXXXX") || {
  echo "FAIL: cannot create a temporary directory"
  exit 1
}
driver_pid=""
# Every driver's watcher is listed in $scratch/watchers, so one a broken
# teardown leaves still ends here.
finish() {
  local pid
  [ -z "$driver_pid" ] || kill -KILL "$driver_pid" 2>/dev/null || true
  for pid in $(cat "$scratch/watchers" 2>/dev/null); do
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$scratch"
}
trap finish EXIT

# The stand-in for docker: objects are files under $STUB, every call is a
# line of $STUB/calls, and each removal and stop is a line of $STUB/events,
# in order. STUB_FAIL_<KIND>_RM=n refuses the first n removals of a kind.
mkdir -p "$scratch/bin"
cat >"$scratch/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -u
echo "$*" >>"$STUB/calls"
key() { printf '%s' "$1" | tr '/:' '%+'; }
refused() {
  local budget
  budget=$(printenv "STUB_FAIL_$1" || echo 0)
  echo "$1" >>"$STUB/refusals"
  [ "$(grep -cx "$1" "$STUB/refusals")" -le "$budget" ]
}
cdir=$STUB/containers vdir=$STUB/volumes idir=$STUB/images
mkdir -p "$cdir" "$vdir" "$idir"
state_of() { sed -n 's/^state=//p' "$cdir/$(key "$1")"; }
set_state() { sed -i "s/^state=.*/state=$2/" "$cdir/$(key "$1")"; }
sub=$1
shift
case $sub in
  container)
    op=$1
    shift
    fmt=""
    while [ "$#" -gt 1 ]; do
      case $1 in --format) fmt=$2; shift 2 ;; --force) shift ;; *) break ;; esac
    done
    name=$1
    [ -e "$cdir/$(key "$name")" ] || { echo "Error: No such container: $name" >&2; exit 1; }
    case $op in
      inspect) [ -z "$fmt" ] || { [ "$(state_of "$name")" = running ] && echo true || echo false; } ;;
      rm)
        if refused CONTAINER_RM; then echo "Error response from daemon: refused" >&2; exit 1; fi
        rm -f "$cdir/$(key "$name")"
        echo "rm container $name" >>"$STUB/events"
        ;;
      *) echo "stub: docker container $op is not stood in" >&2; exit 2 ;;
    esac
    ;;
  create)
    name="" volume=""
    while [ "$#" -gt 0 ]; do
      case $1 in
        --name) name=$2; shift 2 ;;
        --volume) volume=${2%%:*}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'state=created\nvolume=%s\n' "$volume" >"$cdir/$(key "$name")"
    ;;
  start) set_state "$1" running ;;
  exec)
    name=$1
    [ "$(state_of "$name")" = running ] || { echo "Error: container $name is not running" >&2; exit 1; }
    case " $* " in *" quit "*) set_state "$name" exited; echo "quit $name" >>"$STUB/events" ;; esac
    ;;
  stop)
    [ "$1" != --time ] || shift 2
    set_state "$1" exited
    echo "stop $1" >>"$STUB/events"
    ;;
  cp)
    name=${1%%:*}
    [ -e "$cdir/$(key "$name")" ] || { echo "Error: No such container: $name" >&2; exit 1; }
    echo "serial console of $name" >"$2/serial.log"
    ;;
  logs) echo "QEMU's log of $1" ;;
  run)
    # A client whose container's first process ignores TERM: TERM does not
    # end it, as a foreground `docker run` of the stuck download was not.
    trap '' TERM
    echo $$ >>"$SCRATCH/watchers"
    : >"$SCRATCH/running"
    sleep 300 &
    wait
    ;;
  volume)
    op=$1 name=$2
    case $op in
      create) : >"$vdir/$(key "$name")" ;;
      inspect) [ -e "$vdir/$(key "$name")" ] || { echo "Error response from daemon: get $name: no such volume" >&2; exit 1; } ;;
      rm)
        if refused VOLUME_RM; then echo "Error response from daemon: refused" >&2; exit 1; fi
        if grep -rqx "volume=$name" "$cdir"; then echo "Error response from daemon: remove $name: volume is in use" >&2; exit 1; fi
        rm -f "$vdir/$(key "$name")"
        echo "rm volume $name" >>"$STUB/events"
        ;;
      *) echo "stub: docker volume $op is not stood in" >&2; exit 2 ;;
    esac
    ;;
  image)
    op=$1
    shift
    [ "$1" != --force ] || shift
    name=$1
    [ -e "$idir/$(key "$name")" ] || { echo "Error: No such image: $name" >&2; exit 1; }
    case $op in
      inspect) ;;
      rm)
        if refused IMAGE_RM; then echo "Error response from daemon: refused" >&2; exit 1; fi
        rm -f "$idir/$(key "$name")"
        echo "rm image $name" >>"$STUB/events"
        ;;
      *) echo "stub: docker image $op is not stood in" >&2; exit 2 ;;
    esac
    ;;
  build)
    while [ "$#" -gt 0 ]; do
      case $1 in --tag) : >"$idir/$(key "$2")"; shift 2 ;; *) shift ;; esac
    done
    ;;
  *) echo "stub: docker $sub is not stood in" >&2; exit 2 ;;
esac
STUB
chmod +x "$scratch/bin/docker"

# The driver: run.sh's ownership, traps and teardown around what a case
# makes, then the outcome $1.
cat >"$scratch/driver.sh" <<'DRIVER'
set -uo pipefail
OUTCOME=$1
. "$ROOT/scripts/lib/run-names.sh"
. "$TEARDOWN"
printf '_START=%s\n' "$$"
proof_traps
PROOF_PREFIX=$DRIVER_PREFIX
PROOF_WORK=$SCRATCH/work
mkdir -p "$PROOF_WORK" "$SCRATCH/out"
P=$PROOF_PREFIX
proof_own image "${P}qemu:proof" && docker build --tag "${P}qemu:proof" .
proof_own volume "${P}disk" && docker volume create "${P}disk"
# Recorded, never made: a run stopped between the two.
proof_own container "${P}verify"
proof_own container "${P}qemu-trunk" "$SCRATCH/out/trunk" &&
  docker create --name "${P}qemu-trunk" --volume "${P}disk:/disk" "${P}qemu:proof" && docker start "${P}qemu-trunk"
proof_own container "${P}qemu-candidate" "$SCRATCH/out/candidate" &&
  docker create --name "${P}qemu-candidate" --volume "${P}disk:/disk" "${P}qemu:proof" &&
  docker start "${P}qemu-candidate" && docker stop --time 1 "${P}qemu-candidate"
# Names the run must not own, which it is asked to.
for name in "$FOREIGN_CONTAINER" postgres-dev; do
  if proof_own container "$name" 2>/dev/null; then echo "owned $name" >>"$SCRATCH/owned-foreign"; fi
done
sleep 300 &
proof_watch "$!"
echo "$!" >"$SCRATCH/watcher.pid"
echo "$!" >>"$SCRATCH/watchers"
: >"$SCRATCH/ready"
case $OUTCOME in
  success) exit 0 ;;
  failure) exit 1 ;;
  long) proof_fg docker run --rm --init --name "${P}verify" "${P}qemu:proof" /proof/verify-base.sh ;;
  *) while :; do sleep 0.1; done ;;
esac
DRIVER

seed=0123456789
prefix="cyfr-abcdef0123-$$-"
foreign_prefix="cyfr-$seed-4242-"
failures=0
cases=0

# A fresh stand-in Docker holding another run's container, volume and
# image, and unrelated ones.
fresh_docker() {
  rm -rf "$scratch/stub" "$scratch/work" "$scratch/out" "$scratch/ready" "$scratch/running" "$scratch/watcher.pid" "$scratch/owned-foreign"
  mkdir -p "$scratch/stub/containers" "$scratch/stub/volumes" "$scratch/stub/images"
  : >"$scratch/stub/calls"
  : >"$scratch/stub/events"
  : >"$scratch/stub/refusals"
  printf 'state=running\nvolume=%sdisk\n' "$foreign_prefix" >"$scratch/stub/containers/${foreign_prefix}qemu-trunk"
  printf 'state=running\nvolume=pgdata\n' >"$scratch/stub/containers/postgres-dev"
  : >"$scratch/stub/volumes/${foreign_prefix}disk"
  : >"$scratch/stub/volumes/pgdata"
  : >"$scratch/stub/images/${foreign_prefix}qemu+proof"
  : >"$scratch/stub/images/ubuntu+26.04"
}

# Runs the driver to the outcome $1 (success, failure, INT, TERM or HUP)
# with the environment words after it; leaves its status in $code, its
# stdout in $scratch/stdout and its stderr in $scratch/stderr.
drive() {
  local outcome=$1 closes
  shift
  fresh_docker
  # Job control gives the driver a process group of its own and leaves INT
  # untrapped-but-default there, as a foreground run has it.
  set -m
  env "$@" PATH="$scratch/bin:$PATH" STUB="$scratch/stub" ROOT="$root" TEARDOWN="$teardown" \
    SCRATCH="$scratch" DRIVER_PREFIX="$prefix" FOREIGN_CONTAINER="${foreign_prefix}qemu-trunk" \
    PROOF_CLEANUP_PAUSE=0 bash "$scratch/driver.sh" "$outcome" >"$scratch/stdout" 2>"$scratch/stderr" &
  driver_pid=$!
  set +m
  case $outcome in
    INT | TERM | HUP)
      closes=$((SECONDS + 20))
      until [ -e "$scratch/ready" ] || [ "$SECONDS" -ge "$closes" ]; do sleep 0.05; done
      kill "-$outcome" "$driver_pid" 2>/dev/null
      ;;
    long)
      # TERM, as heavy-check sends it, while a docker client that TERM
      # does not end runs: the teardown must start at once, not when the
      # client ends.
      closes=$((SECONDS + 20))
      until [ -e "$scratch/running" ] || [ "$SECONDS" -ge "$closes" ]; do sleep 0.05; done
      kill -TERM "$driver_pid" 2>/dev/null
      ;;
  esac
  code=0
  closes=$((SECONDS + 40))
  while kill -0 "$driver_pid" 2>/dev/null && [ "$SECONDS" -lt "$closes" ]; do sleep 0.1; done
  if kill -0 "$driver_pid" 2>/dev/null; then
    kill -KILL "$driver_pid" 2>/dev/null
    code=timeout
  fi
  if [ "$code" = timeout ]; then
    wait "$driver_pid" 2>/dev/null
    code=137
  else
    wait "$driver_pid" || code=$?
  fi
  driver_pid=""
}

check() {
  cases=$((cases + 1))
  if [ -z "$2" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    printf '%s\n' "$2" | sed 's/^/  /'
    echo "  exit: $code"
    sed 's/^/  event: /' "$scratch/stub/events"
    sed 's/^/  stderr: /' "$scratch/stderr"
    failures=$((failures + 1))
  fi
}

line_of() { grep -nxF "$1" "$scratch/stub/events" | head -n 1 | cut -d: -f1; }

# What a teardown that ended with the status $1 must have done; prints
# each way it fell short.
judge() {
  local want=$1 pid name kind before after watcher
  pid=$(sed -n '1s/^_START=//p' "$scratch/stdout")
  [ "$code" = "$want" ] || echo "the run exited $code, not $want"
  [ -n "$pid" ] || echo "stdout does not begin with _START=<pid>"
  [ "$(tail -n 1 "$scratch/stdout")" = "_EXIT=$pid $want" ] || echo "stdout does not end with _EXIT=$pid $want: $(tail -n 1 "$scratch/stdout")"
  for name in "containers/${prefix}qemu-trunk" "containers/${prefix}qemu-candidate" "containers/${prefix}verify" \
    "volumes/${prefix}disk" "images/${prefix}qemu+proof"; do
    kind=${name%%/*}
    [ ! -e "$scratch/stub/$name" ] || echo "the run's ${kind%s} ${name#*/} is left"
  done
  for name in "containers/${foreign_prefix}qemu-trunk" containers/postgres-dev "volumes/${foreign_prefix}disk" \
    volumes/pgdata "images/${foreign_prefix}qemu+proof" images/ubuntu+26.04; do
    kind=${name%%/*}
    [ -e "$scratch/stub/$name" ] || echo "the ${kind%s} ${name#*/}, not the run's, was removed"
  done
  grep -qx 'state=running' "$scratch/stub/containers/${foreign_prefix}qemu-trunk" 2>/dev/null ||
    echo "another run's guest was stopped"
  [ ! -e "$scratch/owned-foreign" ] || echo "the run owned names outside its prefix: $(tr '\n' ' ' <"$scratch/owned-foreign")"
  watcher=$(cat "$scratch/watcher.pid" 2>/dev/null)
  if [ -z "$watcher" ]; then
    echo "the driver started no watcher"
  elif kill -0 "$watcher" 2>/dev/null; then
    echo "the watcher $watcher outlived the teardown"
  fi
  before=$(line_of "quit ${prefix}qemu-trunk")
  after=$(line_of "rm container ${prefix}qemu-trunk")
  if [ -z "$before" ] || [ -z "$after" ] || [ "$before" -gt "$after" ]; then
    echo "the running guest was not stopped through QMP before its container was removed"
  fi
  before=$(grep -n '^rm container ' "$scratch/stub/events" | tail -n 1 | cut -d: -f1)
  after=$(line_of "rm volume ${prefix}disk")
  if [ -z "$before" ] || [ -z "$after" ] || [ "$before" -gt "$after" ]; then
    echo "the volume was not removed after every container"
  fi
  before=$after
  after=$(line_of "rm image ${prefix}qemu:proof")
  if [ -z "$before" ] || [ -z "$after" ] || [ "$before" -gt "$after" ]; then
    echo "the image was not removed after the volume"
  fi
  [ -s "$scratch/out/trunk/serial.log" ] && [ -s "$scratch/out/trunk/qemu.log" ] ||
    echo "the running guest's evidence was not copied out"
  [ -s "$scratch/out/candidate/serial.log" ] || echo "the stopped guest's evidence was not copied out"
  [ ! -e "$scratch/work" ] || echo "the scratch directory is left"
  [ -d "$scratch/out" ] || echo "the evidence directory was removed"
}

for outcome in success failure INT TERM HUP; do
  case $outcome in success) want=0 ;; failure) want=1 ;; INT) want=130 ;; TERM) want=143 ;; HUP) want=129 ;; esac
  drive "$outcome"
  check "a run that ends by $outcome is torn down whole, in order, and exits $want" "$(judge "$want")"
done

drive long
problems=$(judge 143)
check "TERM while a long docker command runs that TERM does not end tears the run down within 40 s and exits 143" "$problems"

drive success STUB_FAIL_VOLUME_RM=99
problems=$(judge 1 | grep -v -e "volume ${prefix}disk is left" -e 'volume was not removed' -e 'image was not removed after')
[ "$(grep -c "^volume rm ${prefix}disk\$" "$scratch/stub/calls")" = 3 ] || problems+=$'\nthe volume removal was not tried three times'
grep -q "the volume ${prefix}disk is left on this host" "$scratch/stderr" || problems+=$'\nstderr does not name the volume left'
[ ! -e "$scratch/stub/images/${prefix}qemu+proof" ] || problems+=$'\nthe image stayed after the volume failed'
check "a removal that keeps failing fails a passed run, naming what it leaves, and the rest still goes" "$problems"

drive success STUB_FAIL_CONTAINER_RM=2
check "a removal that succeeds within three attempts passes" "$(judge 0)"

for bad in "" "cyfr-notaseed-1-" "cyfr-${seed}-12-extra" "other-${seed}-12-"; do
  : >"$scratch/stub/calls"
  code=0
  PATH="$scratch/bin:$PATH" STUB="$scratch/stub" PROOF_RUN_PREFIX="$bad" \
    bash "$here/run.sh" --case 1 >"$scratch/stdout" 2>"$scratch/stderr" || code=$?
  pid=$(sed -n '1s/^_START=//p' "$scratch/stdout")
  problems=""
  [ "$code" = 64 ] || problems+="run.sh exited $code, not 64"$'\n'
  [ -n "$pid" ] && [ "$(tail -n 1 "$scratch/stdout")" = "_EXIT=$pid 64" ] || problems+="the refusal is not framed"$'\n'
  [ ! -s "$scratch/stub/calls" ] || problems+="docker was called: $(tr '\n' ';' <"$scratch/stub/calls")"$'\n'
  grep -q 'is not a run prefix' "$scratch/stderr" || problems+="stderr does not say why: $(cat "$scratch/stderr")"$'\n'
  check "run.sh refuses the prefix '$bad' before it makes anything" "${problems%$'\n'}"
done

echo "$cases cases, $failures failed"
[ "$failures" -eq 0 ]
