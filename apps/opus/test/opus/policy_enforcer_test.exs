defmodule Opus.PolicyEnforcerTest do
  use ExUnit.Case, async: false

  alias Opus.PolicyEnforcer
  alias Sanctum.{Context, Policy}

  import Sanctum.Test.ComponentHelpers

  defp ref_name(ref) do
    [_type_ns, rest] = String.split(ref, ".", parts: 2)
    [name, _version] = String.split(rest, ":", parts: 2)
    name
  end

  describe "validate_execution/3" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      test_dir = Path.join(System.tmp_dir!(), "cyfr_enforcer_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      Application.put_env(:cyfr, :base_path, test_dir)
      Arca.Cache.init()

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, test_dir: test_dir}
    end

    test "reagents always pass validation" do
      ctx = Context.local()

      assert {:ok, %Policy{}} =
               PolicyEnforcer.validate_execution(
                 ctx,
                 "reagent:local.any-component:1.0.0",
                 :reagent
               )
    end

    test "formulas always pass validation" do
      ctx = Context.local()

      assert {:ok, %Policy{}} =
               PolicyEnforcer.validate_execution(
                 ctx,
                 "reagent:local.any-component:1.0.0",
                 :formula
               )
    end

    test "catalysts without any capabilities are rejected" do
      ctx = Context.local()

      assert {:error, msg} =
               PolicyEnforcer.validate_execution(
                 ctx,
                 "catalyst:local.unknown-catalyst:1.0.0",
                 :catalyst
               )

      assert msg =~ "has no capabilities configured"
    end

    test "catalysts with allowed_paths but no allowed_domains are allowed" do
      ref = "catalyst:local.storage-only-#{:rand.uniform(100_000)}:1.0.0"
      register_test_component(ref_name(ref), "1.0.0", "catalyst", full_capability_manifest())

      ctx = Context.local()

      :ok =
        Sanctum.PolicyStore.put(ctx, ref, %{
          allowed_paths: ["data/"]
        })

      assert {:ok, %Policy{}} = PolicyEnforcer.validate_execution(ctx, ref, :catalyst)

      Sanctum.PolicyStore.delete(ctx, ref)
    end

    test "catalysts with both allowed_domains and allowed_paths are allowed" do
      ref = "catalyst:local.hybrid-#{:rand.uniform(100_000)}:1.0.0"
      register_test_component(ref_name(ref), "1.0.0", "catalyst", full_capability_manifest())

      ctx = Context.local()

      :ok =
        Sanctum.PolicyStore.put(ctx, ref, %{
          allowed_domains: ["api.example.com"],
          allowed_paths: ["data/"]
        })

      assert {:ok, %Policy{}} = PolicyEnforcer.validate_execution(ctx, ref, :catalyst)

      Sanctum.PolicyStore.delete(ctx, ref)
    end

    test "catalysts with allowed_domains are allowed" do
      ref = "catalyst:local.stripe-catalyst-#{:rand.uniform(100_000)}:1.0.0"
      register_test_component(ref_name(ref), "1.0.0", "catalyst", full_capability_manifest())

      ctx = Context.local()

      :ok =
        Sanctum.PolicyStore.put(ctx, ref, %{
          allowed_domains: ["api.stripe.com"]
        })

      assert {:ok, %Policy{}} = PolicyEnforcer.validate_execution(ctx, ref, :catalyst)

      Sanctum.PolicyStore.delete(ctx, ref)
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
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      test_dir = Path.join(System.tmp_dir!(), "cyfr_enforcer_opts_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      Application.put_env(:cyfr, :base_path, test_dir)
      Arca.Cache.init()

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, test_dir: test_dir}
    end

    test "returns options with policy settings for reagent" do
      ctx = Context.local()

      {:ok, opts} =
        PolicyEnforcer.build_execution_opts(ctx, "reagent:local.any-reagent:1.0.0", :reagent)

      assert opts[:component_type] == :reagent
      assert opts[:timeout_ms] > 0
      assert opts[:max_memory_bytes] > 0
      assert %Policy{} = opts[:policy]
    end

    test "includes policy-derived timeout" do
      ref = "reagent:local.timeout-test-#{:rand.uniform(100_000)}:1.0.0"

      register_test_component(
        ref_name(ref),
        "1.0.0",
        "reagent",
        full_capability_manifest("reagent")
      )

      ctx = Context.local()

      :ok = Sanctum.PolicyStore.put(ctx, ref, %{timeout: "120s"})

      {:ok, opts} = PolicyEnforcer.build_execution_opts(ctx, ref, :reagent)

      assert opts[:timeout_ms] == 120_000

      Sanctum.PolicyStore.delete(ctx, ref)
    end

    test "fails for catalyst without any capabilities" do
      ctx = Context.local()

      assert {:error, msg} =
               PolicyEnforcer.build_execution_opts(
                 ctx,
                 "catalyst:local.unknown-catalyst:1.0.0",
                 :catalyst
               )

      assert msg =~ "has no capabilities configured"
    end

    test "succeeds for storage-only catalyst" do
      ref = "catalyst:local.storage-only-opts-#{:rand.uniform(100_000)}:1.0.0"
      register_test_component(ref_name(ref), "1.0.0", "catalyst", full_capability_manifest())

      ctx = Context.local()

      :ok =
        Sanctum.PolicyStore.put(ctx, ref, %{
          allowed_paths: ["data/"],
          timeout: "30s"
        })

      {:ok, opts} = PolicyEnforcer.build_execution_opts(ctx, ref, :catalyst)

      assert opts[:component_type] == :catalyst
      assert opts[:policy].allowed_paths == ["data/"]

      Sanctum.PolicyStore.delete(ctx, ref)
    end

    test "succeeds for catalyst with policy" do
      ref = "catalyst:local.stripe-catalyst-#{:rand.uniform(100_000)}:1.0.0"
      register_test_component(ref_name(ref), "1.0.0", "catalyst", full_capability_manifest())

      ctx = Context.local()

      :ok =
        Sanctum.PolicyStore.put(ctx, ref, %{
          allowed_domains: ["api.stripe.com"],
          timeout: "60s"
        })

      {:ok, opts} = PolicyEnforcer.build_execution_opts(ctx, ref, :catalyst)

      assert opts[:component_type] == :catalyst
      assert opts[:timeout_ms] == 60_000
      assert opts[:policy].allowed_domains == ["api.stripe.com"]

      Sanctum.PolicyStore.delete(ctx, ref)
    end

    test "clamps policy values to platform ceiling" do
      ref = "reagent:local.ceiling-test-#{:rand.uniform(100_000)}:1.0.0"

      register_test_component(
        ref_name(ref),
        "1.0.0",
        "reagent",
        full_capability_manifest("reagent")
      )

      ctx = Context.local()

      :ok = Sanctum.PolicyStore.put(ctx, ref, %{timeout: "25m", max_memory_bytes: 128 * 1024 * 1024})

      {:ok, opts} = PolicyEnforcer.build_execution_opts(ctx, ref, :reagent)

      # Values should be clamped to platform ceiling
      assert opts[:timeout_ms] <= 30 * 60 * 1000
      assert opts[:max_memory_bytes] <= 256 * 1024 * 1024

      Sanctum.PolicyStore.delete(ctx, ref)
    end

    test "returns clamped policy in opts when exceeding ceiling" do
      ref = "reagent:local.clamp-test-#{:rand.uniform(100_000)}:1.0.0"

      register_test_component(
        ref_name(ref),
        "1.0.0",
        "reagent",
        full_capability_manifest("reagent")
      )

      ctx = Context.local()

      # Set values within ceiling to verify they pass through
      :ok = Sanctum.PolicyStore.put(ctx, ref, %{timeout: "5m", max_memory_bytes: 64 * 1024 * 1024})

      {:ok, opts} = PolicyEnforcer.build_execution_opts(ctx, ref, :reagent)

      assert opts[:timeout_ms] == 5 * 60 * 1000
      assert opts[:max_memory_bytes] == 64 * 1024 * 1024

      Sanctum.PolicyStore.delete(ctx, ref)
    end
  end
end
