#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The real-tailnet run's predicates (tests/tailnet-real/run.sh, sourced, so
# nothing of the run starts) on canned answers, as `standin fetch` prints
# them and as the pinned image's `tailscale status --json` reads:
#
#   serve_closed         closed only where the machine refused the Serve
#                        port and answered its PeerAPI in the same ask; a
#                        failure at TLS, DNS, the device's proxy, a timeout
#                        or anything else is not, nor a refusal beside a
#                        PeerAPI that did not answer, nor an answer.
#   identity_projection  the whole projection serve.go makes for a user's
#                        device and for a tagged one; keeping each forbidden
#                        header, substituting an identity, adding a value, a
#                        500, another method, path, query or Host, and a
#                        forged forwarding header each fail. Its Q-encoding
#                        is Go's mime.QEncoding, held to values Go wrote.
#
# Usage: bash tests/tailnet-real/predicates-test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/tailnet-real/run.sh
source "$root/tests/tailnet-real/run.sh"

failures=0
cases=0

# `$1` pass or fail, `$2` the case, `$3...` the command.
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

# ---- serve_closed ----------------------------------------------------------

control='{"status":403,"headers":{},"body":"peerapi"}'
refused='{"error":"refused","detail":"the proxy answered CONNECT 100.64.0.7:443 500: connect tcp 100.64.0.7:443: connection was refused"}'
expect pass "a refused Serve port beside an answering PeerAPI is closed" serve_closed "$control" "$refused"
expect fail "a Serve port whose name the proxy's DNS server refused to resolve is not closed" serve_closed "$control" \
  '{"error":"dns","detail":"the proxy answered CONNECT cyfr-verify.example.ts.net:443 500: lookup cyfr-verify.example.ts.net on 127.0.0.11:53: read udp 172.18.0.2:45376->127.0.0.11:53: read: connection refused"}'
for class in tls dns proxy timeout failed; do
  expect fail "a Serve port that failed at $class is not closed" \
    serve_closed "$control" "{\"error\":\"$class\",\"detail\":\"x509: certificate is not trusted\"}"
done
expect fail "a refusal beside a PeerAPI whose ask failed at the proxy is not closed" \
  serve_closed '{"error":"proxy","detail":"the proxy could not be reached"}' "$refused"
expect fail "a refusal beside no PeerAPI answer at all is not closed" serve_closed "" "$refused"
expect fail "an answering Serve port is not closed" serve_closed "$control" '{"status":200,"headers":{},"body":""}'

# ---- identity_projection -----------------------------------------------------

name="cyfr-verify-abc123.example.ts.net"
device_ip="100.64.0.9"
# The machine's status: the device a user's node (user 7) or a tagged one.
status_for() {
  python3 -I -c '
import json, sys
tags = ["tag:device"] if sys.argv[2] == "tagged" else None
peer = {"ID": "nDevice", "TailscaleIPs": [sys.argv[1], "fd7a:115c:a1e0::9"], "UserID": 7}
if tags:
    peer["Tags"] = tags
print(json.dumps({"Peer": {"nodekey:dev": peer, "nodekey:other": {"ID": "nOther", "TailscaleIPs": ["100.64.0.20"], "UserID": 8}},
                  "User": {"7": {"ID": 7, "LoginName": "person@example.com", "DisplayName": sys.argv[3], "ProfilePicURL": "https://pics.example/p.png"},
                           "8": {"ID": 8, "LoginName": "other@example.com", "DisplayName": "Other", "ProfilePicURL": ""}}}))' \
    "$device_ip" "$1" "${2:-Proof Person}"
}
# The device's answer: Serve's 200 with the echo's body, from the headers
# JSON `$1`, and `$2` a Python edit of `seen` and `answer`.
answer_with() {
  python3 -I -c '
import json, os, sys
seen = {"method": "GET", "host": sys.argv[2], "path": "/probe", "query": "q=1", "headers": json.loads(sys.argv[1]), "remote": "127.0.0.1:1"}
answer = {"status": 200, "headers": {"Content-Type": ["application/json"]}}
exec(sys.argv[3])
answer["body"] = json.dumps(seen) + "\n"
print(json.dumps(answer))' "$1" "$name" "${2:-pass}"
}
user_headers='{"X-Forwarded-For":["'"$device_ip"'"],"X-Forwarded-Proto":["https"],"X-Forwarded-Host":["'"$name"'"],
  "Tailscale-User-Login":["person@example.com"],"Tailscale-User-Name":["Proof Person"],
  "Tailscale-User-Profile-Pic":["https://pics.example/p.png"],"Tailscale-Headers-Info":["https://tailscale.com/s/serve-headers"],
  "Accept-Encoding":["gzip"],"User-Agent":["Go-http-client/1.1"]}'
tagged_headers='{"X-Forwarded-For":["'"$device_ip"'"],"X-Forwarded-Proto":["https"],"X-Forwarded-Host":["'"$name"'"],"Accept-Encoding":["gzip"]}'
user_status="$(status_for user)"
tagged_status="$(status_for tagged)"
project() { identity_projection "$1" "$2" "$device_ip" "$name"; }

expect pass "a user's device: exactly its identity, the forwarding headers, GET /probe?q=1 at the name" \
  project "$(answer_with "$user_headers")" "$user_status"
