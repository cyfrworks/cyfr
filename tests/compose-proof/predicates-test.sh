#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Compose proof's whole-object predicates (tests/compose-proof/
# predicates.sh) on canned objects: each passes the object a case expects,
# and fails when any field it holds is changed, dropped or added to.
#
#   head_holds          every head field (port, email, builds URL, profiles
#                       and the services they start, the node id and name
#                       read from the tailnet state) in .env and in the
#                       running cyfr
#   serve_config_holds  the complete Serve configuration
#   preview_holds       the complete preview: old and new words, the
#                       address-change steps and the command's refusal
#   cookie_holds        the exact signed-out and signed-in redirects
#   anonymous_refused   a forged anonymous request and the plain one each
#                       refused as the home refuses an anonymous request
#                       of its kind
#   capabilities_hold   each proxy's capabilities and security options
#   published_ports_hold every binding a mode publishes, including loopback SOCKS5
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

# ---- published_ports_hold ----------------------------------------------------

local_ports='cyfr 127.0.0.1:4000:4000/tcp'
tailnet_ports="$local_ports
tailscale 127.0.0.1:1055:1055/tcp"
public_ports="$local_ports
caddy :80:80/tcp
caddy :443:443/tcp
caddy :443:443/udp"
expect pass "local publishes only the endpoint's loopback listener" published_ports_hold "$local_ports" "$local_ports"
expect pass "tailnet adds the sidecar's SOCKS5 on loopback" published_ports_hold "$tailnet_ports" "$tailnet_ports"
expect pass "public adds Caddy's TCP and UDP ports" published_ports_hold "$public_ports" "$public_ports"
expect fail "a missing SOCKS5 publication" published_ports_hold "$local_ports" "$tailnet_ports"
expect fail "SOCKS5 on all host interfaces" published_ports_hold "${tailnet_ports/127.0.0.1:1055/0.0.0.0:1055}" "$tailnet_ports"
expect fail "another SOCKS5 host port" published_ports_hold "${tailnet_ports/:1055:1055/:1056:1055}" "$tailnet_ports"
expect fail "another SOCKS5 container port" published_ports_hold "${tailnet_ports/:1055\/tcp/:1056\/tcp}" "$tailnet_ports"
expect fail "SOCKS5 published as UDP" published_ports_hold "${tailnet_ports/1055\/tcp/1055\/udp}" "$tailnet_ports"
expect fail "SOCKS5 published in local" published_ports_hold "$tailnet_ports" "$local_ports"
expect fail "a missing public UDP port" published_ports_hold "${public_ports%$'\n'*}" "$public_ports"
expect fail "a duplicate publication" published_ports_hold "$tailnet_ports
$local_ports" "$tailnet_ports"
expect fail "an added service publication" published_ports_hold "$tailnet_ports
planted 127.0.0.1:1234:1234/tcp" "$tailnet_ports"

# ---- head_holds --------------------------------------------------------------

# A tailnet head as the proof expects one, .env as cyfr access writes it,
# and the running cyfr's environment from it.
node=nProofB1CNTRL
tailnet_head='{"mode":"tailnet","host":"cyfr-1.proof.ts.net","port":4000,"public_url":"https://cyfr-1.proof.ts.net","node_id":"'"$node"'","profiles":["tailnet"]}'
cat >"$scratch/env" <<ENV
# a comment
CYFR_SECRET_KEY_BASE='kept'
CYFR_ACCESS=tailnet
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
# `$6` the machine's name as the tailnet state holds it (Self.DNSName).
holds() { head_holds "$1" "$2" "$(container_env "${3:-$2}")" "${4:-cyfr tailscale}" "${5:-$node}" "${6-cyfr-1.proof.ts.net.}"; }
expect pass "a tailnet head, held whole in .env and the running cyfr" holds "$tailnet_head" "$scratch/env"
# .env and the running cyfr agreeing on a name the tailnet state does not
# hold, the head expected from them: the state's name is the expectation.
wrong_head="${tailnet_head//cyfr-1.proof.ts.net/wrong.proof.ts.net}"
sed 's/cyfr-1\.proof\.ts\.net/wrong.proof.ts.net/g' "$scratch/env" >"$scratch/wrong"
expect fail "a .env and running cyfr agreeing on a name other than the state's" holds "$wrong_head" "$scratch/wrong"
expect pass "the same head where the state holds that name" holds "$wrong_head" "$scratch/wrong" "" "" "" wrong.proof.ts.net.
expect fail "a state name read without its trailing dot" holds "$tailnet_head" "$scratch/env" "" "" "" cyfr-1.proof.ts.net
expect fail "a tailnet head with no name read from the state" holds "$tailnet_head" "$scratch/env" "" "" "" ""
url_head="${tailnet_head//https:\/\/cyfr-1.proof.ts.net/https://cyfr-1.proof.ts.net:8443}"
sed 's|^CYFR_PUBLIC_URL=.*|CYFR_PUBLIC_URL=https://cyfr-1.proof.ts.net:8443|' "$scratch/env" >"$scratch/url"
expect fail "a public URL other than the state's name's, held in .env and the running cyfr" holds "$url_head" "$scratch/url"
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
edit 's/^CYFR_ACCESS=.*/CYFR_ACCESS=public/' mode
expect fail "another mode" holds "$tailnet_head" "$scratch/mode"
edit "s/^CYFR_TAILNET_NODE_ID=.*/CYFR_TAILNET_NODE_ID=nOtherCNTRL/" nodeid
expect fail "a node id in .env other than the state's" holds "$tailnet_head" "$scratch/nodeid" "$scratch/nodeid"
expect fail "a state holding another node" holds "$tailnet_head" "$scratch/env" "$scratch/env" "cyfr tailscale" nOtherCNTRL
expect fail "a proxy running that no profile starts" holds "$tailnet_head" "$scratch/env" "$scratch/env" "caddy cyfr tailscale"
expect fail "the profile's proxy not running" holds "$tailnet_head" "$scratch/env" "$scratch/env" "cyfr"
expect fail "an expected head with a profile the proof knows no proxy of" \
  holds '{"mode":"tailnet","host":"cyfr-1.proof.ts.net","port":4000,"public_url":"https://cyfr-1.proof.ts.net","node_id":"'"$node"'","profiles":["locus-builds","tailnet"]}' "$scratch/env"
