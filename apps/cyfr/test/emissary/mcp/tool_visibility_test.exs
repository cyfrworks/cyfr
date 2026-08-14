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
        "delete",
        "create"
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

    test "mcp_log is dropped — every action requires :storage_read", %{filtered: filtered} do
      # correlate/fan_outs/stats join list/get behind :storage_read, so an
      # unauthenticated caller sees no audit-log actions and the tool is dropped.
      refute Enum.find(filtered, &(&1["name"] == "mcp_log"))
    end

    test "policy_log is dropped — every action requires :storage_read", %{filtered: filtered} do
      refute Enum.find(filtered, &(&1["name"] == "policy_log"))
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

  describe "unclassified actions are invisible (default-deny pin)" do
    # Structural pin, independent of the completeness audit below: an action
    # placed in NEITHER @action_permissions NOR @public_actions must be
    # pruned for every non-wildcard caller — a forgotten classification can
    # hide an action, never expose one.
    test "unknown action pruned for an anonymous caller" do
      ctx = ctx_with([])
      tools = [make_tool("imaginary", ["made_up_action"])]
      assert ToolVisibility.filter_for_context(tools, ctx) == []
    end

    test "unknown action pruned even for a broadly-permissioned caller" do
      ctx = ctx_with([:execute, :admin, :storage_read, :component_manage])
      tools = [make_tool("imaginary", ["made_up_action", "another_one"])]
      assert ToolVisibility.filter_for_context(tools, ctx) == []
    end

    test "unknown action pruned from a tool that keeps its classified ones" do
      ctx = ctx_with([])
      tools = [make_tool("system", ["status", "made_up_action"])]
      [system] = ToolVisibility.filter_for_context(tools, ctx)
      assert action_enum(system) == ["status"]
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

  describe "classification completeness" do
    @tag :requires_opus_modules
    test "every registered tool.action is classified as gated or public" do
      registered =
        Application.get_env(:cyfr, :tool_providers, [])
        |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :tools, 0)))
        |> Enum.flat_map(& &1.tools())
        |> Enum.flat_map(fn tool ->
          name = tool[:name] || tool["name"]

          actions =
            get_in(tool, [:input_schema, "properties", "action", "enum"]) ||
              get_in(tool, ["inputSchema", "properties", "action", "enum"]) || []

          Enum.map(actions, &"#{name}.#{&1}")
        end)
        |> MapSet.new()

      classified =
        MapSet.union(
          MapSet.new(Map.keys(ToolVisibility.action_permissions())),
          ToolVisibility.public_actions()
        )

      unclassified = MapSet.difference(registered, classified)
      stale = MapSet.difference(classified, registered)

      assert MapSet.size(unclassified) == 0, """
      New tool actions are unclassified — they would be HIDDEN from discovery:

        #{unclassified |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}

      Add each to @action_permissions (with its permission) or @public_actions.
      """

      assert MapSet.size(stale) == 0, """
      These classified actions are no longer registered — remove them:

        #{stale |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}
      """
    end
  end

  describe "the anonymous surface is one fact" do
    # Discovery and invocation read the same declaration, and that
    # declaration may only name doors the dispatcher actually opens: a tool
    # registered `requires_auth: true` refuses every anonymous call, so
    # promising one here would advertise a schema for a call that 401s.
    @tag :requires_opus_modules
    test "every anonymously-reachable tool is registered requires_auth: false" do
      auth_free =
        Application.get_env(:cyfr, :tool_providers, [])
        |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :tools, 0)))
        |> Enum.flat_map(& &1.tools())
        |> Enum.filter(&(Map.get(&1, :requires_auth, true) == false))
        |> Enum.map(&(&1[:name] || &1["name"]))
        |> MapSet.new()

      promised = ToolVisibility.anonymous_actions() |> Map.keys() |> MapSet.new()
      broken = MapSet.difference(promised, auth_free)

      assert MapSet.size(broken) == 0, """
      These tools are declared anonymously reachable but the dispatcher
      refuses them without a credential:

        #{broken |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}

      Either drop them from @anonymous_actions or register the tool with
      requires_auth: false.
      """
    end

    test "an uncredentialed caller is shown only what it may call" do
      anonymous =
        Context.build(
          user_id: nil,
          org_id: nil,
          permissions: [],
          auth_method: nil,
          authenticated: false
        )

      filtered = ToolVisibility.filter_for_context(sample_tools(), anonymous)

      for tool <- filtered, action <- action_enum(tool) || [] do
        assert ToolVisibility.anonymous_action?(tool["name"], action),
               "discovery offered #{tool["name"]}.#{action} to an anonymous caller, " <>
                 "which tools/call refuses"
      end

      names = Enum.map(filtered, & &1["name"])
      assert "session" in names
      assert "system" in names
      # Writes that invocation would refuse are no longer advertised.
      refute "aqua" in names
      refute "component" in names
      refute "key" in names
    end
  end
end
