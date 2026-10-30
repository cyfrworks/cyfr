#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The source development stack (CONTRIBUTING.md, "Running from source"):
# CYFR run from this checkout with `mix phx.server`, beside the runtime,
# backends and builds services of docker-compose.yml, run from this tree's
# Locus image (docker-compose.dev.yml).
#
#   scripts/dev-stack.sh          provision .env on its first run, build the
#                                 image when this tree's is not on the host,
#                                 start the containers, then run CYFR in the
#                                 foreground until it stops or is stopped,
#                                 removing the containers on every exit
#   scripts/dev-stack.sh check    run a component through the running server
#                                 as a signed-in person and assert its answer
#   scripts/dev-stack.sh down     stop the server a killed run left, and
#                                 remove the stack's containers and networks
#   scripts/dev-stack.sh slot K   print slot K's values, one NAME=value a line
#                                 (tests/dev-stack/compose-test.sh reads them)
#
# Each worktree runs a loop of its own. Its compose project, and the
# prefix of its containers' names, is cyfr-dev-<seed>, the worktree's seed
# (scripts/lib/run-names.sh), whatever the caller's COMPOSE_* say. Its
# ports and subnets are its slot's: slot K, from 0 to 19, puts Prism on
# 4000 + 10K and its proxy on 4001 + 10K, the runtime on 127.0.0.1:4700 +
# 10K, the host API on 4701 + 10K at the runtime network's gateway, the
# cyfr.run stand-in on 127.79.K.1:4702 + 10K, and the runtime, backends
# and builds networks on 172.16.(100 + 3K), (101 + 3K) and (102 +
# 3K).0/24. A loop takes the slot data/dev-stack.slot remembers while it
# is free, else the first free one from 0, so a lone loop keeps
# localhost:4000, and it remembers the slot it takes. A slot is free when
# no other loop holds its claim (a lock under XDG_RUNTIME_DIR, else
# TMPDIR, held for the loop's life), nothing listens on its ports and no
# Docker network overlaps its subnets; when none is, the loop refuses
# naming each slot's holder.
#
# The stand-in (tests/registry-stand-in/standin.py) answers for cyfr.run's
# registry and directory, so a person the loop makes exists there alone;
# it forwards the GETs it does not own, component search and metadata, to
# https://cyfr.run. The server's registry and directory are the stand-in
# whatever .env says (`mix cyfr.locus.dev_stack`). The loop starts it
# before the server and stops it on every exit path. Its state is
# data/dev-stack/cyfr-run.json, which records the address it serves: every
# genesis a dev database's people signed names that address, so a
# database is bound to the slot its state file names. A new database (the
# task says which) clears the state; a database that is not new takes its
# slot when it is free and refuses otherwise, and without a state file it
# refuses, naming the reset either way.
#
# One run of a worktree's loop holds the project's lock (beside the
# claims) for its whole life, before anything of its checkout is written
# or built, and records its checkout and its server's process group there:
# a start or `down` in the same worktree refuses while it runs, and
# `down`, or the next start, finds a server whose run was killed. Either
# removes what a killed run of this worktree left, by its project's name,
# and never another worktree's. DEV_STACK_GRACE (seconds, default 30) is
# how long a server is given to stop before its process group is killed.
#
# The image is scripts/image.sh's for this tree (`--undated`, with this
# run's pid as its use, so scripts/janitor.sh keeps it while the loop
# runs): shared by every worktree at the same inputs, built only when the
# host does not hold it.
#
# Every setting comes from `mix cyfr.locus.dev_stack`, which derives
# CYFR's from docker-compose.dev.yml as compose resolves it with the
# slot's values, and reads .env and the environment as a mix boot does;
# this script reads neither file itself. The task's one edit of .env adds
# what a mix boot needs and nothing sets, after making the file mode 0600.
# The services' keys reach compose, and CYFR's settings the server, in
# their environments alone; nothing here prints a key or the check's
# bearer token. The one secret it prints is the setup link, on the run
# that writes CYFR_SETUP_TOKEN, as `cyfr init` prints it to the operator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/run-names.sh
. "$ROOT/scripts/lib/run-names.sh"

