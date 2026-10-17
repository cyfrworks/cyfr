#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Regression cases for scripts/ci/seed-guard.sh and scripts/ci/config-seam.sh,
# and for scripts/release.sh's use of the seed guard.
# Each case builds its own scratch git repository and runs the scripts there
# by path, so nothing in this file reimplements their rules.
#
# Usage: bash tests/ci-guards-test.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
seed_guard="$root/scripts/ci/seed-guard.sh"
config_seam="$root/scripts/ci/config-seam.sh"
tmp=${TMPDIR:-/tmp}
scratch=$(mktemp -d "${tmp%/}/cyfr-ci-guards-test.XXXXXX") || {
  echo "FAIL: cannot create a temporary directory"
  exit 1
}
trap 'rm -rf "$scratch"' EXIT

# Neither the host's nor the runner's git configuration reaches the cases:
# no signing, no hooks, no default-branch advice.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=ci-guards GIT_AUTHOR_EMAIL=ci-guards@example.invalid
export GIT_COMMITTER_NAME=ci-guards GIT_COMMITTER_EMAIL=ci-guards@example.invalid

failures=0
cases=0
pass() { cases=$((cases + 1)); echo "PASS: $1"; }
fail() {
  cases=$((cases + 1))
  echo "FAIL: $1"
  echo "  exit: $code"
  sed 's/^/  stdout: /' "$scratch/out"
  sed 's/^/  stderr: /' "$scratch/err"
  failures=$((failures + 1))
}

# A fresh repository for one case; the case runs inside it.
repo_count=0
new_repo() {
  repo_count=$((repo_count + 1))
  repo="$scratch/repo-$repo_count"
  mkdir -p "$repo"
  cd "$repo" || exit 1
  git init -q -b main
  git config commit.gpgsign false
}
commit() { git add -A && git commit -q -m "$1"; }

run() {
  local script=$1
  shift
  bash "$script" "$@" > "$scratch/out" 2> "$scratch/err"
  code=$?
}

has_err() { grep -qF -- "$1" "$scratch/err"; }
quiet() { [ ! -s "$scratch/out" ] && [ ! -s "$scratch/err" ]; }
refused() { [ "$code" -eq 1 ] && has_err "$1" && ! grep -qF -- "$1" "$scratch/out"; }
accepted() { [ "$code" -eq 0 ] && quiet; }
check() { if "$@"; then pass "$label"; else fail "$label"; fi; }

# --- scripts/ci/seed-guard.sh ---

v1=seed/components/catalysts/local/demo/1.0.0
v2=seed/components/catalysts/local/demo/1.0.1

# Two shipped versions of one component, the base of every seed case.
seed_repo() {
  new_repo
  mkdir -p "$v1" "$v2"
  printf 'one\n' > "$v1/a.txt"
  printf 'two\n' > "$v1/b.txt"
  printf 'one\n' > "$v2/a.txt"
  commit base
  base=$(git rev-parse HEAD)
}

label="seed-guard refuses a modified file in an existing version"
seed_repo
printf 'changed\n' > "$v1/a.txt"
commit modify
run "$seed_guard" "$base"
check refused "$v1/a.txt"

label="seed-guard refuses a deleted file whose version directory remains"
seed_repo
git rm -q "$v1/b.txt"
commit delete
run "$seed_guard" "$base"
check refused "$v1/b.txt"

label="seed-guard refuses an added file in an existing version"
seed_repo
printf 'new\n' > "$v1/c.txt"
commit add
run "$seed_guard" "$base"
check refused "$v1/c.txt"

label="seed-guard refuses a file replaced by a symlink in an existing version"
seed_repo
rm "$v1/a.txt"
ln -s b.txt "$v1/a.txt"
commit typechange
run "$seed_guard" "$base"
check refused "$v1/a.txt"