expect fail "an expected head with a field no access setting holds" holds "${tailnet_head%\}},\"extra\":1}" "$scratch/env"
expect fail "a running cyfr whose environment cannot be read" \
  head_holds "$tailnet_head" "$scratch/env" "not json" "cyfr tailscale" "$node"
local_head='{"mode":"local","host":"localhost","port":4000,"profiles":[]}'
printf 'CYFR_ACCESS=local\nCYFR_HOST=localhost\nCYFR_PORT=4000\n' >"$scratch/local"
expect pass "a local head" holds "$local_head" "$scratch/local" "$scratch/local" cyfr ""
printf 'CYFR_ACCESS=local\nCYFR_HOST=localhost\nCYFR_PORT=4000\nCYFR_PUBLIC_URL=http://localhost:4000\n' >"$scratch/local-url"
expect fail "a local .env with a public URL added" holds "$local_head" "$scratch/local-url" "$scratch/local-url" cyfr ""

# ---- serve_config_holds ------------------------------------------------------

serve='{"TCP":{"443":{"HTTPS":true}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4401"}}}}}'
expect pass "the engine's Serve configuration" serve_config_holds "$serve" cyfr.proof.ts.net 4401
for mutated in \
  '{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4401"}}}}}' \
  '{"TCP":{"443":{"HTTPS":true}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4401"},"/x":{"Proxy":"http://cyfr:4000"}}}}}' \
  '{"TCP":{"443":{"HTTPS":true}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4401"}}}},"AllowFunnel":{"cyfr.proof.ts.net:443":true}}' \
  '{"TCP":{"443":{"HTTPS":true}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4000"}}}}}' \
  '{"TCP":{"443":{"HTTPS":true}},"Web":{"other.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4401"}}}}}' \
  '{"TCP":{"443":{"HTTPS":false}},"Web":{"cyfr.proof.ts.net:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4401"}}}}}' \
  '{}' 'not json'; do
  expect fail "a Serve configuration other than the engine's: ${mutated:0:90}" serve_config_holds "$mutated" cyfr.proof.ts.net 4401
done

# ---- preview_holds -----------------------------------------------------------

a='{"mode":"tailnet","host":"cyfr.proof.ts.net","port":4000,"public_url":"https://cyfr.proof.ts.net","node_id":"nA","profiles":["tailnet"]}'
b='{"mode":"tailnet","host":"cyfr-1.proof.ts.net","port":4000,"public_url":"https://cyfr-1.proof.ts.net","node_id":"nB","profiles":["tailnet"]}'
changes="$(python3 -I -c '
import json, re, sys
m = re.search(r"var addressChanges = \[\]string\{(.*?)\n\}", open(sys.argv[1]).read(), re.S)
for i, s in enumerate(re.findall(r"\"(?:[^\"\\\\]|\\\\.)*\"", m.group(1)), 1):
    print(f"  {i}. {json.loads(s)}")' "$ROOT/apps/codex/internal/access/switch.go")"