# Compose reads no setting of the caller's: the project, the files and the
# profiles are this script's.
for name in $(compgen -e); do
  case "$name" in COMPOSE_*) unset "$name" ;; esac
done

GRACE="${DEV_STACK_GRACE:-30}"
case "$GRACE" in '' | *[!0-9]*) echo "dev-stack: DEV_STACK_GRACE is $GRACE, not a number of seconds." >&2; exit 1 ;; esac

SLOTS=20
REMEMBERED=data/dev-stack.slot
STAND_IN_STATE=data/dev-stack/cyfr-run.json
STAND_IN_LOG=data/dev-stack/cyfr-run.log
RESET="reset by deleting the dev database and $STAND_IN_STATE"
LOCK=""
LOCK_FD=""
CLAIM_FD=""
PRIVATE=""
PROJECT=""
IMAGE=""
SLOT_ENV=()
SERVER=""
SERVER_ENDED=""
STAND_IN=""
BOUND=""
STARTED=""

die() {
  echo "dev-stack: $*" >&2
  exit 1
}

# slot_env K: slot K's values, as compose reads them.
slot_env() {
  local k="$1"
  printf '%s\n' "DEV_STACK_SLOT=$k" \
    "DEV_STACK_PRISM_PORT=$((4000 + 10 * k))" "DEV_STACK_PROXY_PORT=$((4001 + 10 * k))" \
    "DEV_STACK_RUNTIME_PORT=$((4700 + 10 * k))" "DEV_STACK_HOST_API_PORT=$((4701 + 10 * k))" \
    "DEV_STACK_RUNTIME_NET=172.16.$((100 + 3 * k))" "DEV_STACK_BACKENDS_NET=172.16.$((101 + 3 * k))" \
    "DEV_STACK_BUILDS_NET=172.16.$((102 + 3 * k))" \
    "DEV_STACK_STAND_IN_ADDRESS=127.79.$k.1" "DEV_STACK_STAND_IN_PORT=$((4702 + 10 * k))"
}
# slot_value NAME: the slot in use's NAME.
slot_value() { printf '%s\n' "${SLOT_ENV[@]}" | sed -n "s/^$1=//p"; }
slot_ok() { case "${1:-}" in [0-9] | 1[0-9]) return 0 ;; *) return 1 ;; esac; }
use_slot() {
  mapfile -t SLOT_ENV < <(slot_env "$1")
}
# The slot this worktree remembers, else 0.
remembered() {
  local k=""
  [ ! -f "$REMEMBERED" ] || k="$(cat "$REMEMBERED")"
  if slot_ok "$k"; then echo "$k"; else echo 0; fi
}

# Every service of the stack, builds included, with nothing interpolated
# from .env: what the services need from it arrives from the task in the
# environment, and the project, the image and the slot's values from this
# script alone.
compose() {
  env "${SLOT_ENV[@]}" DEV_STACK_PROJECT="$PROJECT" DEV_STACK_IMAGE="$IMAGE" \
    docker compose --env-file /dev/null -p "$PROJECT" --profile locus-builds \
    -f docker-compose.yml -f docker-compose.dev.yml "$@"
}

# The loop's files under XDG_RUNTIME_DIR, else TMPDIR: the project's lock
# and the slots' claims.
runtime_dir() { printf '%s' "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"; }
# lock_file PROJECT: the one lock of the project on this host.
lock_file() { printf '%s/%s.dev-stack.lock' "$(runtime_dir)" "$1"; }
claim_file() { printf '%s/cyfr-dev-slot.%s.lock' "$(runtime_dir)" "$1"; }

