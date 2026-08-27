# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCPTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.MCP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Use a test-specific base path to avoid polluting real config
    test_path = Path.join(System.tmp_dir!(), "sanctum_mcp_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local(), test_path: test_path}
  end

  # ============================================================================
  # Tool Discovery
  # ============================================================================

  describe "tools/0" do
    test "returns 10 action-based tools" do
      tools = MCP.tools()
      assert length(tools) == 10

      tool_names = Enum.map(tools, & &1.name)
      assert "session" in tool_names
      # No "secret" tool: the legacy secrets plane retired; vault entries
      # are the only credential store.
      refute "secret" in tool_names
      # No "permission" tool: memberships are presence-only, there are no
      # roles, and the decorative RBAC store is gone.
      refute "permission" in tool_names
      assert "key" in tool_names
      assert "vault" in tool_names
      assert "profile" in tool_names
      # No "policy" tool: the legacy policy plane retired; consents carry
      # the effective capability.
      refute "policy" in tool_names
      assert "oauth" in tool_names
      assert "tincture_visibility" in tool_names
      assert "webhook" in tool_names
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
      assert length(resources) == 2

      uris = Enum.map(resources, & &1.uri)
      assert "sanctum://identity" in uris
      assert "sanctum://permissions" in uris
    end
  end

  describe "resource_templates/0" do
    test "returns no templates" do
      assert MCP.resource_templates() == []
    end
  end

  describe "read/2" do
    test "reads identity resource", %{ctx: ctx} do
      {:ok, result} = MCP.read(ctx, "sanctum://identity")
      assert result.mimeType == "application/json"

      content = Jason.decode!(result.content)
      assert content["user_id"] == "local|local|testns"
      assert content["scope"] == "athanor"
      assert content["athanor_id"] == ctx.athanor_id
    end

    test "reads permissions resource", %{ctx: ctx} do
      {:ok, result} = MCP.read(ctx, "sanctum://permissions")
      assert result.mimeType == "application/json"

      content = Jason.decode!(result.content)
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
    test "whoami returns local user only (registry identity moved to Compendium.MCP.registry.whoami)",
         %{ctx: ctx} do
      {:ok, result} = MCP.handle("session", ctx, %{"action" => "whoami"})
      assert result.user_id == "local|local|testns"
      # session.whoami returns local-user fields plus where the session works
      # (athanor, operator capability); permissions dropped; registry identity
      # lives on Compendium.MCP.registry.whoami.
      assert Map.has_key?(result, :email)
      assert Map.has_key?(result, :provider)
      assert result.athanor_id == ctx.athanor_id
      assert result.platform_admin == false
      # display_name dropped — UI consumers render `email || user_id` directly.
      refute Map.has_key?(result, :display_name)
      refute Map.has_key?(result, :scope)
      refute Map.has_key?(result, :registry)
    end

    test "whoami returns error when not authenticated" do
      ctx = %Context{authenticated: false, permissions: MapSet.new()}
      {:error, msg} = MCP.handle("session", ctx, %{"action" => "whoami"})
      assert msg =~ "Not authenticated"
    end

    test "whoami surfaces :email from Context when present" do
      ctx =
        Context.build(
          user_id: "github|https://github.com|12345",
          email: "alice@example.com",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      {:ok, result} = MCP.handle("session", ctx, %{"action" => "whoami"})
      assert result.email == "alice@example.com"
      assert result.provider == "github"
    end

    test "whoami returns nil :email when Context has no email (e.g. API-key auth)" do
      ctx =
        Context.build(
          user_id: "github|https://github.com|12345",
          permissions: [:*],
          scope: :athanor,
          auth_method: :api_key,
          namespace: "testns",
          authenticated: true
        )

      {:ok, result} = MCP.handle("session", ctx, %{"action" => "whoami"})
      assert result.email == nil
    end

    test "login returns redirect info", %{ctx: ctx} do
      {:ok, result} = MCP.handle("session", ctx, %{"action" => "login"})
      assert result.redirect == "/auth/login"
    end

    test "logout retires the session that called it", %{ctx: ctx} do
      {:ok, session} = Sanctum.Session.create(ctx)
      assert {:ok, _} = Sanctum.Session.load(session.token, surface: :console)

      session_ctx = %{ctx | session_token_hash: Sanctum.Session.token_hash(session.token)}

      {:ok, result} = MCP.handle("session", session_ctx, %{"action" => "logout"})
      assert result.message =~ "Logged out"

      # The whole point: the credential must not survive its own logout.
      assert {:error, _} = Sanctum.Session.load(session.token, surface: :console)
    end

    test "logout refuses when an API key authenticated the call", %{ctx: ctx} do
      {:error, msg} = MCP.handle("session", ctx, %{"action" => "logout"})
      assert msg =~ "No session to log out"
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("session", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid session action"
    end
  end

  # ============================================================================
  # Retired: the "secret" tool. The legacy secrets plane is gone — vault
  # entries (sealed, consent-bound) are the only credential store, managed
  # through the "vault" tool (covered in mcp_vault_profile_test.exs).
  # ============================================================================

  describe "secret tool retired" do
    test "the secret tool is no longer routable", %{ctx: ctx} do
      {:error, msg} = MCP.handle("secret", ctx, %{"action" => "list"})
      assert msg =~ "Unknown tool"
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
      {:ok, result} =
        MCP.handle("key", ctx, %{
          "action" => "create",
          "name" => "test-key"
        })

      assert String.starts_with?(result.api_key, "cyfr_pk_")
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
      assert String.starts_with?(rotated.api_key, "cyfr_pk_")
      assert rotated.api_key != original.api_key
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
      {:error, msg} =
        MCP.handle("key", ctx, %{
          "action" => "create",
          "name" => "invalid-type-key",
          "type" => "INVALID"
        })

      assert msg =~ "Invalid key type"
      assert msg =~ "INVALID"
      assert msg =~ "application, service, or admin"
    end

    test "accepts valid key types", %{ctx: ctx} do
      # Application key type
      {:ok, result} =
        MCP.handle("key", ctx, %{
          "action" => "create",
          "name" => "application-key",
          "type" => "application"
        })

      assert String.starts_with?(result.api_key, "cyfr_pk_")

      # Service key type
      {:ok, result} =
        MCP.handle("key", ctx, %{
          "action" => "create",
          "name" => "service-key",
          "type" => "service"
        })

      assert String.starts_with?(result.api_key, "cyfr_sk_")

      # Admin key type
      {:ok, result} =
        MCP.handle("key", ctx, %{
          "action" => "create",
          "name" => "admin-key",
          "type" => "admin"
        })

      assert String.starts_with?(result.api_key, "cyfr_ak_")
    end
  end

  # ============================================================================

  describe "permission gates" do
    setup do
      restricted_ctx = %Context{
        user_id: "restricted_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:execute]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, restricted_ctx: restricted_ctx}
    end

    test "key:list requires admin permission", %{restricted_ctx: ctx} do
      assert {:error, {:missing_permission, :admin}} =
               Emissary.MCP.ToolRegistry.call_external("key", ctx, %{"action" => "list"})
    end

    test "key:get requires admin permission", %{restricted_ctx: ctx} do
      assert {:error, {:missing_permission, :admin}} =
               Emissary.MCP.ToolRegistry.call_external("key", ctx, %{
                 "action" => "get",
                 "name" => "test-key"
               })
    end
  end

  # ============================================================================
  # Tincture Visibility Tool
  # ============================================================================

  describe "tincture_visibility set is gone" do
    test "the retired verb is an unknown action, not a teaching shim", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("tincture_visibility", ctx, %{
          "action" => "set",
          "publisher" => "local",
          "name" => "test-tincture",
          "public" => true
        })

      assert msg =~ "Invalid tincture_visibility action"
    end
  end

  describe "tincture_visibility get" do
    test "reports private when no public profile exists", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("tincture_visibility", ctx, %{
          "action" => "get",
          "publisher" => "local",
          "name" => "nonexistent"
        })

      assert result.public == false
    end

    test "reports public when an active public profile exists", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :consent_source)
      Application.put_env(:cyfr, :consent_source, Sanctum.Consent.Source.DB)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :consent_source, original),
          else: Application.delete_env(:cyfr, :consent_source)
      end)

      {:ok, _} =
        Arca.ProfileStorage.put(%{
          id: "prof_vis_#{:rand.uniform(1_000_000)}",
          athanor_id: ctx.athanor_id,
          source_ref: "tincture:local.vis-test",
          kind: "public",
          label: "public",
          status: "active"
        })

      # The URL is derived from the athanor row (its slug/kind), so the row
      # behind the test context must exist.
      athanor = Sanctum.TestContext.athanor!()

      {:ok, result} =
        MCP.handle("tincture_visibility", ctx, %{
          "action" => "get",
          "publisher" => "local",
          "name" => "vis-test"
        })

      assert result.public == true
      assert is_binary(result.public_profile_id)
      # The finished public URL rides along, keyed by the owning athanor, so
      # no client composes the route shape itself.
      assert result.athanor == ctx.athanor_id
      segment = Cyfr.TinctureHelpers.athanor_segment(athanor)
      assert result.url == Cyfr.TinctureHelpers.tincture_path(segment, "local", "vis-test")
    end
  end

  describe "tincture_visibility invalid action" do
    test "returns error for unknown action", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("tincture_visibility", ctx, %{"action" => "delete"})

      assert msg =~ "Invalid tincture_visibility action"
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

  # ============================================================================
  # Device-flow gate — single-user only
  # ============================================================================

  describe "session.device-init / device-poll gate" do
    test "device-init is available when auth_provider is OAuth", %{ctx: ctx} do
      previous = Application.get_env(:cyfr, :auth_provider)

      try do
        Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OAuth)

        # The call will still fail because no GitHub client_id is set in the
        # test env, but it should fail with the "client ID not configured"
        # message (proving the gate let it through), not the disabled message.
        result = MCP.handle("session", ctx, %{"action" => "device_init", "provider" => "github"})

        case result do
          {:error, msg} ->
            refute msg =~ "requires the GitHub/Google OAuth provider"
            assert msg =~ "client ID" or msg =~ "Failed to initialize"

          {:ok, _} ->
            :ok
        end
      after
        restore_env(:auth_provider, previous)
      end
    end

    test "device-init is disabled when auth_provider is a non-OAuth provider", %{ctx: ctx} do
      previous = Application.get_env(:cyfr, :auth_provider)

      try do
        Application.put_env(:cyfr, :auth_provider, Sanctum.Test.AltAuthProvider)

        assert {:error, msg} =
                 MCP.handle("session", ctx, %{"action" => "device_init", "provider" => "github"})

        assert msg =~ "requires the GitHub/Google OAuth provider"
        assert msg =~ "/auth/"
      after
        restore_env(:auth_provider, previous)
      end
    end

    test "device-poll is disabled when auth_provider is a non-OAuth provider", %{ctx: ctx} do
      previous = Application.get_env(:cyfr, :auth_provider)

      try do
        Application.put_env(:cyfr, :auth_provider, Sanctum.Test.AltAuthProvider)

        assert {:error, msg} =
                 MCP.handle("session", ctx, %{
                   "action" => "device_poll",
                   "device_code" => "dummy",
                   "provider" => "github"
                 })

        assert msg =~ "requires the GitHub/Google OAuth provider"
      after
        restore_env(:auth_provider, previous)
      end
    end

    test "nil auth_provider is treated as single-user (OAuth-equivalent)", %{ctx: ctx} do
      previous = Application.get_env(:cyfr, :auth_provider)

      try do
        Application.delete_env(:cyfr, :auth_provider)

        result = MCP.handle("session", ctx, %{"action" => "device_init", "provider" => "github"})

        case result do
          {:error, msg} -> refute msg =~ "requires the GitHub/Google OAuth provider"
          {:ok, _} -> :ok
        end
      after
        restore_env(:auth_provider, previous)
      end
    end
  end

  describe "tenant-scoped MCP actions — athanor-scoped vs athanor-less" do
    setup do
      scoped =
        Context.build(
          user_id: "ext_user",
          namespace: "ext_ns",
          athanor_id: "ath_acme",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      unresolved =
        Context.build(
          user_id: "ext_user",
          namespace: "ext_ns",
          athanor_id: nil,
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, scoped: scoped, unresolved: unresolved}
    end

    test "key.create: athanor-scoped succeeds, athanor-less is fail-closed",
         %{scoped: scoped, unresolved: unresolved} do
      assert {:ok, _} =
               MCP.handle("key", scoped, %{"action" => "create", "name" => "ext-ok-key"})

      assert_fail_closed(fn ->
        MCP.handle("key", unresolved, %{"action" => "create", "name" => "ext-no-key"})
      end)
    end
  end

  # A tenant-scoped write must NOT succeed for an athanor-less context: it
  # either raises (the require_tenant! chokepoint) or returns
  # {:error, _} (the tenant_ok early-return). Never {:ok, _}.
  defp assert_fail_closed(fun) do
    result =
      try do
        fun.()
      rescue
        Sanctum.UnauthorizedError -> :raised
      end

    case result do
      :raised -> :ok
      {:error, _} -> :ok
      other -> flunk("expected fail-closed (raise or {:error,_}), got: #{inspect(other)}")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:cyfr, key)
  defp restore_env(key, value), do: Application.put_env(:cyfr, key, value)
end
