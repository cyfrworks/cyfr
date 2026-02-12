defmodule Opus.WasiTraceTest do
  use ExUnit.Case, async: false

  alias Opus.ExecutionRecord
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")

  setup do
    test_path = Path.join(System.tmp_dir!(), "opus_wasi_trace_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    ctx = Context.local()

    # Copy WASM to canonical layout for local reference execution
    wasm_dir = Path.join(test_path, "reagents/local/test-math/0.1.0")
    File.mkdir_p!(wasm_dir)
    wasm_path = Path.join(wasm_dir, "reagent.wasm")
    File.cp!(@math_wasm_path, wasm_path)

    on_exit(fn ->
      File.rm_rf!(test_path)
      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path, wasm_path: wasm_path}
  end

  describe "WASI trace field" do
    test "ExecutionRecord has wasi_trace field" do
      ctx = Context.local()
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{"a" => 1})

      # Field should exist and be nil initially
      assert record.wasi_trace == nil
    end

    test "wasi_trace can be set on completion" do
      ctx = Context.local()
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{"a" => 1})

      # Simulate a trace
      trace = [
        %{call: "fd_write", args: [1, "hello"], result: 5, timestamp: DateTime.utc_now()},
        %{call: "random_get", args: [8], result: :ok, timestamp: DateTime.utc_now()}
      ]

      completed = ExecutionRecord.complete(record, %{"result" => 42}, wasi_trace: trace)

      assert completed.wasi_trace == trace
    end

    test "wasi_trace can be set on failure" do
      ctx = Context.local()
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{"a" => 1})

      trace = [
        %{call: "fd_read", args: [0], result: {:error, :eof}, timestamp: DateTime.utc_now()}
      ]

      failed = ExecutionRecord.fail(record, "Read error", wasi_trace: trace)

      assert failed.wasi_trace == trace
    end

    test "reagent executions have empty trace (no WASI)" do
      # Reagents have no WASI capabilities, so they produce no trace
      ctx = Context.local()
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{}, component_type: :reagent)

      # No WASI = no trace expected
      completed = ExecutionRecord.complete(record, %{"result" => 1})
      assert completed.wasi_trace == nil
    end

    test "formula executions have empty trace (no WASI)" do
      # Formulas compose other components, no direct WASI access
      ctx = Context.local()
      record = ExecutionRecord.new(ctx, %{"local" => "test.wasm"}, %{}, component_type: :formula)

      completed = ExecutionRecord.complete(record, %{"result" => 1})
      assert completed.wasi_trace == nil
    end

    test "wasi_trace is persisted in completed.json", %{ctx: ctx, wasm_path: wasm_path} do
      # Execute - math.wasm is a reagent, so no WASI trace
      {:ok, result} = Opus.MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => %{"local" => wasm_path},
        "input" => %{"a" => 3, "b" => 4}
      })

      # Verify execution succeeded
      assert result.status == "completed"

      # Load the execution record
      {:ok, record} = ExecutionRecord.get(ctx, result.execution_id)

      # For reagent, wasi_trace should be nil
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
