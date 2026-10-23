#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The release proofs' shared plumbing, against stand-ins: no release is
# built and no browser runs. The reuse of a built release
# (tests/release-boot/release.sh `release_build`, RELEASE_BOOT_SKIP_BUILD=1)
# against a git tree of the test's own; the readiness window of
# `server_start` against a listener that accepts and never answers, and
# the redaction of the boot log it prints; a cell's deployment file from
# the command line (`cell_new`, `cell_hostname`, `cell_cli`), with a
# stand-in `cyfr` that records how it was run, and the dotenv reading of
# it (`cell_assignments`); the identity front's readiness
# (tests/identity-proof/front.sh) against a stranger answering on its
# address, with `docker` a stand-in; and the proofs' redaction
# (tests/browser/lib.mjs `redact`) against a case of every pattern it
# hides, run by node; and the browser harness's socket lifetimes against
# peer resets (tests/browser/lib-test.mjs), without launching a browser.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d /tmp/cyfr-release-boot-test.XXXXXX)
servers=()
cleanup() {
  local pid
  for pid in ${servers[@]+"${servers[@]}"}; do kill "$pid" 2>/dev/null || :; done
  [ ! -f "$scratch/own.pid" ] || kill "$(cat "$scratch/own.pid")" 2>/dev/null || :
  [ ! -f "$scratch/cell/stub.pid" ] || kill "$(cat "$scratch/cell/stub.pid")" 2>/dev/null || :
  rm -rf "$scratch"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
status_of() { local s=0; "$@" >"$scratch/out" 2>&1 || s=$?; echo "$s"; }
has() { grep -qF -- "$1" "$scratch/out" || { cat "$scratch/out" >&2; fail "$2"; }; }
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
# A bounded wait on an observable condition: `until_true 10 cmd...`.
until_true() {
  local limit=$(($1 * 10)) n=0
  shift
  until "$@" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -lt "$limit" ] || return 1
    sleep 0.1
  done
}
accepts() { python3 -c 'import socket, sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 1).close()' "$1" "$2"; }

# Run each proof's actual version read on every accepted release version,
# so its live-slot comparison and snapshot manifest keep pre-release suffixes.
python3 -I - "$root" "$scratch" <<'PY'
import json, pathlib, subprocess, sys
root, scratch = map(pathlib.Path, sys.argv[1:])
versions = json.loads((root / "tests/fixtures/release_manifest.json").read_text())["versions"]["accepted"]
tree = scratch / "versions"
mix = tree / "apps/prima/mix.exs"
mix.parent.mkdir(parents=True)
for proof in ("tests/release-boot/boot.sh", "tests/compose-proof/run.sh"):
    reads = [line.strip() for line in (root / proof).read_text().splitlines()
             if line.lstrip().startswith(("VERSION=", "version=")) and '"$ROOT/apps/prima/mix.exs"' in line]
    if len(reads) != 1:
        sys.exit(f"FAIL: {proof} has {len(reads)} version reads, expected one")
    statement = reads[0]
    variable = statement.split("=", 1)[0]
    for version in versions:
        mix.write_text(f'    version: "{version}",\n')
        result = subprocess.run(["bash", "-eu", "-c", 'ROOT=$1\n' + statement +
                                 f'\nprintf \'%s\' "${variable}"', "_", str(tree)],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 0 or result.stdout != version:
            sys.exit(f"FAIL: {proof} read {result.stdout!r} from version {version!r}: {result.stderr}")
print(f"ok: both proofs read all {len(versions)} accepted release versions intact")
PY

# The stand-in listeners: `hang ADDR PORT` accepts every connection and
# never answers; `json ADDR PORT BODY` answers every GET 200 with BODY.
cat >"$scratch/serve.py" <<'PY'
import http.server, socket, sys, time
mode, addr, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
if mode == "hang":
    listener = socket.create_server((addr, port))
    held = []
    while True:
        held.append(listener.accept()[0])
else:
    body = sys.argv[4].encode()
    class Answer(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args):
            pass
    http.server.ThreadingHTTPServer((addr, port), Answer).serve_forever()
PY

# The driver: the real release.sh, harness.sh and front.sh, sourced as a
# proof sources them, with the tree, the build and the cell the test's.
cat >"$scratch/drive.sh" <<'SH'
set -euo pipefail
ADAPTER=sqlite
WORK="$DRIVE_SCRATCH/work"
mkdir -p "$WORK"
source "$DRIVE_CHECKOUT/tests/release-boot/release.sh"
source "$DRIVE_CHECKOUT/tests/browser/harness.sh"
source "$DRIVE_CHECKOUT/tests/identity-proof/front.sh"
ROOT="$DRIVE_SCRATCH/tree"
BUILD_PATH="$DRIVE_SCRATCH/build"
REL="$BUILD_PATH/rel/cyfr"
case "$1" in
  record) release_source >"$BUILD_PATH/release-source" ;;
  reuse) RELEASE_BOOT_SKIP_BUILD=1 release_build ;;
  build) PATH="$DRIVE_SCRATCH/bin:$PATH" release_build ;;
  start)
    READY_TIMEOUT="$2"
    server_start "$DRIVE_SCRATCH/cell"
    ;;
  front)
    BROWSER_AUTHORITY="$DRIVE_SCRATCH/authority"
    identity_directory dir.test "$2" "$3"
    identity_front_start "$DRIVE_SCRATCH/dir"
    ;;
  cell)
    # A cell function, `$2...`, on a checkout of the test's own and the
    # stand-in command line.
    ROOT="$DRIVE_SCRATCH/checkout"
    CELL_CLI="$DRIVE_SCRATCH/bin/cyfr"
    shift
    "$@"
    ;;
