defmodule Opus.OpenAICatalystTest do
  @moduledoc """
  End-to-end integration tests for the OpenAI catalyst WASM component.

  Tests the catalyst through Opus and MCP layers, organized in tiers:
  - Tier 1: Policy Enforcement (offline, no API key)
  - Tier 2: Secrets & Auth Errors (hits OpenAI with invalid keys, zero cost)
  - Tier 3: Operation Routing (mixed)
  - Tier 4: Streaming (real API)
  - Tier 5: MCP Integration
  - Tier 6: Execution Metadata
  - Tier 7: Rate Limiting (offline)
  - Tier 8: Secret Masking

  ## Running

      # Offline tests only:
      mix test apps/opus/test/opus/openai_catalyst_test.exs

      # Include tests that hit OpenAI with invalid keys (free):
      mix test apps/opus/test/opus/openai_catalyst_test.exs --include external

      # Full integration with real API key:
      OPENAI_API_KEY=sk-... mix test apps/opus/test/opus/openai_catalyst_test.exs --include integration --include external
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Opus.MCP

  @wasm_source Path.expand("../../../../components/catalysts/local/openai/0.1.0/catalyst.wasm", __DIR__)

  # Component ref is derived from canonical directory layout:
  #   .../catalysts/local/openai/0.1.0/catalyst.wasm => "local.openai:0.1.0"
  @component_ref "local.openai:0.1.0"

  setup do
    unless File.exists?(@wasm_source) do
      raise "catalyst.wasm not found at #{@wasm_source} — build with: cd components/catalysts/local/openai/0.1.0 && cargo component build --release"
    end

    test_path = Path.join(System.tmp_dir!(), "openai_catalyst_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Copy WASM to canonical layout in temp dir so component ref can be derived
    wasm_dir = Path.join(test_path, "catalysts/local/openai/0.1.0")
    File.mkdir_p!(wasm_dir)
    wasm_path = Path.join(wasm_dir, "catalyst.wasm")
    File.cp!(@wasm_source, wasm_path)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    ctx = Context.local()

    # Clean up any leftover state from previous test runs
    Sanctum.PolicyStore.delete(@component_ref)
    Opus.RateLimiter.reset(ctx.user_id, @component_ref)

    on_exit(fn ->
      Sanctum.PolicyStore.delete(@component_ref)

      try do
        Sanctum.Secrets.delete(ctx, "OPENAI_API_KEY")
      rescue
        _ -> :ok
      end

      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, wasm_path: wasm_path}
  end

  defp ref(wasm_path), do: %{"local" => wasm_path}

  defp setup_policy(opts \\ []) do
    domains = Keyword.get(opts, :allowed_domains, ["api.openai.com"])
    timeout = Keyword.get(opts, :timeout, "30s")
    rate_limit = Keyword.get(opts, :rate_limit, nil)

    policy = %{allowed_domains: domains, timeout: timeout}
    policy = if rate_limit, do: Map.put(policy, :rate_limit, rate_limit), else: policy

    :ok = Sanctum.PolicyStore.put(@component_ref, policy)
  end

  defp setup_secret(ctx, key \\ "test-invalid-key-for-testing") do
    :ok = Sanctum.Secrets.set(ctx, "OPENAI_API_KEY", key)
    :ok = Sanctum.Secrets.grant(ctx, "OPENAI_API_KEY", @component_ref)
  end

  defp real_api_key, do: System.get_env("OPENAI_API_KEY")

  defp models_list_input(stream \\ false) do
    %{"operation" => "models.list", "params" => %{}, "stream" => stream}
  end

  # ============================================================================
  # Tier 1: Policy Enforcement (offline, no API key needed)
  # ============================================================================

  describe "Tier 1 - policy enforcement" do
    test "rejects catalyst with no policy set", %{ctx: ctx, wasm_path: wp} do
      {:error, msg} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)
      assert msg =~ "allowed_domains"
    end

    test "rejects catalyst with empty allowed_domains", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: [])
      {:error, msg} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)
      assert msg =~ "allowed_domains"
    end

    test "wrong domain passes policy gate but HTTP is blocked", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: ["api.wrong.com"])
      setup_secret(ctx)

      {:ok, result} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)

      assert result.status == :completed
      # Domain check blocks the HTTP request — non-200 status
      assert result.output["status"] != 200
    end

    test "correct domain passes policy gate", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: ["api.openai.com"])
      setup_secret(ctx)

      {:ok, result} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)

      assert result.status == :completed
      # Invalid test key → OpenAI returns 401 (not a policy error)
      assert result.output["status"] == 401
    end
  end

  # ============================================================================
  # Tier 2: Secrets & Auth Errors (hits OpenAI with invalid keys, zero cost)
  # ============================================================================

  describe "Tier 2 - secrets and auth errors" do
    @tag :external
    test "no secret set → 401 from OpenAI", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 401
    end

    @tag :external
    test "secret set but NOT granted → 401 from OpenAI", %{ctx: ctx, wasm_path: wp} do
      setup_policy()
      :ok = Sanctum.Secrets.set(ctx, "OPENAI_API_KEY", "sk-test-not-granted")

      {:ok, result} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 401
    end

    @tag :external
    test "invalid API key granted → 401 from OpenAI", %{ctx: ctx, wasm_path: wp} do
      setup_policy()
      setup_secret(ctx, "sk-invalid-key-for-testing-12345")

      {:ok, result} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 401
      assert result.output["error"] != nil
    end
  end

  # ============================================================================
  # Tier 3: Operation Routing
  # ============================================================================

  describe "Tier 3 - operation routing" do
    test "unknown operation returns error", %{ctx: ctx, wasm_path: wp} do
      setup_policy()
      setup_secret(ctx)

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "nonexistent.op",
        "params" => %{},
        "stream" => false
      }, type: :catalyst)

      assert result.status == :completed
      output = result.output
      assert output["status"] == 500 or output["status"] == 400 or
               (is_map(output["error"]) and output["error"] != nil)
    end

    test "missing operation key returns error", %{ctx: ctx, wasm_path: wp} do
      setup_policy()
      setup_secret(ctx)

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "params" => %{},
        "stream" => false
      }, type: :catalyst)

      assert result.status == :completed
      output = result.output
      assert output["status"] != 200 or output["error"] != nil
    end

    @tag :integration
    test "models.list with valid key returns 200", %{ctx: ctx, wasm_path: wp} do
      key = real_api_key()
      unless key, do: ExUnit.Assertions.flunk("OPENAI_API_KEY not set")

      setup_policy(timeout: "30s")
      setup_secret(ctx, key)

      {:ok, result} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 200
      assert is_map(result.output["data"])
    end

    @tag :integration
    test "chat.completions.create with valid key returns 200", %{ctx: ctx, wasm_path: wp} do
      key = real_api_key()
      unless key, do: ExUnit.Assertions.flunk("OPENAI_API_KEY not set")

      setup_policy(timeout: "30s")
      setup_secret(ctx, key)

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "chat.completions.create",
        "params" => %{
          "model" => "gpt-4o-mini",
          "messages" => [%{"role" => "user", "content" => "Say 'hello' and nothing else."}],
          "max_tokens" => 10
        },
        "stream" => false
      }, type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 200
      assert is_map(result.output["data"])
    end
  end

  # ============================================================================
  # Tier 4: Streaming
  # ============================================================================

  describe "Tier 4 - streaming" do
    @tag :integration
    test "chat.completions.create with stream: true returns chunks", %{ctx: ctx, wasm_path: wp} do
      key = real_api_key()
      unless key, do: ExUnit.Assertions.flunk("OPENAI_API_KEY not set")

      setup_policy(timeout: "60s")
      setup_secret(ctx, key)

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "chat.completions.create",
        "params" => %{
          "model" => "gpt-4o-mini",
          "messages" => [%{"role" => "user", "content" => "Say 'hello' and nothing else."}],
          "max_tokens" => 10
        },
        "stream" => true
      }, type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 200

      data = result.output["data"]
      assert is_map(data)
      chunks = data["chunks"]
      assert is_list(chunks)
      assert length(chunks) > 0
    end
  end

  # ============================================================================
  # Tier 5: MCP Integration
  # ============================================================================

  describe "Tier 5 - MCP integration" do
    test "MCP execution with no policy returns error", %{ctx: ctx, wasm_path: wp} do
      {:error, msg} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => ref(wp),
        "input" => models_list_input(),
        "type" => "catalyst"
      })

      assert msg =~ "allowed_domains"
    end

    test "MCP execution with wrong domain returns completed with error output", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: ["api.wrong.com"])
      setup_secret(ctx)

      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => ref(wp),
        "input" => models_list_input(),
        "type" => "catalyst"
      })

      assert result.status == "completed"
      assert result.result["status"] != 200
    end

    @tag :integration
    test "MCP execution with valid config returns completed + 200", %{ctx: ctx, wasm_path: wp} do
      key = real_api_key()
      unless key, do: ExUnit.Assertions.flunk("OPENAI_API_KEY not set")

      setup_policy(timeout: "30s")
      setup_secret(ctx, key)

      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => ref(wp),
        "input" => models_list_input(),
        "type" => "catalyst"
      })

      assert result.status == "completed"
      assert result.result["status"] == 200
      assert is_binary(result.execution_id)
      assert String.starts_with?(result.execution_id, "exec_")
    end

    @tag :integration
    test "execution record readable via MCP.read after catalyst run", %{ctx: ctx, wasm_path: wp} do
      key = real_api_key()
      unless key, do: ExUnit.Assertions.flunk("OPENAI_API_KEY not set")

      setup_policy(timeout: "30s")
      setup_secret(ctx, key)

      {:ok, run_result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => ref(wp),
        "input" => models_list_input(),
        "type" => "catalyst"
      })

      exec_id = run_result.execution_id

      {:ok, json} = MCP.read(ctx, "opus://executions/#{exec_id}")
      {:ok, data} = Jason.decode(json)

      assert data["execution_id"] == exec_id
      assert data["status"] == "completed"
      assert data["component_type"] == "catalyst"
      assert data["output"]["status"] == 200
    end
  end

  # ============================================================================
  # Tier 6: Execution Metadata
  # ============================================================================

  describe "Tier 6 - execution metadata" do
    @tag :external
    test "catalyst stores correct type, digest, and policy snapshot", %{ctx: ctx, wasm_path: wp} do
      setup_policy()
      setup_secret(ctx)

      {:ok, result} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)

      assert result.status == :completed
      assert result.metadata.component_type == :catalyst
      assert String.starts_with?(result.metadata.component_digest, "sha256:")

      policy_applied = result.metadata.policy_applied
      assert is_map(policy_applied)
      assert policy_applied.allowed_domains == ["api.openai.com"]
    end

    @tag :external
    test "execution record persisted to SQLite", %{ctx: ctx, wasm_path: wp} do
      setup_policy()
      setup_secret(ctx)

      {:ok, result} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)

      exec_id = result.metadata.execution_id
      db_record = Arca.Execution.get(exec_id)
      assert db_record != nil
      assert db_record.id == exec_id
      assert db_record.status == "completed"
      assert db_record.completed_at != nil
    end
  end

  # ============================================================================
  # Tier 7: Rate Limiting (offline)
  # ============================================================================

  describe "Tier 7 - rate limiting" do
    test "rate limiter blocks after limit exceeded", %{ctx: ctx, wasm_path: wp} do
      setup_policy(
        allowed_domains: ["api.openai.com"],
        rate_limit: %{requests: 1, window: "1m"}
      )
      setup_secret(ctx)

      {:ok, result1} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)
      assert result1.status == :completed

      {:error, msg} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)
      assert msg =~ "Rate limit"
    end
  end

  # ============================================================================
  # Tier 8: Secret Masking
  # ============================================================================

  describe "Tier 8 - secret masking" do
    @tag :integration
    test "API key not present in execution output JSON", %{ctx: ctx, wasm_path: wp} do
      key = real_api_key()
      unless key, do: ExUnit.Assertions.flunk("OPENAI_API_KEY not set")

      setup_policy(timeout: "30s")
      setup_secret(ctx, key)

      {:ok, result} = Opus.run(ctx, ref(wp), models_list_input(), type: :catalyst)

      assert result.status == :completed

      {:ok, output_json} = Jason.encode(result.output)
      refute String.contains?(output_json, key)

      exec_id = result.metadata.execution_id
      {:ok, record} = Opus.get(ctx, exec_id)

      if record.output do
        {:ok, record_json} = Jason.encode(record.output)
        refute String.contains?(record_json, key)
      end
    end
  end
end
