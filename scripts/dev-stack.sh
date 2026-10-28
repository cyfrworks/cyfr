#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The source development stack (CONTRIBUTING.md, "Running from source"):
# CYFR run from this checkout with `mix phx.server`, beside the runtime,
# backends and builds services of docker-compose.yml built from the same
# tree (docker-compose.dev.yml).
#
#   scripts/dev-stack.sh        provision .env on its first run, build and
#                               start the containers, then run CYFR in the
#                               foreground until it stops or is stopped,
#                               removing the containers on every exit
#   scripts/dev-stack.sh check  run a component through the running server
#                               as a signed-in person and assert its answer
#   scripts/dev-stack.sh down   stop the server a killed run left, and
#                               remove the stack's containers and networks
#   scripts/dev-stack.sh clean  do what down does, then remove the stack's
#                               image
#
# The stack's compose project is the one docker-compose.dev.yml names,
# whatever the caller's COMPOSE_* say. Its containers, networks and ports
# are the host's, so one run on the host holds the project's lock (under
# XDG_RUNTIME_DIR, else TMPDIR) for its whole life, before anything of its
# checkout is written or built, and records its checkout and its server's
# process group there: a start, `down` or `clean` from any checkout
# refuses while it runs, and `down` finds a server whose run was killed.
# DEV_STACK_GRACE (seconds, default 30) is how long a server is given to
# stop before its process group is killed.
#
# Every setting comes from `mix cyfr.locus.dev_stack`, which derives
# CYFR's from docker-compose.dev.yml as compose resolves it and reads .env
# and the environment as a mix boot does; this script reads neither file
# itself. The task's one edit of .env adds what a mix boot needs and
# nothing sets, after making the file mode 0600. The services' keys reach
# compose, and CYFR's settings the server, in their environments alone;
# nothing here prints a key or the check's bearer token. The one secret it
# prints is the setup link, on the run that writes CYFR_SETUP_TOKEN, as
# `cyfr init` prints it to the operator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Compose reads no setting of the caller's: the project, the files and the
# profiles are this script's.
for name in $(compgen -e); do
  case "$name" in COMPOSE_*) unset "$name" ;; esac
done

GRACE="${DEV_STACK_GRACE:-30}"
case "$GRACE" in '' | *[!0-9]*) echo "dev-stack: DEV_STACK_GRACE is $GRACE, not a number of seconds." >&2; exit 1 ;; esac

LOCK=""
LOCK_FD=""
PRIVATE=""
PROJECT=""
IMAGE=""
SERVER=""
SERVER_ENDED=""
STARTED=""

die() {
  echo "dev-stack: $*" >&2
  exit 1
}

# Every service of the stack, builds included, with nothing interpolated
# from .env: what the services need from it arrives from the task in the
# environment. Once the lock has read the project, every call names it.
compose() {
  local project=()
  [ -z "$PROJECT" ] || project=(-p "$PROJECT")
  docker compose --env-file /dev/null "${project[@]}" --profile locus-builds \
    -f docker-compose.yml -f docker-compose.dev.yml "$@"
}

# lock_file PROJECT: the one lock of the project on this host.
lock_file() { printf '%s/%s.dev-stack.lock' "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" "$1"; }

# lock: the project's lock for the rest of this process, or a refusal
# naming the run that holds it. The project comes from the override alone,
# which compose resolves with no .env and no build; the server never
# inherits the lock.
lock() {
  command -v flock >/dev/null || die "flock is not on PATH (util-linux; brew install flock)."
  PROJECT="$(docker compose --env-file /dev/null -f docker-compose.dev.yml config 2>/dev/null | sed -n '1s/^name: //p')"
  [ -n "$PROJECT" ] || die "docker compose could not resolve docker-compose.dev.yml's project name."
  LOCK="$(lock_file "$PROJECT")"
  exec {LOCK_FD}>>"$LOCK"
  if ! flock -n "$LOCK_FD"; then
    local holder checkout
    holder="$(sed -n 's/^pid //p' "$LOCK" 2>/dev/null | head -n 1)"
    checkout="$(sed -n 's/^checkout //p' "$LOCK" 2>/dev/null | head -n 1)"
    LOCK_FD=""
    die "another run of the dev stack (pid ${holder:-unknown}, checkout ${checkout:-unknown}) holds $LOCK; stop it, or wait for it to end."
  fi
  # This run's pid and checkout, beside the server a killed run recorded,
  # which `down` and a start still read; the file stays the one the lock
  # is on.
  local recorded
  recorded="$(sed -n '/^server /p' "$LOCK")"
  printf 'pid %s\ncheckout %s\n%s' "$$" "$ROOT" "${recorded:+$recorded$'\n'}" >"$LOCK"
}