esac
SH
drive() { DRIVE_SCRATCH="$scratch" DRIVE_CHECKOUT="$root" bash "$scratch/drive.sh" "$@"; }

# --- the reuse key -----------------------------------------------------------

tree="$scratch/tree"
mkdir -p "$tree" "$scratch/build/rel/cyfr/bin" "$scratch/bin"
printf '#!/bin/sh\nexit 0\n' >"$scratch/build/rel/cyfr/bin/cyfr"
chmod +x "$scratch/build/rel/cyfr/bin/cyfr"
git -C "$tree" init -q
git -C "$tree" config user.email test@example.com
git -C "$tree" config user.name test
printf 'one\n' >"$tree/a.txt"
printf 'two\n' >"$tree/b.txt"
# The checkout's own ignore rules, so the build's output is ignored here
# as it is there, and one directory of the test's.
{ cat "$root/.gitignore"; printf 'ignored/\n'; } >"$tree/.gitignore"
# A static source mix assets.deploy digests, and a .gz it does not write.
mkdir -p "$tree/apps/cyfr/priv/static" "$tree/apps/cyfr/assets"
printf 'User-agent: *\n' >"$tree/apps/cyfr/priv/static/robots.txt"
printf 'vendored\n' | gzip -n >"$tree/apps/cyfr/assets/vendor.js.gz"
# The precompiled NIF fetch the build runs after mix deps.get, standing in.
mkdir -p "$tree/scripts"
printf '#!/bin/sh\nexit 0\n' >"$tree/scripts/fetch-precompiled-nifs.sh"
chmod +x "$tree/scripts/fetch-precompiled-nifs.sh"
git -C "$tree" add -A
git -C "$tree" commit -qm base

reused() { [ "$(status_of drive reuse)" = 0 ] || { cat "$scratch/out" >&2; fail "$1"; }; has "reusing the sqlite release" "$1"; }
refused() {
  [ "$(status_of drive reuse)" = 1 ] || { cat "$scratch/out" >&2; fail "reused the release: $1"; }
  has "the reused release was built from another tree" "$1"
  has "$2" "$1: the refusal names $2"
  has "run without RELEASE_BOOT_SKIP_BUILD=1" "$1: the refusal says how to rebuild"
}

drive record
grep -Eqx "head=$(git -C "$tree" rev-parse HEAD)" "$scratch/build/release-source" || fail "the record names another HEAD"
grep -Eqx 'adapter=sqlite' "$scratch/build/release-source" || fail "the record names another adapter"
reused "a matching tree"
pass "a release is reused from the tree it was built from"

mkdir -p "$tree/ignored"
printf 'build output\n' >"$tree/ignored/out.txt"
reused "an ignored file changed the key"
pass "an ignored file leaves the key"

printf 'new\n' >"$tree/c.txt"
refused "an untracked file" "tree (built from"
rm "$tree/c.txt"
reused "the tree again after the untracked file went"
printf 'first\n' >"$tree/c.txt"
drive record
reused "a tree holding an untracked file"
printf 'second\n' >"$tree/c.txt"
refused "an untracked file's content rewritten under its path" "tree (built from"
rm "$tree/c.txt"
drive record
reused "the tree again after the untracked file went"
pass "an untracked file, and its content, change the key"

printf 'changed\n' >>"$tree/a.txt"
refused "a modified tracked file" "tree (built from"
git -C "$tree" add a.txt
refused "a staged tracked file" "tree (built from"
git -C "$tree" reset -q --hard
reused "the tree again after the change was undone"
pass "a modified and a staged file change the key"

rm "$tree/b.txt"
refused "a deleted tracked file" "tree (built from"
git -C "$tree" checkout -q -- b.txt
pass "a deleted tracked file changes the key"