# lock: the project's lock for the rest of this process, or a refusal
# naming the run that holds it; the server never inherits it.
lock() {
  command -v flock >/dev/null || die "flock is not on PATH (util-linux; brew install flock)."
  LOCK="$(lock_file "$PROJECT")"
  exec {LOCK_FD}>>"$LOCK"
  if ! flock -n "$LOCK_FD"; then
    local holder checkout
    holder="$(sed -n 's/^pid //p' "$LOCK" 2>/dev/null | head -n 1)"
    checkout="$(sed -n 's/^checkout //p' "$LOCK" 2>/dev/null | head -n 1)"
    LOCK_FD=""
    die "another run of this worktree's dev stack (pid ${holder:-unknown}, checkout ${checkout:-unknown}) holds $LOCK; stop it, or wait for it to end."
  fi
  # This run's pid and checkout, beside the server and the stand-in a
  # killed run recorded, which `down` and a start still read; the file
  # stays the one the lock is on.
  local recorded
  recorded="$(sed -n '/^\(server\|stand-in\) /p' "$LOCK")"
  printf 'pid %s\ncheckout %s\n%s' "$$" "$ROOT" "${recorded:+$recorded$'\n'}" >"$LOCK"
}

# record: this run's lock record, its server and stand-in with their start
# times, so a run killed outright leaves what `down` stops.
record() {
  {
    printf 'pid %s\ncheckout %s\n' "$$" "$ROOT"
    [ -z "$STAND_IN" ] || printf 'stand-in %s %s\n' "$STAND_IN" "$(started "$STAND_IN")"
    [ -z "$SERVER" ] || [ -n "$SERVER_ENDED" ] || printf 'server %s %s\n' "$SERVER" "$(started "$SERVER")"
  } >"$LOCK"
}

# The subnets of every Docker network on the host but this project's, one
# `NAME SUBNET` a line.
networks() {
  local ids
  ids="$(docker network ls -q)" || die "docker could not list the host's networks."
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086
  docker network inspect --format '{{.Name}}{{range .IPAM.Config}} {{.Subnet}}{{end}}' $ids |
    awk -v own="${PROJECT}_" 'index($1, own) != 1 { for (i = 2; i <= NF; i++) print $1, $i }'
}

# overlaps NETWORKS K: the first of NETWORKS (`NAME SUBNET` lines) that
# overlaps one of slot K's subnets, as `the network NAME (SUBNET)`;
# nothing when none does.
overlaps() {
  printf '%s\n' "$1" | python3 -I -c '
import ipaddress, sys
k = int(sys.argv[1])
mine = [ipaddress.ip_network("172.16.%d.0/24" % (100 + 3 * k + i)) for i in range(3)]
for line in sys.stdin:
    name, _, subnet = line.strip().partition(" ")
    try:
        other = ipaddress.ip_network(subnet, strict=False)
    except ValueError:
        continue
    if any(n.version == other.version and n.overlaps(other) for n in mine):
        print("the network %s (%s)" % (name, other))
        break' "$2"
}

# started PID: when PID started, as ps prints it; nothing when it has
# exited.
started() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

# holder FILE: the loop a held claim names, `the loop of CHECKOUT (pid
# PID)`, when the record's pid is a live process that started when the
# record says, so a pid reused since names no one. Its owner writes the
# record as soon as it takes the claim, which leaves a moment when the
# record is empty or a previous owner's, and empties it before it lets the
# claim go; so a record that is empty or does not verify is read again
# for up to a second, and then the holder is `a loop whose record cannot
# be verified`. The claim's lock, not its record, decides that the slot
# is taken.
holder() {
  local pid when checkout n=0
  while :; do
    pid="$(sed -n 's/^pid //p' "$1" 2>/dev/null | head -n 1)"
    when="$(sed -n 's/^started //p' "$1" 2>/dev/null | head -n 1)"
    checkout="$(sed -n 's/^checkout //p' "$1" 2>/dev/null | head -n 1)"
    if [ -n "$checkout" ] && [ -n "$pid" ] && [ -n "$when" ] && [ "$(started "$pid")" = "$when" ]; then
      printf 'the loop of %s (pid %s)' "$checkout" "$pid"
      return 0
    fi
    [ "$n" -lt 10 ] || break
    sleep 0.1
    n=$((n + 1))
  done
  printf 'a loop whose record cannot be verified (%s)' "$1"
}

