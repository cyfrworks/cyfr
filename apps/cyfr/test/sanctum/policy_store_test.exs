defmodule Sanctum.PolicyStoreTest do
  use ExUnit.Case, async: false

  alias Sanctum.{Policy, PolicyStore}
  import Sanctum.Test.ComponentHelpers

  # Database-dependent tests are tagged with @tag :requires_arca
  # They check arca_available?() at runtime and skip gracefully if DB is not available.
  # To explicitly exclude these tests: EXCLUDE_ARCA_TESTS=1 mix test

  setup do
    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Ensure Arca.Cache is initialized
    Arca.Cache.init()

    # Use a unique component ref for each test to avoid conflicts
    rand_id = :rand.uniform(100_000)
    component_name = "test-component-#{rand_id}"
    component_ref = "catalyst:local.#{component_name}:1.0.0"

    # Check if Arca is available for this test run
    arca_ok = arca_available?()

    # Register a test component with a manifest that has setup.policy
    if arca_ok do
      register_test_component(component_name, "1.0.0", "catalyst", %{
        "setup" => %{
          "policy" => %{
            "allowed_domains" => ["example.com"],
            "allowed_methods" => ["GET"],
            "allowed_paths" => ["data/"],
            "allowed_actions" => ["read"],
            "allowed_private_ips" => [],
            "allowed_tools" => [],
            "batch_timeout" => "5m",
            "max_concurrent_tasks" => 10
          }
        }
      })
    end

    {:ok, component_ref: component_ref, component_name: component_name, arca_available: arca_ok}
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
      ctx = Sanctum.Context.local()

      policy = %Policy{
        allowed_domains: ["api.stripe.com"],
        allowed_methods: ["GET", "POST"],
        rate_limit: %{requests: 100, window: "1m"},
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024
      }

      assert :ok = PolicyStore.put(ctx, ref, policy)
      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)

      assert retrieved.allowed_domains == ["api.stripe.com"]
      assert retrieved.allowed_methods == ["GET", "POST"]
      assert retrieved.rate_limit == %{requests: 100, window: "1m"}
    end

    @tag :requires_arca
    test "stores and retrieves a policy map", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_stores_and_retrieves_policy_map(ref)
    end

    defp do_test_stores_and_retrieves_policy_map(ref) do
      ctx = Sanctum.Context.local()

      policy_map = %{
        allowed_domains: ["httpbin.org"],
        allowed_methods: ["GET"],
        rate_limit: %{requests: 50, window: "5m"},
        timeout: "60s"
      }

      assert :ok = PolicyStore.put(ctx, ref, policy_map)
      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)

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
      ctx = Sanctum.Context.local()

      policy1 = %Policy{allowed_domains: ["first.com"]}
      policy2 = %Policy{allowed_domains: ["second.com"]}

      assert :ok = PolicyStore.put(ctx, ref, policy1)
      assert {:ok, retrieved1} = PolicyStore.get(ctx, ref)
      assert retrieved1.allowed_domains == ["first.com"]

      assert :ok = PolicyStore.put(ctx, ref, policy2)
      assert {:ok, retrieved2} = PolicyStore.get(ctx, ref)
      assert retrieved2.allowed_domains == ["second.com"]
    end
  end

  describe "get/1" do
    test "returns error for non-existent policy" do
      ctx = Sanctum.Context.local()

      assert {:error, :not_found} =
               PolicyStore.get(ctx, "catalyst:local.nonexistent-component-xyz:1.0.0")
    end

    @tag :requires_arca
    test "subsequent reads return same data", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_subsequent_reads(ref)
    end

    defp do_test_subsequent_reads(ref) do
      ctx = Sanctum.Context.local()

      policy = %Policy{allowed_domains: ["cached.com"]}
      assert :ok = PolicyStore.put(ctx, ref, policy)

      # Both reads should return the same data (caching is handled by Arca.Cache)
      assert {:ok, _} = PolicyStore.get(ctx, ref)
      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)
      assert retrieved.allowed_domains == ["cached.com"]
    end
  end

  describe "delete/1" do
    @tag :requires_arca
    test "removes a policy", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_removes_policy(ref)
    end

    defp do_test_removes_policy(ref) do
      ctx = Sanctum.Context.local()

      policy = %Policy{allowed_domains: ["delete-me.com"]}

      assert :ok = PolicyStore.put(ctx, ref, policy)
      assert {:ok, _} = PolicyStore.get(ctx, ref)

      assert :ok = PolicyStore.delete(ctx, ref)
      assert {:error, :not_found} = PolicyStore.get(ctx, ref)
    end

    test "succeeds for non-existent policy" do
      ctx = Sanctum.Context.local()
      assert :ok = PolicyStore.delete(ctx, "catalyst:local.never-existed-component:1.0.0")
    end
  end

  describe "list/0" do
    test "returns ok tuple" do
      ctx = Sanctum.Context.local()
      assert {:ok, _} = PolicyStore.list(ctx)
    end

    @tag :requires_arca
    test "returns all stored policies", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_returns_all_stored_policies(ref)
    end

    defp do_test_returns_all_stored_policies(ref) do
      ctx = Sanctum.Context.local()

      policy = %Policy{allowed_domains: ["list-test.com"]}
      assert :ok = PolicyStore.put(ctx, ref, policy)

      # Refs are normalized to canonical format (namespace.name:version)
      {:ok, canonical_ref} = Sanctum.ComponentRef.normalize(ref)

      assert {:ok, policies} = PolicyStore.list(ctx)
      assert Enum.any?(policies, fn p -> p.component_ref == canonical_ref end)
    end
  end

  describe "update_field/3" do
    @tag :requires_arca
    test "updates allowed_domains", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_updates_allowed_domains(ref)
    end

    defp do_test_updates_allowed_domains(ref) do
      ctx = Sanctum.Context.local()

      # First create a base policy
      policy = %Policy{allowed_domains: ["original.com"]}
      assert :ok = PolicyStore.put(ctx, ref, policy)

      # Update allowed_domains
      assert :ok =
               PolicyStore.update_field(ctx, ref, "allowed_domains", ~s(["new.com", "other.com"]))

      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)
      assert retrieved.allowed_domains == ["new.com", "other.com"]
    end

    @tag :requires_arca
    test "updates allowed_methods", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_updates_allowed_methods(ref)
    end

    defp do_test_updates_allowed_methods(ref) do
      ctx = Sanctum.Context.local()

      policy = %Policy{allowed_methods: ["GET"]}
      assert :ok = PolicyStore.put(ctx, ref, policy)

      assert :ok =
               PolicyStore.update_field(ctx, ref, "allowed_methods", ~s(["GET", "POST", "PUT"]))

      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)
      assert retrieved.allowed_methods == ["GET", "POST", "PUT"]
    end

    @tag :requires_arca
    test "updates rate_limit", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_updates_rate_limit(ref)
    end

    defp do_test_updates_rate_limit(ref) do
      ctx = Sanctum.Context.local()

      policy = %Policy{rate_limit: nil}
      assert :ok = PolicyStore.put(ctx, ref, policy)

      assert :ok =
               PolicyStore.update_field(
                 ctx,
                 ref,
                 "rate_limit",
                 ~s({"requests": 50, "window": "5m"})
               )

      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)
      assert retrieved.rate_limit == %{requests: 50, window: "5m"}
    end

    @tag :requires_arca
    test "updates timeout", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_updates_timeout(ref)
    end

    defp do_test_updates_timeout(ref) do
      ctx = Sanctum.Context.local()

      policy = %Policy{timeout: "30s"}
      assert :ok = PolicyStore.put(ctx, ref, policy)

      assert :ok = PolicyStore.update_field(ctx, ref, "timeout", "60s")

      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)
      assert retrieved.timeout == "60s"
    end

    @tag :requires_arca
    test "creates policy if it doesn't exist", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_creates_policy_if_not_exists()
    end

    defp do_test_creates_policy_if_not_exists do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "brand-new-component-#{rand_id}"
      new_ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{"policy" => %{"allowed_domains" => []}}
      })

      assert :ok = PolicyStore.update_field(ctx, new_ref, "allowed_domains", ~s(["created.com"]))

      assert {:ok, retrieved} = PolicyStore.get(ctx, new_ref)
      assert retrieved.allowed_domains == ["created.com"]
    end
  end

  describe "put/2 restricted tools validation" do
    @tag :requires_arca
    test "rejects formula policy with restricted tools", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_rejects_restricted_tools()
    end

    defp do_test_rejects_restricted_tools do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "restricted-test-#{rand_id}"
      ref = "formula:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "formula", %{
        "setup" => %{"policy" => %{"allowed_tools" => []}}
      })

      policy_map = %{
        component_type: "formula",
        allowed_tools: ["execution.run", "session.login"],
        timeout: "30s"
      }

      assert {:error, message} = PolicyStore.put(ctx, ref, policy_map)
      assert message =~ "restricted"
      assert message =~ "session.login"
    end

    @tag :requires_arca
    test "accepts formula policy with safe tools", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_accepts_safe_tools()
    end

    defp do_test_accepts_safe_tools do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "safe-test-#{rand_id}"
      ref = "formula:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "formula", %{
        "setup" => %{"policy" => %{"allowed_tools" => []}}
      })

      policy_map = %{
        component_type: "formula",
        allowed_tools: ["execution.run", "component.search", "guide.get"],
        timeout: "30s"
      }

      assert :ok = PolicyStore.put(ctx, ref, policy_map)
    end

    @tag :requires_arca
    test "accepts formula policy with '*' wildcard", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_accepts_star_wildcard()
    end

    defp do_test_accepts_star_wildcard do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "star-test-#{rand_id}"
      ref = "formula:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "formula", %{
        "setup" => %{"policy" => %{"allowed_tools" => []}}
      })

      policy_map = %{
        component_type: "formula",
        allowed_tools: ["*"],
        timeout: "30s"
      }

      assert :ok = PolicyStore.put(ctx, ref, policy_map)
    end

    @tag :requires_arca
    test "does not restrict catalyst policies", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_no_restrict_catalyst()
    end

    defp do_test_no_restrict_catalyst do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "unrestricted-test-#{rand_id}"
      ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{"policy" => %{"allowed_tools" => []}}
      })

      policy_map = %{
        component_type: "catalyst",
        allowed_tools: ["session.login", "policy.set"],
        timeout: "30s"
      }

      assert :ok = PolicyStore.put(ctx, ref, policy_map)
    end
  end

  describe "encode_json_field error propagation" do
    @tag :requires_arca
    test "put/3 returns error when policy field contains non-encodable data", %{
      component_ref: ref,
      arca_available: arca
    } do
      if not arca, do: :ok, else: do_test_encode_error_propagation(ref)
    end

    defp do_test_encode_error_propagation(ref) do
      ctx = Sanctum.Context.local()

      # A self-referencing term cannot be JSON-encoded.
      # Use a PID which Jason cannot encode.
      policy_map = %{
        component_type: "catalyst",
        allowed_domains: [self()],
        timeout: "30s"
      }

      assert {:error, {:encode_failed, :allowed_domains, _reason}} =
               PolicyStore.put(ctx, ref, policy_map)
    end
  end

  describe "Policy struct integration" do
    @tag :requires_arca
    test "preserves all Policy fields through round-trip", %{
      component_ref: ref,
      arca_available: arca
    } do
      if not arca, do: :ok, else: do_test_preserves_all_policy_fields(ref)
    end

    defp do_test_preserves_all_policy_fields(ref) do
      ctx = Sanctum.Context.local()

      policy = %Policy{
        allowed_domains: ["domain1.com", "domain2.com"],
        allowed_methods: ["GET", "POST", "DELETE"],
        rate_limit: %{requests: 200, window: "10m"},
        timeout: "45s",
        max_memory_bytes: 128 * 1024 * 1024,
        max_request_size: 2_097_152,
        max_response_size: 10_485_760,
        allowed_tools: ["component.*", "storage.read"],
        allowed_paths: ["agent/", "artifacts/"]
      }

      assert :ok = PolicyStore.put(ctx, ref, policy)
      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)

      assert retrieved.allowed_domains == policy.allowed_domains
      assert retrieved.allowed_methods == policy.allowed_methods
      assert retrieved.rate_limit == policy.rate_limit
      assert retrieved.timeout == policy.timeout
      assert retrieved.max_memory_bytes == policy.max_memory_bytes
      assert retrieved.max_request_size == policy.max_request_size
      assert retrieved.max_response_size == policy.max_response_size
      assert retrieved.allowed_tools == policy.allowed_tools
      assert retrieved.allowed_paths == policy.allowed_paths
    end
  end

  describe "allowed_tools and allowed_paths persistence" do
    @tag :requires_arca
    test "round-trips allowed_tools through storage", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_allowed_tools_roundtrip(ref)
    end

    defp do_test_allowed_tools_roundtrip(ref) do
      ctx = Sanctum.Context.local()

      policy = %Policy{
        allowed_tools: ["component.search", "storage.*"],
        allowed_paths: ["agent/"]
      }

      assert :ok = PolicyStore.put(ctx, ref, policy)
      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)

      assert retrieved.allowed_tools == ["component.search", "storage.*"]
      assert retrieved.allowed_paths == ["agent/"]
    end

    @tag :requires_arca
    test "defaults to empty lists when not set", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_defaults_empty_lists()
    end

    defp do_test_defaults_empty_lists do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "no-tools-component-#{rand_id}"
      new_ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{"policy" => %{"allowed_domains" => []}}
      })

      policy = %Policy{allowed_domains: ["example.com"]}
      assert :ok = PolicyStore.put(ctx, new_ref, policy)
      assert {:ok, retrieved} = PolicyStore.get(ctx, new_ref)

      assert retrieved.allowed_tools == []
      assert retrieved.allowed_paths == []
    end

    @tag :requires_arca
    test "update_field for allowed_tools", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_update_field_allowed_tools(ref)
    end

    defp do_test_update_field_allowed_tools(ref) do
      ctx = Sanctum.Context.local()

      policy = %Policy{allowed_tools: []}
      assert :ok = PolicyStore.put(ctx, ref, policy)

      assert :ok =
               PolicyStore.update_field(
                 ctx,
                 ref,
                 "allowed_tools",
                 ~s(["component.*", "storage.read"])
               )

      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)
      assert retrieved.allowed_tools == ["component.*", "storage.read"]
    end

    @tag :requires_arca
    test "update_field for allowed_paths", %{component_ref: ref, arca_available: arca} do
      if not arca, do: :ok, else: do_test_update_field_allowed_paths(ref)
    end

    defp do_test_update_field_allowed_paths(ref) do
      ctx = Sanctum.Context.local()

      policy = %Policy{allowed_paths: []}
      assert :ok = PolicyStore.put(ctx, ref, policy)

      assert :ok = PolicyStore.update_field(ctx, ref, "allowed_paths", ~s(["agent/", "builds/"]))

      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)
      assert retrieved.allowed_paths == ["agent/", "builds/"]
    end
  end

  describe "manifest-driven field validation" do
    @tag :requires_arca
    test "put/2 rejects allowed_domains when manifest only has storage keys", %{
      arca_available: arca
    } do
      if not arca, do: :ok, else: do_test_rejects_http_fields_for_storage_component()
    end

    defp do_test_rejects_http_fields_for_storage_component do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "storage-only-#{rand_id}"
      ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{
          "policy" => %{
            "allowed_paths" => ["data/"],
            "allowed_actions" => ["read", "write"]
          }
        }
      })

      policy_map = %{
        component_type: "catalyst",
        allowed_domains: ["evil.com"],
        timeout: "30s"
      }

      assert {:error, msg} = PolicyStore.put(ctx, ref, policy_map)
      assert msg =~ "allowed_domains"
      assert msg =~ "not configurable"
    end

    @tag :requires_arca
    test "update_field/3 rejects non-applicable field", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_update_field_rejects_non_applicable()
    end

    defp do_test_update_field_rejects_non_applicable do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "http-only-#{rand_id}"
      ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{
          "policy" => %{
            "allowed_domains" => ["api.example.com"],
            "allowed_methods" => ["GET"]
          }
        }
      })

      assert {:error, msg} = PolicyStore.update_field(ctx, ref, "allowed_paths", ~s(["secret/"]))
      assert msg =~ "allowed_paths"
      assert msg =~ "not configurable"
    end

    @tag :requires_arca
    test "put/2 fails when component is not registered", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_fails_when_not_registered()
    end

    defp do_test_fails_when_not_registered do
      ctx = Sanctum.Context.local()

      ref = "catalyst:local.nonexistent-component-#{:rand.uniform(100_000)}:1.0.0"

      policy_map = %{
        component_type: "catalyst",
        allowed_domains: ["example.com"],
        timeout: "30s"
      }

      assert {:error, msg} = PolicyStore.put(ctx, ref, policy_map)
      assert msg =~ "not found" or msg =~ "not declare setup.policy"
    end

    @tag :requires_arca
    test "put/2 accepts universal fields regardless of setup.policy", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_accepts_universal_fields()
    end

    defp do_test_accepts_universal_fields do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "minimal-#{rand_id}"
      ref = "catalyst:local.#{name}:1.0.0"

      # Manifest with minimal setup.policy (only one capability field)
      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{
          "policy" => %{
            "allowed_domains" => []
          }
        }
      })

      # Universal fields should always be accepted
      policy_map = %{
        component_type: "catalyst",
        timeout: "60s",
        max_memory_bytes: 128_000_000,
        rate_limit: %{requests: 100, window: "1m"}
      }

      assert :ok = PolicyStore.put(ctx, ref, policy_map)
    end

    @tag :requires_arca
    test "put/2 fails when manifest has no setup.policy section", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_fails_without_setup_policy()
    end

    defp do_test_fails_without_setup_policy do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "no-policy-#{rand_id}"
      ref = "catalyst:local.#{name}:1.0.0"

      # Register with a manifest that has setup but no policy key
      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{
          "secrets" => [%{"name" => "API_KEY"}]
        }
      })

      policy_map = %{component_type: "catalyst", timeout: "30s"}
      assert {:error, msg} = PolicyStore.put(ctx, ref, policy_map)
      assert msg =~ "setup.policy"
    end

    @tag :requires_arca
    test "put/2 with Policy struct passes when fields match manifest", %{
      component_ref: ref,
      arca_available: arca
    } do
      if not arca, do: :ok, else: do_test_struct_passes(ref)
    end

    defp do_test_struct_passes(ref) do
      ctx = Sanctum.Context.local()

      # The default setup component has all capability fields declared.
      # A Policy struct with non-default values in declared fields should pass.
      policy = %Policy{
        allowed_domains: ["api.example.com"],
        allowed_methods: ["GET", "POST"],
        allowed_paths: ["data/"],
        timeout: "45s"
      }

      assert :ok = PolicyStore.put(ctx, ref, policy)
    end

    @tag :requires_arca
    test "put/2 with Policy struct fails when non-default field not in manifest", %{
      arca_available: arca
    } do
      if not arca, do: :ok, else: do_test_struct_rejects_non_applicable()
    end

    defp do_test_struct_rejects_non_applicable do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "http-struct-#{rand_id}"
      ref = "catalyst:local.#{name}:1.0.0"

      # Only HTTP fields declared
      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{
          "policy" => %{
            "allowed_domains" => [],
            "allowed_methods" => []
          }
        }
      })

      # Policy struct with non-default allowed_paths (storage field not declared)
      policy = %Policy{
        allowed_domains: ["api.example.com"],
        allowed_paths: ["secret/data/"]
      }

      assert {:error, msg} = PolicyStore.put(ctx, ref, policy)
      assert msg =~ "allowed_paths"
    end

    @tag :requires_arca
    test "update_field/3 accepts universal field for any component", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_update_universal_field()
    end

    defp do_test_update_universal_field do
      ctx = Sanctum.Context.local()

      rand_id = :rand.uniform(100_000)
      name = "universal-update-#{rand_id}"
      ref = "catalyst:local.#{name}:1.0.0"

      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{"policy" => %{"allowed_domains" => []}}
      })

      # timeout is universal, should pass even with minimal setup.policy
      assert :ok = PolicyStore.update_field(ctx, ref, "timeout", "120s")
      assert {:ok, retrieved} = PolicyStore.get(ctx, ref)
      assert retrieved.timeout == "120s"
    end

    @tag :requires_arca
    test "put_type_default/2 does NOT require manifest validation", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_type_default_no_manifest()
    end

    defp do_test_type_default_no_manifest do
      ctx = Sanctum.Context.local()

      # Type defaults are global — no specific component, so no manifest.
      # This should work without any registered component.
      policy_map = %{
        allowed_domains: ["*.example.com"],
        timeout: "45s"
      }

      assert :ok = PolicyStore.put_type_default(ctx, :catalyst, policy_map)

      # Cleanup
      PolicyStore.delete_type_default(ctx, :catalyst)
    end
  end

  describe "put/3 ceiling validation" do
    @tag :requires_arca
    test "rejects policy exceeding platform ceiling", %{
      component_ref: ref,
      arca_available: arca
    } do
      if not arca, do: :ok, else: do_test_rejects_exceeding_ceiling(ref)
    end

    defp do_test_rejects_exceeding_ceiling(ref) do
      ctx = Sanctum.Context.local()

      policy_map = %{
        timeout: "999h",
        max_memory_bytes: 999_999_999_999
      }

      assert {:error, msg} = PolicyStore.put(ctx, ref, policy_map)
      assert msg =~ "exceeds"
    end

    @tag :requires_arca
    test "accepts policy within platform ceiling", %{
      component_ref: ref,
      arca_available: arca
    } do
      if not arca, do: :ok, else: do_test_accepts_within_ceiling(ref)
    end

    defp do_test_accepts_within_ceiling(ref) do
      ctx = Sanctum.Context.local()

      policy_map = %{
        timeout: "5m",
        max_memory_bytes: 64 * 1024 * 1024
      }

      assert :ok = PolicyStore.put(ctx, ref, policy_map)
    end

    @tag :requires_arca
    test "put_type_default rejects policy exceeding ceiling", %{arca_available: arca} do
      if not arca, do: :ok, else: do_test_type_default_exceeding_ceiling()
    end

    defp do_test_type_default_exceeding_ceiling do
      ctx = Sanctum.Context.local()

      policy_map = %{timeout: "999h"}

      assert {:error, msg} = PolicyStore.put_type_default(ctx, :reagent, policy_map)
      assert msg =~ "exceeds"
    end
  end

  describe "name-level policy validation against latest manifest" do
    @tag :requires_arca
    test "name-level policies get field validation against latest version", %{
      arca_available: arca
    } do
      if not arca, do: :ok, else: do_test_name_level_field_validation()
    end

    defp do_test_name_level_field_validation do
      ctx = Sanctum.Context.local()
      rand_id = :rand.uniform(100_000)
      name = "name-level-val-#{rand_id}"
      name_ref = "catalyst:local.#{name}"

      # Register component with limited manifest (only allowed_domains)
      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{"policy" => %{"allowed_domains" => []}}
      })

      # Setting allowed_domains should work (declared in manifest)
      assert :ok = PolicyStore.put(ctx, name_ref, %{allowed_domains: ["example.com"]})

      # Setting allowed_paths should fail (not declared in manifest)
      assert {:error, msg} = PolicyStore.put(ctx, name_ref, %{allowed_paths: ["data/"]})
      assert msg =~ "allowed_paths"
    end

    @tag :requires_arca
    test "name-level policy validates against latest version when multiple exist", %{
      arca_available: arca
    } do
      if not arca, do: :ok, else: do_test_name_level_validates_against_latest()
    end

    defp do_test_name_level_validates_against_latest do
      ctx = Sanctum.Context.local()
      rand_id = :rand.uniform(100_000)
      name = "multi-ver-val-#{rand_id}"
      name_ref = "catalyst:local.#{name}"

      # Register v1 with only allowed_domains
      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{"policy" => %{"allowed_domains" => []}}
      })

      # Register v2 with allowed_domains + allowed_paths
      register_test_component(name, "2.0.0", "catalyst", %{
        "setup" => %{
          "policy" => %{"allowed_domains" => [], "allowed_paths" => []}
        }
      })

      # Now name-level validates against v2 (latest), so allowed_paths should work
      assert :ok =
               PolicyStore.put(ctx, name_ref, %{
                 allowed_domains: ["example.com"],
                 allowed_paths: ["data/"]
               })
    end
  end
end
