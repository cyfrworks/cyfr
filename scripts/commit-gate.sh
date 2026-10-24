#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# The per-commit gate: scripts/commit-gate.sh [-l LOGDIR] [-n N] [--close] [-- PostgreSQL test paths]
#
# Runs the checks a commit must pass as concurrent legs, one log per step
# under LOGDIR, and frames its stdout with `_START=<pid>` first and
# `_EXIT=<pid> <status>` last, both carrying the gate's own pid, which
# scripts/await-task.sh waits for. Under scripts/heavy-check.sh
# (HEAVY_CHECK_HELD set) heavy-check writes those lines and the gate
# writes neither; a scoped check (`heavy-check.sh -s`) is refused with 64,
# because the gate sizes itself to the whole host. Legs:
#   static    SQLite test compile and forced dev compile (warnings as
#             errors, so every Boundary declaration is checked), format,
#             credo, ops.gen.cli --check, cyfr.gen.configuration_guide
#             --check, the console's JavaScript tests and its lint (npm ci
#             and npx eslint, as CI's JavaScript job), the test WASM
#             fixtures against their sources (scripts/check-test-wasm.sh,
#             with the pinned wasm-tools and the Rust toolchain the
#             fixtures' build script pins), CI's built-SDK and
#             built-toolkit checks (their scripts read from test.yml), the
#             release-boot names test, the canary's own checks, the image
#             suites' shared plumbing (tests/imagesuite_test.py), the
#             prebuilt binary fetch against the deps' own downloads
#             (tests/fetch-prebuilt-binaries-test.sh) and the
#             two Python self-checks (worker_auth.py and the backends
#             harness.py; none needs a database or an image), dialyzer,
#             the Boundary plants, then the full SQLite suite in N
#             partitions
#   postgres  PostgreSQL test compile and forced dev compile (warnings as
#             errors; the dev build in _build/dev_pg, beside the SQLite
#             one), then in two partitions the given
#             test paths or, with none given, the selection: the storage
#             set (apps/arca/test, apps/cyfr/test/arca) and every tracked
#             apps/*/test test file outside it that tags a test for one
#             adapter or branches on the adapter (PG_PATTERN below), or
#             names a test support module that does, or carries
#             :requires_cargo_component (CARGO_PATTERN below), as CI's
#             PostgreSQL job runs those too, each path once. Its
#             summary counts the paths handed to the runner
#             as `pg_selection=<n>`, the report says so, and
#             postgres.pg_selection.txt lists them. With --close the whole
#             suite in N partitions instead, started once the SQLite
#             suite's partitions have exited (four pools across the
#             adapter jobs)
#   cluster   with --close only, after every other leg: the real-member
#             suite alone on its own database, against an object store
#             the gate does not start (CYFR_CLUSTER=on refuses local
#             storage): the one at CYFR_TEST_S3_ENDPOINT, by default
#             http://127.0.0.1:9000, as CI's cluster job starts MinIO there
#   vocab     the CI vocabulary job's own script, read from test.yml
#   islands   prima, arca and sanctum compiled and tested under
#             MIX_ENV=test, as CI's island jobs are, so each island's
#             test/support compiles with warnings as errors, from a copy
#             that holds only what CI gives them (each read from its
#             test.yml job), once the SQLite suite's partitions have
#             exited; locus with --close
#   go        codex-ci.yml's test job (go vet, gofmt, go test under -race,
#             the Docker Compose and access-engine Docker tests with their
#             ran-and-passed assertions, go build) and keeper-ci.yml's
#             keeper job but its run as root in a container with writable
#             cgroups, once both adapters' suites have exited
#   audit     license-lint.yml's spdx-headers job (both assertions),
#             security.yml's go-audit job for each Go module (govulncheck at
#             the version the job installs, through
#             scripts/security-scan.sh), its elixir-audit job (mix compile,
#             hex.audit, deps.audit, deps.unlock --check-unused, sobelow
#             --config) and its npm-audit job (npm audit of every shipped
#             tincture lockfile, through scripts/security-scan.sh)
#   boot      test.yml's release-boot job: tests/release-boot/boot.sh on
#             SQLite, then on PostgreSQL on a database the leg creates
#             empty on the gate's server and drops once the boot has ended,
#             once both adapters' suites have exited
#   harness   with --close only, after the cluster leg: trivy installed at
#             the version the workflows pin (scripts/lib/trivy-install.sh),
#             both images built from the tree (Dockerfile.locus as
#             test.yml's locus-image job builds it, Dockerfile as its
#             locus-backends-image job does), every image tag those jobs
#             name under the gate's own namespace, test.yml's
#             builder-image, locus-runtime-image and locus-backends-image
#             jobs (every suite, the Compose proof's six cases, the setup
#             proof and each image's trivy scan), the browser job's four
#             shards on this host's pull of the Playwright image, and
#             security.yml's repo-scan job (trivy's secret and
#             misconfiguration scans of the tree git tracks or would add)
# The go, audit and harness legs run CI's jobs as a runner runs them, each
# step read from its workflow (run_job, scripts/lib/workflow_plan.py), so
# the gate's copy and CI's cannot drift: every step under its job's
# timeout-minutes, and once one fails only a step whose `if:` runs after a
# failure. The trivy-action steps run the trivy the harness leg installed,
# at the step's own pin, with the inputs CI gives the action. A close holds
# the host longer than heavy-check's default:
# scripts/heavy-check.sh -t 10800 -- scripts/commit-gate.sh --close.
# Every gate forces the test rebuild on both adapters. Each leg discards
# the caller's MIX_BUILD_PATH: static builds its MIX_ENV=test steps in
# _build/test and its MIX_ENV=dev steps in Mix's default, postgres and
# cluster build in _build/test_pg (postgres its dev compile in
# _build/dev_pg), an island builds inside its copy, the Elixir audit in
# _build/audit and each release boot under boot.sh's own build path.
# Every leg runs with ${CARGO_HOME:-$HOME/.cargo}/bin ahead on its PATH,
# where rustup and `cargo install` put their tools, so the tests tagged
# :requires_cargo_component, which the test helpers exclude where
# cargo-component is not on PATH, run as CI's test jobs run them. A gate
# that finds no cargo-component there or on PATH is refused with 69,
# naming where it looked, before any leg starts: passing with those tests
# excluded would hold a commit to less than CI does. So is a gate without
# go, a go other than the version both go.mod files name (what CI's
# setup-go installs) or a docker that reaches no daemon, each named. The
# close's trivy and the audit's govulncheck are installed per run at CI's
# pins, so no host copy is asked for.
# What a gate makes outside its log directory carries its own name, and
# touches no image, tag or name the host already has (the section on what
# a gate makes, below): it is removed by name after each leg, at the
# gate's exit, and, left by a gate that is gone, at the next gate's start,
# which stops with 1 naming what it could not remove.
# Not part of this gate, so a closing record names each with its own
# result: these checks of the workflows a pull request runs, each a job
# (every step of it) or one step of a job, by the names the workflows give
# them (tests/commit-gate-test.sh holds the list to the workflows exactly):
#   codex-ci.yml test-windows
#   codex-ci.yml test-macos
#   keeper-ci.yml keeper: go test as root with writable-cgroups=true (the real kernel)
#   security.yml security-scan-harness
#   security.yml installer-verify
#   test.yml static: Read the Rust fixtures' toolchain pin
#   test.yml static: Test the model catalysts
#   test.yml static: Every stamped seed guest is built from its source
#   test.yml static: Every seed guest carries a stamp, and its crate version is its own
#   test.yml static: The release proofs' shared plumbing
#   test.yml static: The tag pipeline's graph
#   test.yml static: The containerd image store switch's cases
#   test.yml static: The tag pipeline's image publication
#   test.yml harness-tests-host
#   test.yml harness-tests-partitions
#   test.yml harness-tests-gate
#   test.yml test: Read the Rust fixtures' toolchain pin
#   test.yml test: Install cargo-component
#   test.yml s3-minio
#   test.yml locus-image: Save the Locus image
#   test.yml tailscale-image-guard
#   test.yml seed-guards
#   test.yml config-seam
# and, outside CI, the step benchmark (mix cyfr.bench.step).
# Without -n a suite runs in eight partitions on a host of sixteen cores
# or more (two schedulers each) and in four on a smaller one. A PostgreSQL
# partition holds twenty connections, so the server allows twenty times
# the count and the cluster suite's besides: 400 on the verification host.
# -l names a log directory that does not exist yet or is empty; anything
# else is refused with 64 before any leg starts. A relative LOGDIR
# resolves against the caller's directory. Without -l the gate makes a
# fresh one.
# Every step runs in a session of its own (scripts/lib/contain.sh) under a
# deadline, several times what it takes on a quiet host: a step that
# reaches it is stopped with everything it started, recorded as
# `name=124`, and fails its leg, so a stalled check ends the gate instead
# of keeping the host. GATE_STEP_DEADLINE=SECONDS (positive, at most six
# decimal digits, as the containment library takes) gives every step that
# one deadline. Each leg is this script run in a session of its own, so a
# gate that is killed outright still has its legs and their steps stopped
# by their watchdogs. Stopping the gate (INT, TERM, HUP) stops its legs,
# each leg its steps first, and the gate exits 130, 143 or 129. Its exit
# line says 0 only when the whole run completed and passed; a gate ended
# by any other signal reports 1.
set -uo pipefail

usage() { echo "usage: $0 [-l LOGDIR] [-n N] [--close] [-- PostgreSQL test paths]"; }

# Test files that build real components with cargo-component: CI runs
# them on both adapters.
CARGO_PATTERN=':requires_cargo_component\b'