# claim K NETWORKS: slot K's claim, kept in CLAIM_FD, when the slot is
# free; else nothing held and WHY saying what holds the slot. The claim's
# record names this run, with its start time, as soon as the claim is
# held, before the slot is looked at.
WHY=""
CLAIM_FILE=""
claim() {
  local k="$1" fd file port who
  file="$(claim_file "$k")"
  exec {fd}>>"$file"
  if ! flock -n "$fd"; then
    exec {fd}>&-
    WHY="$(holder "$file")"
    return 1
  fi
  printf 'pid %s\nstarted %s\ncheckout %s\n' "$$" "$(started "$$")" "$ROOT" >"$file"
  for listener in 127.0.0.1:$((4000 + 10 * k)) 127.0.0.1:$((4001 + 10 * k)) 127.0.0.1:$((4700 + 10 * k)) \
    127.0.0.1:$((4701 + 10 * k)) "127.79.$k.1:$((4702 + 10 * k))"; do
    if who="$(held "${listener%:*}" "${listener##*:}")"; then
      : >"$file"
      exec {fd}>&-
      WHY="$listener, held by $who"
      return 1
    fi
  done
  who="$(overlaps "$2" "$k")"
  if [ -n "$who" ]; then
    : >"$file"
    exec {fd}>&-
    WHY="$who"
    return 1
  fi
  CLAIM_FD="$fd" CLAIM_FILE="$file"
}

# take_slot: the slot the database is bound to (BOUND) when it is free, or
# a refusal naming it and the reset; else the slot this worktree remembers
# while it is free, else the first free one, remembered for the next run;
# or a refusal naming every slot's holder.
take_slot() {
  local first k nets taken=()
  first="$(remembered)"
  nets="$(networks)"
  if [ -n "$BOUND" ]; then
    claim "$BOUND" "$nets" ||
      die "This database's people were made at slot $BOUND, which is taken ($WHY). Stop what holds slot $BOUND, or $RESET."
    use_slot "$BOUND"
    mkdir -p "$(dirname "$REMEMBERED")" && printf '%s\n' "$BOUND" >"$REMEMBERED"
    return 0
  fi
  for k in "$first" $(seq 0 $((SLOTS - 1))); do
    [ "$k" != "$first" ] || [ "${#taken[@]}" = 0 ] || continue
    if claim "$k" "$nets"; then
      use_slot "$k"
      mkdir -p "$(dirname "$REMEMBERED")" && printf '%s\n' "$k" >"$REMEMBERED"
      [ "$k" = "$first" ] ||
        echo "dev-stack: slot $first is taken (${taken[0]#"slot $first: "}), so this worktree's loop takes slot $k."
      return 0
    fi
    taken+=("slot $k: $WHY")
  done
  die "every slot is taken: $(printf '%s; ' "${taken[@]}" | sed 's/; $//')."
}

# orphan KIND: the process group of the server, or the stand-in (KIND
# `server` or `stand-in`), a killed run recorded, when its leader is still
# the process the run started; nothing otherwise.
orphan() {
  local pgid started
  read -r pgid started < <(sed -n "s/^$1 //p" "$LOCK" 2>/dev/null) || return 0
  [ -n "${pgid:-}" ] && [ -n "${started:-}" ] || return 0
  [ "$(started "$pgid")" = "$started" ] && echo "$pgid"
  return 0
}

# kept KIND: the lock record's KIND line, if any.
kept() { sed -n "/^$1 /p" "$LOCK" 2>/dev/null || true; }

# gone GROUP: no process is left in GROUP, waited for up to 5 s.
gone() {
  local n=0
  while kill -0 -- "-$1" 2>/dev/null; do
    [ "$n" -lt 50 ] || return 1
    sleep 0.1
    n=$((n + 1))
  done
}

# stop GROUP: the server's process group, its leader given the grace to
# stop before the whole group is killed.
stop() {
  kill -TERM "$1" 2>/dev/null || true
  for _ in $(seq 1 $((GRACE * 10))); do
    kill -0 "$1" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL -- "-$1" 2>/dev/null || true
}

# Ends every run, a signal's included: the server first, then every
# container and network of the stack. A second signal does not cut it
# short.
finish() {
  local status=$?
  trap '' INT TERM HUP
  # The server's whole process group, whether the server still runs or
  # has ended: what it started outlives it otherwise. An ended server's
  # pid is no longer its own, so only its group is signalled.
  if [ -n "$SERVER_ENDED" ]; then
    kill -KILL -- "-$SERVER" 2>/dev/null || true
  elif [ -n "$SERVER" ]; then
    stop "$SERVER"
    wait "$SERVER" 2>/dev/null || true
  fi
  # The stand-in after the server that calls it.
  if [ -n "$STAND_IN" ]; then
    stop "$STAND_IN"
    wait "$STAND_IN" 2>/dev/null || true
  fi
  if [ -n "$STARTED" ]; then
    echo "dev-stack: removing the containers." >&2
    compose down --remove-orphans >/dev/null 2>&1 ||
      echo "dev-stack: the containers could not be removed; \`scripts/dev-stack.sh down\` removes them." >&2
  fi
  # A server's or stand-in's record goes only once its group is gone: this
  # run's own, which it stopped above; a killed run's stays for `down`.
  if [ -n "$LOCK_FD" ]; then
    local left="" kind pid
    for kind in server stand-in; do
      case "$kind" in server) pid="$SERVER" ;; *) pid="$STAND_IN" ;; esac
      if [ -n "$pid" ] && gone "$pid"; then continue; fi
      [ -z "$(kept "$kind")" ] || left="$left$(kept "$kind")"$'\n'
    done
    printf '%s' "$left" >"$LOCK"
  fi
  # The claim's record emptied while the claim is still held: the exit lets
  # the claim go.
  [ -z "$CLAIM_FILE" ] || : >"$CLAIM_FILE"
  [ -z "$PRIVATE" ] || rm -rf "$PRIVATE"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