label="seed-guard refuses a symlink replaced by a file in an existing version"
new_repo
mkdir -p "$v1"
printf 'one\n' > "$v1/a.txt"
ln -s a.txt "$v1/link"
commit base
base=$(git rev-parse HEAD)
rm "$v1/link"
printf 'plain\n' > "$v1/link"
commit typechange
run "$seed_guard" "$base"
check refused "$v1/link"

label="seed-guard refuses a deleted file with a non-ASCII name whose version directory remains"
seed_repo
printf 'x\n' > "$v1/caf$(printf '\303\251').txt"
commit "add with a non-ASCII name"
base=$(git rev-parse HEAD)
git rm -q "$v1/caf$(printf '\303\251').txt"
commit delete
run "$seed_guard" "$base"
check refused "$v1/caf$(printf '\303\251').txt"

label="seed-guard refuses an added file with a non-ASCII name in an existing version"
seed_repo
printf 'x\n' > "$v1/caf$(printf '\303\251').txt"
commit "add with a non-ASCII name"
run "$seed_guard" "$base"
check refused "$v1/caf$(printf '\303\251').txt"

# A version directory whose name carries a byte that is not valid UTF-8,
# under a UTF-8 locale as on GitHub's runners. Under C every byte is a
# character and the case would prove nothing, so the locale is checked to
# be in effect first: there a bracket expression does not match the byte.
label="seed-guard refuses a deletion and an addition in a version whose directory name is not valid UTF-8 under C.UTF-8"
new_repo
v8=seed/components/catalysts/local/caf$(printf '\351')/1.0.0
mkdir -p "$v8"
printf 'one\n' > "$v8/a.txt"
printf 'two\n' > "$v8/b.txt"
commit base
base=$(git rev-parse HEAD)
git rm -q "$v8/b.txt"
printf 'new\n' > "$v8/c.txt"
commit "delete and add"
if LC_ALL=C.UTF-8 bash -c '[[ $1 =~ ^[^/]$ ]]' _ "$(printf '\351')"; then
  code=-1
  echo "the C.UTF-8 locale is not in effect on this host" > "$scratch/err"
  : > "$scratch/out"
  fail "$label"
else
  LC_ALL=C.UTF-8 run "$seed_guard" "$base"
  if refused "$v8/b.txt" && has_err "$v8/c.txt"; then pass "$label"; else fail "$label"; fi
fi

label="seed-guard accepts a whole new version directory"
seed_repo
mkdir -p seed/components/catalysts/local/demo/1.0.2
printf 'three\n' > seed/components/catalysts/local/demo/1.0.2/a.txt
commit "new version"
run "$seed_guard" "$base"
check accepted

label="seed-guard accepts a deleted whole version while another stays tracked"
seed_repo
git rm -q -r "$v1"
commit retire
run "$seed_guard" "$base"
check accepted

# With rename detection the move pairs the two versions as a rename and
# reads as a change inside a shipped version.
label="seed-guard accepts retiring a version while shipping a new one with the same content"
seed_repo
git mv "$v1" seed/components/catalysts/local/demo/1.0.2
commit "retire 1.0.0, ship 1.0.2"
run "$seed_guard" "$base"
check accepted

label="seed-guard refuses a deleted file whose version remains when run from a subdirectory"
seed_repo
git rm -q "$v1/b.txt"
commit delete
cd seed || exit 1
run "$seed_guard" "$base"
check refused "$v1/b.txt"

label="seed-guard accepts BASE equal to HEAD with no output"
seed_repo
run "$seed_guard" "$base"
check accepted

label="seed-guard refuses a tree with no tracked seed file"
new_repo
printf 'x\n' > README.md
commit base
run "$seed_guard" HEAD
check refused "seed/components holds no tracked file"

usage_case() {
  if [ "$code" -eq 64 ] && has_err "usage: " && [ ! -s "$scratch/out" ]; then pass "$label"; else fail "$label"; fi
}

label="seed-guard exits 64 with no BASE"
seed_repo
run "$seed_guard"
usage_case

