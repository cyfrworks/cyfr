#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Regression cases for scripts/ci/seed-guard.sh, scripts/ci/config-seam.sh,
# scripts/ci/retry.sh, scripts/ci/world-checks.sh,
# scripts/ci/self-test-scope.sh, scripts/ci/storage-diagrams.py,
# scripts/ci/main-run.py and scripts/ci/reds.py (the last two against a
# stand-in gh, the last with the workflow that runs it),
# scripts/ci/release-binary-check.sh (against real builds of the command
# line, so it needs go and the module's dependencies), and for
# scripts/release.sh's use of the seed guard.
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

# --- scripts/ci/storage-diagrams.py ---

# A layout source as Arca.Storage spells it: two tenant rows, a reserved
# one and a global one, with a comment row between them.
diagram_layout() {
  cat > "$1" <<'EX'
defmodule Arca.Storage do
  @layout [
    {"aqua", :tenant, nil, :overlay, :shaped},
    # A comment row {"ghost", :tenant, nil, nil, :read},
    {"payloads", :tenant_reserved, nil, nil, :system},
    {"data", :tenant, "data", nil, :open},
    {"cache", :global, nil, nil, :system}
  ]

  @tenant_roots for {root, class, _guest, _seed, _tier} <- @layout,
                    class in [:tenant, :tenant_reserved],
                    do: root
end
EX
}
# A guide drawing an athanor's tree both ways the guides do: a placeholder
# under `athanors/`, and `athanors/<placeholder>/` on one line. Each
# names its extra lines after the tree's roots.
diagram_guide() {
  local extra=$1
  {
    printf '# Guide\n\n```\nproject/\n└── data/\n    ├── cache/\n    └── athanors/\n        └── <athanor id>/\n'
    printf '            ├── aqua/       # soul\n            │   └── roles/  # nested, not a root\n'
    printf '%b' "$extra"
    printf '            ├── payloads/\n            └── data/\n```\n\n```\n└── data/\n    └── athanors/{athanor_id}/\n'
    printf '        ├── aqua/\n        └── data/\n```\n'
  } > guide.md
}
storage_diagrams="$root/scripts/ci/storage-diagrams.py"
run_diagrams() {
  python3 -I "$storage_diagrams" "$@" > "$scratch/out" 2> "$scratch/err"
  code=$?
}
out_has() { grep -qF -- "$1" "$scratch/out"; }

label="storage-diagrams reads the tenant roots from the layout's tenant and reserved rows"
new_repo
diagram_layout storage.ex
run_diagrams --layout storage.ex --roster
if [ "$code" -eq 0 ] && [ "$(tr '\n' ' ' < "$scratch/out")" = 'aqua payloads data ' ]; then pass "$label"; else fail "$label"; fi

label="storage-diagrams reads Arca.Storage's own roster"
cd "$root" || exit 1
run_diagrams --roster
if [ "$code" -eq 0 ] && grep -qx data "$scratch/out" && grep -qx components "$scratch/out" && ! grep -qx cache "$scratch/out"; then pass "$label"; else fail "$label"; fi

label="storage-diagrams passes the guides"
run_diagrams README.md component-guide.md configuration-guide.md integration-guide.md tincture-guide.md identity-guide.md devices-guide.md
if [ "$code" -eq 0 ]; then pass "$label"; else fail "$label"; fi

label="storage-diagrams passes a tree of tenant roots, with anything nested under them"
new_repo
diagram_layout storage.ex
diagram_guide ''
run_diagrams --layout storage.ex guide.md
check accepted

label="storage-diagrams refuses a directory under an athanor's tree that is no tenant root"
diagram_guide '            ├── builds/     # planted\n'
run_diagrams --layout storage.ex guide.md
if [ "$code" -eq 1 ] && out_has 'name a scope that is not a tenant root' && out_has 'guide.md:11:            ├── builds/'; then pass "$label"; else fail "$label"; fi

label="storage-diagrams refuses a global root under an athanor's tree"
diagram_guide '            ├── cache/\n'
run_diagrams --layout storage.ex guide.md
if [ "$code" -eq 1 ] && out_has 'guide.md:11:            ├── cache/'; then pass "$label"; else fail "$label"; fi

label="storage-diagrams refuses a file under an athanor's tree"
diagram_guide '            ├── data\n'
run_diagrams --layout storage.ex guide.md
if [ "$code" -eq 1 ] && out_has 'guide.md:11:            ├── data'; then pass "$label"; else fail "$label"; fi

label="storage-diagrams refuses a phantom in the one-line athanors/<id>/ form"
sed -i 's|^        └── data/$|        ├── builds/\n        └── data/|' guide.md
diagram_guide_line=$(grep -n '^        ├── builds/$' guide.md | cut -d: -f1)
run_diagrams --layout storage.ex guide.md
if [ "$code" -eq 1 ] && out_has "guide.md:$diagram_guide_line:        ├── builds/"; then pass "$label"; else fail "$label"; fi

label="storage-diagrams refuses guides that draw no athanor's tree"
printf '```\nproject/\n└── data/\n    └── cache/\n```\n' > plain.md
run_diagrams --layout storage.ex plain.md
if [ "$code" -eq 1 ] && out_has 'the check would check nothing'; then pass "$label"; else fail "$label"; fi

label="storage-diagrams refuses a layout source it cannot read the roster from"
diagram_guide ''
sed 's/class in \[:tenant, :tenant_reserved\],/class != :global,/' storage.ex > other.ex
run_diagrams --layout other.ex guide.md
if [ "$code" -eq 1 ] && out_has 'no @layout table or no @tenant_roots comprehension'; then pass "$label"; else fail "$label"; fi

label="storage-diagrams exits 64 without a guide"
run_diagrams --layout storage.ex
if [ "$code" -eq 64 ] && [ ! -s "$scratch/out" ]; then pass "$label"; else fail "$label"; fi

# --- world-checks ---

world_checks="$root/scripts/ci/world-checks.sh"

# A merge commit of a branch that writes $1 onto a base, as a pull request's
# run checks out.
merge_repo() {
  new_repo
  printf 'x\n' > base.txt
  commit base
  git checkout -q -b change
  mkdir -p "$(dirname "$1")"
  printf 'x\n' > "$1"
  commit change
  git checkout -q main
  printf 'y\n' > moved.txt
  commit moved
  git merge -q --no-ff -m merge change
}
run_world() {
  : > "$scratch/output"
  env "$@" GITHUB_OUTPUT="$scratch/output" bash "$world_checks" > "$scratch/out" 2> "$scratch/err"
  code=$?
}

for changed in src/app.ex README.md mix.lock.bak apps/codex/go.sum; do
  label="world-checks: a pull request that changes $changed is informational"
  merge_repo "$changed"
  run_world GITHUB_EVENT_NAME=pull_request
  if [ "$code" -eq 0 ] && [ "$(cat "$scratch/output")" = informational=true ]; then pass "$label"; else fail "$label"; fi
done

for changed in mix.lock package-lock.json apps/x/assets/package-lock.json Dockerfile Dockerfile.locus \
  tests/y/Dockerfile docker-compose.yml docker-compose.dev.yml apps/locus/keeper/go.sum rust-toolchain.toml; do
  label="world-checks: a pull request that changes $changed blocks"
  merge_repo "$changed"
  run_world GITHUB_EVENT_NAME=pull_request
  if [ "$code" -eq 0 ] && [ ! -s "$scratch/output" ]; then pass "$label"; else fail "$label"; fi
done

for event in push schedule workflow_dispatch; do
  label="world-checks: a $event blocks"
  merge_repo src/app.ex
  run_world GITHUB_EVENT_NAME=$event
  if [ "$code" -eq 0 ] && [ ! -s "$scratch/output" ]; then pass "$label"; else fail "$label"; fi
done