private() {
  PRIVATE="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-dev-stack.XXXXXX")"
  chmod 700 "$PRIVATE"
}

# Compose reads the shipped cyfr service's env_file even when it starts
# none of it, so a checkout with no .env gets an empty one, mode 0600, for
# the task to write into.
env_file() {
  [ -e .env ] || (umask 077 && : >.env) || die ".env could not be created here; check the checkout's permissions."
}

# docker-compose.dev.yml resolved over docker-compose.yml, with the slot's
# values, into the private directory.
declarations() {
  env_file
  compose config --format json locus-runtime locus-backends locus-builds >"$PRIVATE/stack.json" ||
    die "docker compose could not resolve docker-compose.dev.yml over docker-compose.yml."
}

# image: this tree's Locus image, built when the host does not hold it,
# with this run's pid as its use; `--tag-only` names it without a use or a
# build, for a command that starts nothing.
image() {
  IMAGE="$("$ROOT/scripts/image.sh" --undated "$@" locus)" ||
    die "scripts/image.sh gave no Locus image for this tree; its output ends above."
}

# The settings task, which Ctrl-C ends at once (`+Bd`: no break menu)
# while mix compiles the checkout.
task() { ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +Bd" mix cyfr.locus.dev_stack "$@"; }

# The refusal in the task's output: its `** (Mix)` sentence, else its last
# lines.
refusal() {
  local said
  said="$(printf '%s\n' "$1" | sed -n 's/^\*\* (Mix) //p')"
  printf '%s' "${said:-$(printf '%s\n' "$1" | grep -v '^compose ' | tail -n 3)}"
}

# held ADDRESS PORT: who listens on ADDRESS:PORT, by any address that
# covers it; fails, printing nothing, when the port is free.
held() {
  python3 -I -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind((sys.argv[1], int(sys.argv[2])))
except OSError:
    sys.exit(0)
sys.exit(1)' "$1" "$2" || return 1
  local who
  who="$(ss -Hltnp "sport = :$2" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1 (pid \2)/p' | head -n 1)"
  [ -n "$who" ] || who="$(docker ps --filter "publish=$2" --format 'the container {{.Names}}' 2>/dev/null | head -n 1)"
  echo "${who:-a process this user cannot see}"
}

# bind_database: whether the dev database is new, from the task. A new one
# clears the stand-in's state; one that is not binds the loop (BOUND) to
# the slot the state file's address names, or refuses with the reset.
bind_database() {
  local out new address
  out="$(task database 2>&1)" || die "$(refusal "$out")"
  new="$(value DEV_STACK_DATABASE_NEW "$out")"
  case "$new" in
    1)
      rm -f "$STAND_IN_STATE"
      return 0
      ;;
    0) ;;
    *) die "mix cyfr.locus.dev_stack did not say whether the dev database is new." ;;
  esac
  [ -f "$STAND_IN_STATE" ] ||
    die "This database's people were made beside a stand-in whose state is gone ($STAND_IN_STATE). Reset by deleting the dev database and $STAND_IN_STATE."
  address="$(python3 -I -c 'import json, sys