# Test files that run on one adapter only or assert per adapter: an
# adapter tag, an adapter predicate, or a read of the configured adapter.
PG_PATTERN='@(module|describe)?tag :(postgres|sqlite)\b|(^|[^_a-z])(postgres|sqlite)\?\(\)|@sqlite\?|Arca\.Repo\.adapter\(\)|Arca\.Test\.Adapter\.|__adapter__|compile_env\(:arca, *:adapter|repo_adapter\(\)'

# Test support modules that match PG_PATTERN and whose users are not
# selected for it: the test database's own setup, which every test that
# touches the database passes through, so its users would be most of the
# suite. The storage set runs it on PostgreSQL on every gate.
PG_SUPPORT_EXEMPT='Arca.Test.Sandbox'

# The postgres leg's default selection, one path a line, read from the
# tracked files of the current directory's repository: the storage set,
# then, sorted, the test files outside it that match PG_PATTERN or
# CARGO_PATTERN or name a support module that matches PG_PATTERN
# (pg_support_users), so no file is named twice.
# macOS git grep -E ignores \b, so there the pattern runs as PCRE, which
# reads it the same way.
pg_selection() {
  local s=0 mode=-E direct cargo users
  [ "$(uname -s)" != Darwin ] || mode=-P
  direct=$(git grep -l "$mode" "$PG_PATTERN" -- ':(glob)apps/*/test/**/*_test.exs' \
    ':(exclude,glob)apps/arca/test/**' ':(exclude,glob)apps/cyfr/test/arca/**') || s=$?
  # git grep answers 1 when nothing matches.
  [ "$s" -le 1 ] || return 1
  cargo=$(git grep -l "$mode" "$CARGO_PATTERN" -- ':(glob)apps/*/test/**/*_test.exs' \
    ':(exclude,glob)apps/arca/test/**' ':(exclude,glob)apps/cyfr/test/arca/**') || s=$?
  [ "$s" -le 1 ] || return 1
  users=$(pg_support_users "$mode") || return 1
  printf '%s\n' apps/arca/test apps/cyfr/test/arca
  printf '%s\n%s\n%s\n' "$direct" "$cargo" "$users" | sed '/^$/d' | LC_ALL=C sort -u
}

# The test files outside the storage set that name a test support module
# matching PG_PATTERN, other than PG_SUPPORT_EXEMPT's, or a support module
# that names one. The grammar is a reading of the source, not the compiled
# dependency graph, and has two stated limits: support wrappers are
# followed one level, so a test that reaches an adapter branch through a
# wrapper of a wrapper is not selected for it; and an alias of a
# one-segment root namespace is followed only unrenamed (`alias X`, then
# the full name), so `alias X, as: Y` and then `Y.Test.Leaf` is not. The
# close gate (--close), which runs the whole suite on both adapters, is
# the complete check. Any error, the matcher's included, fails the
# selection.
pg_support_users() {
  local mode=$1 s=0 support others wrappers tests modules='' file module
  support=$(git grep -l "$mode" "$PG_PATTERN" -- ':(glob)apps/*/test/support/**/*.ex' \
    ':(glob)apps/*/test/support/**/*.exs' ':(exclude,glob)apps/*/test/support/**/*_test.exs') || s=$?
  [ "$s" -le 1 ] || return 1
  for file in $support; do modules="$modules $(pg_module_of "$file")"; done
  modules=$(pg_unexempt $modules)
  [ -n "$modules" ] || return 0
  others=$(git ls-files -- ':(glob)apps/*/test/support/**/*.ex' ':(glob)apps/*/test/support/**/*.exs' \
    ':(exclude,glob)apps/*/test/support/**/*_test.exs') || return 1
  # grep -v answers 1 when no other support file is left.
  others=$(printf '%s\n' $others | grep -vxF -e "${support:-/}") || { [ "$?" -eq 1 ] || return 1; }
  # shellcheck disable=SC2086
  wrappers=$(pg_naming "$modules" $others) || return 1
  for file in $wrappers; do modules="$modules $(pg_module_of "$file")"; done
  modules=$(pg_unexempt $modules)
  tests=$(git ls-files -- ':(glob)apps/*/test/**/*_test.exs' \
    ':(exclude,glob)apps/arca/test/**' ':(exclude,glob)apps/cyfr/test/arca/**') || return 1
  # shellcheck disable=SC2086
  pg_naming "$modules" $tests
}

# The module a support file defines first, or nothing.
pg_module_of() { sed -n 's/^defmodule \([A-Za-z0-9_.]*\) do$/\1/p' "$1" | head -n 1; }

# The modules given, without PG_SUPPORT_EXEMPT's, each once.
pg_unexempt() {
  local m
  for m in "$@"; do
    case " $PG_SUPPORT_EXEMPT " in *" $m "*) ;; *) echo "$m" ;; esac
  done | LC_ALL=C sort -u | tr '\n' ' '
}

# The FILES, of those given after MODULES (space-separated), that name one
# of the modules: by its full name (an alias, import, use or call), by its
# last segment in a multi-alias of its parent (`alias Parent.{Leaf, ...}`),
# or through an alias of a namespace of two or more segments above it
# (`alias X.Test`, then `Test.Leaf`, or `alias X.Test, as: T`, then
# `T.Leaf`). One Perl process
# reads them all; a file it cannot read, or any other error, exits non-zero.
pg_naming() {
  local modules=$1
  shift
  [ "$#" -gt 0 ] || return 0
  PG_MODULES=$modules perl -e '
    use strict;
    use warnings;
    my @modules = split " ", $ENV{PG_MODULES};
    sub names {
      my ($text, $module) = @_;
      my @s = split /\./, $module;
      return 1 if $text =~ /(?<![A-Za-z0-9_.])\Q$module\E(?![A-Za-z0-9_])/;
      return 0 if @s < 2;
      my $parent = join ".", @s[0 .. $#s - 1];
      return 1 if $text =~ /\Q$parent\E\.\{[^}]*(?<![A-Za-z0-9_.])\Q$s[-1]\E(?![A-Za-z0-9_])[^}]*\}/;
      for my $k (1 .. $#s - 1) {
        my $prefix = join ".", @s[0 .. $k];
        my $rest = join ".", @s[$k + 1 .. $#s];
        while ($text =~ /^[ \t]*alias[ \t]+\Q$prefix\E[ \t]*(?:,[ \t]*as:[ \t]*([A-Z][A-Za-z0-9_]*))?[ \t]*$/mg) {
          my $name = defined $1 ? $1 : $s[$k];
          return 1 if $text =~ /(?<![A-Za-z0-9_.])\Q$name.$rest\E(?![A-Za-z0-9_])/;
        }
      }
      return 0;
    }
    for my $file (@ARGV) {
      open(my $in, "<", $file) or die "$file: $!\n";
      my $text = do { local $/; <$in> };
      close $in or die "$file: $!\n";
      for my $module (@modules) {
        if (names($text, $module)) { print "$file\n"; last }
      }
    }
  ' -- "$@"
}

deadline_for() {
  if [ -n "${GATE_STEP_DEADLINE:-}" ]; then echo "$GATE_STEP_DEADLINE"; return; fi
  # A step of a CI job (run_job) takes the job's own timeout.
  if [ -n "${STEP_DEADLINE:-}" ]; then echo "$STEP_DEADLINE"; return; fi
  case "$1" in
    fossils|format|credo|opsgen|confguide|js_suite|eslint|wasm_tools|test_wasm|sdk_bundle|toolkit_bundle|boot_names|canary_checks|imagesuite_checks|prebuilt_binaries|worker_auth_check|backends_check|island_compile|island_test) echo 600 ;;
    compile_*|boundary_plants) echo 1200 ;;
    # A first run builds the PLT.
    dialyzer) echo 2400 ;;
    # A database made or dropped in the postgres image, its first pull
    # included.
    boot_database) echo 300 ;;
    # One docker call of a leg's own (docker_call): a tag, a listing, a
    # removal, a DROP in the postgres image.
    docker) echo 300 ;;
    trivy_install) echo 600 ;;
    *) echo 1800 ;;
  esac
}

# The PostgreSQL server the gate's suites and boots reach, with the test
# credentials CI's services take. Nothing writes it to a log.
PG_SERVER=postgres://cyfr:cyfr@localhost:5432

# The steps of a leg, for the deadline of a leg that waits on it.
STATIC_STEPS='compile_sqlite_test compile_sqlite_dev format credo opsgen confguide js_suite eslint wasm_tools test_wasm sdk_bundle toolkit_bundle boot_names canary_checks imagesuite_checks prebuilt_binaries worker_auth_check backends_check dialyzer boundary_plants sqlite_suite'
steps_of() {
  case "$1" in
    static) echo "$STATIC_STEPS" ;;
    postgres) if $CLOSE; then echo 'compile_pg_test compile_pg_dev pg_suite'; else echo 'compile_pg_test compile_pg_dev pg_tests'; fi ;;
  esac
}

# The first status contain_start refused a step with: the leg exits with
# it, and so does the gate.
REFUSED=

# One step: its command runs in a session of its own with its own log
# under its deadline, and its status is appended to the leg's summary as
# `name=status`; a process that outlived the stop fails the step and is
# named there as `name_survivors=pid,...`. Nothing here echoes the
# command: the cluster step's environment holds a database password.
step() {
  local leg=$1 name=$2 log status=0 secs
  shift 2
  log="$LOGDIR/$leg.$name.log"
  secs=$(deadline_for "$name")
  if contain_start -g 180 "$@" >"$log" 2>&1 </dev/null; then
    contain_wait "$CONTAIN_PID" "$secs" 180 || status=$?
    if [ "$status" -eq 124 ]; then
      echo "==> $leg.$name stopped at its ${secs}s deadline" | tee -a "$log" >&2
    fi
    if [ -n "$CONTAIN_SURVIVORS" ]; then
      echo "==> $leg.$name left $CONTAIN_SURVIVORS after KILL" | tee -a "$log" >&2
      echo "${name}_survivors=${CONTAIN_SURVIVORS// /,}" >> "$LOGDIR/$leg.summary"
      [ "$status" -ne 0 ] || status=1
    fi
  else
    status=$?
    [ -n "$REFUSED" ] || REFUSED=$status
    echo "==> $leg.$name could not start: $(tail -n 1 "$log")" >&2
  fi
  echo "$name=$status" >> "$LOGDIR/$leg.summary"
  return "$status"
}

