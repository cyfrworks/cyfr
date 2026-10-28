#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The source development stack's compose override, docker-compose.dev.yml,
# as `docker compose config` resolves it over docker-compose.yml
# (tests/dev-stack/compose_shape.py): the image built from the tree under a
# local tag, the runtime's listener on the host's loopback alone, its host
# calls to the locus-runtime network's gateway, the id CYFR dispatches to by
# default, and every other setting of the shipped service, the keeper's
# restrictions among them, as it is. scripts/dev-stack.sh names the same
# id and address, and the scaffold ships neither file. Each mutation of the
# override fails the shape.
#
# Needs docker's compose plugin and no daemon. SHOW=1 prints why each
# mutation fails. Usage: bash tests/dev-stack/compose-test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-dev-stack-compose.XXXXXX")" || exit 1
trap 'rm -rf "$scratch"' EXIT

failures=0
cases=0
pass() { cases=$((cases + 1)); echo "PASS: $1"; }
failed() {
  cases=$((cases + 1)) failures=$((failures + 1))
  echo "FAIL: $1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/  /'
}

# project DIR OVERRIDE [ENV_LINE]: a project directory holding the shipped
# compose file, OVERRIDE as docker-compose.dev.yml and a .env of ENV_LINE.
project() {
  rm -rf "$1" && mkdir -p "$1"
  cp "$ROOT/docker-compose.yml" "$1/"
  cp "$2" "$1/docker-compose.dev.yml"
  printf '%s\n' "${3:-}" >"$1/.env"
}

# resolve DIR FILE... : the locus-runtime service of those files, in an
# environment holding nothing of the caller's.
resolve() {
  local dir="$1" files=()
  shift
  for f in "$@"; do files+=(-f "$f"); done
  (cd "$dir" && env -i PATH="$PATH" HOME="$HOME" LOCUS_RUNTIME_KEY="$(printf 'ab%.0s' {1..32})" \
    docker compose "${files[@]}" config --format json locus-runtime)
}

# shape DIR PORT: the dev stack's shape against the shipped service.
shape() {
  resolve "$1" docker-compose.yml >"$1/base.json" 2>"$1/err" || { cat "$1/err"; return 1; }
  resolve "$1" docker-compose.yml docker-compose.dev.yml >"$1/dev.json" 2>"$1/err" || { cat "$1/err"; return 1; }
  python3 -I "$ROOT/tests/dev-stack/compose_shape.py" "$1/base.json" "$1/dev.json" "$2" "$ROOT"
}

expect_shape() {
  local want="$1" what="$2" out code
  shift 2
  out="$(shape "$@" 2>&1)"
  code=$?
  if { [ "$want" = pass ] && [ "$code" -eq 0 ]; } || { [ "$want" = fail ] && [ "$code" -ne 0 ] && [ -n "$out" ]; }; then
    pass "$what"; [ -z "${SHOW:-}" ] || printf "%s\n" "$out" | sed "s/^/    /"
  else
    failed "$what (exit $code)" "$out"
  fi
}

override="$ROOT/docker-compose.dev.yml"

project "$scratch/real" "$override"
expect_shape pass "the override over the shipped file is the dev stack's shape" "$scratch/real" 4300
project "$scratch/port" "$override" "CYFR_HOST_API_PORT=4311"
expect_shape pass "the host API's port in .env reaches the runtime's callback address" "$scratch/port" 4311

