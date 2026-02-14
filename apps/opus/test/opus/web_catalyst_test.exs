defmodule Opus.WebCatalystTest do
  @moduledoc """
  End-to-end integration tests for the Web catalyst WASM component.

  The web catalyst has no secrets — it is a pure HTTP reader. Tests are
  organized in tiers matching the other catalyst test suites:
  - Tier 1: Policy Enforcement (offline, no network)
  - Tier 2: Domain Blocking (hits allowed domain but wrong one)
  - Tier 3: Operation Routing — happy paths (hits example.com)
  - Tier 4: Operation Routing — unhappy paths (bad input)
  - Tier 5: MCP Integration
  - Tier 6: Execution Metadata
  - Tier 7: Rate Limiting (offline)

  ## Running

      # Offline tests only:
      mix test apps/opus/test/opus/web_catalyst_test.exs

      # Include tests that hit example.com (free, always available):
      mix test apps/opus/test/opus/web_catalyst_test.exs --include external
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Opus.MCP

  @wasm_source Path.expand("../../../../components/catalysts/local/web/0.1.0/catalyst.wasm", __DIR__)

  # Component ref is derived from canonical directory layout:
  #   .../catalysts/local/web/0.1.0/catalyst.wasm => "catalyst:local.web:0.1.0"
  @component_ref "catalyst:local.web:0.1.0"

  setup do
    unless File.exists?(@wasm_source) do
      raise "catalyst.wasm not found at #{@wasm_source} — build with: cd components/catalysts/local/web/0.1.0/src && cargo component build --release --target wasm32-wasip2 && cp target/wasm32-wasip2/release/web_catalyst.wasm ../catalyst.wasm"
    end

    test_path = Path.join(System.tmp_dir!(), "web_catalyst_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # Copy WASM to canonical layout in temp dir so component ref can be derived
    wasm_dir = Path.join(test_path, "catalysts/local/web/0.1.0")
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
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, wasm_path: wasm_path}
  end

  defp ref(wasm_path), do: %{"local" => wasm_path}

  defp setup_policy(opts \\ []) do
    domains = Keyword.get(opts, :allowed_domains, ["example.com"])
    timeout = Keyword.get(opts, :timeout, "30s")
    rate_limit = Keyword.get(opts, :rate_limit, nil)

    policy = %{allowed_domains: domains, timeout: timeout}
    policy = if rate_limit, do: Map.put(policy, :rate_limit, rate_limit), else: policy

    :ok = Sanctum.PolicyStore.put(@component_ref, policy)
  end

  defp fetch_input(url \\ "https://example.com") do
    %{"operation" => "fetch", "params" => %{"url" => url}}
  end

  defp extract_input(url \\ "https://example.com") do
    %{"operation" => "extract", "params" => %{"url" => url}}
  end

  defp links_input(url \\ "https://example.com") do
    %{"operation" => "links", "params" => %{"url" => url}}
  end

  defp metadata_input(url \\ "https://example.com") do
    %{"operation" => "metadata", "params" => %{"url" => url}}
  end

  # ============================================================================
  # Tier 1: Policy Enforcement (offline, no network)
  # ============================================================================

  describe "Tier 1 - policy enforcement" do
    test "rejects catalyst with no policy set", %{ctx: ctx, wasm_path: wp} do
      {:error, msg} = Opus.run(ctx, ref(wp), fetch_input(), type: :catalyst)
      assert msg =~ "allowed_domains"
    end

    test "rejects catalyst with empty allowed_domains", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: [])
      {:error, msg} = Opus.run(ctx, ref(wp), fetch_input(), type: :catalyst)
      assert msg =~ "allowed_domains"
    end

    test "wrong domain passes policy gate but HTTP is blocked", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: ["api.wrong.com"])

      {:ok, result} = Opus.run(ctx, ref(wp), fetch_input(), type: :catalyst)

      assert result.status == :completed
      # Domain check blocks the HTTP request — error in output
      assert result.output["status"] != 200
    end

    test "correct domain passes policy gate", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: ["example.com"])

      {:ok, result} = Opus.run(ctx, ref(wp), fetch_input(), type: :catalyst)

      assert result.status == :completed
      # example.com should return 200
      assert result.output["status"] == 200
    end
  end

  # ============================================================================
  # Tier 2: Domain Blocking
  # ============================================================================

  describe "Tier 2 - domain blocking" do
    test "fetch to blocked domain returns error", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: ["example.com"])

      {:ok, result} = Opus.run(ctx, ref(wp), fetch_input("https://httpbin.org/get"), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] != 200
    end

    test "extract to blocked domain returns error", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: ["example.com"])

      {:ok, result} = Opus.run(ctx, ref(wp), extract_input("https://httpbin.org/html"), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] != 200
    end

    test "links to blocked domain returns error", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: ["example.com"])

      {:ok, result} = Opus.run(ctx, ref(wp), links_input("https://httpbin.org/html"), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] != 200
    end

    test "metadata to blocked domain returns error", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: ["example.com"])

      {:ok, result} = Opus.run(ctx, ref(wp), metadata_input("https://httpbin.org/html"), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] != 200
    end
  end

  # ============================================================================
  # Tier 3: Operation Routing — Happy Paths
  # ============================================================================

  describe "Tier 3 - happy paths" do
    @tag :external
    test "fetch returns status_code, content_type, headers, body", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), fetch_input(), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 200

      data = result.output["data"]
      assert data["status_code"] == 200
      assert is_binary(data["content_type"])
      assert data["content_type"] =~ "html"
      assert is_map(data["headers"])
      assert is_binary(data["body"])
      assert String.length(data["body"]) > 0
      assert data["truncated"] == false
    end

    @tag :external
    test "fetch with explicit GET method works", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "fetch",
        "params" => %{"url" => "https://example.com", "method" => "GET"}
      }, type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 200
      assert result.output["data"]["status_code"] == 200
    end

    @tag :external
    test "fetch with custom headers works", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "fetch",
        "params" => %{
          "url" => "https://example.com",
          "headers" => %{"Accept" => "text/html"}
        }
      }, type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 200
    end

    @tag :external
    test "extract returns title and readable text", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), extract_input(), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 200

      data = result.output["data"]
      assert is_binary(data["title"])
      assert String.length(data["title"]) > 0
      assert is_binary(data["text"])
      assert String.length(data["text"]) > 0
      assert is_integer(data["word_count"])
      assert data["word_count"] > 0
      assert data["url"] == "https://example.com"
    end

    @tag :external
    test "links returns array of href/text objects", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), links_input(), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 200

      data = result.output["data"]
      assert data["url"] == "https://example.com"
      assert is_list(data["links"])
      assert is_integer(data["count"])

      # example.com has at least one link ("More information...")
      if data["count"] > 0 do
        link = List.first(data["links"])
        assert is_binary(link["href"])
        assert is_binary(link["text"])
        assert String.starts_with?(link["href"], "http")
      end
    end

    @tag :external
    test "metadata returns title and structured fields", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), metadata_input(), type: :catalyst)

      assert result.status == :completed
      assert result.output["status"] == 200

      data = result.output["data"]
      assert data["url"] == "https://example.com"
      assert is_binary(data["title"])
      assert String.length(data["title"]) > 0
      # description, canonical, og may or may not be present on example.com
      assert Map.has_key?(data, "description")
      assert Map.has_key?(data, "canonical")
      assert is_map(data["og"])
    end
  end

  # ============================================================================
  # Tier 4: Operation Routing — Unhappy Paths
  # ============================================================================

  describe "Tier 4 - unhappy paths" do
    test "unknown operation returns 400 error", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "nonexistent.op",
        "params" => %{}
      }, type: :catalyst)

      assert result.status == :completed
      output = result.output
      assert output["status"] == 400
      assert output["error"]["type"] == "unknown_operation"
    end

    test "missing operation key returns 500 error", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "params" => %{"url" => "https://example.com"}
      }, type: :catalyst)

      assert result.status == :completed
      output = result.output
      assert output["status"] == 500
      assert output["error"] != nil
    end

    test "fetch without url returns 500 error", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "fetch",
        "params" => %{}
      }, type: :catalyst)

      assert result.status == :completed
      output = result.output
      assert output["status"] == 500
      assert output["error"] != nil
    end

    test "extract without url returns 500 error", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "extract",
        "params" => %{}
      }, type: :catalyst)

      assert result.status == :completed
      output = result.output
      assert output["status"] == 500
      assert output["error"] != nil
    end

    test "links without url returns 500 error", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "links",
        "params" => %{}
      }, type: :catalyst)

      assert result.status == :completed
      output = result.output
      assert output["status"] == 500
      assert output["error"] != nil
    end

    test "metadata without url returns 500 error", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "metadata",
        "params" => %{}
      }, type: :catalyst)

      assert result.status == :completed
      output = result.output
      assert output["status"] == 500
      assert output["error"] != nil
    end

    test "empty JSON input returns 500 error", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), %{}, type: :catalyst)

      assert result.status == :completed
      output = result.output
      assert output["status"] == 500
      assert output["error"] != nil
    end

    test "missing params key still works (defaults to empty object)", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), %{
        "operation" => "fetch"
      }, type: :catalyst)

      assert result.status == :completed
      # Should fail because url is missing, not because params is missing
      output = result.output
      assert output["status"] == 500
      assert output["error"] != nil
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
        "input" => fetch_input(),
        "type" => "catalyst"
      })

      assert msg =~ "allowed_domains"
    end

    test "MCP execution with wrong domain returns completed with error output", %{ctx: ctx, wasm_path: wp} do
      setup_policy(allowed_domains: ["api.wrong.com"])

      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => ref(wp),
        "input" => fetch_input(),
        "type" => "catalyst"
      })

      assert result.status == "completed"
      assert result.result["status"] != 200
    end

    @tag :external
    test "MCP execution with valid config returns completed + 200", %{ctx: ctx, wasm_path: wp} do
      setup_policy(timeout: "30s")

      {:ok, result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => ref(wp),
        "input" => fetch_input(),
        "type" => "catalyst"
      })

      assert result.status == "completed"
      assert result.result["status"] == 200
      assert is_binary(result.execution_id)
      assert String.starts_with?(result.execution_id, "exec_")
    end

    @tag :external
    test "execution record readable via MCP.read after catalyst run", %{ctx: ctx, wasm_path: wp} do
      setup_policy(timeout: "30s")

      {:ok, run_result} = MCP.handle("execution", ctx, %{
        "action" => "run",
        "reference" => ref(wp),
        "input" => extract_input(),
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

      {:ok, result} = Opus.run(ctx, ref(wp), fetch_input(), type: :catalyst)

      assert result.status == :completed
      assert result.metadata.component_type == :catalyst
      assert String.starts_with?(result.metadata.component_digest, "sha256:")

      policy_applied = result.metadata.policy_applied
      assert is_map(policy_applied)
      assert policy_applied.allowed_domains == ["example.com"]
    end

    @tag :external
    test "execution record persisted to SQLite", %{ctx: ctx, wasm_path: wp} do
      setup_policy()

      {:ok, result} = Opus.run(ctx, ref(wp), fetch_input(), type: :catalyst)

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
        allowed_domains: ["example.com"],
        rate_limit: %{requests: 1, window: "1m"}
      )

      {:ok, result1} = Opus.run(ctx, ref(wp), fetch_input(), type: :catalyst)
      assert result1.status == :completed

      {:error, msg} = Opus.run(ctx, ref(wp), fetch_input(), type: :catalyst)
      assert msg =~ "Rate limit"
    end
  end
end
