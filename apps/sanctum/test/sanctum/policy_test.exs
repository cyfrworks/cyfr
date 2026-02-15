defmodule Sanctum.PolicyTest do
  use ExUnit.Case, async: false

  alias Sanctum.Policy
  alias Sanctum.Context

  describe "default/0" do
    test "returns restrictive default policy" do
      policy = Policy.default()

      assert policy.allowed_domains == []
      assert policy.rate_limit == %{requests: 100, window: "1m"}
      assert policy.timeout == "30s"
      assert policy.max_memory_bytes == 64 * 1024 * 1024
      assert policy.allowed_tools == []
      assert policy.allowed_storage_paths == []
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

  describe "allows_storage_path?/2" do
    test "allows all paths when empty list" do
      policy = %Policy{allowed_storage_paths: []}

      assert Policy.allows_storage_path?(policy, "agent/data.json")
      assert Policy.allows_storage_path?(policy, "secrets/key.json")
      assert Policy.allows_storage_path?(policy, "anything")
    end

    test "restricts to prefix when non-empty" do
      policy = %Policy{allowed_storage_paths: ["agent/"]}

      assert Policy.allows_storage_path?(policy, "agent/data.json")
      assert Policy.allows_storage_path?(policy, "agent/sub/file.txt")
      refute Policy.allows_storage_path?(policy, "secrets/key.json")
      refute Policy.allows_storage_path?(policy, "other/path")
    end

    test "allows multiple path prefixes" do
      policy = %Policy{allowed_storage_paths: ["agent/", "artifacts/"]}

      assert Policy.allows_storage_path?(policy, "agent/data.json")
      assert Policy.allows_storage_path?(policy, "artifacts/build.wasm")
      refute Policy.allows_storage_path?(policy, "secrets/key.json")
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
      assert policy.timeout == "30s"
      assert policy.rate_limit == nil
    end

    test "parses memory sizes" do
      map = %{"max_memory_bytes" => "128MB"}
      assert {:ok, policy} = Policy.from_map(map)

      assert policy.max_memory_bytes == 128 * 1024 * 1024
    end

    test "parses allowed_tools and allowed_storage_paths" do
      map = %{
        "allowed_tools" => ["component.*", "storage.read"],
        "allowed_storage_paths" => ["agent/", "artifacts/"]
      }

      assert {:ok, policy} = Policy.from_map(map)

      assert policy.allowed_tools == ["component.*", "storage.read"]
      assert policy.allowed_storage_paths == ["agent/", "artifacts/"]
    end

    test "defaults allowed_tools and allowed_storage_paths to empty" do
      assert {:ok, policy} = Policy.from_map(%{})

      assert policy.allowed_tools == []
      assert policy.allowed_storage_paths == []
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
    test "preserves allowed_tools and allowed_storage_paths" do
      policy = %Policy{
        allowed_domains: ["api.stripe.com"],
        allowed_tools: ["component.*", "storage.read"],
        allowed_storage_paths: ["agent/"]
      }

      map = Policy.to_map(policy)
      assert {:ok, round_tripped} = Policy.from_map(map)

      assert round_tripped.allowed_tools == ["component.*", "storage.read"]
      assert round_tripped.allowed_storage_paths == ["agent/"]
      assert round_tripped.allowed_domains == ["api.stripe.com"]
    end
  end

  describe "get_effective/2" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

      test_dir = Path.join(System.tmp_dir!(), "cyfr_policy_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      Application.put_env(:arca, :base_path, test_dir)

      # Initialize Arca cache (caching now handled by Arca)
      Arca.Cache.init()

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, test_dir: test_dir}
    end

    test "returns type-aware default when no policy exists for catalyst" do
      ctx = Context.local()
      {:ok, policy} = Policy.get_effective(ctx, "catalyst:local.some-component:1.0.0")

      assert policy.allowed_domains == []
      assert policy.timeout == "3m"
    end

    test "returns type-aware default when no policy exists for reagent" do
      ctx = Context.local()
      {:ok, policy} = Policy.get_effective(ctx, "reagent:local.some-component:1.0.0")

      assert policy.allowed_domains == []
      assert policy.timeout == "1m"
    end

    test "returns generic default for untyped refs" do
      ctx = Context.local()
      {:ok, policy} = Policy.get_effective(ctx, "local.some-component:1.0.0")

      assert policy.timeout == "30s"
    end

    test "returns stored policy from SQLite", %{test_dir: _test_dir} do
      ref = "catalyst:local.test-stored-#{:rand.uniform(100_000)}:1.0.0"

      # Store policy in SQLite via PolicyStore
      :ok = Sanctum.PolicyStore.put(ref, %{
        allowed_domains: ["api.stripe.com", "api.openai.com"],
        timeout: "60s"
      })

      ctx = Context.local()
      {:ok, policy} = Policy.get_effective(ctx, ref)

      assert policy.allowed_domains == ["api.stripe.com", "api.openai.com"]
      assert policy.timeout == "60s"

      # Cleanup
      Sanctum.PolicyStore.delete(ref)
    end

    test "component policy from SQLite is returned correctly", %{test_dir: _test_dir} do
      ref = "catalyst:local.stripe-catalyst-#{:rand.uniform(100_000)}:1.0.0"

      # Store component-specific policy
      :ok = Sanctum.PolicyStore.put(ref, %{
        allowed_domains: ["api.stripe.com"],
        timeout: "120s"
      })

      ctx = Context.local()
      {:ok, policy} = Policy.get_effective(ctx, ref)

      assert policy.allowed_domains == ["api.stripe.com"]
      assert policy.timeout == "120s"

      # Cleanup
      Sanctum.PolicyStore.delete(ref)
    end
  end
end
