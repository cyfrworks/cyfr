#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The PostgreSQL databases tests/release-boot/boot.sh creates beside the one
# CYFR_DATABASE_URL names, against a `docker` that records each PostgreSQL
# command instead of running it: two runs sharing one URL derive names of
# their own, within PostgreSQL's 63-byte identifier limit, and each run's
# cleanup drops only the databases it created. No database or image is
# needed.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
boot="$root/tests/release-boot/boot.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-boot-names-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Records each command's SQL, one line per `-c`, in DOCKER_LOG; a CREATE
# fails while DOCKER_REFUSE_CREATE=1, as it does for a name that exists.
mkdir "$scratch/bin"
cat > "$scratch/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
refuse=0
while [ "$#" -gt 0 ]; do
  if [ "$1" = -c ]; then
    echo "$2" >> "$DOCKER_LOG"
    case "$2" in "CREATE DATABASE"*) [ "${DOCKER_REFUSE_CREATE:-}" != 1 ] || refuse=1 ;; esac
    shift
  fi
  shift
done
exit "$refuse"
DOCKER
chmod +x "$scratch/bin/docker"

# One run of boot.sh's restores case, as far as its databases go: it derives
# and creates its cell and restore databases and prints their names, and
# its exit drops what it created, as boot.sh's cleanup does. `$1` names the
# run's log.
run() {
  DOCKER_LOG="$scratch/$1.log" PATH="$scratch/bin:$PATH" bash -c '
    set -euo pipefail
    fail() { echo "boot.sh failed: $*" >&2; exit 1; }
    source "$1"
    trap pg_drop_created EXIT
    cell=$(pg_run_database cell); restore=$(pg_run_database restore)
    echo "$cell"; echo "$restore"
    pg_fresh_database "$cell"
    pg_fresh_database "$restore"' run "$boot"
}

# --- two runs on one URL --------------------------------------------------
export CYFR_DATABASE_URL="postgres://cyfr:cyfr@localhost:5432/cyfr_release_boot?sslmode=disable"
run a > "$scratch/a.names"; mapfile -t a < "$scratch/a.names"
run b > "$scratch/b.names"; mapfile -t b < "$scratch/b.names"
[ "${#a[@]}" = 2 ] && [ "${#b[@]}" = 2 ] || fail "a run did not name two databases: ${a[*]} / ${b[*]}"
for name in "${a[@]}" "${b[@]}"; do
  [[ "$name" =~ ^cyfr_release_boot_[0-9]+_[0-9a-f]{8}_(cell|restore)$ ]] || fail "unexpected name $name"
done
[ "$(printf '%s\n' "${a[@]}" "${b[@]}" | sort -u | wc -l)" = 4 ] ||
  fail "two runs on one URL derived a shared name: ${a[*]} / ${b[*]}"

# Each run creates its own two, drops exactly those, and drops nothing first.
for r in a b; do
  declare -n names=$r
  expected=$(printf '%s\n' \
    "CREATE DATABASE \"${names[0]}\"" "CREATE DATABASE \"${names[1]}\"" \
    "DROP DATABASE IF EXISTS \"${names[0]}\" WITH (FORCE)" "DROP DATABASE IF EXISTS \"${names[1]}\" WITH (FORCE)")
  [ "$(cat "$scratch/$r.log")" = "$expected" ] ||
    fail "run $r issued other statements than its own creates and drops: $(cat "$scratch/$r.log")"
  unset -n names
done
echo "ok: two runs on one URL derive disjoint names and drop only their own: ${a[*]} / ${b[*]}"

# --- a name it could not create is not the run's to drop ------------------
: > "$scratch/c.log"
DOCKER_REFUSE_CREATE=1 run c > /dev/null 2>&1 && fail "a refused CREATE did not fail the run"
grep -q '^DROP' "$scratch/c.log" && fail "a run dropped a database it did not create: $(cat "$scratch/c.log")"
echo "ok: a database the run could not create is never dropped"

# --- a long database name -------------------------------------------------
long=$(printf 'd%.0s' {1..70})
export CYFR_DATABASE_URL="postgres://cyfr:cyfr@localhost:5432/$long"
run long > "$scratch/long.names"; mapfile -t l < "$scratch/long.names"
for name in "${l[@]}"; do
  [ "$(printf '%s' "$name" | wc -c)" -le 63 ] || fail "$name is longer than 63 bytes"
  [[ "$name" =~ ^d+_[0-9]+_[0-9a-f]{8}_(cell|restore)$ ]] || fail "unexpected name $name"
done
[ "${l[0]}" != "${l[1]}" ] || fail "the long base's cell and restore names are one"
echo "ok: a 70-byte database name gives names within 63 bytes: ${l[*]}"
