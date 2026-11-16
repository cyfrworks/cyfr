#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Regression cases for scripts/ci/seed-guard.sh, scripts/ci/config-seam.sh,
# scripts/ci/retry.sh, scripts/ci/world-checks.sh,
# scripts/ci/storage-diagrams.py and scripts/ci/main-run.py (against a
# stand-in gh), and for scripts/release.sh's use of the seed guard.
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
# The stand-in gh answers from $GH_STATE, a JSON list of push runs on main:
# `api --paginate URL` lists them two to a page, as gh prints pages; a POST
# to runs/ID/rerun-failed-jobs or runs/ID/rerun takes the run to its next
# attempt, queued. Every call is a line of $GH_CALLS; under GH_FAIL every
# call fails, under GH_FAIL_POST every POST.
mkdir -p "$scratch/gh-bin"
cat > "$scratch/gh-bin/gh" <<'GH'
#!/usr/bin/env python3
import json, os, re, sys
args = sys.argv[1:]
with open(os.environ["GH_CALLS"], "a") as f:
    f.write(" ".join(args) + "\n")
if os.environ.get("GH_FAIL") or args[:1] != ["api"]:
    sys.exit("gh: stand-in refused")
runs = json.load(open(os.environ["GH_STATE"]))
if args[1:3] == ["-X", "POST"]:
    if os.environ.get("GH_FAIL_POST"):
        sys.exit("gh: HTTP 403")
    m = re.fullmatch(r"repos/\{owner\}/\{repo\}/actions/runs/(\d+)/(rerun-failed-jobs|rerun)", args[3])
    run = next((r for r in runs if m and str(r["id"]) == m[1]), None)
    if run is None:
        sys.exit("gh: HTTP 404")
    run.update(run_attempt=run["run_attempt"] + 1, status="queued", conclusion=None)
    json.dump(runs, open(os.environ["GH_STATE"], "w"))
    sys.exit(0)
url = args[-1]
if args[1] != "--paginate" or not re.match(r"repos/\{owner\}/\{repo\}/actions/runs\?branch=main&event=push&created=%3E%3D[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}%3A[0-9]{2}%3A[0-9]{2}Z&per_page=100$", url):
    sys.exit(f"gh: stand-in does not answer {args}")
for i in range(0, max(len(runs), 1), 2):
    print(json.dumps({"total_count": len(runs), "workflow_runs": runs[i:i + 2]}))
GH
chmod +x "$scratch/gh-bin/gh"

# Main: B, then C, D and E, with X on a branch; at B the workflows Test
# (every push to main), Codex (pushes to main under apps/codex), Release
# (tags) and Nightly (a schedule).
main_run_repo() {
  new_repo
  mkdir -p .github/workflows
  printf 'name: Test\non:\n  push:\n    branches: [main]\n  pull_request:\njobs: {}\n' > .github/workflows/test.yml
  printf "name: Codex\non:\n  push:\n    branches: [main]\n    paths:\n      - 'apps/codex/**'\njobs: {}\n" > .github/workflows/codex.yml
  printf "name: Release\non:\n  push:\n    tags: ['[0-9]+.[0-9]+.[0-9]+']\njobs: {}\n" > .github/workflows/release.yml
  printf "name: Nightly\non:\n  schedule:\n    - cron: '0 3 * * *'\njobs: {}\n" > .github/workflows/nightly.yml
  commit B; B=$(git rev-parse HEAD)
  for c in C D E; do printf '%s\n' "$c" > "$c.txt"; commit "$c"; eval "$c=\$(git rev-parse HEAD)"; done
  git checkout -q -b side "$C"; printf 'x\n' > x.txt; commit X; X=$(git rev-parse HEAD); git checkout -q main
  git init -q --bare "$repo.origin"
  git remote add origin "$repo.origin"
  git push -q origin main
  git fetch -q origin
}
# runs 'WORKFLOW COMMIT STATUS CONCLUSION ATTEMPT'...: the stand-in's runs,
# numbered from 101 in order, COMMIT one of B C D E X.
runs() {
  : > "$scratch/gh-calls"
  python3 -I - "$scratch/gh-state" "$B" "$C" "$D" "$E" "$X" "$@" <<'PY'
import json, sys
state, shas, specs = sys.argv[1], dict(zip("BCDEX", sys.argv[2:7])), sys.argv[7:]
runs = []
for i, spec in enumerate(specs):
    wf, c, status, conclusion, attempt = spec.split()
    runs.append({"id": 101 + i, "path": f".github/workflows/{wf}", "head_sha": shas[c], "status": status,
                 "conclusion": None if conclusion == "-" else conclusion, "run_attempt": int(attempt),
                 "html_url": f"https://example.invalid/runs/{101 + i}"})
json.dump(runs, open(state, "w"))
PY
}
read_main() {
  env PATH="$scratch/gh-bin:$PATH" GH_STATE="$scratch/gh-state" GH_CALLS="$scratch/gh-calls" "$@" \
    python3 -I "$main_run" > "$scratch/out" 2> "$scratch/err"
  code=$?
}
line() { grep -qxE -- "$1" "$scratch/out"; }
posts() { grep -c -- '-X POST' "$scratch/gh-calls"; }
reran() { grep -qxF -- "api -X POST repos/{owner}/{repo}/actions/runs/$1" "$scratch/gh-calls"; }
main_run_at() { # COMMIT [ARGS...]: read_main with the script's arguments
  local c=$1; shift
  env PATH="$scratch/gh-bin:$PATH" GH_STATE="$scratch/gh-state" GH_CALLS="$scratch/gh-calls" ${MAIN_RUN_ENV:-} \
    python3 -I "$main_run" "$@" "$c" > "$scratch/out" 2> "$scratch/err"
  code=$?
}