label="seed-guard exits 64 for a BASE that is not a commit"
run "$seed_guard" no-such-revision
usage_case
label="seed-guard exits 64 for a BASE that names a tree"
run "$seed_guard" "$base^{tree}"
usage_case

label="seed-guard exits 64 with an extra argument"
run "$seed_guard" "$base" HEAD
usage_case
label="seed-guard exits 64 with usage only when given -h"
run "$seed_guard" -h
if ! has_err "is not a commit"; then usage_case; else fail "$label"; fi

# --- scripts/ci/config-seam.sh ---

# One source file under apps/, then a commit; the scan reads tracked files.
source_file() {
  mkdir -p "$(dirname "$1")"
  cat > "$1"
}
config_repo() {
  new_repo
  # A key the cases do not touch, so no case meets the vacuity guard by accident.
  source_file apps/other/lib/other.ex << 'EX'
defmodule Other do
  @x Application.compile_env(:cyfr, :unrelated_key, 1)
end
EX
}
runtime_read() {
  source_file apps/demo/lib/runtime.ex << EX
defmodule Runtime do
  def value, do: Application.get_env(:cyfr, :$1)
end
EX
}

label="config-seam accepts a key whose marker is in the comment block directly above its read"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  # config:compile-runtime-ok — the value is bound at compile time and
  # read at runtime only to report it.
  @x Application.compile_env(:cyfr, :demo_key, 1)
end
EX
runtime_read demo_key
commit case
run "$config_seam"
check accepted

label="config-seam refuses a key whose marker block is separated from its read by code"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  # config:compile-runtime-ok — misplaced.
  @y 2
  @x Application.compile_env(:cyfr, :demo_key, 1)
end
EX
runtime_read demo_key
commit case
run "$config_seam"
if refused "apps/demo/lib/demo.ex:4" && has_err ":demo_key" && has_err "apps/demo/lib/runtime.ex:2"; then pass "$label"; else fail "$label"; fi

label="config-seam refuses a key whose marker sits on an unrelated line of the same file"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  @x Application.compile_env(:cyfr, :demo_key, 1)

  def f, do: :ok # config:compile-runtime-ok
end
EX
runtime_read demo_key
commit case
run "$config_seam"
check refused "apps/demo/lib/demo.ex:2"

label="config-seam accepts a runtime read of a key with no compile-time read"
config_repo
runtime_read runtime_only
commit case
run "$config_seam"
check accepted

label="config-seam accepts a marker on the read's own line"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  @x Application.compile_env(:cyfr, :demo_key, 1) # config:compile-runtime-ok — on purpose
end
EX
runtime_read demo_key
commit case
run "$config_seam"
check accepted

label="config-seam refuses the unmarked one of two reads of a key in one file"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  # config:compile-runtime-ok — on purpose
  @x Application.compile_env(:cyfr, :demo_key, 1)

  @y Application.compile_env(:cyfr, :demo_key, 1)
end
EX
runtime_read demo_key
commit case
run "$config_seam"
if refused "apps/demo/lib/demo.ex:5" && ! has_err "apps/demo/lib/demo.ex:3"; then pass "$label"; else fail "$label"; fi

label="config-seam refuses a read separated from its marker block by a blank line"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  # config:compile-runtime-ok — on purpose

  @x Application.compile_env(:cyfr, :demo_key, 1)
end
EX
runtime_read demo_key
commit case
run "$config_seam"
check refused "apps/demo/lib/demo.ex:4"

label="config-seam exempts only the first of two consecutive reads under one marker block"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  # config:compile-runtime-ok — on purpose
  @x Application.compile_env(:cyfr, :demo_key, 1)
  @y Application.compile_env(:cyfr, :demo_key, 2)
end
EX
runtime_read demo_key
commit case
run "$config_seam"
if refused "apps/demo/lib/demo.ex:4" && ! has_err "apps/demo/lib/demo.ex:3"; then pass "$label"; else fail "$label"; fi