printf 'three\n' >"$tree/d.txt"
git -C "$tree" add d.txt
git -C "$tree" commit -qm next
refused "another HEAD" "head (built from"
git -C "$tree" reset -q --hard HEAD~1
reused "the first HEAD again"
pass "another HEAD changes the key"

sed -i 's/^adapter=sqlite$/adapter=postgres/' "$scratch/build/release-source"
refused "another adapter" "adapter (built from"
drive record
cp "$scratch/build/release-source" "$scratch/record"

rm "$scratch/build/release-source"
refused "a missing record" "release-source is missing"
head -n 2 "$scratch/record" >"$scratch/build/release-source"
refused "a record of two lines" "release-source is malformed"
{ cat "$scratch/record"; printf 'tree=%064d\n' 0; } >"$scratch/build/release-source"
refused "a record of four lines" "release-source is malformed"
sed 's/^tree=.*/tree=not-a-digest/' "$scratch/record" >"$scratch/build/release-source"
refused "a record with no digest" "release-source is malformed"
sed 's/^head=.*/head=not-a-commit/' "$scratch/record" >"$scratch/build/release-source"
refused "a record with no commit" "release-source is malformed"
sed 's/^adapter=.*/adapter=mysql/' "$scratch/record" >"$scratch/build/release-source"
refused "a record naming no adapter of the release's" "release-source is malformed"
cp "$scratch/record" "$scratch/build/release-source"
reused "the record restored"
pass "a missing or malformed record is refused"

# A stand-in `mix`: assets.deploy writes what phx.digest writes beside a
# static source, its gzip companion and digested copies (ignored, as the
# checkout's rules ignore them), and `release` leaves a release. With
# STUB_MIX_EDIT=PATH, a developer's save lands on PATH while the release
# builds.
static=apps/cyfr/priv/static
digested="$static/sw-0123456789abcdef0123456789abcdef.js"
cat >"$scratch/bin/mix" <<SH
#!/usr/bin/env bash
case "\$1" in
  assets.deploy)
    gzip -n -c $static/robots.txt >$static/robots.txt.gz
    cp $static/robots.txt $static/robots-9e2c81b0855bbff2baa8371bc4a78186.txt
    gzip -n -c $static/robots.txt >$static/robots-9e2c81b0855bbff2baa8371bc4a78186.txt.gz
    printf 'self.addEventListener("fetch", () => {});\\n' >"$digested"
    gzip -n -c "$digested" >"$digested.gz"
    ;;
  release)
    mkdir -p "\$MIX_BUILD_PATH/rel/cyfr/bin"
    printf '#!/bin/sh\\nexit 0\\n' >"\$MIX_BUILD_PATH/rel/cyfr/bin/cyfr"
    chmod +x "\$MIX_BUILD_PATH/rel/cyfr/bin/cyfr"
    [ -z "\${STUB_MIX_EDIT:-}" ] || printf 'saved while the release built\\n' >>"\$STUB_MIX_EDIT"
    ;;
esac
exit 0
SH
chmod +x "$scratch/bin/mix"
# The tree as a checkout leaves it: the sources, none of the build's output.
unbuilt() {
  git -C "$tree" checkout -q -- .
  git -C "$tree" clean -q -fdX -- "$static"
}
edited_mid_build() {
  [ "$(STUB_MIX_EDIT="$1" status_of drive build)" = 1 ] || { cat "$scratch/out" >&2; fail "a release built around a mid-build edit of $1 was recorded"; }
  has "the tree changed while the sqlite release built" "a mid-build edit of $1: the refusal says the tree changed"
  [ ! -e "$scratch/build/release-source" ] || fail "a release built around a mid-build edit of $1 left a record"
  refused "the release built around a mid-build edit of $1" "release-source is missing"
  unbuilt
}
edited_mid_build a.txt
pass "a tracked file edited while the release builds leaves the release unrecorded"
edited_mid_build apps/cyfr/priv/static/robots.txt
pass "a static source under apps/cyfr/priv/static edited while the release builds leaves it unrecorded"
edited_mid_build apps/cyfr/assets/vendor.js.gz
pass "a .gz outside apps/cyfr/priv/static edited while the release builds leaves it unrecorded"

[ "$(status_of drive build)" = 0 ] || { cat "$scratch/out" >&2; fail "a build that wrote only its own output was not recorded"; }
for f in "$static/robots.txt.gz" "$digested" "$digested.gz"; do [ -f "$tree/$f" ] || fail "the stand-in build wrote no $f"; done
[ -z "$(git -C "$tree" status --porcelain -- "$static")" ] || { git -C "$tree" status --porcelain -- "$static" >&2; fail "the build's output under $static is not ignored"; }
[ -s "$scratch/build/release-source" ] || fail "a build that wrote only its own output left no record"
reused "the release whose build wrote its digested copies and .gz"
unbuilt
pass "a build that writes digested copies and .gz into the ignored paths is recorded and reused"

