#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/janitor.sh against planted state: a stand-in docker
# (tests/image-stub.sh) holding containers, networks, volumes and images
# named for live and finished runs, heavy-check holder records, image
# locks and uses, and run and log directories, under a toy repository with
# three worktrees and a clone. Each janitor run's output is printed,
# indented. It needs git, python3, flock, pgrep and setsid, and no
# Docker, database or build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-janitor-test.XXXXXX")
S=$(cd "$S" && pwd -P)
export ROOT S

cleanup() {
  local p
  if [ -s "$S/pids" ]; then
    while read -r p; do kill "$p" 2>/dev/null || :; done <"$S/pids"
  fi
  rm -rf "$S"
}
trap 'cleanup 2>/dev/null || :' EXIT

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR DOCKER_DEFAULT_PLATFORM STUB_PLATFORM PROOF_RUN_PREFIX
export GIT_CEILING_DIRECTORIES="$S" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$S/run" "$S/tmp"
export XDG_RUNTIME_DIR="$S/run" HEAVY_CHECK_LOCK="$S/hc.lock" JANITOR_TMP="$S/tmp"
STATE="$S/run/cyfr-image"
mkdir -p -m 700 "$STATE"

# shellcheck source=image-stub.sh
. "$ROOT/tests/image-stub.sh"
stub_docker

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