label="world-checks: no event, as in the commit gate, blocks"
merge_repo src/app.ex
run_world -u GITHUB_EVENT_NAME
if [ "$code" -eq 0 ] && [ ! -s "$scratch/output" ]; then pass "$label"; else fail "$label"; fi

label="world-checks: a checkout with no parent to compare blocks"
new_repo
printf 'x\n' > base.txt
commit base
run_world GITHUB_EVENT_NAME=pull_request
if [ "$code" -eq 0 ] && [ ! -s "$scratch/output" ]; then pass "$label"; else fail "$label"; fi

label="world-checks: an argument is refused"
merge_repo src/app.ex
rm -f "$scratch/output"
GITHUB_EVENT_NAME=pull_request GITHUB_OUTPUT="$scratch/output" bash "$world_checks" x > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 64 ] && [ ! -e "$scratch/output" ]; then pass "$label"; else fail "$label"; fi

# --- self-test-scope ---

self_test_scope="$root/scripts/ci/self-test-scope.sh"

# A merge commit of a branch onto a base that moved, as a pull request's
# run checks out: the branch writes each path given, or removes it given
# as -PATH; the base writes moved.txt and each path given after --. The
# branch's tip is $head_sha.
scope_repo() {
  local p side=change
  new_repo
  mkdir -p scripts/lib tests
  printf 'x\n' > scripts/lib/contain.sh
  printf 'x\n' > tests/contain-test.sh
  printf 'x\n' > base.txt
  commit base
  git checkout -q -b change
  for p in "$@"; do
    if [ "$p" = -- ]; then
      commit change
      git checkout -q main
      printf 'y\n' > moved.txt
      side=main
      continue
    fi
    case $p in
      -*) git rm -q "${p#-}" ;;
      *) mkdir -p "$(dirname "$p")" && printf '%s\n' "$side" >> "$p" ;;
    esac
  done
  if [ "$side" = change ]; then
    commit change
    git checkout -q main
    printf 'y\n' > moved.txt
  fi
  commit moved
  git merge -q --no-ff -m merge change
  head_sha=$(git rev-parse change)
}
run_scope() {
  : > "$scratch/output"
  env "$@" GITHUB_OUTPUT="$scratch/output" bash "$self_test_scope" > "$scratch/out" 2> "$scratch/err"
  code=$?
}
# The jobs skipped, as the output names them, on one line.
skipped() { [ "$code" -eq 0 ] && [ "$(paste -sd ' ' "$scratch/output")" = "$1" ]; }
pr() { run_scope GITHUB_EVENT_NAME=pull_request PR_HEAD_SHA="$head_sha"; }

# Each case: the paths a pull request changes, then the jobs it skips.
while IFS='|' read -r changed want; do
  label="self-test-scope: a pull request that changes $changed skips '$want'"
  # shellcheck disable=SC2086 # each word is one path
  scope_repo $changed
  pr
  if skipped "$want"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
src/app.ex README.md apps/arca/lib/arca.ex apps/cyfr/assets/js/app.js|host=false partitions=false gate=false
apps/codex/go.mod seed/components/x/1.0.0/a.txt apps/arca/test/stored_test.exs|host=false partitions=false gate=false
scripts/lib/contain.sh|
-scripts/lib/contain.sh|
.github/workflows/test.yml|
scripts/ci/self-test-scope.sh|
tests/contain-test.sh|partitions=false gate=false
-tests/contain-test.sh|partitions=false gate=false
tests/load-check/run.sh|partitions=false gate=false
scripts/stages.tsv|partitions=false gate=false
scripts/heavy-check.sh|partitions=false gate=false
.github/workflows/release.yml|partitions=false
.github/workflows/codex-ci.yml|partitions=false
scripts/commit-gate.sh|partitions=false
config/test.exs|host=false gate=false
config/database_choice.exs|host=false gate=false
scripts/test-partition-weights.tsv|host=false gate=false
.github/actions/setup-elixir/action.yml|host=false gate=false
tests/commit-gate-test.sh|host=false partitions=false
CASES

label="self-test-scope: what the base changed since the branch left it is not the pull request's"
scope_repo README.md -- scripts/lib/contain.sh .github/workflows/test.yml scripts/commit-gate.sh
pr
if skipped 'host=false partitions=false gate=false'; then pass "$label"; else fail "$label"; fi

label="self-test-scope: each job skipped is named not needed"
scope_repo README.md
pr
if [ "$(grep -c '^harness-tests-[a-z]*: not needed, ' "$scratch/out")" = 3 ] && [ ! -s "$scratch/err" ]; then pass "$label"; else fail "$label"; fi

for event in push schedule workflow_dispatch; do
  label="self-test-scope: a $event runs every job"
  scope_repo README.md
  run_scope GITHUB_EVENT_NAME=$event PR_HEAD_SHA="$head_sha"
  if skipped ''; then pass "$label"; else fail "$label"; fi
done

label="self-test-scope: no event, as on a host, runs every job"
scope_repo README.md
run_scope -u GITHUB_EVENT_NAME PR_HEAD_SHA="$head_sha"
if skipped ''; then pass "$label"; else fail "$label"; fi

label="self-test-scope: a pull request with no head named runs every job"
scope_repo README.md
run_scope -u PR_HEAD_SHA GITHUB_EVENT_NAME=pull_request
if skipped ''; then pass "$label"; else fail "$label"; fi

label="self-test-scope: a merge whose second parent is not the head runs every job"
scope_repo README.md
run_scope GITHUB_EVENT_NAME=pull_request PR_HEAD_SHA="$(git rev-parse HEAD^1)"
if skipped ''; then pass "$label"; else fail "$label"; fi

label="self-test-scope: a checkout of the head itself, no merge, runs every job"
scope_repo README.md
git checkout -q change
run_scope GITHUB_EVENT_NAME=pull_request PR_HEAD_SHA="$head_sha"
if skipped ''; then pass "$label"; else fail "$label"; fi

label="self-test-scope: a checkout without the merge's parents runs every job"
scope_repo README.md
git clone -q --depth 1 "file://$repo" "$repo.shallow"
cd "$repo.shallow" || exit 1
run_scope GITHUB_EVENT_NAME=pull_request PR_HEAD_SHA="$head_sha"
if skipped ''; then pass "$label"; else fail "$label"; fi

label="self-test-scope: a diff that cannot be read runs every job"
scope_repo README.md
mkdir -p "$scratch/broken-git"
real_git=$(command -v git)
printf '#!/bin/sh\n[ "$1" != diff ] || exit 128\nexec "%s" "$@"\n' "$real_git" > "$scratch/broken-git/git"
chmod +x "$scratch/broken-git/git"
run_scope PATH="$scratch/broken-git:$PATH" GITHUB_EVENT_NAME=pull_request PR_HEAD_SHA="$head_sha"
if skipped ''; then pass "$label"; else fail "$label"; fi

label="self-test-scope: an argument is refused"
scope_repo README.md
rm -f "$scratch/output"
GITHUB_EVENT_NAME=pull_request PR_HEAD_SHA="$head_sha" GITHUB_OUTPUT="$scratch/output" bash "$self_test_scope" x > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 64 ] && [ ! -e "$scratch/output" ]; then pass "$label"; else fail "$label"; fi

# GitHub keeps a failed job's outputs, so a run that fails after deciding
# must leave none: here its log cannot be written.
label="self-test-scope: a run that fails before its outputs leaves none"
scope_repo README.md
: > "$scratch/output"
GITHUB_EVENT_NAME=pull_request PR_HEAD_SHA="$head_sha" GITHUB_OUTPUT="$scratch/output" bash "$self_test_scope" > /dev/full 2> "$scratch/err"
code=$?
: > "$scratch/out"
if [ "$code" -ne 0 ] && [ ! -s "$scratch/output" ]; then pass "$label"; else fail "$label"; fi

