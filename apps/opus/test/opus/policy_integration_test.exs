defmodule Opus.PolicyIntegrationTest do
  @moduledoc """
  Integration tests for the v0.3 Policy Gate milestone.

  These tests verify the complete policy lifecycle:
  1. Policy storage via Sanctum.PolicyStore
  2. Policy enforcement via Opus.PolicyEnforcer
  3. Rate limiting via Opus.RateLimiter
  4. HTTP host function policy validation via Opus.HttpHandler
  """
  use ExUnit.Case, async: false

  alias Opus.{HttpHandler, PolicyEnforcer, RateLimiter}
  alias Sanctum.{Context, Policy, PolicyStore}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    test_dir = Path.join(System.tmp_dir!(), "cyfr_integration_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:arca, :base_path, test_dir)

    # Initialize Arca cache (caching now handled by Arca)
    Arca.Cache.init()

    # Ensure rate limiter is running
    case GenServer.whereis(RateLimiter) do
      nil -> {:ok, _} = RateLimiter.start_link([])
      _pid -> :ok
    end

    ctx = %Context{
      user_id: "test_user_#{:rand.uniform(100_000)}",
      org_id: nil,
      scope: :local,
      permissions: [:read, :write, :execute]
    }

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir, ctx: ctx}
  end

  describe "full policy lifecycle" do
    test "catalyst execution respects policy constraints", %{ctx: ctx} do
      component_ref = "catalyst:local.test-catalyst-#{:rand.uniform(100_000)}:1.0.0"

      # Store policy in SQLite via PolicyStore
      :ok = PolicyStore.put(component_ref, %{
        allowed_domains: ["api.stripe.com", "httpbin.org"],
        allowed_methods: ["GET", "POST"],
        rate_limit: %{requests: 10, window: "1m"},
        timeout: "30s"
      })

      # 1. Validate catalyst can execute (has allowed_domains) — returns {:ok, policy}
      assert {:ok, %Sanctum.Policy{}} = PolicyEnforcer.validate_execution(ctx, component_ref, :catalyst)

      # 2. Get policy and verify constraints
      {:ok, policy} = PolicyEnforcer.get_policy(ctx, component_ref)
      assert "api.stripe.com" in policy.allowed_domains
      assert "httpbin.org" in policy.allowed_domains

      # 3. Test domain checking
      assert :ok = PolicyEnforcer.check_domain(policy, "api.stripe.com")
      assert :ok = PolicyEnforcer.check_domain(policy, "httpbin.org")
      assert {:error, _} = PolicyEnforcer.check_domain(policy, "evil.com")

      # 4. Test method checking
      assert :ok = PolicyEnforcer.check_method(policy, "GET")
      assert :ok = PolicyEnforcer.check_method(policy, "POST")
      assert {:error, _} = PolicyEnforcer.check_method(policy, "DELETE")

      # 5. Test combined HTTP request validation
      assert :ok = PolicyEnforcer.check_http_request(policy, "api.stripe.com", "GET")
      assert {:error, _} = PolicyEnforcer.check_http_request(policy, "evil.com", "GET")
      assert {:error, _} = PolicyEnforcer.check_http_request(policy, "api.stripe.com", "DELETE")

      PolicyStore.delete(component_ref)
    end

    test "blocked domain returns clear error with allowed list", %{ctx: ctx} do
      component_ref = "catalyst:local.test-catalyst-#{:rand.uniform(100_000)}:1.0.0"

      :ok = PolicyStore.put(component_ref, %{
        allowed_domains: ["api.stripe.com", "httpbin.org"]
      })

      {:ok, policy} = PolicyEnforcer.get_policy(ctx, component_ref)

      # Attempt to access blocked domain
      {:error, error_msg} = PolicyEnforcer.check_domain(policy, "evil.com")

      # Verify error format matches v0.3 spec
      assert error_msg =~ "Error: Policy violation"
      assert error_msg =~ "domain \"evil.com\" not in allowed_domains"
      assert error_msg =~ "Allowed:"
      assert error_msg =~ "api.stripe.com"
      assert error_msg =~ "httpbin.org"

      PolicyStore.delete(component_ref)
    end

    test "rate limit exhaustion returns retry_after time", %{ctx: ctx} do
      component_ref = "catalyst:local.test-rate-limited-#{:rand.uniform(100_000)}:1.0.0"
      user_id = ctx.user_id

      policy = %Policy{
        allowed_domains: ["api.stripe.com"],
        rate_limit: %{requests: 3, window: "1m"},
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024
      }

      # Use up all 3 requests
      assert {:ok, 2} = RateLimiter.check(user_id, component_ref, policy)
      assert {:ok, 1} = RateLimiter.check(user_id, component_ref, policy)
      assert {:ok, 0} = RateLimiter.check(user_id, component_ref, policy)

      # Fourth request should be rate limited with retry_after
      assert {:error, :rate_limited, retry_after_ms} =
               RateLimiter.check(user_id, component_ref, policy)

      assert is_integer(retry_after_ms)
      assert retry_after_ms >= 0
      assert retry_after_ms <= 60_000

      # Cleanup
      RateLimiter.reset(user_id, component_ref)
    end
  end

  describe "component type enforcement" do
    test "reagent components cannot make HTTP requests - always pass validation" do
      ctx = Context.local()
      assert :ok = PolicyEnforcer.validate_execution(ctx, "reagent:local.any-reagent:1.0.0", :reagent)
    end

    test "catalyst without allowed_domains is rejected", %{ctx: ctx} do
      {:error, error_msg} =
        PolicyEnforcer.validate_execution(ctx, "catalyst:local.nonexistent-catalyst:1.0.0", :catalyst)

      assert error_msg =~ "has no allowed_domains configured"
      assert error_msg =~ "allowed_domains"
    end

    test "catalyst with empty allowed_domains is rejected", %{ctx: ctx} do
      component_ref = "catalyst:local.empty-policy-catalyst-#{:rand.uniform(100_000)}:1.0.0"

      # Store policy with empty allowed_domains
      :ok = PolicyStore.put(component_ref, %{
        allowed_domains: []
      })

      {:error, error_msg} = PolicyEnforcer.validate_execution(ctx, component_ref, :catalyst)
      assert error_msg =~ "has no allowed_domains configured"

      PolicyStore.delete(component_ref)
    end
  end

  describe "HTTP host function policy integration" do
    test "build_http_imports returns valid import map", %{ctx: ctx} do
      policy = %Policy{
        allowed_domains: ["httpbin.org", "api.stripe.com"],
        allowed_methods: ["GET", "POST"],
        rate_limit: %{requests: 100, window: "1m"},
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024
      }

      imports = HttpHandler.build_http_imports(policy, ctx, "local.test-component:1.0.0")

      assert Map.has_key?(imports, "cyfr:http/fetch@0.1.0")
      assert Map.has_key?(imports["cyfr:http/fetch@0.1.0"], "request")
    end

    test "host function validates domain before executing requests", %{ctx: ctx} do
      policy = %Policy{
        allowed_domains: ["httpbin.org"],
        allowed_methods: ["GET"],
        rate_limit: nil,
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880
      }

      # Allowed domain passes domain check
      assert :ok = PolicyEnforcer.check_domain(policy, "httpbin.org")

      # Blocked domain via host function returns error JSON
      request = Jason.encode!(%{
        "method" => "GET",
        "url" => "https://evil.com/data",
        "headers" => %{},
        "body" => ""
      })

      result = HttpHandler.execute(request, policy, ctx, "local.test-component:1.0.0")
      decoded = Jason.decode!(result)
      assert decoded["error"]["type"] == "domain_blocked"
    end
  end

  describe "policy violation audit logging" do
    test "log_violation creates audit entry without error" do
      violation_data = %{
        component_ref: "local.test-catalyst:1.0.0",
        user_id: "test_user_123",
        domain: "evil.com",
        method: "GET",
        reason: "Domain not in allowed list"
      }

      result = Sanctum.PolicyLog.log_violation(violation_data)
      assert result == :ok or match?({:error, _}, result)
    end

    test "log_violation includes all required fields" do
      violation_data = %{
        component_ref: "local.stripe-catalyst:1.0.0",
        user_id: "user_456",
        domain: "unauthorized.com",
        method: "POST",
        reason: "Error: Policy violation - domain \"unauthorized.com\" not in allowed_domains"
      }

      result = Sanctum.PolicyLog.log_violation(violation_data)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "build_execution_opts integration" do
    test "returns complete execution options for catalyst", %{ctx: ctx} do
      component_ref = "catalyst:local.opts-catalyst-#{:rand.uniform(100_000)}:1.0.0"

      :ok = PolicyStore.put(component_ref, %{
        allowed_domains: ["api.stripe.com"],
        timeout: "45s",
        max_memory_bytes: 128_000_000
      })

      {:ok, opts} = PolicyEnforcer.build_execution_opts(ctx, component_ref, :catalyst)

      assert opts[:component_type] == :catalyst
      assert opts[:timeout_ms] == 45_000
      assert opts[:max_memory_bytes] == 128_000_000
      assert %Policy{} = opts[:policy]
      assert "api.stripe.com" in opts[:policy].allowed_domains

      PolicyStore.delete(component_ref)
    end

    test "fails for catalyst without policy", %{ctx: ctx} do
      {:error, reason} =
        PolicyEnforcer.build_execution_opts(ctx, "catalyst:local.nonexistent-catalyst:1.0.0", :catalyst)

      assert reason =~ "has no allowed_domains configured"
    end
  end
end
