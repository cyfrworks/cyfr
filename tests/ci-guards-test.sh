#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Regression cases for scripts/ci/seed-guard.sh, scripts/ci/config-seam.sh,
# scripts/ci/retry.sh, scripts/ci/world-checks.sh,
# scripts/ci/self-test-scope.sh, scripts/ci/storage-diagrams.py,
# scripts/ci/cluster-cell.sh,
# scripts/ci/main-run.py and scripts/ci/reds.py (the last two against a
# stand-in gh, the last with the workflow that runs it),
# scripts/ci/release-binary-check.sh (against real builds of the command
# line, so it needs go and the module's dependencies), for
# scripts/release.sh's use of the seed guard, for test.yml's jobs divided
# between runners: the two-node suite's cells, the partition runner test's
# groups, the Elixir shards, the browser shards' viewports and the app
# image's groups (it reads test.yml through PyYAML), for what lets a check
# pass in every workflow (a trivy scan's pin and inputs, continue-on-error,
# the MinIO image's digest, the npm audit's lockfiles), for the image
# builds' layer cache (one workflow writes it and a package, release.yml's
# publishing aside), and for the run prefix the proof scripts name what
# they make under.
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

label="world-checks: no event, as on a host, blocks"
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
src/app.ex README.md apps/arca/lib/arca.ex apps/cyfr/assets/js/app.js|host=false partitions=false
apps/codex/go.mod seed/components/x/1.0.0/a.txt apps/arca/test/stored_test.exs|host=false partitions=false
scripts/lib/contain.sh|
-scripts/lib/contain.sh|
.github/workflows/test.yml|
scripts/ci/self-test-scope.sh|
tests/contain-test.sh|partitions=false
-tests/contain-test.sh|partitions=false
scripts/stages.tsv|partitions=false
scripts/heavy-check.sh|partitions=false
.github/workflows/release.yml|partitions=false
.github/workflows/codex-ci.yml|partitions=false
config/test.exs|host=false
config/database_choice.exs|host=false
scripts/test-partition-weights.tsv|host=false
.github/actions/setup-elixir/action.yml|host=false
CASES

label="self-test-scope: what the base changed since the branch left it is not the pull request's"
scope_repo README.md -- scripts/lib/contain.sh .github/workflows/test.yml scripts/heavy-check.sh
pr
if skipped 'host=false partitions=false'; then pass "$label"; else fail "$label"; fi

label="self-test-scope: each job skipped is named not needed"
scope_repo README.md
pr
if [ "$(grep -c '^harness-tests-[a-z]*: not needed, ' "$scratch/out")" = 2 ] && [ ! -s "$scratch/err" ]; then pass "$label"; else fail "$label"; fi

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

for job in ("harness-tests-host", "harness-tests-partitions"):
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

# self-test-scope answers for a change to any workflow, so test.yml starts
# on one: both its path filters name every file under .github/workflows.
label="self-test-scope: test.yml starts on a push or a pull request that changes any workflow"
python3 -I - "$root/.github/workflows/test.yml" > "$scratch/out" 2> "$scratch/err" <<'PY'
import re, sys

lines = open(sys.argv[1]).read().split("\n")
for event in ("push", "pull_request"):
    start = lines.index(f"  {event}:")
    paths = []
    for line in lines[start + 1:]:
        if re.match(r"  \S", line) or re.match(r"\S", line):
            break
        m = re.fullmatch(r"      - '([^']*)'", line)
        if m:
            paths.append(m[1])
    if ".github/workflows/**" not in paths:
        print(f"{event}: its paths do not name .github/workflows/**")
PY
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi

# --- test.yml's jobs divided between runners ---