expect pass "a tagged device: no identity header at all" project "$(answer_with "$tagged_headers")" "$tagged_status"
expect fail "a tagged device given identity headers" project "$(answer_with "$user_headers")" "$tagged_status"
expect fail "a user's device given none" project "$(answer_with "$tagged_headers")" "$user_status"

# Each forbidden header kept with the forged value, for each kind of device.
keep="seen['headers'][os.environ['K']] = [os.environ['V']]"
for header in "Tailscale-Funnel-Request:?1" 'Tailscale-App-Capabilities:{"evil.example/cap":[{}]}' \
  "Forwarded:for=198.51.100.1"; do
  export K="${header%%:*}" V="${header#*:}"
  expect fail "a user's device with the forged $K kept" project "$(answer_with "$user_headers" "$keep")" "$user_status"
  expect fail "a tagged device with the forged $K kept" project "$(answer_with "$tagged_headers" "$keep")" "$tagged_status"
done
for header in "Tailscale-User-Login:admin@evil.example" "Tailscale-User-Name:Forged" \
  "Tailscale-User-Profile-Pic:https://evil.example/p.png" "Tailscale-Headers-Info:https://evil.example/info"; do
  key="${header%%:*}" value="${header#*:}"
  expect fail "a user's device with the forged $key in place of its own" \
    project "$(answer_with "$user_headers" "seen['headers']['$key'] = ['$value']")" "$user_status"
  expect fail "a user's device with the forged $key added beside its own" \
    project "$(answer_with "$user_headers" "seen['headers']['$key'].append('$value')")" "$user_status"
  expect fail "a tagged device with the forged $key kept" \
    project "$(answer_with "$tagged_headers" "seen['headers']['$key'] = ['$value']")" "$tagged_status"
done
expect fail "another user's identity substituted" \
  project "$(answer_with "$user_headers" "seen['headers']['Tailscale-User-Login'] = ['other@example.com']")" "$user_status"
expect fail "the forged X-Forwarded-For kept beside the device's" \
  project "$(answer_with "$user_headers" "seen['headers']['X-Forwarded-For'] = ['203.0.113.9', '$device_ip']")" "$user_status"
expect fail "the forged X-Forwarded-Proto kept" \
  project "$(answer_with "$user_headers" "seen['headers']['X-Forwarded-Proto'] = ['http']")" "$user_status"
expect fail "the forged X-Forwarded-Host kept" \
  project "$(answer_with "$user_headers" "seen['headers']['X-Forwarded-Host'] = ['evil.example']")" "$user_status"
expect fail "Serve answering 500" project "$(answer_with "$user_headers" "answer['status'] = 500")" "$user_status"
expect fail "another method reaching the upstream" project "$(answer_with "$user_headers" "seen['method'] = 'POST'")" "$user_status"
expect fail "another path reaching the upstream" project "$(answer_with "$user_headers" "seen['path'] = '/'")" "$user_status"
expect fail "another query reaching the upstream" project "$(answer_with "$user_headers" "seen['query'] = 'q=2'")" "$user_status"
expect fail "another Host reaching the upstream" project "$(answer_with "$user_headers" "seen['host'] = 'evil.example'")" "$user_status"
expect fail "a probe that failed" project '{"error":"tls","detail":"x509: certificate is not trusted"}' "$user_status"
expect fail "a device the machine's status does not name" project "$(answer_with "$user_headers")" '{"Peer":{},"User":{}}'

# A display name serve.go must Q-encode, and Go's own encodings of three
# names (mime.QEncoding.Encode("utf-8", v), recorded from Go 1.27).
encoded='=?utf-8?q?Pr=C5=8Dof_P=C3=A9rson_=E2=98=83?='
expect pass "a non-ASCII display name is held Q-encoded, as serve.go encodes it" \
  project "$(answer_with "$user_headers" "seen['headers']['Tailscale-User-Name'] = ['$encoded']")" "$(status_for user 'Prōof Pérson ☃')"
expect fail "a non-ASCII display name sent unencoded" \
  project "$(answer_with "$user_headers" "seen['headers']['Tailscale-User-Name'] = ['Prōof Pérson ☃']")" "$(status_for user 'Prōof Pérson ☃')"
long='Ünïcödé Ünïcödé Ünïcödé Ünïcödé Ünïcödé Ünïcödé Ünïcödé'
long_encoded='=?utf-8?q?=C3=9Cn=C3=AFc=C3=B6d=C3=A9_=C3=9Cn=C3=AFc=C3=B6d=C3=A9_=C3=9Cn?= =?utf-8?q?=C3=AFc=C3=B6d=C3=A9_=C3=9Cn=C3=AFc=C3=B6d=C3=A9_=C3=9Cn=C3=AFc?= =?utf-8?q?=C3=B6d=C3=A9_=C3=9Cn=C3=AFc=C3=B6d=C3=A9_=C3=9Cn=C3=AFc=C3=B6d?= =?utf-8?q?=C3=A9?='
expect pass "a long display name is split into encoded words as Go splits it" \
  project "$(answer_with "$user_headers" "seen['headers']['Tailscale-User-Name'] = ['$long_encoded']")" "$(status_for user "$long")"
expect pass "an ASCII name with = ? _ is sent as it is" \
  project "$(answer_with "$user_headers" "seen['headers']['Tailscale-User-Name'] = ['a_b=c?d']")" "$(status_for user 'a_b=c?d')"

echo "$cases cases, $failures failed"
[ "$failures" -eq 0 ]
