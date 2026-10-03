<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 CYFR Works Inc. -->

# chat-fixture

A `model/chat@1` catalyst (`cyfr:catalyst` world) whose `chat` plays the
script its request carries and answers what it was given, so a test drives
everything the contract lets a model catalyst emit and answer through the
real engine, the wire and a turn. It holds no test logic: the events, the
answer, a refusal, a trap and a wait are all the script's. Nothing is
dialled. It is test support and never seed media;
`Cyfr.Test.ChatFixture` lays it as `catalyst:local.chat-fixture:0.1.0` with
an `api_key` need whose field is `FIXTURE_API_KEY`.

```jsonc
{"operation": "describe", "params": {}}              // capabilities
{"operation": "describe", "params": {"model": "…"}}  // + a 1,000,000-token window
{"operation": "models",   "params": {}}
{"operation": "chat",     "params": {…}}             // reads FIXTURE_API_KEY, then
                                                     // plays the script
```

## The script

The script is a JSON object in a fenced block, opened by
`` ```chat-fixture `` and closed by `` ``` ``, in the text of a `user`
message of the request: a person's own line, which is what a turn sends a
catalyst. The last block of the last `user` message that carries one is the
script (a turn that left the model nothing to read is followed by the
person's next line in the same `user` message), and the step played is
`steps[n]` where `n` is how many `assistant` messages follow that message,
so each `chat` of a turn plays the next step with nothing kept between
calls. A request with no script plays a greeting: two
`text.delta`, `usage`, `stop`, and one text block. A script that is not
JSON, or that has no step `n`, is refused as `invalid_request`.

```jsonc
{"steps": [
  {
    "emit": [                       // in order, through cyfr:emit/events
      {"type": "text.delta", "text": "Looking."},
      {"type": "tool_call.start", "index": 0, "id": "c1", "name": "notes"},
      {"$repeat": 3, "event": {"type": "text.delta", "text": "."}}
    ],
    "sleep_ms": 0,                  // then wait this long
    "then": "trap",                 // then trap, answering nothing
    "refuse": {"status": 502, "error": {"type": "…", "message": "…"}},
                                    // or answer this envelope as it stands
    "answer": {"content": [], "stop_reason": "tool_call", "usage": {}}
                                    // or answer this as the envelope's data
  }
]}
```

An event is emitted as it stands: the fixture checks nothing about it.
Three words are the fixture's own, in `emit`, `refuse` and `answer` alike:

| Word | Played as |
|------|-----------|
| `{{key}}` in a string | the bound key |
| `{{key:a:b}}` in a string | the key's bytes `a..b`; either bound may be left out |
| `{"$fill": text, "bytes": n}` as a value | `text` repeated to `n` bytes |

so a script names the key without holding it, and an event past the size
bound is made in the guest. An `emit` item `{"$repeat": n, "event": {…}}`
emits the event `n` times.

Every answer carries, beside the script's `answer`, what the fixture was
given and what the host replied:

```jsonc
"fixture": {
  "step": 0,
  "received": {…},                  // the request's params, whole
  "emitted": [                      // one per emit item, in order
    {"ok": true, "sequence": "1.1"},
    {"repeat": 3, "accepted": 3, "refused": 0, "first_refusal": null}
  ]
}
```

## Rebuilding

The binary is checked in; rebuild whenever `src/lib.rs` or `Cargo.lock`
changes, and record the digests the build prints below: the contract test
holds `src/lib.rs`, `Cargo.lock` and `chat_fixture.wasm` to them, so a
source change without a rebuild fails.

```sh
apps/cyfr/test/support/test_wasm/chat_fixture/build.sh          # build and write
apps/cyfr/test/support/test_wasm/chat_fixture/build.sh --check  # build and compare
```

`build.sh` lays the crate out in a scratch directory with the canonical
catalyst `Cargo.toml` (`Prima.CargoToml.template(:catalyst)`) and the
catalyst world's WIT (`wit/catalyst`), builds it `--locked` to `Cargo.lock`
with `cargo component build --release --target wasm32-wasip2`, and remaps
the scratch directory and the Cargo home out of the paths rustc embeds, so
the bytes carry nothing of where they were built. The toolchain:

```
rustc 1.93.0 (254b59607 2026-01-19)
cargo-component 0.21.1
targets wasm32-wasip1 wasm32-wasip2
```

It reads crates.io for the crates `Cargo.lock` names.

## Digests

```
src/lib.rs        sha256:622c46c9fd609bf92f633bfe6f02d1b783a6808a8d2f5b63962717c9e2da06ea
Cargo.lock        sha256:695ceaa15daafe0e307ee5bb4497e044c8bcae806665f8923f015b8b86c6a1b2
chat_fixture.wasm sha256:e1dcc9000352beae42ab6600f32628760eb95e5fa472ed8352b6b3553e9a471c
```
