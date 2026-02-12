defmodule Opus.PolicyEnforcerTest do
  use ExUnit.Case, async: false

  alias Opus.PolicyEnforcer
  alias Sanctum.{Context, Policy}

  describe "validate_execution/3" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

      test_dir = Path.join(System.tmp_dir!(), "cyfr_enforcer_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      Application.put_env(:arca, :base_path, test_dir)
      Arca.Cache.init()

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, test_dir: test_dir}
    end

    test "reagents always pass validation" do
      ctx = Context.local()
      assert :ok = PolicyEnforcer.validate_execution(ctx, "any-component", :reagent)
    end

    test "formulas always pass validation" do
      ctx = Context.local()
      assert :ok = PolicyEnforcer.validate_execution(ctx, "any-component", :formula)
    end

    test "catalysts without allowed_domains are rejected" do
      ctx = Context.local()

      assert {:error, reason} =
               PolicyEnforcer.validate_execution(ctx, "unknown-catalyst", :catalyst)

      assert reason =~ "has no allowed_domains configured"
    end

    test "catalysts with allowed_domains are allowed" do
      ref = "stripe-catalyst-#{:rand.uniform(100_000)}"

      :ok = Sanctum.PolicyStore.put(ref, %{
        allowed_domains: ["api.stripe.com"]
      })

      ctx = Context.local()
      assert {:ok, %Policy{}} = PolicyEnforcer.validate_execution(ctx, ref, :catalyst)

      Sanctum.PolicyStore.delete(ref)
    end
  end

  describe "check_domain/2" do
    test "allows exact domain match" do
      policy = %Policy{allowed_domains: ["api.stripe.com"]}
      assert :ok = PolicyEnforcer.check_domain(policy, "api.stripe.com")
    end

    test "allows wildcard domain match" do
      policy = %Policy{allowed_domains: ["*.stripe.com"]}
      assert :ok = PolicyEnforcer.check_domain(policy, "api.stripe.com")
    end

    test "rejects unauthorized domains" do
      policy = %Policy{allowed_domains: ["api.stripe.com"]}

      assert {:error, reason} = PolicyEnforcer.check_domain(policy, "evil.com")
      assert reason =~ "Policy violation - domain \"evil.com\" not in allowed_domains"
      assert reason =~ "Allowed: api.stripe.com"
    end

    test "rejects all domains when empty" do
      policy = %Policy{allowed_domains: []}

      assert {:error, _reason} = PolicyEnforcer.check_domain(policy, "any.com")
    end
  end

  describe "build_execution_opts/3" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

      test_dir = Path.join(System.tmp_dir!(), "cyfr_enforcer_opts_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      Application.put_env(:arca, :base_path, test_dir)
      Arca.Cache.init()

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, test_dir: test_dir}
    end

    test "returns options with policy settings for reagent" do
      ctx = Context.local()
      {:ok, opts} = PolicyEnforcer.build_execution_opts(ctx, "any-reagent", :reagent)

      assert opts[:component_type] == :reagent
      assert opts[:timeout_ms] > 0
      assert opts[:max_memory_bytes] > 0
      assert %Policy{} = opts[:policy]
    end

    test "includes policy-derived timeout" do
      ref = "timeout-test-#{:rand.uniform(100_000)}"

      :ok = Sanctum.PolicyStore.put(ref, %{timeout: "120s"})

      ctx = Context.local()
      {:ok, opts} = PolicyEnforcer.build_execution_opts(ctx, ref, :reagent)

      assert opts[:timeout_ms] == 120_000

      Sanctum.PolicyStore.delete(ref)
    end

    test "fails for catalyst without policy" do
      ctx = Context.local()

      assert {:error, reason} =
               PolicyEnforcer.build_execution_opts(ctx, "unknown-catalyst", :catalyst)

      assert reason =~ "has no allowed_domains configured"
    end

    test "succeeds for catalyst with policy" do
      ref = "stripe-catalyst-#{:rand.uniform(100_000)}"

      :ok = Sanctum.PolicyStore.put(ref, %{
        allowed_domains: ["api.stripe.com"],
        timeout: "60s"
      })

      ctx = Context.local()
      {:ok, opts} = PolicyEnforcer.build_execution_opts(ctx, ref, :catalyst)

      assert opts[:component_type] == :catalyst
      assert opts[:timeout_ms] == 60_000
      assert opts[:policy].allowed_domains == ["api.stripe.com"]

      Sanctum.PolicyStore.delete(ref)
    end
  end
end