label="main-run: the commit's own runs green, each workflow a push to main runs is green and the rest unread"
main_run_repo
runs "test.yml C completed success 1" "codex.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 0 ] && [ "$(grep -c '' "$scratch/out")" = 3 ] && line 'Codex: green, run 102 on [0-9a-f]{9} \(the commit\), attempt 1: https://example.invalid/runs/102' &&
  line 'Test: green, run 101 on [0-9a-f]{9} \(the commit\), attempt 1: .*' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="main-run: origin's main head is the commit by default"
main_run_repo
runs "test.yml E completed success 1" "codex.yml C completed failure 1"
read_main
if [ "$code" -eq 0 ] && line 'Test: green, run 101 .*\(the commit\).*' && line 'Codex: not run: .*' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="main-run: a workflow its path filter left out reads not run"
main_run_repo
runs "test.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 0 ] && line 'Codex: not run: its path filter left out the commit and every later push'; then pass "$label"; else fail "$label"; fi

label="main-run: no run yet covers the commit, and the read waits"
main_run_repo
runs "test.yml B completed success 1" "test.yml X completed success 1"
main_run_at "$C"
if [ "$code" -eq 2 ] && line 'Test: no run yet' && line 'Codex: no run yet'; then pass "$label"; else fail "$label"; fi

label="main-run: a run in progress waits"
main_run_repo
runs "test.yml C in_progress - 1" "codex.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 2 ] && line 'Test: running, run 101 .*' && line 'Codex: green, .*'; then pass "$label"; else fail "$label"; fi

label="main-run: a red first attempt has its failed jobs rerun once, and a second read starts no second rerun"
main_run_repo
runs "test.yml C completed failure 1" "codex.yml C completed success 1"
main_run_at "$C"
first=$code
first_ok=false
line 'Test: red \(failure\), rerun started, run 101 on [0-9a-f]{9} \(the commit\), attempt 1: .*' && reran 101/rerun-failed-jobs && [ "$(posts)" = 1 ] && first_ok=true
main_run_at "$C"
if [ "$first" -eq 3 ] && $first_ok && [ "$code" -eq 2 ] && line 'Test: running, run 101 .*attempt 2: .*' && [ "$(posts)" = 1 ]; then pass "$label"; else fail "$label"; fi

label="main-run: a run red on its rerun is red twice and never rerun again"
main_run_repo
runs "test.yml C completed failure 2" "codex.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 4 ] && line 'Test: red twice \(failure\), run 101 .*attempt 2: .*: open a regression job' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="main-run: -n says what it would rerun and starts nothing"
main_run_repo
runs "test.yml C completed timed_out 1" "codex.yml C completed success 1"
main_run_at "$C" -n
if [ "$code" -eq 3 ] && line 'Test: red \(timed_out\), would rerun, run 101 .*' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="main-run: a cancelled run gives way to a later commit's"
main_run_repo
runs "test.yml C completed cancelled 1" "test.yml D completed success 1" "codex.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 0 ] && line 'Test: green, run 102 on [0-9a-f]{9} \(1 commit later\), attempt 1: .*' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="main-run: a run only cancelled runs cover is rerun whole, once"
main_run_repo
runs "test.yml C completed cancelled 1" "test.yml D completed cancelled 1" "codex.yml C completed success 1"
main_run_at "$C"
if [ "$code" -eq 3 ] && line 'Test: red \(cancelled, and no run covers it\), rerun started, run 101 .*' && reran 101/rerun && [ "$(posts)" = 1 ]; then pass "$label"; else fail "$label"; fi

label="main-run: the nearest covering run decides, the commit's own before a later one"
main_run_repo
runs "test.yml E completed failure 2" "test.yml D completed success 1" "codex.yml C completed success 1" "codex.yml D completed failure 1"
main_run_at "$C"
if [ "$code" -eq 0 ] && line 'Test: green, run 102 on [0-9a-f]{9} \(1 commit later\), .*' && line 'Codex: green, run 103 .*\(the commit\).*' && [ "$(posts)" = 0 ]; then pass "$label"; else fail "$label"; fi

label="main-run: a red-twice line outranks a rerun started beside it"
main_run_repo
runs "test.yml C completed failure 2" "codex.yml C completed failure 1"
main_run_at "$C"
if [ "$code" -eq 4 ] && line 'Codex: red \(failure\), rerun started, .*' && line 'Test: red twice .*' && reran 102/rerun-failed-jobs && [ "$(posts)" = 1 ]; then pass "$label"; else fail "$label"; fi

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