# cluster_cells WORKFLOW SCRIPT: the cluster job's matrix is the cells a
# and b alone; its selection step is exactly SCRIPT's call with the
# matrix's cell, and its suite step exactly the run of the files that
# step gave; no other step names either script. SCRIPT, run in this
# checkout, gives each file of the suite to one cell, and, run in a
# scratch copy of the suite with two files added, gives a what it gave
# here and b the added files besides. Each error is a line.
cluster_cells() {
  python3 -I - "$1" "$root" "$2" "$scratch/cells-copy" <<'PY'
import os, shutil, subprocess, sys, yaml
wf, root, script, copy = sys.argv[1:]
job = yaml.safe_load(open(wf))["jobs"]["cluster"]
errors = []
matrix = job.get("strategy", {}).get("matrix", {})
if matrix != {"cell": ["a", "b"]}:
    errors.append(f"the cluster matrix is {matrix}, not the cells a and b alone")
want = [
    {"name": "The cell's files", "id": "cell", "env": {"CELL": "${{ matrix.cell }}"},
     "run": 'files=$(scripts/ci/cluster-cell.sh "$CELL")\necho "files=$files" >> "$GITHUB_OUTPUT"\n'},
    {"name": "Run the two-node suite",
     "env": {"MIX_BUILD_PATH": "_build/test", "CELL_FILES": "${{ steps.cell.outputs.files }}"},
     "run": "scripts/test-partitioned.sh -n 1 -a postgres -- --warnings-as-errors --only cluster $CELL_FILES"},
]
for w in want:
    got = [s for s in job["steps"] if s.get("name") == w["name"]]
    if got != [w]:
        errors.append(f"the cluster job's step {w['name']!r} is {got}, not {w}")
others = [s.get("name") for s in job["steps"] if s not in want
          and any(n in str(s.get("run", "")) for n in ("cluster-cell.sh", "test-partitioned.sh"))]
if others:
    errors.append(f"the cluster job's steps {others} also select or run the suite")
def cells(where):
    out = {}
    for cell in ("a", "b"):
        r = subprocess.run(["bash", script, cell], cwd=where, capture_output=True, text=True,
                           env={"PATH": os.environ["PATH"]})
        if r.returncode != 0:
            errors.append(f"cell {cell}'s selection in {'this checkout' if where == root else 'the copy'} failed: {r.stderr.strip()}")
            return None
        out[cell] = r.stdout.split()
    return out
def suite(where):
    found = set()
    for d, _, names in os.walk(os.path.join(where, "apps/cyfr/test/cluster")):
        found |= {os.path.relpath(os.path.join(d, n), where) for n in names if n.endswith("_test.exs")}
    return found
here = cells(root)
if here:
    if set(here["a"]) & set(here["b"]) or sorted(here["a"] + here["b"]) != sorted(suite(root)):
        errors.append(f"the cells do not hold each file of the suite once: a {here['a']}, b {here['b']}")
    shutil.rmtree(copy, ignore_errors=True)
    for f in suite(root):
        os.makedirs(os.path.dirname(os.path.join(copy, f)), exist_ok=True)
        open(os.path.join(copy, f), "w").close()
    added = ["apps/cyfr/test/cluster/added_test.exs", "apps/cyfr/test/cluster/nested/added_test.exs"]
    for f in added:
        os.makedirs(os.path.dirname(os.path.join(copy, f)), exist_ok=True)
        open(os.path.join(copy, f), "w").close()
    there = cells(copy)
    if there and (there["a"] != here["a"] or sorted(there["b"]) != sorted(here["b"] + added)):
        errors.append(f"with two files added the cells are a {there['a']}, b {there['b']}: the added files are not b's alone")
for e in errors:
    print(e)
PY
}
cell_script="$root/scripts/ci/cluster-cell.sh"
label="test.yml: the two-node suite runs in the cells a and b, a its listed files and b every other"
cluster_cells "$root/.github/workflows/test.yml" "$cell_script" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
# Planted: a third cell, both runners on cell a, cell b's files restated
# in the step, cell b's files restated in the script, and a listed file
# the suite does not have, each named.
plant_cells() { # KIND: writes cells.yml and cells.sh, one of them planted
  python3 -I - "$root/.github/workflows/test.yml" "$cell_script" "$scratch" "$1" "$root" <<'PY'
import subprocess, sys
wf, script, out, kind, root = sys.argv[1:]
w, s = open(wf).read(), open(script).read()
b = subprocess.run(["bash", script, "b"], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
edits = {
    "third": ("w", "        cell: [a, b]\n", "        cell: [a, b, c]\n"),
    "constant": ("w", "          CELL: ${{ matrix.cell }}\n", "          CELL: a\n"),
    "restated": ("w", '          files=$(scripts/ci/cluster-cell.sh "$CELL")\n',
                 f'          files=$(scripts/ci/cluster-cell.sh "$CELL")\n          [ "$CELL" = a ] || files="{b}"\n'),
    "listed": ("s", "  b) files=$(LC_ALL=C comm -23", f'  b) files="{b}"; : $(LC_ALL=C comm -23'),
    "absent": ("s", "cell_a=(\n", "cell_a=(\n  apps/cyfr/test/cluster/planted_test.exs\n"),
}
where, old, new = edits[kind]
target = w if where == "w" else s
assert target.count(old) == 1, old
target = target.replace(old, new)
open(f"{out}/cells.yml", "w").write(target if where == "w" else w)
open(f"{out}/cells.sh", "w").write(target if where == "s" else s)
PY
}
while IFS='|' read -r kind want; do
  label="test.yml: the cluster check refuses $kind ($want)"
  plant_cells "$kind"
  cluster_cells "$scratch/cells.yml" "$scratch/cells.sh" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qF "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
third|the cluster matrix is {'cell': ['a', 'b', 'c']}, not the cells a and b alone
constant|the cluster job's step "The cell's files" is
restated|the cluster job's step "The cell's files" is
listed|the added files are not b's alone
absent|cell a lists files the suite does not have: apps/cyfr/test/cluster/planted_test.exs
CASES

# partition_groups WORKFLOW SCRIPT: the harness-tests-partitions matrix is
# the groups SCRIPT names (--groups), and the job's one step that runs
# the partition runner's test is exactly its run with the matrix's group.
partition_groups() {
  python3 -I - "$1" "$(bash "$2" --groups)" <<'PY'
import sys, yaml
wf, groups = sys.argv[1], sys.argv[2].split()
job = yaml.safe_load(open(wf))["jobs"]["harness-tests-partitions"]
matrix = job.get("strategy", {}).get("matrix", {})
if matrix != {"group": groups}:
    print(f"the partitions matrix is {matrix}, and the test's groups are {' '.join(groups)}")
want = {"name": "The partition runner's cases of this group", "env": {"GROUP": "${{ matrix.group }}"},
        "run": 'bash tests/test-partitioned-test.sh "$GROUP"'}
runs = [s for s in job["steps"] if "test-partitioned-test.sh" in str(s.get("run", ""))]
if runs != [want]:
    print(f"the partitions job runs the test in {runs}, not once in {want}")
PY
}
label="test.yml: the partitions matrix is the partition runner test's groups, each run alone"
partition_groups "$root/.github/workflows/test.yml" "$root/tests/test-partitioned-test.sh" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
# Planted: a group the matrix alone gained, one the test alone gained, the
# group only in a comment, a second run without it in the same step, and
# a second step that runs the whole test.
plant_groups() { # KIND: writes groups.yml and groups-test.sh, one of them planted
  python3 -I - "$root/.github/workflows/test.yml" "$root/tests/test-partitioned-test.sh" "$scratch" "$1" <<'PY'
import sys
wf, script, out, kind = sys.argv[1:]
w, s = open(wf).read(), open(script).read()
run = '        run: bash tests/test-partitioned-test.sh "$GROUP"\n'
edits = {
    "matrix": ("w", "        group: [report, rest]\n", "        group: [report, rest, more]\n"),
    "test": ("s", "TEST_GROUPS='report rest'\n", "TEST_GROUPS='report rest more'\n"),
    "comment": ("w", run, '        run: |\n          bash tests/test-partitioned-test.sh # "$GROUP"\n'),
    "second": ("w", run, '        run: |\n          bash tests/test-partitioned-test.sh "$GROUP"\n          bash tests/test-partitioned-test.sh\n'),
    "step": ("w", run, run + "      - name: The whole test\n        run: bash tests/test-partitioned-test.sh\n"),
}
where, old, new = edits[kind]
target = w if where == "w" else s
assert target.count(old) == 1, old
target = target.replace(old, new)
open(f"{out}/groups.yml", "w").write(target if where == "w" else w)
open(f"{out}/groups-test.sh", "w").write(target if where == "s" else s)
PY
}
while IFS='|' read -r kind want; do
  label="test.yml: the partitions check refuses $kind ($want)"
  plant_groups "$kind"
  partition_groups "$scratch/groups.yml" "$scratch/groups-test.sh" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qF "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
matrix|the partitions matrix is {'group': ['report', 'rest', 'more']}, and the test's groups are report rest
test|the partitions matrix is {'group': ['report', 'rest']}, and the test's groups are report rest more
comment|the partitions job runs the test in
second|the partitions job runs the test in
step|the partitions job runs the test in
CASES

# plant WORKFLOW OLD NEW: .github/workflows/WORKFLOW with OLD, which it
# holds once, replaced by NEW, written to $scratch/planted.yml; a \n in
# OLD or NEW is a newline.
plant() {
  rm -f "$scratch/planted.yml"
  python3 -I - "$root/.github/workflows/$1" "$scratch/planted.yml" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:]
old, new = old.replace("\\n", "\n"), new.replace("\\n", "\n")
s = open(src).read()
assert s.count(old) == 1, old
open(dst, "w").write(s.replace(old, new))
PY
}

