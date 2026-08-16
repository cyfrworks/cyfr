# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolVisibilityTest do
  # Not async: reads the live registry cache the application owns.
  use ExUnit.Case, async: false

  alias Emissary.MCP.ToolRegistry
  alias Emissary.MCP.ToolVisibility
  alias Sanctum.Context

  # ============================================================================
  # Fixtures — live registry, not hand-copied samples. A hand-kept fixture
  # list drifted (it taught retired actions for years); deriving from
  # ToolRegistry.list_tools/0 means these tests exercise the same tool
  # definitions production serves.
  # ============================================================================

  defp live_tools do
    ToolRegistry.list_tools()
    |> Enum.reject(&String.contains?(&1["name"], ":"))
  end

  defp live_tool(name), do: Enum.find(live_tools(), &(&1["name"] == name))

  defp make_tool(name, actions, annotations \\ nil) do
    %{
      "name" => name,
      "description" => "Test tool: #{name}",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => actions}
        },
        "required" => ["action"]
      }
    }
    |> then(fn tool ->
      if annotations, do: Map.put(tool, "annotations", annotations), else: tool
    end)
  end

  defp make_tool_no_actions(name) do
    %{
      "name" => name,
      "description" => "External tool: #{name}",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  end

  defp ctx_with(permissions, auth_method \\ :api_key) do
    Context.build(
      user_id: "test_user",
      permissions: permissions,
      auth_method: auth_method,
      namespace: "testns",
      authenticated: true
    )
  end

  defp anonymous_ctx do
    Context.build(
      user_id: nil,
      athanor_id: nil,
      permissions: [],
      auth_method: nil,
      authenticated: false
    )
  end

  defp action_enum(tool_def) do
    get_in(tool_def, ["inputSchema", "properties", "action", "enum"])
  end

  defp visible_actions(name, ctx) do
    case ToolVisibility.filter_for_context([live_tool(name)], ctx) do
      [tool] -> action_enum(tool) || []
      [] -> []
    end
  end

  # ============================================================================
  # Permission-gated visibility (live definitions)
  # ============================================================================

  describe "execute-only context" do
    @tag :requires_opus_modules
    test "sees execution actions minus the admin-gated force_release" do
      actions = visible_actions("execution", ctx_with([:execute]))
      assert "run" in actions
      assert "status" in actions
      refute "force_release" in actions
    end

    @tag :requires_opus_modules
    test "sees all schedule actions and the build tool whole" do
      assert length(visible_actions("schedule", ctx_with([:execute]))) == 8

      build = visible_actions("build", ctx_with([:execute]))
      assert "compile" in build
      assert "validate" in build
      assert "toolchains" in build
    end

    test "does not see tools whose every action needs another permission" do
      names =
        live_tools()
        |> ToolVisibility.filter_for_context(ctx_with([:execute]))
        |> Enum.map(& &1["name"])

      refute "key" in names
      refute "record" in names
    end

    test "sees every session action — the anonymous ones and `use`" do
      assert Enum.sort(visible_actions("session", ctx_with([:execute]))) ==
               ~w(device_init device_poll login logout use whoami)
    end

    test "operator-only actions are shown to platform admins alone" do
      member = ctx_with([:*])
      admin = %{member | platform_admin: true}

      assert visible_actions("door", member) == []

      assert Enum.sort(visible_actions("door", admin)) ==
               ~w(allow deny list remove requests resolve)
    end
  end

  describe "no permissions context" do
    test "sees only open and anonymous actions" do
      ctx = ctx_with([])
      names = live_tools() |> ToolVisibility.filter_for_context(ctx) |> Enum.map(& &1["name"])

      assert "aqua" in names
      assert "system" in names
      assert "tools" in names
      assert "mcp_servers" in names
      refute "key" in names
      refute "record" in names
      refute "retention" in names
    end

    test "component shows open reads, hides gated reads and writes" do
      actions = visible_actions("component", ctx_with([]))
      assert "search" in actions
      assert "inspect" in actions
      assert "list" in actions
      refute "get_blob" in actions
      refute "pull" in actions
      refute "push" in actions
      refute "deprecate" in actions
      refute "yank" in actions
    end

    test "audit logs are hidden without :storage_read" do
      assert visible_actions("mcp_log", ctx_with([])) == []
      assert visible_actions("policy_log", ctx_with([])) == []
    end
  end

  describe "mixed permissions" do
    test "component_read adds the gated reads, not the writes" do
      actions = visible_actions("component", ctx_with([:component_read]))
      assert "search" in actions
      assert "get_blob" in actions
      assert "discover" in actions
      refute "pull" in actions
      refute "push" in actions
    end

    test "retention splits get/set/cleanup across three permissions" do
      assert visible_actions("retention", ctx_with([:storage_read])) == ["get"]
      assert "cleanup" in visible_actions("retention", ctx_with([:admin]))
      assert "set" in visible_actions("retention", ctx_with([:storage_write]))
    end
  end

  # ============================================================================
  # Consent-class visibility mirrors the Authz surface arms
  # ============================================================================

  describe "consent-class actions" do
    test "an OIDC session sees the whole vault and profile surface" do
      ctx = ctx_with([], :oidc)
      assert length(visible_actions("vault", ctx)) == 8
      assert length(visible_actions("profile", ctx)) == 6
    end

    test "an API key sees only the staging arms — whatever its permissions" do
      # An :admin key being shown vault.rotate and refused on call was the
      # drift this derivation exists to prevent: Authz admits surfaces by
      # auth_method, so :* does not short-circuit consent visibility.
      for perms <- [[], [:admin], [:*]] do
        ctx = ctx_with(perms, :api_key)
        assert visible_actions("vault", ctx) == ["list"]

        profile = visible_actions("profile", ctx)
        assert "plan" in profile
        assert "commit" in profile
        refute "revoke" in profile
      end
    end

    test "an anonymous caller sees neither" do
      assert visible_actions("vault", anonymous_ctx()) == []
      assert visible_actions("profile", anonymous_ctx()) == []
    end
  end

  # ============================================================================
  # Structural behavior (hand fixtures)
  # ============================================================================

  describe "unclassified actions are invisible (default-deny pin)" do
    test "a tool without annotations is hidden from everyone" do
      tools = [make_tool("imaginary", ["made_up_action"])]
      assert ToolVisibility.filter_for_context(tools, anonymous_ctx()) == []
      assert ToolVisibility.filter_for_context(tools, ctx_with([:admin, :execute])) == []
    end

    test "an unannotated action is pruned from a tool that keeps its declared ones" do
      annotations = %{actions: %{"status" => %{kind: :read, planes: [:external]}}}
      tools = [make_tool("imaginary", ["status", "made_up_action"], annotations)]

      [tool] = ToolVisibility.filter_for_context(tools, ctx_with([]))
      assert action_enum(tool) == ["status"]
    end
  end

  describe "external tools" do
    test "a tool with no action enum passes through for authenticated callers" do
      ext = make_tool_no_actions("notion:create_page")
      assert ToolVisibility.filter_for_context([ext], ctx_with([])) == [ext]
    end

    test "a tool with no action enum is hidden from anonymous callers" do
      ext = make_tool_no_actions("notion:create_page")
      assert ToolVisibility.filter_for_context([ext], anonymous_ctx()) == []
    end
  end

  # ============================================================================
  # Completeness: the audit is the classification
  # ============================================================================

  describe "classification completeness" do
    @tag :requires_opus_modules
    test "every registered action carries a complete access declaration" do
      assert ToolRegistry.audit_action_kinds() == :ok
    end
  end

  # ============================================================================
  # Discovery = invocation, by construction and by test
  # ============================================================================

  describe "dispatch parity" do
    # For every registered action and a spread of caller shapes, discovery
    # and dispatch must agree: an action a caller is shown, dispatch would
    # authorize; an action dispatch refuses, discovery hides. Contexts are
    # built with explicit scopes — Sanctum.TestContext.local/0 holds :* and
    # would prove nothing.
    test "a caller is shown exactly the actions dispatch would authorize" do
      probes = [
        anonymous_ctx(),
        ctx_with([]),
        ctx_with([], :oidc),
        ctx_with([:execute]),
        ctx_with([:storage_read]),
        ctx_with([:admin]),
        ctx_with([:component_manage], :oidc)
      ]

      for tool_def <- live_tools(),
          name = tool_def["name"],
          {:ok, {_module, meta}} = Arca.Cache.get({:mcp_tool, name}),
          action <- action_enum(tool_def) || [],
          ctx <- probes do
        visible = action in visible_actions(name, ctx)

        authorized =
          ToolRegistry.authorize_annotated_action(name, meta, ctx, %{"action" => action}) == :ok

        assert visible == authorized,
               "#{name}.#{action}: discovery says #{inspect(visible)} but dispatch says " <>
                 "#{inspect(authorized)} for auth_method=#{inspect(ctx.auth_method)} " <>
                 "permissions=#{inspect(ctx.permissions)} authenticated=#{ctx.authenticated}"
      end
    end
  end

  describe "the anonymous surface is one fact" do
    test "anonymous_action? and the auth annotation are the same answer" do
      for tool_def <- live_tools(),
          name = tool_def["name"],
          action <- action_enum(tool_def) || [] do
        {:ok, {_module, meta}} = Arca.Cache.get({:mcp_tool, name})
        declared = get_in(meta, [:annotations, :actions, action, :auth]) == :anonymous

        assert ToolVisibility.anonymous_action?(name, action) == declared,
               "#{name}.#{action}: anonymous_action? disagrees with the annotation"
      end
    end

    test "the anonymous set is exactly session plus the health check" do
      anonymous =
        for tool_def <- live_tools(),
            name = tool_def["name"],
            action <- action_enum(tool_def) || [],
            ToolVisibility.anonymous_action?(name, action),
            into: MapSet.new() do
          "#{name}.#{action}"
        end

      expected =
        MapSet.new(~w(
          session.login session.logout session.whoami
          session.device_init session.device_poll
          system.status
        ))

      assert anonymous == expected
    end

    test "an uncredentialed caller is shown only what it may call" do
      filtered = ToolVisibility.filter_for_context(live_tools(), anonymous_ctx())

      for tool <- filtered, action <- action_enum(tool) || [] do
        assert ToolVisibility.anonymous_action?(tool["name"], action),
               "discovery offered #{tool["name"]}.#{action} to an anonymous caller, " <>
                 "which tools/call refuses"
      end

      names = Enum.map(filtered, & &1["name"])
      assert "session" in names
      assert "system" in names
      refute "aqua" in names
      refute "component" in names
      refute "key" in names
      refute "tools" in names
    end
  end
end
