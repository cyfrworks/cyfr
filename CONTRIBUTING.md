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

CYFR runs from the checkout with `mix phx.server` at the umbrella root, and
Prism reloads as its files change. Components run in the `locus-runtime`
container built from the same tree, because the runtime runs only under
`cyfr-locus` in its container. A `mix` boot runs no Locus role.
`docker-compose.dev.yml`, layered over `docker-compose.yml`, is that
container's development shape, and `scripts/dev-stack.sh` drives it. Besides
the setup the next section names (the pinned `wasm-tools`, the prebuilt
binaries and the tailwind CLI), the stack needs Docker with its compose
plugin, `openssl`, and a host that allows unprivileged user namespaces
(`docker-compose.yml`'s `locus-runtime` service says why).

1. Give `.env` at the checkout's root a way to sign in. Take
   `CYFR_GITHUB_CLIENT_ID` from `.env.example`, and put your own email in
   `CYFR_PLATFORM_ADMIN_EMAILS`. Copy no other line: `.env.example` is a
   compose deployment's file.
2. `scripts/dev-stack.sh` builds `cyfr-locus:dev` from the tree and starts it
   as the worker service `wrk_local` on `127.0.0.1:4200`, where CYFR
   dispatches by default. Its first run adds a `CYFR_LOCUS_RUNTIME_ROOT` to
   `.env`, and later runs keep it. The runtime's key is derived from that
   root (`mix cyfr.locus.runtime_key wrk_local`) and reaches the container
   through the environment alone. The script refuses a
   `CYFR_LOCUS_RUNTIME_WORKERS`, `CYFR_HOST_API_BIND` or `CYFR_HOST_API_URL`
   that would send runs or the runtime's calls elsewhere. Run it again after
   changing anything the Locus image holds.
3. Start CYFR as the script prints:
   `CYFR_HOST_API_BIND=172.16.231.1 mix phx.server`. That address is the
   runtime network's gateway, the one address the container reaches the host
   API at. Without the stack, a plain `mix phx.server` serves Prism and runs
   no component.
4. Sign in at http://localhost:4000 and create an API key on the API Keys
   page. `CYFR_TOKEN=<key> scripts/dev-stack.sh check` runs
   `catalyst:local.files` through the server and the container: it writes a
   nonce, reads it back and deletes it, and fails naming the refusal or the
   failed run. A session token from the dev CLI's `cyfr login` works too.
5. `scripts/dev-stack.sh down` removes the container and its network.

AQUA answers in the chat once a model provider's key is in the vault, as on
any install. Builds and stdio MCP servers stay off: no builds or backends
service is configured, so CYFR refuses a build and a stdio server. The stack
takes the shipped `locus-runtime` network's subnet (`172.16.231.0/24`), so it
does not run beside a stack started from `docker-compose.yml` on the same
host.

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
- Before a commit, run `scripts/heavy-check.sh -- scripts/commit-gate.sh`.
  A change's check is its pull request's run on GitHub, which runs every
  check in parallel, and a release tag is cut on a tree that run proved
  green: `scripts/release.sh` reads HEAD's check runs through `gh` before it
  tags HEAD, or HEAD plus a bump commit holding the version lines alone,
  which the tag's own workflow checks again before it publishes; it runs
  the gate's close here only with `--gate`. Right before it tags it runs
  the dependency audits again (`scripts/dependency-audit.sh`, the same
  ones CI runs), because the advisory feeds they read change
  independently of the tree, and a tag whose own run fails them publishes
  nothing. The close,
  `scripts/heavy-check.sh -t 10800 -- scripts/commit-gate.sh --close`, holds
  the host for over an hour and is a tool for working offline or for
  reproducing a failing CI job here, not a requirement. The gate's header
  lists what each runs and which of CI's checks stay CI's alone. Besides `cargo-component` it needs `go` at the version both
  `go.mod` files name and a running Docker daemon, and it refuses to run
  without them; it installs `govulncheck` and the close's `trivy` itself,
  at the versions CI pins.
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
