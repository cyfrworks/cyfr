defmodule Sanctum.MCPTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.MCP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    # Use a test-specific base path to avoid polluting real config
    test_path = Path.join(System.tmp_dir!(), "sanctum_mcp_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)
      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Context.local(), test_path: test_path}
  end

  # ============================================================================
  # Tool Discovery
  # ============================================================================

  describe "tools/0" do
    test "returns 7 action-based tools" do
      tools = MCP.tools()
      assert length(tools) == 7

      tool_names = Enum.map(tools, & &1.name)
      assert "session" in tool_names
      assert "secret" in tool_names
      assert "permission" in tool_names
      assert "key" in tool_names
      assert "audit" in tool_names
      assert "policy" in tool_names
      assert "config" in tool_names
    end

    test "each tool has required schema fields" do
      for tool <- MCP.tools() do
        assert is_binary(tool.name)
        assert is_binary(tool.title)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
        assert tool.input_schema["type"] == "object"
        assert "action" in tool.input_schema["required"]
      end
    end
  end

  # ============================================================================
  # Resources
  # ============================================================================

  describe "resources/0" do
    test "returns identity and permissions resources" do
      resources = MCP.resources()
      assert length(resources) == 3

      uris = Enum.map(resources, & &1.uri)
      assert "sanctum://identity" in uris
      assert "sanctum://permissions" in uris
      assert "sanctum://permissions/{reference}" in uris
    end
  end

  describe "read/2" do
    test "reads identity resource", %{ctx: ctx} do
      {:ok, result} = MCP.read(ctx, "sanctum://identity")
      assert result.mimeType == "application/json"

      content = Jason.decode!(result.content)
      assert content["user_id"] == "local_user"
      assert content["scope"] == "personal"
    end

    test "reads permissions resource", %{ctx: ctx} do
      {:ok, result} = MCP.read(ctx, "sanctum://permissions")
      assert result.mimeType == "application/json"

      content = Jason.decode!(result.content)
      assert is_list(content["permissions"])
    end

    test "reads resource-specific permissions", %{ctx: ctx} do
      {:ok, result} = MCP.read(ctx, "sanctum://permissions/components/test-component:1.0")
      assert result.mimeType == "application/json"

      content = Jason.decode!(result.content)
      assert content["reference"] == "components/test-component:1.0"
      assert is_list(content["permissions"])
    end

    test "returns error for unknown resource", %{ctx: ctx} do
      {:error, msg} = MCP.read(ctx, "sanctum://unknown")
      assert msg =~ "Unknown resource"
    end
  end

  # ============================================================================
  # Session Tool
  # ============================================================================

  describe "session tool" do
    test "whoami returns current identity", %{ctx: ctx} do
      {:ok, result} = MCP.handle("session", ctx, %{"action" => "whoami"})
      assert result.user_id == "local_user"
      assert result.scope == :personal
      assert is_list(result.permissions)
    end

    test "whoami returns error when not authenticated" do
      ctx = %Context{authenticated: false, permissions: MapSet.new()}
      {:error, msg} = MCP.handle("session", ctx, %{"action" => "whoami"})
      assert msg =~ "Not authenticated"
    end

    test "login returns redirect info", %{ctx: ctx} do
      {:ok, result} = MCP.handle("session", ctx, %{"action" => "login"})
      assert result.redirect == "/auth/login"
    end

    test "logout succeeds", %{ctx: ctx} do
      {:ok, result} = MCP.handle("session", ctx, %{"action" => "logout"})
      assert result.message =~ "Logged out"
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("session", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid session action"
    end
  end

  # ============================================================================
  # Secret Tool
  # ============================================================================

  describe "secret tool" do
    test "list returns empty initially", %{ctx: ctx} do
      {:ok, result} = MCP.handle("secret", ctx, %{"action" => "list"})
      assert result.secrets == []
      assert result.count == 0
    end

    test "set and get a secret returns masked value", %{ctx: ctx} do
      {:ok, result} = MCP.handle("secret", ctx, %{
        "action" => "set",
        "name" => "API_KEY",
        "value" => "secret123"
      })
      assert result.stored == true
      assert result.name == "API_KEY"

      # Get returns masked value, not the actual secret
      {:ok, result} = MCP.handle("secret", ctx, %{"action" => "get", "name" => "API_KEY"})
      assert result.name == "API_KEY"
      assert result.value == "secr...****"  # First 4 chars + masked
      assert result.length == 9  # Length of "secret123"
    end

    test "get short secret returns fully masked value", %{ctx: ctx} do
      {:ok, _} = MCP.handle("secret", ctx, %{
        "action" => "set",
        "name" => "SHORT",
        "value" => "abc"
      })

      {:ok, result} = MCP.handle("secret", ctx, %{"action" => "get", "name" => "SHORT"})
      assert result.value == "****"  # Fully masked for short secrets
      assert result.length == 3
    end

    test "get missing secret returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("secret", ctx, %{"action" => "get", "name" => "MISSING"})
      assert msg =~ "not found"
    end

    test "delete a secret", %{ctx: ctx} do
      MCP.handle("secret", ctx, %{"action" => "set", "name" => "TO_DELETE", "value" => "val"})

      {:ok, result} = MCP.handle("secret", ctx, %{"action" => "delete", "name" => "TO_DELETE"})
      assert result.deleted == true

      {:error, _} = MCP.handle("secret", ctx, %{"action" => "get", "name" => "TO_DELETE"})
    end

    test "grant and revoke access", %{ctx: ctx} do
      MCP.handle("secret", ctx, %{"action" => "set", "name" => "GRANT_TEST", "value" => "val"})

      {:ok, result} = MCP.handle("secret", ctx, %{
        "action" => "grant",
        "name" => "GRANT_TEST",
        "component_ref" => "local.my-component:1.0.0"
      })
      assert result.granted == true

      {:ok, result} = MCP.handle("secret", ctx, %{
        "action" => "revoke",
        "name" => "GRANT_TEST",
        "component_ref" => "local.my-component:1.0.0"
      })
      assert result.status == :revoked
    end

    test "set without value returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("secret", ctx, %{"action" => "set", "name" => "TEST"})
      assert msg =~ "Missing required"
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("secret", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid secret action"
    end
  end

  # ============================================================================
  # Permission Tool
  # ============================================================================

  describe "permission tool" do
    test "list returns empty initially", %{ctx: ctx} do
      {:ok, result} = MCP.handle("permission", ctx, %{"action" => "list"})
      assert result.permissions == []
      assert result.count == 0
    end

    test "set and get permissions", %{ctx: ctx} do
      {:ok, result} = MCP.handle("permission", ctx, %{
        "action" => "set",
        "subject" => "user@example.com",
        "permissions" => ["execute", "component.publish"]
      })
      assert result.updated == true

      {:ok, result} = MCP.handle("permission", ctx, %{
        "action" => "get",
        "subject" => "user@example.com"
      })
      assert result.permissions == ["execute", "component.publish"]
    end

    test "get missing subject returns empty permissions", %{ctx: ctx} do
      {:ok, result} = MCP.handle("permission", ctx, %{
        "action" => "get",
        "subject" => "unknown@example.com"
      })
      assert result.permissions == []
    end

    test "set without permissions returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("permission", ctx, %{
        "action" => "set",
        "subject" => "user@example.com"
      })
      assert msg =~ "Missing required"
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("permission", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid permission action"
    end
  end

  # ============================================================================
  # Key Tool
  # ============================================================================

  describe "key tool" do
    test "list returns empty initially", %{ctx: ctx} do
      {:ok, result} = MCP.handle("key", ctx, %{"action" => "list"})
      assert result.keys == []
      assert result.count == 0
    end

    test "create and get a key", %{ctx: ctx} do
      {:ok, result} = MCP.handle("key", ctx, %{
        "action" => "create",
        "name" => "test-key",
        "scope" => ["execution"]
      })
      assert String.starts_with?(result.key, "cyfr_pk_")
      assert result.name == "test-key"

      {:ok, result} = MCP.handle("key", ctx, %{"action" => "get", "name" => "test-key"})
      assert result.name == "test-key"
      assert result.key_prefix =~ "cyfr_pk_"
    end

    test "create duplicate key returns error", %{ctx: ctx} do
      MCP.handle("key", ctx, %{"action" => "create", "name" => "dup-key"})

      {:error, msg} = MCP.handle("key", ctx, %{"action" => "create", "name" => "dup-key"})
      assert msg =~ "already exists"
    end

    test "revoke a key", %{ctx: ctx} do
      MCP.handle("key", ctx, %{"action" => "create", "name" => "revoke-key"})

      {:ok, result} = MCP.handle("key", ctx, %{"action" => "revoke", "name" => "revoke-key"})
      assert result.revoked == true

      # Key should not appear in list after revocation
      {:ok, result} = MCP.handle("key", ctx, %{"action" => "list"})
      names = Enum.map(result.keys, & &1.name)
      refute "revoke-key" in names
    end

    test "rotate a key", %{ctx: ctx} do
      {:ok, original} = MCP.handle("key", ctx, %{"action" => "create", "name" => "rotate-key"})

      {:ok, rotated} = MCP.handle("key", ctx, %{"action" => "rotate", "name" => "rotate-key"})
      assert rotated.name == "rotate-key"
      assert String.starts_with?(rotated.key, "cyfr_pk_")
      assert rotated.key != original.key
    end

    test "get missing key returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("key", ctx, %{"action" => "get", "name" => "missing"})
      assert msg =~ "not found"
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("key", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid key action"
    end

    test "rejects invalid key type", %{ctx: ctx} do
      {:error, msg} = MCP.handle("key", ctx, %{
        "action" => "create",
        "name" => "invalid-type-key",
        "type" => "INVALID"
      })
      assert msg =~ "Invalid key type"
      assert msg =~ "INVALID"
      assert msg =~ "public, secret, or admin"
    end

    test "accepts valid key types", %{ctx: ctx} do
      # Public key type
      {:ok, result} = MCP.handle("key", ctx, %{
        "action" => "create",
        "name" => "public-key",
        "type" => "public"
      })
      assert String.starts_with?(result.key, "cyfr_pk_")

      # Secret key type
      {:ok, result} = MCP.handle("key", ctx, %{
        "action" => "create",
        "name" => "secret-key",
        "type" => "secret"
      })
      assert String.starts_with?(result.key, "cyfr_sk_")

      # Admin key type
      {:ok, result} = MCP.handle("key", ctx, %{
        "action" => "create",
        "name" => "admin-key",
        "type" => "admin"
      })
      assert String.starts_with?(result.key, "cyfr_ak_")
    end
  end

  # ============================================================================
  # Audit Tool
  # ============================================================================

  describe "audit tool" do
    test "list returns empty initially", %{ctx: ctx} do
      {:ok, result} = MCP.handle("audit", ctx, %{"action" => "list"})
      assert result.events == []
      assert result.count == 0
    end

    test "list events after logging", %{ctx: ctx} do
      # Log some events directly
      Sanctum.Audit.log(ctx, "execution", %{component: "test-component"})
      Sanctum.Audit.log(ctx, "auth", %{action: "login"})

      {:ok, result} = MCP.handle("audit", ctx, %{"action" => "list"})
      assert result.count == 2
    end

    test "list with filters", %{ctx: ctx} do
      Sanctum.Audit.log(ctx, "execution", %{component: "test"})
      Sanctum.Audit.log(ctx, "auth", %{action: "login"})

      {:ok, result} = MCP.handle("audit", ctx, %{
        "action" => "list",
        "filters" => %{"event_type" => "execution"}
      })
      assert result.count == 1
      assert hd(result.events)["event_type"] == "execution"
    end

    test "export as json", %{ctx: ctx} do
      Sanctum.Audit.log(ctx, "execution", %{component: "test"})

      {:ok, result} = MCP.handle("audit", ctx, %{
        "action" => "export",
        "format" => "json"
      })
      assert result.format == "json"
      assert is_binary(result.data)
      assert Jason.decode!(result.data) |> is_list()
    end

    test "export as csv", %{ctx: ctx} do
      Sanctum.Audit.log(ctx, "execution", %{component: "test"})

      {:ok, result} = MCP.handle("audit", ctx, %{
        "action" => "export",
        "format" => "csv"
      })
      assert result.format == "csv"
      assert result.data =~ "timestamp,event_type"
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("audit", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid audit action"
    end
  end

  # ============================================================================
  # Policy Tool
  # ============================================================================

  describe "policy tool" do
    test "list returns empty initially", %{ctx: ctx} do
      {:ok, result} = MCP.handle("policy", ctx, %{"action" => "list"})
      assert result.policies == []
      assert result.count == 0
    end

    test "set and get a policy", %{ctx: ctx} do
      policy = %{
        allowed_domains: ["api.stripe.com"],
        rate_limit: %{requests: 100, window: "1m"},
        timeout: "30s"
      }

      {:ok, result} = MCP.handle("policy", ctx, %{
        "action" => "set",
        "component_ref" => "local.stripe-catalyst:1.0.0",
        "policy" => policy
      })
      assert result.stored == true
      assert result.component_ref == "local.stripe-catalyst:1.0.0"

      {:ok, result} = MCP.handle("policy", ctx, %{
        "action" => "get",
        "component_ref" => "local.stripe-catalyst:1.0.0"
      })
      assert result.component_ref == "local.stripe-catalyst:1.0.0"
      assert result.policy.allowed_domains == ["api.stripe.com"]
      assert result.policy.timeout == "30s"
    end

    test "get missing policy returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy", ctx, %{
        "action" => "get",
        "component_ref" => "local.nonexistent:1.0.0"
      })
      assert msg =~ "not found"
    end

    test "update_field on a policy", %{ctx: ctx} do
      # Set initial policy
      MCP.handle("policy", ctx, %{
        "action" => "set",
        "component_ref" => "local.update-test:1.0.0",
        "policy" => %{allowed_domains: ["example.com"], timeout: "30s"}
      })

      # Update a single field
      {:ok, result} = MCP.handle("policy", ctx, %{
        "action" => "update_field",
        "component_ref" => "local.update-test:1.0.0",
        "field" => "allowed_domains",
        "value" => ~s(["api.example.com", "cdn.example.com"])
      })
      assert result.updated == true
      assert result.field == "allowed_domains"

      # Verify the field was updated
      {:ok, result} = MCP.handle("policy", ctx, %{
        "action" => "get",
        "component_ref" => "local.update-test:1.0.0"
      })
      assert result.policy.allowed_domains == ["api.example.com", "cdn.example.com"]
    end

    test "delete a policy", %{ctx: ctx} do
      MCP.handle("policy", ctx, %{
        "action" => "set",
        "component_ref" => "local.delete-test:1.0.0",
        "policy" => %{timeout: "10s"}
      })

      {:ok, result} = MCP.handle("policy", ctx, %{
        "action" => "delete",
        "component_ref" => "local.delete-test:1.0.0"
      })
      assert result.deleted == true

      {:error, _} = MCP.handle("policy", ctx, %{
        "action" => "get",
        "component_ref" => "local.delete-test:1.0.0"
      })
    end

    test "list shows stored policies", %{ctx: ctx} do
      MCP.handle("policy", ctx, %{
        "action" => "set",
        "component_ref" => "local.list-test-a:1.0.0",
        "policy" => %{timeout: "10s"}
      })
      MCP.handle("policy", ctx, %{
        "action" => "set",
        "component_ref" => "local.list-test-b:1.0.0",
        "policy" => %{timeout: "20s"}
      })

      {:ok, result} = MCP.handle("policy", ctx, %{"action" => "list"})
      assert result.count >= 2

      refs = Enum.map(result.policies, & &1.component_ref)
      assert "local.list-test-a:1.0.0" in refs
      assert "local.list-test-b:1.0.0" in refs
    end

    test "get without component_ref returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy", ctx, %{"action" => "get"})
      assert msg =~ "Missing required"
    end

    test "set without policy returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy", ctx, %{"action" => "set"})
      assert msg =~ "Missing required"
    end

    test "update_field without required args returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy", ctx, %{"action" => "update_field"})
      assert msg =~ "Missing required"
    end

    test "delete without component_ref returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy", ctx, %{"action" => "delete"})
      assert msg =~ "Missing required"
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid policy action"
    end
  end

  # ============================================================================
  # Config Tool
  # ============================================================================

  describe "config tool" do
    test "list returns components", %{ctx: ctx} do
      {:ok, result} = MCP.handle("config", ctx, %{"action" => "list"})
      assert is_list(result.components)
      assert is_integer(result.count)
    end

    test "get_all returns empty config for unknown component", %{ctx: ctx} do
      {:ok, result} = MCP.handle("config", ctx, %{
        "action" => "get_all",
        "component_ref" => "local.nonexistent:1.0.0"
      })
      assert result.component_ref == "local.nonexistent:1.0.0"
      assert result.config == %{}
    end

    test "get missing key returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("config", ctx, %{
        "action" => "get",
        "component_ref" => "local.nonexistent:1.0.0",
        "key" => "missing_key"
      })
      assert msg =~ "not found"
    end

    test "get without required args returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("config", ctx, %{"action" => "get"})
      assert msg =~ "Missing required"
    end

    test "get_all without component_ref returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("config", ctx, %{"action" => "get_all"})
      assert msg =~ "Missing required"
    end

    test "set without required args returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("config", ctx, %{"action" => "set"})
      assert msg =~ "Missing required"
    end

    test "delete without required args returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("config", ctx, %{"action" => "delete"})
      assert msg =~ "Missing required"
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("config", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid config action"
    end
  end

  # ============================================================================
  # Policy Tool - MCP Boundary Actions
  # ============================================================================

  describe "policy.get_effective action" do
    test "returns default policy when none configured", %{ctx: ctx} do
      {:ok, result} = MCP.handle("policy", ctx, %{
        "action" => "get_effective",
        "component_ref" => "local.unconfigured:1.0.0"
      })

      # Default policy has empty allowed_domains
      assert result["allowed_domains"] == []
      assert result["timeout"] == "30s"
      assert is_integer(result["max_memory_bytes"])
    end

    test "returns configured policy", %{ctx: ctx} do
      MCP.handle("policy", ctx, %{
        "action" => "set",
        "component_ref" => "local.effective-test:1.0.0",
        "policy" => %{allowed_domains: ["api.stripe.com"], timeout: "60s"}
      })

      {:ok, result} = MCP.handle("policy", ctx, %{
        "action" => "get_effective",
        "component_ref" => "local.effective-test:1.0.0"
      })

      assert result["allowed_domains"] == ["api.stripe.com"]
      assert result["timeout"] == "60s"
    end

    test "returns error without component_ref", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy", ctx, %{"action" => "get_effective"})
      assert msg =~ "Missing required"
    end
  end

  describe "policy.check_rate_limit action" do
    test "returns allowed when no policy exists", %{ctx: ctx} do
      {:ok, result} = MCP.handle("policy", ctx, %{
        "action" => "check_rate_limit",
        "component_ref" => "local.no-policy:1.0.0"
      })

      assert result.allowed == true
      assert result.remaining == nil
    end

    test "returns allowed when policy has no rate limit", %{ctx: ctx} do
      MCP.handle("policy", ctx, %{
        "action" => "set",
        "component_ref" => "local.no-rate-limit:1.0.0",
        "policy" => %{allowed_domains: ["example.com"]}
      })

      {:ok, result} = MCP.handle("policy", ctx, %{
        "action" => "check_rate_limit",
        "component_ref" => "local.no-rate-limit:1.0.0"
      })

      assert result.allowed == true
    end

    test "returns error without component_ref", %{ctx: ctx} do
      {:error, msg} = MCP.handle("policy", ctx, %{"action" => "check_rate_limit"})
      assert msg =~ "Missing required"
    end
  end

  # ============================================================================
  # Secret Tool - MCP Boundary Actions
  # ============================================================================

  describe "secret.resolve_granted action" do
    test "returns empty map when no secrets granted", %{ctx: ctx} do
      {:ok, result} = MCP.handle("secret", ctx, %{
        "action" => "resolve_granted",
        "component_ref" => "local.no-secrets:1.0.0"
      })

      assert result.secrets == %{}
    end

    test "returns granted secrets", %{ctx: ctx} do
      MCP.handle("secret", ctx, %{"action" => "set", "name" => "RESOLVE_KEY", "value" => "resolve-val"})
      MCP.handle("secret", ctx, %{"action" => "grant", "name" => "RESOLVE_KEY", "component_ref" => "local.resolve-test:1.0.0"})

      {:ok, result} = MCP.handle("secret", ctx, %{
        "action" => "resolve_granted",
        "component_ref" => "local.resolve-test:1.0.0"
      })

      assert result.secrets["RESOLVE_KEY"] == "resolve-val"
    end

    test "returns error without component_ref", %{ctx: ctx} do
      {:error, msg} = MCP.handle("secret", ctx, %{"action" => "resolve_granted"})
      assert msg =~ "Missing required"
    end
  end

  describe "secret.can_access action" do
    test "returns allowed false when not granted", %{ctx: ctx} do
      MCP.handle("secret", ctx, %{"action" => "set", "name" => "ACCESS_TEST", "value" => "val"})

      {:ok, result} = MCP.handle("secret", ctx, %{
        "action" => "can_access",
        "name" => "ACCESS_TEST",
        "component_ref" => "local.no-access:1.0.0"
      })

      assert result.allowed == false
    end

    test "returns allowed true when granted", %{ctx: ctx} do
      MCP.handle("secret", ctx, %{"action" => "set", "name" => "GRANTED_TEST", "value" => "val"})
      MCP.handle("secret", ctx, %{"action" => "grant", "name" => "GRANTED_TEST", "component_ref" => "local.has-access:1.0.0"})

      {:ok, result} = MCP.handle("secret", ctx, %{
        "action" => "can_access",
        "name" => "GRANTED_TEST",
        "component_ref" => "local.has-access:1.0.0"
      })

      assert result.allowed == true
    end

    test "returns error without required args", %{ctx: ctx} do
      {:error, msg} = MCP.handle("secret", ctx, %{"action" => "can_access"})
      assert msg =~ "Missing required"
    end
  end

  # ============================================================================
  # Audit Tool - MCP Boundary Actions
  # ============================================================================

  describe "audit.log_violation action" do
    test "logs a violation and returns success", %{ctx: ctx} do
      {:ok, result} = MCP.handle("audit", ctx, %{
        "action" => "log_violation",
        "component_ref" => "local.bad-component:1.0.0",
        "violation_type" => "domain_blocked",
        "details" => "Attempted to reach evil.com",
        "domain" => "evil.com",
        "method" => "GET",
        "reason" => "Domain not in allowed list"
      })

      assert result.logged == true
    end
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  describe "unknown tool" do
    test "returns error for unknown tool", %{ctx: ctx} do
      {:error, msg} = MCP.handle("unknown_tool", ctx, %{})
      assert msg =~ "Unknown tool"
    end
  end
end
