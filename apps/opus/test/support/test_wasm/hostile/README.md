<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# hostile guests

Components written in WebAssembly text that push against what the engine
lets one run hold (`Opus.Runtime.store_limits/1`). Each `.wat` says what
it does; the tests that run them are `Opus.StoreLimitsTest` in this
suite, and `Opus.MemoryBoundTest` in CYFR's.

| Guest | World | Does |
|---|---|---|
| `extra_memory` | reagent | declares a second linear memory |
| `wide_table` | reagent | declares a table one element past the bound |
| `grower` | reagent | grows its memory and its table until refused, and answers the sizes reached |

## Rebuilding

The binaries are checked in. `build.sh` builds each from its `.wat` with
wabt `wat2wasm` 1.0.41 and `wasm-tools` 1.244.0 (the component embeds the
latter's version, so another version gives other bytes), against the WIT
under `wit/`; `build.sh --check` compares a fresh build with what is
checked in. Rebuild whenever a `.wat` changes and record what the build
prints below: `Opus.StoreLimitsTest` holds each file to its digest, so a
source changed without a rebuild fails.

```sh
apps/opus/test/support/test_wasm/hostile/build.sh           # build and write
apps/opus/test/support/test_wasm/hostile/build.sh --check   # compare only
```

```text
extra_memory.wat  sha256:975aba9fb5c33c053cebe9420cb2dfc44e66e4873388ad9a3b1a78fe645a9d2d
extra_memory.wasm sha256:906871b6f762ce5a99737c1575dd02e4797306371cd06ca89105be36b21f31d5
wide_table.wat    sha256:bd0d751e454cc09c55b9019ae4cae63b030d0fd0eaa2df43f0858d715b9de488
wide_table.wasm   sha256:d2fb6afac827c8ed10c71ab98dcc2c55f00215421004e0a7876ee950a087711d
grower.wat        sha256:e9a8a932b1b02902f1a219bf98b76a7cc051a767f7d56f53272f6f1c2e6bfb03
grower.wasm       sha256:f915f13a65d49810417abfe67ae5dec31c1ffe6ffbde40167d6f0247646e5e7b
```