# --- the readiness window ------------------------------------------------------

# A release whose `start` holds a listener on the cell's port that accepts
# and never answers, and whose `stop` ends it. Its log first writes every
# secret the cell holds, and a bearer credential, which the failure's dump
# of that log must not show.
port=$(free_port)
mkdir -p "$scratch/cell"
{
  printf 'CYFR_PORT=%s\n' "$port"
  echo "CYFR_SECRET_KEY_BASE=key-base-Q7w9e2r4t6y8u0i1o3p5"
  echo "CYFR_LOCUS_BACKENDS_KEY=backends-key-5f1e9d3c7b"
  echo "CYFR_DATABASE_URL=postgres://cyfr:db-pass-8642@localhost:5432/cyfr_x"
} >"$scratch/cell/.env"
printf '{"primary":"k1","keys":{"k1":"keyring-key-A1b2C3d4E5f6="}}' >"$scratch/cell/keyring.json"
cat >"$scratch/build/rel/cyfr/bin/cyfr" <<SH
#!/usr/bin/env bash
case "\$1" in
  start)
    echo "key base \$CYFR_SECRET_KEY_BASE, backends \$CYFR_LOCUS_BACKENDS_KEY"
    echo "repo at \$CYFR_DATABASE_URL, password db-pass-8642"
    echo "keyring \$CYFR_CRYPTO_KEYRING, key keyring-key-A1b2C3d4E5f6="
    echo "authorization: Bearer bearer-cred-9753"
    echo \$\$ >"\$PWD/stub.pid"; exec python3 "$scratch/serve.py" hang 127.0.0.1 "\$CYFR_PORT" ;;
  stop) kill "\$(cat "\$PWD/stub.pid")" 2>/dev/null; exit 0 ;;
esac
SH
ready=4
probe=$(sed -n 's/^READY_PROBE_SECONDS=//p' "$root/tests/release-boot/release.sh")
[[ "$probe" =~ ^[0-9]+$ ]] || fail "release.sh names no READY_PROBE_SECONDS"
started=$SECONDS
status=$(status_of timeout -k 5 120 bash -c 'DRIVE_SCRATCH="$1" DRIVE_CHECKOUT="$2" bash "$1/drive.sh" start "$3"' _ "$scratch" "$root" "$ready")
took=$((SECONDS - started))
[ "$status" = 1 ] || { cat "$scratch/out" >&2; fail "a listener that never answers ended server_start with $status, not 1"; }
has "did not answer /api/health/ready on 127.0.0.1:$port within ${ready}s" "the failure names the port and the window"
has "cell $scratch/cell" "the failure names the cell"
has "----- boot log of cell $scratch/cell -----" "the failure prints the boot log"
has "[secret]" "the boot log's secrets are masked"
for secret in key-base-Q7w9e2r4t6y8u0i1o3p5 backends-key-5f1e9d3c7b db-pass-8642 keyring-key-A1b2C3d4E5f6 bearer-cred-9753; do
  if grep -qF -- "$secret" "$scratch/out"; then cat "$scratch/out" >&2; fail "the failed start's boot log shows $secret"; fi
done
# The window, one probe, and the stop of a listener that ends on `stop`.
[ "$took" -le $((ready + probe + 5)) ] || fail "server_start gave up after ${took}s, past ${ready}s and one ${probe}s probe"
if accepts 127.0.0.1 "$port" 2>/dev/null; then fail "a listener outlived the failed start on $port"; fi
if kill -0 "$(cat "$scratch/cell/stub.pid")" 2>/dev/null; then fail "the started server outlived the failed start"; fi
pass "a listener that never answers fails server_start in ${took}s, naming the cell and port, printing its log with no secret of the cell's, and leaves no server"

# --- a cell's deployment file, from the command line --------------------------