# mutate NAME WHAT SED_EXPRESSION: the override edited, which must fail.
mutate() {
  local dir="$scratch/m-$1"
  sed -E "$3" "$override" >"$scratch/m-$1.yml"
  if cmp -s "$override" "$scratch/m-$1.yml"; then
    failed "$2 (the edit changed nothing)"
    return
  fi
  project "$dir" "$scratch/m-$1.yml"
  expect_shape fail "$2" "$dir" 4300
}
mutate wildcard "the runtime published on every interface" 's/"127\.0\.0\.1:4200:4200"/"0.0.0.0:4200:4200"/'
mutate nohost "the runtime published with no host address" 's/"127\.0\.0\.1:4200:4200"/"4200:4200"/'
mutate otherport "the runtime published on another host port" 's/"127\.0\.0\.1:4200:4200"/"127.0.0.1:4201:4200"/'
mutate published "the published image tag" 's|image: cyfr-locus:dev|image: ghcr.io/cyfrworks/cyfr-locus:latest|'
mutate pulled "an image compose may pull" '/pull_policy: build/d'
mutate callback "the runtime's callbacks to the shipped cyfr service" 's|http://172\.16\.231\.1:|http://cyfr:|'
mutate loopback "the runtime's callbacks to its own loopback" 's|http://172\.16\.231\.1:|http://127.0.0.1:|'
mutate gateway "another gateway than the callbacks name" 's/gateway: 172\.16\.231\.1/gateway: 172.16.231.254/'
mutate serviceid "the shipped service id, which CYFR does not dispatch to" 's/LOCUS_RUNTIME_SERVICE_ID=wrk_local/LOCUS_RUNTIME_SERVICE_ID=wrk_locus/'
mutate joined "the security options joined to the shipped ones" 's/security_opt: !override/security_opt:/'
mutate seccomp "the keeper's profile dropped" '/seccomp=\.\/apps/d'
mutate noprofile "a profile the checkout does not hold" 's|seccomp=\./apps/locus/keeper/seccomp/keeper\.json|seccomp=./keeper.seccomp.json|'
mutate nnp "no-new-privileges dropped" '/- no-new-privileges:true/d'
mutate capability "a capability added" 's/^(    pull_policy: build)$/\1\n    cap_add: [NET_ADMIN]/'
mutate writable "a writable root" 's/^(    pull_policy: build)$/\1\n    read_only: false/'
mutate hostnet "the host's network" 's/^(    pull_policy: build)$/\1\n    network_mode: host/'
mutate unnamed "the checkout directory's project name" '/^name: cyfr-dev$/d'
mutate container "the shipped container name" 's/container_name: cyfr-dev-locus-runtime/container_name: cyfr-locus-runtime/'
mutate subnet "another subnet" 's|subnet: 172\.16\.231\.0/24|subnet: 172.16.232.0/24|'

# scripts/dev-stack.sh tells the mix boot what the override declares: the
# id CYFR dispatches to at the runtime's published address, and the bind
# its callbacks reach.
script="$ROOT/scripts/dev-stack.sh"
dev_env="$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1]))["services"]["locus-runtime"]; p=s["ports"][0]; print(s["environment"]["LOCUS_RUNTIME_SERVICE_ID"], p["host_ip"]+":"+p["published"], s["environment"]["LOCUS_RUNTIME_HOST_API_URL"].split("//")[1].split(":")[0])' "$scratch/real/dev.json")"
read -r want_id want_at want_bind <<<"$dev_env"
script_line() { sed -n "s/^$1=//p" "$script"; }
if [ "$(script_line SERVICE_ID)" = "$want_id" ] &&
  [ "$(script_line WORKERS)" = "\$SERVICE_ID=http://$want_at" ] &&
  [ "$(script_line HOST_API_BIND)" = "$want_bind" ]; then
  pass "scripts/dev-stack.sh names the override's id ($want_id), address ($want_at) and gateway ($want_bind)"
else
  failed "scripts/dev-stack.sh disagrees with the override" "$(grep -E '^(SERVICE_ID|WORKERS|HOST_API_BIND)=' "$script")"
fi

# ships_neither TARBALL: the scaffold holds the shipped compose file and
# neither the override nor the script that starts it.
ships_neither() {
  local listing
  listing="$(tar -tzf "$1")" || return 1
  grep -qxF docker-compose.yml <<<"$listing" || { echo "no docker-compose.yml in the scaffold"; return 1; }
  if grep -E '(^|/)(docker-compose\.dev\.yml|dev-stack\.sh)$' <<<"$listing"; then return 1; fi
  return 0
}
if out="$(bash "$ROOT/scripts/scaffold-tarball.sh" "$scratch/scaffold.tar.gz" 2>&1)" && out="$(ships_neither "$scratch/scaffold.tar.gz" 2>&1)"; then
  pass "the scaffold ships docker-compose.yml and neither docker-compose.dev.yml nor scripts/dev-stack.sh"
else
  failed "the scaffold" "$out"
fi
mkdir -p "$scratch/planted/scripts"
(cd "$scratch/planted" && touch docker-compose.yml docker-compose.dev.yml scripts/dev-stack.sh &&
  tar czf ../planted-override.tar.gz docker-compose.yml docker-compose.dev.yml &&
  tar czf ../planted-script.tar.gz docker-compose.yml scripts/dev-stack.sh)
for planted in override script; do
  if ships_neither "$scratch/planted-$planted.tar.gz" >/dev/null 2>&1; then
    failed "a scaffold shipping the $planted passed"
  else
    pass "a scaffold shipping the $planted fails"
  fi
done

echo "$((cases - failures))/$cases passed"
[ "$failures" -eq 0 ]
