<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# formula-probe

A formula (`cyfr:formula` world) that makes the invoke calls its input
lists, in order, and answers every answer as it came. It does nothing
else. The runner crate's tests run it (`apps/locus/runner/tests/formula.rs`)
with the scripts their cases need: children called, spawned and streamed,
tasks awaited, polled and cancelled, and requests that do not read.

```jsonc
// Its input: each step one of the eight invoke functions and its argument,
// passed as it is when it is a string and as its JSON text otherwise.
{"steps": [{"fn": "spawn", "arg": {"tool": "execution", "action": "run", "args": {"reference": "…"}}},
           {"fn": "await", "arg": "task_1"},
           {"fn": "call",  "arg": "not json"}]}

// Its output: each answer as its JSON value, or as its text when it is no JSON.
{"answers": [{"task_id": "task_1"}, {"status": "completed", "output": {…}, "task_id": "task_1"}, …]}
```

The functions are `call`, `spawn`, `await`, `await-all`, `await-any`,
`poll`, `cancel` and `emit`; a step naming another answers
`{"probe_error": …}` and calls nothing.

## Rebuilding

The binary is checked in; rebuild whenever `src/lib.rs` or `Cargo.lock`
changes, or the `formula` world it is built against (`wit/formula`,
`Prima.CargoToml`'s formula scaffold), and record the digests the build
prints below.

```sh
apps/locus/test/support/runtime/test_wasm/formula_probe/build.sh          # build and write
apps/locus/test/support/runtime/test_wasm/formula_probe/build.sh --check  # build and compare
```

`build.sh` runs `apps/cyfr/test/support/test_wasm/build-fixture.sh`, the
suites' one recipe for a Rust fixture, which lays the crate out with the
canonical formula `Cargo.toml` (`Prima.CargoToml.template(:formula)`) and
the formula world's WIT, and is the one pin of the toolchain.

## Digests

```
src/lib.rs         sha256:f79d41d4531c84d6fee068dfd6b8567acd99059ded1f7e503fce142baddce11a
Cargo.lock         sha256:695ceaa15daafe0e307ee5bb4497e044c8bcae806665f8923f015b8b86c6a1b2
formula_probe.wasm sha256:2fb26932b56435e3e4fa35cbff7890c13f8fec56232599661aabdd87dc0cd958
```