# elixir_shards WORKFLOW: the test job's matrix is both adapters by shards 1
# to N, where N is the count its Run tests step names, so the shards are
# the whole split; and the dev compile runs on one shard the matrix has,
# on both adapters alike.
elixir_shards() {
  python3 -I - "$1" <<'PY'
import re, sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["test"]
matrix = job["strategy"]["matrix"]
run = next(s["run"] for s in job["steps"] if s.get("name") == "Run tests")
counts = re.findall(r'--shard "\$\{\{ matrix\.shard \}\}/([1-9][0-9]*)"', run)
if len(counts) != 1:
    print("Run tests names no one shard of N")
elif matrix.get("shard") != list(range(1, int(counts[0]) + 1)):
    print(f"the shards are {matrix.get('shard')}, not 1 to {counts[0]}")
if matrix.get("db") != ["sqlite", "postgres"]:
    print(f"the adapters are {matrix.get('db')}, not sqlite and postgres")
if sorted(matrix) != ["db", "shard"]:
    print(f"the matrix has {sorted(matrix)}, not db and shard alone")
dev = next(s for s in job["steps"] if s.get("name") == "Compile the dev target with warnings as errors")
cond = str(dev.get("if", "")).strip()
m = re.fullmatch(r"\$\{\{(.*)\}\}", cond, re.S)
cond = (m.group(1) if m else cond).strip()
m = re.fullmatch(r"matrix\.shard == ([1-9][0-9]*)", cond)
if m is None or int(m[1]) not in matrix.get("shard", []):
    print(f"the dev compile runs under {cond or 'no condition'!r}, not on one shard of each adapter")
PY
}
label="test.yml: the Elixir shards are the whole split on both adapters, and the dev compile runs on one shard of each"
elixir_shards "$root/.github/workflows/test.yml" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
while IFS='|' read -r kind old new want; do
  label="test.yml: the shards check refuses $kind ($want)"
  plant test.yml "$old" "$new"
  elixir_shards "$scratch/planted.yml" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qxF -- "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
a dropped shard|        shard: [1, 2, 3, 4]|        shard: [1, 2, 3]|the shards are [1, 2, 3], not 1 to 4
another count|--shard "${{ matrix.shard }}/4"|--shard "${{ matrix.shard }}/5"|the shards are [1, 2, 3, 4], not 1 to 5
the dev compile on every shard|        if: matrix.shard == 1\n|\n|the dev compile runs under 'no condition', not on one shard of each adapter
the dev compile on a shard the matrix lacks|        if: matrix.shard == 1\n|        if: matrix.shard == 5\n|the dev compile runs under 'matrix.shard == 5', not on one shard of each adapter
the dev compile on one adapter|        if: matrix.shard == 1\n|        if: matrix.shard == 1 && matrix.db == 'sqlite'\n|the dev compile runs under "matrix.shard == 1 && matrix.db == 'sqlite'", not on one shard of each adapter
CASES

# browser_viewports WORKFLOW: across the browser and browser-tincture
# matrices no shard is listed twice, and no two shards run one proof at
# one viewport (a shard with no viewport runs its proofs at every
# viewport they take).
browser_viewports() {
  python3 -I - "$1" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
rows = {}
for job in ("browser", "browser-tincture"):
    for e in jobs[job]["strategy"]["matrix"]["include"]:
        if e["shard"] in rows:
            print(f"test.yml lists browser shard {e['shard']} twice")
        rows[e["shard"]] = e
where = {}
for shard, e in sorted(rows.items()):
    for proof in e.get("proofs", []):
        where.setdefault(proof, []).append((shard, e.get("viewport")))
for proof, at in sorted(where.items()):
    views = [v for _, v in at]
    if len(at) > 1 and (None in views or len(set(views)) != len(views)):
        print(f"the {proof} proof runs at one viewport in more than one shard: {', '.join(s for s, _ in at)}")
PY
}
label="test.yml: no two browser shards run one proof at one viewport"
browser_viewports "$root/.github/workflows/test.yml" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
while IFS='|' read -r kind row want; do
  label="test.yml: the browser shards check refuses $kind ($want)"
  plant test.yml '    steps: &browser-steps\n' "$row    steps: &browser-steps\n"
  browser_viewports "$scratch/planted.yml" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qxF -- "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
a second shard of approval at the desktop|          - shard: i\n            title: approval proof, desktop again\n            proofs: [approval]\n            build: release\n            viewport: desktop\n|the approval proof runs at one viewport in more than one shard: e, f, i
a shard listed twice|          - shard: b\n            title: the markdown proof\n            proofs: [markdown]\n            build: markdown\n|test.yml lists browser shard b twice
CASES