leg_static() {
  # Both test builds are forced on every gate. A module stores the
  # signatures it infers from the remote functions it calls, and Mix
  # recompiles it only when a compile-time or export dependency changes,
  # so an incremental build keeps a caller's stale signatures: the gate
  # would then fail on a type warning that is not the commit's, or pass
  # without one the commit has.
  step static compile_sqlite_test env MIX_BUILD_PATH=_build/test CYFR_DATABASE=sqlite MIX_ENV=test mix compile --force --warnings-as-errors || return
  # Forced: incremental state can keep a Boundary declaration the tree no
  # longer has, and a plain compile only warns. Mix takes MIX_BUILD_PATH
  # as given, with no environment suffix, so the dev steps run on Mix's
  # default, _build/dev, and never share a directory with the test build.
  step static compile_sqlite_dev env CYFR_DATABASE=sqlite MIX_ENV=dev mix compile --force --warnings-as-errors || return
  step static format mix format --check-formatted || return
  step static credo mix credo --strict || return
  step static opsgen mix ops.gen.cli --check || return
  step static confguide mix cyfr.gen.configuration_guide --check || return
  step static js_suite apps/cyfr/assets/test/run.sh || return
  # CI's JavaScript job: the lint tools as package-lock.json pins them,
  # with no install script run, then eslint over the console and the SDK.
  # npm would otherwise keep Node's compile cache in TMPDIR, which the gate
  # leaves as it found it.
  step static eslint env NODE_DISABLE_COMPILE_CACHE=1 \
    bash -c 'cd apps/cyfr/assets && npm ci --ignore-scripts --no-audit --no-fund && npx eslint .' || return
  # Every checked-in test WASM fixture is its source's build, with the
  # pinned wasm-tools and the Rust toolchain the fixtures' build script
  # pins (CI reads the same pin), from rustup's bin directory, which the
  # gate put on PATH.
  step static wasm_tools scripts/wasm-tools.sh install _tools || return
  local rustc
  rustc=$(sed -n 's/^rustc_version=//p' apps/cyfr/test/support/test_wasm/build-fixture.sh)
  step static test_wasm env RUSTUP_TOOLCHAIN="$rustc" scripts/check-test-wasm.sh || return
  # Each rebuilds its bundle into the checkout and fails when the tracked
  # file is not the build, as CI's test job runs it.
  local sdk="$LOGDIR/static.sdk_bundle.sh" toolkit="$LOGDIR/static.toolkit_bundle.sh"
  if ! ci_step "The built SDK is its source's" > "$sdk" ||
    ! ci_step "The built toolkit is its source's" > "$toolkit"; then
    echo "ci_steps=1" >> "$LOGDIR/static.summary"
    return 1
  fi
  step static sdk_bundle env MIX_BUILD_PATH=_build/test CYFR_DATABASE=sqlite MIX_ENV=test bash "$sdk" || return
  step static toolkit_bundle env MIX_BUILD_PATH=_build/test CYFR_DATABASE=sqlite MIX_ENV=test bash "$toolkit" || return
  step static boot_names bash tests/release-boot/names-test.sh || return
  step static canary_checks python3 -I tests/locus-runtime-image/canary_test.py || return
  step static imagesuite_checks python3 -I tests/imagesuite_test.py || return
  step static prebuilt_binaries bash tests/fetch-prebuilt-binaries-test.sh || return
  # The image suites' own protocol code against the vectors, with no image.
  step static worker_auth_check python3 -I tests/locus-runtime-image/worker_auth.py --self-check || return
  step static backends_check python3 -I tests/locus-backends-image/harness.py --self-check || return
  step static dialyzer mix dialyzer || return
  # The Boundary plants: each writes a forbidden edge into a copy of the tree
  # and force-compiles it, so they run once here and never in the partitions.
  step static boundary_plants env MIX_BUILD_PATH=_build/test CYFR_DATABASE=sqlite MIX_ENV=test mix test apps/cyfr/test/cyfr/boundaries_test.exs --only boundary_plant || return
  step static sqlite_suite env MIX_BUILD_PATH=_build/test scripts/test-partitioned.sh -n "$PARTS" -a sqlite -- --warnings-as-errors || return
}

leg_postgres() {
  export MIX_BUILD_PATH=_build/test_pg
  # Forced for the stale inferred signatures leg_static names.
  step postgres compile_pg_test env CYFR_DATABASE=postgres MIX_ENV=test mix compile --force --warnings-as-errors || return
  # CI compiles the dev target on each adapter: an adapter branch under
  # compile_env compiles only on its own. In a build directory of its own,
  # so the SQLite dev build in _build/dev is never the other adapter's.
  step postgres compile_pg_dev env MIX_BUILD_PATH=_build/dev_pg CYFR_DATABASE=postgres MIX_ENV=dev mix compile --force --warnings-as-errors || return
  if $CLOSE; then
    # One adapter's suite has the host at a time: the PostgreSQL suite's
    # partitions start once the SQLite suite's have exited.
    await_leg postgres static || return
    step postgres pg_suite scripts/test-partitioned.sh -n "$PARTS" -a postgres -- --warnings-as-errors || return
  else
    local list="$LOGDIR/postgres.pg_selection.txt" paths=() p
    if [ "${#PG_PATHS[@]}" -gt 0 ]; then
      printf '%s\n' "${PG_PATHS[@]}" > "$list"
    elif ! pg_selection > "$list"; then
      echo '==> postgres: the PostgreSQL selection could not be read (git grep)' >&2
      echo 'pg_selection_read=1' >> "$LOGDIR/postgres.summary"
      return 1
    fi
    while IFS= read -r p; do paths+=("$p"); done < "$list"
    echo "pg_selection=${#paths[@]}" >> "$LOGDIR/postgres.summary"
    step postgres pg_tests scripts/test-partitioned.sh -n 2 -a postgres -- --warnings-as-errors "${paths[@]}" || return
  fi
}

# The script of test.yml's step named $1, as CI runs it, on stdout: read
# from the workflow, so the gate's copy and CI's cannot drift.
ci_step() {
  python3 - .github/workflows/test.yml "$1" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for s in job.get("steps", []):
        if s.get("name") == sys.argv[2]:
            print("set -e"); print(s["run"]); sys.exit(0)
sys.exit(f"step {sys.argv[2]!r} not found in test.yml")
PY
}

# The vocabulary job's script is CI's. macOS git grep -E ignores \b, so
# there the patterns run as PCRE, which reads them the same way.
leg_vocab() {
  local script="$LOGDIR/vocab.sh"
  ci_step "Retired names stay out and the storage layout is Arca's" > "$script" || return 1
  if [ "$(uname -s)" = Darwin ]; then sed -i '' 's/git grep -InE/git grep -InP/' "$script"; fi
  step vocab fossils bash "$script"
}

# One phase of an island, in the island's directory, under its deadline.
island_phase() {
  local name=$1 phase=$2 status=0
  shift 2
  # MIX_ENV=test as CI's island jobs run under it: the compile phase then
  # builds the island's test/support with warnings as errors too.
  if contain_start -g 180 env MIX_ENV=test CYFR_DATABASE=sqlite MIX_OS_CONCURRENCY_LOCK=0 "$@" >>"$ISLAND_LOG" 2>&1 </dev/null; then
    contain_wait "$CONTAIN_PID" "$(deadline_for "island_$phase")" 180 || status=$?
    if [ "$status" -eq 124 ]; then
      echo "==> islands.$name stopped at its deadline" | tee -a "$ISLAND_LOG" >&2
    fi
    if [ -n "$CONTAIN_SURVIVORS" ]; then
      echo "==> islands.$name left $CONTAIN_SURVIVORS after KILL" | tee -a "$ISLAND_LOG" >&2
      echo "${name}_survivors=${CONTAIN_SURVIVORS// /,}" >> "$LOGDIR/islands.summary"
      [ "$status" -ne 0 ] || status=1
    fi
  else
    status=$?
    # The leg reads this back and exits with the refusal, as a refused
    # step makes it.
    echo "${name}_refused=$status" >> "$LOGDIR/islands.summary"
    echo "==> islands.$name could not start its $phase phase: $(tail -n 1 "$ISLAND_LOG")" >&2
  fi
  return "$status"
}