# Each scoped job's `if:` in test.yml, evaluated for each result and
# output the scope job can give it: skipped only when the scope job
# succeeded and answered false, and never in a cancelled run.
scope_conditions() {
  python3 -I - "$root/.github/workflows/test.yml" <<'PY'
import re, sys

lines = open(sys.argv[1]).read().split("\n")
def condition(job):
    start = lines.index(f"  {job}:")
    for line in lines[start + 1:]:
        if re.match(r"  \S", line):
            break
        m = re.fullmatch(r"    if: (.*)", line)
        if m:
            return m[1]
    return None

TOKEN = re.compile(r"\s+|\$\{\{|\}\}|\(|\)|&&|\|\||!=|==|!|'[^']*'|[a-z][\w.-]*\(\)|needs\.self-test-scope\.(?:result|outputs\.[a-z]+)")
def evaluate(expression, job, cancelled, result, output):
    out, i = [], 0
    while i < len(expression):
        m = TOKEN.match(expression, i)
        if not m:
            raise SystemExit(f"{job}: cannot read its if: at {expression[i:]!r}")
        t, i = m[0], m.end()
        if t.isspace() or t in ("${{", "}}"):
            continue
        out.append({
            "(": "(", ")": ")", "&&": " and ", "||": " or ", "!=": "!=", "==": "==", "!": " not ",
            "cancelled()": repr(cancelled), "always()": "True",
            "success()": repr(not cancelled and result == "success"),
            "failure()": repr(not cancelled and result == "failure"),
            "needs.self-test-scope.result": repr(result),
            f"needs.self-test-scope.outputs.{job.removeprefix('harness-tests-')}": repr(output),
        }.get(t, t if t.startswith("'") else None) or sys.exit(f"{job}: its if: names {t}, which this check does not read"))
    return eval("".join(out), {"__builtins__": {}})

for job in ("harness-tests-host", "harness-tests-partitions", "harness-tests-gate"):
    expression = condition(job)
    if expression is None:
        print(f"{job}: no if:")
        continue
    for cancelled, result, output, want in [
        (False, "success", "false", False), (False, "success", "", True), (False, "success", "true", True),
        (False, "failure", "false", True), (False, "failure", "", True), (False, "cancelled", "false", True),
        (False, "skipped", "", True), (True, "success", "", False), (True, "failure", "false", False),
    ]:
        if evaluate(expression, job, cancelled, result, output) != want:
            state = "a cancelled run, " if cancelled else ""
            print(f"{job}: {state}scope {result} with output {output!r} {'runs' if not want else 'skips'} it")
PY
}
label="self-test-scope: test.yml skips a scoped job only after a scope job that succeeded and answered false"
scope_conditions > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi

# --- retry ---

retry="$root/scripts/ci/retry.sh"
# Its gaps are recorded in $scratch/slept and not waited.
mkdir -p "$scratch/retry-bin"
printf '#!/bin/sh\necho "$1" >> "%s/slept"\n' "$scratch" > "$scratch/retry-bin/sleep"
chmod +x "$scratch/retry-bin/sleep"
run_retry() { PATH="$scratch/retry-bin:$PATH" run "$retry" "$@"; }
# A command that fails until it has been run $2 times, counting in $1.
flaky="c=\$(cat \"\$1\" 2>/dev/null || echo 0); echo \$((c + 1)) > \"\$1\"; [ \"\$c\" -ge \"\$2\" ]"

for passes_on in 1 2 3; do
  label="retry: a fetch that passes on attempt $passes_on ends 0 after $passes_on"
  rm -f "$scratch/count"
  run_retry bash -c "$flaky" - "$scratch/count" "$((passes_on - 1))"
  if [ "$code" -eq 0 ] && [ "$(cat "$scratch/count")" = "$passes_on" ]; then pass "$label"; else fail "$label"; fi
done

label="retry: a fetch that never passes ends with its own status after three, 30 s apart"
rm -f "$scratch/count" "$scratch/slept"
run_retry bash -c 'echo x >> "$1"; exit 7' - "$scratch/count"
if [ "$code" -eq 7 ] && [ "$(wc -l < "$scratch/count")" -eq 3 ] && [ "$(tr '\n' ' ' < "$scratch/slept")" = '30 30 ' ]; then pass "$label"; else fail "$label"; fi

label="retry: no command is refused"
run_retry
if [ "$code" -eq 64 ]; then pass "$label"; else fail "$label"; fi

# --- scripts/ci/main-run.py ---

main_run="$root/scripts/ci/main-run.py"
# The stand-in gh answers from $GH_STATE, a JSON list of push runs on main.
# `api --paginate URL` lists, two to a page as gh prints pages, the runs of
# the URL's head_sha, or without one every run created at or after its
# `created` bound; each page states the total, which GH_SHORT makes one
# more than it lists, as a capped or broken listing does. A POST to
# runs/ID/rerun-failed-jobs or runs/ID/rerun takes the run to its next
# attempt, queued; under GH_STALE the listing keeps the attempt it had and
# a second POST for the run is refused, as for a run already rerunning.
# Every call is a line of $GH_CALLS; under GH_FAIL every call fails, under
# GH_FAIL_POST every POST.
mkdir -p "$scratch/gh-bin"
cat > "$scratch/gh-bin/gh" <<'GH'
#!/usr/bin/env python3
import json, os, re, sys, urllib.parse
args = sys.argv[1:]
with open(os.environ["GH_CALLS"], "a") as f:
    f.write(" ".join(args) + "\n")
if os.environ.get("GH_FAIL") or args[:1] != ["api"]:
    sys.exit("gh: stand-in refused")
state = os.environ["GH_STATE"]
runs = json.load(open(state))
if args[1:3] == ["-X", "POST"]:
    m = re.fullmatch(r"repos/\{owner\}/\{repo\}/actions/runs/(\d+)/(rerun-failed-jobs|rerun)", args[3])
    run = next((r for r in runs if m and str(r["id"]) == m[1]), None)
    posted = state + ".posted"
    seen = open(posted).read().split() if os.path.exists(posted) else []
    if os.environ.get("GH_FAIL_POST") or run is None or m[1] in seen:
        sys.exit("gh: HTTP 403")
    open(posted, "a").write(m[1] + "\n")
    if not os.environ.get("GH_STALE"):
        run.update(run_attempt=run["run_attempt"] + 1, status="queued", conclusion=None)
        json.dump(runs, open(state, "w"))
    sys.exit(0)
path, _, query = args[-1].partition("?")
q = dict(urllib.parse.parse_qsl(query))
if args[1] != "--paginate" or path != "repos/{owner}/{repo}/actions/runs" or (q.get("branch"), q.get("event")) != ("main", "push"):
    sys.exit(f"gh: stand-in does not answer {args}")
if "head_sha" in q:
    runs = [r for r in runs if r["head_sha"] == q["head_sha"]]
else:
    runs = [r for r in runs if r["created_at"] >= q["created"].removeprefix(">=")]
total = len(runs) + (1 if os.environ.get("GH_SHORT") else 0)
for i in range(0, max(len(runs), 1), 2):
    print(json.dumps({"total_count": total, "workflow_runs": runs[i:i + 2]}))
GH
chmod +x "$scratch/gh-bin/gh"

