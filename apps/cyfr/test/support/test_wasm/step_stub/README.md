<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# step-stub

A `model/chat@1` catalyst (`cyfr:catalyst` world) that answers at once, so
`Cyfr.Test.StepBench` and `mix cyfr.bench.step` time the host's path of a
turn's model step rather than a provider's.

Input selects the operation:

```jsonc
{"operation": "describe", "params": {}}                  // capabilities
{"operation": "describe", "params": {"model": "…"}}      // + a 1,000,000-token window
{"operation": "models",   "params": {}}
{"operation": "chat",     "params": {…}}                 // reads STUB_API_KEY, then
                                                         // emits four text.delta, usage
                                                         // and stop, and answers one
                                                         // text block
```

The bench registers it as `catalyst:local.step-stub:0.1.0` with an
`api_key` need whose field is `STUB_API_KEY`.

## Rebuilding

The binary is checked in; rebuild whenever `src/lib.rs` or `Cargo.lock`
changes, and record the digests the build prints below: the step bench's
test holds `src/lib.rs`, `Cargo.lock` and `step_stub.wasm` to them, so a
source change without a rebuild fails.

```sh
apps/cyfr/test/support/test_wasm/step_stub/build.sh          # build and write
apps/cyfr/test/support/test_wasm/step_stub/build.sh --check  # build and compare
```

`build.sh` lays the crate out in a scratch directory with the canonical
catalyst `Cargo.toml` (`Cyfr.CargoToml.template(:catalyst)`) and the
catalyst world's WIT (`wit/catalyst`), builds it `--locked` to `Cargo.lock`
with `cargo component build --release --target wasm32-wasip2`, and remaps
the scratch directory and the Cargo home out of the paths rustc embeds, so
the bytes carry nothing of where they were built. The toolchain:

```
rustc 1.93.0 (254b59607 2026-01-19)
cargo-component 0.21.1
targets wasm32-wasip1 wasm32-wasip2
```

It reads crates.io for the crates `Cargo.lock` names.

## Digests

```
src/lib.rs     sha256:6e82e25d5dcdb375abab1e8fd3b4af37e53e9b361c4db66083f7b8bcb8923421
Cargo.lock     sha256:695ceaa15daafe0e307ee5bb4497e044c8bcae806665f8923f015b8b86c6a1b2
step_stub.wasm sha256:93a8cf7d10930184f0141ea0f404e64d2fa4d9659c852964cef70dc4fb483f6e
```