print(json.load(open(sys.argv[1])).get("directory", ""))' "$STAND_IN_STATE" 2>/dev/null)" || address=""
  BOUND="$(printf '%s' "$address" | sed -n 's|^http://127\.79\.\([0-9]*\)\.1:[0-9]*$|\1|p')"
  slot_ok "$BOUND" && [ "$address" = "http://127.79.$BOUND.1:$((4702 + 10 * BOUND))" ] ||
    die "$STAND_IN_STATE names $address, the address of no slot. Reset by deleting the dev database and $STAND_IN_STATE."
}

# start_stand_in: the slot's stand-in, in a process group of its own, up
# before the server it answers; its log in $STAND_IN_LOG.
start_stand_in() {
  local address port n=0
  address="$(slot_value DEV_STACK_STAND_IN_ADDRESS)" port="$(slot_value DEV_STACK_STAND_IN_PORT)"
  mkdir -p "$(dirname "$STAND_IN_STATE")"
  (exec {LOCK_FD}>&- {CLAIM_FD}>&- &&
    exec python3 -I -c 'import os, sys; os.setpgid(0, 0); os.execvp(sys.argv[1], sys.argv[1:])' \
      python3 -I "$ROOT/tests/registry-stand-in/standin.py" --address "$address" --port "$port" \
      --state "$STAND_IN_STATE" --ready-file "$PRIVATE/stand-in.ready" --upstream https://cyfr.run \
      </dev/null >"$STAND_IN_LOG" 2>&1) &
  STAND_IN=$!
  record
  until [ -s "$PRIVATE/stand-in.ready" ]; do
    if ! kill -0 "$STAND_IN" 2>/dev/null || [ "$n" -ge 100 ]; then
      tail -n 5 "$STAND_IN_LOG" >&2 || true
      die "the cyfr.run stand-in did not start on $address:$port; its log ends above."
    fi
    sleep 0.1
    n=$((n + 1))
  done
  echo "dev-stack: the cyfr.run stand-in answers at http://$address:$port."
}