# A checkout holding what cell_new reads of one: .env.example, a seed tree
# and a wasm-tools installer that installs nothing.
mkdir -p "$scratch/checkout/scripts" "$scratch/checkout/seed/aqua" "$scratch/bin"
cp "$root/.env.example" "$scratch/checkout/.env.example"
printf '#!/bin/sh\nexit 0\n' >"$scratch/checkout/scripts/wasm-tools.sh"
chmod +x "$scratch/checkout/scripts/wasm-tools.sh"
# The stand-in `cyfr`: it records how each run was made (its arguments,
# HOME, its directory's name, the names in its environment and whether
# .env.example is the checkout's) in calls.log, then does what init and
# access do to .env, or exits as $scratch/cli-fails says. It reads nothing
# of the caller's environment, which cell_cli clears.
cat >"$scratch/bin/cyfr" <<SH
#!/usr/bin/env bash
{
  printf 'args=%s\\n' "\$*"
  printf 'home=%s\\n' "\$HOME"
  printf 'dir=%s\\n' "\$(basename "\$PWD")"
  printf 'env=%s\\n' "\$(env | cut -d= -f1 | sort | tr '\\n' ' ')"
  if cmp -s .env.example "$scratch/checkout/.env.example"; then echo example=same; else echo example=other; fi
} >>"$scratch/calls.log"
if [ -s "$scratch/cli-fails" ]; then
  # Failing after it wrote .env and printed a secret of it.
  sed -e 's/^CYFR_SECRET_KEY_BASE=\$/CYFR_SECRET_KEY_BASE=stub-key-base-0123456789abcdef/' .env.example >.env
  echo "the key base: stub-key-base-0123456789abcdef"
  exit "\$(cat "$scratch/cli-fails")"
fi
command="\$1" domain=""
while [ \$# -gt 0 ]; do [ "\$1" = --domain ] && domain="\$2"; shift; done
case "\$command" in
  init)
    [ ! -e .env ] || exit 9
    sed -e 's/^CYFR_SECRET_KEY_BASE=\$/CYFR_SECRET_KEY_BASE=stub-key-base-0123456789abcdef/' .env.example >.env
    ;;
  access) [ -e .env ] || exit 9 ;;
esac
if [ -n "\$domain" ]; then
  sed -i -e 's/^CYFR_ACCESS=.*/CYFR_ACCESS=public/' -e "s/^CYFR_HOST=.*/CYFR_HOST=\$domain/" .env
  [ -e "$scratch/cli-writes-no-url" ] || echo "CYFR_PUBLIC_URL=https://\$domain" >>.env
fi
exit 0
SH
chmod +x "$scratch/bin/cyfr"
cell() { DRIVE_SCRATCH="$scratch" DRIVE_CHECKOUT="$root" COMPOSE_PROFILES=public CYFR_LEFTOVER=1 bash "$scratch/drive.sh" cell "$@"; }
calls() { sed -n "s/^$1=//p" "$scratch/calls.log"; }
assigned() { grep -c "^$2=" "$scratch/cells/$1/.env"; }
value() { sed -n "s/^$2=//p" "$scratch/cells/$1/.env"; }
mkdir -p "$scratch/cells"

: >"$scratch/calls.log"
[ "$(status_of cell cell_new "$scratch/cells/local")" = 0 ] || { cat "$scratch/out" >&2; fail "cell_new failed on the stand-in command line"; }
[ "$(calls args)" = "init --no-interactive --no-pull --access local" ] || fail "cell_new ran cyfr $(calls args), not init --no-interactive --no-pull --access local"
[ "$(calls home)" = "$scratch/cells/local/home" ] || fail "the command line ran with HOME $(calls home), not the cell's"
[[ "$(calls dir)" == cyfr-cell-local-* ]] || fail "the command line ran in $(calls dir), not a directory of the run's own"
[ "$(calls example)" = same ] || fail "the command line's .env.example is not the checkout's"
case " $(calls env) " in
  *" COMPOSE_PROFILES "* | *" CYFR_LEFTOVER "*) fail "the caller's environment reached the command line: $(calls env)" ;;
esac
for key in CYFR_PUBLIC_URL CYFR_BIND_ADDRESS; do
  [ "$(assigned local "$key")" = 0 ] || fail "the local cell's deployment file assigns $key"
done
for pair in CYFR_ACCESS=local CYFR_HOST=localhost CYFR_PORT=4399 CYFR_DATABASE=sqlite CYFR_AUTO_MIGRATE=on \
  CYFR_HOST_API_BIND=127.0.0.1 CYFR_HOST_API_PORT=4398 LOCUS_RUNTIME_SERVICE_ID=wrk_locus \
  CYFR_PLATFORM_ADMIN_EMAILS=operator@example.com CYFR_SECRET_KEY_BASE=stub-key-base-0123456789abcdef; do
  [ "$(assigned local "${pair%%=*}")" = 1 ] && [ "$(value local "${pair%%=*}")" = "${pair#*=}" ] ||
    fail "the local cell's deployment file does not assign $pair once: $(grep "^${pair%%=*}=" "$scratch/cells/local/.env" | tr '\n' ' ')"
done
# init's own lines stay where init wrote them; the test's settings
# rewrite in place.
[ "$(grep -n '^CYFR_PORT=' "$scratch/cells/local/.env" | cut -d: -f1)" = "$(grep -n '^CYFR_PORT=' "$root/.env.example" | cut -d: -f1)" ] ||
  fail "CYFR_PORT moved from the line init wrote it on"
