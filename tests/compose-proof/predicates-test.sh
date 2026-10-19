#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Compose proof's whole-object predicates (tests/compose-proof/
# predicates.sh) on canned objects: each passes the object a case expects,
# and fails when any field it holds is changed, dropped or added to.
#
#   head_holds          every head field (port, email, builds URL, profiles
#                       and the services they start, the node id read from
#                       the tailnet state) in .env and in the running cyfr
#   serve_config_holds  the complete Serve configuration
#   preview_holds       the complete preview: old and new words and the
#                       address-change steps
#   cookie_holds        the exact signed-out and signed-in redirects
#   same_refusal        a forged anonymous request refused as the plain one
#   capabilities_hold   each proxy's capabilities and security options
#
# Usage: bash tests/compose-proof/predicates-test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/compose-proof/predicates.sh
source "$ROOT/tests/compose-proof/predicates.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-compose-predicates.XXXXXX")" || exit 1
trap 'rm -rf "$scratch"' EXIT

failures=0
cases=0
expect() {
  local want="$1" what="$2" out code
  shift 2
  cases=$((cases + 1))
  out="$("$@" 2>&1)"
  code=$?
  if { [ "$want" = pass ] && [ "$code" -eq 0 ]; } || { [ "$want" = fail ] && [ "$code" -ne 0 ] && [ -n "$out" ]; }; then
    echo "PASS: $what"
  else
    echo "FAIL: $what (exit $code)"
    printf '%s\n' "$out" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

# ---- head_holds --------------------------------------------------------------

# A tailnet head as the proof expects one, .env as cyfr reach writes it,
# and the running cyfr's environment from it.
node=nProofB1CNTRL
tailnet_head='{"mode":"tailnet","host":"cyfr-1.proof.ts.net","port":4000,"public_url":"https://cyfr-1.proof.ts.net","node_id":"'"$node"'","profiles":["tailnet"]}'
cat >"$scratch/env" <<ENV
# a comment
CYFR_SECRET_KEY_BASE='kept'
CYFR_REACH=tailnet
CYFR_HOST=cyfr-1.proof.ts.net
CYFR_PORT=4000
CYFR_PUBLIC_URL=https://cyfr-1.proof.ts.net
CYFR_TAILNET_NODE_ID=$node
CADDY_ACME_EMAIL=
CYFR_LOCUS_BUILDS_URL=
ENV
container_env() {
  python3 -I -c '
import json, sys
env = ["PATH=/usr/bin", "CYFR_SECRET_KEY_BASE=kept"]
for line in open(sys.argv[1]).read().splitlines():
    if line and not line.startswith("#"):
        env.append(line.replace("\x27", ""))
print(json.dumps(env))' "$1"
}
holds() { head_holds "$1" "$2" "$(container_env "${3:-$2}")" "${4:-cyfr tailscale}" "${5:-$node}"; }
expect pass "a tailnet head, held whole in .env and the running cyfr" holds "$tailnet_head" "$scratch/env"
edit() {
  sed "$1" "$scratch/env" >"$scratch/$2"
}
edit 's/^CYFR_PORT=4000$/CYFR_PORT=4001/' port
expect fail "another port in .env" holds "$tailnet_head" "$scratch/port" "$scratch/env"
expect fail "another port in the running cyfr" holds "$tailnet_head" "$scratch/env" "$scratch/port"
edit 's/^CADDY_ACME_EMAIL=$/CADDY_ACME_EMAIL=ops@example.com/' email
expect fail "an email the head has none of" holds "$tailnet_head" "$scratch/email"
edit 's|^CYFR_LOCUS_BUILDS_URL=$|CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100|' builds
expect fail "a builds URL the head has none of" holds "$tailnet_head" "$scratch/builds"
edit '/^CYFR_PUBLIC_URL=/d' nourl
expect fail "the head's public URL missing" holds "$tailnet_head" "$scratch/nourl"
edit 's/^CYFR_HOST=.*/CYFR_HOST=cyfr.proof.ts.net/' host
expect fail "another host" holds "$tailnet_head" "$scratch/host"
edit 's/^CYFR_REACH=.*/CYFR_REACH=public/' mode
expect fail "another mode" holds "$tailnet_head" "$scratch/mode"
edit "s/^CYFR_TAILNET_NODE_ID=.*/CYFR_TAILNET_NODE_ID=nOtherCNTRL/" nodeid
expect fail "a node id in .env other than the state's" holds "$tailnet_head" "$scratch/nodeid" "$scratch/nodeid"
expect fail "a state holding another node" holds "$tailnet_head" "$scratch/env" "$scratch/env" "cyfr tailscale" nOtherCNTRL
expect fail "a proxy running that no profile starts" holds "$tailnet_head" "$scratch/env" "$scratch/env" "caddy cyfr tailscale"
expect fail "the profile's proxy not running" holds "$tailnet_head" "$scratch/env" "$scratch/env" "cyfr"
expect fail "an expected head with a profile the proof knows no proxy of" \
  holds '{"mode":"tailnet","host":"cyfr-1.proof.ts.net","port":4000,"public_url":"https://cyfr-1.proof.ts.net","node_id":"'"$node"'","profiles":["locus-builds","tailnet"]}' "$scratch/env"
expect fail "an expected head with a field no reach setting holds" holds "${tailnet_head%\}},\"extra\":1}" "$scratch/env"
expect fail "a running cyfr whose environment cannot be read" \
  head_holds "$tailnet_head" "$scratch/env" "not json" "cyfr tailscale" "$node"
local_head='{"mode":"local","host":"localhost","port":4000,"profiles":[]}'
printf 'CYFR_REACH=local\nCYFR_HOST=localhost\nCYFR_PORT=4000\n' >"$scratch/local"
expect pass "a local head" holds "$local_head" "$scratch/local" "$scratch/local" cyfr ""
printf 'CYFR_REACH=local\nCYFR_HOST=localhost\nCYFR_PORT=4000\nCYFR_PUBLIC_URL=http://localhost:4000\n' >"$scratch/local-url"
expect fail "a local .env with a public URL added" holds "$local_head" "$scratch/local-url" "$scratch/local-url" cyfr ""

# ---- serve_config_holds ------------------------------------------------------

serve='{"TCP":{"443":{"HTTPS":true}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4001"}}}}}'
expect pass "the engine's Serve configuration" serve_config_holds "$serve" cyfr.proof.ts.net 4001
for mutated in \
  '{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4001"}}}}}' \
  '{"TCP":{"443":{"HTTPS":true}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4001"},"/x":{"Proxy":"http://cyfr:4000"}}}}}' \
  '{"TCP":{"443":{"HTTPS":true}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4001"}}}},"AllowFunnel":{"cyfr.proof.ts.net:443":true}}' \
  '{"TCP":{"443":{"HTTPS":true}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4000"}}}}}' \
  '{"TCP":{"443":{"HTTPS":true}},"Web":{"other.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4001"}}}}}' \
  '{"TCP":{"443":{"HTTPS":false}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4001"}}}}}' \
  '{}' 'not json'; do
  expect fail "a Serve configuration other than the engine's: ${mutated:0:90}" serve_config_holds "$mutated" cyfr.proof.ts.net 4001
done

# ---- preview_holds -----------------------------------------------------------

a='{"mode":"tailnet","host":"cyfr.proof.ts.net","port":4000,"public_url":"https://cyfr.proof.ts.net","node_id":"nA","profiles":["tailnet"]}'
b='{"mode":"tailnet","host":"cyfr-1.proof.ts.net","port":4000,"public_url":"https://cyfr-1.proof.ts.net","node_id":"nB","profiles":["tailnet"]}'
changes="$(python3 -I -c '
import json, re, sys
m = re.search(r"var addressChanges = \[\]string\{(.*?)\n\}", open(sys.argv[1]).read(), re.S)
for i, s in enumerate(re.findall(r"\"(?:[^\"\\\\]|\\\\.)*\"", m.group(1)), 1):
    print(f"  {i}. {json.loads(s)}")' "$ROOT/apps/codex/internal/reach/switch.go")"
cat >"$scratch/preview" <<LOG
\$ cyfr reach tailnet
This changes how this home is reached:
  Who can reach this home: your devices on Tailscale, and people you share this machine with → your devices on Tailscale, and people you share this machine with
  Address: https://cyfr.proof.ts.net → https://cyfr-1.proof.ts.net
  Certificate email: none → none
  Ports opened on this machine: none → none
The address changes, so:
$changes
Your CYFR identity does not change.
Error: The change above was shown, not made: cyfr reach makes a change only once it is confirmed, and there is no terminal to confirm it on. Nothing was changed. Run it again with --yes to make the change, or on a terminal to confirm it
LOG
expect pass "the complete preview of A to B" preview_holds "$scratch/preview" "$a" "$b"
mutate_preview() {
  sed "$1" "$scratch/preview" >"$scratch/preview-$2"
  expect fail "$3" preview_holds "$scratch/preview-$2" "$a" "$b"
}
mutate_preview 's|https://cyfr.proof.ts.net → https://cyfr-1.proof.ts.net|https://cyfr-1.proof.ts.net → https://cyfr.proof.ts.net|' swapped "the transition shown the wrong way"
mutate_preview 's|  Certificate email: none → none|  Certificate email: none → ops@example.com|' email "another new email shown"
mutate_preview 's|  Ports opened on this machine: none → none|  Ports opened on this machine: none → 80 and 443|' ports "other new ports shown"
mutate_preview 's|Who can reach this home: your devices|Who can reach this home: anyone|' who "another old audience shown"
mutate_preview '/^  2\. /d' step "an address-change step dropped"
mutate_preview '/^Your CYFR identity/a\  5. An extra step.' extra "a line added to the preview"
# shellcheck disable=SC2016
mutate_preview '$d' refusal "the refusal after it missing"
expect fail "the preview read against another new head" preview_holds "$scratch/preview" "$a" "${b//cyfr-1/cyfr-2}"
expect fail "the preview read against another old head" preview_holds "$scratch/preview" "${a//cyfr.proof/cyfr-0.proof}" "$b"

# ---- cookie_holds ------------------------------------------------------------

unsigned='{"status":302,"headers":{"Location":["/login"]},"body":""}'
signed='{"status":302,"headers":{"Location":["/chat?a=%40compose-proof"]},"body":""}'
expect pass "signed out to /login, signed in to the person's chat" cookie_holds "$unsigned" "$signed" "@compose-proof"
expect fail "a signed 500" cookie_holds "$unsigned" '{"status":500,"headers":{},"body":"oops"}' "@compose-proof"
expect fail "a signed redirect elsewhere" cookie_holds "$unsigned" '{"status":302,"headers":{"Location":["/a/other"]},"body":""}' "@compose-proof"
expect fail "another person's chat" cookie_holds "$unsigned" '{"status":302,"headers":{"Location":["/chat?a=%40someone-else"]},"body":""}' "@compose-proof"
expect fail "an unchanged principal (signed answered as unsigned)" cookie_holds "$unsigned" "$unsigned" "@compose-proof"
expect fail "a signed-out page served" cookie_holds '{"status":200,"headers":{},"body":"page"}' "$signed" "@compose-proof"
expect fail "no answer with the cookie" cookie_holds "$unsigned" '{"error":"tls","detail":"x"}' "@compose-proof"

# ---- same_refusal ------------------------------------------------------------

rpc_refusal='{"status":200,"headers":{},"body":"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32001,\"message\":\"Authentication required\"}}"}'
expect pass "a forged anonymous MCP request refused as the plain one" same_refusal "$rpc_refusal" "$rpc_refusal"
expect fail "the forged one answered with a result" same_refusal "$rpc_refusal" \
  '{"status":200,"headers":{},"body":"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}"}'
expect fail "the forged one refused with another code" same_refusal "$rpc_refusal" \
  '{"status":200,"headers":{},"body":"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"x\"}}"}'
expect fail "the forged one with another status" same_refusal "$rpc_refusal" \
  '{"status":401,"headers":{},"body":"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32001,\"message\":\"x\"}}"}'
expect fail "a plain anonymous request that was not refused" same_refusal '{"status":200,"headers":{},"body":"page"}' '{"status":200,"headers":{},"body":"page"}'
page_plain=$'IP=172.16.234.9\nHTTP/1.1 302 Found\nLocation: /login\n\n\nSTATUS=302'
expect pass "a forged anonymous page request redirected as the plain one" same_refusal "$page_plain" "$page_plain"
expect fail "the forged one sent elsewhere" same_refusal "$page_plain" $'IP=172.16.234.9\nHTTP/1.1 302 Found\nLocation: /chat?a=%40x\n\n\nSTATUS=302'
expect fail "the forged one served" same_refusal "$page_plain" $'IP=172.16.234.9\nHTTP/1.1 200 OK\n\npage\nSTATUS=200'
expect fail "the forged one got no answer" same_refusal "$page_plain" $'IP=172.16.234.9\n\n\nSTATUS=refused'

# ---- capabilities_hold -------------------------------------------------------

caddy='{"CapDrop":["ALL"],"CapAdd":["NET_BIND_SERVICE"],"SecurityOpt":["no-new-privileges:true"]}'
tailscale='{"CapDrop":["ALL"],"CapAdd":null,"SecurityOpt":["no-new-privileges:true"]}'
status_with() { printf 'Name:\tx\nCapInh:\t0000000000000000\nCapPrm:\t%s\nCapEff:\t%s\nCapBnd:\t%s\n' "$1" "$1" "$1"; }
expect pass "caddy: ALL dropped, NET_BIND_SERVICE added and effective alone" capabilities_hold caddy "$caddy" "$(status_with 0000000000000400)"
expect pass "caddy, its capability named as Docker may name it" \
  capabilities_hold caddy '{"CapDrop":["ALL"],"CapAdd":["CAP_NET_BIND_SERVICE"],"SecurityOpt":["no-new-privileges:true"]}' "$(status_with 0000000000000400)"
expect pass "tailscale: nothing effective" capabilities_hold tailscale "$tailscale" "$(status_with 0000000000000000)"
expect fail "caddy with NET_RAW effective too" capabilities_hold caddy "$caddy" "$(status_with 0000000000002400)"
expect fail "caddy with NET_RAW added" \
  capabilities_hold caddy '{"CapDrop":["ALL"],"CapAdd":["NET_BIND_SERVICE","NET_RAW"],"SecurityOpt":["no-new-privileges:true"]}' "$(status_with 0000000000000400)"
expect fail "caddy keeping the default set" \
  capabilities_hold caddy '{"CapDrop":null,"CapAdd":["NET_BIND_SERVICE"],"SecurityOpt":["no-new-privileges:true"]}' "$(status_with 00000000a80425fb)"
expect fail "tailscale with a capability effective" capabilities_hold tailscale "$tailscale" "$(status_with 0000000000000400)"
expect fail "tailscale without no-new-privileges" \
  capabilities_hold tailscale '{"CapDrop":["ALL"],"CapAdd":null,"SecurityOpt":null}' "$(status_with 0000000000000000)"
expect fail "tailscale with another security option" \
  capabilities_hold tailscale '{"CapDrop":["ALL"],"CapAdd":null,"SecurityOpt":["no-new-privileges:true","apparmor=unconfined"]}' "$(status_with 0000000000000000)"
expect fail "a process status with no CapEff" capabilities_hold tailscale "$tailscale" "Name: x"

echo "$cases cases, $failures failed"
[ "$failures" -eq 0 ]
