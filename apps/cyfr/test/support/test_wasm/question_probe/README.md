<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# question-probe

A catalyst (`cyfr:catalyst` world) that asks its person before each
statement it is handed, through `cyfr:question/ask`, and reports what it
was told. It does nothing outside itself: a statement it is allowed to run
is reported `allowed` and touched no further. CYFR's tests publish it with
a manifest that declares two actions, and `component-guide.md` ("Asking
before an action") shows its source as the worked example.

```jsonc
// The manifest the tests publish it with, beside its name and version:
{"type": "catalyst",
 "asks": [{"name": "delete_table", "title": "delete a table"},
          {"name": "delete_rows",  "title": "delete rows from a table"}]}

// Its input: each statement is asked about on its own, in order.
{"operation": "run", "params": {"statements": ["DROP TABLE users", "DELETE FROM logs"]}}

// Its output: what each ask was answered.
{"status": 200, "data": {"results": [{"statement": "DROP TABLE users", "answer": "allowed"}, …]}}
```

A statement that starts with `DELETE` is asked under `delete_rows`, one
that starts with `UNDECLARED` under `undeclared_action`, which the manifest
does not declare, and any other under `delete_table`, the harsher action.
An answer is `allowed`, `denied`, `unattended`, `invalid` or
`unavailable`.

## Rebuilding

The binary is checked in; rebuild whenever `src/lib.rs` or `Cargo.lock`
changes, or the `catalyst` world it is built against (`wit/catalyst`,
`Prima.CargoToml`'s catalyst scaffold), and record the digests the build
prints below.

```sh
apps/cyfr/test/support/test_wasm/question_probe/build.sh          # build and write
apps/cyfr/test/support/test_wasm/question_probe/build.sh --check  # build and compare
```

`build.sh` runs `apps/cyfr/test/support/test_wasm/build-fixture.sh`, which
lays the crate out with the canonical catalyst `Cargo.toml`
(`Prima.CargoToml.template(:catalyst)`) and the catalyst world's WIT, and
is the one pin of the toolchain.

## Digests

```
src/lib.rs          sha256:f25a40e674a974a87add3efd70f8b2d32ea35394d7670aad2b4b9f96f9638fc7
Cargo.lock          sha256:695ceaa15daafe0e307ee5bb4497e044c8bcae806665f8923f015b8b86c6a1b2
question_probe.wasm sha256:0897946e1f8df3ab82e63c0e331b6775d85d478800fbfcd04937f59dcb0d46ea
```