# app_groups WORKFLOW: each group of the app-image-suites and
# app-image-locus-suites matrices is listed once, and its job needs the
# producer of each image its `images` name and no other; each case a step
# of the jobs names (contains(matrix.cases, ...)) is in exactly one
# group's cases, and each case a group lists is a step's.
app_groups() {
  python3 -I - "$1" <<'PY'
import re, sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
producers = {"app": "app-image", "locus": "locus-image"}
groups, steps, listed = [], set(), {}
for name in ("app-image-suites", "app-image-locus-suites"):
    job = jobs[name]
    needs = job.get("needs", [])
    needs = sorted([needs] if isinstance(needs, str) else needs)
    steps |= {k for st in job["steps"] for k in re.findall(r"contains\(matrix\.cases, '([a-z0-9-]+)'\)", str(st.get("if", "")))}
    for e in job["strategy"]["matrix"]["include"]:
        groups.append(e["group"])
        want = sorted(producers[i] for i in e.get("images", []))
        if needs != want:
            print(f"group {e['group']} runs the images {', '.join(e.get('images', []))}, and its job {name} needs {', '.join(needs) or 'nothing'}")
        for c in e.get("cases", []):
            listed.setdefault(c, []).append(e["group"])
for g in sorted({g for g in groups if groups.count(g) > 1}):
    print(f"test.yml lists app image group {g} twice")
for c in sorted(steps):
    if len(listed.get(c, [])) != 1:
        print(f"the case {c} is in {len(listed.get(c, []))} groups, not one: {', '.join(listed.get(c, [])) or 'none'}")
for c in sorted(set(listed) - steps):
    print(f"group {', '.join(listed[c])} lists the case {c}, which no step runs")
PY
}
label="test.yml: each app image case runs in one group, each group on the producers of its images alone"
app_groups "$root/.github/workflows/test.yml" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
while IFS='|' read -r kind old new want; do
  label="test.yml: the app image groups check refuses $kind ($want)"
  plant test.yml "$old" "$new"
  app_groups "$scratch/planted.yml" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qxF -- "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
a case in two groups|            cases: [bind, restore-identity]\n|            cases: [bind, restore-identity]\n          - group: d\n            title: bind again\n            images: [app]\n            cases: [bind]\n|the case bind is in 2 groups, not one: c, d
a case in no group|            cases: [interrupt, restore, restore-person, scan]\n|            cases: [interrupt, restore-person, scan]\n|the case restore is in 0 groups, not one: none
a case no step runs|            cases: [interrupt, restore, restore-person, scan]\n|            cases: [interrupt, restore, restore-person, scan, planted]\n|group a lists the case planted, which no step runs
a job without a producer|    needs: [locus-image, app-image]\n|    needs: app-image\n|group both runs the images locus, app, and its job app-image-locus-suites needs app-image
CASES

# --- what lets a check pass ---

# fixture_workflow NAME: writes $scratch/fixture/NAME.yml from stdin, in a
# directory holding that one workflow (rm'd first), for the planted cases.
fixture_workflow() {
  rm -rf "$scratch/fixture" && mkdir -p "$scratch/fixture" && cat > "$scratch/fixture/$1.yml"
}

# trivy_scans WORKFLOW_DIR: every aquasecurity/trivy-action step of every
# workflow pins its trivy release (`version: vX.Y.Z`), all the same one (a
# step with no version installs whatever trivy is latest), fails on a
# finding (exit-code 1) and reads only inputs this check knows. An image
# scan (image-ref) fails on CRITICAL and HIGH, fixed or not yet fixable
# alike (ignore-unfixed), past .trivyignore.yaml's exceptions alone; a
# repository scan (scan-type fs) reads the whole tree, a secret scan
# failing on any secret and a misconfiguration scan on CRITICAL and HIGH
# past .trivyignore.yaml's exceptions. Each error is a line.
trivy_scans() {
  python3 -I - "$1" <<'PY'
import glob, os, re, sys, yaml
INPUTS = {"version", "image-ref", "scan-type", "scan-ref", "scanners", "format", "exit-code", "severity",
          "ignore-unfixed", "trivyignores"}
IMAGE = {"severity": "CRITICAL,HIGH", "ignore-unfixed": "true", "trivyignores": ".trivyignore.yaml"}
FS = {"secret": {}, "misconfig": {"severity": "CRITICAL,HIGH", "trivyignores": ".trivyignore.yaml"}}
pins = set()
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.yml"))):
    for job, body in (yaml.safe_load(open(path)).get("jobs") or {}).items():
        for step in body.get("steps") or []:
            if str(step.get("uses", "")).split("@")[0] != "aquasecurity/trivy-action":
                continue
            where = f"{os.path.basename(path)} {job}: '{step.get('name', 'a trivy-action step')}'"
            given = {k: str(v).lower() if isinstance(v, bool) else str(v) for k, v in (step.get("with") or {}).items()}
            version = given.get("version", "")
            if re.fullmatch(r"v\d+\.\d+\.\d+", version):
                pins.add(version)
            else:
                print(f"{where} pins {version or 'no version'}, not one vX.Y.Z")
            for k in sorted(set(given) - INPUTS):
                print(f"{where} sets {k}, an input this check does not read")
            if given.get("exit-code") != "1":
                print(f"{where} exits {given.get('exit-code', 'with no exit-code')} on a finding, not 1")
            if "image-ref" in given:
                want = IMAGE
                if given.get("scan-type", "image") != "image" or "scanners" in given:
                    print(f"{where} scans an image as {given.get('scan-type')} {given.get('scanners', '')}".rstrip())
            elif given.get("scan-type") == "fs" and given.get("scanners") in FS:
                want = FS[given["scanners"]]
                if given.get("scan-ref", ".") != ".":
                    print(f"{where} scans {given['scan-ref']}, not the whole tree")
            else:
                print(f"{where} is neither an image scan nor a secret or misconfiguration scan of the tree")
                continue
            for k in ("severity", "ignore-unfixed", "trivyignores"):
                if given.get(k) != want.get(k):
                    print(f"{where} sets {k} to {given.get(k, 'nothing')}, not {want.get(k, 'nothing')}")
if len(pins) > 1:
    print(f"the trivy-action steps pin {', '.join(sorted(pins))}, not one release")
if not pins:
    print("no trivy-action step pins a release")
PY
}
label="workflows: every trivy scan pins one release, fails on a finding, and reads what it should"
trivy_scans "$root/.github/workflows" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
# trivy_fixture [EDIT]: a workflow of one image scan, one secret scan and
# one misconfiguration scan, each as the check wants it, with EDIT (a sed
# expression) applied.
trivy_fixture() {
  fixture_workflow scans <<'YML'
jobs:
  image:
    steps:
      - name: Scan the image
        uses: aquasecurity/trivy-action@0000000000000000000000000000000000000000
        with:
          version: v1.2.3
          image-ref: fixture:ci
          format: table
          exit-code: '1'
          severity: CRITICAL,HIGH
          ignore-unfixed: true
          trivyignores: .trivyignore.yaml
  repo:
    steps:
      - name: Secret scan
        uses: aquasecurity/trivy-action@0000000000000000000000000000000000000000
        with:
          version: v1.2.3
          scan-type: fs
          scanners: secret
          format: table
          exit-code: '1'
      - name: Misconfiguration scan
        uses: aquasecurity/trivy-action@0000000000000000000000000000000000000000
        with:
          version: v1.2.3
          scan-type: fs
          scanners: misconfig
          format: table
          exit-code: '1'
          severity: CRITICAL,HIGH
          trivyignores: .trivyignore.yaml
YML
  [ -z "${1:-}" ] || sed -i -e "$1" "$scratch/fixture/scans.yml"
}
label="workflows: the trivy check passes the fixture's three scans"
trivy_fixture
trivy_scans "$scratch/fixture" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
while IFS='|' read -r kind edit want; do
  label="workflows: the trivy check refuses $kind ($want)"
  trivy_fixture "$edit"
  trivy_scans "$scratch/fixture" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qxF -- "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