label="config-seam accepts a marker on the first line of a longer comment block"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  use Something,
    # config:compile-runtime-ok — the adapter is bound at compile time;
    # the runtime read reports which one.
    #
    adapter: Application.compile_env(:cyfr, :demo_key, 1)
end
EX
runtime_read demo_key
commit case
run "$config_seam"
check accepted

label="config-seam keeps keys apart at a name boundary"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  @x Application.compile_env(:cyfr, :foo, 1)
end
EX
runtime_read foo_bar
commit case
run "$config_seam"
check accepted

label="config-seam refuses from a subdirectory as from the root"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  @x Application.compile_env(:cyfr, :demo_key, 1)
end
EX
runtime_read demo_key
commit case
cd apps/demo || exit 1
run "$config_seam"
check refused "apps/demo/lib/demo.ex:2"

label="config-seam refuses a tree with no compile_env read"
new_repo
runtime_read runtime_only
commit case
run "$config_seam"
check refused "no compile_env reads matched"

label="config-seam leaves no temporary file after a passing and a failing run"
config_repo
source_file apps/demo/lib/demo.ex << 'EX'
defmodule Demo do
  @x Application.compile_env(:cyfr, :demo_key, 1)
end
EX
commit case
mkdir "$scratch/tmpdir"
TMPDIR="$scratch/tmpdir" bash "$config_seam" > "$scratch/out" 2> "$scratch/err"
code=$?
passed=$code
runtime_read demo_key
commit runtime
TMPDIR="$scratch/tmpdir" bash "$config_seam" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$passed" -eq 0 ] && [ "$code" -eq 1 ] && [ -z "$(ls -A "$scratch/tmpdir")" ]; then pass "$label"; else fail "$label"; fi

label="config-seam exits 64 when given an argument"
run "$config_seam" extra
usage_case
label="config-seam exits 64 when given -h"
run "$config_seam" -h
usage_case

label="seed-guard leaves no temporary file after a passing and a failing run"
seed_repo
rm -rf "$scratch/tmpdir"
mkdir "$scratch/tmpdir"
TMPDIR="$scratch/tmpdir" bash "$seed_guard" "$base" > "$scratch/out" 2> "$scratch/err"
passed=$?
printf 'changed\n' > "$v1/a.txt"
commit modify
TMPDIR="$scratch/tmpdir" bash "$seed_guard" "$base" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$passed" -eq 0 ] && [ "$code" -eq 1 ] && [ -z "$(ls -A "$scratch/tmpdir")" ]; then pass "$label"; else fail "$label"; fi

# --- scripts/release.sh runs the seed guard against the last tag ---

# A seed repository whose base is tagged as a release, holding release.sh
# and the seed guard as the repository does, so release.sh runs the guard
# at its own path.
release_repo() {
  seed_repo
  mkdir -p scripts/ci
  cp "$root/scripts/release.sh" scripts/release.sh
  cp "$seed_guard" scripts/ci/seed-guard.sh
  commit "release scripts"
  git tag 0.1.0
}

label="release.sh refuses a file replaced by a symlink in a version the last tag shipped"
release_repo
rm "$v1/a.txt"
ln -s b.txt "$v1/a.txt"
commit typechange
run scripts/release.sh 0.1.1
if [ "$code" -eq 1 ] && has_err "$v1/a.txt" && grep -qF "shipped by 0.1.0" "$scratch/out" && ! git rev-parse --verify --quiet 0.1.1 > /dev/null; then pass "$label"; else fail "$label"; fi

label="release.sh refuses a modified file in a version the last tag shipped"
release_repo
printf 'changed\n' > "$v1/a.txt"
commit modify
run scripts/release.sh 0.1.1
if [ "$code" -eq 1 ] && has_err "$v1/a.txt" && ! git rev-parse --verify --quiet 0.1.1 > /dev/null; then pass "$label"; else fail "$label"; fi

cd "$root" || exit 1
echo "$((cases - failures)) of $cases cases passed"
[ "$failures" -eq 0 ]
