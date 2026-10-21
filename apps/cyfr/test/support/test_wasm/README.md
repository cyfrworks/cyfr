<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# Test WASM files

CYFR's suite's WebAssembly fixtures.

| File | Is |
|---|---|
| `guests/` | `reagent.wasm`, `catalyst.wasm` and `formula.wasm`, a component of each executable world that answers `{"ran":true}` to any input but `{"trap":true}`, on which it traps; built from the `.wat` beside each by `guests/build.sh`, and read through `Cyfr.Test.Guests.wasm/1` |
| `chat_fixture/` | a `model/chat@1` catalyst that plays the script its request carries, built from Rust; its README says how |
| `step_stub/` | a `model/chat@1` catalyst that answers at once, for timing the host's path of a model step, built from Rust; its README says how |
| `build-fixture.sh` | builds a Rust fixture: `chat_fixture/build.sh`, `step_stub/build.sh` and `apps/cyfr/test/integration/runtime/support/test_wasm/nested_probe/build.sh` each call it with their name, world and directory, and keep their `--check` |

`guests/build.sh` builds each guest with `_tools/wasm-tools` at the
version `scripts/wasm-tools.sh` pins, and nothing else, and refuses a
missing or other `wasm-tools`, naming `scripts/wasm-tools.sh install
_tools`: the core module is parsed, stripped of its custom sections,
given its world's WIT from `wit/` and made a component, which records the
version of the tool that made it. Rebuild whenever a `.wat` changes or the
pin moves; `guests/build.sh --check` compares a fresh build with what is
checked in.

`scripts/check-test-wasm.sh` checks that each guest and each Rust fixture
is its source's build (`--wat-only` skips the Rust builds, for a host
without their toolchain). `build-fixture.sh` refuses a missing or other
toolchain, naming it.
