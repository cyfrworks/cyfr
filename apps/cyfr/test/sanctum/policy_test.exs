# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PolicyTest do
  use ExUnit.Case, async: false

  alias Sanctum.Policy
  import Sanctum.Test.ComponentHelpers

  describe "default/0" do
    test "returns restrictive default policy" do
      policy = Policy.default()

      assert policy.allowed_domains == []
      assert policy.rate_limit == %{requests: 100, window: "1m"}
      assert policy.timeout == "1m"
      assert policy.max_memory_bytes == 64 * 1024 * 1024
      assert policy.allowed_tools == []
      assert policy.allowed_paths == []
    end
  end

  describe "allows_domain?/2" do
    test "allows exact domain match" do
      policy = %Policy{allowed_domains: ["api.stripe.com"]}

      assert Policy.allows_domain?(policy, "api.stripe.com")
      refute Policy.allows_domain?(policy, "api.paypal.com")
    end

    test "allows wildcard domain match" do
      policy = %Policy{allowed_domains: ["*.stripe.com"]}

      assert Policy.allows_domain?(policy, "api.stripe.com")
      assert Policy.allows_domain?(policy, "dashboard.stripe.com")
      refute Policy.allows_domain?(policy, "stripe.com")
      refute Policy.allows_domain?(policy, "evil.com")
    end

    test "blocks all domains when empty" do
      policy = %Policy{allowed_domains: []}

      refute Policy.allows_domain?(policy, "api.stripe.com")
      refute Policy.allows_domain?(policy, "localhost")
    end

    test "allows multiple domains" do
      policy = %Policy{allowed_domains: ["api.stripe.com", "api.openai.com"]}

      assert Policy.allows_domain?(policy, "api.stripe.com")
      assert Policy.allows_domain?(policy, "api.openai.com")
      refute Policy.allows_domain?(policy, "evil.com")
    end
  end

  describe "default/1" do
    test "catalyst default has 3m timeout" do
      policy = Policy.default(:catalyst)
      assert policy.timeout == "3m"
      assert policy.allowed_domains == []
      assert policy.rate_limit == %{requests: 100, window: "1m"}
    end

    test "formula default has 5m timeout" do
      policy = Policy.default(:formula)
      assert policy.timeout == "5m"
    end

    test "reagent default has 1m timeout" do
      policy = Policy.default(:reagent)
      assert policy.timeout == "1m"
    end
  end

  describe "timeout_ms/1" do
    test "parses seconds" do
      policy = %Policy{timeout: "30s"}
      assert Policy.timeout_ms(policy) == {:ok, 30_000}
    end

    test "parses minutes" do
      policy = %Policy{timeout: "2m"}
      assert Policy.timeout_ms(policy) == {:ok, 120_000}
    end

    test "parses milliseconds" do
      policy = %Policy{timeout: "500ms"}
      assert Policy.timeout_ms(policy) == {:ok, 500}
    end

    test "parses hours" do
      policy = %Policy{timeout: "1h"}
      assert Policy.timeout_ms(policy) == {:ok, 3_600_000}
    end

    test "returns error for invalid duration" do
      policy = %Policy{timeout: "abc"}
      assert {:error, msg} = Policy.timeout_ms(policy)
      assert msg =~ "Invalid duration"
    end
  end

  describe "allows_tool?/2" do
    test "allows exact tool match" do
      policy = %Policy{allowed_tools: ["component.search"]}

      assert Policy.allows_tool?(policy, "component.search")
      refute Policy.allows_tool?(policy, "component.inspect")
    end

    test "allows wildcard tool match" do
      policy = %Policy{allowed_tools: ["component.*"]}

      assert Policy.allows_tool?(policy, "component.search")
      assert Policy.allows_tool?(policy, "component.inspect")
      refute Policy.allows_tool?(policy, "storage.read")
    end

    test "denies all tools when empty list" do
      policy = %Policy{allowed_tools: []}

      refute Policy.allows_tool?(policy, "component.search")
      refute Policy.allows_tool?(policy, "storage.read")
    end

    test "allows multiple tool patterns" do
      policy = %Policy{allowed_tools: ["component.search", "storage.*"]}

      assert Policy.allows_tool?(policy, "component.search")
      refute Policy.allows_tool?(policy, "component.inspect")
      assert Policy.allows_tool?(policy, "storage.read")
      assert Policy.allows_tool?(policy, "storage.write")
    end
  end

  describe "allows_path?/2" do
    test "denies all paths when empty list" do
      policy = %Policy{allowed_paths: []}

      refute Policy.allows_path?(policy, "data/file.json")
      refute Policy.allows_path?(policy, "components/catalysts/test/0.1.0/catalyst.wasm")
    end

    test "* allows both data and components" do
      policy = %Policy{allowed_paths: ["*"]}

      assert Policy.allows_path?(policy, "data/file.txt")
      assert Policy.allows_path?(policy, "data/reports/2024.json")
      assert Policy.allows_path?(policy, "components/catalysts/test/0.1.0/catalyst.wasm")
    end

    test "data/ allows all data paths" do
      policy = %Policy{allowed_paths: ["data/"]}

      assert Policy.allows_path?(policy, "data/file.txt")
      assert Policy.allows_path?(policy, "data/reports/2024.json")
      refute Policy.allows_path?(policy, "components/catalysts/test/0.1.0/catalyst.wasm")
    end

    test "components/ allows all component paths" do
      policy = %Policy{allowed_paths: ["components/"]}

      assert Policy.allows_path?(policy, "components/catalysts/test/0.1.0/catalyst.wasm")
      assert Policy.allows_path?(policy, "components/reagents/agent/data.json")
      refute Policy.allows_path?(policy, "data/file.txt")
    end

    test "bare scope name without slash matches nothing" do
      policy = %Policy{allowed_paths: ["data"]}

      refute Policy.allows_path?(policy, "data/file.txt")
      refute Policy.allows_path?(policy, "datafile.txt")
    end

    test "exact file path matches only that file" do
      policy = %Policy{allowed_paths: ["data/report.json"]}

      assert Policy.allows_path?(policy, "data/report.json")
      refute Policy.allows_path?(policy, "data/report.json.bak")
      refute Policy.allows_path?(policy, "data/other.json")
      refute Policy.allows_path?(policy, "data/report.json/nested")
    end

    test "restricts to sub-prefix" do
      policy = %Policy{allowed_paths: ["data/reports/"]}

      assert Policy.allows_path?(policy, "data/reports/2024.json")
      assert Policy.allows_path?(policy, "data/reports/sub/file.txt")
      refute Policy.allows_path?(policy, "data/secrets/key.json")
    end

    test "no prefix bleed without directory boundary" do
      policy = %Policy{allowed_paths: ["data/"]}

      refute Policy.allows_path?(policy, "datafile.txt")
    end

    test "allows multiple path prefixes" do
      policy = %Policy{allowed_paths: ["data/", "components/catalysts/"]}

      assert Policy.allows_path?(policy, "data/file.json")
      assert Policy.allows_path?(policy, "components/catalysts/test/0.1.0/catalyst.wasm")
      refute Policy.allows_path?(policy, "components/reagents/agent/data.json")
    end
  end

  describe "allows_action?/2" do
    test "allows action in list" do
      policy = %Policy{allowed_actions: ["read", "write", "list"]}

      assert Policy.allows_action?(policy, "read")
      assert Policy.allows_action?(policy, "write")
      assert Policy.allows_action?(policy, "list")
    end

    test "denies action not in list" do
      policy = %Policy{allowed_actions: ["read", "list"]}

      refute Policy.allows_action?(policy, "write")
      refute Policy.allows_action?(policy, "delete")
    end

    test "case insensitive matching" do
      policy = %Policy{allowed_actions: ["READ", "Write"]}

      assert Policy.allows_action?(policy, "read")
      assert Policy.allows_action?(policy, "write")
      assert Policy.allows_action?(policy, "READ")
    end

    test "default denies all storage actions" do
      policy = Policy.default()

      refute Policy.allows_action?(policy, "read")
      refute Policy.allows_action?(policy, "write")
      refute Policy.allows_action?(policy, "list")
      refute Policy.allows_action?(policy, "delete")
      refute Policy.allows_action?(policy, "exists")
    end

    test "empty list denies all" do
      policy = %Policy{allowed_actions: []}

      refute Policy.allows_action?(policy, "read")
      refute Policy.allows_action?(policy, "write")
    end
  end

  describe "allows_private_ip?/2" do
    test "denies all private IPs when allowed_private_ips is empty" do
      policy = %Policy{allowed_private_ips: []}

      refute Policy.allows_private_ip?(policy, {10, 0, 0, 1})
      refute Policy.allows_private_ip?(policy, {192, 168, 1, 1})
      refute Policy.allows_private_ip?(policy, {127, 0, 0, 1})
    end

    test "allows exact IP match" do
      policy = %Policy{allowed_private_ips: ["192.168.1.100"]}

      assert Policy.allows_private_ip?(policy, {192, 168, 1, 100})
      refute Policy.allows_private_ip?(policy, {192, 168, 1, 101})
    end

    test "allows CIDR range match" do
      policy = %Policy{allowed_private_ips: ["10.0.0.0/8"]}

      assert Policy.allows_private_ip?(policy, {10, 0, 0, 1})
      assert Policy.allows_private_ip?(policy, {10, 1, 2, 3})
      assert Policy.allows_private_ip?(policy, {10, 255, 255, 255})
      refute Policy.allows_private_ip?(policy, {192, 168, 1, 1})
    end

    test "allows /16 CIDR range" do
      policy = %Policy{allowed_private_ips: ["192.168.0.0/16"]}

      assert Policy.allows_private_ip?(policy, {192, 168, 0, 1})
      assert Policy.allows_private_ip?(policy, {192, 168, 255, 255})
      refute Policy.allows_private_ip?(policy, {10, 0, 0, 1})
    end

    test "allows /32 CIDR (single host)" do
      policy = %Policy{allowed_private_ips: ["10.1.2.3/32"]}

      assert Policy.allows_private_ip?(policy, {10, 1, 2, 3})
      refute Policy.allows_private_ip?(policy, {10, 1, 2, 4})
    end

    test "always blocks 169.254.0.0/16 even when explicitly listed" do
      policy = %Policy{allowed_private_ips: ["169.254.0.0/16", "169.254.169.254"]}

      refute Policy.allows_private_ip?(policy, {169, 254, 169, 254})
      refute Policy.allows_private_ip?(policy, {169, 254, 0, 1})
    end

    test "allows multiple entries" do
      policy = %Policy{allowed_private_ips: ["10.0.0.0/8", "192.168.1.100"]}

      assert Policy.allows_private_ip?(policy, {10, 1, 2, 3})
      assert Policy.allows_private_ip?(policy, {192, 168, 1, 100})
      refute Policy.allows_private_ip?(policy, {192, 168, 1, 101})
    end

    test "handles IPv4-mapped IPv6 addresses" do
      policy = %Policy{allowed_private_ips: ["10.0.0.0/8"]}

      # ::ffff:10.0.0.1 = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}
      assert Policy.allows_private_ip?(policy, {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
      # ::ffff:192.168.1.1 not in 10.0.0.0/8
      refute Policy.allows_private_ip?(policy, {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101})
    end

    test "blocks IPv4-mapped IPv6 link-local even when listed" do
      policy = %Policy{allowed_private_ips: ["169.254.0.0/16"]}

      # ::ffff:169.254.169.254
      refute Policy.allows_private_ip?(policy, {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
    end
  end

  describe "from_map/1" do
    test "converts map to policy struct" do
      map = %{
        "allowed_domains" => ["api.stripe.com", "api.openai.com"],
        "timeout" => "60s",
        "rate_limit" => "50/1m"
      }

      assert {:ok, policy} = Policy.from_map(map)

      assert policy.allowed_domains == ["api.stripe.com", "api.openai.com"]
      assert policy.timeout == "60s"
      assert policy.rate_limit == %{requests: 50, window: "1m"}
    end

    test "handles missing fields with defaults" do
      assert {:ok, policy} = Policy.from_map(%{})

      assert policy.allowed_domains == []
      assert policy.timeout == "1m"
      assert policy.rate_limit == nil
    end

    test "parses memory sizes" do
      map = %{"max_memory_bytes" => "128MB"}
      assert {:ok, policy} = Policy.from_map(map)

      assert policy.max_memory_bytes == 128 * 1024 * 1024
    end

    test "parses allowed_tools and allowed_paths" do
      map = %{
        "allowed_tools" => ["component.*", "storage.read"],
        "allowed_paths" => ["data/", "components/catalysts/"]
      }

      assert {:ok, policy} = Policy.from_map(map)

      assert policy.allowed_tools == ["component.*", "storage.read"]
      assert policy.allowed_paths == ["data/", "components/catalysts/"]
    end

    test "defaults allowed_tools and allowed_paths to empty" do
      assert {:ok, policy} = Policy.from_map(%{})

      assert policy.allowed_tools == []
      assert policy.allowed_paths == []
    end

    test "returns error for invalid memory size" do
      map = %{"max_memory_bytes" => "abc"}
      assert {:error, msg} = Policy.from_map(map)
      assert msg =~ "Invalid memory size"
    end

    test "returns error for invalid rate limit" do
      map = %{"rate_limit" => "not-valid"}
      assert {:error, msg} = Policy.from_map(map)
      assert msg =~ "Invalid rate limit"
    end
  end

  describe "to_map/from_map round-trip" do
    test "preserves allowed_tools and allowed_paths" do
      policy = %Policy{
        allowed_domains: ["api.stripe.com"],
        allowed_tools: ["component.*", "storage.read"],
        allowed_paths: ["data/"]
      }

      map = Policy.to_map(policy)
      assert {:ok, round_tripped} = Policy.from_map(map)

      assert round_tripped.allowed_tools == ["component.*", "storage.read"]
      assert round_tripped.allowed_paths == ["data/"]
      assert round_tripped.allowed_domains == ["api.stripe.com"]
    end

    test "preserves allowed_actions" do
      policy = %Policy{
        allowed_domains: ["api.stripe.com"],
        allowed_actions: ["read", "list", "exists"]
      }

      map = Policy.to_map(policy)
      assert {:ok, round_tripped} = Policy.from_map(map)

      assert round_tripped.allowed_actions == ["read", "list", "exists"]
    end

    test "defaults allowed_actions to empty when not present in map" do
      assert {:ok, policy} = Policy.from_map(%{})

      assert policy.allowed_actions == []
    end

    test "preserves allowed_private_ips" do
      policy = %Policy{
        allowed_domains: ["api.stripe.com"],
        allowed_private_ips: ["10.0.0.0/8", "192.168.1.100"]
      }

      map = Policy.to_map(policy)
      assert {:ok, round_tripped} = Policy.from_map(map)

      assert round_tripped.allowed_private_ips == ["10.0.0.0/8", "192.168.1.100"]
    end
  end

  describe "get_effective/2" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      test_dir = Path.join(System.tmp_dir!(), "cyfr_policy_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      Application.put_env(:cyfr, :base_path, test_dir)

      # Initialize Arca cache (caching now handled by Arca)
      Arca.Cache.init()

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, test_dir: test_dir}
    end

    test "returns type-aware default when no policy exists for catalyst" do
      ctx = Sanctum.TestContext.local()
      {:ok, policy, meta} = Policy.get_effective(ctx, "catalyst:local.some-component:1.0.0")

      assert policy.allowed_domains == []
      assert policy.timeout == "3m"
      assert meta.source in [:type_default, :hardcoded_default]
    end

    test "returns type-aware default when no policy exists for reagent" do
      ctx = Sanctum.TestContext.local()
      {:ok, policy, meta} = Policy.get_effective(ctx, "reagent:local.some-component:1.0.0")

      assert policy.allowed_domains == []
      assert policy.timeout == "1m"
      assert meta.source in [:type_default, :hardcoded_default]
    end

    test "fails closed on an un-normalizable (untyped) ref (S6)" do
      # A missing type prefix is a caller bug — get_effective returns an
      # :invalid_ref error rather than silently substituting a default policy
      # (which masked the bug and could return a different policy than asked).
      ctx = Sanctum.TestContext.local()

      assert {:error, {:invalid_ref, _reason}} =
               Policy.get_effective(ctx, "local.some-component:1.0.0")
    end

    test "returns stored policy from SQLite", %{test_dir: _test_dir} do
      rand_id = :rand.uniform(100_000)
      name = "test-stored-#{rand_id}"
      ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", full_capability_manifest())

      ctx = Sanctum.TestContext.local()

      # Store policy in SQLite via PolicyStore
      :ok =
        Sanctum.PolicyStore.put(ctx, ref, %{
          allowed_domains: ["api.stripe.com", "api.openai.com"],
          timeout: "60s"
        })

      {:ok, policy, meta} = Policy.get_effective(ctx, ref)

      assert policy.allowed_domains == ["api.stripe.com", "api.openai.com"]
      assert policy.timeout == "60s"
      assert meta.source == :exact_ref

      # Cleanup
      Sanctum.PolicyStore.delete(ctx, ref)
    end

    test "component policy from SQLite is returned correctly", %{test_dir: _test_dir} do
      rand_id = :rand.uniform(100_000)
      name = "stripe-catalyst-#{rand_id}"
      ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", full_capability_manifest())

      ctx = Sanctum.TestContext.local()

      # Store component-specific policy
      :ok =
        Sanctum.PolicyStore.put(ctx, ref, %{
          allowed_domains: ["api.stripe.com"],
          timeout: "120s"
        })

      {:ok, policy, meta} = Policy.get_effective(ctx, ref)

      assert policy.allowed_domains == ["api.stripe.com"]
      assert policy.timeout == "120s"
      assert meta.source == :exact_ref

      # Cleanup
      Sanctum.PolicyStore.delete(ctx, ref)
    end

    test "name-level policy is found when exact ref has no policy", %{test_dir: _test_dir} do
      rand_id = :rand.uniform(100_000)
      name = "name-level-test-#{rand_id}"
      name_ref = "catalyst:local.#{name}"
      exact_ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", full_capability_manifest())

      ctx = Sanctum.TestContext.local()

      # Store name-level policy (without version)
      :ok =
        Sanctum.PolicyStore.put(ctx, name_ref, %{
          allowed_domains: ["api.example.com"],
          timeout: "45s"
        })

      {:ok, policy, meta} = Policy.get_effective(ctx, exact_ref)

      assert policy.allowed_domains == ["api.example.com"]
      assert policy.timeout == "45s"
      assert meta.source == :name_level

      # Cleanup
      Sanctum.PolicyStore.delete(ctx, name_ref)
    end

    test "exact ref policy takes precedence over name-level", %{test_dir: _test_dir} do
      rand_id = :rand.uniform(100_000)
      name = "precedence-test-#{rand_id}"
      name_ref = "catalyst:local.#{name}"
      exact_ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", full_capability_manifest())

      ctx = Sanctum.TestContext.local()

      # Store both name-level and exact-ref policies
      :ok =
        Sanctum.PolicyStore.put(ctx, name_ref, %{
          allowed_domains: ["name-level.example.com"],
          timeout: "30s"
        })

      :ok =
        Sanctum.PolicyStore.put(ctx, exact_ref, %{
          allowed_domains: ["exact.example.com"],
          timeout: "60s"
        })

      {:ok, policy, meta} = Policy.get_effective(ctx, exact_ref)

      assert policy.allowed_domains == ["exact.example.com"]
      assert policy.timeout == "60s"
      assert meta.source == :exact_ref

      # Cleanup
      Sanctum.PolicyStore.delete(ctx, name_ref)
      Sanctum.PolicyStore.delete(ctx, exact_ref)
    end

    test "returns uncovered_capabilities in meta for name-level policies", %{test_dir: _test_dir} do
      rand_id = :rand.uniform(100_000)
      name = "uncovered-cap-#{rand_id}"
      name_ref = "catalyst:local.#{name}"
      versioned_ref = "catalyst:local.#{name}:1.0.0"

      # Register component that declares allowed_domains AND allowed_paths
      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{
          "policy" => %{
            "allowed_domains" => [],
            "allowed_paths" => []
          }
        }
      })

      ctx = Sanctum.TestContext.local()

      # Store name-level policy that only covers allowed_domains
      :ok =
        Sanctum.PolicyStore.put(ctx, name_ref, %{
          allowed_domains: ["api.example.com"]
        })

      # Looking up via versioned ref should find name-level policy
      # and report uncovered_capabilities for allowed_paths
      {:ok, policy, meta} = Policy.get_effective(ctx, versioned_ref)

      assert policy.allowed_domains == ["api.example.com"]
      assert meta.source == :name_level
      assert meta.uncovered_capabilities == ["allowed_paths"]

      # Cleanup
      Sanctum.PolicyStore.delete(ctx, name_ref)
    end

    test "no uncovered_capabilities when all declared capabilities are covered", %{
      test_dir: _test_dir
    } do
      rand_id = :rand.uniform(100_000)
      name = "covered-cap-#{rand_id}"
      name_ref = "catalyst:local.#{name}"
      versioned_ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{
          "policy" => %{
            "allowed_domains" => [],
            "allowed_paths" => []
          }
        }
      })

      ctx = Sanctum.TestContext.local()

      # Store name-level policy covering both capabilities
      :ok =
        Sanctum.PolicyStore.put(ctx, name_ref, %{
          allowed_domains: ["api.example.com"],
          allowed_paths: ["data/"]
        })

      {:ok, _policy, meta} = Policy.get_effective(ctx, versioned_ref)

      assert meta.source == :name_level
      refute Map.has_key?(meta, :uncovered_capabilities)

      # Cleanup
      Sanctum.PolicyStore.delete(ctx, name_ref)
    end
  end
end
