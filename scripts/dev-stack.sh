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
# `up` gives .env a CYFR_LOCUS_RUNTIME_ROOT when neither it nor the
# environment holds one, and keeps one that is there. The runtime's key is
# derived from it by `mix cyfr.locus.runtime_key` and handed to compose in
# the environment alone; nothing here prints it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# What docker-compose.dev.yml declares, which the mix boot must agree with.
SERVICE_ID=wrk_local
WORKERS=$SERVICE_ID=http://127.0.0.1:4200
HOST_API_BIND=172.16.231.1

die() {
  echo "dev-stack: $*" >&2
  exit 1
}

compose() {
  docker compose -f docker-compose.yml -f docker-compose.dev.yml "$@"
}

# NAME's value as a mix boot reads it: the environment's when set, else the
# last assignment in .env, its quotes removed; empty when neither sets it.
setting() {
  local name="$1" value
  value="${!name:-}"
  if [ -z "$value" ] && [ -f .env ]; then
    value="$(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?$name=(.*)$/\2/p" .env | tail -n 1)"
    value="$(printf '%s' "$value" | sed -E "s/^[[:space:]]*//; s/[[:space:]]*$//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/")"
  fi
  printf '%s' "$value"
}

# A setting the mix boot reads that would send its runs, or the runtime's
# host calls, somewhere this stack is not.
agree() {
  local name="$1" want="$2" have
  have="$(setting "$name")"
  if [ -n "$have" ] && [ "$have" != "$want" ]; then
    die "$name is $have, and this stack needs $want. Unset it in .env and the environment, or set it to $want."
  fi
}

up() {
  command -v docker >/dev/null || die "docker is not on PATH."
  command -v openssl >/dev/null || die "openssl is not on PATH."

  local port root out key
  port="$(setting CYFR_HOST_API_PORT)"
  port="${port:-4300}"
  agree CYFR_LOCUS_RUNTIME_WORKERS "$WORKERS"
  agree CYFR_HOST_API_BIND "$HOST_API_BIND"
  agree CYFR_HOST_API_URL "http://$HOST_API_BIND:$port"

  root="$(setting CYFR_LOCUS_RUNTIME_ROOT)"
  if [ -z "$root" ]; then
    root="$(openssl rand -hex 32)"
    (umask 077 && touch .env)
    [ -z "$(tail -c 1 .env)" ] || echo >>.env
    echo "CYFR_LOCUS_RUNTIME_ROOT=$root" >>.env
    echo "dev-stack: .env holds a new CYFR_LOCUS_RUNTIME_ROOT."
  fi

  # The one derivation of a worker service's key from the root.
  if ! out="$(CYFR_LOCUS_RUNTIME_ROOT="$root" mix cyfr.locus.runtime_key "$SERVICE_ID" 2>&1)"; then
    die "the runtime's key could not be derived: $(printf '%s\n' "$out" | grep -v '^LOCUS_RUNTIME_KEY=' | tail -n 3)"
  fi
  key="$(printf '%s\n' "$out" | sed -n 's/^LOCUS_RUNTIME_KEY=//p')"
  [ -n "$key" ] || die "mix cyfr.locus.runtime_key printed no key."

  LOCUS_RUNTIME_KEY="$key" compose up --detach --build --wait locus-runtime ||
    die "the runtime did not start; \`docker logs cyfr-dev-locus-runtime\` says why."

  cat <<EOF

The runtime runs from this tree: cyfr-locus:dev as $SERVICE_ID on 127.0.0.1:4200.
Start CYFR from the umbrella root, its host API on the runtime network's gateway:

  CYFR_HOST_API_BIND=$HOST_API_BIND mix phx.server

Then \`scripts/dev-stack.sh check\` runs a component through it, and
\`scripts/dev-stack.sh down\` stops the runtime.
EOF
}

# files ACTION ARGUMENTS_JSON: one run of the shipped files catalyst
# through the server's /mcp as the person CYFR_TOKEN signs in, its result
# printed as JSON; a refusal or a failed run ends the check naming it.
files() {
  local body answer
  body="$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"execution","arguments":{"action":"run","reference":"catalyst:local.files","input":{"action":"%s",%s}},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"dev-stack","version":"0"},"io.modelcontextprotocol/clientCapabilities":{}}}}' "$1" "$2")"
  answer="$(curl -sS -m 120 -X POST "$MCP" \
    -H "authorization: Bearer $CYFR_TOKEN" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' -H 'mcp-protocol-version: 2026-07-28' \
    -H 'mcp-method: tools/call' -H 'mcp-name: execution' -d "$body")" ||
    die "$MCP did not answer: is \`mix phx.server\` running?"
  printf '%s' "$answer" | python3 -I -c '
import json, sys
action, raw = sys.argv[1], sys.stdin.read()
try:
    reply = json.loads(raw)
except ValueError:
    sys.exit("%s: the server answered %r" % (action, raw[:300]))
if "error" in reply:
    sys.exit("%s: refused: %s" % (action, reply["error"].get("message")))
result = reply["result"]
text = result["content"][0]["text"]
if result.get("isError"):
    sys.exit("%s: the run failed: %s" % (action, text))
run = json.loads(text)
print("%s: execution %s %s" % (action, run.get("execution_id"), run.get("status")), file=sys.stderr)
if run.get("status") != "completed":
    sys.exit("%s: the run ended %s: %s" % (action, run.get("status"), text))
print(json.dumps(run.get("result")))' "$1"
}

check() {
  [ -n "${CYFR_TOKEN:-}" ] ||
    die "CYFR_TOKEN is not set: the check runs a component as a signed-in person. Create an API key on Prism's API Keys page, or sign the dev CLI in with \`cyfr login\`, and pass the key or the session token as CYFR_TOKEN."
  local port nonce path written read content
  port="$(setting CYFR_PORT)"
  MCP="http://127.0.0.1:${port:-4000}/mcp"
  nonce="dev-stack-$(openssl rand -hex 8)"
  path="data/dev-stack-check-$nonce.txt"

  written="$(files write_text "\"path\":\"$path\",\"content\":\"$nonce\"")" || exit 1
  read="$(files read_text "\"path\":\"$path\"")" || exit 1
  files delete "\"path\":\"$path\"" >/dev/null || exit 1
  content="$(printf '%s' "$read" | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("content"))')"
  [ "$content" = "$nonce" ] ||
    die "the runtime read back ${content@Q} from $path, not ${nonce@Q} (write answered $written)"
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
