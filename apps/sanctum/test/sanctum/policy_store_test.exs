defmodule Sanctum.PolicyStoreTest do
  use ExUnit.Case, async: false

  alias Sanctum.{Policy, PolicyStore}

  # Database-dependent tests are tagged with @tag :requires_arca
  # They check arca_available?() at runtime and skip gracefully if DB is not available.
  # To explicitly exclude these tests: EXCLUDE_ARCA_TESTS=1 mix test

  setup do
    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    # Ensure Arca.Cache is initialized
    Arca.Cache.init()

    # Use a unique component ref for each test to avoid conflicts
    component_ref = "catalyst:local.test-component-#{:rand.uniform(100_000)}:1.0.0"

    # Check if Arca is available for this test run
    arca_ok = arca_available?()

    on_exit(fn ->
      # Clean up the test policy
      PolicyStore.delete(component_ref)
    end)

    {:ok, component_ref: component_ref, arca_available: arca_ok}
  end

  # Runtime check for Arca availability (database must be running)
  defp arca_available? do
    Code.ensure_loaded?(Arca.PolicyStorage) and
      Code.ensure_loaded?(Arca.Repo) and
      match?({:ok, _}, Arca.Repo.query("SELECT 1"))
  rescue
    _ -> false
  end

  describe "put/2 and get/1" do
    @tag :requires_arca
    test "stores and retrieves a policy struct", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_stores_and_retrieves_policy_struct(ref)
    end

    defp do_test_stores_and_retrieves_policy_struct(ref) do
      policy = %Policy{
        allowed_domains: ["api.stripe.com"],
        allowed_methods: ["GET", "POST"],
        rate_limit: %{requests: 100, window: "1m"},
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024
      }

      assert :ok = PolicyStore.put(ref, policy)
      assert {:ok, retrieved} = PolicyStore.get(ref)

      assert retrieved.allowed_domains == ["api.stripe.com"]
      assert retrieved.allowed_methods == ["GET", "POST"]
      assert retrieved.rate_limit == %{requests: 100, window: "1m"}
    end

    @tag :requires_arca
    test "stores and retrieves a policy map", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_stores_and_retrieves_policy_map(ref)
    end

    defp do_test_stores_and_retrieves_policy_map(ref) do
      policy_map = %{
        allowed_domains: ["httpbin.org"],
        allowed_methods: ["GET"],
        rate_limit: %{requests: 50, window: "5m"},
        timeout: "60s"
      }

      assert :ok = PolicyStore.put(ref, policy_map)
      assert {:ok, retrieved} = PolicyStore.get(ref)

      assert retrieved.allowed_domains == ["httpbin.org"]
      assert retrieved.allowed_methods == ["GET"]
      assert retrieved.rate_limit == %{requests: 50, window: "5m"}
      assert retrieved.timeout == "60s"
    end

    @tag :requires_arca
    test "upserts existing policy", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_upserts_existing_policy(ref)
    end

    defp do_test_upserts_existing_policy(ref) do
      policy1 = %Policy{allowed_domains: ["first.com"]}
      policy2 = %Policy{allowed_domains: ["second.com"]}

      assert :ok = PolicyStore.put(ref, policy1)
      assert {:ok, retrieved1} = PolicyStore.get(ref)
      assert retrieved1.allowed_domains == ["first.com"]

      assert :ok = PolicyStore.put(ref, policy2)
      assert {:ok, retrieved2} = PolicyStore.get(ref)
      assert retrieved2.allowed_domains == ["second.com"]
    end
  end

  describe "get/1" do
    test "returns error for non-existent policy" do
      assert {:error, :not_found} = PolicyStore.get("catalyst:local.nonexistent-component-xyz:1.0.0")
    end

    @tag :requires_arca
    test "subsequent reads return same data", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_subsequent_reads(ref)
    end

    defp do_test_subsequent_reads(ref) do
      policy = %Policy{allowed_domains: ["cached.com"]}
      assert :ok = PolicyStore.put(ref, policy)

      # Both reads should return the same data (caching is handled by Arca.Cache)
      assert {:ok, _} = PolicyStore.get(ref)
      assert {:ok, retrieved} = PolicyStore.get(ref)
      assert retrieved.allowed_domains == ["cached.com"]
    end
  end

  describe "delete/1" do
    @tag :requires_arca
    test "removes a policy", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_removes_policy(ref)
    end

    defp do_test_removes_policy(ref) do
      policy = %Policy{allowed_domains: ["delete-me.com"]}

      assert :ok = PolicyStore.put(ref, policy)
      assert {:ok, _} = PolicyStore.get(ref)

      assert :ok = PolicyStore.delete(ref)
      assert {:error, :not_found} = PolicyStore.get(ref)
    end

    test "succeeds for non-existent policy" do
      assert :ok = PolicyStore.delete("catalyst:local.never-existed-component:1.0.0")
    end
  end

  describe "list/0" do
    test "returns ok tuple" do
      assert {:ok, _} = PolicyStore.list()
    end

    @tag :requires_arca
    test "returns all stored policies", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_returns_all_stored_policies(ref)
    end

    defp do_test_returns_all_stored_policies(ref) do
      policy = %Policy{allowed_domains: ["list-test.com"]}
      assert :ok = PolicyStore.put(ref, policy)

      # Refs are normalized to canonical format (namespace.name:version)
      {:ok, canonical_ref} = Sanctum.ComponentRef.normalize(ref)

      assert {:ok, policies} = PolicyStore.list()
      assert Enum.any?(policies, fn p -> p.component_ref == canonical_ref end)
    end
  end

  describe "update_field/3" do
    @tag :requires_arca
    test "updates allowed_domains", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_updates_allowed_domains(ref)
    end

    defp do_test_updates_allowed_domains(ref) do
      # First create a base policy
      policy = %Policy{allowed_domains: ["original.com"]}
      assert :ok = PolicyStore.put(ref, policy)

      # Update allowed_domains
      assert :ok = PolicyStore.update_field(ref, "allowed_domains", ~s(["new.com", "other.com"]))

      assert {:ok, retrieved} = PolicyStore.get(ref)
      assert retrieved.allowed_domains == ["new.com", "other.com"]
    end

    @tag :requires_arca
    test "updates allowed_methods", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_updates_allowed_methods(ref)
    end

    defp do_test_updates_allowed_methods(ref) do
      policy = %Policy{allowed_methods: ["GET"]}
      assert :ok = PolicyStore.put(ref, policy)

      assert :ok = PolicyStore.update_field(ref, "allowed_methods", ~s(["GET", "POST", "PUT"]))

      assert {:ok, retrieved} = PolicyStore.get(ref)
      assert retrieved.allowed_methods == ["GET", "POST", "PUT"]
    end

    @tag :requires_arca
    test "updates rate_limit", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_updates_rate_limit(ref)
    end

    defp do_test_updates_rate_limit(ref) do
      policy = %Policy{rate_limit: nil}
      assert :ok = PolicyStore.put(ref, policy)

      assert :ok = PolicyStore.update_field(ref, "rate_limit", ~s({"requests": 50, "window": "5m"}))

      assert {:ok, retrieved} = PolicyStore.get(ref)
      assert retrieved.rate_limit == %{requests: 50, window: "5m"}
    end

    @tag :requires_arca
    test "updates timeout", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_updates_timeout(ref)
    end

    defp do_test_updates_timeout(ref) do
      policy = %Policy{timeout: "30s"}
      assert :ok = PolicyStore.put(ref, policy)

      assert :ok = PolicyStore.update_field(ref, "timeout", "60s")

      assert {:ok, retrieved} = PolicyStore.get(ref)
      assert retrieved.timeout == "60s"
    end

    @tag :requires_arca
    test "creates policy if it doesn't exist", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_creates_policy_if_not_exists()
    end

    defp do_test_creates_policy_if_not_exists do
      new_ref = "catalyst:local.brand-new-component-#{:rand.uniform(100_000)}:1.0.0"

      on_exit(fn -> PolicyStore.delete(new_ref) end)

      assert :ok = PolicyStore.update_field(new_ref, "allowed_domains", ~s(["created.com"]))

      assert {:ok, retrieved} = PolicyStore.get(new_ref)
      assert retrieved.allowed_domains == ["created.com"]
    end
  end

  describe "Policy struct integration" do
    @tag :requires_arca
    test "preserves all Policy fields through round-trip", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_preserves_all_policy_fields(ref)
    end

    defp do_test_preserves_all_policy_fields(ref) do
      policy = %Policy{
        allowed_domains: ["domain1.com", "domain2.com"],
        allowed_methods: ["GET", "POST", "DELETE"],
        rate_limit: %{requests: 200, window: "10m"},
        timeout: "45s",
        max_memory_bytes: 128 * 1024 * 1024,
        max_request_size: 2_097_152,
        max_response_size: 10_485_760,
        allowed_tools: ["component.*", "storage.read"],
        allowed_storage_paths: ["agent/", "artifacts/"]
      }

      assert :ok = PolicyStore.put(ref, policy)
      assert {:ok, retrieved} = PolicyStore.get(ref)

      assert retrieved.allowed_domains == policy.allowed_domains
      assert retrieved.allowed_methods == policy.allowed_methods
      assert retrieved.rate_limit == policy.rate_limit
      assert retrieved.timeout == policy.timeout
      assert retrieved.max_memory_bytes == policy.max_memory_bytes
      assert retrieved.max_request_size == policy.max_request_size
      assert retrieved.max_response_size == policy.max_response_size
      assert retrieved.allowed_tools == policy.allowed_tools
      assert retrieved.allowed_storage_paths == policy.allowed_storage_paths
    end
  end

  describe "allowed_tools and allowed_storage_paths persistence" do
    @tag :requires_arca
    test "round-trips allowed_tools through storage", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_allowed_tools_roundtrip(ref)
    end

    defp do_test_allowed_tools_roundtrip(ref) do
      policy = %Policy{
        allowed_tools: ["component.search", "storage.*"],
        allowed_storage_paths: ["agent/"]
      }

      assert :ok = PolicyStore.put(ref, policy)
      assert {:ok, retrieved} = PolicyStore.get(ref)

      assert retrieved.allowed_tools == ["component.search", "storage.*"]
      assert retrieved.allowed_storage_paths == ["agent/"]
    end

    @tag :requires_arca
    test "defaults to empty lists when not set", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_defaults_empty_lists()
    end

    defp do_test_defaults_empty_lists do
      new_ref = "catalyst:local.no-tools-component-#{:rand.uniform(100_000)}:1.0.0"
      on_exit(fn -> PolicyStore.delete(new_ref) end)

      policy = %Policy{allowed_domains: ["example.com"]}
      assert :ok = PolicyStore.put(new_ref, policy)
      assert {:ok, retrieved} = PolicyStore.get(new_ref)

      assert retrieved.allowed_tools == []
      assert retrieved.allowed_storage_paths == []
    end

    @tag :requires_arca
    test "update_field for allowed_tools", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_update_field_allowed_tools(ref)
    end

    defp do_test_update_field_allowed_tools(ref) do
      policy = %Policy{allowed_tools: []}
      assert :ok = PolicyStore.put(ref, policy)

      assert :ok = PolicyStore.update_field(ref, "allowed_tools", ~s(["component.*", "storage.read"]))

      assert {:ok, retrieved} = PolicyStore.get(ref)
      assert retrieved.allowed_tools == ["component.*", "storage.read"]
    end

    @tag :requires_arca
    test "update_field for allowed_storage_paths", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_update_field_allowed_storage_paths(ref)
    end

    defp do_test_update_field_allowed_storage_paths(ref) do
      policy = %Policy{allowed_storage_paths: []}
      assert :ok = PolicyStore.put(ref, policy)

      assert :ok = PolicyStore.update_field(ref, "allowed_storage_paths", ~s(["agent/", "builds/"]))

      assert {:ok, retrieved} = PolicyStore.get(ref)
      assert retrieved.allowed_storage_paths == ["agent/", "builds/"]
    end
  end
end