a step with no version|0,/version: v1.2.3/{/version: v1.2.3/d}|scans.yml image: 'Scan the image' pins no version, not one vX.Y.Z
a second release|/name: Misconfiguration scan/,/version:/s/version: v1.2.3/version: v1.2.4/|the trivy-action steps pin v1.2.3, v1.2.4, not one release
a scan that passes on a finding|0,/exit-code: '1'/s/exit-code: '1'/exit-code: '0'/|scans.yml image: 'Scan the image' exits 0 on a finding, not 1
an image scan that lets HIGH through|0,/severity: CRITICAL,HIGH/s/severity: CRITICAL,HIGH/severity: CRITICAL/|scans.yml image: 'Scan the image' sets severity to CRITICAL, not CRITICAL,HIGH
an image scan that drops the unfixed|/ignore-unfixed: true/d|scans.yml image: 'Scan the image' sets ignore-unfixed to nothing, not true
a secret scan given a floor|/scanners: secret/a\          severity: CRITICAL|scans.yml repo: 'Secret scan' sets severity to CRITICAL, not nothing
a misconfiguration scan with another ignore file|$s/trivyignores: .trivyignore.yaml/trivyignores: other.yaml/|scans.yml repo: 'Misconfiguration scan' sets trivyignores to other.yaml, not .trivyignore.yaml
a repository scan of one directory|/scanners: secret/a\          scan-ref: apps|scans.yml repo: 'Secret scan' scans apps, not the whole tree
an input the check does not read|/scanners: secret/a\          skip-dirs: apps|scans.yml repo: 'Secret scan' sets skip-dirs, an input this check does not read
CASES

# advisory_steps WORKFLOW_DIR: no job sets continue-on-error, and a step
# sets it only as an advisory check does, informational exactly when
# scripts/ci/world-checks.sh says so (WORLD below, in a job that runs that
# script in an earlier step with id world), or as the one step that
# publishes and checks nothing, release.yml's Homebrew cask. Any other
# continue-on-error lets a failed check pass. Each error is a line.
advisory_steps() {
  python3 -I - "$1" <<'PY'
import glob, os, sys, yaml
WORLD = "${{ steps.world.outputs.informational == 'true' }}"
PUBLISHES = {("release.yml", "release", "Publish Homebrew cask to tap"): True}
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.yml"))):
    wf = os.path.basename(path)
    for job, body in (yaml.safe_load(open(path)).get("jobs") or {}).items():
        if "continue-on-error" in body:
            print(f"{wf} {job}: the job sets continue-on-error")
        world = False
        for step in body.get("steps") or []:
            where = f"{wf} {job}: '{step.get('name', step.get('uses', 'a step'))}'"
            if "continue-on-error" in step:
                value = step["continue-on-error"]
                if (wf, job, step.get("name")) in PUBLISHES and value == PUBLISHES[(wf, job, step.get("name"))]:
                    pass
                elif value != WORLD:
                    print(f"{where} sets continue-on-error: {value}")
                elif not world:
                    print(f"{where} is advisory with no world-checks step before it")
            if step.get("id") == "world" and str(step.get("run", "")).strip() == "scripts/ci/world-checks.sh":
                world = True
PY
}
label="workflows: a failed check fails its job, save an advisory check the world checks release"
advisory_steps "$root/.github/workflows" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
# advisory_fixture [EDIT]: a job whose scan is advisory after its world
# step, and the release job's Homebrew cask, with EDIT applied.
advisory_fixture() {
  fixture_workflow release <<'YML'
jobs:
  image:
    steps:
      - name: Whether the advisory checks block this run
        id: world
        run: scripts/ci/world-checks.sh
      - name: Scan the image
        continue-on-error: ${{ steps.world.outputs.informational == 'true' }}
        run: "true"
      - name: Run the suite
        run: "true"
  release:
    steps:
      - name: Publish Homebrew cask to tap
        continue-on-error: true
        run: "true"
YML
  [ -z "${1:-}" ] || sed -i -e "$1" "$scratch/fixture/release.yml"
}
label="workflows: the advisory check passes the fixture's advisory scan and the cask"
advisory_fixture
advisory_steps "$scratch/fixture" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
while IFS='|' read -r kind edit want; do
  label="workflows: the advisory check refuses $kind ($want)"
  advisory_fixture "$edit"
  advisory_steps "$scratch/fixture" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qxF -- "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
a scan that always passes|s/continue-on-error: \${{ steps.world.outputs.informational == 'true' }}/continue-on-error: true/|release.yml image: 'Scan the image' sets continue-on-error: True
a suite that may fail|/name: Run the suite/a\        continue-on-error: true|release.yml image: 'Run the suite' sets continue-on-error: True
an advisory step with no world step|/id: world/d|release.yml image: 'Scan the image' is advisory with no world-checks step before it
a job that may fail|/^  image:/a\    continue-on-error: true|release.yml image: the job sets continue-on-error
another publishing step that may fail|s/name: Publish Homebrew cask to tap/name: Publish the notes/|release.yml release: 'Publish the notes' sets continue-on-error: True
CASES

