<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# Test WASM files

The runtime suite's WebAssembly binaries, each checked in beside the
WebAssembly text it is built from.

| File | Is |
|---|---|
| `math.wasm` | a core module exporting `sum`, `add` and `multiply`, each over two i32s; CYFR's suite holds a byte copy (`apps/cyfr/test/support/test_wasm/math.wasm`) |
| `echo.wasm` | a reagent component whose `compute` answers its input unchanged |
| `spin.wasm` | a reagent component whose `compute` never returns, so only the runner's watchdog ends it |
| `hostile/` | components that push against the engine's bounds or use a refused feature, with their own `build.sh` and README |

## Rebuilding

`build.sh` builds each binary from its `.wat` with `_tools/wasm-tools` at
the version `scripts/wasm-tools.sh` pins, and nothing else, and writes
CYFR's copy of `math.wasm` with Locus's; it refuses a missing or other
`wasm-tools`, naming `scripts/wasm-tools.sh install _tools`. A core
module is parsed and stripped of its custom sections; `echo` and `spin`
are then given the reagent world's WIT and made components, which record
the version of the tool that made them. Rebuild whenever a `.wat` changes
or the pin moves; `build.sh --check` compares a fresh build with what is
checked in, and `scripts/check-test-wasm.sh` runs it.

```sh
apps/locus/test/support/runtime/test_wasm/build.sh           # build and write
apps/locus/test/support/runtime/test_wasm/build.sh --check   # compare only
```
