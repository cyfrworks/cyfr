# Contributing to CYFR

Thanks for your interest in improving CYFR. Issues and pull requests are
welcome.

## Licensing of contributions (inbound = outbound)

CYFR uses **mixed per-file licensing** (see [`LICENSE`](LICENSE) and
[`FAIR_SOURCE.md`](FAIR_SOURCE.md)). Contributions are accepted under the
license of the **file being changed**:

- Files under `apps/sanctum/**` are **FSL-1.1-Apache-2.0**. Contributions
  to those files are made under FSL-1.1-Apache-2.0.
- Every other file is **Apache-2.0**. Contributions to those files are made
  under Apache-2.0.

By submitting a contribution, you agree to license it under the license that
already applies to the file(s) you change. There is no separate CLA and no
sign-off requirement.

## New files

Open every source file with the SPDX header that matches the directory it
lives in, after a shebang line if it has one, in the file's own comment
syntax:

```
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
```

(use `FSL-1.1-Apache-2.0` only for files inside `apps/sanctum/`).

The `license-lint` workflow enforces this boundary on every pull request for
Elixir, Go, WIT, the console's JavaScript and the backends image suite — a
missing or wrong header fails CI.

## Running from source

`scripts/dev-stack.sh`, from the checkout, runs CYFR from source the way an
install runs it: Prism, the server and live reload from `mix phx.server`,
and the runtime, the backends service (stdio MCP servers) and the builds
service in their containers under `cyfr-locus`, each with the shipped
security options and its egress guard, run from this tree's Locus image.
Besides the setup the next section names (the pinned `wasm-tools`, the
prebuilt binaries and the tailwind CLI), it needs Docker with its compose
plugin, `python3`, and a host that allows unprivileged user namespaces
(`docker-compose.yml`'s `locus-runtime` service says why).

On its first run it makes `.env` mode 0600 and writes into it what a `mix`
boot needs and nothing sets: `CYFR_GITHUB_CLIENT_ID` from `.env.example`,
and `CYFR_SETUP_TOKEN`, the runtime root and the backends key, minted as
`cyfr init` mints them. Later runs keep every value. The builds key, which
a `mix` boot refuses without the builds URL only the stack sets, is minted
for each run unless `.env` sets one. It then builds the tree's Locus image
with `scripts/image.sh` when the host does not hold it already (every
worktree at the same inputs shares one), starts a stand-in for cyfr.run
(`tests/registry-stand-in/standin.py`) and the containers, and runs
`mix phx.server` in the foreground at http://localhost:4000. The server
reaches cyfr.run only through the stand-in, whatever `.env` says: a name
and an identity made in the loop exist at the stand-in alone, kept in
`data/dev-stack/cyfr-run.json`, and no cyfr.run checkout is needed.
Component search and metadata pass through it to cyfr.run, and component
pulls still come from cyfr.run's OCI registry. A new dev database starts
the stand-in afresh; a database that is not new needs the stand-in state
it was made with, and the loop refuses, naming the reset (deleting the dev
database and `data/dev-stack/cyfr-run.json`), when that state is gone. A
`mix` boot outside the loop names no registry or directory unless `.env`
does. The run that
writes the setup token prints the setup link,
`http://localhost:4000/setup#<token>`, as `cyfr init` does: it asks for a
name and a passkey, which set up CYFR's first person, who administers it,
and shows their recovery code, all against the stand-in. Prism and the
server reload as their files change; a change under `apps/locus` or to the
Locus image's other inputs takes effect at the next start. Ctrl-C stops
the server and removes the containers; the image stays, so a start with
nothing changed builds nothing. The image is shared, so the janitor, not
the loop, removes it once no worktree produces it and no loop uses it:
run `scripts/janitor.sh --dry-run` to see what it would remove, then
`scripts/janitor.sh` to remove it by hand. `scripts/dev-stack.sh down` stops
the server and removes the containers a killed run of the same worktree
left.

Each worktree runs a loop of its own, beside the others, a test suite, a
proof or a CI-style run on the same host. Its containers are named
`cyfr-dev-<seed>`, the worktree's seed, and its ports and networks are a
slot's, one of twenty, its stand-in on 127.79.K.1 for slot K. A database
is bound to the slot its stand-in state was made at: the loop takes that
slot when it is free, and refuses, naming it, when it is not. The first loop on a host keeps
http://localhost:4000, so a lone worktree sees no change; a second
worktree's loop takes the next free slot, Prism on 4010 and so on, and
prints its address, which the worktree remembers in
`data/dev-stack.slot` for its next run. A `.env` that sets `CYFR_PORT` or
another address of the stack refuses a slot it disagrees with, by name.
With an API key from Prism's API Keys page, `CYFR_TOKEN=<key>
scripts/dev-stack.sh check` runs a component through the worktree's running
loop and asserts its answer.

AQUA answers in the chat once a model provider's key is in the vault, as on
any install. While a worktree's loop runs, a second start or `down` in the
same worktree refuses, naming the run that holds it.

## Before opening a PR

- Consult [`ARCHITECTURE.md`](ARCHITECTURE.md) when deciding ownership,
  changing a layer edge, a port or an invariant, or resolving an unclear
  architectural contract. A change to a principle, a layer edge, a port or an
  invariant changes that document in the same pull request.
- Keep changes focused and match the surrounding code style.
- Every component is validated by the pinned `wasm-tools`, which the dev
  and test configurations name at `_tools/wasm-tools`, and the application
  refuses to start without it: install it once with
  `scripts/wasm-tools.sh install _tools` (`scripts/test-partitioned.sh`
  installs it when it is missing).
- After `mix deps.get` in a fresh checkout, and after a change to
  `mix.lock`, run `scripts/fetch-prebuilt-binaries.sh` before the first
  compile, and `scripts/fetch-prebuilt-binaries.sh --tailwind` before the
  first `mix assets.deploy` or dev server: neither the deps' precompiled
  NIFs (wasmex's, exqlite's and lazy_html's) nor the tailwind CLI download
  through the deps' own downloads, and the script's header says why.
- The tests tagged `:requires_cargo_component` build real components, and
  the test helpers exclude them where `cargo-component` is not on `PATH`.
  CI runs them on both adapters, so install it
  (`cargo install cargo-component --locked`) with the `wasm32-wasip1` and
  `wasm32-wasip2` targets on rustup's default toolchain: a build runs
  outside the checkout, where `rust-toolchain.toml` does not choose the
  toolchain. `scripts/commit-gate.sh` looks for it in
  `${CARGO_HOME:-~/.cargo}/bin` and on `PATH`, and refuses to run without it.
- Checks run in stages. `scripts/stages.tsv` names what each stage runs,
  and `scripts/stage.sh STAGE` runs it, queuing each check through
  `scripts/heavy-check.sh` in the lane the table names:
  - `save`, after an edit: the format and credo checks, an incremental
    compile with warnings as errors, and the touched tests on SQLite;
  - `handoff`, before you report a change ready: the format and credo
    checks, a forced compile on both adapters, the generated files'
    checks, the touched tests on both adapters (all of `apps/arca/test`
    when Arca changed), `mix dialyzer` when a `lib` file changed, and the
    self-test of every harness script you touched;
  - `pull-request`: the pull request's run on GitHub is the check, and it
    runs every check in parallel. `scripts/stage.sh pull-request` runs
    `scripts/commit-gate.sh`, CI's checks on this host, for working
    offline or reproducing a failing CI job;
  - `release`: the gate's close, which holds the host for over an hour;
  - `nightly`, once a day from a worktree of its own, queued like any
    other check: each adapter's whole suite twice, the tests that failed
    in one run and passed in the other, the partition weights
    regenerated into the run's report, and `scripts/janitor.sh`.

  The touched tests are the changed test files and, for each changed or
  deleted `apps/<app>/lib/<path>.ex`, `apps/<app>/test/<path>_test.exs`
  where it exists; name others after `--`. `scripts/stage.sh -n STAGE`
  lists what it would run. A branch stacked on another sets `STAGE_BASE`
  to that branch, so the handoff stage runs its own changes alone rather
  than everything since `origin/main`.
- A release tag is cut on a tree its pull request's run proved green:
  `scripts/release.sh` reads HEAD's check runs through `gh` before it tags
  HEAD, or HEAD plus a bump commit holding the version lines alone, which
  the tag's own workflow checks again before it publishes; with `--gate`
  it runs the release stage here first. Right before it tags it runs the
  dependency audits again (`scripts/dependency-audit.sh`, the same ones CI
  runs), because the advisory feeds they read change independently of the
  tree, and a tag whose own run fails them publishes nothing. The gate's
  header lists what it runs and which of CI's checks stay CI's alone.
  Besides `cargo-component` it needs `go` at the version both `go.mod`
  files name and a running Docker daemon, and it refuses to run without
  them; it installs `govulncheck` and the close's `trivy` itself, at the
  versions CI pins.
- `scripts/heavy-check.sh` queues the checks of everyone sharing a host
  in three lanes: an exclusive check (the default) runs alone, a proof
  (`-p`: a proof, an image suite, an image build or a release boot) runs
  one at a time beside at most `PROOF_SCOPED` scoped checks (a number the
  script sets from a measured load test), and a scoped check (`-s`: named
  test paths in one partition, a compile, dialyzer, credo or a light
  self-test) runs up to three side by side, on a third of the cores each. Checks start in the order
  they queued, and `scripts/heavy-check.sh --status` shows who holds the
  host and who waits.
- Local runs take the Locus and app images from `scripts/image.sh locus`
  and `scripts/image.sh app`, which tag each by a hash of its inputs, so
  every checkout at the same inputs shares one build.
  `scripts/janitor.sh --dry-run` lists what the nightly janitor would
  remove.
- Run the tests for what you touched as operating-system partitions:
  `scripts/test-partitioned.sh <test paths>` on SQLite, and
  `scripts/test-partitioned.sh -a postgres <test paths>` on PostgreSQL.
  CI runs the whole suite on both, each across four runners: `--shard I/N`
  runs only shard I's partitions of the whole split, so a shard is CI's
  split of the suite between machines, not the local one, which runs it
  whole. After a run,
  `scripts/test-partitioned.sh -- --failed` with the same `-a` reruns
  exactly the failures every partition recorded: each adapter keeps its
  record under its own build path. `mix test --failed` reads SQLite's;
  it reaches PostgreSQL's only with
  `MIX_BUILD_PATH=_build/test_pg CYFR_DATABASE=postgres`. The split
  weighs each file by `scripts/test-partition-weights.tsv`; to regenerate
  it, move it aside, make two runs of
  `CYFR_TEST_TIMINGS_DIR=<absolute dir> scripts/test-partitioned.sh -n 8 -- --formatter ExUnit.CLIFormatter --formatter Prima.Test.TimingFormatter`,
  each into a fresh directory, and keep each file's larger
  `elixir scripts/test-timings.exs weights <dir>` value, as its header
  says.
- If you changed a `@spec` or a function's return shape, run `mix dialyzer`.
  CI runs it too. It is fast once the PLT is built, and the findings it
  reports are recorded in [`.dialyzer_ignore.exs`](.dialyzer_ignore.exs)
  — fixing one means deleting its line and its reason there, since a filter
  that matches nothing also fails the build.
- Don't describe the product as "open source" in user-facing copy — it is
  "Fair Source" / "source available" (see [`FAIR_SOURCE.md`](FAIR_SOURCE.md)).
