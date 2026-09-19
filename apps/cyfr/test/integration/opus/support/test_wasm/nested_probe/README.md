<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# nested-probe

A minimal `cyfr:formula` world component (`export run; import invoke`) used
by `Opus.Test.NestedExecution` to build **real** nested WASM executions in
tests. Unlike `../math.wasm` (a WASI-P1 core module that cannot execute as
a component), `nested_probe.wasm` is a genuine Component Model binary.

Input selects the operation:

```jsonc
{"op": "echo"}                                       // no host calls
{"op": "call",  "request": {"tool": "…", "action": "…", "args": {}}}
{"op": "spawn_await",     "request": {…}}            // spawn + await
{"op": "spawn_await_all", "requests": [{…}, …]}      // spawn N + await-all
{"op": "emit",  "payload": {…}}
{"op": "chain", "depth": 2, "leaf": {…request…}}     // self-invoke N deep
```

Raw host responses are returned verbatim in `result_raw` / `emit_raw` so
tests characterize exactly what the host did.

## Rebuilding

The binary is checked in; rebuild whenever `src/lib.rs` or `Cargo.lock`
changes, and record the digests the build prints below: the probe's test
holds `src/lib.rs`, `Cargo.lock` and `nested_probe.wasm` to them, so a
source change without a rebuild fails.

```sh
apps/cyfr/test/integration/opus/support/test_wasm/nested_probe/build.sh          # build and write
apps/cyfr/test/integration/opus/support/test_wasm/nested_probe/build.sh --check  # build and compare
```

`build.sh` lays the crate out in a scratch directory with the canonical
formula `Cargo.toml` (`Cyfr.CargoToml.template(:formula)`) and the formula
world's WIT (`wit/formula`), builds it `--locked` to `Cargo.lock` with
`cargo component build --release --target wasm32-wasip2`, and remaps the
scratch directory and the Cargo home out of the paths rustc embeds, so the
bytes carry nothing of where they were built. The toolchain:

```
rustc 1.93.0 (254b59607 2026-01-19)
cargo-component 0.21.1
targets wasm32-wasip1 wasm32-wasip2
```

It reads crates.io for the crates `Cargo.lock` names. If the probe's
version ever changes, update `SELF_REF` in `src/lib.rs` and `@probe_ref` in
`../../nested_execution_helper.exs` together.

## Digests

```
src/lib.rs        sha256:dc14e4127322fb72f612cff1d612e5ca9c4501470af412b538ac104be60a4ced
Cargo.lock        sha256:695ceaa15daafe0e307ee5bb4497e044c8bcae806665f8923f015b8b86c6a1b2
nested_probe.wasm sha256:c205df383dca253e3b6c8b9d87490fa5ad8e15ae9dcadce1f09a55f9deb75971
```
