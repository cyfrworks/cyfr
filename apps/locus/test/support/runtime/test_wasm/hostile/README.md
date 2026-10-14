<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# hostile guests

Components written in WebAssembly text that push against what the engine
lets one run hold (`Locus.Runtime.Engine.store_limits/1`), what its vault hands
it, what a request naming a connection may carry, or what reaches a guest
of the credential CYFR attaches for it, that trap, or that use a feature
the runtime refuses (`Prima.ComponentFeatures`). Each `.wat` says what it
does; the tests that run them are `Locus.Runtime.StoreLimitsTest`,
`Locus.Runtime.TrapTest`, `Locus.Runtime.ComponentFeaturesTest` and
`Locus.Runtime.VaultDenialTest` in this suite,
`Locus.Runtime.MemoryBoundTest`, `Locus.Runtime.SecretAuditTest`,
`Locus.Runtime.AttachedFetchTest`, `Locus.Runtime.FormulaHandlerTest`,
`Opus.Schedules.SchedulerTest`, `CyfrWeb.WebhookFlowIntegrationTest`,
`Aqua.LaunchTest` and `Compendium.ComponentFeaturesAdmissionTest` in
CYFR's, and the worker image's `tests/locus-runtime-image/runners.py` and
`tests/locus-runtime-image/canary.py`.

| Guest | World | Does |
|---|---|---|
| `extra_memory` | reagent | declares a second linear memory |
| `wide_table` | reagent | declares a table one element past the bound |
| `grower` | reagent | grows its memory and its table until refused, and answers the sizes reached |
| `vault_probe` | catalyst | reads a granted, an ungranted, an overlong and a control-byte field name |
| `attached_header_probe` | catalyst | sends its input as its one request, naming a connection, and answers the request's answer; an input that adds an `Authorization` header is refused by shape |
| `credential_canary` | catalyst | sends its input as its one request, naming a connection, reads `CANARY_KEY` from its vault, and writes the request's answer and the read's result to one event and to its output |
| `trapper` | reagent | traps on the input `{"trap":true}` and answers `{"ran":true}` to any other |
| `async_lift` | reagent | lifts `compute` async with a callback; refused for the component-model async feature |
| `sync_lift` | reagent | `async_lift` lifted synchronously; admitted |
| `gc_alloc` | reagent | allocates a GC struct; refused for the GC feature |
| `exception_throw` | reagent | throws a tag and catches it with `try_table`; refused for the exception-handling feature |
| `externref_table` | reagent | declares a table of `externref`; refused for GC's reference types |

## Rebuilding

The binaries are checked in. `build.sh` builds each from its `.wat` with
`_tools/wasm-tools` at the version `scripts/wasm-tools.sh` pins, and
nothing else, and refuses a missing or other `wasm-tools`, naming
`scripts/wasm-tools.sh install _tools`: a core module is parsed, stripped
of its custom sections, given its world's WIT from `wit/` and made a
component; a `.wat` that is a whole component is parsed as it stands. The
component records the version of the tool that made it, so another version
gives other bytes. `build.sh --check` compares a fresh build with what is
checked in, and `scripts/check-test-wasm.sh` runs it. Rebuild whenever a
`.wat` changes or the pin moves, and record what the build prints below:
`Locus.Runtime.StoreLimitsTest` holds each file to its digest, so a source
changed without a rebuild fails.

```sh
apps/locus/test/support/runtime/test_wasm/hostile/build.sh           # build and write
apps/locus/test/support/runtime/test_wasm/hostile/build.sh --check   # compare only
```

```text
extra_memory.wat           sha256:4f77c1473bee65d056d60911c661e41eca27ba08644869da6bb0b55f3e5cf62e
extra_memory.wasm          sha256:219eb7033c8f9a328e05b441441eef8f9aa75fdd09714ff2320530b6486eafdb
wide_table.wat             sha256:4f824339d5fdd1f86bd8cecc419518ba38b43982331b2231606fe3760c051937
wide_table.wasm            sha256:c859d1b0b879e6cc3e6e9c0a0a7a45f0c9f0a2adae1b1becaac8d6bb8466e17c
grower.wat                 sha256:4653562e719e9cf0afeeeb492eb5258d0f398b175877ca30b0ba0abf762f577c
grower.wasm                sha256:7e7b1f9a6a4046af9c317f34230e8ddc49dba8fe2e37cd3920ba856f5745fead
vault_probe.wat            sha256:4b110e1e10e335a559a97e1ad7067dd94f868c204603e53fbcb2158ac2e63f31
vault_probe.wasm           sha256:2bdd667749cf8cf6379d58e09c8a64694825bf8eac7758be365406950b0f6b8e
attached_header_probe.wat  sha256:15557a58c237f2afc8cedf7aea4ac107575a25b06a1cb37d145074168468b468
attached_header_probe.wasm sha256:e437e51b231f7619fdb6fe7a9c3ffc2d63631f69c97b76b5a4f231a415c2c341
credential_canary.wat      sha256:1a6454ba0eb640603d8e19e53798ab1b40f651857c2bd79c78ae983ed2d2022d
credential_canary.wasm     sha256:a060410f737ba9418beab64d568ecd17e95424909e99cca86e021a64e1baa0e1
trapper.wat                sha256:bd87bb0835163c620f3b0b67ec482798faace66aec66781581285421392c94f9
trapper.wasm               sha256:6c0709e585eb71f180c8f0386324aec45d4cd19db13ddc41e76ebdc7c1e1eb8c
async_lift.wat             sha256:c990b80ab5dc7f5ae6051c16e3722f8e402b38b123f385f63785302a8f470e8f
async_lift.wasm            sha256:e1429137b0c6056577d31a5bff20be298e28a0690ef1259e393d34e345273c39
sync_lift.wat              sha256:83a4419d4e24ab767b75cfe637a0e8a765533ffcd142b500c535074a58ca7df9
sync_lift.wasm             sha256:a225d550f65257c943f0ee51eed2a24a5ed3266db81c122acd28daa9c84d7845
gc_alloc.wat               sha256:0eac783a3c84b3ba341a745f5cf3410fc31b18faaeae2e83a32be17c0472e9e8
gc_alloc.wasm              sha256:ca09d8c97e10c7c5528d00da279debd1c5a35a064c1000666d1412af533ee0c8
exception_throw.wat        sha256:557fad0ae8479152bfddd68c3f6ecd1d728cac41cbc12017dfa888b78eb87f64
exception_throw.wasm       sha256:f558999c8ca27b298dae43ed58d7f7d53062a160edf399dc6168bd1ec655aaba
externref_table.wat        sha256:f730a802a33e7ce0bb6b0aa070662d9b4818138b6fec3328ec4c99193aa83bc6
externref_table.wasm       sha256:63c8f0725b2704e0ca504d9f6a69414999bb8c722b98d30a3df47d5709e09b62
```