live_pid() { sleep 600 >/dev/null 2>&1 & echo $! >>"$S/pids"; echo $!; }
# Sets the modification time of each path to DAYS ago: age DAYS PATH...
age() { python3 -I -c 'import os, sys, time
t = time.time() - float(sys.argv[1]) * 86400
for p in sys.argv[2:]:
    os.utime(p, (t, t))' "$@"; }
inode() { ls -id "$1" | awk '{print $1}'; }
dead_pid() { ( exit 0 ) & local p=$!; wait "$p"; echo "$p"; }
OLD=2026-01-01T00:00:00Z
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
plant_image() { printf 'tag=%s\nlabel=%s\ncreated=%s\n' "$1" "$2" "$3" >"$(image_file "$1")"; }
plant_container() { printf 'image=%s\n' "${2:-busybox}" >"$DOCKER_STUB/containers/$1"; }
record() { printf 'pid=%s mode=scoped since=2026-10-29T00:00:00+0000 hold=2700s %s checkout=/x command=run pid=1 group=1\n' "$1" "$2" >"$3"; }
# Runs the janitor from the toy repository: janitor RUN-NAME ARGS...
janitor() {
  local name=$1 status=0
  shift
  (cd "$S/repo" && scripts/janitor.sh "$@") >"$S/$name.out" 2>&1 || status=$?
  sed 's/^/    /' "$S/$name.out"
  return "$status"
}
has() { grep -qxF -- "$2" "$S/$1.out" || fail "the $1 run did not say: $2"; }
lacks() { if grep -qF -- "$2" "$S/$1.out"; then fail "the $1 run named: $2"; fi; }
gone() { [ ! -e "$1" ] || fail "${1#"$S"/} is still there"; }
there() { [ -e "$1" ] || fail "${1#"$S"/} went"; }

toy_repo "$S/repo"
git -C "$S/repo" worktree add -q --detach "$S/wt2"
git -C "$S/repo" worktree add -q --detach "$S/wt3"
git clone -q "$S/repo" "$S/clone"

# Rule 1: run objects. seed is any ten hex digits.
seed=aaaaaaaaaa
d1=$(dead_pid); d2=$(dead_pid); d3=$(dead_pid); d4=$(dead_pid); d5=$(dead_pid)
l1=$(live_pid)
setsid sleep 600 >/dev/null 2>&1 & group=$!; echo "$group" >>"$S/pids"
until_true 10 eval '[ "$(ps -o pgid= -p "$group" | tr -d " ")" = "$group" ]' || fail "setsid did not make $group a group leader"
watchdog=$(live_pid)
for pid in "$d1" "$d2"; do
  plant_container "cyfr-$seed-$pid-compose-proof-cyfr-1"
  touch "$DOCKER_STUB/networks/cyfr-$seed-$pid-net" "$DOCKER_STUB/volumes/cyfr-$seed-$pid-pgdata"
  plant_image "cyfr-$seed-$pid-cyfr-tailscale-standin:run1" '' "$OLD"
done
l2=$(live_pid)
for pid in "$l1" "$l2" "$d3" "$d4" "$d5"; do plant_container "cyfr-$seed-$pid-proof"; done
record "$d2" "group=$(dead_pid) watchdog=$(dead_pid)" "$HEAVY_CHECK_LOCK.holder"
record "$d3" "group=$group watchdog=$(dead_pid)" "$HEAVY_CHECK_LOCK.slot1.holder"
record "$d4" "group=$(dead_pid) watchdog=$watchdog" "$HEAVY_CHECK_LOCK.slot2.holder"
record "$d5" '' "$HEAVY_CHECK_LOCK.proof.holder"
# A stale record, its group and watchdog gone, for a pid that still lives.
record "$l2" "group=$(dead_pid) watchdog=$(dead_pid)" "$HEAVY_CHECK_LOCK.slot3.holder"
plant_container other-project-db
plant_container cyfr-gate-4242-boot-psql
touch "$DOCKER_STUB/networks/cyfr-gate-4242-boot-net"

# Rule 2: labelled images, each kept for one reason alone or removable.
base=$(cd "$S/repo" && scripts/image.sh --tag-only locus)
t0=cyfr-locus:in-00000000000000000000
t2=cyfr-locus:in-22222222222222222222
t3=cyfr:in-33333333333333333333
t4=cyfr-locus:in-44444444444444444444
t5=cyfr-locus:in-55555555555555555555
plant_image "$base" "${base##*:in-}" "$OLD"
plant_image "$t0" "${t0##*:in-}" "$OLD"
plant_image "$t2" "${t2##*:in-}" "$OLD"
user=$(live_pid)
printf '%s\n' "$(dead_pid)" "$user" >"$STATE/${t2##*:in-}.uses"
plant_image "$t3" "${t3##*:in-}" "$OLD"
plant_container uses-t3 "$t3"
plant_image "$t4" "${t4##*:in-}" "$NOW"
plant_image "$t5" 'another-label' "$OLD"
plant_image cyfr-locus:c2c6 '' "$OLD"
# A worktree whose tag could be read before, and no longer can.
printf '# wt3\n' >>"$S/wt3/config/config.exs"
t6=$(cd "$S/wt3" && scripts/image.sh --tag-only locus)
plant_image "$t6" "${t6##*:in-}" "$OLD"
printf 'ADD config/config.exs /x\n' >>"$S/wt3/Dockerfile.locus"

# Rules 4 and 5: run and log directories.
run_dir() { # NAME RUNNER-PID: a runner directory with its pid
  mkdir -p "$S/tmp/$1"
  echo "$2" >"$S/tmp/$1/runner-pid"
}
# DIR N NAME [CREATED]: partition N's database receipt and env. The env's
# URL names CREATED, so a receipt whose CREATED differs from NAME is refused
# by the receipt check alone.
receipt() {
  mkdir -p "$1/p$2"
  printf '%s' "$3" >"$1/p$2/database-name"
  printf '%s' "${4:-$3}" >"$1/p$2/database-created"
  printf "export CYFR_DATABASE_URL='postgres://cyfr:s3cret@localhost:5432/%s'\n" "${4:-$3}" >"$1/p$2.env"
}
db=cyfr_test_0123456789abcdef0123456789abcdef_p1
run_dir cyfr-t.r1 "$(dead_pid)"; receipt "$S/tmp/cyfr-t.r1" 1 "$db"
run_dir cyfr-t.r2 "$(dead_pid)"; mkdir -p "$S/tmp/cyfr-t.r2/p1"; echo x >"$S/tmp/cyfr-t.r2/p1/database-create-pending"
run_dir cyfr-t.r3 "$(dead_pid)"; receipt "$S/tmp/cyfr-t.r3" 1 "$db" cyfr_test_ffffffffffffffffffffffffffffffff_p1
run_dir cyfr-t.r4 "$(live_pid)"; receipt "$S/tmp/cyfr-t.r4" 1 "$db"
run_dir cyfr-t.r5 "$(dead_pid)"; receipt "$S/tmp/cyfr-t.r5" 1 "$db"
run_dir cyfr-t.r7 "$(dead_pid)"; mkdir -p "$S/tmp/cyfr-t.r7/p1"
# One readable receipt beside one that is not: nothing of the run is dropped.
db1=cyfr_test_11111111111111111111111111111111_p1
db2=cyfr_test_11111111111111111111111111111111_p2
run_dir cyfr-t.r8 "$(dead_pid)"; receipt "$S/tmp/cyfr-t.r8" 1 "$db1"; receipt "$S/tmp/cyfr-t.r8" 2 "$db2" mismatched
mkdir -p "$S/tmp/cyfr-stage.nightly.a" "$S/tmp/cyfr-gate.b" "$S/tmp/cyfr-stage.save.c"
age 4 "$S"/tmp/cyfr-t.r1 "$S"/tmp/cyfr-t.r2 "$S"/tmp/cyfr-t.r3 "$S"/tmp/cyfr-t.r4 "$S"/tmp/cyfr-t.r7 "$S"/tmp/cyfr-t.r8
age 1 "$S/tmp/cyfr-t.r5" "$S/tmp/cyfr-stage.save.c"
age 8 "$S/tmp/cyfr-stage.nightly.a" "$S/tmp/cyfr-gate.b"

# Rule 6: uses with dead and live pids.
h6=66666666666666666666
printf '%s\n' "$(dead_pid)" "$user" "$(dead_pid)" >"$STATE/$h6.uses"
touch "$STATE/$h6.lock"

snapshot() {
  (cd "$S" && find docker/images docker/containers docker/networks docker/volumes tmp run -type f -print0 |
    LC_ALL=C sort -z | xargs -0 cksum)
}

begin '--dry-run names what it would remove and removes nothing'
snapshot >"$S/before"
: >"$DOCKER_STUB/calls"
janitor dry --dry-run || fail "the dry run exited $?"
snapshot >"$S/after"
diff "$S/before" "$S/after" >/dev/null || fail "the dry run changed: $(diff "$S/before" "$S/after" | head -5 | tr '\n' ' ')"
if grep -E '^(rm|network rm|volume rm|image rm|image prune|builder|run) ' "$DOCKER_STUB/calls"; then fail 'the dry run called a removal'; fi
has dry "would remove container cyfr-$seed-$d1-compose-proof-cyfr-1"
has dry "would remove image $t0"
has dry "would remove database $db"
has dry "would remove directory $S/tmp/cyfr-t.r1"
has dry "would remove 2 dead uses of $h6"

lock_inode=$(inode "$STATE/$h6.lock")
begin 'rule 1: a finished run, by its record or by no record and no process, loses its objects'
: >"$DOCKER_STUB/calls"
janitor main || fail "the janitor exited $?"
for pid in "$d1" "$d2"; do
  gone "$DOCKER_STUB/containers/cyfr-$seed-$pid-compose-proof-cyfr-1"
  gone "$DOCKER_STUB/networks/cyfr-$seed-$pid-net"
  gone "$DOCKER_STUB/volumes/cyfr-$seed-$pid-pgdata"
  gone "$(image_file "cyfr-$seed-$pid-cyfr-tailscale-standin:run1")"
  has main "removed container cyfr-$seed-$pid-compose-proof-cyfr-1"
  has main "removed network cyfr-$seed-$pid-net"
  has main "removed volume cyfr-$seed-$pid-pgdata"
  has main "removed image cyfr-$seed-$pid-cyfr-tailscale-standin:run1"
  grep -qxF "rm -f -v cyfr-$seed-$pid-compose-proof-cyfr-1" "$DOCKER_STUB/calls" || fail 'a container went without rm -f -v'
done

begin 'rule 1: a run is kept while its pid, its group or its watchdog lives, or its record names no group'
has main "kept container cyfr-$seed-$l1-proof: its pid $l1 is alive"
has main "kept container cyfr-$seed-$d3-proof: a process of its group $group is alive"
has main "kept container cyfr-$seed-$d4-proof: its watchdog $watchdog is alive"
has main "kept container cyfr-$seed-$d5-proof: its holder record names no group"
has main "kept container cyfr-$seed-$l2-proof: its pid $l2 is alive"
for pid in "$l1" "$l2" "$d3" "$d4" "$d5"; do there "$DOCKER_STUB/containers/cyfr-$seed-$pid-proof"; done
for name in other-project-db cyfr-gate-4242-boot-psql; do there "$DOCKER_STUB/containers/$name"; lacks main "$name"; done
lacks main cyfr-gate-4242-boot-net

begin 'rule 2: an old image no worktree produces, no live use names and no container uses goes; each reason alone keeps one'
gone "$(image_file "$t0")"; has main "removed image $t0"
has main "kept image $base: a worktree produces it"
has main "kept image $t2: a live use names it (pid $user)"
has main "kept image $t3: a container uses it"
has main "kept image $t4: it is younger than 24 hours"
for t in "$base" "$t2" "$t3" "$t4" "$t5" cyfr-locus:c2c6; do there "$(image_file "$t")"; done
lacks main "$t5"; lacks main cyfr-locus:c2c6
grep -qxF "image rm $t0" "$DOCKER_STUB/calls" || fail 'the old image went other than by image rm without force'
grep -qxF 'image prune -f --filter label=works.cyfr.image-inputs' "$DOCKER_STUB/calls" || fail 'no labelled dangling prune'

begin 'rule 2: a worktree whose tag cannot be read is named and keeps nothing'
has main "worktree $S/wt3: no tag (65)"
gone "$(image_file "$t6")"; has main "removed image $t6"

begin 'rule 3: build cache unused for seven days is pruned'
grep -qxF 'builder prune -f --filter until=168h' "$DOCKER_STUB/calls" || fail 'no build-cache prune'
has main 'removed build-cache unused for 168h'

begin 'rule 4: an old run directory of a dead runner loses its databases, then itself; one it cannot read is kept'
gone "$S/tmp/cyfr-t.r1"; has main "removed database $db"; has main "removed directory $S/tmp/cyfr-t.r1"
grep -qF "psql -v ON_ERROR_STOP=1 -q postgres://cyfr:s3cret@localhost:5432/postgres -c DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" "$DOCKER_STUB/calls" ||
  fail "the drop call: $(grep '^run ' "$DOCKER_STUB/calls")"
lacks main s3cret
gone "$S/tmp/cyfr-t.r7"; has main "removed directory $S/tmp/cyfr-t.r7"
has main "kept directory $S/tmp/cyfr-t.r2: partition 1's database receipt cannot be read"
has main "kept directory $S/tmp/cyfr-t.r3: partition 1's database receipt cannot be read"
has main "kept directory $S/tmp/cyfr-t.r4: its runner $(cat "$S/tmp/cyfr-t.r4/runner-pid") is alive"
for d in r2 r3 r4 r5; do there "$S/tmp/cyfr-t.$d"; done
lacks main cyfr-t.r5

begin 'rule 4: every receipt is read before the first drop: one unreadable receipt keeps every database'
has main "kept directory $S/tmp/cyfr-t.r8: partition 2's database receipt cannot be read"
there "$S/tmp/cyfr-t.r8/p1/database-created"; there "$S/tmp/cyfr-t.r8/p2/database-created"
if grep -qF "$db1" "$DOCKER_STUB/calls"; then fail "the readable partition's database was dropped: $(grep -F "$db1" "$DOCKER_STUB/calls")"; fi
lacks main "removed database $db1"

begin 'rule 5: log directories older than seven days go'
gone "$S/tmp/cyfr-stage.nightly.a"; gone "$S/tmp/cyfr-gate.b"; there "$S/tmp/cyfr-stage.save.c"
has main "removed directory $S/tmp/cyfr-stage.nightly.a"
has main "removed directory $S/tmp/cyfr-gate.b"

begin 'rule 6: dead uses go under the lock, and no lock file is ever removed'
[ "$(cat "$STATE/$h6.uses")" = "$user" ] || fail "the uses left: $(cat "$STATE/$h6.uses" | tr '\n' ' ')"
has main "removed 2 dead uses of $h6"
[ "$(inode "$STATE/$h6.lock")" = "$lock_inode" ] || fail 'the lock file was replaced'
[ -e "$STATE/${t0##*:in-}.lock" ] || fail "the removed image's lock file went"

begin '--keep-build-cache strikes rule 3'
: >"$DOCKER_STUB/calls"
janitor keep --keep-build-cache || fail "the janitor exited $?"
if grep -q '^builder ' "$DOCKER_STUB/calls"; then fail 'the build cache was pruned'; fi
has keep 'kept build-cache unused for 168h: --keep-build-cache strikes the rule'

begin 'a drop that fails after another succeeded is named as a partial failure'
run_dir cyfr-t.r9 "$(dead_pid)"; receipt "$S/tmp/cyfr-t.r9" 1 "$db1"; receipt "$S/tmp/cyfr-t.r9" 2 "$db2"
age 4 "$S/tmp/cyfr-t.r9"
printf '%s' "$db2" >"$DOCKER_STUB/run-fail"
status=0; janitor partial --keep-build-cache || status=$?
rm "$DOCKER_STUB/run-fail"
[ "$status" = 1 ] || fail "exited $status, not 1"
has partial "removed database $db1"
grep -qF "failed database $db2: stub: the run failed" "$S/partial.out" || fail 'the failed drop is not named'
has partial "failed directory $S/tmp/cyfr-t.r9: kept; it dropped $db1 and left $db2"
gone "$S/tmp/cyfr-t.r9/p1/database-created"; there "$S/tmp/cyfr-t.r9/p2/database-created"

begin 'a dropped database whose receipt cannot be removed is reported as dropped'
db3=cyfr_test_33333333333333333333333333333333_p1
run_dir cyfr-t.r10 "$(dead_pid)"; receipt "$S/tmp/cyfr-t.r10" 1 "$db3"
age 4 "$S/tmp/cyfr-t.r10"
mkdir -p "$S/rm-bin"
cat >"$S/rm-bin/rm" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "$S/tmp/cyfr-t.r10/p1/database-created" ]; then echo 'stub: the receipt could not be removed' >&2; exit 1; fi
done
exec $(command -v rm) "\$@"
EOF
chmod +x "$S/rm-bin/rm"
status=0; PATH="$S/rm-bin:$PATH" janitor receipt --keep-build-cache || status=$?
[ "$status" = 1 ] || fail "exited $status, not 1"
has receipt "removed database $db3"
grep -qF "failed receipt $S/tmp/cyfr-t.r10/p1/database-created: stub: the receipt could not be removed" "$S/receipt.out" ||
  fail 'the receipt that stayed is not named'