# Main: B, then C, D and E, a minute apart from 12:00 UTC, with X on a
# branch. B's workflow files would mislead a reader of them (Wild runs on
# every branch's push, Codex only under apps/codex): the script reads runs
# alone.
main_run_repo() {
  local c n=0
  new_repo
  mkdir -p .github/workflows
  printf "name: Wild\non:\n  push:\n    branches: ['**']\njobs: {}\n" > .github/workflows/wild.yml
  printf "name: Codex\non:\n  push:\n    branches: [main]\n    paths: ['apps/codex/**']\njobs: {}\n" > .github/workflows/codex.yml
  printf "name: Test\non:\n  push:\n    branches: [main]\njobs: {}\n" > .github/workflows/test.yml
  for c in B C D E; do
    printf '%s\n' "$c" > "$c.txt"
    GIT_COMMITTER_DATE="2026-01-01T12:0${n}:00Z" GIT_AUTHOR_DATE="2026-01-01T12:0${n}:00Z" commit "$c"
    eval "$c=\$(git rev-parse HEAD)"; n=$((n + 1))
  done
  git checkout -q -b side "$C"; printf 'x\n' > x.txt; commit X; X=$(git rev-parse HEAD); git checkout -q main
  git init -q --bare "$repo.origin"
  git remote add origin "$repo.origin"
  git push -q origin main
  git fetch -q origin
  rm -f "$scratch/gh-state.posted"
}
# runs 'WORKFLOW COMMIT STATUS CONCLUSION ATTEMPT [CREATED]'...: the
# stand-in's runs, numbered from 101 in order, COMMIT one of B C D E X,
# each named after its workflow and made at 13:00 UTC unless CREATED says.
runs() {
  : > "$scratch/gh-calls"
  python3 -I - "$scratch/gh-state" "$B" "$C" "$D" "$E" "$X" "$@" <<'PY'
import json, sys
state, shas, specs = sys.argv[1], dict(zip("BCDEX", sys.argv[2:7])), sys.argv[7:]
runs = []
for i, spec in enumerate(specs):
    wf, c, status, conclusion, attempt, *created = spec.split()
    runs.append({"id": 101 + i, "name": wf.removesuffix(".yml").capitalize(), "path": f".github/workflows/{wf}",
                 "head_sha": shas[c], "status": status, "conclusion": None if conclusion == "-" else conclusion,
                 "run_attempt": int(attempt), "created_at": (created or ["2026-01-01T13:00:00Z"])[0],
                 "html_url": f"https://example.invalid/runs/{101 + i}"})
json.dump(runs, open(state, "w"))
PY
}
# main_run_at COMMIT [ARGS...]: reads with COMMIT given, MAIN_RUN_ENV set.
main_run_at() {
  local c=$1; shift
  # shellcheck disable=SC2086 # each word is one assignment
  env PATH="$scratch/gh-bin:$PATH" GH_STATE="$scratch/gh-state" GH_CALLS="$scratch/gh-calls" ${MAIN_RUN_ENV:-} \
    python3 -I "$main_run" "$@" ${c:+"$c"} > "$scratch/out" 2> "$scratch/err"
  code=$?
}
line() { grep -qxE -- "$1" "$scratch/out"; }
lines() { grep -c '' "$scratch/out"; }
posts() { grep -c -- '-X POST' "$scratch/gh-calls"; }
reran() { grep -qxF -- "api -X POST repos/{owner}/{repo}/actions/runs/$1/rerun-failed-jobs" "$scratch/gh-calls"; }

label="main-run: the commit's own runs green, one line for each workflow with a run"
main_run_repo
runs "test.yml C completed success 1" "codex.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 0 ] && [ "$(lines)" = 3 ] && line 'Codex: green, run 102 on [0-9a-f]{9} \(the commit\), attempt 1: https://example.invalid/runs/102' &&
  line 'Test: green, run 101 on [0-9a-f]{9} \(the commit\), attempt 1: .*' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="main-run: origin's main head is the commit by default"
main_run_repo
runs "test.yml E completed success 1" "codex.yml C completed failure 1"
main_run_at ""
if [ "$code" -eq 0 ] && [ "$(lines)" = 2 ] && line 'Test: green, run 101 .*\(the commit\).*' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="main-run: a workflow without a run is not listed, nor called path-filtered"
main_run_repo
runs "test.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 0 ] && [ "$(lines)" = 2 ] && line 'Test: green, .*' && ! grep -q 'Codex\|Wild\|not run' "$scratch/out"; then pass "$label"; else fail "$label"; fi

label="main-run: a workflow's run is read whatever its file's branch patterns say"
main_run_repo
runs "wild.yml C completed failure 2" "test.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 4 ] && line 'Wild: red twice \(failure\), run 101 .*: open a regression job'; then pass "$label"; else fail "$label"; fi

label="main-run: no run on the commit or later on main is no run yet, and the read waits"
main_run_repo
runs "test.yml B completed success 1" "test.yml X completed success 1"
main_run_at "$C"
if [ "$code" -eq 2 ] && [ "$(lines)" = 2 ] && line 'no run yet'; then pass "$label"; else fail "$label"; fi

label="main-run: a run in progress waits"
main_run_repo
runs "test.yml C in_progress - 1" "codex.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 2 ] && line 'Test: running, run 101 .*' && line 'Codex: green, .*'; then pass "$label"; else fail "$label"; fi

label="main-run: a red first attempt has its failed jobs rerun once, and a second read starts no second rerun"
main_run_repo
runs "test.yml C completed failure 1" "codex.yml C completed success 1"
main_run_at "$C"
first=$code first_ok=false
line 'Test: red \(failure\), rerun started, run 101 on [0-9a-f]{9} \(the commit\), attempt 1: .*' && reran 101 && [ "$(posts)" = 1 ] && first_ok=true
main_run_at "$C"
if [ "$first" -eq 3 ] && $first_ok && [ "$code" -eq 2 ] && line 'Test: running, run 101 .*attempt 2: .*' && [ "$(posts)" = 1 ]; then pass "$label"; else fail "$label"; fi

# A second read that still sees the first attempt cannot tell it from the
# first read: it asks again, and GitHub, which refuses a rerun of a run
# already rerunning, makes it an error rather than a second rerun.
label="main-run: a second read of a stale first attempt asks again and reports the refusal"
main_run_repo
runs "test.yml C completed failure 1"
MAIN_RUN_ENV=GH_STALE=1 main_run_at "$C"
first=$code
MAIN_RUN_ENV=GH_STALE=1 main_run_at "$C"
if [ "$first" -eq 3 ] && [ "$code" -eq 1 ] && line 'Test: red \(failure\), its rerun could not be started .*HTTP 403.*' &&
  [ "$(posts)" = 2 ] && [ "$(grep -c '' "$scratch/gh-state.posted")" = 1 ]; then pass "$label"; else fail "$label"; fi

label="main-run: a run red on its rerun is red twice and never rerun again"
main_run_repo
runs "test.yml C completed failure 2" "codex.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 4 ] && line 'Test: red twice \(failure\), run 101 .*attempt 2: .*: open a regression job' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

# A run .github/workflows/rerun.yml already reran reads as its rerun ended.
label="main-run: a run green on its rerun is green, and nothing is rerun"
main_run_repo
runs "test.yml C completed success 2"
main_run_at "$C"
if [ "$code" -eq 0 ] && line 'Test: green, run 101 .*attempt 2: .*' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

for conclusion in timed_out action_required startup_failure stale; do
  label="main-run: a whole run concluded $conclusion is red"
  main_run_repo
  runs "test.yml C completed $conclusion 1"
  main_run_at "$C" -n
  if [ "$code" -eq 3 ] && line "Test: red \\($conclusion\\), would rerun, run 101 .*" && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi
done

for conclusion in skipped neutral; do
  label="main-run: a whole run concluded $conclusion is green"
  main_run_repo
  runs "test.yml C completed $conclusion 1"
  main_run_at "$C"
  if [ "$code" -eq 0 ] && line 'Test: green, run 101 .*'; then pass "$label"; else fail "$label"; fi
done

