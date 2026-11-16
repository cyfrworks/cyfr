#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Decide which harness self-test jobs this run needs: scripts/ci/self-test-scope.sh
#
# test.yml's harness-tests-host, harness-tests-partitions and
# harness-tests-gate jobs test the CI and host scripts against stand-ins,
# so a pull request that changes no file their scripts read cannot turn
# them red. For each job whose paths below a pull request leaves as its
# base has them, this writes JOB=false (host, partitions, gate) to
# GITHUB_OUTPUT, and test.yml skips that job. It writes nothing, and every
# job runs, everywhere else: a push to main, a release or the nightly
# (test.yml called from release.yml or nightly.yml carries the caller's
# event), a run with no event, and a diff that cannot be read.
#
# It compares the merge commit a pull request's run checks out with that
# commit's first parent, the base, so the job's checkout takes
# fetch-depth: 2. That commit's second parent must be the pull request's
# head (PR_HEAD_SHA): a checkout of anything else runs every job.
#
# Each job's paths are what the scripts it runs read, source, copy or
# execute, followed into the scripts those run, and the job's own
# definition (test.yml, the setup-elixir action) and this script. A path
# left out skips a job that could have failed, so a script that starts
# reading another file adds it here.
#
# Exit 0 with or without the output, 64 when given any argument.
set -euo pipefail

[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 64; }

# Every job: its definition and this decision.
always=(.github/workflows/test.yml scripts/ci/self-test-scope.sh)

# The containment library, the host queue, the run names, the stage table,
# the shared images, the janitor and the load check. Their fixtures are
# scratch repositories holding copies of these; the stage table's guard
# reads every workflow, and the load check one block of the commit gate.
host=(
  .github/workflows
  scripts/lib
  scripts/await-task.sh scripts/commit-gate.sh scripts/heavy-check.sh scripts/image.sh
  scripts/janitor.sh scripts/nightly.sh scripts/stage.sh scripts/stages.tsv
  tests/contain-test.sh tests/heavy-check-test.sh tests/run-names-test.sh tests/stage-test.sh
  tests/image-test.sh tests/image-stub.sh tests/janitor-test.sh
  tests/load-check
  tests/handle-proof/run.sh
  tests/install-screen-proof/prepare.sh tests/install-screen-proof/base-image.sh
  tests/install-screen-proof/lib.sh
  tests/browser/harness.sh
)

# The partition runner against a stand-in Mix and a toy umbrella, with its
# real helper and default weights table, and the helper's unit tests,
# which evaluate the test configuration.
partitions=(
  .github/actions/setup-elixir
  scripts/lib
  scripts/test-partitioned.sh scripts/test-partition-env.exs scripts/test-partition-weights.tsv
  scripts/wasm-tools.sh
  tests/test-partitioned-test.sh tests/test-partition-env-test.exs
  config/test.exs config/database_choice.exs
)

# The commit gate against a stand-in Mix, on this checkout. It reads every
# workflow and every tracked file under scripts/ and tests/; the checks it
# runs for real read the console's assets and the SDK bundle (the
# JavaScript suite and its lint), the shipped seed, the WIT tree, every
# tracked WASM fixture and its recipe (Prima.CargoToml through the real
# Mix), the islands' copies, the Go and Rust pins, and every tracked test
# file under apps/ (the PostgreSQL selection). Left out: the whole-tree
# scans it repeats (vocabulary, SPDX headers) and the umbrella's compile,
# which a change outside these paths fails in their own jobs of the same
# run (vocabulary-gate, license-lint.yml, static).
gate=(
  .github
  scripts tests
  rust-toolchain.toml mix.exs mix.lock .trivyignore.yaml
  config/database_choice.exs config/locus_runtime.exs
  apps/codex/go.mod apps/locus/keeper/go.mod
  ':(glob)apps/*/test/**'
  apps/cyfr/assets apps/cyfr/priv/static
  apps/cyfr/lib/compendium/scaffold.ex apps/prima/lib/prima/cargo_toml.ex
  wit seed
  ':(glob)**/*.wasm'
)

[ "${GITHUB_EVENT_NAME:-}" = pull_request ] || exit 0
[ -n "${PR_HEAD_SHA:-}" ] || exit 0
second=$(git rev-parse -q --verify 'HEAD^2^{commit}') || exit 0
[ "$second" = "$PR_HEAD_SHA" ] || exit 0
git rev-parse -q --verify 'HEAD^1^{commit}' >/dev/null || exit 0

for job in host partitions gate; do
  declare -n paths=$job
  # 0 is no change; 1 a change and anything else a diff that cannot be
  # read, and both run the job.
  if git diff --quiet HEAD^1 HEAD -- "${always[@]}" "${paths[@]}"; then
    echo "$job=false" >>"$GITHUB_OUTPUT"
    echo "harness-tests-$job: not needed, this pull request changes none of the paths its scripts read"
  fi
  unset -n paths
done
