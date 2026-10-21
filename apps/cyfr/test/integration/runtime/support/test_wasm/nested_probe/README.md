<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# nested-probe

A minimal `cyfr:formula` world component (`export run; import invoke`) used
by `Locus.Runtime.Test.NestedExecution` to build **real** nested WASM executions in
tests.

Input selects the operation:

```jsonc
{"op": "echo"}                                       // no host calls
{"op": "call",  "request": {"tool": "…", "action": "…", "args": {}}}
{"op": "spawn_await",     "request": {…}}            // spawn + await
{"op": "spawn_await_all", "requests": [{…}, …]}      // spawn N + await-all
{"op": "emit",  "payload": {…}}
{"op": "chain", "depth": 2, "leaf": {…request…}}     // self-invoke N deep
{"op": "steps", "steps": [                           // several, in order
  {"call": {…}}, {"spawn": {…}}, {"emit": {…}},
  {"await": 1}, {"await_all": [1, 2]}, {"poll": 1}, {"cancel": "task_1"}
]}                                                   // a task by the index of
                                                     // the step that spawned
                                                     // it, or by its id
```

Raw host responses are returned verbatim in `result_raw` / `emit_raw`, and
a `steps` run's in `results`, one per step, so tests characterize exactly
what the host did.

## Rebuilding

The binary is checked in; rebuild whenever `src/lib.rs` or `Cargo.lock`
changes, and record the digests the build prints below: the probe's test
holds `src/lib.rs`, `Cargo.lock` and `nested_probe.wasm` to them, so a
source change without a rebuild fails.

```sh
apps/cyfr/test/integration/runtime/support/test_wasm/nested_probe/build.sh          # build and write
apps/cyfr/test/integration/runtime/support/test_wasm/nested_probe/build.sh --check  # build and compare
```

`build.sh` lays the crate out in a scratch directory with the canonical
formula `Cargo.toml` (`Prima.CargoToml.template(:formula)`) and the formula
world's WIT (`wit/formula`), builds it `--locked` to `Cargo.lock` with
`cargo component build --release --target wasm32-wasip2`, and remaps the
scratch directory and the Cargo home out of the paths rustc embeds, so the
bytes carry nothing of where they were built. `build.sh` runs
`apps/cyfr/test/support/test_wasm/build-fixture.sh`, the one pin of the
toolchain (rustc, its `wasm32-wasip2` target and cargo-component), which
refuses a missing or other one by name.

It reads crates.io for the crates `Cargo.lock` names. If the probe's
version ever changes, update `SELF_REF` in `src/lib.rs` and `@probe_ref` in
`../../nested_execution_helper.exs` together.

## Digests

```
src/lib.rs        sha256:e206a6b3e4633a35636a4001957004714ef8ab25932399c74223d68636df436d
Cargo.lock        sha256:695ceaa15daafe0e307ee5bb4497e044c8bcae806665f8923f015b8b86c6a1b2
nested_probe.wasm sha256:a19032f3fbecf90d5a85ab44c9a3936c6c5dacf7d091976c6aac232deb9ad420
```