# minio_digest WORKFLOW: the cluster job and the S3 adapter's job start the
# object store from one pinned image: every pgsty/silo reference in
# WORKFLOW names one sha256 digest, and both jobs hold it. Each error is a
# line.
minio_digest() {
  python3 -I - "$1" <<'PY'
import re, sys, yaml
text = open(sys.argv[1]).read()
jobs = yaml.safe_load(text)["jobs"]
refs = re.findall(r"pgsty/silo[@:][^\s\"']*", text)
pinned = sorted({r for r in refs if re.fullmatch(r"pgsty/silo@sha256:[0-9a-f]{64}", r)})
for r in sorted(set(refs) - set(pinned)):
    print(f"test.yml names the MinIO image unpinned: {r}")
if len(pinned) != 1:
    print(f"test.yml names the MinIO image by {len(pinned)} digests, not one: {' '.join(pinned)}")
for job in ("cluster", "s3-minio"):
    if not any(p in yaml.safe_dump(jobs.get(job, {}), width=1000) for p in pinned):
        print(f"the {job} job starts no MinIO image of the pinned digest")
PY
}
label="test.yml: the cluster and S3 jobs start MinIO from one pinned digest"
minio_digest "$root/.github/workflows/test.yml" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
# minio_plant KIND: test.yml with the S3 job's digest changed (other) or
# the cluster job's image unpinned (tag), to $scratch/planted.yml.
minio_plant() {
  python3 -I - "$root/.github/workflows/test.yml" "$scratch/planted.yml" "$1" <<'PY'
import re, sys
src, dst, kind = sys.argv[1:]
s = open(src).read()
spans = [m.span() for m in re.finditer(r"pgsty/silo@sha256:[0-9a-f]{64}", s)]
assert len(spans) >= 2, spans
start, end = spans[-1] if kind == "other" else spans[0]
new = s[start:end - 1] + ("0" if s[end - 1] != "0" else "1") if kind == "other" else "pgsty/silo:latest"
open(dst, "w").write(s[:start] + new + s[end:])
PY
}
while IFS='|' read -r kind want; do
  label="test.yml: the MinIO check refuses $kind ($want)"
  minio_plant "$kind"
  minio_digest "$scratch/planted.yml" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qF -- "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
other|test.yml names the MinIO image by 2 digests, not one:
tag|test.yml names the MinIO image unpinned: pgsty/silo:latest
CASES

# npm_audit SCRIPT TREE: security.yml's audit step, its script SCRIPT run
# in TREE with a stand-in for scripts/security-scan.sh, audits every
# package-lock.json under TREE/seed/components outside node_modules once,
# each with an audit level no laxer than high, and fails when one audit
# fails; with no lockfile it fails. Each error is a line.
NPM_STEP='Audit every shipped lockfile'
npm_audit_script() { # WORKFLOW: the npm-audit job's audit step's script
  python3 -I - "$1" "$NPM_STEP" <<'PY'
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["npm-audit"]
print(next(s["run"] for s in job["steps"] if s.get("name") == sys.argv[2]))
PY
}
npm_audit() {
  local script=$1 tree=$2 ws="$scratch/npm-ws" want got status
  rm -rf "$ws" && mkdir -p "$ws/scripts"
  printf '#!/usr/bin/env bash\necho "$PWD|$*" >> "%s/calls"\n[ "${NPM_FAIL:-}" != "$PWD" ]\n' "$ws" > "$ws/scripts/security-scan.sh"
  want=$(cd "$tree" && find seed/components -name package-lock.json -not -path '*/node_modules/*' | sort | sed "s|^|$tree/|; s|/package-lock.json$||")
  [ -n "$want" ] || { echo "$tree holds no shipped lockfile"; return 0; }
  status=0; (cd "$tree" && GITHUB_WORKSPACE="$ws" bash -c "$script") >/dev/null 2>&1 || status=$?
  [ "$status" = 0 ] || echo "the audit step exited $status with every audit passing"
  got=$(cut -d'|' -f1 "$ws/calls" 2>/dev/null | sort)
  [ "$got" = "$want" ] || echo "the audit step audited $(printf '%s' "$got" | grep -c .) of $(printf '%s\n' "$want" | grep -c .) lockfiles"
  while IFS='|' read -r dir args; do
    case "$args " in
      "npm audit "*"--audit-level=critical "* | "npm audit "*"--audit-level critical "* | "npm audit "*"--audit-level=none "* | \
        "npm audit "*"--audit-level none "*) echo "$dir is audited at a laxer level: $args" ;;
      "npm audit "*) ;;
      *) echo "$dir is audited by something other than npm audit: $args" ;;
    esac
  done < "$ws/calls"
  rm -f "$ws/calls"
  status=0; (cd "$tree" && NPM_FAIL="$(printf '%s\n' "$want" | head -n 1)" GITHUB_WORKSPACE="$ws" bash -c "$script") >/dev/null 2>&1 || status=$?
  [ "$status" != 0 ] || echo "the audit step passed with an audit failing"
  mkdir -p "$scratch/npm-empty/seed/components"
  status=0; (cd "$scratch/npm-empty" && GITHUB_WORKSPACE="$ws" bash -c "$script") >/dev/null 2>&1 || status=$?
  [ "$status" != 0 ] || echo "the audit step passed with no lockfile to read"
}
npm_audit_script "$root/.github/workflows/security.yml" > "$scratch/npm-step.sh" || fail "security.yml has no npm-audit step '$NPM_STEP'"
label="security.yml: the npm audit reads every shipped lockfile and fails on a failed audit"
npm_audit "$(cat "$scratch/npm-step.sh")" "$root" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
# A tree of two shipped lockfiles and one under node_modules, and the
# step's script with a protection taken out.
mkdir -p "$scratch/npm-tree/seed/components/a/1.0.0" "$scratch/npm-tree/seed/components/b/2.0.0/x" \
  "$scratch/npm-tree/seed/components/b/2.0.0/node_modules/dep"
