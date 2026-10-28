#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The source development stack (CONTRIBUTING.md, "Running from source"):
# the locus-runtime container built from this checkout
# (docker-compose.dev.yml), beside a control plane run from the checkout
# with `mix phx.server`.
#
#   scripts/dev-stack.sh [up]   build the runtime from the tree and start it,
#                               then print the command that starts CYFR
#   scripts/dev-stack.sh check  run a component through the running server
#                               as a signed-in person and assert its answer
#   scripts/dev-stack.sh down   stop and remove the runtime container
#
# Every setting comes from `mix cyfr.locus.dev_stack`, which reads .env and
# the environment as a mix boot does; this script reads no .env itself.
# Its one edit of .env is the runtime root `up` writes when none is set,
# after making the file mode 0600. The runtime's key reaches compose in the
# environment alone, and the check's bearer token in a header file of its
# own; nothing here prints either.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# What docker-compose.dev.yml declares, which the mix boot must agree with.
SERVICE_ID=wrk_local
WORKER_URL=http://127.0.0.1:4200
HOST_API_BIND=172.16.231.1

PRIVATE=""
trap '[ -z "$PRIVATE" ] || rm -rf "$PRIVATE"' EXIT

die() {
  echo "dev-stack: $*" >&2
  exit 1
}

compose() {
  docker compose -f docker-compose.yml -f docker-compose.dev.yml "$@"
}

# The refusal in the task's output: its `** (Mix)` sentence, else its last
# lines.
refusal() {
  local said
  said="$(printf '%s\n' "$1" | sed -n 's/^\*\* (Mix) //p')"
  printf '%s' "${said:-$(printf '%s\n' "$1" | grep -v '^LOCUS_RUNTIME_KEY=' | tail -n 3)}"
}

# The value of NAME=value in the task's output.
line() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }

# The runtime root `up` writes when none is set: the file made mode 0600
# first, since it then holds a secret.
provision() {
  (umask 077 && touch .env) || die ".env could not be created here; check the checkout's permissions."
  chmod 600 .env || die ".env could not be made mode 0600; make it yours (chown) and run again."
  case "$(ls -ln .env)" in
    -rw-------*) ;;
    *) die ".env is not mode 0600 after chmod; put the checkout on a filesystem that keeps modes, or set CYFR_LOCUS_RUNTIME_ROOT yourself." ;;
  esac
  [ -z "$(tail -c 1 .env)" ] || echo >>.env
  echo "CYFR_LOCUS_RUNTIME_ROOT=$(openssl rand -hex 32)" >>.env
  echo "dev-stack: .env is mode 0600 and holds a new CYFR_LOCUS_RUNTIME_ROOT."
}

up() {
  command -v docker >/dev/null || die "docker is not on PATH."
  command -v openssl >/dev/null || die "openssl is not on PATH."

  local out status key port
  out="$(mix cyfr.locus.dev_stack key "$SERVICE_ID" "$WORKER_URL" "$HOST_API_BIND" 2>&1)" && status=0 || status=$?
  if [ "$status" = 3 ]; then
    provision
    out="$(mix cyfr.locus.dev_stack key "$SERVICE_ID" "$WORKER_URL" "$HOST_API_BIND" 2>&1)" && status=0 || status=$?
  fi
  [ "$status" = 0 ] || die "$(refusal "$out")"
  key="$(line LOCUS_RUNTIME_KEY "$out")"
  port="$(line CYFR_HOST_API_PORT "$out")"
  [ -n "$key" ] && [ -n "$port" ] || die "mix cyfr.locus.dev_stack printed no key or no port."

  LOCUS_RUNTIME_KEY="$key" CYFR_HOST_API_PORT="$port" compose up --detach --build --wait locus-runtime ||
    die "the runtime did not start; \`docker logs cyfr-dev-locus-runtime\` says why."

  cat <<EOF

The runtime runs from this tree: cyfr-locus:dev as $SERVICE_ID on ${WORKER_URL#http://}.
Start CYFR from the umbrella root, its host API on the runtime network's gateway:

  CYFR_HOST_API_BIND=$HOST_API_BIND mix phx.server

Then \`scripts/dev-stack.sh check\` runs a component through it, and
\`scripts/dev-stack.sh down\` stops the runtime.
EOF
}

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
    echo "$1: $MCP did not answer ($answer): is \`mix phx.server\` running?"
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
  out="$(mix cyfr.locus.dev_stack endpoint 2>&1)" || die "$(refusal "$out")"
  port="$(line CYFR_PORT "$out")"
  [ -n "$port" ] || die "mix cyfr.locus.dev_stack printed no port."
  MCP="http://127.0.0.1:$port/mcp"

  PRIVATE="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-dev-stack.XXXXXX")"
  chmod 700 "$PRIVATE"
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
  [ -f .env ] || die "no .env: this checkout has no dev stack to stop."
  compose down
}

case "${1:-up}" in
  up) up ;;
  check) check ;;
  down) down ;;
  *)
    echo "usage: scripts/dev-stack.sh [up|check|down]" >&2
    exit 2
    ;;
esac