# What test.yml's island job for application $1 (`$1-independence`)
# gives the island, on stdout as one line: the application, then each path
# its step copies in, in the step's order, and `_tools` where it installs
# the pinned wasm-tools there. The step is read whole: each line is one the
# gate mirrors (a `cp` of tracked paths, each to the island's directory of
# the same name, the wasm-tools install, `cd` into the application,
# `mix compile --warnings-as-errors` and `mix test`) or setup that changes
# nothing the island holds (`set`, `island=`, `mkdir -p`); any other line
# fails it, so the gate's island cannot drift from CI's.
island_spec() {
  python3 -I - .github/workflows/test.yml "$1" <<'PY'
import re, shlex, sys, yaml

path, app = sys.argv[1], sys.argv[2]
job = (yaml.safe_load(open(path))["jobs"]).get(app + "-independence")
if job is None:
    sys.exit(f"test.yml has no {app}-independence job")
steps = [s for s in job.get("steps", []) if f'cd "$island/apps/{app}"' in s.get("run", "")]
if len(steps) != 1:
    sys.exit(f"test.yml's {app}-independence job has {len(steps)} steps that enter the island, not one")
copied, ran = [], set()
for line in steps[0]["run"].split("\n"):
    line = line.strip()
    if not line or line.startswith("#") or re.fullmatch(r"set -[a-z]+ pipefail|island=\S+|mkdir -p( \"\$island/[a-z]+\")+", line):
        continue
    words = shlex.split(line)
    if line == 'scripts/wasm-tools.sh install "$island/_tools"':
        copied.append("_tools")
    elif line in (f'cd "$island/apps/{app}"', "mix compile --warnings-as-errors", "mix test"):
        ran.add(line)
    elif words[0] == "cp" and len(words) >= 3:
        sources = [w for w in words[1:-1] if w != "-R"]
        for src in sources:
            parent = src.rsplit("/", 1)[0] + "/" if "/" in src else ""
            if src.startswith(("-", "/")) or ".." in src.split("/") or words[-1] != "$island/" + parent:
                sys.exit(f"test.yml's {app} island copies {src} to {words[-1]}, which the gate does not mirror: {line}")
        copied += sources
    else:
        sys.exit(f"test.yml's {app} island runs a line the gate does not mirror: {line}")
for need in (f'cd "$island/apps/{app}"', "mix compile --warnings-as-errors", "mix test"):
    if need not in ran:
        sys.exit(f"test.yml's {app} island does not run {need}")
print(" ".join([app] + copied))
PY
}

