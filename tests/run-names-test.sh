#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/lib/run-names.sh against toy Git worktrees and listeners this
# test holds on 127.0.0.1. It needs git, python3 and a SHA-256 tool, and
# no Docker, database or build.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
LIB="$root/scripts/lib/run-names.sh"
S=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-run-names-test.XXXXXX")
S=$(cd "$S" && pwd -P)

# Git finds no repository above the scratch directory, whatever holds it,
# and no configuration of the host's changes what the toy repositories do.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export GIT_CEILING_DIRECTORIES="$S" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

cleanup() {
  local f
  for f in "$S"/*.pid; do
    [ -s "$f" ] && kill "$(cat "$f")" 2>/dev/null
  done
  rm -rf "$S"
}
trap 'cleanup 2>/dev/null || :' EXIT

case_name=
fail() { echo "FAIL: $case_name: $*" >&2; exit 1; }
begin() { case_name=$1; echo "case $case_name"; }

# A bounded wait on an observable condition: `until_true 10 test -e file`.
until_true() {
  local limit=$(( $1 * 10 )) n=0
  shift
  until "$@" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt "$limit" ] || return 1
    sleep 0.1
  done
}

# The seed the contract names, computed here on its own, through Python
# rather than either tool the library reads: the first ten hex digits of
# the SHA-256 of the directory's physical path.
expected_seed() {
  local physical
  physical=$(cd "$1" && pwd -P)
  python3 -I -c 'import hashlib, os, sys; print(hashlib.sha256(os.fsencode(sys.argv[1])).hexdigest()[:10])' "$physical"
}

# A directory holding only the named tools, as links to the host's, for a
# PATH that hides every other.
only_tools() {
  local dir=$1 tool
  shift
  mkdir -p "$dir"
  for tool in "$@"; do ln -sf "$(command -v "$tool")" "$dir/$tool"; done
}

# A python3 for run_names_free_port's bind check that counts every bind it
# is asked for, one port per line in $COUNTING_LOG, and refuses each one
# as a held port would. Any other use runs the host's python3.
counting_python() {
  mkdir -p "$S/counting"
  cat >"$S/counting/python3" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -I ] && [ "$2" = -c ]; then
  code=$3; shift 3
  exec "$COUNTING_REAL" -I -c "import errno, os, socket
def bind(self, address):
    with open(os.environ['COUNTING_LOG'], 'a') as log:
        log.write('%d\n' % address[1])
    raise OSError(errno.EADDRINUSE, 'held')
socket.socket.bind = bind
$code" "$@"
fi
exec "$COUNTING_REAL" "$@"
EOF
  chmod +x "$S/counting/python3"
  COUNTING_REAL=$(command -v python3) COUNTING_LOG="$S/binds"
  export COUNTING_REAL COUNTING_LOG
}

# A listener on 127.0.0.1:PORT until the test ends, ready once its file
# exists. Refuses when the port cannot be held.
hold() {
  python3 -I -c '
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen()
open(sys.argv[2], "w").close()
time.sleep(600)
' "$1" "$S/hold-$1.ready" 2>/dev/null &
  echo $! >"$S/hold-$1.pid"
  until_true 10 test -e "$S/hold-$1.ready" || fail "could not hold port $1"
}

# Whether a bind on 127.0.0.1:PORT succeeds now.
bindable() {
  python3 -I -c '
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
' "$1"
}

# shellcheck source=../scripts/lib/run-names.sh
. "$LIB"

git init -q -b main "$S/repo"
git -C "$S/repo" -c user.name=test -c user.email=test@invalid commit -q --allow-empty -m init
git -C "$S/repo" worktree add -q --detach "$S/wt1"
git -C "$S/repo" worktree add -q --detach "$S/wt2"
mkdir -p "$S/wt1/sub/dir" "$S/outside"
ln -s "$S/wt1" "$S/link"

begin 'the seed is ten hex digits of the worktree physical path, from any spelling of it'
seed=$(run_names_seed "$S/wt1")
[[ $seed =~ ^[0-9a-f]{10}$ ]] || fail "not ten lowercase hex digits: $seed"
[ "$seed" = "$(expected_seed "$S/wt1")" ] || fail "seed $seed is not the path's digest $(expected_seed "$S/wt1")"
[ "$(run_names_seed "$S/link")" = "$seed" ] || fail 'a symlink to the worktree gave another seed'
[ "$(run_names_seed "$S/link/sub/dir")" = "$seed" ] || fail 'a subdirectory through the symlink gave another seed'
[ "$(cd "$S/link/sub" && run_names_seed)" = "$seed" ] || fail 'the working directory, reached through the symlink, gave another seed'

begin 'without sha256sum the seed is the same, through shasum'
command -v shasum >/dev/null 2>&1 || fail 'shasum is not installed, so its fallback cannot be shown'
only_tools "$S/shasum-only" git shasum
if (PATH="$S/shasum-only"; command -v sha256sum) >/dev/null 2>&1; then fail 'sha256sum is still on the narrowed PATH'; fi
[ "$(PATH="$S/shasum-only"; run_names_seed "$S/wt1")" = "$seed" ] || fail 'shasum gave another seed than sha256sum'
only_tools "$S/git-only" git
status=0; (PATH="$S/git-only"; run_names_seed "$S/wt1") >/dev/null 2>"$S/err" || status=$?
[ "$status" = 69 ] || fail "with neither tool the seed returned $status, not 69"
grep -qF 'sha256sum or shasum is required' "$S/err" || fail "the refusal does not name the tools: $(cat "$S/err")"

begin 'two worktrees of one repository get distinct seeds'
[ "$(run_names_seed "$S/wt2")" = "$(expected_seed "$S/wt2")" ] || fail 'the second worktree seed is not its path digest'
[ "$(run_names_seed "$S/wt2")" != "$seed" ] || fail 'two worktrees share a seed'
[ "$(run_names_seed "$S/repo")" != "$seed" ] || fail 'the main worktree shares a seed with a linked one'

begin 'outside a checkout the seed and the prefix return 69, naming the directory'
for dir in "$S/outside" "$S/missing" "$S/repo/.git"; do
  status=0; out=$(run_names_seed "$dir" 2>"$S/err") || status=$?
  [ "$status" = 69 ] || fail "run_names_seed $dir returned $status, not 69"
  [ -z "$out" ] || fail "run_names_seed $dir printed $out"
  grep -qF "$dir is not inside a git worktree" "$S/err" || fail "the refusal does not name $dir: $(cat "$S/err")"
done
status=0; (cd "$S/outside" && run_names_seed) >/dev/null 2>&1 || status=$?
[ "$status" = 69 ] || fail "the working directory outside a checkout returned $status, not 69"
status=0; run_names_prefix "$S/outside" >/dev/null 2>&1 || status=$?
[ "$status" = 69 ] || fail "run_names_prefix outside a checkout returned $status, not 69"

begin 'the prefix carries the seed and the calling script pid, and the pattern matches it'
out=$(bash -c '. "$1"; run_names_prefix "$2"; echo "$$"' run-names "$LIB" "$S/wt1")
prefix=$(printf '%s\n' "$out" | sed -n 1p)
caller=$(printf '%s\n' "$out" | sed -n 2p)
[ "$prefix" = "cyfr-$seed-$caller-" ] || fail "prefix $prefix is not cyfr-$seed-$caller-"
[[ $prefix =~ $RUN_NAMES_PATTERN ]] || fail "the pattern does not match $prefix"
[ "${BASH_REMATCH[1]}" = "$seed" ] && [ "${BASH_REMATCH[2]}" = "$caller" ] ||
  fail "the pattern captured ${BASH_REMATCH[1]} and ${BASH_REMATCH[2]}"
[[ "${prefix}compose-proof-net" =~ $RUN_NAMES_PATTERN ]] || fail 'a name made from the prefix does not match'
[ "$(run_names_prefix "$S/wt1")" = "cyfr-$seed-$$-" ] || fail 'a command substitution did not keep the calling shell pid'
for name in "cyfr-gate-4242-boot-psql" "cyfr-${seed:0:9}-4242-x" "cyfr-${seed}x-4242-x" "cyfr-$seed--x" "x-cyfr-$seed-4242-"; do
  if [[ $name =~ $RUN_NAMES_PATTERN ]]; then fail "the pattern matches $name"; fi
done

begin 'a free port lies in 20000-29999 and binds'
[ "$RUN_NAMES_PORT_FIRST" = 20000 ] && [ "$RUN_NAMES_PORT_LAST" = 29999 ] ||
  fail "the range is $RUN_NAMES_PORT_FIRST-$RUN_NAMES_PORT_LAST"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  port=$(run_names_free_port)
  [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 20000 ] && [ "$port" -le 29999 ] || fail "port $port is outside 20000-29999"
  bindable "$port" || fail "port $port does not bind"
done

# Two neighbouring ports this test can hold, both free now.
first=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  port=$(run_names_free_port)
  if [ "$port" -lt 29999 ] && bindable "$((port + 1))"; then first=$port; break; fi
done
[ -n "$first" ] || fail 'found no two free neighbouring ports to narrow the range to'
second=$((first + 1))

begin 'a held port is skipped'
RUN_NAMES_PORT_FIRST=$first RUN_NAMES_PORT_LAST=$second
for _ in 1 2 3 4 5; do
  port=$(run_names_free_port)
  [ "$port" = "$first" ] || [ "$port" = "$second" ] || fail "with both free it returned $port, outside $first-$second"
done
hold "$first"
if bindable "$first"; then fail "the holder does not hold $first"; fi
for _ in $(seq 20); do
  port=$(run_names_free_port)
  [ "$port" = "$second" ] || fail "returned $port while $first is held"
done

begin 'with every port of the range held it returns 1, naming the range'
hold "$second"
status=0; out=$(run_names_free_port 2>"$S/err") || status=$?
[ "$status" = 1 ] || fail "returned $status, not 1"
[ -z "$out" ] || fail "printed $out"
grep -qF "no free port in $first-$second after 2 tries" "$S/err" || fail "the refusal does not name the range: $(cat "$S/err")"

begin 'the free port tries at most 50 ports, each once'
counting_python
RUN_NAMES_PORT_FIRST=20000 RUN_NAMES_PORT_LAST=20059
: >"$S/binds"
status=0; (PATH="$S/counting:$PATH"; run_names_free_port) >/dev/null 2>"$S/err" || status=$?
[ "$status" = 1 ] || fail "with all 60 ports refused it returned $status, not 1"
[ "$(wc -l <"$S/binds")" = 50 ] || fail "it tried $(wc -l <"$S/binds") ports of 60, not 50"
[ "$(sort -u "$S/binds" | wc -l)" = 50 ] || fail 'it tried a port twice'
grep -qF 'no free port in 20000-20059 after 50 tries' "$S/err" || fail "the refusal does not name the range: $(cat "$S/err")"
RUN_NAMES_PORT_LAST=20029
: >"$S/binds"
(PATH="$S/counting:$PATH"; run_names_free_port) >/dev/null 2>&1 || :
[ "$(sort -u "$S/binds" | wc -l)" = 30 ] && [ "$(wc -l <"$S/binds")" = 30 ] ||
  fail "in a range of 30 it tried $(wc -l <"$S/binds") binds over $(sort -u "$S/binds" | wc -l) ports, not each of the 30 once"
if awk '$1 < 20000 || $1 > 20029' "$S/binds" | grep -q .; then fail 'it tried a port outside the range'; fi

begin 'without python3 the free port returns 69'
mkdir -p "$S/empty-path"
status=0; (PATH="$S/empty-path"; run_names_free_port) >/dev/null 2>"$S/err" || status=$?
[ "$status" = 69 ] || fail "returned $status, not 69"
grep -qF 'python3 is required' "$S/err" || fail "the refusal does not name python3: $(cat "$S/err")"

echo 'run-names tests passed'
