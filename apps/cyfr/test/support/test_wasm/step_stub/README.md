<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# step-stub

A `model/chat@1` catalyst (`cyfr:catalyst` world) that answers at once, so
`Cyfr.Test.StepBench` and `mix cyfr.bench.step` time the host's path of a
turn's model step rather than a provider's. It reads no credential.

Input selects the operation:

```jsonc
{"operation": "describe", "params": {}}                  // capabilities
{"operation": "describe", "params": {"model": "…"}}      // + a 1,000,000-token window
{"operation": "models",   "params": {}}
{"operation": "chat",     "params": {…}}                 // emits four text.delta, usage
                                                         // and stop, and answers one
                                                         // text block
```

A `chat` whose last user message's text is a JSON object naming
`bench_fetch` first makes that request through `cyfr:http/fetch`, before
its first delta, and refuses with the host's error, or `http_error`,
unless it is answered 200. The text is the object whole, or the object
after a display name and `": "`, as the turn loop writes a line where
several people talk; it is split at the first `": "`, since a display
name holds none. The bench sends its request that way, as its turn's
message:

```jsonc
{"bench_fetch": {"method": "GET", "url": "http://127.0.0.1:…/one-byte",
                 "connection": "api_key"}}               // attached mode only
```

Any other `chat`, a person's words or a `chat` with no messages, makes no
request and answers the same.

The bench registers it as `catalyst:local.step-stub:0.1.0` with an
`api_key` need whose field is `STUB_API_KEY`, which CYFR attaches to a
request naming the need as its `connection`. The masking suites register
it with a disclose-only need, bound to a disclosed entry whose field and
token CYFR hands each run, so both are in the run's masking set; the stub
writes their text and never reads them.

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
catalyst `Cargo.toml` (`Prima.CargoToml.template(:catalyst)`) and the
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
src/lib.rs     sha256:8de6c09c8f0707a18480d61a273a041b65b81e1765d186cb97d79c775cb9d794
Cargo.lock     sha256:695ceaa15daafe0e307ee5bb4497e044c8bcae806665f8923f015b8b86c6a1b2
step_stub.wasm sha256:6b5cec15143b6c420de8a632075c0b0ac56f46d3b3f9273b7345caf34ea38f6b
```
