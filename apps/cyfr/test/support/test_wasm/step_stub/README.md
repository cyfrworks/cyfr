# step-stub

A `model/chat@1` catalyst (`cyfr:catalyst` world) that answers at once, so
`Cyfr.Test.StepBench` and `mix cyfr.bench.step` time the host's path of a
turn's model step rather than a provider's.

Input selects the operation:

```jsonc
{"operation": "describe", "params": {}}                  // capabilities
{"operation": "describe", "params": {"model": "…"}}      // + a 1,000,000-token window
{"operation": "models",   "params": {}}
{"operation": "chat",     "params": {…}}                 // reads STUB_API_KEY, then
                                                         // emits four text.delta, usage
                                                         // and stop, and answers one
                                                         // text block
```

The bench registers it as `catalyst:local.step-stub:0.1.0` with an
`api_key` need whose field is `STUB_API_KEY`.

## Rebuilding

The binary is checked in; rebuild only when `src/lib.rs` changes. The
build goes through the Locus pipeline with the canonical catalyst
Cargo.toml (which binds every WIT package the catalyst world imports) —
from the repo root:

```sh
MIX_ENV=test mix run --no-start -e '
{:ok, _} = Application.ensure_all_started(:locus)
dir = "apps/cyfr/test/support/test_wasm/step_stub"

source = %{
  "src/lib.rs" => File.read!(Path.join(dir, "src/lib.rs")),
  "Cargo.toml" => Cyfr.CargoToml.template(:catalyst)
}

{:ok, %{wasm_bytes: bytes, digest: digest}} =
  Locus.Builder.compile(source, :rust, target_type: :catalyst)

File.write!(Path.join(dir, "step_stub.wasm"), bytes)
IO.puts(digest)
'
```

Requires the Rust component toolchain (`cargo-component`).
