# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.VisibilityTest do
  # Not async: reads the live registry cache the application owns.
  use ExUnit.Case, async: false

  alias Sanctum.Annotations
  alias Sanctum.Catalog
  alias Sanctum.Visibility
  alias Sanctum.Context

  # Derive fixtures from Catalog.list_tools/0 to check the definitions served at runtime.

  defp live_tools do
    Catalog.list_tools()
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

  # A paired device's context: the device channel's surface, naming its
  # paired client.
  defp paired_device_ctx(permissions),
    do: %{ctx_with(permissions, :device) | client_id: "pcl_probe"}

  defp anonymous_ctx do
    Context.build(
      user_id: nil,
      athanor_id: nil,
      permissions: [],
      auth_method: nil,
      authenticated: false
    )
  end

  # A session ahead of its claim, or a door-denied person's: a user and no
  # authentication.
  defp unclaimed_ctx do
    Context.build(
      user_id: "test_user",
      permissions: [],
      auth_method: :oidc,
      authenticated: false
    )
  end

  # What the action's own annotation declares, read apart from discovery.
  defp anonymous?(name, action) do
    {:ok, {_module, meta}} = Catalog.lookup(name)
    Annotations.auth(meta, action) == :anonymous
  end

  defp action_enum(tool_def) do
    get_in(tool_def, ["inputSchema", "properties", "action", "enum"])
  end

  defp visible_actions(name, ctx), do: shown_actions(live_tool(name), ctx)

  defp shown_actions(tool_def, ctx) do
    case Visibility.filter_for_context([tool_def], ctx) do
      [tool] -> action_enum(tool) || []
      [] -> []
    end
  end

  # ============================================================================
  # Permission-gated visibility (live definitions)
  # ============================================================================

  describe "execute-only context" do
    test "sees execution actions minus the admin-gated force_release" do
      actions = visible_actions("execution", ctx_with([:execute]))
      assert "run" in actions
      assert "status" in actions
      refute "force_release" in actions
    end

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
        |> Visibility.filter_for_context(ctx_with([:execute]))
        |> Enum.map(& &1["name"])

      refute "key" in names
      refute "record" in names
    end

    test "sees every session action — the anonymous ones and `use`" do
      assert Enum.sort(visible_actions("session", ctx_with([:execute]))) ==
               ~w(cli_begin cli_cancel cli_poll device_init device_poll login logout read_resource use whoami)
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
      names = live_tools() |> Visibility.filter_for_context(ctx) |> Enum.map(& &1["name"])

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
  # Consent-class visibility: the Authz surface arms the gate asks
  # ============================================================================

  describe "consent-class actions" do
    test "an OIDC session sees the whole vault and profile surface" do
      ctx = ctx_with([], :oidc)
      assert length(visible_actions("vault", ctx)) == 10
      assert length(visible_actions("profile", ctx)) == 8

      # Moving a provider's default needs the session and nothing more
      # (`consent: :interactive`, no fresh confirmation): a session sees it,
      # and an API key, held to the staging arms below, does not.
      assert "set_default" in visible_actions("vault", ctx)
    end

    test "an API key sees only the staging arms and the consent-free status — whatever its permissions" do
      # An :admin key being shown vault.rotate and refused on call was the
      # drift this derivation exists to prevent: Authz admits surfaces by
      # auth_method, so :* does not short-circuit consent visibility.
      for perms <- [[], [:admin], [:*]] do
        ctx = ctx_with(perms, :api_key)
        assert visible_actions("vault", ctx) == ["list", "status"]

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

    test "a paired device sees what its person's session sees: the whole surface" do
      device = paired_device_ctx([])

      assert visible_actions("vault", device) == visible_actions("vault", ctx_with([], :oidc))
      assert visible_actions("profile", device) == visible_actions("profile", ctx_with([], :oidc))
      assert length(visible_actions("vault", device)) == 10
      assert "commit" in visible_actions("profile", device)
      assert "revoke" in visible_actions("pairing", device)
    end

    test "a paired client is the device channel's alone: a context claiming the other half sees no consent arm" do
      # What a surface no consent arm admits sees: the consent-free actions.
      unconsenting = visible_actions("vault", ctx_with([], :scheduled))
      refute "create" in unconsenting

      for ctx <- [ctx_with([], :device), %{ctx_with([], :oidc) | client_id: "pcl_probe"}] do
        assert visible_actions("vault", ctx) == unconsenting, inspect(ctx.auth_method)
        refute "commit" in visible_actions("profile", ctx)
        refute "plan" in visible_actions("profile", ctx)
        refute "begin" in visible_actions("pairing", ctx)
      end
    end

    test "inside a chain the in-chain arm is the session's alone" do
      guest = Context.enter_guest(paired_device_ctx([]))
      refute "revoke" in visible_actions("vault", guest)

      session_chain = Context.enter_guest(ctx_with([], :oidc))
      assert visible_actions("vault", session_chain) != []
    end
  end

  # ============================================================================
  # Structural behavior (hand fixtures)
  # ============================================================================

  describe "unclassified actions are invisible (default-deny pin)" do
    test "a tool without annotations is hidden from everyone" do
      tools = [make_tool("imaginary", ["made_up_action"])]
      assert Visibility.filter_for_context(tools, anonymous_ctx()) == []
      assert Visibility.filter_for_context(tools, ctx_with([:admin, :execute])) == []
    end

    test "an unannotated action is pruned from a tool that keeps its declared ones" do
      annotations = %{actions: %{"status" => %{kind: :read, planes: [:external]}}}
      tools = [make_tool("imaginary", ["status", "made_up_action"], annotations)]

      [tool] = Visibility.filter_for_context(tools, ctx_with([]))
      assert action_enum(tool) == ["status"]
    end
  end

  describe "external tools" do
    test "a tool with no action enum passes through for authenticated callers" do
      ext = make_tool_no_actions("notion:create_page")
      assert Visibility.filter_for_context([ext], ctx_with([])) == [ext]
    end

    test "a tool with no action enum is hidden from anonymous callers" do
      ext = make_tool_no_actions("notion:create_page")
      assert Visibility.filter_for_context([ext], anonymous_ctx()) == []
    end
  end

  # ============================================================================
  # Completeness: the audit is the classification
  # ============================================================================

  describe "classification completeness" do
    test "every registered action carries a complete access declaration" do
      assert Catalog.audit_action_kinds() == :ok
    end
  end

  # ============================================================================
  # Discovery = invocation, by construction and by test
  # ============================================================================

  # Every kind of caller an ingress produces: no credential; a session ahead
  # of its claim; a browser session; a paired device, and each half of one
  # without the other; an API key; a schedule; a webhook; a tincture a
  # person invokes and a public one (`anonymous: true`); the system; and a
  # tincture session's upgrade. Each holds no permission, one, or the
  # wildcard, as a member and as a platform administrator, on the external
  # plane and inside a running chain. Contexts are built with explicit
  # permissions: Sanctum.TestContext.local/0 holds :* and would prove nothing.
  defp live_callers do
    kinds = [
      anonymous_ctx(),
      unclaimed_ctx(),
      ctx_with([], :oidc),
      paired_device_ctx([]),
      ctx_with([], :device),
      %{ctx_with([], :oidc) | client_id: "pcl_probe"},
      ctx_with([], :api_key),
      ctx_with([], :scheduled),
      ctx_with([], :webhook),
      ctx_with([], :tincture),
      %{ctx_with([:execute], :tincture) | anonymous: true},
      ctx_with([], :system),
      ctx_with([], :session)
    ]

    for kind <- kinds,
        permissions <- [[], [:execute], [:storage_read], [:admin], [:component_manage], [:*]],
        platform_admin <- [false, true],
        ctx = %{kind | permissions: MapSet.new(permissions), platform_admin: platform_admin},
        plane_ctx <- [ctx, Context.enter_guest(ctx)],
        do: plane_ctx
  end

  # The fields a refusal depends on, to name a caller in a failure.
  defp caller(%Context{} = ctx) do
    ctx
    |> Map.take(~w(plane authenticated user_id anonymous auth_method client_id platform_admin)a)
    |> Map.put(:permissions, Enum.sort(ctx.permissions))
  end

  # At most `limit` of `cases`, with their count, for a failure message.
  defp sample(cases, limit \\ 12) do
    "#{length(cases)} cases, the first #{min(limit, length(cases))}:\n" <>
      Enum.map_join(Enum.take(Enum.reverse(cases), limit), "\n", &inspect/1)
  end

  describe "dispatch parity" do
    # For every registered action and every kind of caller, discovery and
    # dispatch agree: an action a caller is shown, dispatch would authorize;
    # an action dispatch refuses, discovery hides. A context on the guest
    # plane is a running chain's (`call_external/4` refuses it), so it is
    # asked as `call_in_chain/5` asks, on the actions its plane reaches.
    test "a caller is shown exactly the actions dispatch would authorize" do
      callers = live_callers()

      {disagreements, seen} =
        for tool_def <- live_tools(),
            name = tool_def["name"],
            {:ok, {_module, meta}} = Catalog.lookup(name),
            ctx <- callers,
            reduce: {[], MapSet.new()} do
          acc ->
            shown = shown_actions(tool_def, ctx)
            in_chain? = ctx.plane == :guest

            for action <- action_enum(tool_def) || [],
                not in_chain? or Catalog.in_chain_reachable?(name, action),
                reduce: acc do
              {disagreements, seen} ->
                visible = action in shown
                args = %{"action" => action}
                answer = Catalog.authorize_annotated_action(name, meta, ctx, args, in_chain?)
                seen = MapSet.put(seen, {ctx.plane, visible})
                entry = {"#{name}.#{action}", caller(ctx), shown: visible, gate: answer}

                if visible == (answer == :ok),
                  do: {disagreements, seen},
                  else: {[entry | disagreements], seen}
            end
        end

      assert disagreements == [], "discovery and dispatch disagree in " <> sample(disagreements)

      # Not vacuous: on each plane, some action is shown and some hidden.
      assert seen ==
               MapSet.new(
                 for plane <- [:external, :guest], shown <- [true, false], do: {plane, shown}
               )
    end
  end

  # ============================================================================
  # One predicate: every annotation against every caller
  # ============================================================================

  # Every annotation over the fields admission reads: `auth` (absent, so its
  # default, or each value), `scope`, `permission` and `consent`, each absent
  # or each value, and `planes`; and an action with no annotation at all.
  defp synthetic_annotations do
    annotated =
      for auth <- [:absent, :required, :signed_in, :anonymous],
          scope <- [nil, :platform],
          permission <- [nil, :execute],
          consent <- [nil, :interactive, :staging],
          planes <- [[:external], [:in_chain], [:external, :in_chain]] do
        [auth: auth, scope: scope, permission: permission, consent: consent]
        |> Enum.reject(fn {_field, value} -> value in [nil, :absent] end)
        |> Map.new()
        |> Map.merge(%{kind: :read, planes: planes})
      end

    [nil | annotated]
  end

  # Every caller over the fields admission reads: the plane; the identity
  # (authenticated with a user, a user without authentication, neither),
  # anonymous or not; every authentication method; a paired client or none;
  # platform administration; and no permission, the one the annotations
  # name, another, or the wildcard.
  defp synthetic_callers do
    for plane <- [:external, :guest],
        {authenticated, user_id} <- [{true, "test_user"}, {false, "test_user"}, {false, nil}],
        anonymous <- [false, true],
        auth_method <- [
          :oidc,
          :device,
          :api_key,
          :scheduled,
          :webhook,
          :tincture,
          :system,
          :session,
          nil
        ],
        client_id <- [nil, "pcl_probe"],
        platform_admin <- [false, true],
        permissions <- [[], [:execute], [:admin], [:*]] do
      Context.build(
        user_id: user_id,
        permissions: permissions,
        auth_method: auth_method,
        authenticated: authenticated,
        anonymous: anonymous,
        client_id: client_id,
        platform_admin: platform_admin,
        plane: plane
      )
    end
  end

  # One action, `probe.act`, carrying `annotation`: its wire definition,
  # which discovery reads, and its table entry, which the gate reads.
  defp probe_tool(nil), do: make_tool("probe", ["act"])
  defp probe_tool(annotation), do: make_tool("probe", ["act"], %{actions: %{"act" => annotation}})

  defp probe_meta(nil), do: %{}
  defp probe_meta(annotation), do: %{annotations: %{actions: %{"act" => annotation}}}

  # The gate's answer, asked as the caller's plane asks it.
  defp gate(annotation, ctx) do
    Catalog.authorize_annotated_action(
      "probe",
      probe_meta(annotation),
      ctx,
      %{"action" => "act"},
      ctx.plane == :guest
    )
  end

  defp shown?(annotation, ctx),
    do: Visibility.filter_for_context([probe_tool(annotation)], ctx) != []

  # The gate's answer, check by check: an action without a declaration, or
  # outside the caller's plane, is unknown; then auth, scope, permission and
  # consent, in that order, the first that refuses naming the refusal.
  defp expected(nil, _ctx), do: {:error, {:unknown_action, "probe.act"}}

  defp expected(annotation, ctx) do
    in_chain? = ctx.plane == :guest
    permission = Map.get(annotation, :permission)

    cond do
      not in_chain? and :external not in annotation.planes ->
        {:error, {:unknown_action, "probe.act"}}

      not auth_admits?(Map.get(annotation, :auth, :required), ctx) ->
        {:error, {:tool_auth_required, "probe"}}

      Map.get(annotation, :scope) == :platform and not ctx.platform_admin ->
        {:error, :platform_admin_required}

      permission != nil and not Context.has_permission?(ctx, permission) ->
        {:error, {:missing_permission, permission}}

      true ->
        case consent_refusal(Map.get(annotation, :consent), ctx, in_chain?) do
          nil -> :ok
          refusal -> {:error, {:consent_class_required, refusal}}
        end
    end
  end

  defp auth_admits?(:anonymous, _ctx), do: true
  defp auth_admits?(:signed_in, ctx), do: ctx.authenticated or is_binary(ctx.user_id)
  defp auth_admits?(:required, ctx), do: ctx.authenticated

  # Who may act under a consent class (`Sanctum.Consent.Authz`): staging
  # never inside a chain; then a caller authenticated on a credential of
  # its own; then, inside a chain, a session alone, and outside one the
  # surfaces the class admits, a paired client being the device channel's
  # alone.
  defp consent_refusal(nil, _ctx, _in_chain?), do: nil
  defp consent_refusal(:staging, %Context{plane: :guest}, _in_chain?), do: :guest_plane
  defp consent_refusal(_class, %Context{authenticated: false}, _in_chain?), do: :not_authenticated
  defp consent_refusal(_class, %Context{anonymous: true}, _in_chain?), do: :anonymous
  defp consent_refusal(:interactive, %Context{auth_method: :oidc}, true), do: nil

  defp consent_refusal(:interactive, %Context{auth_method: method}, true),
    do: {:surface_not_permitted, method}

  defp consent_refusal(class, %Context{auth_method: method, client_id: client_id}, false) do
    surface =
      cond do
        method == :device and is_binary(client_id) -> :device
        method != :device and is_nil(client_id) -> method
        true -> nil
      end

    admitted = if class == :interactive, do: [:oidc, :device], else: [:oidc, :device, :api_key]
    if surface != nil and surface in admitted, do: nil, else: {:surface_not_permitted, method}
  end

  describe "one predicate for discovery and the gate" do
    test "the gate answers every annotation and caller with its first refusing check, in auth, scope, permission, consent order" do
      callers = synthetic_callers()

      differing =
        for annotation <- synthetic_annotations(), ctx <- callers, reduce: [] do
          acc ->
            answer = gate(annotation, ctx)

            if answer == expected(annotation, ctx),
              do: acc,
              else: [{annotation, caller(ctx), answer} | acc]
        end

      assert differing == [],
             "the gate answers other than its checks name in " <> sample(differing)
    end

    test "discovery shows exactly what the gate admits, over every annotation and caller" do
      callers = synthetic_callers()

      disagreements =
        for annotation <- synthetic_annotations(), ctx <- callers, reduce: [] do
          acc ->
            shown = shown?(annotation, ctx)
            answer = gate(annotation, ctx)

            if shown == (answer == :ok),
              do: acc,
              else: [{annotation, caller(ctx), shown: shown, gate: answer} | acc]
        end

      assert disagreements == [], "discovery and the gate disagree in " <> sample(disagreements)
    end
  end

  describe "the anonymous surface is one fact" do
    test "the anonymous set is exactly session, the health check, a public tincture, a pairing's completion and a certificate's renewal" do
      anonymous =
        for tool_def <- live_tools(),
            name = tool_def["name"],
            action <- action_enum(tool_def) || [],
            anonymous?(name, action),
            into: MapSet.new() do
          "#{name}.#{action}"
        end

      expected =
        MapSet.new(~w(
          session.logout session.whoami
          session.device_init session.device_poll session.read_resource
          session.cli_begin session.cli_poll session.cli_cancel
          system.status tincture.invoke_public pairing.complete
          person.renew_certificate
        ))

      assert anonymous == expected
    end

    test "an uncredentialed caller is shown only what it may call" do
      filtered = Visibility.filter_for_context(live_tools(), anonymous_ctx())

      for tool <- filtered, action <- action_enum(tool) || [] do
        assert anonymous?(tool["name"], action),
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
