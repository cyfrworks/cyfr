defmodule Sanctum.Policy.FieldSchemaTest do
  use ExUnit.Case, async: true

  alias Sanctum.Policy.FieldSchema

  describe "configurable_fields/1" do
    test "returns error when setup_policy is nil" do
      assert {:error, msg} = FieldSchema.configurable_fields(nil)
      assert msg =~ "setup.policy is required"
    end

    test "returns only universal fields for empty setup_policy" do
      assert {:ok, fields} = FieldSchema.configurable_fields(%{})
      assert fields == FieldSchema.universal_fields()
    end

    test "includes HTTP capability fields when declared in setup_policy" do
      setup_policy = %{
        "allowed_domains" => ["api.example.com"],
        "allowed_methods" => ["GET", "POST"]
      }

      assert {:ok, fields} = FieldSchema.configurable_fields(setup_policy)
      assert "allowed_domains" in fields
      assert "allowed_methods" in fields
      assert "timeout" in fields
      refute "allowed_paths" in fields
      refute "allowed_actions" in fields
      refute "allowed_tools" in fields
    end

    test "includes storage capability fields when declared in setup_policy" do
      setup_policy = %{
        "allowed_paths" => ["data/"],
        "allowed_actions" => ["read", "write"]
      }

      assert {:ok, fields} = FieldSchema.configurable_fields(setup_policy)
      assert "allowed_paths" in fields
      assert "allowed_actions" in fields
      assert "timeout" in fields
      refute "allowed_domains" in fields
      refute "allowed_methods" in fields
    end

    test "includes formula fields when declared in setup_policy" do
      setup_policy = %{
        "allowed_tools" => ["component.*"],
        "batch_timeout" => "10m",
        "max_concurrent_tasks" => 5
      }

      assert {:ok, fields} = FieldSchema.configurable_fields(setup_policy)
      assert "allowed_tools" in fields
      assert "batch_timeout" in fields
      assert "max_concurrent_tasks" in fields
      refute "allowed_domains" in fields
    end

    test "universal fields are always included regardless of setup_policy" do
      setup_policy = %{"allowed_domains" => []}

      assert {:ok, fields} = FieldSchema.configurable_fields(setup_policy)

      for uf <- FieldSchema.universal_fields() do
        assert uf in fields, "Expected universal field '#{uf}' to be included"
      end
    end
  end

  describe "validate_fields/2" do
    test "returns error when setup_policy is nil" do
      assert {:error, msg} = FieldSchema.validate_fields(%{allowed_domains: []}, nil)
      assert msg =~ "setup.policy is required"
    end

    test "accepts universal fields regardless of setup_policy" do
      setup_policy = %{}
      policy_map = %{timeout: "60s", max_memory_bytes: 128_000_000}
      assert :ok = FieldSchema.validate_fields(policy_map, setup_policy)
    end

    test "rejects allowed_domains when setup_policy only has storage keys" do
      setup_policy = %{
        "allowed_paths" => ["data/"],
        "allowed_actions" => ["read"]
      }

      policy_map = %{allowed_domains: ["evil.com"], timeout: "30s"}
      assert {:error, msg} = FieldSchema.validate_fields(policy_map, setup_policy)
      assert msg =~ "allowed_domains"
      assert msg =~ "not configurable"
    end

    test "rejects allowed_paths when setup_policy only has HTTP keys" do
      setup_policy = %{
        "allowed_domains" => ["api.example.com"],
        "allowed_methods" => ["GET"]
      }

      policy_map = %{allowed_paths: ["/secret"], timeout: "30s"}
      assert {:error, msg} = FieldSchema.validate_fields(policy_map, setup_policy)
      assert msg =~ "allowed_paths"
      assert msg =~ "not configurable"
    end

    test "accepts matching capability fields" do
      setup_policy = %{
        "allowed_domains" => ["api.example.com"],
        "allowed_methods" => ["GET"]
      }

      policy_map = %{allowed_domains: ["api.example.com"], allowed_methods: ["GET"]}
      assert :ok = FieldSchema.validate_fields(policy_map, setup_policy)
    end

    test "reports multiple invalid fields" do
      setup_policy = %{}
      policy_map = %{allowed_domains: ["x.com"], allowed_paths: ["/data"], allowed_tools: ["t"]}
      assert {:error, msg} = FieldSchema.validate_fields(policy_map, setup_policy)
      assert msg =~ "allowed_domains"
      assert msg =~ "allowed_paths"
      assert msg =~ "allowed_tools"
    end

    test "ignores empty capability fields not in setup_policy" do
      setup_policy = %{"allowed_domains" => []}
      # Empty lists for non-declared fields should pass (they're defaults)
      policy_map = %{allowed_domains: ["x.com"], allowed_paths: [], allowed_tools: []}
      assert :ok = FieldSchema.validate_fields(policy_map, setup_policy)
    end
  end

  describe "validate_field/2" do
    test "returns error when setup_policy is nil" do
      assert {:error, _} = FieldSchema.validate_field("allowed_domains", nil)
    end

    test "accepts universal fields" do
      assert :ok = FieldSchema.validate_field("timeout", %{})
      assert :ok = FieldSchema.validate_field("max_memory_bytes", %{})
      assert :ok = FieldSchema.validate_field("rate_limit", %{})
    end

    test "accepts declared capability field" do
      setup_policy = %{"allowed_domains" => []}
      assert :ok = FieldSchema.validate_field("allowed_domains", setup_policy)
    end

    test "rejects undeclared capability field" do
      setup_policy = %{"allowed_paths" => []}
      assert {:error, msg} = FieldSchema.validate_field("allowed_domains", setup_policy)
      assert msg =~ "allowed_domains"
      assert msg =~ "not configurable"
    end

    test "accepts unknown fields (future-proofing)" do
      assert :ok = FieldSchema.validate_field("some_future_field", %{})
    end
  end

  describe "default_configurable_fields/1" do
    test "catalyst returns universal + catalyst capability fields" do
      assert {:ok, fields} = FieldSchema.default_configurable_fields("catalyst")
      # Universal fields
      for uf <- FieldSchema.universal_fields() do
        assert uf in fields, "Expected universal field '#{uf}'"
      end

      # Catalyst capability fields
      assert "allowed_domains" in fields
      assert "allowed_methods" in fields
      assert "allowed_private_ips" in fields
      assert "allowed_paths" in fields
      assert "allowed_actions" in fields
      # Formula fields excluded
      refute "allowed_tools" in fields
      refute "batch_timeout" in fields
      refute "max_concurrent_tasks" in fields
    end

    test "formula returns universal + formula capability fields" do
      assert {:ok, fields} = FieldSchema.default_configurable_fields("formula")

      for uf <- FieldSchema.universal_fields() do
        assert uf in fields, "Expected universal field '#{uf}'"
      end

      assert "allowed_tools" in fields
      assert "batch_timeout" in fields
      assert "max_concurrent_tasks" in fields
      # Catalyst fields excluded
      refute "allowed_domains" in fields
      refute "allowed_methods" in fields
      refute "allowed_paths" in fields
    end

    test "reagent returns only universal fields" do
      assert {:ok, fields} = FieldSchema.default_configurable_fields("reagent")
      assert fields == FieldSchema.universal_fields()
    end

    test "accepts atom types" do
      assert {:ok, catalyst_fields} = FieldSchema.default_configurable_fields(:catalyst)
      assert "allowed_domains" in catalyst_fields

      assert {:ok, formula_fields} = FieldSchema.default_configurable_fields(:formula)
      assert "allowed_tools" in formula_fields

      assert {:ok, reagent_fields} = FieldSchema.default_configurable_fields(:reagent)
      assert reagent_fields == FieldSchema.universal_fields()
    end

    test "string and atom return the same results" do
      assert FieldSchema.default_configurable_fields("catalyst") ==
               FieldSchema.default_configurable_fields(:catalyst)

      assert FieldSchema.default_configurable_fields("formula") ==
               FieldSchema.default_configurable_fields(:formula)

      assert FieldSchema.default_configurable_fields("reagent") ==
               FieldSchema.default_configurable_fields(:reagent)
    end

    test "nil returns error" do
      assert {:error, _} = FieldSchema.default_configurable_fields(nil)
    end

    test "unknown type returns error" do
      assert {:error, _} = FieldSchema.default_configurable_fields("widget")
    end
  end

  describe "edge cases" do
    test "validate_fields with string keys in policy_map" do
      # MCP tool input often has string keys, not atoms
      setup_policy = %{"allowed_paths" => []}
      policy_map = %{"allowed_domains" => ["evil.com"], "timeout" => "30s"}
      assert {:error, msg} = FieldSchema.validate_fields(policy_map, setup_policy)
      assert msg =~ "allowed_domains"
    end

    test "validate_fields with string keys matching defaults passes" do
      # String key "batch_timeout" => "5m" should be treated as default
      setup_policy = %{"allowed_domains" => []}
      policy_map = %{"batch_timeout" => "5m", "max_concurrent_tasks" => 10}
      assert :ok = FieldSchema.validate_fields(policy_map, setup_policy)
    end

    test "validate_fields with string keys non-default values rejects" do
      setup_policy = %{"allowed_domains" => []}
      policy_map = %{"batch_timeout" => "10m"}
      assert {:error, msg} = FieldSchema.validate_fields(policy_map, setup_policy)
      assert msg =~ "batch_timeout"
    end

    test "configurable_fields with atom keys in setup_policy" do
      # Manifests decoded from JSON have string keys, but handle atoms too
      setup_policy = %{allowed_domains: [], allowed_methods: []}
      assert {:ok, fields} = FieldSchema.configurable_fields(setup_policy)
      assert "allowed_domains" in fields
      assert "allowed_methods" in fields
    end

    test "validate_field with atom field name" do
      setup_policy = %{"allowed_domains" => []}
      assert :ok = FieldSchema.validate_field(:allowed_domains, setup_policy)
    end

    test "validate_field rejects atom field name not in setup_policy" do
      setup_policy = %{"allowed_paths" => []}
      assert {:error, _} = FieldSchema.validate_field(:allowed_domains, setup_policy)
    end

    test "validate_fields with empty setup_policy rejects all non-default capability fields" do
      setup_policy = %{}
      policy_map = %{allowed_domains: ["x.com"]}
      assert {:error, _} = FieldSchema.validate_fields(policy_map, setup_policy)
    end

    test "validate_fields with empty setup_policy allows only universal fields" do
      setup_policy = %{}

      policy_map = %{
        timeout: "60s",
        max_memory_bytes: 256_000_000,
        rate_limit: %{requests: 10, window: "1m"}
      }

      assert :ok = FieldSchema.validate_fields(policy_map, setup_policy)
    end

    test "setup_policy with extra unknown keys doesn't affect validation" do
      setup_policy = %{"allowed_domains" => [], "custom_setting" => true, "notes" => "test"}
      assert {:ok, fields} = FieldSchema.configurable_fields(setup_policy)
      # Only recognized capability fields are included
      assert "allowed_domains" in fields
      refute "custom_setting" in fields
      refute "notes" in fields
    end

    test "component_type key in policy_map is not treated as capability field" do
      setup_policy = %{"allowed_domains" => []}
      policy_map = %{component_type: "catalyst", allowed_domains: ["x.com"]}
      assert :ok = FieldSchema.validate_fields(policy_map, setup_policy)
    end

    test "validate_fields with nil values for capability fields passes" do
      setup_policy = %{"allowed_domains" => []}
      policy_map = %{allowed_paths: nil, allowed_tools: nil}
      assert :ok = FieldSchema.validate_fields(policy_map, setup_policy)
    end

    test "validate_fields with non-list truthy value for undeclared field rejects" do
      # e.g. someone passes allowed_domains: "example.com" (string not list)
      setup_policy = %{"allowed_paths" => []}
      policy_map = %{allowed_domains: "example.com"}
      assert {:error, _} = FieldSchema.validate_fields(policy_map, setup_policy)
    end

    test "explicitly_set? treats 0 as non-default for most fields" do
      # max_concurrent_tasks default is 10, so 0 is explicitly set
      setup_policy = %{"allowed_domains" => []}
      policy_map = %{max_concurrent_tasks: 0}
      assert {:error, _} = FieldSchema.validate_fields(policy_map, setup_policy)
    end

    test "explicitly_set? treats batch_timeout non-default as set" do
      setup_policy = %{"allowed_domains" => []}
      policy_map = %{batch_timeout: "10m"}
      assert {:error, _} = FieldSchema.validate_fields(policy_map, setup_policy)
    end

    test "explicitly_set? treats batch_timeout default '5m' as not set" do
      setup_policy = %{"allowed_domains" => []}
      policy_map = %{batch_timeout: "5m"}
      assert :ok = FieldSchema.validate_fields(policy_map, setup_policy)
    end
  end
end