pass "a local cell is init's deployment file with the test's settings beside it, none of the caller's environment reaching the command line"

: >"$scratch/calls.log"
[ "$(status_of cell cell_new "$scratch/cells/named" "" cyfr.example.com)" = 0 ] || { cat "$scratch/out" >&2; fail "cell_new failed for a named cell"; }
[ "$(calls args)" = "init --no-interactive --no-pull --access public --domain cyfr.example.com" ] ||
  fail "cell_new ran cyfr $(calls args) for a named cell"
[ "$(status_of cell cell_hostname "$scratch/cells/named" cyfr.example.com 4500)" = 0 ] || { cat "$scratch/out" >&2; fail "cell_hostname failed"; }
[ "$(grep -c '^args=' "$scratch/calls.log")" = 1 ] || fail "cell_hostname ran the command line again on a cell init made public at its name: $(calls args)"
for pair in CYFR_ACCESS=public CYFR_HOST=cyfr.example.com CYFR_PUBLIC_URL=https://cyfr.example.com CYFR_PORT=4500 CYFR_HOST_API_PORT=4501 CYFR_PROXY_PORT=4502; do
  [ "$(assigned named "${pair%%=*}")" = 1 ] && [ "$(value named "${pair%%=*}")" = "${pair#*=}" ] ||
    fail "the named cell's deployment file does not assign $pair once"
done
[ "$(cat "$scratch/cells/named/node")" = "cyfr-cyfr-example-com-sqlite-$(cat "$scratch/cells/named/node" | sed 's/.*-//')" ] ||
  fail "the named cell's node name is not its own: $(cat "$scratch/cells/named/node")"
[ "$(DRIVE_SCRATCH="$scratch" DRIVE_CHECKOUT="$root" bash "$scratch/drive.sh" cell cell_proxy_port "$scratch/cells/named")" = 4502 ] ||
  fail "cell_proxy_port does not answer the named cell's proxy listener port"
pass "a named cell is init's public home at its name, on three ports of its own, its proxy listener's the third"

: >"$scratch/calls.log"
: >"$scratch/cli-writes-no-url"
cp -a "$scratch/cells/local" "$scratch/cells/moved"
key_before="$(value moved CYFR_SECRET_KEY_BASE)"
[ "$(status_of cell cell_hostname "$scratch/cells/moved" other.example.com 4600)" = 0 ] || { cat "$scratch/out" >&2; fail "cell_hostname failed on a local cell"; }
[ "$(calls args)" = "access public --domain other.example.com --yes" ] || fail "cell_hostname ran cyfr $(calls args) on a local cell"
[ "$(value moved CYFR_SECRET_KEY_BASE)" = "$key_before" ] || fail "the switch lost the cell's key base"
[ "$(value moved CYFR_ACCESS)" = public ] && [ "$(value moved CYFR_HOST)" = other.example.com ] || fail "the switched cell is not public at other.example.com"
[ "$(assigned moved CYFR_PUBLIC_URL)" = 0 ] || fail "the fixture wrote a CYFR_PUBLIC_URL the command line did not"
rm -f "$scratch/cli-writes-no-url"
pass "a local cell becomes a public home through cyfr access, its keys kept, and the fixture writes no address of its own"

printf '3\n' >"$scratch/cli-fails"
[ "$(status_of cell cell_new "$scratch/cells/failed")" = 1 ] || fail "a command line that failed did not fail cell_new"
has "cyfr init exited 3 for cell $scratch/cells/failed" "the failure names the command and the cell"
has "the command line's output for cell" "the failure prints the command line's output"
if grep -qF stub-key-base-0123456789abcdef "$scratch/out"; then fail "the failure printed the key base the command line wrote"; fi
rm -f "$scratch/cli-fails"
pass "a failed command line fails the cell, printing its output redacted"

mkdir -p "$scratch/cells/dotenv"
cat >"$scratch/cells/dotenv/.env" <<'ENV'
# a comment
export EXPORTED=1

SINGLE='a b # c $HOME'
DOUBLE="plain"
EMPTY=
PLAIN=x=y
ENV
DRIVE_SCRATCH="$scratch" DRIVE_CHECKOUT="$root" bash "$scratch/drive.sh" cell cell_assignments "$scratch/cells/dotenv" >"$scratch/assignments"
[ "$(cat "$scratch/assignments")" = "$(printf '%s\n' 'EXPORTED=1' 'SINGLE=a b # c $HOME' 'DOUBLE=plain' 'EMPTY=' 'PLAIN=x=y')" ] ||
  fail "cell_assignments read $(tr '\n' '|' <"$scratch/assignments")"