# An island is an application compiled and tested from a copy holding only
# what CI gives it (island_spec reads the list from test.yml): deps and
# the pinned tools are linked in, the rest copied.
# Its build directory is the copy's own and one Mix process at a time
# uses it, so Mix's build lock excludes no one there, and it is off: Mix
# through 1.20.4 can wait forever on a lock it holds itself, the second
# time a fresh lock directory is taken. It runs as a subshell of the
# islands leg and starts its phases' sessions itself, so it stops them on
# TERM, which the leg sends it when the leg is stopped.
island() {
  local name=$1 spec a paths status=0
  ISLAND_COPY=
  trap 'trap "" INT TERM; contain_stop_all 180 >/dev/null; [ -z "$ISLAND_COPY" ] || rm -rf "$ISLAND_COPY"; exit 143' TERM INT
  ISLAND_LOG="$LOGDIR/islands.$name.log"
  : > "$ISLAND_LOG"
  if ! spec=$(island_spec "$name" 2>>"$ISLAND_LOG"); then
    echo "==> islands.$name: test.yml's copy list could not be read: $(tail -n 1 "$ISLAND_LOG")" >&2
    echo "$name=1" >> "$LOGDIR/islands.summary"
    return 1
  fi
  ISLAND_COPY=$(mktemp -d "$LOGDIR/island_${name}.XXXX") || return 1
  read -r -a paths <<<"$spec"
  for a in "${paths[@]:1}"; do
    case "$a" in
      deps|_tools) ln -s "$ROOT/$a" "$ISLAND_COPY/$a" ;;
      */*) mkdir -p "$ISLAND_COPY/${a%/*}" && cp -R "$a" "$ISLAND_COPY/${a%/*}/" ;;
      *) cp -R "$a" "$ISLAND_COPY/" ;;
    esac || status=1
  done
  if [ "$status" -eq 0 ] && cd "$ISLAND_COPY/apps/$name"; then
    island_phase "$name" compile mix compile --warnings-as-errors &&
      island_phase "$name" test mix test
    status=$?
  else
    status=1
  fi
  cd "$ROOT" || :
  echo "$name=$status" >> "$LOGDIR/islands.summary"
  rm -rf "$ISLAND_COPY"
  return "$status"
}

ISLAND_PIDS=()
# Stops the island subshells: each stops its own sessions on TERM, within
# the step grace plus 15 s.
stop_islands() {
  local p n=0 live
  for p in ${ISLAND_PIDS[@]+"${ISLAND_PIDS[@]}"}; do kill -TERM "$p" 2>/dev/null || :; done
  while [ "$n" -lt 2000 ]; do
    live=
    for p in ${ISLAND_PIDS[@]+"${ISLAND_PIDS[@]}"}; do if leg_alive "$p"; then live=1; fi; done
    [ -n "$live" ] || break
    sleep 0.1
    n=$((n + 1))
  done
  for p in ${ISLAND_PIDS[@]+"${ISLAND_PIDS[@]}"}; do
    kill -KILL "$p" 2>/dev/null || :
    wait "$p" 2>/dev/null || :
  done
  ISLAND_PIDS=()
}

# Runs the islands named concurrently.
run_islands() {
  local status=0 p name
  ISLAND_PIDS=()
  for name in "$@"; do
    # The function runs as the asynchronous subshell itself, so its pid is
    # the one its trap is on.
    island "$name" &
    ISLAND_PIDS+=("$!")
  done
  for p in "${ISLAND_PIDS[@]}"; do wait "$p" || status=1; done
  ISLAND_PIDS=()
  return "$status"
}

leg_islands() {
  local status=0
  # The islands run their own SQLite suites: they start once the static
  # leg's partitions have exited, so no two SQLite suites share the
  # machine's I/O, under which a SQLite writer's wait outlasts its bound.
  await_leg islands static || return
  # Under --close the PostgreSQL suite's partitions follow the SQLite
  # suite's, and the islands' SQLite writers wait out its I/O too.
  if $CLOSE; then await_leg islands postgres || return; fi
  run_islands prima arca sanctum || status=1
  if $CLOSE; then
    run_islands locus || status=1
  fi
  # An island runs in a subshell of the leg, so its refused start comes
  # back through the summary.
  [ -n "$REFUSED" ] || REFUSED=$(sed -n 's/^[a-z_]*_refused=//p' "$LOGDIR/islands.summary" 2>/dev/null | head -n 1)
  return $status
}

# The cluster suite runs alone: real members on their own database, after
# every other leg's pools have exited.
leg_cluster() {
  export MIX_BUILD_PATH=_build/test_pg
  step cluster cluster env CYFR_DATABASE_URL="$PG_SERVER/cyfr_cluster_test" \
    CYFR_CLUSTER_DATABASE_URL="$PG_SERVER/cyfr_cluster_test" \
    CYFR_SECRET_KEY_BASE="${CYFR_SECRET_KEY_BASE:-JspnK9M8XQE1HFBRZWuzJqK8ZX8ITp5vPQ6MJv2RmFfKpGr2fEhAgSf3UqBT5xTk}" \
    scripts/test-partitioned.sh -n 1 -a postgres -- --warnings-as-errors --only cluster apps/cyfr/test/cluster
}

# One job of a CI workflow, run here as a runner runs it:
#   run_job LEG SLUG WORKFLOW JOB [KEY=VALUE]... [--except STEP | --only STEP | --env NAME=VALUE]...
# scripts/lib/workflow_plan.py reads the job from the workflow and plans
# each step (its header says what a step becomes on this host). Every step
# that runs is a step of the leg, `SLUG_NN` after its place in the job,
# under the job's timeout-minutes as its deadline; once one has failed,
# only a step whose `if:` runs after a failure does, as on a runner. The
# job's status is `SLUG=status` in the leg's summary and its result line
# is LEG.SLUG.result; its plan stays in LEG.SLUG.plan, its step summary in
# LEG.SLUG.summary.md and what an upload step keeps under artifacts/. Its
# RUNNER_TEMP, TMPDIR/cyfr-gate-G-LEG.SLUG.temp, goes when the job ends.
run_job() {
  local leg=$1 slug=$2 wf=$3 job=$4 dir temp s when secs kind name failed= ran=0 status=0 picks= a prev=
  shift 4
  for a in "$@"; do
    case "$prev:$a" in --*:*) ;; *:[a-z]*=*) picks="$picks $a" ;; esac
    prev=$a
  done
  dir="$LOGDIR/$leg.$slug.plan" temp="${TMPDIR:-/tmp}/cyfr-gate-$GATE_ID-$leg.$slug.temp"
  if ! python3 -I "$ROOT/scripts/lib/workflow_plan.py" "$ROOT" "$wf" "$job" "$dir" "$temp" "$@" --artifacts "$LOGDIR/artifacts" \
    >"$LOGDIR/$leg.$slug.log" 2>&1 </dev/null; then
    echo "==> $leg.$slug: $wf $job$picks could not be planned: $(tail -n 1 "$LOGDIR/$leg.$slug.log")" >&2
    echo "$wf $job$picks: not planned, $(tail -n 1 "$LOGDIR/$leg.$slug.log")" > "$LOGDIR/$leg.$slug.result"
    echo "$slug=1" >> "$LOGDIR/$leg.summary"
    return 1
  fi
  mkdir -p "$temp"
  while IFS=$'\t' read -r s when secs kind name <&3; do
    case "$kind" in setup|-) continue ;; esac
    case "$when" in
      ok) [ -z "$failed" ] || continue ;;
      failed) [ -n "$failed" ] || continue ;;
      always) ;;
      *) continue ;;
    esac
    ran=$((ran + 1))
    if ! STEP_DEADLINE=$secs step "$leg" "${slug}_$s" bash "$dir/$s.sh"; then
      [ -n "$failed" ] || failed=$name
      status=1
      [ -z "$REFUSED" ] || break
    fi
  done 3<"$dir/plan"
  [ ! -f "$temp/.summary.md" ] || cp "$temp/.summary.md" "$LOGDIR/$leg.$slug.summary.md"
  rm -rf "$temp"
  local steps="$ran steps"
  [ "$ran" != 1 ] || steps='1 step'
  if [ -n "$failed" ]; then
    echo "$wf $job$picks: FAILED at '$failed' ($steps ran)" > "$LOGDIR/$leg.$slug.result"
  else
    echo "$wf $job$picks: $steps passed" > "$LOGDIR/$leg.$slug.result"
  fi
  echo "$slug=$status" >> "$LOGDIR/$leg.summary"
  return "$status"
}

# --- what a gate makes, by name ----------------------------------------------
# Everything a gate makes outside its log directory carries the gate's id
# G, its pid, and no name the host already has: images under the
# repository namespace cyfr-gate-G/ (each image tag of the jobs the
# harness leg runs, renamed by scripts/lib/workflow_plan.py); what the
# scripts a leg runs name after their own run (a compose project with its
# containers, networks and volumes, an image, a directory under TMPDIR,
# and every container a `docker run` or `docker create` starts, however
# briefly, since one whose caller is killed runs on), which each puts
# PROOF_RUN_PREFIX before and every leg sets to cyfr-gate-G-LEG-, the
# gate's own PostgreSQL clients named the same way (cyfr-gate-G-gate- in
# the gate itself); the database cyfr_gate_boot_G and the ones boot.sh
# names beside it (cyfr_gate_boot_G_...); and the RUNNER_TEMP, tool and
# docker_call scratch directories TMPDIR/cyfr-gate-G-LEG.... Every process
# a leg starts carries COMMIT_GATE=G and COMMIT_GATE_LEG=LEG in its
# environment, names outside CYFR_, since a cyfr server refuses to boot
# with a CYFR_ variable it does not declare. So what is left is found by
# name, and nothing needs remembering: gate_clean removes it after every
# leg ends, however it ended (the leg, and the gate for a leg that died),
# at the gate's exit, and at the next gate's start, where, since a gate
# takes the host alone (scripts/heavy-check.sh), everything named
# cyfr-gate-<digits> whose gate's pid no longer runs is an orphan of a
# gate that is gone. It first stops the sessions of the processes carrying
# the marker and confirms none is left, then removes in dependency order:
# containers, networks, volumes, the gate's image tags, the databases, the
# directories; then lists each kind again. A listing that fails, a removal
# that fails and a second listing that still finds something each fail
# it, naming what is left, and end it there: nothing after it in
# dependency order is removed (a directory stays while a container that
# may hold it does). Every docker call runs contained under the docker
# deadline (docker_call).

# One docker command, contained under the docker deadline, its stdout in
# DOCKER_OUT and its stderr appended to log $1. Returns docker's status,
# 124 at the deadline, or the status containment refused it with, which
# the leg then exits with, as a refused step makes it.
DOCKER_OUT=
# Where docker_call keeps a call's output: a directory named after the gate
# and its leg (or `gate`), so a gate that dies leaves nothing unnamed.
DOCKER_SCRATCH=
docker_call() {
  local log=$1 out s=0
  shift
  mkdir -p "$DOCKER_SCRATCH" || return 1
  out=$(mktemp "$DOCKER_SCRATCH/docker.XXXXXX") || return 1
  DOCKER_OUT=
  if contain_start -g 30 docker "$@" >"$out" 2>>"$log" </dev/null; then
    contain_wait "$CONTAIN_PID" "$(deadline_for docker)" 30 || s=$?
    [ -z "$CONTAIN_SURVIVORS" ] || [ "$s" -ne 0 ] || s=1
    [ "$s" -ne 124 ] || echo "==> docker $1 stopped at its deadline" >> "$log"
  else
    s=$?
    [ -n "$REFUSED" ] || REFUSED=$s
    echo "==> docker $1 could not start: $s" >> "$log"
  fi
  DOCKER_OUT=$(cat "$out") || s=1
  rm -f "$out"
  return "$s"
}

# Whether gate $1 still runs: its process exists and has not exited (a
# zombie has).
gate_running() {
  local s
  if [ -r "/proc/$1/stat" ]; then
    read -r s < "/proc/$1/stat" 2>/dev/null || return 1
    s=${s##*) }
    s=${s%% *}
  else
    s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
    s=${s//[[:space:]]/}
  fi
  case $s in ''|Z*|X*) return 1 ;; esac
}

# The sessions of the live processes whose environment carries
# COMMIT_GATE matching regex $1 and COMMIT_GATE_LEG matching regex $2,
# other than session $3, one a line; with `gone` as $4, only those whose
# gate no longer runs. With no /proc to read environments from, it fails,
# said on stderr.
gate_sessions() {
  python3 -I - "$1" "$2" "$3" "${4:-}" <<'PY'
import os, re, sys
gate = re.compile(r"COMMIT_GATE=(%s)" % sys.argv[1])
leg = re.compile(r"COMMIT_GATE_LEG=(?:%s)" % sys.argv[2])
own, gone = sys.argv[3], sys.argv[4] == "gone"

def running(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            stat = f.read()
    except OSError:
        return False
    return stat[stat.rindex(")") + 2:].split()[0] not in ("Z", "X")
if not os.path.isdir("/proc/self"):
    print("no /proc here: the sessions a gate's legs left cannot be read", file=sys.stderr)
    sys.exit(3)
found = set()
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            env = [e.decode("utf-8", "replace") for e in f.read().split(b"\0")]
        with open(f"/proc/{pid}/stat") as f:
            stat = f.read()
    except OSError:
        continue
    fields = stat[stat.rindex(")") + 2:].split()
    if fields[0] in ("Z", "X") or fields[3] == own:
        continue
    marks = [m for m in map(gate.fullmatch, env) if m]
    if not marks or not any(leg.fullmatch(e) for e in env):
        continue
    if gone and running(marks[0].group(1)):
        continue
    found.add(fields[3])
print("\n".join(sorted(found, key=int)))
PY
}

# gate_clean SCOPE [LEG] LOG: what SCOPE covers removed, as the section
# above says: `leg LEG` this gate's for that leg (every kind: what is
# named cyfr-gate-G-LEG-, the namespace's images for the harness leg, the
# databases for the boot leg, the directories), `gate` all of this gate's,
# `orphans` every gate's that no longer runs (run before this gate makes
# anything): a process, or anything named after a gate, whose gate's pid
# still runs is left alone. Where the sessions cannot be read from
# process environments (no /proc), nothing can be confirmed stopped, so
# nothing is removed: what would have been is named, and it fails, unless
# there is nothing to remove.
gate_clean() {
  local scope=$1 leg= log id legre own sids sid s=0 kind pass passes name rest d dbre gone= unread= found=0 named image
  if [ "$scope" = leg ]; then leg=$2; log=$3; else log=$2; fi
  case "$scope" in
    leg) id=$GATE_ID; legre=$leg ;;
    gate) id=$GATE_ID; legre='.*' ;;
    orphans) id='[0-9]+'; legre='.*' ;;
    *) echo "gate_clean: no scope $scope" >&2; return 64 ;;
  esac
  [ "$scope" != orphans ] || gone=gone
  # What a leg names after its run is cyfr-gate-G-LEG-...; the harness leg
  # also builds and tags the namespace's images, cyfr-gate-G/....
  named="^cyfr-gate-($id)-"
  image="^cyfr-gate-($id)(/[^:]+|-[^/:]+):.+\$"
  if [ "$scope" = leg ]; then
    named="^cyfr-gate-($id)-$leg-"
    image="^cyfr-gate-($id)-$leg-[^/:]+:.+\$"
    [ "$leg" != harness ] || image="^cyfr-gate-($id)(/[^:]+|-$leg-[^/:]+):.+\$"
  fi
  own=$(ps -o sid= -p "$$" | tr -d ' ')
  # The sessions first, each stopped with everything it started, and none
  # left before anything they might use is removed.
  if sids=$(gate_sessions "$id" "$legre" "$own" "$gone" 2>>"$log"); then
    for sid in $sids; do
      echo "==> stopping session $sid, which a gate's leg left running" >&2
      contain_stop "$sid" 30 >/dev/null 2>>"$log" || s=1
    done
    sids=$(gate_sessions "$id" "$legre" "$own" "$gone" 2>>"$log") || return 1
    if [ -n "$sids" ] || [ "$s" -ne 0 ]; then
      echo "==> sessions a gate's leg left are still running ($(echo $sids)): nothing is removed" >&2
      return 1
    fi
    passes='remove verify'
  else
    unread=1
    passes=find
  fi
  # remove_one KIND NAME: removes it, or, with the sessions unread, names it.
  remove_one() {
    if [ -n "$unread" ]; then
      echo "==> the $1 $2 is left: no session can be confirmed stopped here" >&2
      found=1
      return 0
    fi
    case $1 in
      directory) echo "==> removing the directory $2" >&2; rm -rf "$2" ;;
      database)
        echo "==> dropping the database $2" >&2
        docker_call "$log" run --rm --name "${PROOF_RUN_PREFIX:-cyfr-gate-$$-gate-}psql-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" \
          --network host -e PGOPTIONS=--client-min-messages=warning postgres:18.6 \
          psql -v ON_ERROR_STOP=1 -q "$PG_SERVER/postgres" -c "DROP DATABASE IF EXISTS \"$2\" WITH (FORCE)" ;;
      *)
        echo "==> removing the $1 $2" >&2
        case $1 in
          container) docker_call "$log" rm -f "$2" ;;
          network) docker_call "$log" network rm "$2" ;;
          volume) docker_call "$log" volume rm -f "$2" ;;
          image) docker_call "$log" image rm "$2" ;;
        esac ;;
    esac || { echo "==> the $1 $2 could not be removed" >&2; s=1; }
  }
  # The first failure ends the cleaning: a listing or a removal that fails,
  # or a second listing that still finds something, leaves everything
  # after it in dependency order (what may hold or need what is left), all
  # of it still named for the next sweep.
  stop_here() {
    echo "==> the cleaning stops at the failure above: nothing after it in dependency order is removed" >&2
    return 1
  }
  # Docker's kinds, for every scope and leg, before the databases and the
  # directories they may hold open.
  for pass in $passes; do
    for kind in container network volume image; do
      case $kind in
        container) docker_call "$log" ps -a --format '{{.Names}}' ;;
        network) docker_call "$log" network ls --format '{{.Name}}' ;;
        volume) docker_call "$log" volume ls --format '{{.Name}}' ;;
        image) docker_call "$log" image ls --format '{{.Repository}}:{{.Tag}}' ;;
      esac || { echo "==> the ${kind}s could not be listed" >&2; stop_here; return 1; }
      while IFS= read -r name; do
        case $kind in
          image) [[ "$name" =~ $image ]] || continue ;;
          *) [[ "$name" =~ $named ]] || continue ;;
        esac
        [ -z "$gone" ] || ! gate_running "${BASH_REMATCH[1]}" || continue
        if [ "$pass" = verify ]; then
          echo "==> the $kind $name is still there" >&2
          s=1
        else
          remove_one "$kind" "$name"
          [ "$s" -eq 0 ] || { stop_here; return 1; }
        fi
      done <<<"$DOCKER_OUT"
      # A kind still there holds up the kinds after it.
      [ "$s" -eq 0 ] || { stop_here; return 1; }
    done
  done
  if [ "$scope" != leg ] || [ "$leg" = boot ]; then
    [ "$id" != '[0-9]+' ] || dbre='[0-9]+'
    dbre=${dbre:-$id}
    for pass in $passes; do
      if ! docker_call "$log" run --rm --name "${PROOF_RUN_PREFIX:-cyfr-gate-$$-gate-}psql-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" \
        --network host -e PGOPTIONS=--client-min-messages=warning postgres:18.6 \
        psql -v ON_ERROR_STOP=1 -qAt "$PG_SERVER/postgres" \
        -c "SELECT datname FROM pg_database WHERE datname ~ '^cyfr_gate_boot_$dbre(_|\$)' ORDER BY 1"; then
        echo "==> the databases could not be listed" >&2
        stop_here
        return 1
      fi
      while IFS= read -r name; do
        [[ "$name" =~ ^cyfr_gate_boot_(${dbre})(_|$) ]] || continue
        [ -z "$gone" ] || ! gate_running "${BASH_REMATCH[1]}" || continue
        if [ "$pass" = verify ]; then
          echo "==> the database $name is still there" >&2
          s=1
        else
          remove_one database "$name"
          [ "$s" -eq 0 ] || { stop_here; return 1; }
        fi
      done <<<"$DOCKER_OUT"
      [ "$s" -eq 0 ] || { stop_here; return 1; }
    done
  fi
  for pass in $passes; do
    for d in "${TMPDIR:-/tmp}"/cyfr-gate-*; do
      [ -e "$d" ] || [ -L "$d" ] || continue
      name=${d##*/}
      rest=${name#cyfr-gate-}
      [[ "$rest" =~ ^($id)-(.+)$ ]] || continue
      [ -z "$gone" ] || ! gate_running "${BASH_REMATCH[1]}" || continue
      case "$scope" in leg) case "${BASH_REMATCH[2]}" in "$leg".*|"$leg"-*) ;; *) continue ;; esac ;; esac
      # The cleaner's own scratch is the gate's while it runs.
      [ "$d" != "${DOCKER_SCRATCH:-}" ] || continue
      if [ "$pass" = verify ]; then
        echo "==> the directory $d is still there" >&2
        s=1
      else
        remove_one directory "$d"
        [ "$s" -eq 0 ] || { stop_here; return 1; }
      fi
    done
  done
  if [ -n "$unread" ] && [ "$found" -ne 0 ]; then
    echo "==> the sessions a gate's legs left cannot be read from process environments here (no /proc), so none can be confirmed stopped and nothing above is removed" >&2
    return 1
  fi
  return "$s"
}