label="main-run: a cancelled run gives way to a later commit's"
main_run_repo
runs "test.yml C completed cancelled 1" "test.yml D completed success 1" "codex.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 0 ] && line 'Test: green, run 102 on [0-9a-f]{9} \(1 commit later on main\), attempt 1: .*' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="main-run: a cover of cancelled runs alone starts nothing and is red twice"
main_run_repo
runs "test.yml C completed cancelled 1" "test.yml D completed cancelled 1" "codex.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 4 ] && line 'Test: red \(cancelled, and nothing newer covers it\), nothing started, run 101 .*: open a regression job' &&
  [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="main-run: the nearest covering run decides, the commit's own before a later one"
main_run_repo
runs "test.yml E completed failure 2" "test.yml D completed success 1" "codex.yml C completed success 1" "codex.yml D completed failure 1"
main_run_at "$C"
if [ "$code" -eq 0 ] && line 'Test: green, run 102 on [0-9a-f]{9} \(1 commit later on main\), .*' && line 'Codex: green, run 103 .*\(the commit\).*' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

# A push that left main's first-parent line: C on main, then D (a child of
# C) pushed, then main fast-forwarded to X, a merge of D into E, a branch
# commit from C. Main's first-parent line is X, E, C, and D's runs still
# cover C, before X's.
label="main-run: a pushed commit off main's first-parent line still covers it"
main_run_repo
git reset -q --hard "$C"
printf 'd\n' > d2.txt; commit D2; D=$(git rev-parse HEAD)
git push -q -f origin main
git checkout -q -b branch "$C"; printf 'e\n' > e2.txt; commit E2; E=$(git rev-parse HEAD)
git merge -q --no-ff -m merge "$D"; X=$(git rev-parse HEAD)
git checkout -q main; git merge -q --ff-only "$X"; git push -q origin main
runs "test.yml D completed failure 2" "test.yml X completed success 1"
main_run_at "$C"
if [ "$code" -eq 4 ] && [ "$(git rev-list --first-parent "$X" | grep -c "$D")" = 0 ] &&
  line "Test: red twice \\(failure\\), run 101 on ${D:0:9} \\([0-9]+ commits? later on main\\), .*"; then pass "$label"; else fail "$label"; fi

label="main-run: a commit's run made long before its commit time still covers it"
main_run_repo
runs "test.yml C completed failure 2 2026-01-01T10:00:00Z" "test.yml D completed success 1"
main_run_at "$C"
if [ "$code" -eq 4 ] && line 'Test: red twice \(failure\), run 101 .*'; then pass "$label"; else fail "$label"; fi

label="main-run: a listing that does not hold every run is an error, never a later green"
main_run_repo
runs "test.yml C completed failure 2" "test.yml D completed success 1"
MAIN_RUN_ENV=GH_SHORT=1 main_run_at "$C"
if [ "$code" -eq 1 ] && has_err 'were not all read' && ! grep -q 'green' "$scratch/out"; then pass "$label"; else fail "$label"; fi

label="main-run: a red-twice line outranks a rerun started beside it"
main_run_repo
runs "test.yml C completed failure 2" "codex.yml C completed failure 1"
main_run_at "$C"
if [ "$code" -eq 4 ] && line 'Codex: red \(failure\), rerun started, .*' && line 'Test: red twice .*' && reran 102 && [ "$(posts)" = 1 ]; then pass "$label"; else fail "$label"; fi

label="main-run: a rerun that cannot be started is an error"
main_run_repo
runs "test.yml C completed failure 1" "codex.yml C completed success 1"
MAIN_RUN_ENV=GH_FAIL_POST=1 main_run_at "$C"
if [ "$code" -eq 1 ] && line 'Test: red \(failure\), its rerun could not be started .*'; then pass "$label"; else fail "$label"; fi

label="main-run: runs that cannot be read are an error"
main_run_repo
runs "test.yml C completed success 1"
MAIN_RUN_ENV=GH_FAIL=1 main_run_at "$C"
if [ "$code" -eq 1 ] && has_err 'main-run: gh api'; then pass "$label"; else fail "$label"; fi

label="main-run: a commit not on origin's main is refused"
main_run_repo
runs "test.yml X completed success 1"
main_run_at "$X"
if [ "$code" -eq 64 ] && has_err 'is not on origin' && [ ! -s "$scratch/out" ]; then pass "$label"; else fail "$label"; fi

label="main-run: an unknown option is refused"
main_run_repo
runs
main_run_at "$C" --wait
if [ "$code" -eq 64 ] && has_err 'usage:' && [ "$(grep -c '' "$scratch/gh-calls")" = 0 ]; then pass "$label"; else fail "$label"; fi

# --- scripts/ci/reds.py ---

reds="$root/scripts/ci/reds.py"
# The stand-in gh answers from $GH_STATE, a JSON object: "issues", the
# repository's issues and pull requests (each {number, title, state,
# comments[, pull_request]}), "jobs", each run attempt's jobs by
# "RUN/ATTEMPT", and "logs", each job's log by id (a job without one is a
# log that cannot be read, and one holding a terminal escape sequence is
# refused without --allow-escape-sequences, as gh 2.97.0 and later refuse
# it). It lists the open issues and an attempt's
# jobs two to a page, as gh prints pages; opens, comments on and closes
# issues; and adds each run whose failed jobs it is asked to rerun to
# "reruns". Every call is a line of $GH_CALLS; under GH_FAIL every call
# fails. Calls take turns on the state, and under GH_BARRIER, a file, the
# first two listings of the open issues each read the issues, then wait
# for the other before answering, as two runs that list at one moment.
mkdir -p "$scratch/reds-bin"
cat > "$scratch/reds-bin/gh" <<'GH'
#!/usr/bin/env python3
import json, os, re, sys
args = sys.argv[1:]
with open(os.environ["GH_CALLS"], "a") as f:
    f.write(" ".join(a.replace("\n", "\\n") for a in args) + "\n")
if os.environ.get("GH_FAIL") or args[:1] != ["api"]:
    sys.exit("gh: stand-in refused")
import fcntl, time
path = os.environ["GH_STATE"]
lock = open(path + ".lock", "a")
fcntl.flock(lock, fcntl.LOCK_EX)
state = json.load(open(path))
barrier = os.environ.get("GH_BARRIER")
args = args[1:]
method = "GET"
if args[:1] == ["-X"]:
    method, args = args[1], args[2:]
escapes = "--allow-escape-sequences" in args
args = [a for a in args if a != "--allow-escape-sequences"]
paginate = args[:1] == ["--paginate"]
url, fields = (args[1:] if paginate else args)[0], {}
rest = (args[1:] if paginate else args)[1:]
while rest:
    flag, value, rest = rest[0], rest[1], rest[2:]
    assert flag == "-f", rest
    k, _, v = value.partition("=")
    fields[k] = v
issue = lambda n: next(i for i in state["issues"] if i["number"] == n)
def save():
    json.dump(state, open(path, "w"))
def pages(items, wrap):
    for i in range(0, max(len(items), 1), 2):
        print(json.dumps(wrap(items[i:i + 2])))
r = "repos/{owner}/{repo}/"
if method == "GET" and paginate and url == r + "issues?state=open&per_page=100":
    listed = [i for i in state["issues"] if i["state"] == "open"]
    if barrier:
        with open(barrier, "a") as f:
            f.write("listed\n")
        arrived = len(open(barrier).read().split())
        fcntl.flock(lock, fcntl.LOCK_UN)
        until = time.time() + 10
        while arrived <= 2 and len(open(barrier).read().split()) < 2 and time.time() < until:
            time.sleep(0.05)
    pages(listed, lambda p: p)
elif method == "GET" and paginate and (m := re.fullmatch(re.escape(r) + r"actions/runs/(\d+)/attempts/(\d+)/jobs\?per_page=100", url)):
    jobs = state["jobs"].get(f"{m[1]}/{m[2]}", [])
    pages(jobs, lambda p: {"total_count": len(jobs), "jobs": p})
elif method == "GET" and (m := re.fullmatch(re.escape(r) + r"actions/jobs/(\d+)/logs", url)):
    if m[1] not in state["logs"]:
        sys.exit("gh: Not Found (HTTP 404)")
    if "\x1b" in state["logs"][m[1]] and not escapes:
        sys.exit("the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway")
    sys.stdout.write(state["logs"][m[1]])
elif method == "POST" and (m := re.fullmatch(re.escape(r) + r"actions/runs/(\d+)/rerun-failed-jobs", url)) and not fields:
    state["reruns"].append(int(m[1])); save()
elif method == "POST" and url == r + "issues" and sorted(fields) == ["body", "title"]:
    n = 1 + max((i["number"] for i in state["issues"]), default=0)
    state["issues"].append({"number": n, "title": fields["title"], "state": "open", "comments": [fields["body"]]}); save()
    print(json.dumps({"number": n}))
elif method == "POST" and (m := re.fullmatch(re.escape(r) + r"issues/(\d+)/comments", url)) and sorted(fields) == ["body"]:
    issue(int(m[1]))["comments"].append(fields["body"]); save()
elif method == "PATCH" and (m := re.fullmatch(re.escape(r) + r"issues/(\d+)", url)) and fields in ({"state": "closed", "state_reason": "completed"}, {"state": "closed", "state_reason": "not_planned"}):
    issue(int(m[1]))["state"] = "closed"; save()
else:
    sys.exit(f"gh: stand-in does not answer {sys.argv[1:]}")
GH
chmod +x "$scratch/reds-bin/gh"

# reds_state [ISSUE...]: a fresh stand-in state, each ISSUE 'NUMBER
# open|closed|pr TITLE'. Run 7's attempt 1 failed two jobs and passed one:
# job 71's log names ExUnit failures, one twice, and a harness FAIL line
# under the runner's timestamps, with a mention and a link, after a step
# command the runner coloured, as in every job's log; job 72's log
# names none; job 73 passed. Its attempt 2 failed job 75 again; job 74's
# log cannot be read. Run 8's attempt 1 failed no job.
reds_state() {
  : > "$scratch/reds-calls"
  python3 -I - "$scratch/reds-state" "$@" <<'PY'
import json, sys
issues = []
for spec in sys.argv[2:]:
    n, kind, title = spec.split(" ", 2)
    issue = {"number": int(n), "title": title, "state": "closed" if kind == "closed" else "open", "comments": []}
    if kind == "pr":
        issue["pull_request"] = {}
    issues.append(issue)
log71 = "\n".join([
    "2026-11-18T09:58:00.1234567Z \x1b[36;1mscripts/test-partitioned.sh -a postgres\x1b[0m",
    "2026-11-18T10:00:00.1234567Z ==> partition 2/4",
    "2026-11-18T10:00:01.0000000Z   1) test a session ends on sign-out (CyfrWeb.SessionTest)",
    "2026-11-18T10:00:01.1000000Z      apps/cyfr/test/cyfr_web/session_test.exs:41",
    "2026-11-18T10:00:02.0000000Z   2) test @someone [x](https://example.invalid) (Aqua.RunnerTest)",
    "2026-11-18T10:00:03.0000000Z   1) test a session ends on sign-out (CyfrWeb.SessionTest)",
    "2026-11-18T10:00:04.0000000Z FAIL: main-run: a run in progress waits",
    "2026-11-18T10:00:05.0000000Z 3 tests, 2 failures",
])
json.dump({"issues": issues, "reruns": [], "logs": {"71": log71, "72": "all quiet\n", "73": "ok\n"},
           "jobs": {"7/1": [{"id": 71, "name": "Elixir Tests (postgres, shard 2)", "conclusion": "failure"},
                            {"id": 72, "name": "@someone's job", "conclusion": "timed_out"},
                            {"id": 73, "name": "Static checks", "conclusion": "success"}],
                    "7/2": [{"id": 74, "name": "Elixir Tests (postgres, shard 2)", "conclusion": "success"},
                            {"id": 75, "name": "Browser harness (canvas)", "conclusion": "failure"},
                            {"id": 76, "name": "Static checks", "conclusion": "success"}],
                    "8/1": [{"id": 81, "name": "Static checks", "conclusion": "success"}]}},
          open(sys.argv[1], "w"))
PY
}
# reds_run COMMAND [NAME=VALUE...]: runs the script with only those facts.
reds_run() {
  local command=$1; shift
  env -i PATH="$scratch/reds-bin:$PATH" GH_STATE="$scratch/reds-state" GH_CALLS="$scratch/reds-calls" ${REDS_ENV:-} "$@" \
    python3 -I "$reds" "$command" > "$scratch/out" 2> "$scratch/err"
  code=$?
}
sha=0123456789abcdef0123456789abcdef01234567
# test_run RUN ATTEMPT CONCLUSION EVENT BRANCH: a completed Test run's facts.
test_run() {
  reds_run test-run RUN_ID="$1" RUN_ATTEMPT="$2" CONCLUSION="$3" EVENT="$4" HEAD_BRANCH="$5" HEAD_SHA="$sha" \
    RUN_URL="https://example.invalid/runs/$1"
}
# state EXPRESSION: the Python expression over the stand-in's state `s`,
# `issues` its issues by title, holds.
state() {
  python3 -I - "$scratch/reds-state" "$1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
issues = {}
for i in s["issues"]:
    issues.setdefault(i["title"], []).append(i)
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
}
writes() { grep -c -- '^api -X ' "$scratch/reds-calls"; }
calls() { grep -c '' "$scratch/reds-calls"; }
flakes="Flaky tests"
red_twice="Test is red twice on main"
nightly_red="Host nightly is red"
silent="Host nightly sent no report"

for spec in "pull_request feature:for a pull request" "push main:on main"; do
  event=${spec%%:*} where=${spec#*:}
  label="reds: a Test run that failed its first attempt $where has its failed jobs rerun once, and nothing else"
  reds_state
  test_run 7 1 failure $event
  if [ "$code" -eq 0 ] && state 's["reruns"] == [7] and not s["issues"]' && [ "$(writes)" = 1 ] &&
    grep -qxF "reds: run 7, attempt 1, failure $where: its failed jobs rerun once" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done

label="reds: a rerun that passed records a flake naming the run, the commit, the jobs that failed and the tests their logs name"
reds_state "1 closed $flakes" "2 pr $flakes"
test_run 7 2 success pull_request feature
body_ok=$(python3 -I - "$scratch/reds-state" "$sha" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
new = [i for i in s["issues"] if i["number"] == 3]
body = new[0]["comments"][0] if new and len(new[0]["comments"]) == 1 else ""
head = f"A flake for a pull request: [run 7](https://example.invalid/runs/7) of commit {sys.argv[2]} failed on attempt 1 and passed on attempt 2, nothing changed."
block = ["    Elixir Tests (postgres, shard 2)",
         "        1) test a session ends on sign-out (CyfrWeb.SessionTest)",
         "        2) test @someone [x](https://example.invalid) (Aqua.RunnerTest)",
         "        FAIL: main-run: a run in progress waits",
         "    @someone's job",
         "        (its log names no failing test)"]
lines = body.split("\n")
print("yes" if new and new[0]["title"] == "Flaky tests" and lines[0].startswith(head) and lines[1] == "" and lines[2:] == block
      and [i["comments"] for i in s["issues"][:2]] == [[], []] and not s["reruns"] else f"no: {s}")
PY
)
if [ "$code" -eq 0 ] && [ "$body_ok" = yes ] && grep -qxF "reds: opened #3, $flakes" "$scratch/out"; then pass "$label"; else fail "$label"; echo "  state: $body_ok"; fi

label="reds: a second flake is one more comment on the open record, the oldest when two are open"
reds_state "4 open $flakes" "5 open $flakes"
test_run 7 2 success push main
if [ "$code" -eq 0 ] && state 'len(issues["Flaky tests"]) == 2 and len(issues["Flaky tests"][0]["comments"]) == 1 and not issues["Flaky tests"][1]["comments"]' &&
  state 'issues["Flaky tests"][0]["comments"][0].startswith("A flake on main: ")' && [ "$(writes)" = 1 ]; then pass "$label"; else fail "$label"; fi

label="reds: a flake's job whose log cannot be read is still named, and the script's output says why"
reds_state
python3 -I - "$scratch/reds-state" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); del s["logs"]["72"]; json.dump(s, open(sys.argv[1], "w"))
PY
test_run 7 2 success pull_request feature
if [ "$code" -eq 0 ] && state '"    @someone'"'"'s job\n        (its log could not be read)" in issues["Flaky tests"][0]["comments"][0]' &&
  grep -qxF 'reds: the log of job 72 could not be read: gh api --allow-escape-sequences repos/{owner}/{repo}/actions/jobs/72/logs: gh: Not Found (HTTP 404)' "$scratch/out"; then pass "$label"; else fail "$label"; fi

# A pull request's author writes its test names and log lines; the record
# keeps their text and none of their control characters.
label="reds: a failing-test line carrying control characters reaches the record without them"
reds_state
python3 -I - "$scratch/reds-state" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["logs"]["72"] = "2026-11-18T10:00:06.0000000Z   3) test \x1b[31mred\x1b[0m\x07 and\x7f\x00 bell\t(Color.Test)\n"
json.dump(s, open(sys.argv[1], "w"))
PY
test_run 7 2 success pull_request feature
if [ "$code" -eq 0 ] && state '"    @someone'"'"'s job\n        3) test [31mred[0m and bell(Color.Test)" in issues["Flaky tests"][0]["comments"][0] and not any(ord(c) < 32 and c != "\n" or ord(c) == 127 for c in issues["Flaky tests"][0]["comments"][0])'; then pass "$label"; else fail "$label"; fi

label="reds: a passed rerun whose earlier attempt failed no job (a rerun by hand of a green or cancelled run) records nothing"
reds_state
test_run 8 2 success pull_request feature
if [ "$code" -eq 0 ] && state 'not s["issues"] and not s["reruns"]' && [ "$(writes)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="reds: a rerun red again on main is not rerun, and opens the red-twice issue naming the run and its failed jobs"
reds_state "1 open $flakes"
test_run 7 2 failure push main
if [ "$code" -eq 0 ] && state 'not s["reruns"] and [i["comments"] for i in issues["Test is red twice on main"]] == [[
  f"[Run 7](https://example.invalid/runs/7) of commit '"$sha"' on main failed again on attempt 2, and is not rerun: open a regression job. Its failed jobs:\n\n    Browser harness (canvas)"]]' &&
  state 'not issues["Flaky tests"][0]["comments"]'; then pass "$label"; else fail "$label"; fi

