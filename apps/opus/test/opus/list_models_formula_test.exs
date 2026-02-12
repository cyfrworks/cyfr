defmodule Opus.ListModelsFormulaTest do
  @moduledoc """
  Integration tests for the list-models Formula WASM component.

  Tests the formula through Opus layers, organized in tiers:
  - Tier 1: WASM Validation (offline, no API key)
  - Tier 2: Formula Execution - Offline (invoke host function, error paths)
  - Tier 3: Formula Execution - Live (requires OpenAI catalyst + API key)
  - Tier 4: MCP Integration
  - Tier 5: Execution Metadata & Lineage

  ## Running

      # Offline tests only:
      mix test apps/opus/test/opus/list_models_formula_test.exs

      # Full integration with real API key + published catalyst:
      OPENAI_API_KEY=sk-... mix test apps/opus/test/opus/list_models_formula_test.exs --include integration --include external
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Opus.MCP

  @formula_wasm_source Path.expand(
    "../../../../components/formulas/local/list-models/0.1.0/formula.wasm",
    __DIR__
  )

  @catalyst_wasm_source Path.expand(
    "../../../../components/catalysts/local/openai/0.1.0/catalyst.wasm",
    __DIR__
  )

  setup do
    unless File.exists?(@formula_wasm_source) do
      raise "formula.wasm not found at #{@formula_wasm_source} — build with: cd components/formulas/local/list-models/0.1.0/src && cargo component build --release --target wasm32-wasip2 && cp target/wasm32-wasip2/release/list_models.wasm ../formula.wasm"
    end

    test_path = Path.join(System.tmp_dir!(), "list_models_formula_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Copy formula WASM to canonical layout in temp dir
    formula_dir = Path.join(test_path, "formulas/local/list-models/0.1.0")
    File.mkdir_p!(formula_dir)
    formula_wasm_path = Path.join(formula_dir, "formula.wasm")
    File.cp!(@formula_wasm_source, formula_wasm_path)

    # Copy catalyst WASM to canonical layout if available (for live tests)
    catalyst_dir = Path.join(test_path, "catalysts/local/openai/0.1.0")
    File.mkdir_p!(catalyst_dir)
    has_catalyst = File.exists?(@catalyst_wasm_source)
    catalyst_wasm_path = Path.join(catalyst_dir, "catalyst.wasm")
    if has_catalyst, do: File.cp!(@catalyst_wasm_source, catalyst_wasm_path)

    # Use shared sandbox mode so spawned processes (Wasmex GenServer, Executor spawn)
    # can access the DB connection.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Ensure WAL mode + busy_timeout for SQLite concurrent access
    try do
      Arca.Repo.query!("PRAGMA journal_mode=WAL")
      Arca.Repo.query!("PRAGMA busy_timeout=10000")
    rescue
      _ -> :ok
    end

    ctx = Context.local()

    # Clean up DB state before on_exit (while the connection is still alive).
    # on_exit runs in a separate process after the test process exits, which
    # invalidates the shared DB connection. So we register a non-DB cleanup only.
    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok,
     ctx: ctx,
     test_path: test_path,
     formula_wasm_path: formula_wasm_path,
     formula_bytes: File.read!(formula_wasm_path),
     catalyst_wasm_path: catalyst_wasm_path,
     has_catalyst: has_catalyst}
  end

  defp ref(wasm_path), do: %{"local" => wasm_path}

  @catalyst_ref "local.openai:0.1.0"

  defp setup_catalyst_policy(opts \\ []) do
    domains = Keyword.get(opts, :allowed_domains, ["api.openai.com"])
    timeout = Keyword.get(opts, :timeout, "30s")
    :ok = Sanctum.PolicyStore.put(@catalyst_ref, %{allowed_domains: domains, timeout: timeout})
  end

  defp setup_catalyst_secret(ctx, key \\ "test-invalid-key-for-testing") do
    :ok = Sanctum.Secrets.set(ctx, "OPENAI_API_KEY", key)
    :ok = Sanctum.Secrets.grant(ctx, "OPENAI_API_KEY", @catalyst_ref)
  end

  defp real_api_key, do: System.get_env("OPENAI_API_KEY")

  # Build a no-op invoke import that returns a canned error response.
  # This avoids any DB writes from sub-invocations during WASM validation.
  defp noop_invoke_imports do
    %{
      "cyfr:formula/invoke@0.1.0" => %{
        "call" => {:fn, fn _json_request ->
          Jason.encode!(%{
            "error" => %{
              "type" => "test_noop",
              "message" => "Invoke disabled in test"
            }
          })
        end}
      }
    }
  end

  # ============================================================================
  # Tier 1: WASM Validation (offline, no API key needed)
  # ============================================================================

  describe "Tier 1 - WASM validation" do
    test "formula.wasm is a valid WASM component", %{formula_bytes: fb} do
      assert byte_size(fb) > 0

      engine_config = %Wasmex.EngineConfig{consume_fuel: true}
      {:ok, engine} = Wasmex.Engine.new(engine_config)

      result = Wasmex.Components.start_link(%{
        bytes: fb,
        engine: engine,
        imports: noop_invoke_imports()
      })

      case result do
        {:ok, pid} ->
          GenServer.stop(pid, :normal)
          assert true

        {:error, reason} ->
          flunk("Failed to load formula.wasm as Component: #{inspect(reason)}")
      end
    end

    test "formula exports cyfr:formula/run and imports cyfr:formula/invoke", %{formula_bytes: fb} do
      engine_config = %Wasmex.EngineConfig{consume_fuel: true}
      {:ok, engine} = Wasmex.Engine.new(engine_config)

      {:ok, pid} = Wasmex.Components.start_link(%{
        bytes: fb,
        engine: engine,
        imports: noop_invoke_imports()
      })

      # Call the run function with empty JSON
      result = Wasmex.Components.call_function(
        pid,
        ["cyfr:formula/run@0.1.0", "run"],
        ["{}"],
        30_000
      )

      GenServer.stop(pid, :normal)

      # The formula calls invoke which returns our noop error,
      # but the export IS callable and returns valid JSON
      assert {:ok, json_output} = result
      assert is_binary(json_output)
      assert {:ok, parsed} = Jason.decode(json_output)
      assert is_map(parsed)
    end

    test "formula returns error JSON when invoke fails", %{formula_bytes: fb} do
      engine_config = %Wasmex.EngineConfig{consume_fuel: true}
      {:ok, engine} = Wasmex.Engine.new(engine_config)

      {:ok, pid} = Wasmex.Components.start_link(%{
        bytes: fb,
        engine: engine,
        imports: noop_invoke_imports()
      })

      {:ok, json_output} = Wasmex.Components.call_function(
        pid,
        ["cyfr:formula/run@0.1.0", "run"],
        ["{}"],
        30_000
      )

      GenServer.stop(pid, :normal)

      {:ok, parsed} = Jason.decode(json_output)

      # The formula collects per-provider errors into "errors" (plural)
      # and always returns {"models": {...}, "errors": {...}}
      assert Map.has_key?(parsed, "errors"), "expected errors key, got: #{inspect(Map.keys(parsed))}"
      assert Map.has_key?(parsed, "models")
    end

    test "formula handles JSON input gracefully", %{formula_bytes: fb} do
      engine_config = %Wasmex.EngineConfig{consume_fuel: true}
      {:ok, engine} = Wasmex.Engine.new(engine_config)

      {:ok, pid} = Wasmex.Components.start_link(%{
        bytes: fb,
        engine: engine,
        imports: noop_invoke_imports()
      })

      # Pass some structured input
      input = Jason.encode!(%{"filter" => "gpt"})
      {:ok, json_output} = Wasmex.Components.call_function(
        pid,
        ["cyfr:formula/run@0.1.0", "run"],
        [input],
        30_000
      )

      GenServer.stop(pid, :normal)

      assert {:ok, _parsed} = Jason.decode(json_output)
    end
  end

  # ============================================================================
  # Tier 2: Formula Execution - Offline Error Paths
  # Uses Runtime.execute_component directly to test the formula execution
  # with the real FormulaHandler invoke host function.
  # ============================================================================

  describe "Tier 2 - formula execution offline" do
    test "formula runs as component_type :formula via Runtime", %{formula_bytes: fb, ctx: ctx} do
      {:ok, output, _metadata} = Opus.Runtime.execute_component(fb, %{},
        component_type: :formula,
        ctx: ctx,
        execution_id: "exec_test-runtime-formula"
      )

      # The formula calls invoke → FormulaHandler → Executor.run with openai:0.1.0
      # registry ref. Without the catalyst published, invoke returns an error.
      assert is_map(output)
      assert Map.has_key?(output, "error") or Map.has_key?(output, "models")
    end

    test "formula via Opus.run returns completed status", %{formula_wasm_path: fwp, ctx: ctx} do
      {:ok, result} = Opus.run(ctx, ref(fwp), %{}, type: :formula)

      assert result.status == :completed
      assert is_map(result.output)
    end

    test "formula stores execution record", %{formula_wasm_path: fwp, ctx: ctx} do
      {:ok, result} = Opus.run(ctx, ref(fwp), %{}, type: :formula)

      exec_id = result.metadata.execution_id
      assert String.starts_with?(exec_id, "exec_")

      # Allow a small delay for the DB write from the spawned process
      Process.sleep(100)
      db_record = Arca.Execution.get(exec_id)
      assert db_record != nil
      assert db_record.status == "completed"
    end

    test "formula metadata records correct component_type", %{formula_wasm_path: fwp, ctx: ctx} do
      {:ok, result} = Opus.run(ctx, ref(fwp), %{}, type: :formula)

      assert result.metadata.component_type == :formula
      assert String.starts_with?(result.metadata.component_digest, "sha256:")
    end

    test "formula via local file reference", %{formula_wasm_path: fwp, ctx: ctx} do
      {:ok, result} = Opus.run(ctx, ref(fwp), %{}, type: :formula)

      assert result.status == :completed
      assert is_map(result.output)
    end
  end

  # ============================================================================
  # Tier 3: Formula Execution - Live (requires catalyst + API key)
  # ============================================================================

  describe "Tier 3 - formula live execution" do
    @tag :integration
    test "formula invokes catalyst and returns models list", %{
      formula_bytes: fb,
      catalyst_wasm_path: cwp,
      ctx: ctx,
      has_catalyst: has_catalyst
    } do
      key = real_api_key()
      unless key, do: flunk("OPENAI_API_KEY not set")
      unless has_catalyst, do: flunk("catalyst.wasm not found")

      # Setup catalyst policy and secrets
      setup_catalyst_policy(timeout: "30s")
      setup_catalyst_secret(ctx, key)

      # Use the local catalyst file path
      catalyst_local_ref = %{"local" => cwp}

      # Set up policy for the local ref (uses canonical ref from path)
      Sanctum.PolicyStore.put(@catalyst_ref, %{
        allowed_domains: ["api.openai.com"],
        timeout: "30s"
      })
      :ok = Sanctum.Secrets.grant(ctx, "OPENAI_API_KEY", @catalyst_ref)

      parent_exec_id = "exec_formula-live-#{:rand.uniform(100_000)}"

      # Build custom invoke that redirects registry ref to our local catalyst
      custom_imports = %{
        "cyfr:formula/invoke@0.1.0" => %{
          "call" => {:fn, fn json_request ->
            case Jason.decode(json_request) do
              {:ok, req} ->
                modified_req = Map.put(req, "reference", catalyst_local_ref)
                Opus.FormulaHandler.execute(Jason.encode!(modified_req), ctx, parent_exec_id)

              {:error, _} ->
                Opus.FormulaHandler.encode_error(:invalid_json, "Invalid JSON")
            end
          end}
        }
      }

      engine_config = %Wasmex.EngineConfig{consume_fuel: true}
      {:ok, engine} = Wasmex.Engine.new(engine_config)

      {:ok, pid} = Wasmex.Components.start_link(%{
        bytes: fb,
        engine: engine,
        imports: custom_imports
      })

      {:ok, json_output} = Wasmex.Components.call_function(
        pid,
        ["cyfr:formula/run@0.1.0", "run"],
        ["{}"],
        60_000
      )

      GenServer.stop(pid, :normal)

      {:ok, output} = Jason.decode(json_output)

      assert Map.has_key?(output, "models"), "expected 'models' key, got: #{inspect(Map.keys(output))}"

      models = output["models"]
      assert is_map(models), "expected models to be a map"

      if Map.has_key?(models, "data") do
        assert is_list(models["data"]), "expected models.data to be a list"
        assert length(models["data"]) > 0, "expected at least one model"
      end
    end
  end

  # ============================================================================
  # Tier 4: MCP Integration
  # ============================================================================

  describe "Tier 4 - MCP integration" do
    test "MCP execution run with formula type returns completed", %{formula_wasm_path: fwp, ctx: ctx} do
      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => ref(fwp),
        "input" => %{},
        "type" => "formula"
      })

      assert result.status == "completed"
      assert is_binary(result.execution_id)
      assert String.starts_with?(result.execution_id, "exec_")
    end

    test "MCP execution logs readable after formula run", %{formula_wasm_path: fwp, ctx: ctx} do
      {:ok, run_result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => ref(fwp),
        "input" => %{},
        "type" => "formula"
      })

      exec_id = run_result.execution_id

      {:ok, json} = MCP.read(ctx, "opus://executions/#{exec_id}")
      {:ok, data} = Jason.decode(json)

      assert data["execution_id"] == exec_id
      assert data["status"] == "completed"
      assert data["component_type"] == "formula"
    end
  end

  # ============================================================================
  # Tier 5: Execution Metadata & Lineage
  # ============================================================================

  describe "Tier 5 - execution metadata" do
    test "formula execution has correct component_type in metadata", %{formula_wasm_path: fwp, ctx: ctx} do
      {:ok, result} = Opus.run(ctx, ref(fwp), %{}, type: :formula)

      assert result.metadata.component_type == :formula
      assert is_binary(result.metadata.component_digest)
      assert String.starts_with?(result.metadata.component_digest, "sha256:")
      assert is_integer(result.metadata.duration_ms)
      assert result.metadata.duration_ms >= 0
    end

    test "formula execution record persisted to SQLite with type", %{formula_wasm_path: fwp, ctx: ctx} do
      {:ok, result} = Opus.run(ctx, ref(fwp), %{}, type: :formula)

      exec_id = result.metadata.execution_id
      Process.sleep(100)
      db_record = Arca.Execution.get(exec_id)

      assert db_record != nil
      assert db_record.id == exec_id
      assert db_record.status == "completed"
      assert db_record.component_type == "formula"
    end
  end
end