run() {
  command -v docker >/dev/null || die "docker is not on PATH."
  command -v python3 >/dev/null || die "python3 is not on PATH."
  lock
  private
  local left
  left="$(orphan server)"
  [ -z "$left" ] ||
    die "the server a killed run of this worktree left still runs (process group $left); \`scripts/dev-stack.sh down\` stops it."
  left="$(orphan stand-in)"
  [ -z "$left" ] ||
    die "the cyfr.run stand-in a killed run of this worktree left still runs (process group $left); \`scripts/dev-stack.sh down\` stops it."
  # The image's tag names it in the declarations; the image itself is
  # built, when the host lacks it, once the settings are agreed.
  image --tag-only
  env_file
  # What a killed run of this worktree left, removed by its project's name
  # before a slot is chosen: its networks and published ports would hold
  # its own slot.
  use_slot "$(remembered)"
  compose down --remove-orphans >/dev/null 2>&1 || true
  echo "dev-stack: reading the settings; mix compiles the checkout first when it has changed."
  bind_database
  take_slot
  declarations

  local out status line wrote="" setup="" server=() keys=() port=""
  out="$(task settings "$PRIVATE/stack.json" "$(slot_value DEV_STACK_STAND_IN_ADDRESS):$(slot_value DEV_STACK_STAND_IN_PORT)" 2>&1)" &&
    status=0 || status=$?
  [ "$status" = 0 ] || die "$(refusal "$out")"
  while IFS= read -r line; do
    case "$line" in
      "wrote "*) wrote="${line#wrote }" ;;
      "setup "*) setup="${line#setup }" ;;
      "server "*) server+=("${line#server }") ;;
      "compose "*) keys+=("${line#compose }") ;;
    esac
  done <<<"$out"
  for line in "${server[@]}"; do
    case "$line" in CYFR_PORT=*) port="${line#*=}" ;; esac
  done
  [ -n "$port" ] && [ "${#keys[@]}" = 3 ] || die "mix cyfr.locus.dev_stack printed no settings."
  [ -z "$wrote" ] || echo "dev-stack: .env is mode 0600 and now sets ${wrote// /, }."

  # This tree's image, with this run as its use; built only when the host
  # lacks it, so an unchanged tree starts without a build.
  image --for "$$"
  start_stand_in
  STARTED=1
  if ! (export "${keys[@]}" && compose up --detach --no-build --wait locus-runtime locus-backends locus-builds); then
    compose logs --tail 30 >&2 || true
    die "the containers did not start; their logs end above."
  fi

  printf '\n%s\n%s\n' \
    "dev-stack: the runtime, backends and builds services run from this tree." \
    "dev-stack: CYFR starts at http://localhost:$port and reloads as its files change."
  [ -z "$setup" ] || echo "dev-stack: set up its first person, who administers it, at $setup"
  printf '%s\n\n' "dev-stack: Ctrl-C stops it and removes the containers."
  # The server in a process group of its own, so the whole of it stops
  # with the run, and its settings in its environment alone. The run, not
  # the terminal, stops it: Ctrl-C reaches the script, whose exit stops
  # the server and then the containers.
  (exec {LOCK_FD}>&- {CLAIM_FD}>&- && export "${server[@]}" &&
    exec python3 -I -c 'import os, sys; os.setpgid(0, 0); os.execvp(sys.argv[1], sys.argv[1:])' mix phx.server </dev/null) &
  SERVER=$!
  record
  wait "$SERVER" && status=0 || status=$?
  SERVER_ENDED=1
  echo "dev-stack: CYFR exited with status $status." >&2
  exit "$status"
}

# The value of NAME=value in the task's output.
value() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }

# files ACTION ARGUMENTS_JSON: one run of the shipped files catalyst
# through the server's /mcp as the person CYFR_TOKEN signs in. Prints the
# run's result as JSON, or else the refusal or the failure and fails.
files() {
  local body answer
  body="$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"execution","arguments":{"action":"run","reference":"catalyst:local.files","input":{"action":"%s",%s}},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"dev-stack","version":"0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' "$1" "$2")"
  answer="$(curl -sS -m 120 -X POST "$MCP" \
    -H @"$PRIVATE/authorization" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' -H 'mcp-protocol-version: 2026-07-28' \
    -H 'mcp-method: tools/call' -H 'mcp-name: execution' -d "$body" 2>&1)" || {
    echo "$1: $MCP did not answer ($answer): is scripts/dev-stack.sh running?"
    return 1
  }
  printf '%s' "$answer" | python3 -I -c '
import json, sys
action, raw = sys.argv[1], sys.stdin.read()
def fail(message):
    print("%s: %s" % (action, message))
    sys.exit(1)
try:
    reply = json.loads(raw)
except ValueError:
    fail("the server answered %r" % raw[:300])
if "error" in reply:
    fail("refused: %s" % reply["error"].get("message"))
result = reply["result"]
text = result["content"][0]["text"]
if result.get("isError"):
    fail("the run failed: %s" % text)
run = json.loads(text)
print("%s: execution %s %s" % (action, run.get("execution_id"), run.get("status")), file=sys.stderr)
if run.get("status") != "completed":
    fail("the run ended %s: %s" % (run.get("status"), text))
print(json.dumps(run.get("result")))' "$1"
}

# verify PATH NONCE: the runtime reads NONCE back from PATH. Prints the
# failure and fails otherwise, every way it can, so its caller's one
# cleanup path follows each; errexit does not apply inside it.
verify() {
  local read content
  read="$(files read_text "\"path\":\"$1\"")" || { printf '%s' "$read"; return 1; }
  content="$(printf '%s' "$read" | python3 -I -c '
