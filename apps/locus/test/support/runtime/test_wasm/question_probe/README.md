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
{"operation": "run", "params": {"statements": ["DROP TABLE users", "DELETE FROM logs WHERE id = 7"]}}

// Its output: what each ask was answered.
{"status": 200, "data": {"results": [{"statement": "DROP TABLE users", "answer": "allowed"}, …]}}
```

It reads a statement only when it is exactly one of two shapes, its words
separated by single spaces: `DROP TABLE <table>`, asked under
`delete_table`, and `DELETE FROM <table> WHERE id = <id>`, asked under
`delete_rows`, a table's name being a lowercase letter then lowercase
letters, digits and underscores, and an id one to eighteen digits. Any
other statement, two statements joined, a clause it does not read, is
`declined` and nobody is asked. An answer is otherwise `allowed`,
`denied`, `unattended`, `invalid` or `unavailable`.

## Rebuilding

The binary is checked in; rebuild whenever `src/lib.rs` or `Cargo.lock`
changes, or the `catalyst` world it is built against (`wit/catalyst`,
`Prima.CargoToml`'s catalyst scaffold), and record the digests the build
prints below.

```sh
apps/locus/test/support/runtime/test_wasm/question_probe/build.sh          # build and write
apps/locus/test/support/runtime/test_wasm/question_probe/build.sh --check  # build and compare
```

`build.sh` runs `apps/cyfr/test/support/test_wasm/build-fixture.sh`, the
suites' one recipe for a Rust fixture, which
lays the crate out with the canonical catalyst `Cargo.toml`
(`Prima.CargoToml.template(:catalyst)`) and the catalyst world's WIT, and
is the one pin of the toolchain.

## Digests

```
src/lib.rs          sha256:b68ac7e7d929c5ca7391e73fd673425588e84c219b7b97ec1fac2d0e68ca9e71
Cargo.lock          sha256:695ceaa15daafe0e307ee5bb4497e044c8bcae806665f8923f015b8b86c6a1b2
question_probe.wasm sha256:b9b3f4cd0372c2ff3513742843b7ae4f4b1fde25f89432ca99d4cbcfcdcfed0b
```