has receipt "failed directory $S/tmp/cyfr-t.r10: kept; it dropped $db3, and the receipts of $db3 stay"
there "$S/tmp/cyfr-t.r10/p1/database-created"
janitor receipt-again --keep-build-cache || fail "the next run exited $?"
has receipt-again "removed database $db3"
gone "$S/tmp/cyfr-t.r10"

begin 'a removal that fails exits 1 naming it, and keeps what it names'
receipt "$S/tmp/cyfr-t.r5" 1 "$db"
age 4 "$S/tmp/cyfr-t.r5"
touch "$DOCKER_STUB/run-fail"
plant_image "$t0" "${t0##*:in-}" "$OLD"
touch "$DOCKER_STUB/rm-fail"
status=0; janitor failing || status=$?
rm "$DOCKER_STUB/run-fail" "$DOCKER_STUB/rm-fail"
[ "$status" = 1 ] || fail "exited $status, not 1"
grep -qF "failed database $db: stub: the run failed" "$S/failing.out" || fail 'the failed drop is not named'
grep -qF "failed image $t0: Error response from daemon: stub refuses $t0" "$S/failing.out" || fail 'the failed image removal is not named'
there "$S/tmp/cyfr-t.r5"; there "$S/tmp/cyfr-t.r5/p1/database-created"; there "$(image_file "$t0")"