for line in 'INLINE=x # comment' 'OPEN="x' 'ESCAPED="a\nb"' 'not an assignment'; do
  printf '%s\n' "$line" >"$scratch/cells/dotenv/.env"
  [ "$(status_of bash -c 'DRIVE_SCRATCH="$1" DRIVE_CHECKOUT="$2" bash "$1/drive.sh" cell cell_assignments "$1/cells/dotenv"' _ "$scratch" "$root")" = 1 ] ||
    fail "cell_assignments read '$line' instead of refusing it"
  has "cannot read as the release does" "the refusal of '$line' says why"
done
pass "a deployment file's lines are read as a dotenv reader reads them, and a line that cannot be is refused"

# --- the identity front's readiness -----------------------------------------

# `docker` as the front sees it: `run` starts the front's control listener
# answering the token it was given (STUB_FRONT=own), or starts nothing, a
# front that could not listen (STUB_FRONT=dead); `inspect` says which.
mkdir -p "$scratch/bin" "$scratch/authority" "$scratch/dir"
: >"$scratch/authority/dir.test.pem"
printf 'CYFR_HOST=dir.test\nCYFR_PORT=%s\nCYFR_PROXY_PORT=%s\n' "$(free_port)" "$(free_port)" >"$scratch/dir/.env"
cat >"$scratch/bin/docker" <<SH
#!/usr/bin/env bash
case "\$1" in
  run)
    if [ "\$STUB_FRONT" = own ]; then
      for ((i = 1; i <= \$#; i++)); do
        case "\${!i}" in *:443) address="\${!i%:443}"; next=\$((i + 1)); control="\${!next}" ;; esac
      done
      token="\${!#}"
      python3 "$scratch/serve.py" json "\$address" "\$control" "{\"name\":\"dir.test\",\"mode\":\"none\",\"token\":\"\$token\"}" &
      echo \$! >"$scratch/own.pid"
    fi
    echo stub-container
    ;;
  inspect) if [ "\$STUB_FRONT" = own ]; then echo true; else echo false; fi ;;
  logs) echo "the stand-in front's log" ;;
esac
exit 0
SH
chmod +x "$scratch/bin/docker"
front() { PATH="$scratch/bin:$PATH" STUB_FRONT="$1" drive front "$2" "$3"; }

control=$(free_port)
python3 "$scratch/serve.py" json 127.77.0.9 "$control" '{"name":"dir.test","mode":"none"}' &
servers+=("$!")
until_true 10 accepts 127.77.0.9 "$control" || fail "the stranger never listened"
[ "$(status_of front dead 127.77.0.9 "$control")" = 1 ] || { cat "$scratch/out" >&2; fail "a stranger's health answer was taken for the front's"; }
has "the front of dir.test stopped before it answered on http://127.77.0.9:$control, where another front answers" \
  "the refusal names the front and the stranger"
pass "a stranger answering on the front's address without the front's token is refused"

control=$(free_port)
[ "$(status_of front own 127.77.0.10 "$control")" = 0 ] || { cat "$scratch/out" >&2; fail "the front's own health answer was refused"; }
kill "$(cat "$scratch/own.pid")" 2>/dev/null || :
pass "the front's own health answer, with its token, is accepted"

# --- the redaction --------------------------------------------------------------

cat >"$scratch/redact-check.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const { redact, MARKER } = await import(pathToFileURL(process.argv[2]).href);

// The keys and attributes whose values a proof's record never shows.
const SECRET_KEYS = ["session", "static", "_csrf_token", "token", "plan_token", "proof"];
const SECRET_ATTRIBUTES = ["data-phx-session", "data-phx-static", "data-csrf"];