for conclusion in failure success; do
  for spec in "push main" "pull_request feature"; do
    read -r event branch <<<"$spec"
    label="reds: a third attempt, $conclusion on $branch, is a person's: nothing is read, rerun or written"
    reds_state "3 open $red_twice" "4 open $flakes"
    test_run 7 3 "$conclusion" "$event" "$branch"
    if [ "$code" -eq 0 ] && [ "$(calls)" = 0 ] && grep -qF 'an attempt after the second is a person' "$scratch/out"; then pass "$label"; else fail "$label"; fi
  done
done

# Two flakes recorded at one moment: both find no record open and both
# open one; the later, listing again, moves its text to the earlier and
# closes its own.
label="reds: two flakes recorded at one moment end in one open record holding both"
reds_state "1 closed $flakes"
: > "$scratch/reds-barrier"
racers=()
for spec in "pull_request feature" "push main"; do
  read -r event branch <<<"$spec"
  env -i PATH="$scratch/reds-bin:$PATH" GH_STATE="$scratch/reds-state" GH_CALLS="$scratch/reds-calls" GH_BARRIER="$scratch/reds-barrier" \
    RUN_ID=7 RUN_ATTEMPT=2 CONCLUSION=success EVENT="$event" HEAD_BRANCH="$branch" HEAD_SHA="$sha" RUN_URL=https://example.invalid/runs/7 \
    python3 -I "$reds" test-run > "$scratch/out-$branch" 2> "$scratch/err-$branch" &
  racers+=("$!")
