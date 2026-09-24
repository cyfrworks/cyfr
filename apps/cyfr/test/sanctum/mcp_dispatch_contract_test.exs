# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCPDispatchContractTest do
  @moduledoc """
  Frozen external contract for `Sanctum.MCP`.

  Checks provider exports, tool names, action vocabularies and error
  contracts used by the registry and MCP clients.
  """
  # async: false — the setups set shared sandbox mode (a global mutation), which
  # would corrupt other async tests' connection ownership if run concurrently.
  use ExUnit.Case, async: false

  alias Sanctum.MCP

  @tool_names ~w(session athanor member door oauth key tincture_visibility webhook vault profile)

  @action_enums %{
    "session" => [
      "login",
      "logout",
      "whoami",
      "device_init",
      "device_poll",
      "use",
      "read_resource"
    ],
    "athanor" => [
      "list",
      "get",
      "create",
      "pair",
      "rename",
      "archive",
      "unarchive",
      "settings",
      "provision",
      "purge",
      "destroy"
    ],
    "member" => ["list", "add", "remove", "leave"],
    "door" => ["list", "requests", "allow", "deny", "remove", "resolve"],
    "oauth" => ["set_client", "list", "delete_client"],
    "key" => ["create", "get", "list", "revoke", "rotate"],
    "tincture_visibility" => ["get"],
    "webhook" => ["create", "list", "get", "update", "revoke", "rotate"],
    "vault" => ["list", "create", "rename", "rotate", "rebind", "authorize", "revoke", "delete"],
    "profile" => ["plan", "preview", "commit", "grant", "publish", "list", "revoke"]
  }

  @invalid_action_errors %{
    "session" => "Unknown action: session.___no_such_action___",
    "athanor" => "Unknown action: athanor.___no_such_action___",
    "member" => "Unknown action: member.___no_such_action___",
    "door" => "Unknown action: door.___no_such_action___",
    "oauth" => "Invalid oauth action. Use: set_client, list, or delete_client",
    "key" => "Invalid key action. Use: create, get, list, revoke, or rotate",
    "tincture_visibility" => "Invalid tincture_visibility action. Use: get",
    "webhook" => "Invalid webhook action. Use: create, list, get, update, revoke, or rotate",
    "vault" =>
      "Invalid vault action. Use: list, create, rename, rotate, rebind, authorize, revoke, or delete",
    "profile" =>
      "Invalid profile action. Use: plan, preview, commit, grant, publish, list, or revoke"
  }

  describe "tools/0 — frozen surface" do
    test "exactly these 10 tools, in order" do
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

  describe "session.read_resource — contract" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      {:ok, ctx: Sanctum.TestContext.local()}
    end

    test "sanctum://identity returns JSON with user_id/athanor_id/scope", %{ctx: ctx} do
      assert {:ok, %{content: content, mimeType: "application/json"}} =
               read(ctx, "sanctum://identity")

      decoded = Jason.decode!(content)
      assert decoded["user_id"] == ctx.user_id
      assert Map.has_key?(decoded, "athanor_id")
      assert Map.has_key?(decoded, "scope")
    end

    test "sanctum://permissions returns JSON with a permissions key", %{ctx: ctx} do
      assert {:ok, %{content: content, mimeType: "application/json"}} =
               read(ctx, "sanctum://permissions")

      assert Map.has_key?(Jason.decode!(content), "permissions")
    end

    test "unknown URI → exact typed refusal", %{ctx: ctx} do
      assert read(ctx, "sanctum://nope") ==
               {:error, {:invalid_argument, "Unknown resource URI: sanctum://nope"}}
    end

    test "the declaration: anonymous, no permission, external, replay-safe, one uri" do
      [session] = Enum.filter(MCP.tools(), &(&1.name == "session"))
      op = Enum.find(session.operations, &(&1.action == "read_resource"))

      assert %{auth: :anonymous, permission: nil, planes: [:external], kind: :read} = op
      assert op.recovery == :replay_safe
      assert op.resource_schemes == ["sanctum"]
      assert [%{name: "uri", type: :string, required: true}] = op.args
    end
  end

  defp read(ctx, uri),
    do:
      Cyfr.Ops.Catalog.call_external("session", ctx, %{
        "action" => "read_resource",
        "uri" => uri
      })

  describe "handle/3 — terminal clauses (the split tripwires)" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      {:ok, ctx: Sanctum.TestContext.local()}
    end

    test "each tool's invalid-action terminal sentence is frozen", %{ctx: ctx} do
      for {tool, expected} <- @invalid_action_errors do
        assert {:error, reason} = MCP.handle(tool, ctx, %{"action" => "___no_such_action___"})

        assert Cyfr.Ops.Error.render(reason) == expected,
               "invalid-action message drift for tool #{tool}"
      end
    end

    test "unknown tool → exact error string", %{ctx: ctx} do
      assert MCP.handle("totally_unknown", ctx, %{"action" => "x"}) ==
               {:error, "Unknown tool: totally_unknown"}
    end
  end
end