# CI's Go jobs on Linux: codex-ci.yml's whole test job, and keeper-ci.yml's
# keeper job but its run as root in a container with writable cgroups,
# which stays CI's. The -race suites load every core, so they start once
# both adapters' suites have exited, whose tests carry timing bounds.
leg_go() {
  local status=0
  await_leg go static || return
  await_leg go postgres || return
  run_job go codex_test codex-ci.yml test || status=1
  [ -z "$REFUSED" ] || return 1
  run_job go keeper keeper-ci.yml keeper --except 'go test as root with writable-cgroups=true (the real kernel)' || status=1
  return "$status"
}

# The licence lint and the dependency audits as license-lint.yml and
# security.yml run them. govulncheck is the version security.yml installs,
# built into a tool directory of the gate's ahead on PATH; the Elixir
# audit's Mix builds under a build path of its own, beside the legs'
# builds; npm audit reads every shipped tincture lockfile.
leg_audit() {
  local status=0 gobin
  gobin="${TMPDIR:-/tmp}/cyfr-gate-$GATE_ID-audit.gobin"
  run_job audit spdx license-lint.yml spdx-headers || status=1
  [ -z "$REFUSED" ] || return 1
  run_job audit govuln_codex security.yml go-audit tree=apps/codex --env "GOBIN=$gobin" --env "PATH=$gobin:$PATH" || status=1
  [ -z "$REFUSED" ] || return 1
  run_job audit govuln_keeper security.yml go-audit tree=apps/locus/keeper --env "GOBIN=$gobin" --env "PATH=$gobin:$PATH" || status=1
  [ -z "$REFUSED" ] || return 1
  run_job audit elixir_audit security.yml elixir-audit --env "MIX_BUILD_PATH=$ROOT/_build/audit" || status=1
  [ -z "$REFUSED" ] || return 1
  run_job audit npm_audit security.yml npm-audit || status=1
  rm -rf "$gobin"
  return "$status"
}

# test.yml's release-boot job: the release built and booted by
# tests/release-boot/boot.sh on each adapter in turn, since both start
# their cells on the same default listeners. Each adapter's release builds
# under boot.sh's own build path (_build/prod_release_boot_<adapter>),
# apart from the suites' builds and from each other. SQLite boots with no
# database URL; PostgreSQL on cyfr_gate_boot_G, which this leg creates
# empty on the gate's server and beside which boot.sh creates and drops
# its own (`pg_run_database`); gate_clean drops whatever of those is left,
# a CREATE whose client failed included. The release builds load every
# core, so the boots start once both adapters' suites have exited, as the
# go leg does.
leg_boot() {
  local status=0 db="cyfr_gate_boot_$GATE_ID"
  await_leg boot static || return
  await_leg boot postgres || return
  STEP_DEADLINE=1800 step boot boot_sqlite env -u CYFR_DATABASE_URL tests/release-boot/boot.sh sqlite || status=1
  [ -z "$REFUSED" ] || return 1
  step boot boot_database docker run --rm --name "${PROOF_RUN_PREFIX}database-create" --network host \
    -e PGOPTIONS=--client-min-messages=warning postgres:18.6 \
    psql -v ON_ERROR_STOP=1 -q "$PG_SERVER/postgres" -c "CREATE DATABASE \"$db\"" || return 1
  STEP_DEADLINE=1800 step boot boot_postgres env CYFR_DATABASE_URL="$PG_SERVER/$db" \
    tests/release-boot/boot.sh postgres || status=1
  step boot boot_database_drop docker run --rm --name "${PROOF_RUN_PREFIX}database-drop" --network host \
    -e PGOPTIONS=--client-min-messages=warning postgres:18.6 \
    psql -v ON_ERROR_STOP=1 -q "$PG_SERVER/postgres" -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" || status=1
  return "$status"
}

# With --close, after every other leg: trivy installed at the version the
# workflows' trivy-action steps pin (scripts/lib/trivy-install.sh) into a
# tool directory of the gate's ahead on PATH, both images built from the
# tree, then test.yml's image jobs (each suite, the Compose proof's six
# cases and the setup proof in the backends job, and each image's scan),
# the browser job's four shards and security.yml's repository scans, each
# job as CI runs it, every image tag the jobs name under the gate's
# namespace (--image-namespace). A job whose image did not build fails at
# its first step that needs it. The image suites name every compose
# project and container they start from the gate's prefix
# (PROOF_RUN_PREFIX), and what a suite left is removed after its job.
leg_harness() {
  local status=0 log="$LOGDIR/harness.docker.log" ns="cyfr-gate-$GATE_ID" tools version
  tools="${TMPDIR:-/tmp}/cyfr-gate-$GATE_ID-harness.tools"
  if version=$(python3 -I "$ROOT/scripts/lib/workflow_plan.py" --trivy-version "$ROOT" 2>>"$log"); then
    step harness trivy_install scripts/lib/trivy-install.sh "$version" "$tools" || status=1
  else
    echo 'trivy_version=1' >> "$LOGDIR/harness.summary"
    status=1
  fi
  [ -z "$REFUSED" ] || return 1
  export PATH="$tools:$PATH"
  run_job harness build_locus test.yml locus-image --only 'Build the Locus image once' --image-namespace "$ns" || status=1
  [ -z "$REFUSED" ] || return 1
  run_job harness build_app test.yml locus-backends-image --only 'Build the app image' --image-namespace "$ns" || status=1
  [ -z "$REFUSED" ] || return 1
  run_job harness builder_image test.yml builder-image --image-namespace "$ns" || status=1
  [ -z "$REFUSED" ] || return 1
  harness_sweep || status=1
  run_job harness runtime_image test.yml locus-runtime-image --image-namespace "$ns" || status=1
  [ -z "$REFUSED" ] || return 1
  harness_sweep || status=1
  run_job harness backends_image test.yml locus-backends-image --image-namespace "$ns" || status=1
  [ -z "$REFUSED" ] || return 1
  harness_sweep || status=1
  run_job harness browser_a test.yml browser shard=a --image-namespace "$ns" || status=1
  [ -z "$REFUSED" ] || return 1
  run_job harness browser_b test.yml browser shard=b --image-namespace "$ns" || status=1
  [ -z "$REFUSED" ] || return 1
  run_job harness browser_c test.yml browser shard=c --image-namespace "$ns" || status=1
  [ -z "$REFUSED" ] || return 1
  run_job harness browser_d test.yml browser shard=d --image-namespace "$ns" || status=1
  [ -z "$REFUSED" ] || return 1
  run_job harness repo_scan security.yml repo-scan || status=1
  rm -rf "$tools"
  return "$status"
}