done
wait "${racers[0]}"; first=$?
wait "${racers[1]}"; code=$?
cat "$scratch/out-feature" "$scratch/out-main" > "$scratch/out"
cat "$scratch/err-feature" "$scratch/err-main" > "$scratch/err"
if [ "$first" -eq 0 ] && [ "$code" -eq 0 ] && [ "$(grep -c '^listed$' "$scratch/reds-barrier")" -ge 2 ] &&
  state '[(i["number"], i["state"]) for i in issues["Flaky tests"]] == [(1, "closed"), (2, "open"), (3, "closed")] and sorted(c.split(":")[0] for c in issues["Flaky tests"][1]["comments"]) == ["A flake for a pull request", "A flake on main"]'; then pass "$label"; else fail "$label"; fi

label="reds: a pull request's rerun red again is left red, with nothing rerun or written"
reds_state
test_run 7 2 failure pull_request feature
if [ "$code" -eq 0 ] && [ "$(calls)" = 0 ] && grep -qxF 'reds: run 7, attempt 2, failure for a pull request: not rerun again, the red stands for its author' "$scratch/out"; then pass "$label"; else fail "$label"; fi

for spec in "cancelled 1 pull_request feature" "cancelled 2 push main" "action_required 1 pull_request feature" "success 1 push main"; do
  read -r conclusion attempt event branch <<<"$spec"
  label="reds: a run concluded $conclusion on attempt $attempt is left alone"
  reds_state
  test_run 7 "$attempt" "$conclusion" "$event" "$branch"
  if [ "$code" -eq 0 ] && [ "$(calls)" = 0 ]; then pass "$label"; else fail "$label"; fi
done

for spec in "push 0.6.0-alpha.15" "push feature" "schedule main" "workflow_dispatch main"; do
  read -r event branch <<<"$spec"
  label="reds: a failed $event run on $branch is neither a pull request's nor a push on main, and is left alone"
  reds_state
  test_run 7 1 failure "$event" "$branch"
  if [ "$code" -eq 0 ] && [ "$(calls)" = 0 ] && grep -qF 'left alone' "$scratch/out"; then pass "$label"; else fail "$label"; fi
done

label="reds: a rerun that cannot be started, or records that cannot be read, is an error"
reds_state
REDS_ENV=GH_FAIL=1 test_run 7 1 failure push main
first=$code
REDS_ENV=GH_FAIL=1 test_run 7 2 success push main
if [ "$first" -eq 1 ] && [ "$code" -eq 1 ] && has_err 'reds: gh api'; then pass "$label"; else fail "$label"; fi

label="reds: a malformed fact or an unknown command is refused before any call"
reds_state
reds_run test-run RUN_ID=7 RUN_ATTEMPT=one CONCLUSION=failure EVENT=push HEAD_BRANCH=main HEAD_SHA="$sha" RUN_URL=u
first=$code
reds_run rerun
if [ "$first" -eq 64 ] && [ "$code" -eq 64 ] && has_err 'usage:' && [ "$(calls)" = 0 ]; then pass "$label"; else fail "$label"; fi

# The host's nightly report and its watchdog.
night() { # OUTCOME STATUS: the report job's facts
  reds_run nightly OUTCOME="$1" COMMIT="$sha" STATUS="$2" LOGS=/tmp/cyfr-stage.nightly.Ab1sCd \
    SUMMARY=$'janitor: ok 9s\nhandle-proof: failed 1 312s\ncanvas-proof-desktop: not run 69 0s' RUN_URL=https://example.invalid/runs/9
}
label="reds: a red night opens the nightly issue naming the commit, the exit, the rows that did not pass and the host's log folder"
reds_state "1 open $silent"
night failure 1
if [ "$code" -eq 0 ] && state '[i["comments"] for i in issues["Host nightly is red"]] == [["The host'"'"'s [nightly report](https://example.invalid/runs/9) failed:\n\n" + "\n".join([
  "    commit: '"$sha"'", "    exit: 1", "    logs on the host: /tmp/cyfr-stage.nightly.Ab1sCd", "    rows that did not pass:",
  "      handle-proof: failed 1 312s", "      canvas-proof-desktop: not run 69 0s"])]]' && state 'not s["issues"][0]["comments"]'; then pass "$label"; else fail "$label"; fi

