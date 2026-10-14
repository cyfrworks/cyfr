<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# Test WASM files

CYFR's suite's WebAssembly fixtures.

| File | Is |
|---|---|
| `math.wasm` | a byte copy of the runtime suite's `apps/locus/test/support/runtime/test_wasm/math.wasm`, built from the `math.wat` there; it changes only when that one is rebuilt |
| `chat_fixture/` | a `model/chat@1` catalyst that plays the script its request carries, built from Rust; its README says how |
| `step_stub/` | a `model/chat@1` catalyst that answers at once, for timing the host's path of a model step, built from Rust; its README says how |
| `build-fixture.sh` | builds a Rust fixture: `chat_fixture/build.sh`, `step_stub/build.sh` and `apps/cyfr/test/integration/runtime/support/test_wasm/nested_probe/build.sh` each call it with their name, world and directory, and keep their `--check` |

`scripts/check-test-wasm.sh` checks that `math.wasm` is that byte copy and
that each Rust fixture is its source's build (`--wat-only` skips the Rust
builds, for a host without `cargo` and `cargo-component`).
