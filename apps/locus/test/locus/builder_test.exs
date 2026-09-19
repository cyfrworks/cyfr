# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderTest do
  @moduledoc """
  The builder answers a request with output files or with the build wire's
  own refusal, and nothing in between: what a request lacks is `malformed`
  before anything runs, a toolchain this machine lacks is `unavailable`, a
  build that exits non-zero is `failed` with its status, and output past a
  bound is refused as `failed`, never cut to fit. The executor here is the
  test environment's direct launcher.
  """

  # Replaces PATH for the duration of one test.
  use ExUnit.Case, async: false

  alias Cyfr.BuilderProtocol
  alias Locus.Builder

  defp rust(sources, fields \\ %{}) do
    Map.merge(%{language: :rust, target_type: :reagent, resolve: false, sources: sources}, fields)
  end

  defp tincture(sources), do: rust(sources, %{language: :javascript, target_type: :tincture})

  defp scripted(script) do
    tincture(%{
      "package.json" =>
        Jason.encode!(%{name: "builder-probe", private: true, scripts: %{build: script}})
    })
  end

  # Every stage and log line a build reported, oldest first.
  defp collecting do
    {:ok, lines} = Agent.start_link(fn -> [] end)

    {fn stage, message -> Agent.update(lines, &[{stage, message} | &1]) end,
     fn -> Agent.get(lines, &Enum.reverse/1) end}
  end

  describe "toolchains" do
    test "each of the wire's languages reports whether its toolchain is here" do
      toolchains = Builder.available_toolchains()

      assert Map.keys(toolchains) |> Enum.sort() == Enum.sort(BuilderProtocol.languages())
      assert toolchains.rust.command == "cargo-component"
      assert toolchains.javascript.command == "npm"
      assert is_boolean(toolchains.rust.available)
      assert is_boolean(toolchains.javascript.available)

      # What a health answer carries is what the wire reads.
      assert {:ok, line} =
               BuilderProtocol.encode_health(%{release: "0.0.0", toolchains: toolchains})

      assert {:ok, {:health, %{toolchains: ^toolchains}}} = BuilderProtocol.read_line(line)
    end

    test "a language the builder does not speak has no toolchain" do
      refute Builder.toolchain_available?(:python)
      refute Builder.toolchain_available?(:go)
    end
  end

  describe "a request that makes no build is malformed, and nothing runs" do
    test "no sources" do
      assert {:error, {:malformed, "sources name no files"}} = Builder.prepare(rust(%{}))
      assert {:error, {:malformed, _}} = Builder.prepare(tincture(%{}))
    end

    test "a rust build without src/lib.rs, a javascript build without package.json" do
      assert {:error, {:malformed, sentence}} =
               Builder.prepare(rust(%{"src/utils.rs" => "pub fn hello() {}"}))

      assert sentence =~ "src/lib.rs"

      assert {:error, {:malformed, sentence}} =
               Builder.prepare(tincture(%{"src/main.jsx" => "export default function() {}"}))

      assert sentence =~ "package.json"
    end

    test "sources past the wire's bound" do
      big = String.duplicate("x", 600_000)
      max = BuilderProtocol.max_source_bytes()

      assert {:error, {:malformed, sentence}} =
               Builder.prepare(rust(%{"src/lib.rs" => big, "src/utils.rs" => big}))

      assert sentence == "sources total 1200000 bytes; at most #{max} are read"
    end

    test "a source path that leaves the build's directory" do
      sources = %{"src/lib.rs" => "pub fn hello() {}", "../../../../tmp/escape.rs" => "pwned"}

      assert {:error, {:malformed, sentence}} = Builder.prepare(rust(sources))
      assert sentence == "../../../../tmp/escape.rs is not a safe relative path"
    end

    test "a type built from the other language" do
      assert {:error, {:malformed, "a reagent is not built from javascript"}} =
               Builder.prepare(%{
                 language: :javascript,
                 target_type: :reagent,
                 resolve: false,
                 sources: %{"package.json" => "{}"}
               })

      assert {:error, {:malformed, "a tincture is not built from rust"}} =
               Builder.prepare(rust(%{"src/lib.rs" => ""}, %{target_type: :tincture}))
    end
  end

  describe "a toolchain this machine lacks" do
    setup do
      path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")
      on_exit(fn -> System.put_env("PATH", path) end)
    end

    test "is unavailable, in the sentence the wire's vectors carry, and nothing runs" do
      assert {:error, {:unavailable, "the rust toolchain is not installed in this image"}} =
               Builder.prepare(rust(%{"src/lib.rs" => "pub fn hello() {}"}))

      assert {:error, {:unavailable, "the javascript toolchain is not installed in this image"}} =
               Builder.build(scripted("true"))
    end
  end

  describe "a configured Cargo seed that is missing" do
    setup do
      Application.put_env(:locus, :cargo_seed, "/nonexistent/cargo-seed")
      on_exit(fn -> Application.delete_env(:locus, :cargo_seed) end)
    end

    @tag :requires_cargo_component
    test "is a broken image: unavailable" do
      assert {:error, {:unavailable, sentence}} =
               Builder.prepare(rust(%{"src/lib.rs" => "pub fn hello() {}"}))

      assert sentence =~ "/nonexistent/cargo-seed/registry"
    end
  end

  describe "a tincture" do
    @describetag :requires_node

    test "builds to the files of its dist, reporting its stages and its log" do
      {on_progress, progress} = collecting()

      script =
        "mkdir -p dist/assets && echo built >&2 && echo hi > dist/index.html && echo js > dist/assets/app.js"

      assert {:ok, built} = Builder.build(scripted(script), on_progress: on_progress)

      assert built == %{
               language: :javascript,
               target_type: :tincture,
               outputs: %{"index.html" => "hi\n", "assets/app.js" => "js\n"}
             }

      stages = Enum.map(progress.(), &elem(&1, 0))
      assert Enum.dedup(stages) == [:preparing, :compiling, :output]
      assert Enum.all?(stages, &(&1 in BuilderProtocol.stages()))
      assert {:output, "built"} in progress.()

      # What the builder answers is a result the wire carries.
      assert {:ok, line} = BuilderProtocol.encode_result(Map.put(built, :diagnostics, []))
      assert {:ok, {:result, %{outputs: outputs}}} = BuilderProtocol.read_line(line)
      assert outputs == built.outputs
    end

    test "that exits non-zero is failed with its status, its log delivered" do
      {on_progress, progress} = collecting()

      assert {:error, {:failed, {:status, status}}} =
               Builder.build(scripted("echo broken >&2; exit 7"), on_progress: on_progress)

      assert is_integer(status) and status != 0
      assert {:output, "broken"} in progress.()
    end

    test "that leaves no dist is failed, and says why" do
      {on_progress, progress} = collecting()

      assert {:error, {:failed, {:status, 0}}} =
               Builder.build(scripted("true"), on_progress: on_progress)

      assert {:compiling, "the build produced no output files in dist/"} in progress.()
    end

    test "whose files pass the wire's count is refused, never cut to fit" do
      {on_progress, progress} = collecting()
      max = BuilderProtocol.max_output_files()

      script =
        "mkdir dist && i=0 && while [ $i -le #{max} ]; do : > dist/f$i; i=$((i+1)); done"

      assert {:error, {:failed, {:status, 0}}} =
               Builder.build(scripted(script), on_progress: on_progress)

      assert {:compiling, "the build produced more than #{max} files"} in progress.()
    end

    @tag timeout: 120_000
    test "whose bytes pass the wire's bound is refused, never cut to fit" do
      {on_progress, progress} = collecting()
      max = BuilderProtocol.max_output_bytes()

      script = "mkdir dist && head -c #{max + 1} /dev/zero > dist/big"

      assert {:error, {:failed, {:status, 0}}} =
               Builder.build(scripted(script), on_progress: on_progress)

      assert {:validating,
              "the build's outputs total #{max + 1} bytes; at most #{max} are answered"} in progress.()
    end

    @tag timeout: 120_000
    test "whose archive passes what the executor collects is ended there" do
      {on_progress, progress} = collecting()
      past = BuilderProtocol.max_output_bytes() + 8 * 1024 * 1024

      script = "mkdir dist && head -c #{past} /dev/zero > dist/big"

      assert {:error, {:failed, _exit}} =
               Builder.build(scripted(script), on_progress: on_progress)

      assert Enum.any?(progress.(), fn {_stage, message} -> message =~ "was refused" end)
    end

    test "past its budget is a timeout naming the budget" do
      assert {:error, {:timeout, 1_500}} = Builder.build(scripted("sleep 60"), timeout_ms: 1_500)
    end
  end

  describe "a rust component" do
    @describetag :requires_cargo_component
    @describetag timeout: 900_000

    @lib_rs """
    #[allow(warnings)]
    mod bindings;

    use bindings::exports::cyfr::reagent::compute::Guest;

    struct MyReagent;
    bindings::export!(MyReagent with_types_in bindings);

    impl Guest for MyReagent {
        fn compute(input: String) -> String {
            input
        }
    }
    """

    test "builds to a validated component and the lock it resolved, and builds locked to it" do
      {on_progress, progress} = collecting()

      assert {:ok, %{language: :rust, target_type: :reagent, outputs: outputs}} =
               Builder.build(rust(%{"src/lib.rs" => @lib_rs}), on_progress: on_progress)

      wasm = BuilderProtocol.component_wasm()
      lock = BuilderProtocol.component_lockfile()
      assert Map.keys(outputs) |> Enum.sort() == Enum.sort([wasm, lock])
      assert {:ok, _} = Compendium.WasmValidator.validate(outputs[wasm])
      assert outputs[lock] =~ ~s(name = "wit-bindgen-rt")

      assert Enum.dedup(Enum.map(progress.(), &elem(&1, 0))) --
               [:preparing, :compiling, :output, :validating] == []

      assert {:validating, "Validating WASM binary..."} in progress.()

      # A dependency the lock does not cover fails with cargo's own message;
      # `resolve` resolves afresh.
      cargo_toml =
        :reagent
        |> Builder.cargo_toml_for()
        |> String.replace("[dependencies]\n", "[dependencies]\nsmallvec = \"1\"\n")

      sources = %{
        "src/lib.rs" => @lib_rs,
        "Cargo.toml" => cargo_toml,
        "Cargo.lock" => outputs[lock]
      }

      {on_progress, progress} = collecting()

      assert {:error, {:failed, {:status, status}}} =
               Builder.build(rust(sources), on_progress: on_progress)

      assert status != 0
      assert Enum.any?(progress.(), fn {_stage, message} -> message =~ "--locked" end)

      assert {:ok, %{outputs: resolved}} = Builder.build(rust(sources, %{resolve: true}))
      assert resolved[lock] =~ ~s(name = "smallvec")
    end

    test "that does not compile is failed with cargo's status and its log" do
      {on_progress, progress} = collecting()

      assert {:error, {:failed, {:status, status}}} =
               Builder.build(rust(%{"src/lib.rs" => "this is not valid rust code at all!!"}),
                 on_progress: on_progress
               )

      assert status != 0
      assert Enum.any?(progress.(), fn {stage, _message} -> stage == :output end)
    end
  end
end