cat >"$scratch/preview" <<LOG
\$ cyfr access tailnet
This changes how this home is reached:
  Who can reach this home: your devices on Tailscale, and people you share this machine with → your devices on Tailscale, and people you share this machine with
  Address: https://cyfr.proof.ts.net → https://cyfr-1.proof.ts.net
  Certificate email: none → none
  Ports opened on this machine: none → none
  Tailnet machine: cyfr.proof.ts.net (nA) → cyfr-1.proof.ts.net (nB)
The address changes, so:
$changes
Your CYFR identity does not change.
Error: The change above was shown, not made: cyfr access makes a change only once it is confirmed, and there is no terminal to confirm it on. Nothing was changed. Run it again with --yes to make the change, or on a terminal to confirm it
LOG
expect pass "the complete preview of A to B" preview_holds "$scratch/preview" "$a" "$b"
mutate_preview() {
  sed "$1" "$scratch/preview" >"$scratch/preview-$2"
  expect fail "$3" preview_holds "$scratch/preview-$2" "$a" "$b"
}
mutate_preview 's|https://cyfr.proof.ts.net → https://cyfr-1.proof.ts.net|https://cyfr-1.proof.ts.net → https://cyfr.proof.ts.net|' swapped "the transition shown the wrong way"
mutate_preview 's|  Certificate email: none → none|  Certificate email: none → ops@example.com|' email "another new email shown"
mutate_preview 's|  Ports opened on this machine: none → none|  Ports opened on this machine: none → 80 and 443|' ports "other new ports shown"
mutate_preview '/  Tailnet machine:/d' no-machine "the tailnet machine's change not shown"
mutate_preview 's|(nB)|(nC)|' other-node "another new node id shown"
mutate_preview 's|cyfr.proof.ts.net (nA)|cyfr.proof.ts.net (nB)|' same-node "the old node shown as the new one"
mutate_preview 's|Who can reach this home: your devices|Who can reach this home: anyone|' who "another old audience shown"
mutate_preview '/^  2\. /d' step "an address-change step dropped"
mutate_preview '/^Your CYFR identity/a\  5. An extra step.' extra "a line added to the preview"
# shellcheck disable=SC2016
mutate_preview '$d' refusal "the refusal after it missing"
# shellcheck disable=SC2016
mutate_preview '$c\panic: failed while parsing --yes' panic "a failure naming --yes in place of the refusal"
# shellcheck disable=SC2016
mutate_preview '$s/, or on a terminal to confirm it$//' cut "the refusal cut short"
# shellcheck disable=SC2016
mutate_preview '$s/^Error: //' bare "the refusal not printed as the command's error"
# shellcheck disable=SC2016
mutate_preview '$s/shown, not made/made/' made "a refusal saying the change was made"
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

# ---- anonymous_refused -------------------------------------------------------

# The anonymous subscriptions/listen the proof sends (run.sh mcp_body), and
# the two refusals the home gives an anonymous request: the MCP
# controller's 401 and the protected mount's redirect to /login.
listen_request='{"jsonrpc": "2.0", "id": 1, "method": "subscriptions/listen", "params": {"_meta": {}}}'
rpc_envelope() { printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}' "${1:-1}" "${2:--33001}" "${3:-Unauthorized: subscriptions/listen requires authentication}"; }
# A `standin fetch` answer: status `$1`, headers JSON `$2`, body `$3`.
fetch_answer() { python3 -I -c 'import json, sys; print(json.dumps({"status": int(sys.argv[1]), "headers": json.loads(sys.argv[2]), "body": sys.argv[3]}))' "$@"; }
# A from_network answer: curl's header dump `$1` (lines, CRLF-ended as
# curl writes them), the body `$2` and curl's status `$3`.
curl_answer() { printf 'IP=172.16.234.9\n%s\n\r\n\n%s\nSTATUS=%s\n' "$(printf '%s' "$1" | sed 's/$/\r/')" "$2" "$3"; }
mcp_headers='{"Content-Type":["application/json; charset=utf-8"],"Mcp-Protocol-Version":["2026-03-26"],"Www-Authenticate":["Bearer"],"X-Request-Id":["r1"]}'
mcp_refused="$(fetch_answer 401 "$mcp_headers" "$(rpc_envelope)")"
mcp_refused_curl="$(curl_answer $'HTTP/1.1 401 Unauthorized\ncontent-type: application/json; charset=utf-8\nwww-authenticate: Bearer\nx-request-id: r2' "$(rpc_envelope)" 401)"
page_refused="$(fetch_answer 302 '{"Location":["/login"],"Content-Type":["text/html; charset=utf-8"]}' '<html><body>You are being <a href="/login">redirected</a>.</body></html>')"
page_refused_curl="$(curl_answer $'HTTP/1.1 302 Found\nlocation: /login\ncontent-type: text/html; charset=utf-8' '<html><body>You are being <a href="/login">redirected</a>.</body></html>' 302)"
anon() { anonymous_refused "$1" "$2" "$3" "${4-$listen_request}"; }