for d in a/1.0.0 b/2.0.0/x b/2.0.0/node_modules/dep; do echo '{}' > "$scratch/npm-tree/seed/components/$d/package-lock.json"; done
while IFS='#' read -r kind old new want; do
  label="security.yml: the npm audit check refuses $kind ($want)"
  python3 -I - "$scratch/npm-step.sh" "$old" "$new" > "$scratch/npm-planted.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
old, new = sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
assert s.count(old) == 1, old
print(s.replace(old, new), end="")
PY
  npm_audit "$(cat "$scratch/npm-planted.sh")" "$scratch/npm-tree" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qF -- "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
a step that audits one lockfile#for lock in "${locks[@]}"; do#for lock in "${locks[0]}"; do#the audit step audited 1 of 2 lockfiles
a step at a laxer level#--audit-level=high#--audit-level=critical#is audited at a laxer level
a step that passes on a failed audit#) || status=1#) || :#the audit step passed with an audit failing
a step that passes with no lockfile#  exit 1\n#  exit 0\n#the audit step passed with no lockfile to read
CASES

# --- the image builds' layer cache ---

# cache_boundary WORKFLOW_DIR: the layer cache's credential is one
# workflow's. No workflow asks for packages: write (nor write-all) but
# layer-cache.yml's writer and release.yml's publishing jobs; test.yml and
# release.yml write no layer cache, neither a cache-to of their own nor
# .github/actions/image-build with write other than 'false'; and
# layer-cache.yml runs on a push to main and on a schedule, nothing else.
# Each error is a line.
cache_boundary() {
  python3 -I - "$1" <<'PY'
import glob, os, sys, yaml
WRITERS = {("layer-cache.yml", "write"), ("release.yml", "images"), ("release.yml", "merge")}
def writes_packages(perms):
    return perms == "write-all" or (isinstance(perms, dict) and perms.get("packages") == "write")
# GitHub runs a workflow file of either extension.
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.yml")) + glob.glob(os.path.join(sys.argv[1], "*.yaml"))):
    wf = os.path.basename(path)
    doc = yaml.safe_load(open(path)) or {}
    if writes_packages(doc.get("permissions")):
        print(f"{wf}: the workflow asks for packages: write")
    for job, body in (doc.get("jobs") or {}).items():
        if writes_packages(body.get("permissions")) and (wf, job) not in WRITERS:
            print(f"{wf} {job}: the job asks for packages: write")
        if wf not in ("test.yml", "release.yml"):
            continue
        for step in body.get("steps") or []:
            where = f"{wf} {job}: '{step.get('name', step.get('uses', 'a step'))}'"
            given = step.get("with") or {}
            if "cache-to" in given:
                print(f"{where} writes a layer cache")
            if step.get("uses") == "./.github/actions/image-build" and str(given.get("write")) != "false":
                print(f"{where} builds with write {given.get('write')}, not 'false'")
    if wf == "layer-cache.yml":
        # PyYAML reads the bare key on as True.
        on = doc.get("on", doc.get(True))
        if not (isinstance(on, dict) and set(on) == {"push", "schedule"} and on["push"] == {"branches": ["main"]}
                and isinstance(on["schedule"], list) and on["schedule"]):
            print(f"layer-cache.yml runs on {on}, not a push to main and a schedule alone")
PY
}
label="workflows: only the layer cache's writer and release's publishing write a package, and only the writer writes the cache"
cache_boundary "$root/.github/workflows" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
while IFS='|' read -r kind wf body want; do
  label="workflows: the layer cache's boundary check refuses $kind"
  rm -rf "$scratch/fixture" && mkdir -p "$scratch/fixture" && printf '%b' "$body" > "$scratch/fixture/$wf"
  cache_boundary "$scratch/fixture" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qxF -- "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
a Test job that writes a package|test.yml|jobs:\n  image:\n    permissions:\n      packages: write\n    steps: []\n|test.yml image: the job asks for packages: write
a release build that writes a cache|release.yml|jobs:\n  images:\n    steps:\n      - name: Build\n        with:\n          cache-to: type=registry,ref=example/cache:app\n|release.yml images: 'Build' writes a layer cache
a writer a pull request starts|layer-cache.yml|on:\n  push:\n    branches: [main]\n  schedule:\n    - cron: '7 0 * * *'\n  pull_request:\njobs: {}\n|layer-cache.yml runs on {'push': {'branches': ['main']}, 'schedule': [{'cron': '7 0 * * *'}], 'pull_request': None}, not a push to main and a schedule alone
a .yaml workflow that writes a package|plant.yaml|jobs:\n  image:\n    permissions:\n      packages: write\n    steps: []\n|plant.yaml image: the job asks for packages: write
CASES

# --- the proofs' run prefix ---