// Each case: a text, the secrets the proof knew, and what must not be
// written of it.
const cases = [
  { text: "cookie=k3y-c00kie-value; seen", secrets: ["k3y-c00kie-value"], hidden: ["k3y-c00kie-value"] },
  { text: '{"kit":"line-one-of-the-kit"}', secrets: ["line-one-of-the-kit"], hidden: ["line-one-of-the-kit"] },
  { text: "a frame cut short at k3y-c0", secrets: ["k3y-c00kie-value"], hidden: ["k3y-c0"] },
  ...SECRET_KEYS.map((key) => ({ text: `{"${key}":"v-${key}-1234"}`, secrets: [], hidden: [`v-${key}-1234`] })),
  { text: '[\\"phx\\",{\\"session\\":\\"escaped-session-5678\\"}]', secrets: [], hidden: ["escaped-session-5678"] },
  { text: '{"plan_token":"cut-short-plan-tok', secrets: [], hidden: ["cut-short-plan-tok"] },
  { text: '{"proof":"preview-proof-2468"}', secrets: [], hidden: ["preview-proof-2468"] },
  ...SECRET_ATTRIBUTES.map((a) => ({ text: `<div ${a}="attr-${a}-9876">`, secrets: [], hidden: [`attr-${a}-9876`] })),
  { text: '<div data-phx-session=\\"escaped-attr-4321\\">', secrets: [], hidden: ["escaped-attr-4321"] },
  { text: 'src="/_s/AbC-123_xyz/local/n/1.0.0/dist/index.html"', secrets: [], hidden: ["AbC-123_xyz"] },
  { text: "GET /_s/Pr3fixCred/x.js 200", secrets: [], hidden: ["Pr3fixCred"] },
  { text: "/_s/cut-short-pr3fix", secrets: [], hidden: ["cut-short-pr3fix"] },
  { text: '"/_c/v1/HostCred-77/app.js"', secrets: [], hidden: ["HostCred-77"] },
  { text: "token SFMyNTY.g2gDbQ.AAAA-bbbb_cc and on", secrets: [], hidden: ["g2gDbQ.AAAA-bbbb_cc"] },
  { text: "authorization: Bearer bearer-cred-42", secrets: [], hidden: ["bearer-cred-42"] },
  { text: '{"authorization":"bearer lower-cred-43"}', secrets: [], hidden: ["lower-cred-43"] },
];

const failures = [];
for (const c of cases) {
  for (const h of c.hidden) if (!c.text.includes(h)) failures.push(`the case ${JSON.stringify(c.text)} does not hold ${h}`);
  const out = redact(c.text, c.secrets);
  for (const h of c.hidden) if (out.includes(h)) failures.push(`${JSON.stringify(c.text)} is written ${JSON.stringify(out)}, holding ${h}`);
  if (redact(out, c.secrets) !== out) failures.push(`redacting ${JSON.stringify(out)} again changed it`);
}

// The marker forms.
const forms = redact('src="/_s/Cred/x" "/_c/v1/Cred/y" SFMyNTY.a.b Bearer z known-secret-1', ["known-secret-1"]);
for (const marker of ["/_s/[credential]/", "/_c/v1/[credential]/", "[signed token]", `Bearer ${MARKER}`, ` ${MARKER}`]) {
  if (!forms.includes(marker)) failures.push(`the marker ${marker} is not in ${JSON.stringify(forms)}`);
}
// JSON text stays JSON: a masked value before an escaped quote keeps the
// escape. The approval record's resolved policy (escaped JSON holding the
// attach template) and an asset address inside a string, written as the
// approval proof writes its record (`recordText`, indented) and as the
// hostile-frame proof's brief and the canvas proof's record are read back
// (`JSON.parse(redact(JSON.stringify(x)))`).
const shapes = {
  approval: { resolved_policy: JSON.stringify({ attach: { in: "header", name: "Authorization", template: "Bearer {value}" } }) },
  asset: { m: 'loaded "/_s/Cred99" and stopped', host: 'framed "/_c/v1/HostCred" too' },
  brief: { src: "/_s/Cred", frame: JSON.stringify({ src: "/_s/Cred", auth: "Bearer tok" }) },
};
for (const [name, value] of Object.entries(shapes)) {
  for (const indent of [2, undefined]) {
    const out = redact(JSON.stringify(value, null, indent), []);
    try {
      JSON.parse(out);
    } catch (error) {
      failures.push(`the ${name} shape${indent ? ", indented," : ""} is not JSON once redacted: ${out.replace(/\s+/g, " ")} (${error.message})`);
    }
    for (const kept of ["Cred99", "HostCred", "/_s/Cred", "Bearer tok"]) if (out.includes(kept)) failures.push(`the ${name} shape kept ${kept}: ${out}`);
  }
}

// What a proof asserts on is not a secret, and stays: a key that only ends
// in a secret-named key's name is not one.
const plain = '{"name":"proof-game","reproof":"kept-1357","suite":"canvas","path":"/t/@person/local/proof-game","held":true}';
if (redact(plain, []) !== plain) failures.push(`a record with no secret is written ${JSON.stringify(redact(plain, []))}`);

for (const f of failures) console.error(`FAIL: ${f}`);
if (failures.length) process.exit(1);
console.log(`ok: ${cases.length} cases, each value hidden`);
JS
node "$scratch/redact-check.mjs" "$root/tests/browser/lib.mjs" || fail "the redaction leaves a value it hides"
pass "the redaction hides every case's values, keeps JSON JSON and keeps what is not a secret"

node --test "$root/tests/browser/lib-test.mjs" || fail "the browser harness did not handle a peer reset"
pass "the browser harness records idle resets and fails active transfers without ending the process"

echo "release-boot-test: all checks passed"
