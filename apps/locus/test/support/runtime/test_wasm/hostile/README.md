<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# hostile guests

Components written in WebAssembly text that push against what the engine
lets one run hold (`Locus.Runtime.Engine.store_limits/1`), what its vault
hands it, what a request naming a connection may carry or what reaches a
guest of the credential CYFR attaches for it, that trap, or that use a feature the runtime refuses
(`Prima.ComponentFeatures`). Each `.wat` says what it does. The validator's
own defaults leave the last five guests' features off, so the check answers
each of them as invalid WebAssembly rather than as a refused feature's
(`tests/fixtures/component_features.json`, which `Prima.ComponentFeaturesTest`
plays). The tests that run them are `Locus.Runtime.StoreLimitsTest`, `Locus.Runtime.TrapTest`,
`Locus.Runtime.ComponentFeaturesTest`, `Locus.Runtime.WasiCapabilitiesTest` and `Locus.Runtime.VaultDenialTest`
in this suite,
`Locus.Runtime.MemoryBoundTest`, `Locus.Runtime.SecretAuditTest`,
`Locus.Runtime.AttachedFetchTest`, `Cyfr.FormulaHostCallsTest`,
`Opus.Schedules.SchedulerTest`, `CyfrWeb.WebhookFlowIntegrationTest`,
`Aqua.LaunchTest` and `Compendium.ComponentFeaturesAdmissionTest` in
CYFR's, the runner crate's (`apps/locus/runner/tests/`, `stream_*`, `fetch_twice` and `fetch_garbage` among them), and the worker image's `tests/locus-runtime-image/runners.py` and
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
| `stackful_lift` | reagent | lifts `compute` async without a callback; refused for the component-model async stackful ABI |
| `async_cancel` | reagent | `sync_lift` beside a `subtask.cancel` builtin marked `async`; refused for the more async builtins feature |
| `error_context` | reagent | `sync_lift` beside an `error-context.drop` builtin; refused for the component-model error-context feature |
| `thread_index` | reagent | `sync_lift` beside a `thread.index` builtin; refused for the component-model threading feature |
| `legacy_try` | reagent | runs a legacy `try` block with a `catch_all`; refused for the legacy exception-handling feature |
| `nested_output` | reagent | answers its input's length in nested arrays, a JSON value that deep, for the runner's depth bound on a guest's output |
| `storage_flood` | catalyst | calls its storage forever with a request that is no JSON: each call is refused before any host call and is one `storage.call` event |
| `vault_log_flood` | catalyst | asks its vault forever for a name carrying a control byte: each read is refused unreported, and is one line the runner would log |
| `slow_validate` | none | imports an instance of 1,500 functions and instantiates a component of it 3,000 times: slow to validate, for a run whose budget ends while the compile thread works |
| `stream_once` | catalyst | opens one stream with its input as the request, reads it once, closes it and answers that read: a guest that closes a stream early and completes |
| `stream_flood` | catalyst | opens, reads once and closes streams with its input as the request until one is refused, and answers the refusal |
| `fetch_twice` | catalyst | sends its input as its request twice in one run and answers the second answer: a guest that follows a redirect back to the URL it asked |
| `stream_hold` | catalyst | opens a stream and holds it unread while it reads a second sixty times, and answers the last read: an answer arriving whole that its guest never reads |
| `stream_aside` | catalyst | opens a stream and leaves it open and unread, reads a second once and closes it, and answers that read: a stream dropped with its run's store |
| `stream_closed` | catalyst | opens a stream and closes it unread, reads a second once and closes it, and answers that read: an answer arriving after its guest closed it |
| `stream_late` | catalyst | opens a stream, reads a second sixty times, then reads the first once and answers that read: an answer read some six seconds after it arrived |
| `stream_pile` | catalyst | opens streams with its input as the request, closing none, until one is refused, and answers the refusal |
| `fetch_garbage` | catalyst | hands its fetch the text `{"method":`, which is no JSON, and answers the fetch's answer |
| `stream_twice` | catalyst | opens a stream, reads it twice and answers the second read |
| `stream_until` | catalyst | opens a stream and reads it until a read hands data, an error or the end, and answers that read |

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
stackful_lift.wat          sha256:684a82ff8ceb5b2eb829b4c3dbfb13362a4b6737e7b797cb995eeec11e6257f1
stackful_lift.wasm         sha256:49a875f253c1c30e489ce59f0fe73bb2b42f0403de132c3264e7ee535c02ba21
async_cancel.wat           sha256:aa89b5fb002d71bf91e3399b1c2ca7c39a73df6d8a96077c2c23b57cf12133eb
async_cancel.wasm          sha256:4c9498900a51a4673b8adfd3baa3cb258c1afe431aa8e43177b7dccccaf3c973
error_context.wat          sha256:9449fdf13fdd7f3d5ea3122951586f82614e1903b41b835af90fd7c47bd23fa8
error_context.wasm         sha256:9a08c0c7e1b04bd8674d5f2b76778e50ff71bb0b9f6ee475b2b3ad05233daf8b
thread_index.wat           sha256:04f120ad4c7f342e5d1b039dd955e0ea5942d45570f8388ec93c5ed46fa6a965
thread_index.wasm          sha256:43d05d009f61e8b9dd152adcbd1ed5392c99973285a3b4f61d1b377e5c8d48cd
legacy_try.wat             sha256:2adc44fa64ff904bf6a019c2bbdfb9d6f44d4628d7e616bc3e72c5e79d52ab4a
legacy_try.wasm            sha256:244f4dbd5d1a29ff8c0b37fc84d21f3630f88b0b7451de28108610c7ea1dd454
nested_output.wat          sha256:3ce720e5c66fb39198f2ec614efc5e28b01b4c436fc9ab23c00d3203758f55f6
nested_output.wasm         sha256:dd21f5cce9f42efea0dd574d0a49293f81b73bf83bd98ade4cbda2d6a6169961
storage_flood.wat          sha256:7e78a283bc928b0f6dc732b7c42a9a518f3bede2de981c5823c45bda33deb67b
storage_flood.wasm         sha256:6ac5b830ad0faedf0cf223927120972ef1843aa62437db6bd9ed4d0708990622
vault_log_flood.wat        sha256:1c223ece263e5549e7ee246da17a98dc9494eeb125d85cb9d3a712f94ce6dcf2
vault_log_flood.wasm       sha256:971e8407c7934f41c2495b85f87fb34c9048975b91b52cdbf4952e117d9c8e6d
slow_validate.wat          sha256:0cfefb7c8520d6da2f62c6c8fc3a7d2e81352d7cee84d409d94917d72bc5cdb8
slow_validate.wasm         sha256:157de6295fc6e0dd345cfd777edc98464bb5fd932d99e97a09fbfe1564648ff6
stream_once.wat            sha256:3f414255276c3799bd582762344092a8e51c1bf0232005aff2ebb17483e3defc
stream_once.wasm           sha256:30630a47b9d054326a6f4d481ad512e9de0f4e9cd58c48e970d86db0bd9f5872
stream_flood.wat           sha256:5ffaf203420f11fd8b144f6deac1d04b2c5f70b04ef9c9d5bad017bf5a9275fd
stream_flood.wasm          sha256:e396f2cb1c6a2043b364bf98619ab5799b7bf129bb4707e981e8e7210dc2bd4d
fetch_twice.wat            sha256:d876111b0ea9e5696bc0ca273445adbccd729ea5242b22cc2a046d2f8164bc41
fetch_twice.wasm           sha256:50b507f2cd70b3b98f1e08c2084a3c91c43db56c91b69edfec95dee0929bab73
stream_hold.wat            sha256:acd3e32c4f4e1849a1e38b781fc96f75218b37b7cddb92d78d9ee5063a44f367
stream_hold.wasm           sha256:b0e9cedd8f83162e9f9b1f6ae5cb61005883f9bc5c4e9ca1df818235d6bedbb4
stream_aside.wat           sha256:907ee7f4691e71f9bf363f9692a6cef1021ff0c0296d8a8d1851acd0fef20b36
stream_aside.wasm          sha256:e99551468d57d4298f5bece99b8ba89e8e024b0bd90e3b94591e13c818b979d8
stream_closed.wat          sha256:b2496e4f75d266251c537661f53d29014b768b7b4dcfde658ecef88f96915210
stream_closed.wasm         sha256:cbfc083ed020aeeb4b69b7d0496a7d3d30883b668a211672e998c021dcda2613
stream_late.wat            sha256:f9a002a03c34aad30010bd074069640a965feb8b078d14528041a9812cad9875
stream_late.wasm           sha256:81c0a156f931529586589029d644a51f0ac412d002a86ca21938f9fb13fbbece
stream_pile.wat            sha256:b1fa1792dc0a720ad805397dc9c9e48d71d0e17545e667b944efb4240583fc88
stream_pile.wasm           sha256:5428547d54d0acf3a0ecef919ccb0de38ec97a6f4249bf4fa005474e24a77447
fetch_garbage.wat          sha256:1aeaed4fa0a5799495f17bff41ca5151cb129be24e0c7d75e5aa3aa354d560e8
fetch_garbage.wasm         sha256:1e746c7f664de67f0e5efd1b20e649ddbf67bd857323aa760688697023ada74a
stream_twice.wat           sha256:79fb683d2a1670350c5f80fddd874b63eb7e45e056c8a41d6b68795f29b0523a
stream_twice.wasm          sha256:451be323de707ba2a913d320a2b99103b623e1699acbe460d5fd3122abc6428f
stream_until.wat           sha256:2c3d7e80e5b4ea81b67d75c1e2fd68d7770851359b95c489c619fd14705b5a3d
stream_until.wasm          sha256:5c6d6471e2f48e7eee3a5a3f54be528d023084ad16ae7565b11fa6969bc261fc
```