expect pass "a forged anonymous MCP request refused as the plain one, 401 with the auth error" anon mcp "$mcp_refused" "$mcp_refused"
expect pass "the same through curl, its header names as the server sends them" anon mcp "$mcp_refused_curl" "$mcp_refused"
expect pass "a forged anonymous page request redirected to /login as the plain one" anon page "$page_refused_curl" "$page_refused_curl"
expect pass "the same through fetch" anon page "$page_refused" "$page_refused_curl"
# Both probes answered alike, but not with the anonymous refusal.
both() { expect fail "$1" anon "$2" "$3" "$3" "${4-$listen_request}"; }
both "both page requests answered 500" page "$(fetch_answer 500 '{}' oops)"
both "both MCP requests answered 500" mcp "$(fetch_answer 500 '{}' oops)"
both "both page requests redirected to /chat" page "$(fetch_answer 302 '{"Location":["/chat?a=somebody"]}' '')"
both "both page requests redirected to /chat, through curl" page "$(curl_answer $'HTTP/1.1 302 Found\nlocation: /chat?a=somebody' '' 302)"
both "both MCP requests answered another RPC error" mcp "$(fetch_answer 401 "$mcp_headers" "$(rpc_envelope 1 -32601 'Method not found')")"
both "both MCP requests answered the wrong RPC error at 200" mcp \
  "$(fetch_answer 200 '{}' '{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Authentication required"}}')"
both "both page requests with duplicate Location values" page "$(fetch_answer 302 '{"Location":["/login","/chat?a=somebody"]}' '')"
both "both page requests with two Location headers, through curl" page \
  "$(curl_answer $'HTTP/1.1 302 Found\nlocation: /login\nlocation: /chat?a=somebody' '' 302)"
both "both MCP requests' auth error at 200" mcp "$(fetch_answer 200 "$mcp_headers" "$(rpc_envelope)")"
both "both MCP requests' auth error for another request id" mcp "$(fetch_answer 401 "$mcp_headers" "$(rpc_envelope 2)")"
both "both MCP requests' auth error with a null id" mcp "$(fetch_answer 401 "$mcp_headers" "$(rpc_envelope null)")"
both "both MCP requests' auth error with another message" mcp "$(fetch_answer 401 "$mcp_headers" "$(rpc_envelope 1 -33001 'Authentication required')")"
both "both MCP requests' auth error with data added" mcp \
  "$(fetch_answer 401 "$mcp_headers" '{"jsonrpc":"2.0","id":1,"error":{"code":-33001,"message":"Unauthorized: subscriptions/listen requires authentication","data":{}}}')"
both "both MCP requests' auth error with a result beside it" mcp \
  "$(fetch_answer 401 "$mcp_headers" '{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-33001,"message":"Unauthorized: subscriptions/listen requires authentication"}}')"
both "both MCP requests' auth error with the id true" mcp "$(fetch_answer 401 "$mcp_headers" "$(rpc_envelope true)")"
both "both MCP requests' auth error with its code a float" mcp "$(fetch_answer 401 "$mcp_headers" "$(rpc_envelope 1 -33001.0)")"
both "both MCP requests answered with a result" mcp "$(fetch_answer 200 '{}' '{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}')"
both "both MCP requests' 401 without its Bearer challenge" mcp \
  "$(fetch_answer 401 '{"Content-Type":["application/json"]}' "$(rpc_envelope)")"
both "a page request answered as the MCP request is" page "$mcp_refused"
both "an MCP request answered as the page request is" mcp "$page_refused"
both "a curl dump whose status line is not curl's status" page "$(curl_answer $'HTTP/1.1 200 OK\nlocation: /login' '' 302)"
both "no answer to either" page $'IP=172.16.234.9\n\n\nSTATUS=refused'
both "an MCP refusal read against a request with no id" mcp "$mcp_refused" '{"jsonrpc": "2.0", "method": "subscriptions/listen"}'
expect fail "a request of a kind the proof does not send" anon tools "$mcp_refused" "$mcp_refused"
expect fail "the forged MCP request answered with a result" anon mcp "$mcp_refused" \
  "$(fetch_answer 200 '{}' '{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}')"
expect fail "the forged page request served" anon page "$page_refused_curl" "$(curl_answer 'HTTP/1.1 200 OK' page 200)"
expect fail "the forged page request sent to a chat" anon page "$page_refused_curl" "$(fetch_answer 302 '{"Location":["/chat?a=%40x"]}' '')"
expect fail "the forged page request got no answer" anon page "$page_refused_curl" $'IP=172.16.234.9\n\n\nSTATUS=refused'

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