# What an image job's suites left under the harness leg's prefix, removed
# before the next job: the containers, networks and volumes, with the
# images kept for the jobs after it.
harness_sweep() {
  local log="$LOGDIR/harness.docker.log" kind name pass s=0
  for pass in remove verify; do
    for kind in container network volume; do
      case $kind in
        container) docker_call "$log" ps -a --format '{{.Names}}' ;;
        network) docker_call "$log" network ls --format '{{.Name}}' ;;
        volume) docker_call "$log" volume ls --format '{{.Name}}' ;;
      esac || { echo "==> the ${kind}s could not be listed" >&2; s=1; continue; }
      while IFS= read -r name; do
        [[ "$name" =~ ^cyfr-gate-$GATE_ID-harness- ]] || continue
        if [ "$pass" = verify ]; then
          echo "==> the $kind $name is still there" >&2
          s=1
          continue
        fi
        echo "==> removing the $kind $name a suite left" >&2
        case $kind in
          container) docker_call "$log" rm -f "$name" ;;
          network) docker_call "$log" network rm "$name" ;;
          volume) docker_call "$log" volume rm -f "$name" ;;
        esac || { echo "==> the $kind $name could not be removed" >&2; s=1; }
      done <<<"$DOCKER_OUT"
    done
  done
  return "$s"
}

# Whether process $1 exists and has not exited. A leg is the gate's child,
# not its peer's, so a dead leg stays a zombie until the gate reaps it.
leg_alive() {
  local s
  case ${1:-} in ''|0*|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  s=${s//[[:space:]]/}
  case $s in ''|Z*|X*) return 1 ;; esac
  return 0
}

# A leg that must follow another waits for the marker the other leaves
# when it ends, whatever its status. It watches the other leg's pid, which
# the gate gives it: a leg that ended without leaving its marker fails the
# waiting one within a second or two, and so does a wait longer than the
# sum of the other leg's step deadlines.
await_leg() {
  local leg=$1 other=$2 pid limit=0 name start=$SECONDS
  case $other in
    static) pid=$PEER_STATIC ;;
    postgres) pid=$PEER_POSTGRES ;;
  esac
  for name in $(steps_of "$other"); do limit=$((limit + $(deadline_for "$name"))); done
  until [ -e "$LOGDIR/$other.done" ]; do
    if ! leg_alive "$pid"; then
      [ ! -e "$LOGDIR/$other.done" ] || return 0
      echo "==> $leg: the $other leg ended without its marker" >&2
      echo "await_$other=1" >> "$LOGDIR/$leg.summary"
      return 1
    fi
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      echo "==> $leg: the $other leg did not end within ${limit}s" >&2
      echo "await_$other=124" >> "$LOGDIR/$leg.summary"
      return 1
    fi
    sleep 1
  done
}

# Sourced (tests/commit-gate-test.sh reads pg_selection), the script
# defines its functions and runs nothing.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")" || exit 1
ROOT=$(dirname "$(dirname "$SELF")")
. "$ROOT/scripts/lib/contain.sh" || exit 69

# --- a leg: "$SELF" --leg NAME, started by the gate ------------------------
# It takes the gate's parsed options and its peers' pids from the
# environment, prepares nothing and writes no terminal line. Stopped, it
# stops its own steps first.
if [ "${1:-}" = --leg ]; then
  leg=${2:-}
  case "$leg" in static|postgres|vocab|islands|cluster|go|audit|boot|harness) ;; *) echo "unknown leg: $leg" >&2; exit 64 ;; esac
  LOGDIR=${GATE_LEG_LOGDIR:-}; PARTS=${GATE_LEG_PARTS:-}; CLOSE=${GATE_LEG_CLOSE:-}
  PEER_STATIC=${GATE_LEG_PEER_STATIC:-}; PEER_POSTGRES=${GATE_LEG_PEER_POSTGRES:-}
  PG_PATHS=()
  if [ -n "${GATE_LEG_PG_PATHS:-}" ]; then
    while IFS= read -r p; do PG_PATHS+=("$p"); done <<<"$GATE_LEG_PG_PATHS"
  fi
  unset GATE_LEG_LOGDIR GATE_LEG_PARTS GATE_LEG_CLOSE GATE_LEG_PEER_STATIC GATE_LEG_PEER_POSTGRES GATE_LEG_PG_PATHS
  case "$CLOSE" in true|false) ;; *) echo 'a leg runs only under the gate' >&2; exit 64 ;; esac
  # The gate's id and this leg's name, which every process of the leg
  # carries in its environment.
  [ -d "$LOGDIR" ] && [[ "${COMMIT_GATE:-}" =~ ^[0-9]+$ ]] && [ "${COMMIT_GATE_LEG:-}" = "$leg" ] ||
    { echo 'a leg runs only under the gate' >&2; exit 64; }
  GATE_ID=$COMMIT_GATE
  DOCKER_SCRATCH="${TMPDIR:-/tmp}/cyfr-gate-$GATE_ID-$leg.scratch"
  # What the scripts the leg runs name after their own run (a compose
  # project, a container, an image, a directory) is named after the gate
  # and the leg too: they put PROOF_RUN_PREFIX before those names.
  export PROOF_RUN_PREFIX="cyfr-gate-$GATE_ID-$leg-"
  cd "$ROOT" || exit 1
  unset MIX_BUILD_PATH
  # What the leg made outside its steps is removed by name once its steps
  # have stopped, however the leg ends; the gate does it again for a leg
  # that did not end cleanly.
  leg_cleanup() {
    local c=0
    gate_clean leg "$leg" "$LOGDIR/$leg.cleanup.log" || c=1
    rm -rf "$DOCKER_SCRATCH"
    echo "cleanup=$c" >> "$LOGDIR/$leg.summary"
    return "$c"
  }
  # The gate stops a leg with TERM, through contain_stop_all. A leg starts
  # as an asynchronous child with SIGINT ignored, so it cannot trap INT.
  leg_signal() {
    trap '' TERM
    stop_islands
    contain_stop_all 180 >/dev/null || :
    leg_cleanup || :
    exit 143
  }
  trap leg_signal TERM
  "leg_$leg"; s=$?
  leg_cleanup || s=1
  : > "$LOGDIR/$leg.done"
  if [ -n "$REFUSED" ]; then exit "$REFUSED"; fi
  [ "$s" -eq 0 ] || exit 1
  exit 0
fi

# --- the gate ----------------------------------------------------------------
LOGDIR=""; PARTS=""; CLOSE=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -l) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; LOGDIR=$2; shift 2 ;;
    -n) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; PARTS=$2; shift 2 ;;
    --close) CLOSE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
PG_PATHS=("$@")

if [ "${HEAVY_CHECK_HELD:-}" = scoped ]; then
  echo 'the commit gate takes the whole host: run it under scripts/heavy-check.sh without -s' >&2
  exit 64
fi

# The terminal lines are heavy-check's when it runs the gate.
TERMINAL=false
[ -n "${HEAVY_CHECK_HELD:-}" ] || TERMINAL=true
STARTED=false
OWNER=false
# Set only by the last line of a run that passed. Bash runs the EXIT trap
# for a signal the gate does not trap (USR1, say) with $? at 0 and then
# dies of it, so 0 is reported only for a run that reached its end with 0.
COMPLETED=false
# The gate's id, which names everything it makes; set once its legs may
# start, and what they made is removed at its exit.
GATE_ID=
# Every exit path after option parsing: whatever still runs is stopped,
# the registry swept and removed when this gate made it, and the
# `_EXIT=` line written last.
gate_exit() {
  local s=$?
  trap - EXIT
  trap '' INT TERM HUP
  [ "$s" -ne 0 ] || $COMPLETED || s=1
  contain_stop_all 240 || { [ "$s" -ne 0 ] || s=1; }
  # Whatever a leg made and left, named after this gate; what cannot be
  # removed is the next gate's to remove.
  if [ -n "$GATE_ID" ] && ! gate_clean gate "$LOGDIR/gate.cleanup.log"; then
    echo "==> what the legs made could not all be removed; the next gate removes it (see $LOGDIR/gate.cleanup.log)" >&2
    [ "$s" -ne 0 ] || s=1
  fi
  [ -z "$DOCKER_SCRATCH" ] || rm -rf "$DOCKER_SCRATCH"
  if $OWNER; then
    contain_sweep_registry 240 || { [ "$s" -ne 0 ] || s=1; }
    rm -f "$CONTAIN_REGISTRY"
  fi
  if $STARTED; then printf '\n_EXIT=%s %s\n' "$$" "$s"; fi
  exit "$s"
}
gate_signal() {
  trap '' INT TERM HUP
  echo '==> gate interrupted, stopping its legs' >&2
  contain_stop_all 240 >/dev/null || :
  exit "$1"
}
trap gate_exit EXIT
trap 'gate_signal 130' INT
trap 'gate_signal 143' TERM
trap 'gate_signal 129' HUP
if $TERMINAL; then echo "_START=$$"; STARTED=true; fi

case "${GATE_STEP_DEADLINE:-1}" in
  ''|*[!0-9]*|0*|???????*) echo 'GATE_STEP_DEADLINE must be positive decimal seconds, at most six digits' >&2; exit 64 ;;
esac

