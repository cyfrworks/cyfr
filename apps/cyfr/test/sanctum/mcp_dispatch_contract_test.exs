# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCPDispatchContractTest do
  @moduledoc """
  Frozen external contract for `Sanctum.MCP`.

  This is THE regression gate for the MCP decomposition (Phase 3 #11): the
  registry calls `tools/0`, `handle/3`, `resources/0`, `resource_templates/0`,
  `read/2` by module name, and MCP clients depend on the exact tool names,
  per-tool action vocabularies, and terminal error strings. The split must
  keep every assertion below byte-identical.
  """
  # async: false — the setups set shared sandbox mode (a global mutation), which
  # would corrupt other async tests' connection ownership if run concurrently.
  use ExUnit.Case, async: false

  alias Sanctum.MCP

  @tool_names ~w(session oauth key tincture_visibility webhook vault profile)

  @action_enums %{
    "session" => ["login", "logout", "whoami", "device_init", "device_poll"],
    "oauth" => ["set_client"],
    "key" => ["create", "get", "list", "revoke", "rotate"],
    "tincture_visibility" => ["get"],
    "webhook" => ["create", "list", "get", "update", "revoke", "rotate"],
    "vault" => ["list", "create", "rename", "rotate", "rebind", "authorize", "revoke", "delete"],
    "profile" => ["plan", "preview", "commit", "publish", "list", "revoke"]
  }

  @invalid_action_errors %{
    "session" =>
      "Invalid session action. Use: login, logout, whoami, device_init, or device_poll",
    "oauth" => "Invalid oauth action. Use: set_client",
    "key" => "Invalid key action. Use: create, get, list, revoke, or rotate",
    "tincture_visibility" => "Invalid tincture_visibility action. Use: get",
    "webhook" => "Invalid webhook action. Use: create, get, list, update, revoke, rotate",
    "vault" =>
      "Invalid vault action. Use: list, create, rename, rotate, rebind, authorize, revoke, delete",
    "profile" => "Invalid profile action. Use: plan, preview, commit, publish, list, revoke"
  }

  describe "tools/0 — frozen surface" do
    test "exactly these 7 tools, in order" do
      assert Enum.map(MCP.tools(), & &1.name) == @tool_names
    end

    test "every tool has the structural shape MCP clients depend on" do
      for tool <- MCP.tools() do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        schema = tool.input_schema
        assert schema["type"] == "object"
        assert "action" in schema["required"]
        enum = schema["properties"]["action"]["enum"]
        assert is_list(enum) and enum != []
        assert Enum.all?(enum, &is_binary/1)
      end
    end

    test "each tool's action enum is frozen" do
      by_name = Map.new(MCP.tools(), &{&1.name, &1})

      for {name, expected} <- @action_enums do
        assert by_name[name].input_schema["properties"]["action"]["enum"] == expected,
               "action enum drift for tool #{name}"
      end
    end
  end

  describe "resources/0 and resource_templates/0 — frozen" do
    test "resources/0" do
      assert MCP.resources() == [
               %{
                 uri: "sanctum://identity",
                 name: "Current Identity",
                 description: "Current authenticated user identity",
                 mimeType: "application/json"
               },
               %{
                 uri: "sanctum://permissions",
                 name: "User Permissions",
                 description: "Current user's granted permissions",
                 mimeType: "application/json"
               }
             ]
    end

    test "resource_templates/0" do
      assert MCP.resource_templates() == []
    end
  end

  describe "read/2 — contract" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      {:ok, ctx: Sanctum.TestContext.local()}
    end

    test "sanctum://identity returns JSON with user_id/athanor_id/scope", %{ctx: ctx} do
      assert {:ok, %{content: content, mimeType: "application/json"}} =
               MCP.read(ctx, "sanctum://identity")

      decoded = Jason.decode!(content)
      assert decoded["user_id"] == ctx.user_id
      assert Map.has_key?(decoded, "athanor_id")
      assert Map.has_key?(decoded, "scope")
    end

    test "sanctum://permissions returns JSON with a permissions key", %{ctx: ctx} do
      assert {:ok, %{content: content, mimeType: "application/json"}} =
               MCP.read(ctx, "sanctum://permissions")

      assert Map.has_key?(Jason.decode!(content), "permissions")
    end

    test "unknown URI → exact error string", %{ctx: ctx} do
      assert MCP.read(ctx, "sanctum://nope") == {:error, "Unknown resource URI: sanctum://nope"}
    end
  end

  describe "handle/3 — terminal clauses (the split tripwires)" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      {:ok, ctx: Sanctum.TestContext.local()}
    end

    test "each tool's invalid-action terminal string is frozen", %{ctx: ctx} do
      for {tool, expected} <- @invalid_action_errors do
        assert MCP.handle(tool, ctx, %{"action" => "___no_such_action___"}) ==
                 {:error, expected},
               "invalid-action message drift for tool #{tool}"
      end
    end

    test "unknown tool → exact error string", %{ctx: ctx} do
      assert MCP.handle("totally_unknown", ctx, %{"action" => "x"}) ==
               {:error, "Unknown tool: totally_unknown"}
    end
  end
end
