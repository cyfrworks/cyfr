<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# hostile guests

Components written in WebAssembly text that push against what the engine
lets one run hold (`Locus.Runtime.Engine.store_limits/1`), what its vault
hands it, what a request naming a connection may carry or what reaches a
guest of the credential CYFR attaches for it, that trap, or that use a feature the runtime refuses
(`Prima.ComponentFeatures`). Each `.wat` says what it does; the tests that
run them are `Locus.Runtime.StoreLimitsTest`, `Locus.Runtime.TrapTest`,
`Locus.Runtime.ComponentFeaturesTest`, `Locus.Runtime.WasiCapabilitiesTest` and `Locus.Runtime.VaultDenialTest`
in this suite,
`Locus.Runtime.MemoryBoundTest`, `Locus.Runtime.SecretAuditTest`,
`Locus.Runtime.AttachedFetchTest`, `Cyfr.FormulaHostCallsTest`,
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
| `wide_arithmetic` | reagent | adds two 128-bit integers with `i64.add128` and answers `{"carried":true}`; admitted |
| `socket_probe` | reagent, catalyst, formula | opens a TCP and a UDP socket through WASI and answers what the host said to each |

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
extra_memory.wasm          sha256:7a05d3fda1ed26681605591e2a6e86bc9010f1364842cf7c6fc3d185fc3ab4d7
wide_table.wat             sha256:4f824339d5fdd1f86bd8cecc419518ba38b43982331b2231606fe3760c051937
wide_table.wasm            sha256:2b594ca2dcb47a3ed1854ca7c6ad4c37ec5d72b66dd78dffc8453c7d2c465972
grower.wat                 sha256:4653562e719e9cf0afeeeb492eb5258d0f398b175877ca30b0ba0abf762f577c
grower.wasm                sha256:5d01278ec5d17784df8ecdde6f95689f3db6bf804b0781e888c57e35e6e83666
vault_probe.wat            sha256:4b110e1e10e335a559a97e1ad7067dd94f868c204603e53fbcb2158ac2e63f31
vault_probe.wasm           sha256:72a15e0ab85a585bc79772e6b3a73f86d5d7724c5cfb08260e146bc4e7b67278
attached_header_probe.wat  sha256:15557a58c237f2afc8cedf7aea4ac107575a25b06a1cb37d145074168468b468
attached_header_probe.wasm sha256:e6269ad0a060d8275bbae609fbbbc002ab884ff99a955bacdb7646d422322a38
credential_canary.wat      sha256:1a6454ba0eb640603d8e19e53798ab1b40f651857c2bd79c78ae983ed2d2022d
credential_canary.wasm     sha256:de98bb4ac754308e506ef44ef50e3c9c65ac48528f300e0c434ce69300af3815
trapper.wat                sha256:bd87bb0835163c620f3b0b67ec482798faace66aec66781581285421392c94f9
trapper.wasm               sha256:585bdd27e68350494160b2a2f050e1159b926b4564921083b6484a57129584fd
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
wide_arithmetic.wat        sha256:24d8a77f677b3b1bfb332edcb5cced1e056bdadee724b747502f58058fea7db2
wide_arithmetic.wasm       sha256:0d77f0ef7217f2449c83a0d08d7bb0ad2f1de42fecc334b657f1ba927e6a677b
socket_probe.wat           sha256:e113d384df5ea66d0c6ff53282665d641f33644f375187794ca8ede37368bcfb
socket_probe.wasm          sha256:d3e535bfe8f5a0b94c1f3414729139a734e76dd4c45de6da0d828f0db80dc31d
```
