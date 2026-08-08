# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WasiTraceTest do
  use ExUnit.Case, async: false

  alias Opus.ExecutionRecord
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @test_ref "reagent:local.test-math:0.1.0"

  setup do
    test_path = Path.join(System.tmp_dir!(), "opus_wasi_trace_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    # Every execution roots under a profile's consent: bootstrap mints one
    # through the production DB source, and the loader reads it back.
    Application.put_env(:cyfr, :consent_source, Sanctum.Consent.Source.DB)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()

    wasm_bytes = File.read!(@math_wasm_path)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, wasm_bytes, %{
        name: "test-math",
        version: "0.1.0",
        type: "reagent",
        description: "Test math component"
      })

    {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

    on_exit(fn ->
      File.rm_rf!(test_path)
      Application.put_env(:cyfr, :consent_source, Sanctum.Consent.Source.Memory)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path, ref: @test_ref}
  end

  describe "WASI trace field" do
    test "ExecutionRecord has wasi_trace field" do
      ctx = Sanctum.TestContext.local()
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})

      # Field should exist and be nil initially
      assert record.wasi_trace == nil
    end

    test "wasi_trace can be set on completion" do
      ctx = Sanctum.TestContext.local()
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})

      # Simulate a trace
      trace = [
        %{call: "fd_write", args: [1, "hello"], result: 5, timestamp: DateTime.utc_now()},
        %{call: "random_get", args: [8], result: :ok, timestamp: DateTime.utc_now()}
      ]

      completed = ExecutionRecord.complete(record, %{"result" => 42}, wasi_trace: trace)

      assert completed.wasi_trace == trace
    end

    test "wasi_trace can be set on failure" do
      ctx = Sanctum.TestContext.local()
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{"a" => 1})

      trace = [
        %{call: "fd_read", args: [0], result: {:error, :eof}, timestamp: DateTime.utc_now()}
      ]

      failed = ExecutionRecord.fail(record, "Read error", wasi_trace: trace)

      assert failed.wasi_trace == trace
    end

    test "reagent executions have empty trace (no WASI)" do
      # Reagents have no WASI capabilities, so they produce no trace
      ctx = Sanctum.TestContext.local()
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{}, component_type: :reagent)

      # No WASI = no trace expected
      completed = ExecutionRecord.complete(record, %{"result" => 1})
      assert completed.wasi_trace == nil
    end

    test "formula executions have empty trace (no WASI)" do
      # Formulas compose other components, no direct WASI access
      ctx = Sanctum.TestContext.local()
      record = ExecutionRecord.new(ctx, "reagent:local.test:0.1.0", %{}, component_type: :formula)

      completed = ExecutionRecord.complete(record, %{"result" => 1})
      assert completed.wasi_trace == nil
    end

    test "wasi_trace is nil for failed execution", %{ctx: ctx, ref: ref} do
      # Execute - math.wasm is a core module, execution fails (no Component Model fallback)
      {:error, error_msg} =
        Opus.MCP.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"a" => 3, "b" => 4}
        })

      assert error_msg =~ "Component Model"

      # Find the failed record via list
      {:ok, list_result} = Opus.MCP.handle("execution", ctx, %{"action" => "list"})
      assert list_result.executions != []
      exec = hd(list_result.executions)

      # Load the execution record
      {:ok, record} = ExecutionRecord.get(ctx, exec.execution_id)

      # wasi_trace should be nil
      assert record.wasi_trace == nil
    end
  end

  describe "WASI trace capability detection" do
    test "ComponentType.wasi_options returns options without HTTP for reagent" do
      opts = Opus.ComponentType.wasi_options(:reagent)
      assert %Wasmex.Wasi.WasiP2Options{} = opts
      assert opts.allow_http == false
    end

    test "ComponentType.wasi_options returns options without HTTP for formula" do
      opts = Opus.ComponentType.wasi_options(:formula)
      assert %Wasmex.Wasi.WasiP2Options{} = opts
      assert opts.allow_http == false
    end

    test "ComponentType.wasi_options returns WASI options for catalyst (HTTP via host function)" do
      opts = Opus.ComponentType.wasi_options(:catalyst)
      assert opts != nil
      assert %Wasmex.Wasi.WasiP2Options{} = opts
      # Catalysts use cyfr:http/fetch host function, not native wasi:http
      assert opts.allow_http == false
    end
  end

  describe "WASI trace documentation" do
    @moduledoc """
    ## WASI Trace Capture - Implementation Notes

    The `wasi_trace` field in ExecutionRecord is designed to capture WASI system
    calls made during component execution for forensic replay purposes.

    ### Current Implementation Status

    Wasmex (the underlying WASM runtime) does not provide automatic call tracing.
    However, it does support:

    1. **stdout/stderr capture via Wasmex.Pipe** - Can capture console output
    2. **WASI function overwriting** - Can replace default WASI implementations
       with Elixir functions that log calls before delegating

    ### Future Enhancement Path

    To implement full WASI call tracing:

    1. Create a `Opus.WasiTracer` module that wraps WASI calls
    2. Override WASI functions (fd_write, fd_read, random_get, etc.) in the
       imports with tracing versions
    3. Collect traces in a process dictionary or agent during execution
    4. Return traces with the execution result

    ### Component Types and WASI

    | Type | WASI Access | Trace Expected |
    |------|-------------|----------------|
    | Reagent | None | Never |
    | Formula | None | Never |
    | Catalyst | Full (HTTP, FS) | When available |

    ### References

    - Wasmex WASI: https://hexdocs.pm/wasmex/Wasmex.html
    - Wasmex.Pipe: https://hexdocs.pm/wasmex/Wasmex.Pipe.html
    """

    test "documentation test - always passes" do
      # This test exists to ensure the documentation compiles
      assert true
    end
  end
end