# Every leg takes rustup's bin directory on its PATH, and a gate that
# finds no cargo-component is refused before it touches the log directory.
CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin"
export PATH="$CARGO_BIN:$PATH"
if ! command -v cargo-component >/dev/null 2>&1; then
  echo "==> cargo-component is neither in $CARGO_BIN nor on PATH: the tests tagged :requires_cargo_component would be excluded, and CI runs them (cargo install cargo-component --locked, with rustup's wasm32-wasip2 target)" >&2
  exit 69
fi
# The go, audit and boot legs run Go and Docker as CI's jobs do: each is
# refused with 69 here, naming what is missing, as is a go other than the
# version each Go module's go.mod names, which CI's setup-go installs, and
# a docker that reaches no daemon.
need_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "==> $1 is not on PATH: $2" >&2
  exit 69
}
need_tool go 'the go leg runs the Go suites of codex-ci.yml and keeper-ci.yml with it, and the audit leg builds govulncheck with it'
need_tool docker "the go leg's Compose tests, the release boots and the close's image jobs run Docker"
# The binary's own version, read outside any module: inside one that
# names a newer go, a go held to itself refuses to answer.
have=$(cd / && GOTOOLCHAIN=local go env GOVERSION 2>/dev/null) || have=
for mod in apps/codex apps/locus/keeper; do
  want=$(sed -n 's/^toolchain go//p' "$ROOT/$mod/go.mod")
  [ -n "$want" ] || want=$(sed -n 's/^go //p' "$ROOT/$mod/go.mod")
  if [ -z "$want" ] || [ "$have" != "go$want" ]; then
    echo "==> go on PATH is ${have:-unreadable} and $mod/go.mod names go${want:-nothing}, which CI's setup-go installs: put that version first on PATH" >&2
    exit 69
  fi
done
if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  echo "==> docker reaches no daemon: the go leg's Compose tests, the release boots and the close's image jobs need one" >&2
  exit 69
fi
# What a gate that is gone left, removed before anything else runs: on
# a host a gate takes alone, everything named after a gate is an orphan.
DOCKER_SCRATCH="${TMPDIR:-/tmp}/cyfr-gate-$$-gate"
(umask 077 && mkdir -p "$DOCKER_SCRATCH") || exit 1
orphans_log="$DOCKER_SCRATCH/orphans.log"
if ! gate_clean orphans "$orphans_log"; then
  cat "$orphans_log" >&2
  # A refused start ends the gate with the refusal, as it does a leg.
  [ -z "$REFUSED" ] || exit "$REFUSED"
  echo "==> what an earlier gate left could not all be removed (above); the gate stops" >&2
  exit 1
fi
rm -f "$orphans_log"

# A log directory holds this run's logs alone, so the verdict reads
# nothing an earlier run left.
refuse_logdir() { echo "the log directory $LOGDIR $1: -l takes a new or empty directory" >&2; exit 64; }
if [ -n "$LOGDIR" ]; then
  if [ -e "$LOGDIR" ] && [ ! -d "$LOGDIR" ]; then
    refuse_logdir 'is not a directory'
  elif [ -d "$LOGDIR" ]; then
    entries=$(ls -A -- "$LOGDIR" 2>/dev/null) || refuse_logdir 'cannot be read'
    [ -z "$entries" ] || refuse_logdir 'is not empty'
    [ -w "$LOGDIR" ] && [ -x "$LOGDIR" ] || refuse_logdir 'is not writable'
  else
    mkdir -p -- "$LOGDIR" 2>/dev/null || refuse_logdir 'cannot be created'
  fi
else
  LOGDIR=$(mktemp -d /tmp/cyfr-gate.XXXXXX) || exit 1
fi
LOGDIR=$(cd "$LOGDIR" && pwd -P) || exit 1

if [ -z "$PARTS" ]; then
  cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
  if [ "$cores" -ge 16 ]; then PARTS=8; else PARTS=4; fi
fi

cd "$ROOT" || exit 1
# Run directly, the gate is the outermost wrapper and owns the registry of
# every session started under it; under heavy-check it appends to
# heavy-check's.
if [ -z "${CONTAIN_REGISTRY:-}" ]; then
  contain_registry_create || exit 1
  OWNER=true
fi

# The pinned validator the dev and test configurations name
# (`_tools/wasm-tools`), before any leg compiles or tests.
s=0
if contain_start -g 30 scripts/wasm-tools.sh install _tools >/dev/null </dev/null; then
  contain_wait "$CONTAIN_PID" 300 30 || s=$?
else
  s=$?
  echo '==> the pinned wasm-tools install could not start' >&2
  exit "$s"
fi
if [ "$s" -ne 0 ]; then
  echo "==> the pinned wasm-tools could not be installed (scripts/wasm-tools.sh): $s" >&2
  [ "$s" -eq 124 ] && exit 124
  exit 1
fi
# The deps' precompiled NIFs in the caches their compiles read, before any
# leg compiles the deps into a build of its own: the compile cannot download
# them itself (scripts/fetch-prebuilt-binaries.sh says why). CI's jobs run
# the same fetch after mix deps.get, which the gate's plan takes as setup.
s=0
if contain_start -g 30 scripts/fetch-prebuilt-binaries.sh >/dev/null </dev/null; then
  contain_wait "$CONTAIN_PID" 600 30 || s=$?
else
  s=$?
  echo '==> the prebuilt binary fetch could not start' >&2
  exit "$s"
fi
if [ "$s" -ne 0 ]; then
  echo "==> the deps' precompiled NIFs could not be fetched (scripts/fetch-prebuilt-binaries.sh): $s" >&2
  [ "$s" -eq 124 ] && exit 124
  exit 1
fi
start=$SECONDS
echo "==> commit gate at $(git rev-parse --short HEAD) ($(uname -s)), logs in $LOGDIR"

GATE_ID=$$
export GATE_LEG_LOGDIR="$LOGDIR" GATE_LEG_PARTS="$PARTS" GATE_LEG_CLOSE="$CLOSE"
GATE_LEG_PG_PATHS=$(printf '%s\n' ${PG_PATHS[@]+"${PG_PATHS[@]}"})
export GATE_LEG_PG_PATHS
# Each leg leads a session of its own under a watchdog with the leg
# grace, which outlasts a leg's stop of its current step.
start_leg() {
  local s=0
  contain_start -g 240 env COMMIT_GATE="$GATE_ID" COMMIT_GATE_LEG="$1" "$SELF" --leg "$1" </dev/null || s=$?
  if [ "$s" -ne 0 ]; then
    echo "==> the $1 leg could not start" >&2
    exit "$s"
  fi
  eval "pid_$1=\$CONTAIN_PID"
}
# The islands compile from deps the static leg's compile has already
# fetched; nothing else is shared, so the four legs run at once.
start_leg static
export GATE_LEG_PEER_STATIC="$pid_static"
start_leg postgres
export GATE_LEG_PEER_POSTGRES="$pid_postgres"
start_leg vocab
start_leg islands
start_leg go
start_leg audit
start_leg boot

status=0
# A leg's exit status is 0, 1, or the status contain_start refused one of
# its steps with, which the gate keeps.
leg_result() {
  local leg=$1 s=0 pid_var="pid_$1" r
  contain_wait "${!pid_var}" 0 240 || s=$?
  if [ -n "$CONTAIN_SURVIVORS" ]; then
    echo "==> the $leg leg left $CONTAIN_SURVIVORS after KILL" >&2
    [ "$s" -ne 0 ] || s=1
  fi
  # A leg that did not end cleanly (it died, failed or was refused) may
  # have left sessions or what it made: removed by name now.
  if [ "$s" -ne 0 ]; then
    if gate_clean leg "$leg" "$LOGDIR/$leg.cleanup.log"; then
      echo 'gate_cleanup=0' >> "$LOGDIR/$leg.summary"
    else
      echo 'gate_cleanup=1' >> "$LOGDIR/$leg.summary"
    fi
  fi
  if [ "$s" -eq 0 ]; then
    r=ok
  else
    r=FAILED
    case "$s:$status" in
      64:0|64:1|69:0|69:1|69:64) status=$s ;;
      *) [ "$status" -ne 0 ] || status=1 ;;
    esac
  fi
  printf '==> %-9s %-7s %s\n' "$leg" "$r" "$(tr '\n' ' ' < "$LOGDIR/$leg.summary" 2>/dev/null)"
}
for leg in static postgres vocab islands go audit boot; do leg_result "$leg"; done
if $CLOSE; then
  start_leg cluster
  leg_result cluster
  start_leg harness
  leg_result harness
fi
for leg in static postgres cluster islands; do
  [ -f "$LOGDIR/$leg.summary" ] || continue
  while IFS='=' read -r name _; do
    case "$leg.$name" in
      postgres.pg_selection)
        printf '    postgres.pg_selection: %s paths handed to the runner, listed in postgres.pg_selection.txt\n' \
          "$(sed -n 's/^pg_selection=//p' "$LOGDIR/postgres.summary")"
        continue ;;
      static.sqlite_suite|postgres.pg_tests|postgres.pg_suite|cluster.cluster) f="$LOGDIR/$leg.$name.log" ;;
      islands.*_survivors) continue ;;
      islands.*) f="$LOGDIR/islands.$name.log" ;;
      *) continue ;;
    esac
    [ -f "$f" ] || continue
    printf '    %s: %s\n' "$leg.$name" "$(grep -E '^(Result:|==> [0-9]+ partitions)' "$f" | tr '\n' ' ')"
  done < "$LOGDIR/$leg.summary"
done
# Each CI job a leg ran, and how it ended.
for f in "$LOGDIR"/*.result; do
  [ -f "$f" ] || continue
  r=${f##*/}
  printf '    %s: %s\n' "${r%.result}" "$(cat "$f")"
done
if [ "$status" -eq 0 ]; then verdict=passed; else verdict=FAILED; fi
echo "==> gate $verdict in $((SECONDS - start))s, logs in $LOGDIR"
[ "$status" -ne 0 ] || COMPLETED=true
exit "$status"
