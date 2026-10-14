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

Each binary is built with the pinned `wasm-tools` alone,
`_tools/wasm-tools` at the version `scripts/wasm-tools.sh` pins. A core
module is parsed and stripped of its custom sections; `echo` and `spin`
are then given the reagent world's WIT and made components, which record
the version of the tool that made them. From the repository root, after
changing a `.wat` (the commands in `echo.wat` and `spin.wat` name an
earlier toolchain):

```sh
scripts/wasm-tools.sh install _tools
d=apps/locus/test/support/runtime/test_wasm
_tools/wasm-tools parse "$d/math.wat" | _tools/wasm-tools strip --all -o "$d/math.wasm"
cp "$d/math.wasm" apps/cyfr/test/support/test_wasm/math.wasm
t=$(mktemp -d)
for name in echo spin; do
  _tools/wasm-tools parse "$d/$name.wat" | _tools/wasm-tools strip --all -o "$t/$name.core.wasm"
  _tools/wasm-tools component embed wit/reagent --world reagent "$t/$name.core.wasm" -o "$t/$name.embedded.wasm"
  _tools/wasm-tools component new "$t/$name.embedded.wasm" -o "$d/$name.wasm"
done
rm -r "$t"
```

`scripts/check-test-wasm.sh` builds each afresh and fails naming any
binary that is not its source's build.
