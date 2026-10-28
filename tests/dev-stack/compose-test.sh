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
# restrictions among them, as it is. scripts/dev-stack.sh, with docker, mix
# and curl stubbed, hands compose the key derived for the override's id
# and the mix boot's settings as `mix cyfr.locus.dev_stack` reads them,
# refuses what disagrees, secures the root it writes and the check's
# bearer, and cleans up after a failed check. The scaffold ships neither
# file. Each mutation of the override or the script fails; an equivalent
# respelling holds.
#
# Needs docker's compose plugin (no daemon) and a build of the checkout
# (_build/$MIX_ENV, or DEV_STACK_BUILD). SHOW=1 prints why each mutation
# fails. Usage: bash tests/dev-stack/compose-test.sh
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

# scripts/dev-stack.sh at its command boundary: docker, mix and curl
# stubbed on PATH, each recording what it is handed. The stubbed mix runs
# the real cyfr.locus task it is asked for from this checkout's build, so every
# .env below is read by the reader a mix boot uses. What the script must
# hand on comes from the resolved override: its service id, its published
# address and its gateway, and the key the documented derivation gives
# (.env.example: the root's HMAC of `cyfr-locus/v1/runtime\n<id>`).
read -r want_id want_url want_bind < <(python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
s = d["services"]["locus-runtime"]
p = s["ports"][0]
print(s["environment"]["LOCUS_RUNTIME_SERVICE_ID"], "http://%s:%s" % (p["host_ip"], p["published"]),
      d["networks"]["locus-runtime"]["ipam"]["config"][0]["gateway"])' "$scratch/real/dev.json")
derived() { printf 'cyfr-locus/v1/runtime\n%s' "$want_id" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" | sed 's/^.*= //'; }

build="${DEV_STACK_BUILD:-$ROOT/${MIX_BUILD_PATH:-_build/${MIX_ENV:-dev}}}"
ebins=""
for dir in "$build"/lib/*/ebin; do ebins="$ebins -pa $dir"; done
[ -f "$build/lib/cyfr/ebin/Elixir.Mix.Tasks.Cyfr.Locus.DevStack.beam" ] ||
  failed "no build of mix cyfr.locus.dev_stack under $build: compile the checkout first"

stubs="$scratch/bin"
mkdir -p "$stubs"
cat >"$stubs/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s|LOCUS_RUNTIME_KEY=%s|CYFR_HOST_API_PORT=%s\n' "$*" "${LOCUS_RUNTIME_KEY-unset}" "${CYFR_HOST_API_PORT-unset}" >>"$STUB_LOG/docker.calls"
exit "${STUB_DOCKER_STATUS:-0}"
STUB
cat >"$stubs/mix" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/mix.calls"
case "${1:-}" in
  cyfr.locus.dev_stack) task=Mix.Tasks.Cyfr.Locus.DevStack ;;
  cyfr.locus.runtime_key) task=Mix.Tasks.Cyfr.Locus.RuntimeKey ;;
  *) echo "the stub runs the cyfr.locus tasks alone, not ${1:-nothing}" >&2; exit 99 ;;
esac
shift
# shellcheck disable=SC2086
exec elixir $STUB_EBINS -e '
Mix.start()
try do
  '"$task"'.run(System.argv())
rescue
  e in Mix.Error ->
    IO.puts(:stderr, "** (Mix) " <> Exception.message(e))
    System.halt(if is_integer(e.mix), do: e.mix, else: 1)
end' -- "$@"
STUB
cat >"$stubs/curl" <<'STUB'
#!/usr/bin/env python3
# The server's /mcp for the check: records the arguments, the header
# file's modes and content, and each action; answers each run completed,
# or refused where STUB_FAIL names its action. STUB_READ_RESULT stands for
# the read's result.
import json, os, sys
log = os.environ["STUB_LOG"]
args = sys.argv[1:]
with open(os.path.join(log, "curl.calls"), "a") as f:
    f.write(" ".join(args) + "\n")
header = "no header file"
for i, a in enumerate(args):
    if a == "-H" and args[i + 1].startswith("@"):
        path = args[i + 1][1:]
        modes = (oct(os.stat(path).st_mode & 0o777), oct(os.stat(os.path.dirname(path)).st_mode & 0o777))
        right = open(path).read() == "authorization: Bearer %s\n" % os.environ["STUB_TOKEN"]
        header = "file=%s dir=%s bearer=%s" % (modes[0], modes[1], "ok" if right else "wrong")
with open(os.path.join(log, "curl.headers"), "a") as f:
    f.write(header + "\n")
url = next(a for a in args if a.startswith("http"))
body = json.loads(args[args.index("-d") + 1])
given = body["params"]["arguments"]["input"]
action = given["action"]
with open(os.path.join(log, "curl.actions"), "a") as f:
    f.write("%s %s %s\n" % (action, url, given.get("path")))
store = os.path.join(log, "store.json")
files = json.load(open(store)) if os.path.exists(store) else {}
if action in os.environ.get("STUB_FAIL", "").split(","):
    print(json.dumps({"jsonrpc": "2.0", "id": 1, "error": {"code": -32603, "message": "stub %s failure" % action}}))
    sys.exit(0)
if action == "write_text":
    files[given["path"]] = given["content"]
    result = {"path": given["path"]}
elif action == "read_text":
    result = {"path": given["path"], "content": files.get(given["path"])}
    if "STUB_READ_RESULT" in os.environ:
        result = json.loads(os.environ["STUB_READ_RESULT"])
else:
    files.pop(given["path"], None)
    result = {"deleted": given["path"]}
json.dump(files, open(store, "w"))
run = {"status": "completed", "execution_id": "exec_stub", "result": result}
print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": json.dumps(run)}]}}))
STUB
chmod +x "$stubs/docker" "$stubs/mix" "$stubs/curl"

token="dev-stack-test-token-$(openssl rand -hex 6)"
root_a="$(printf 'ab%.0s' {1..32})"

# stack SCRIPT NAME ENV_TEXT MODE COMMAND [VAR=VALUE...]: SCRIPT run as
# COMMAND in a project of its own, its .env ENV_TEXT at MODE (none for no
# file), with only PATH, HOME and the given variables in its environment.
# Leaves $case_dir with the stubs' records, out (stdout), err (stderr),
# env.before and status.
stack() {
  local script="$1" name="$2" text="$3" mode="$4" command="$5"
  shift 5
  case_dir="$scratch/case-$name"
  rm -rf "$case_dir" && mkdir -p "$case_dir/scripts" "$case_dir/tmp" "$case_dir/log"
  cp "$script" "$case_dir/scripts/dev-stack.sh"
  cp "$ROOT/docker-compose.yml" "$ROOT/docker-compose.dev.yml" "$case_dir/"
  if [ "$mode" != none ]; then
    printf '%s' "$text" >"$case_dir/.env"
    chmod "$mode" "$case_dir/.env"
    cp -p "$case_dir/.env" "$case_dir/env.before"
  fi
  (cd "$case_dir" && env -i PATH="$stubs:$PATH" HOME="$HOME" LC_ALL=C.UTF-8 TMPDIR="$case_dir/tmp" \
    STUB_LOG="$case_dir/log" STUB_EBINS="$ebins" STUB_TOKEN="$token" "$@" \
    bash scripts/dev-stack.sh "$command" >"$case_dir/out" 2>"$case_dir/err")
  echo "$?" >"$case_dir/status"
}
record() { cat "$case_dir/log/$1" 2>/dev/null; }
mode_of() { python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }
compose_call() { echo "compose -f docker-compose.yml -f docker-compose.dev.yml up --detach --build --wait locus-runtime|LOCUS_RUNTIME_KEY=$1|CYFR_HOST_API_PORT=$2"; }
key_call="cyfr.locus.dev_stack key $want_id $want_url $want_bind"

# Each case prints why it fails, nothing when it holds.
case_provision() {
  local admin=$'CYFR_PLATFORM_ADMIN_EMAILS=dev@example.test\n' added new
  stack "$1" provision "$admin" 0644 up
  [ "$(cat "$case_dir/status")" = 0 ] || { echo "up exited $(cat "$case_dir/status"): $(cat "$case_dir/err")"; return; }
  [ "$(mode_of "$case_dir/.env")" = 0o600 ] || echo ".env is $(mode_of "$case_dir/.env") after the root was written"
  grep -qxF "dev-stack: .env is mode 0600 and holds a new CYFR_LOCUS_RUNTIME_ROOT." "$case_dir/out" || echo "up did not say .env is mode 0600: $(cat "$case_dir/out")"
  added="$(tail -c +$((${#admin} + 1)) "$case_dir/.env")"
  [ "$(head -c ${#admin} "$case_dir/.env")" = "${admin%$'\n'}" ] || echo ".env's own lines changed: $(cat "$case_dir/.env")"
  [[ "$added" =~ ^CYFR_LOCUS_RUNTIME_ROOT=[0-9a-f]{64}$ ]] || echo ".env gained $(printf '%q' "$added"), not one root line"
  new="${added#CYFR_LOCUS_RUNTIME_ROOT=}"
  [ "$(record mix.calls)" = "$key_call"$'\n'"$key_call" ] || echo "mix was handed: $(record mix.calls)"
  [ "$(record docker.calls)" = "$(compose_call "$(derived "$new")" 4300)" ] || echo "compose was handed: $(record docker.calls)"
  if grep -qF "$new" "$case_dir/out" "$case_dir/err"; then echo "the root reached the output"; fi
}
case_retained() {
  local text
  for text in "CYFR_LOCUS_RUNTIME_ROOT = $root_a"$'\n' "CYFR_LOCUS_RUNTIME_ROOT=$root_a # the stack's root"$'\n' \
    "CYFR_LOCUS_RUNTIME_ROOT=$root_a"$'\nCYFR_HOST_API_PORT = 4311\n'; do
    stack "$1" retained "$text" 0644 up
    [ "$(cat "$case_dir/status")" = 0 ] || { echo "up exited $(cat "$case_dir/status") on $(printf '%q' "$text"): $(cat "$case_dir/err")"; continue; }
    cmp -s "$case_dir/.env" "$case_dir/env.before" || echo ".env changed from $(printf '%q' "$text") to $(printf '%q' "$(cat "$case_dir/.env")")"
    local port=4300
    case "$text" in *4311*) port=4311 ;; esac
    [ "$(record docker.calls)" = "$(compose_call "$(derived "$root_a")" "$port")" ] || echo "on $(printf '%q' "$text") compose was handed: $(record docker.calls)"
    if grep -qF "$(derived "$root_a")" "$case_dir/out" "$case_dir/err"; then echo "the key reached the output"; fi
  done
}
case_refused() {
  local text name
  for text in "CYFR_LOCUS_RUNTIME_ROOT=$root_a"$'\nCYFR_LOCUS_RUNTIME_WORKERS = wrk_elsewhere=http://127.0.0.1:4999\n' \
    "CYFR_LOCUS_RUNTIME_ROOT=$root_a"$'\nCYFR_HOST_API_BIND=0.0.0.0 # all of them\n' \
    "CYFR_LOCUS_RUNTIME_ROOT=$root_a"$'\nCYFR_HOST_API_URL=http://cyfr:4300\n'; do
    name="$(printf '%s' "$text" | sed -n '2s/[ =].*//p')"
    stack "$1" refused "$text" 0644 up
    [ "$(cat "$case_dir/status")" != 0 ] || echo "up accepted $name from $(printf '%q' "$text")"
    grep -qF "dev-stack: $name is " "$case_dir/err" || echo "the refusal does not name $name: $(cat "$case_dir/err")"
    [ -z "$(record docker.calls)" ] || echo "compose ran though $name disagreed: $(record docker.calls)"
    cmp -s "$case_dir/.env" "$case_dir/env.before" || echo ".env changed on a refusal of $name"
  done
  stack "$1" empty-override "CYFR_LOCUS_RUNTIME_ROOT=$root_a"$'\n' 0644 up CYFR_LOCUS_RUNTIME_ROOT=
  [ "$(cat "$case_dir/status")" != 0 ] || echo "up accepted a root the environment sets empty over .env's"
  grep -qF "CYFR_LOCUS_RUNTIME_ROOT is set empty in the environment" "$case_dir/err" || echo "the empty override's refusal: $(cat "$case_dir/err")"
  [ -z "$(record docker.calls)" ] || echo "compose ran under an empty root override"
  cmp -s "$case_dir/.env" "$case_dir/env.before" || echo ".env changed under an empty root override"
}
case_docker_fails() {
  stack "$1" docker-fails "CYFR_LOCUS_RUNTIME_ROOT=$root_a"$'\n' 0600 up STUB_DOCKER_STATUS=1
  [ "$(cat "$case_dir/status")" != 0 ] || echo "up exited 0 though compose failed"
  if grep -qF "The runtime runs from this tree" "$case_dir/out"; then echo "up printed its success after compose failed"; fi
}
case_check() {
  stack "$1" check $'CYFR_PORT = 4555\n' 0644 check CYFR_TOKEN="$token"
  [ "$(cat "$case_dir/status")" = 0 ] || { echo "check exited $(cat "$case_dir/status"): $(cat "$case_dir/err")"; return; }
  [ "$(record curl.actions | awk '{print $1, $2}' | sort -u)" = "delete http://127.0.0.1:4555/mcp
read_text http://127.0.0.1:4555/mcp
write_text http://127.0.0.1:4555/mcp" ] || echo "the check ran: $(record curl.actions)"
  [ "$(record curl.headers | sort -u)" = "file=0o600 dir=0o700 bearer=ok" ] || echo "the bearer's header file: $(record curl.headers)"
  if grep -qF "$token" "$case_dir/log/curl.calls" "$case_dir/out" "$case_dir/err"; then echo "the token reached curl's arguments or the output"; fi
  [ -z "$(ls -A "$case_dir/tmp")" ] || echo "the check left $(ls -A "$case_dir/tmp") behind"
  [ "$(cat "$case_dir/log/store.json")" = "{}" ] || echo "the check left a file in the athanor: $(cat "$case_dir/log/store.json")"
}
case_failed_read() {
  stack "$1" failed-read "" none check CYFR_TOKEN="$token" STUB_FAIL=read_text
  [ "$(cat "$case_dir/status")" != 0 ] || echo "check exited 0 though its read failed"
  [ "$(record curl.actions | awk '{print $1}')" = $'write_text\nread_text\ndelete' ] || echo "after the failed read the check ran: $(record curl.actions)"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: read_text: refused: stub read_text failure" ] || echo "the check did not end with the read's failure: $(cat "$case_dir/err")"
  [ "$(cat "$case_dir/log/store.json")" = "{}" ] || echo "the failed read left its file: $(cat "$case_dir/log/store.json")"
  [ -z "$(ls -A "$case_dir/tmp")" ] || echo "the failed check left $(ls -A "$case_dir/tmp") behind"

  stack "$1" failed-delete "" none check CYFR_TOKEN="$token" STUB_FAIL=read_text,delete
  [ "$(record curl.actions | awk '{print $1}')" = $'write_text\nread_text\ndelete' ] || echo "with the delete failing too the check ran: $(record curl.actions)"
  local left
  left="$(record curl.actions | awk 'NR == 1 {print $3}')"
  grep -qF "dev-stack: $left is left in the athanor's storage" "$case_dir/err" || echo "the check did not name the file it left: $(cat "$case_dir/err")"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: read_text: refused: stub read_text failure" ] || echo "the check did not end with the read's failure: $(cat "$case_dir/err")"
}
case_release_root() {
  local sentence="dev-stack: RELEASE_ROOT is set, and it names a release: the dev stack runs CYFR from the checkout, which reads the .env at its root. Unset RELEASE_ROOT and run again."
  local command
  mkdir -p "$scratch/release"
  printf 'CYFR_LOCUS_RUNTIME_ROOT=%s\nCYFR_PORT=4557\n' "$(printf 'cd%.0s' {1..32})" >"$scratch/release/.env"
  for command in up check; do
    stack "$1" release-root $'CYFR_PLATFORM_ADMIN_EMAILS=dev@example.test\n' 0644 "$command" \
      RELEASE_ROOT="$scratch/release" CYFR_TOKEN="$token"
    [ "$(cat "$case_dir/status")" != 0 ] || echo "$command exited 0 under RELEASE_ROOT"
    [ "$(tail -n 1 "$case_dir/err")" = "$sentence" ] || echo "$command did not end on the RELEASE_ROOT refusal: $(cat "$case_dir/err")"
    cmp -s "$case_dir/.env" "$case_dir/env.before" || echo "$command changed .env under RELEASE_ROOT: $(cat "$case_dir/.env")"
    [ -z "$(record docker.calls)" ] || echo "$command ran compose under RELEASE_ROOT: $(record docker.calls)"
    [ -z "$(record curl.actions)" ] || echo "$command ran the files catalyst under RELEASE_ROOT: $(record curl.actions)"
  done
}
case_failed_parse() {
  stack "$1" failed-parse "" none check CYFR_TOKEN="$token" STUB_READ_RESULT='[]'
  [ "$(cat "$case_dir/status")" != 0 ] || echo "check exited 0 though its read answered no content"
  [ "$(record curl.actions | awk '{print $1}')" = $'write_text\nread_text\ndelete' ] || echo "after a read with no content the check ran: $(record curl.actions)"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: read_text: the run answered no content: []" ] || echo "the check did not end with the read's failure: $(cat "$case_dir/err")"
  [ "$(cat "$case_dir/log/store.json")" = "{}" ] || echo "a read with no content left its file: $(cat "$case_dir/log/store.json")"
  [ -z "$(ls -A "$case_dir/tmp")" ] || echo "the failed check left $(ls -A "$case_dir/tmp") behind"
}
BOUNDARY_CASES="case_provision case_retained case_refused case_release_root case_docker_fails case_check case_failed_read case_failed_parse"

# boundary SCRIPT [CASE...]: the failures of SCRIPT under each case.
boundary() {
  local script="$1" c
  shift
  for c in "${@:-$BOUNDARY_CASES}"; do
    # shellcheck disable=SC2086
    for c1 in $c; do "$c1" "$script" | sed "s/^/$c1: /"; done
  done
}

script="$ROOT/scripts/dev-stack.sh"
for c in $BOUNDARY_CASES; do
  out="$(boundary "$script" "$c")"
  if [ -z "$out" ]; then pass "scripts/dev-stack.sh: ${c#case_}"; else failed "scripts/dev-stack.sh: ${c#case_}" "$out"; fi
done

# respell NAME WHAT SED_EXPRESSION: an equivalent spelling, which holds.
respell() {
  sed -E "$3" "$script" >"$scratch/r-$1.sh"
  if cmp -s "$script" "$scratch/r-$1.sh"; then failed "$2 (the edit changed nothing)"; return; fi
  out="$(boundary "$scratch/r-$1.sh")"
  if [ -z "$out" ]; then pass "$2 holds"; else failed "$2 fails" "$out"; fi
}
respell quoted "the dev stack's declarations quoted" 's/^(SERVICE_ID|WORKER_URL|HOST_API_BIND)=(.*)$/\1="\2"/'
# break NAME WHAT CASE SED_EXPRESSION: the script broken, which CASE catches.
break_script() {
  sed -E "$4" "$script" >"$scratch/b-$1.sh"
  if cmp -s "$script" "$scratch/b-$1.sh"; then failed "$2 (the edit changed nothing)"; return; fi
  out="$(boundary "$scratch/b-$1.sh" "$3")"
  if [ -n "$out" ]; then
    pass "$2 fails"
    [ -z "${SHOW:-}" ] || printf '%s\n' "$out" | sed 's/^/    /'
  else
    failed "$2 passed"
  fi
}
break_script wrongid "the key derived for another service id" "case_provision case_retained" 's/key "\$SERVICE_ID"/key wrk_wrong/g'
break_script chmod "the root written with .env's mode left as it was" case_provision '/chmod 600 \.env/d'
break_script argv "the bearer on curl's command line" case_check 's|-H @"\$PRIVATE/authorization"|-H "authorization: Bearer $CYFR_TOKEN"|'
break_script discard "no delete after a failed read" "case_failed_read case_failed_parse" '/^    discard "\$path"$/d'
break_script keep "the private directory kept" case_check "s/^trap .*EXIT$/trap ':' EXIT/"

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