label="reds: a second red night is one more comment on the open nightly issue"
reds_state "2 open $nightly_red"
night failure 69
if [ "$code" -eq 0 ] && state 'len(s["issues"]) == 1 and len(s["issues"][0]["comments"]) == 1 and "    exit: 69" in s["issues"][0]["comments"][0]'; then pass "$label"; else fail "$label"; fi

label="reds: a green night closes the open nightly issue with a comment, and leaves the watchdog's open"
reds_state "2 open $nightly_red" "3 open $silent"
night success 0
if [ "$code" -eq 0 ] && state '[(i["state"], i["comments"]) for i in s["issues"]] == [("closed", ["The host'"'"'s [nightly](https://example.invalid/runs/9) of '"$sha"' exited 0."]), ("open", [])]'; then pass "$label"; else fail "$label"; fi

label="reds: a green night with no issue open writes nothing"
reds_state "2 closed $nightly_red"
night success 0
if [ "$code" -eq 0 ] && [ "$(writes)" = 0 ] && state 's["issues"][0]["state"] == "closed"'; then pass "$label"; else fail "$label"; fi

label="reds: the watchdog's red opens its own issue, then comments on it, and its green closes it alone"
reds_state "1 open $nightly_red"
reds_run watchdog OUTCOME=failure RUN_URL=https://example.invalid/runs/10
first=$code
reds_run watchdog OUTCOME=failure RUN_URL=https://example.invalid/runs/11
second=$code
red_ok=false
state '[len(i["comments"]) for i in issues["Host nightly sent no report"]] == [2] and "[watchdog](https://example.invalid/runs/11)" in issues["Host nightly sent no report"][0]["comments"][1]' && red_ok=true
reds_run watchdog OUTCOME=success RUN_URL=https://example.invalid/runs/12
if [ "$first" -eq 0 ] && [ "$second" -eq 0 ] && $red_ok && [ "$code" -eq 0 ] &&
  state '[(i["title"], i["state"]) for i in s["issues"]] == [("Host nightly is red", "open"), ("Host nightly sent no report", "closed")]'; then pass "$label"; else fail "$label"; fi

label="reds: a check outcome other than success or failure is refused"
reds_state
reds_run watchdog OUTCOME=skipped RUN_URL=u
if [ "$code" -eq 64 ] && [ "$(calls)" = 0 ]; then pass "$label"; else fail "$label"; fi

# The workflow that runs it: on each completed Test run, with write
# permissions on its job alone, from the script alone checked out of the
# default branch, the event's facts handed over through the environment.
label="reds: rerun.yml follows every completed Test run and runs nothing of the run's own"
rerun_ok=$(python3 -I - "$root/.github/workflows/rerun.yml" <<'PY'
import sys, yaml
spec = yaml.safe_load(open(sys.argv[1]))
on, errors = spec.get(True, spec.get("on")), []
if on != {"workflow_run": {"workflows": ["Test"], "types": ["completed"]}}:
    errors.append(f"it runs on {on}")
if spec.get("permissions") != {}:
    errors.append(f"its permissions are {spec.get('permissions')}")
(job,) = spec["jobs"].values()
if job.get("permissions") != {"contents": "read", "actions": "write", "issues": "write"}:
    errors.append(f"its job's permissions are {job.get('permissions')}")
checkout, step = job["steps"]
if not checkout["uses"].startswith("actions/checkout@") or checkout.get("with") != {
        "ref": "${{ github.event.repository.default_branch }}", "sparse-checkout": "scripts/ci/reds.py",
        "sparse-checkout-cone-mode": False, "persist-credentials": False}:
    errors.append(f"it checks out {checkout}")
facts = {k: f"${{{{ github.event.workflow_run.{v} }}}}" for k, v in (("RUN_ID", "id"), ("RUN_ATTEMPT", "run_attempt"),
         ("CONCLUSION", "conclusion"), ("EVENT", "event"), ("HEAD_BRANCH", "head_branch"), ("HEAD_SHA", "head_sha"), ("RUN_URL", "html_url"))}
if step.get("run") != "python3 -I scripts/ci/reds.py test-run" or step.get("env") != {
        "GH_TOKEN": "${{ github.token }}", "GH_REPO": "${{ github.repository }}", **facts}:
    errors.append(f"its step is {step}")
print("; ".join(errors) or "yes")
PY
)
if [ "$rerun_ok" = yes ]; then pass "$label"; else fail "$label"; echo "  $rerun_ok"; fi

# --- scripts/ci/release-binary-check.sh ---
# Real builds of the command line: as the release builds it (.goreleaser.yml's
# env and ldflags), and with the release proof's tag and folder as
# tests/compose-proof/run.sh builds it. The marker check is shown alone on
# the tagged binary, its build settings read through a go whose tag line is
# masked, as a build that reached the proof file some other way would read.
binary_check="$root/scripts/ci/release-binary-check.sh"
bins="$scratch/bins"
mkdir -p "$bins"
built=1
(cd "$root/apps/codex" &&
  CGO_ENABLED=0 go build -mod=readonly -ldflags "-s -w -X github.com/cyfr/codex/internal/version.Version=0.1.0" -o "$bins/release" . &&
  CGO_ENABLED=0 go build -mod=readonly -tags releaseproof \
    -ldflags "-s -w -X github.com/cyfr/codex/cmd.proofReleases=$bins/releases" -o "$bins/proof" .) > "$scratch/out" 2> "$scratch/err" || built=0
code=$built

label="release-binary-check passes the command line built as the release builds it"
if [ "$built" = 1 ]; then
  run "$binary_check" "$bins/release"
  if [ "$code" -eq 0 ] && grep -qF "release binary ok" "$scratch/out" && [ ! -s "$scratch/err" ]; then pass "$label"; else fail "$label"; fi
else
  fail "$label (the command line did not build)"
fi

label="release-binary-check refuses the command line built with the release proof's tag"
if [ "$built" = 1 ]; then
  run "$binary_check" "$bins/proof"
  check refused "was built with build tags:  build -tags=releaseproof"
else
  fail "$label (the command line did not build)"
fi

label="release-binary-check refuses a binary holding the release proof's marker with no tag recorded"
if [ "$built" = 1 ]; then
  mkdir -p "$scratch/masked-go"
  real_go=$(command -v go)
  printf '#!/usr/bin/env bash\n"%s" "$@" | grep -vE "^[[:space:]]+build[[:space:]]+-tags="\n' "$real_go" > "$scratch/masked-go/go"
  chmod +x "$scratch/masked-go/go"
  PATH="$scratch/masked-go:$PATH" run "$binary_check" "$bins/proof"
  check refused "holds the release proof"
else
  fail "$label (the command line did not build)"
fi

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
  printf 'A release note.\n' > "$scratch/notes.md"
}

label="release.sh refuses a file replaced by a symlink in a version the last tag shipped"
release_repo
rm "$v1/a.txt"
ln -s b.txt "$v1/a.txt"
commit typechange
run scripts/release.sh 0.1.1 --notes "$scratch/notes.md"
if [ "$code" -eq 1 ] && has_err "$v1/a.txt" && grep -qF "shipped by 0.1.0" "$scratch/out" && ! git rev-parse --verify --quiet 0.1.1 > /dev/null; then pass "$label"; else fail "$label"; fi

label="release.sh refuses a modified file in a version the last tag shipped"
release_repo
printf 'changed\n' > "$v1/a.txt"
commit modify
run scripts/release.sh 0.1.1 --notes "$scratch/notes.md"
if [ "$code" -eq 1 ] && has_err "$v1/a.txt" && ! git rev-parse --verify --quiet 0.1.1 > /dev/null; then pass "$label"; else fail "$label"; fi

cd "$root" || exit 1
echo "$((cases - failures)) of $cases cases passed"
[ "$failures" -eq 0 ]