# orphan: the process group of the server a killed run recorded, when its
# leader is still the process the run started; nothing otherwise.
orphan() {
  local pgid started
  read -r pgid started < <(sed -n 's/^server //p' "$LOCK" 2>/dev/null) || return 0
  [ -n "${pgid:-}" ] && [ -n "${started:-}" ] || return 0
  [ "$(ps -o lstart= -p "$pgid" 2>/dev/null | sed 's/^ *//; s/ *$//')" = "$started" ] && echo "$pgid"
  return 0
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
  if [ -n "$STARTED" ]; then
    echo "dev-stack: removing the containers." >&2
    compose down --remove-orphans >/dev/null 2>&1 ||
      echo "dev-stack: the containers could not be removed; \`scripts/dev-stack.sh down\` removes them." >&2
  fi
  [ -z "$LOCK_FD" ] || : >"$LOCK"
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

# docker-compose.dev.yml resolved over docker-compose.yml into the private
# directory. Compose reads the shipped cyfr service's env_file even when
# it starts none of it, so a checkout with no .env gets an empty one,
# mode 0600, for the task to write into.
declarations() {
  [ -e .env ] || (umask 077 && : >.env) || die ".env could not be created here; check the checkout's permissions."
  compose config --format json locus-runtime locus-backends locus-builds >"$PRIVATE/stack.json" ||
    die "docker compose could not resolve docker-compose.dev.yml over docker-compose.yml."
  local out
  out="$(task names "$PRIVATE/stack.json" 2>&1)" || die "$(refusal "$out")"
  IMAGE="$(printf '%s\n' "$out" | sed -n 's/^image //p')"
  [ -n "$IMAGE" ] || die "mix cyfr.locus.dev_stack printed no image."
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

# held PORT: who listens on 127.0.0.1:PORT, by any address that covers
# it; fails, printing nothing, when the port is free.
held() {
  python3 -I -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(0)
sys.exit(1)' "$1" || return 1
  local who
  who="$(ss -Hltnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1 (pid \2)/p' | head -n 1)"
  [ -n "$who" ] || who="$(docker ps --filter "publish=$1" --format 'the container {{.Names}}' 2>/dev/null | head -n 1)"
  echo "${who:-a process this user cannot see}"
}

# free PORT WHAT: refuses, naming the holder, when PORT is taken.
free() {
  local who
  if who="$(held "$1")"; then
    die "127.0.0.1:$1, $2, is held by $who. Stop it and run again."
  fi
}

run() {
  command -v docker >/dev/null || die "docker is not on PATH."
  command -v python3 >/dev/null || die "python3 is not on PATH."
  lock
  private
  declarations

  echo "dev-stack: reading the settings; mix compiles the checkout first when it has changed."
  local out status line wrote="" setup="" server=() keys=() port="" runtime_port="" host_api_port=""
  out="$(task settings "$PRIVATE/stack.json" 2>&1)" &&
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
    case "$line" in
      CYFR_PORT=*) port="${line#*=}" ;;
      CYFR_LOCUS_RUNTIME_WORKERS=*) runtime_port="${line##*:}" ;;
      CYFR_HOST_API_PORT=*) host_api_port="${line#*=}" ;;
    esac
  done
  [ -n "$port" ] && [ -n "$runtime_port" ] && [ -n "$host_api_port" ] && [ "${#keys[@]}" = 3 ] ||
    die "mix cyfr.locus.dev_stack printed no settings."
  [ -z "$wrote" ] || echo "dev-stack: .env is mode 0600 and now sets ${wrote// /, }."

  local left who
  left="$(orphan)"
  if [ -n "$left" ] && who="$(held "$port")"; then
    die "127.0.0.1:$port, Prism's address, is held by $who, the server a killed run left; \`scripts/dev-stack.sh down\` stops it."
  fi
  free "$port" "Prism's address"
  # What an earlier run left when it ended without its cleanup is this
  # stack's: with Prism's address free, no run of it is serving.
  compose down --remove-orphans >/dev/null 2>&1 || true
  free "$runtime_port" "the runtime's listener"
  free "$host_api_port" "the host API's port"

  STARTED=1
  # Every service runs the one image, built once from the tree (from
  # compose's cache when nothing changed): built per service, the builds
  # of one tag race to export it.
  compose build locus-runtime || die "cyfr-locus did not build from the tree; the build's output ends above."
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
  (exec {LOCK_FD}>&- && export "${server[@]}" &&
    exec python3 -I -c 'import os, sys; os.setpgid(0, 0); os.execvp(sys.argv[1], sys.argv[1:])' mix phx.server </dev/null) &
  SERVER=$!
  printf 'pid %s\ncheckout %s\nserver %s %s\n' "$$" "$ROOT" "$SERVER" "$(ps -o lstart= -p "$SERVER")" >"$LOCK"
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
  declarations
  out="$(task endpoint "$PRIVATE/stack.json" 2>&1)" || die "$(refusal "$out")"
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
  private
  declarations
  local left
  left="$(orphan)"
  if [ -n "$left" ]; then
    echo "dev-stack: stopping the server a killed run left (process group $left)."
    stop "$left"
  fi
  compose down --remove-orphans
}

# clean: down, then the stack's image and nothing else of the host's.
clean() {
  down
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker image rm "$IMAGE"
  else
    echo "dev-stack: $IMAGE is not on this host."
  fi
}

case "${1:-}" in
  "") run ;;
  check) check ;;
  down) down ;;
  clean) clean ;;
  *)
    echo "usage: scripts/dev-stack.sh [check | down | clean]" >&2
    exit 2
    ;;
esac
