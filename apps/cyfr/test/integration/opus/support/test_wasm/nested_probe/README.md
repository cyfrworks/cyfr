# nested-probe

A minimal `cyfr:formula` world component (`export run; import invoke`) used
by `Opus.Test.NestedExecution` to build **real** nested WASM executions in
tests. Unlike `../math.wasm` (a WASI-P1 core module that cannot execute as
a component), `nested_probe.wasm` is a genuine Component Model binary.

Input selects the operation:

```jsonc
{"op": "echo"}                                       // no host calls
{"op": "call",  "request": {"tool": "…", "action": "…", "args": {}}}
{"op": "spawn_await",     "request": {…}}            // spawn + await
{"op": "spawn_await_all", "requests": [{…}, …]}      // spawn N + await-all
{"op": "emit",  "payload": {…}}
{"op": "chain", "depth": 2, "leaf": {…request…}}     // self-invoke N deep
```

Raw host responses are returned verbatim in `result_raw` / `emit_raw` so
tests characterize exactly what the host did.

## Rebuilding

The binary is checked in; rebuild only when `src/lib.rs` changes. The
build goes through the same Locus pipeline `cyfr build compile` uses
(never cargo directly) — from the repo root:

```sh
mix run - <<'EOF'
source = %{"src/lib.rs" => File.read!("apps/opus/test/support/test_wasm/nested_probe/src/lib.rs")}
{:ok, %{wasm_bytes: bytes, digest: digest}} =
  Locus.Builder.compile(source, :rust, target_type: :formula)
File.write!("apps/opus/test/support/test_wasm/nested_probe/nested_probe.wasm", bytes)
IO.puts(digest)
EOF
```

Requires the Rust component toolchain (`cargo-component`). The Cargo.toml
and WIT come from the standard formula scaffold templates; only
`src/lib.rs` is source here. If the probe's version ever changes, update
`SELF_REF` in `src/lib.rs` and `@probe_ref` in
`apps/opus/test/support/nested_execution_helper.ex` together.