# run_prefixes ROOT: every script that names what it makes after its run
# reads PROOF_RUN_PREFIX in the expressions that name it, and no tracked
# script under ROOT's tests/ or scripts/ makes a directory under TMPDIR
# named cyfr-... without the prefix before it. Each error is a line. Read
# as text, it passes a new `docker run` or `docker create` with no --name
# under the prefix, whose container then outlives a killed run.
# FILE:EXPRESSION, each a script and the expression that names what it makes.
PREFIX_SPECS=(
  'tests/compose-proof/run.sh:RUN="${PROOF_RUN_PREFIX:-}cyfr-compose-proof-'
  'tests/compose-proof/run.sh:STANDIN_IMAGE="${PROOF_RUN_PREFIX:-}cyfr-tailscale-standin:'
  'tests/setup-proof/app.sh:RUN="${PROOF_RUN_PREFIX:-}cyfr-setup-app-'
  'tests/compose-proof/tailscale-standin/proof.sh:RUN="${PROOF_RUN_PREFIX:-}cyfr-standin-proof-'
  'tests/compose-proof/tailscale-standin/proof.sh:IMAGE="${PROOF_RUN_PREFIX:-}cyfr-tailscale-standin:'
  'tests/identity-proof/front.sh:name="${PROOF_RUN_PREFIX:-}cyfr-identity-front-'
  'tests/proxy-hsts/run.sh:RUN="${PROOF_RUN_PREFIX:-}cyfr-proxy-hsts-'
  'tests/release-boot/boot.sh:${PROOF_RUN_PREFIX:+--name "${PROOF_RUN_PREFIX}cyfr-release-boot-$RUN_ID-ns"}'
  'tests/release-boot/boot.sh:${PROOF_RUN_PREFIX:+--name "${PROOF_RUN_PREFIX}cyfr-release-boot-$RUN_ID-reserve"}'
  'tests/browser/harness.sh:${PROOF_RUN_PREFIX:+--name "${PROOF_RUN_PREFIX}cyfr-playwright-$$-'
  'tests/imagesuite.py:PROJECT_PREFIX = os.environ.get("PROOF_RUN_PREFIX", "")'
  'tests/imagesuite.py:tempfile.mkdtemp(prefix=PROJECT_PREFIX + prefix)'
)
run_prefixes() {
  local spec f want unprefixed
  for spec in "${PREFIX_SPECS[@]}"; do
    f=${spec%%:*} want=${spec#*:}
    grep -qF -- "$want" "$1/$f" || echo "$f names what it makes without the run prefix: no $want"
  done
  unprefixed=$(cd "$1" && git grep -n 'mktemp[^"]*"${TMPDIR:-/tmp}/cyfr-' -- tests scripts) || :
  [ -z "$unprefixed" ] || echo "a directory a script makes under TMPDIR is named without the run prefix: $unprefixed"
}
label="proofs: the scripts that name what they make after their run read PROOF_RUN_PREFIX for it"
run_prefixes "$root" > "$scratch/out" 2> "$scratch/err"
code=$?
if [ "$code" -eq 0 ] && quiet; then pass "$label"; else fail "$label"; fi
# Planted, in a repository holding the scripts' copies: the HSTS proof's
# run named under no prefix, and a script making an unprefixed directory.
new_repo
for spec in "${PREFIX_SPECS[@]}"; do f=${spec%%:*}; mkdir -p "$(dirname "$f")" && cp "$root/$f" "$f"; done
sed -i 's/RUN="${PROOF_RUN_PREFIX:-}cyfr-proxy-hsts-/RUN="cyfr-proxy-hsts-/' tests/proxy-hsts/run.sh
printf 'd=$(mktemp -d "${TMPDIR:-/tmp}/%s")\n' cyfr-planted.XXXXXX > tests/planted.sh
commit planted
cd "$root" || exit 1
while IFS='|' read -r kind want; do
  label="proofs: the run prefix check refuses $kind ($want)"
  run_prefixes "$repo" > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -eq 0 ] && grep -qF -- "$want" "$scratch/out"; then pass "$label"; else fail "$label"; fi
done <<'CASES'
a run named under no prefix|tests/proxy-hsts/run.sh names what it makes without the run prefix: no RUN="${PROOF_RUN_PREFIX:-}cyfr-proxy-hsts-
an unprefixed directory under TMPDIR|a directory a script makes under TMPDIR is named without the run prefix: tests/planted.sh:1:
CASES

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
# job 71's log names ExUnit failures, one twice, and harness and desktop
# proof FAIL lines under the runner's timestamps, with a mention and a link, after a step
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
    "2026-11-18T10:00:04.1000000Z PASS first_open: a CYFR just connected opens at its root",
    "2026-11-18T10:00:04.2000000Z FAIL device_lock: the device's Lock ends its session {\"held\":false}",
    "2026-11-18T10:00:04.3000000Z FAIL refused --no-sandbox: exit 0",
    "2026-11-18T10:00:04.4000000Z FAILED to read nothing: not a row",
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
         "        FAIL device_lock: the device's Lock ends its session {\"held\":false}",
         "        FAIL refused --no-sandbox: exit 0",
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
  reds_run nightly OUTCOME="$1" COMMIT="$sha" STATUS="$2" LOGS=/var/tmp/cyfr/cyfr-stage.nightly.Ab1sCd \
    SUMMARY=$'janitor: ok 9s\nhandle-proof: failed 1 312s\ncanvas-proof-desktop: not run 69 0s' RUN_URL=https://example.invalid/runs/9
}
label="reds: a red night opens the nightly issue naming the commit, the exit, the rows that did not pass and the host's log folder"
reds_state "1 open $silent"
night failure 1
if [ "$code" -eq 0 ] && state '[i["comments"] for i in issues["Host nightly is red"]] == [["The host'"'"'s [nightly report](https://example.invalid/runs/9) failed:\n\n" + "\n".join([
  "    commit: '"$sha"'", "    exit: 1", "    logs on the host: /var/tmp/cyfr/cyfr-stage.nightly.Ab1sCd", "    rows that did not pass:",
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

# A command line that calls the tests' cheap key derivation, built as the
# release builds it: the file is laid over the tree and never written to it.
cat > "$scratch/cheap-caller.go" <<'GO'
package main

import "github.com/cyfr/codex/internal/holder"

func init() { holder.CheapDerivationForTests() }
GO
printf '{"Replace":{"%s/apps/codex/zz_cheap_caller.go":"%s/cheap-caller.go"}}' "$root" "$scratch" > "$scratch/cheap-overlay.json"
cheap_built=1
(cd "$root/apps/codex" &&
  CGO_ENABLED=0 go build -mod=readonly -overlay "$scratch/cheap-overlay.json" \
    -ldflags "-s -w -X github.com/cyfr/codex/internal/version.Version=0.1.0" -o "$bins/cheap" .) > "$scratch/out" 2> "$scratch/err" || cheap_built=0
code=$cheap_built

label="release-binary-check refuses a binary that can reach the cheap key derivation"
if [ "$cheap_built" = 1 ]; then
  run "$binary_check" "$bins/cheap"
  check refused "holds the tests' cheap key derivation"
else
  fail "$label (the command line did not build)"
fi

label="the cheap key derivation refuses by name in the command line built as the release builds it"
if [ "$cheap_built" = 1 ]; then
  "$bins/cheap" version > "$scratch/out" 2> "$scratch/err"
  code=$?
  if [ "$code" -ne 0 ] && grep -qF "panic: holder.CheapDerivationForTests: " "$scratch/err"; then pass "$label"; else fail "$label"; fi
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
