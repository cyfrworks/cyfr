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
#   scripts/dev-stack.sh down   remove the stack's containers and networks
#
# Every setting comes from `mix cyfr.locus.dev_stack`, which derives
# CYFR's from docker-compose.dev.yml as compose resolves it and reads .env
# and the environment as a mix boot does; this script reads neither file
# itself. The task's one edit of .env adds what a mix boot needs and
# nothing sets, after making the file mode 0600. The services' keys reach
# compose, and CYFR's settings the server, in their environments alone;
# nothing here prints a key or the check's bearer token.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PRIVATE=""
SERVER=""
STARTED=""

die() {
  echo "dev-stack: $*" >&2
  exit 1
}

# Every service of the stack, builds included, with nothing interpolated
# from .env: what the services need from it arrives from the task in the
# environment.
compose() {
  docker compose --env-file /dev/null --profile locus-builds -f docker-compose.yml -f docker-compose.dev.yml "$@"
}

# Ends every run, a signal's included: the server first, then every
# container and network of the stack. A second signal does not cut it
# short.
finish() {
  local status=$?
  trap '' INT TERM HUP
  if [ -n "$SERVER" ]; then
    kill -TERM "$SERVER" 2>/dev/null || true
    for _ in $(seq 1 300); do
      kill -0 "$SERVER" 2>/dev/null || break
      sleep 0.1
    done
    # Whatever is left of the server's process group: an asset watcher,
    # or a server that outlived its 30 seconds.
    kill -KILL -- "-$SERVER" 2>/dev/null || true
    wait "$SERVER" 2>/dev/null || true
  fi
  if [ -n "$STARTED" ]; then
    echo "dev-stack: removing the containers." >&2
    compose down --remove-orphans >/dev/null 2>&1 ||
      echo "dev-stack: the containers could not be removed; \`scripts/dev-stack.sh down\` removes them." >&2
  fi
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
  private
  declarations

  echo "dev-stack: reading the settings; mix compiles the checkout first when it has changed."
  local out status line wrote="" server=() keys=() port="" runtime_port="" host_api_port=""
  out="$(task settings "$PRIVATE/stack.json" "$(git config user.email 2>/dev/null || true)" 2>&1)" &&
    status=0 || status=$?
  [ "$status" = 0 ] || die "$(refusal "$out")"
  while IFS= read -r line; do
    case "$line" in
      "wrote "*) wrote="${line#wrote }" ;;
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

  free "$port" "Prism's address"
  # What an earlier run left when it ended without its cleanup is this
  # stack's: with Prism's address free, no run of it is serving.
  compose down --remove-orphans >/dev/null 2>&1 || true
  free "$runtime_port" "the runtime's listener"
  free "$host_api_port" "the host API's port"

  STARTED=1
  if ! (export "${keys[@]}" && compose up --detach --build --wait locus-runtime locus-backends locus-builds); then
    compose logs --tail 30 >&2 || true
    die "the containers did not start; their logs end above."
  fi

  printf '\n%s\n%s\n%s\n\n' \
    "dev-stack: the runtime, backends and builds services run from this tree." \
    "dev-stack: CYFR starts at http://localhost:$port and reloads as its files change." \
    "dev-stack: Ctrl-C stops it and removes the containers."
  # The server in a process group of its own, so the whole of it stops
  # with the run, and its settings in its environment alone. The run, not
  # the terminal, stops it: Ctrl-C reaches the script, whose exit stops
  # the server and then the containers.
  (export "${server[@]}" &&
    exec python3 -I -c 'import os, sys; os.setpgid(0, 0); os.execvp(sys.argv[1], sys.argv[1:])' mix phx.server </dev/null) &
  SERVER=$!
  wait "$SERVER" && status=0 || status=$?
  SERVER=""
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
  private
  declarations
  compose down --remove-orphans
}

case "${1:-}" in
  "") run ;;
  check) check ;;
  down) down ;;
  *)
    echo "usage: scripts/dev-stack.sh [check | down]" >&2
    exit 2
    ;;
esac