import json, sys
result = json.load(sys.stdin)
if not isinstance(result, dict) or not isinstance(result.get("content"), str):
    sys.exit(1)
print(result["content"])' 2>/dev/null)" || { printf 'read_text: the run answered no content: %s' "$read"; return 1; }
  [ "$content" = "$2" ] || { printf 'the runtime read back %s from %s, not %s.' "${content@Q}" "$1" "${2@Q}"; return 1; }
}

# discard PATH: the check's file deleted once after a failure; saying so
# when that fails too.
discard() {
  local out
  out="$(files delete "\"path\":\"$1\"")" ||
    echo "dev-stack: $1 is left in the athanor's storage, since its delete failed too: $out" >&2
}

check() {
  [ -n "${CYFR_TOKEN:-}" ] ||
    die "CYFR_TOKEN is not set: the check runs a component as a signed-in person. Create an API key on Prism's API Keys page, or sign the dev CLI in with \`cyfr login\`, and pass the key or the session token as CYFR_TOKEN."
  local out port nonce path failure
  private
  [ -f "$REMEMBERED" ] && slot_ok "$(cat "$REMEMBERED")" ||
    die "no loop has started in this worktree, so it has no slot; scripts/dev-stack.sh starts one."
  use_slot "$(cat "$REMEMBERED")"
  image --tag-only
  declarations
  out="$(task endpoint "$PRIVATE/stack.json" "$(slot_value DEV_STACK_STAND_IN_ADDRESS):$(slot_value DEV_STACK_STAND_IN_PORT)" 2>&1)" ||
    die "$(refusal "$out")"
  port="$(value CYFR_PORT "$out")"
  [ -n "$port" ] || die "mix cyfr.locus.dev_stack printed no port."
  MCP="http://127.0.0.1:$port/mcp"

  (umask 077 && printf 'authorization: Bearer %s\n' "$CYFR_TOKEN" >"$PRIVATE/authorization")

  nonce="dev-stack-$(openssl rand -hex 8)"
  path="data/dev-stack-check-$nonce.txt"

  out="$(files write_text "\"path\":\"$path\",\"content\":\"$nonce\"")" || die "$out"
  # The write landed: every failure from here deletes the file once and
  # ends with its own sentence.
  if ! failure="$(verify "$path" "$nonce")"; then
    discard "$path"
    die "$failure"
  fi
  out="$(files delete "\"path\":\"$path\"")" ||
    die "$path is left in the athanor's storage, since its delete failed: $out"
  echo "dev-stack: catalyst:local.files wrote, read back and deleted $nonce through $MCP and the runtime container."
}

down() {
  lock
  # The server first, then the stand-in it called, whatever fails after:
  # each record goes only once its group is gone.
  local left kind rest
  for kind in server stand-in; do
    left="$(orphan "$kind")"
    [ -n "$left" ] || continue
    echo "dev-stack: stopping the $kind a killed run left (process group $left)."
    stop "$left"
    gone "$left" || die "the $kind a killed run left (process group $left) outlived KILL; its record stays for the next \`scripts/dev-stack.sh down\`."
    # The stand-in's record stays until its own turn.
    rest="$([ "$kind" = stand-in ] || kept stand-in)"
    printf 'pid %s\ncheckout %s\n%s' "$$" "$ROOT" "${rest:+$rest$'\n'}" >"$LOCK"
  done
  use_slot "$(remembered)"
  image --tag-only
  env_file
  compose down --remove-orphans
}

PROJECT="cyfr-dev-$(run_names_seed "$ROOT")" ||
  die "$ROOT is in no git worktree, so the loop has no seed to name its project by."

case "${1:-}" in
  "") run ;;
  check) check ;;
  down) down ;;
  slot)
    slot_ok "${2:-}" || { echo "usage: scripts/dev-stack.sh slot K, K from 0 to $((SLOTS - 1))" >&2; exit 2; }
    slot_env "$2"
    ;;
  *)
    echo "usage: scripts/dev-stack.sh [check | down | slot K]" >&2
    exit 2
    ;;
esac
