# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolVisibilityTest do
  use ExUnit.Case, async: true

  alias Emissary.MCP.ToolVisibility
  alias Sanctum.Context

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp make_tool(name, actions) do
    %{
      "name" => name,
      "description" => "Test tool: #{name}",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => actions
          }
        },
        "required" => ["action"]
      }
    }
  end

  defp make_tool_no_actions(name) do
    %{
      "name" => name,
      "description" => "External tool: #{name}",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{}
      }
    }
  end

  defp ctx_with(permissions) do
    Context.build(
      user_id: "test_user",
      permissions: permissions,
      auth_method: :api_key,
      namespace: "testns",
      authenticated: true
    )
  end

  defp action_enum(tool_def) do
    get_in(tool_def, ["inputSchema", "properties", "action", "enum"])
  end

  defp sample_tools do
    [
      make_tool("execution", [
        "run",
        "run_stream",
        "list",
        "logs",
        "cancel",
        "status",
        "force_release"
      ]),
      make_tool("key", ["create", "get", "list", "revoke", "rotate"]),
      make_tool("component", [
        "search",
        "inspect",
        "list",
        "categories",
        "setup_plan",
        "get_blob",
        "discover",
        "pull",
        "push",
        "register",
        "remove",
        "new"
      ]),
      make_tool("session", [
        "whoami",
        "login",
        "logout",
        "device_init",
        "device_poll"
      ]),
      make_tool("aqua", ["list", "get", "create", "create_agent", "update", "delete"]),
      make_tool("system", ["status", "notify"]),
      make_tool("schedule", [
        "create",
        "list",
        "get",
        "update",
        "pause",
        "resume",
        "delete",
        "re_resolve"
      ]),
      make_tool("permission", ["get", "list", "set"]),
      make_tool("record", ["get", "list"]),
      make_tool("retention", ["get", "set", "cleanup"]),
      make_tool("mcp_log", ["list", "get", "correlate", "stats"]),
      make_tool("policy_log", ["list", "get", "correlate"]),
      make_tool("build", ["compile", "validate", "toolchains"]),
      make_tool("mcp_servers", [
        "add",
        "delete",
        "list",
        "get",
        "test",
        "refresh",
        "enable",
        "disable"
      ]),
      make_tool("tools", ["list"]),
      make_tool_no_actions("notion:create_page")
    ]
  end

  # ============================================================================
  # Tests
  # ============================================================================

  describe "wildcard permission" do
    test "returns all tools unmodified" do
      ctx = ctx_with([:*])
      tools = sample_tools()
      assert ToolVisibility.filter_for_context(tools, ctx) == tools
    end
  end

  describe "execute-only context" do
    setup do
      ctx = ctx_with([:execute])
      filtered = ToolVisibility.filter_for_context(sample_tools(), ctx)
      %{filtered: filtered, names: Enum.map(filtered, & &1["name"])}
    end

    test "sees execution tool with gated actions (minus force_release)", %{filtered: filtered} do
      exec = Enum.find(filtered, &(&1["name"] == "execution"))
      assert exec
      actions = action_enum(exec)
      assert "run" in actions
      assert "status" in actions
      refute "force_release" in actions
    end

    test "sees schedule and build.compile", %{filtered: filtered} do
      schedule = Enum.find(filtered, &(&1["name"] == "schedule"))
      assert schedule
      assert length(action_enum(schedule)) == 8

      build = Enum.find(filtered, &(&1["name"] == "build"))
      assert build
      assert "compile" in action_enum(build)
      assert "validate" in action_enum(build)
      assert "toolchains" in action_enum(build)
    end

    test "sees public-only tools", %{names: names} do
      assert "aqua" in names
      assert "system" in names
      assert "tools" in names
      assert "mcp_servers" in names
    end

    test "does not see fully-gated tools", %{names: names} do
      refute "key" in names
      refute "permission" in names
      refute "record" in names
    end

    test "sees session.whoami only", %{filtered: filtered} do
      session = Enum.find(filtered, &(&1["name"] == "session"))
      assert session
      # The only unprivileged session action is `whoami`. Device-flow actions
      # require `:admin` per ToolVisibility; login/logout are gated too.
      assert action_enum(session) == ["whoami"]
    end
  end

  describe "no permissions context" do
    setup do
      ctx = ctx_with([])
      filtered = ToolVisibility.filter_for_context(sample_tools(), ctx)
      %{filtered: filtered, names: Enum.map(filtered, & &1["name"])}
    end

    test "sees public tools", %{names: names} do
      assert "aqua" in names
      assert "system" in names
      assert "tools" in names
      assert "mcp_servers" in names
    end

    test "does not see gated tools", %{names: names} do
      refute "key" in names
      refute "execution" in names
      refute "schedule" in names
      refute "permission" in names
      refute "record" in names
    end

    test "session only has whoami", %{filtered: filtered} do
      session = Enum.find(filtered, &(&1["name"] == "session"))
      assert session
      # Post auth-refactor — see the equivalent assertion in the user-perm
      # describe block above.
      assert action_enum(session) == ["whoami"]
    end

    test "component only has public actions", %{filtered: filtered} do
      comp = Enum.find(filtered, &(&1["name"] == "component"))
      assert comp
      actions = action_enum(comp)
      assert "search" in actions
      assert "inspect" in actions
      assert "list" in actions
      refute "get_blob" in actions
      refute "pull" in actions
      refute "push" in actions
    end

    test "mcp_log only has public actions", %{filtered: filtered} do
      log = Enum.find(filtered, &(&1["name"] == "mcp_log"))
      assert log
      actions = action_enum(log)
      assert "correlate" in actions
      assert "stats" in actions
      refute "list" in actions
      refute "get" in actions
    end

    test "policy_log only has correlate", %{filtered: filtered} do
      log = Enum.find(filtered, &(&1["name"] == "policy_log"))
      assert log
      assert action_enum(log) == ["correlate"]
    end

    test "build only has public actions", %{filtered: filtered} do
      build = Enum.find(filtered, &(&1["name"] == "build"))
      assert build
      actions = action_enum(build)
      assert "validate" in actions
      assert "toolchains" in actions
      refute "compile" in actions
    end

    test "retention only has admin cleanup — dropped entirely", %{names: names} do
      refute "retention" in names
    end
  end

  describe "mixed permissions" do
    test "execute + storage_read sees union" do
      ctx = ctx_with([:execute, :storage_read])
      filtered = ToolVisibility.filter_for_context(sample_tools(), ctx)
      names = Enum.map(filtered, & &1["name"])

      assert "execution" in names
      assert "schedule" in names

      record = Enum.find(filtered, &(&1["name"] == "record"))
      assert record
      actions = action_enum(record)
      assert "list" in actions
      assert "get" in actions
    end
  end

  describe "mixed-action tool pruning" do
    test "component with component_manage keeps all actions" do
      ctx = ctx_with([:component_read, :component_manage])
      tools = [sample_tools() |> Enum.find(&(&1["name"] == "component"))]
      [comp] = ToolVisibility.filter_for_context(tools, ctx)
      actions = action_enum(comp)

      # public + component_read + component_manage = all
      assert "search" in actions
      assert "get_blob" in actions
      assert "pull" in actions
      assert "push" in actions
      assert length(actions) == 12
    end

    test "component with only component_read sees public + read actions" do
      ctx = ctx_with([:component_read])
      tools = [sample_tools() |> Enum.find(&(&1["name"] == "component"))]
      [comp] = ToolVisibility.filter_for_context(tools, ctx)
      actions = action_enum(comp)

      assert "search" in actions
      assert "get_blob" in actions
      assert "discover" in actions
      refute "pull" in actions
      refute "push" in actions
    end
  end

  describe "fully-gated tool dropped" do
    test "key tool dropped for non-admin" do
      ctx = ctx_with([:execute, :secrets_read])
      tools = [make_tool("key", ["create", "get", "list", "revoke", "rotate"])]
      assert ToolVisibility.filter_for_context(tools, ctx) == []
    end
  end

  describe "external tools" do
    test "tool with no action enum and colon namespace passes through" do
      ctx = ctx_with([])
      ext = make_tool_no_actions("notion:create_page")
      assert ToolVisibility.filter_for_context([ext], ctx) == [ext]
    end

    test "tool with no action enum and no namespace passes through" do
      ctx = ctx_with([])
      ext = make_tool_no_actions("custom_tool")
      assert ToolVisibility.filter_for_context([ext], ctx) == [ext]
    end
  end

  describe "retention tool" do
    test "storage_read sees get only" do
      ctx = ctx_with([:storage_read])
      tools = [sample_tools() |> Enum.find(&(&1["name"] == "retention"))]
      [ret] = ToolVisibility.filter_for_context(tools, ctx)
      actions = action_enum(ret)

      assert actions == ["get"]
    end

    test "admin sees cleanup" do
      ctx = ctx_with([:admin])
      tools = [sample_tools() |> Enum.find(&(&1["name"] == "retention"))]
      [ret] = ToolVisibility.filter_for_context(tools, ctx)
      actions = action_enum(ret)

      assert "cleanup" in actions
    end
  end
end