# The interleavings of a janitor and an image.sh call for one tag, from a
# clone, which no worktree of the repository speaks for.
printf '# clone\n' >>"$S/clone/config/config.exs"
tc=$(cd "$S/clone" && scripts/image.sh --tag-only locus)
hc=${tc##*:in-}

begin 'the janitor first: it removes the old image, and image.sh then builds it again'
rm -f "$(image_file "$t0")"
plant_image "$tc" "$hc" "$OLD"
: >"$DOCKER_STUB/calls"
janitor first || fail "the janitor exited $?"
has first "removed image $tc"
consumer=$(live_pid)
out=$(cd "$S/clone" && scripts/image.sh --for "$consumer" locus 2>"$S/err")
[ "$out" = "$tc" ] && grep -qxF "image: built $tc" "$S/err" || fail "image.sh said $out $(cat "$S/err")"
there "$(image_file "$tc")"

begin 'image.sh first: its use keeps the image from the janitor'
plant_image "$tc" "$hc" "$OLD"
out=$(cd "$S/clone" && scripts/image.sh --for "$consumer" locus 2>"$S/err")
grep -qxF "image: reused $tc" "$S/err" || fail "image.sh said $(cat "$S/err")"
janitor second || fail "the janitor exited $?"
has second "kept image $tc: a live use names it (pid $consumer)"
there "$(image_file "$tc")"

begin 'both waiting on the lock: never removed after image.sh printed its tag'
kill "$consumer"; until_true 10 eval '! ps -p "$consumer" >/dev/null'
plant_image "$tc" "$hc" "$OLD"
lock_inode=$(inode "$STATE/$hc.lock")
: >"$DOCKER_STUB/calls"
( exec 7>>"$STATE/$hc.lock"; flock 7; touch "$S/held"; until_true 60 test -e "$S/release" ) & holder=$!
until_true 10 test -e "$S/held" || fail 'the test could not take the lock'
janitor racing >/dev/null & racing=$!
until_true 60 grep -qF "image inspect -f {{index .Config.Labels \"works.cyfr.image-inputs\"}} $tc" "$DOCKER_STUB/calls" ||
  fail 'the janitor never reached the image'
consumer=$(live_pid)
(cd "$S/clone" && scripts/image.sh --for "$consumer" locus >"$S/racing-image.out" 2>&1) & imaging=$!
sleep 1
ps -p "$racing" >/dev/null || fail 'the janitor did not wait for the lock'
if grep -qxF "image rm $tc" "$DOCKER_STUB/calls"; then fail 'the janitor removed the image under a lock it did not hold'; fi
[ ! -s "$S/racing-image.out" ] || fail "image.sh did not wait for the lock: $(cat "$S/racing-image.out")"
touch "$S/release"; wait "$holder"
wait "$racing" || fail "the janitor exited $?"
wait "$imaging" || fail "image.sh exited $?"
grep -qxF "$tc" "$S/racing-image.out" || fail "image.sh printed: $(cat "$S/racing-image.out")"
there "$(image_file "$tc")"
grep -qxF "$consumer" "$STATE/$hc.uses" || fail 'the use is not recorded'
removal=$(grep -nxF "image rm $tc" "$DOCKER_STUB/calls" | cut -d: -f1 | head -1)
if [ -n "$removal" ]; then
  build=$(grep -n "^build .*--tag $tc -\$" "$DOCKER_STUB/calls" | cut -d: -f1 | tail -1)
  [ -n "$build" ] && [ "$build" -gt "$removal" ] || fail 'the image was removed and image.sh did not build it again'
  echo '    the janitor took the lock first; image.sh built the tag again'
else
  echo "    image.sh took the lock first; the janitor kept the tag"
fi
[ "$(inode "$STATE/$hc.lock")" = "$lock_inode" ] || fail 'the lock file was replaced'

echo 'janitor tests passed'
