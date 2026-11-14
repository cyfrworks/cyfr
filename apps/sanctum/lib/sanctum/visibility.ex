# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Visibility do
  @moduledoc """
  The one authorization predicate over an action's access annotation
  (`authorize/4`), and what a caller may see in `tools/list`.

  The gate (`Sanctum.Catalog`) asks `authorize/4` before a handler runs,
  and discovery asks it of every action it lists, so a caller is shown
  exactly the doors dispatch would open for them. It reads the
  annotation's `auth`, `scope`, `permission` and `consent`, in that order,
  and the first that refuses names the refusal:

  - `auth: :anonymous` serves everyone, `:signed_in` an authenticated
    caller or a session that has not claimed its namespace yet, and
    `:required` (the default) an authenticated caller.
  - `scope: :platform` serves a platform administrator alone.
  - `permission:` requires the named permission.
  - `consent:` requires a surface `Sanctum.Consent.Authz` admits:
    `:interactive` an OIDC session or a paired device, and inside a
    running chain the session alone; `:staging` those or an API key, and
    never inside a chain.

  Discovery also serves a caller outside a running chain only actions whose
  planes include `:external`, as dispatch does; a running chain's view is
  pruned to its own plane by `Sanctum.Catalog`. Unannotated actions are
  invisible and refused by dispatch.

  The completeness audit (`Sanctum.Catalog.audit_action_kinds/0`,
  asserted `:ok` in CI) guarantees every registered action carries a full
  declaration, so nothing falls through to an accidental default.

  An outside server's tools (namespaced with `:`, no action enum) carry no
  per-action classification: outside a running chain a caller is shown
  those `external_tools/1` answers, the ones a call is admitted for now,
  and `filter_for_context/2` hides them from a caller with no credential.
  """

  alias Sanctum.Annotations
  alias Sanctum.Context

  @doc """
  May this caller act under this access annotation? The gate's
  authorization of a declared action
  (`Sanctum.Catalog.authorize_annotated_action/5`) and of a stream open,
  and discovery's of every action it lists: `auth`, then `scope`,
  `permission` and `consent`, the first refusal answered. `name` is the
  operation the authentication refusal names; `in_chain?` asks the consent
  class as a call inside a running chain is asked.
  """
  @spec authorize(String.t(), map(), Context.t(), boolean()) ::
          :ok | {:error, Sanctum.Unauthorized.reason()}
  def authorize(name, annotation, %Context{} = ctx, in_chain?)
      when is_map(annotation) and is_boolean(in_chain?) do
    with :ok <- check_auth(name, ctx, annotation),
         :ok <- check_scope(ctx, annotation),
         :ok <- check_permission(ctx, annotation) do
      check_consent(ctx, annotation, in_chain?)
    end
  end

  # Authenticated callers always pass; `:anonymous` actions serve anyone;
  # `:signed_in` actions serve a session that has not claimed its
  # namespace yet (`user_id` set, `authenticated: false`).
  defp check_auth(name, ctx, annotation) do
    admitted =
      case Map.get(annotation, :auth, :required) do
        :anonymous -> true
        :signed_in -> ctx.authenticated or is_binary(ctx.user_id)
        _ -> ctx.authenticated
      end

    if admitted, do: :ok, else: {:error, {:tool_auth_required, name}}
  end

  # `scope: :platform` is the operator capability, not a widened tenant scope:
  # the caller still works inside one athanor and only the mark on their
  # person row (`platform_admin`) admits them.
  defp check_scope(ctx, annotation) do
    case Map.get(annotation, :scope) do
      nil -> :ok
      :platform when ctx.platform_admin -> :ok
      :platform -> {:error, :platform_admin_required}
    end
  end

  defp check_permission(ctx, annotation) do
    case Map.get(annotation, :permission) do
      nil -> :ok
      permission -> Context.require_permission(ctx, permission, :in_chain)
    end
  end

  # Consent is decided on how the caller authenticated, never by permission
  # atom, so `:*` does not short-circuit it. The typed refusals are kept for
  # rendering through `Sanctum.Consent.Authz.message/1`. In-chain interactive
  # calls keep the surface check; the approved proposal supplies consent for
  # the guest plane. Staging actions require the full surface and plane
  # checks and are unavailable in-chain.
  defp check_consent(ctx, annotation, in_chain?) do
    case Map.get(annotation, :consent) do
      nil ->
        :ok

      :interactive ->
        interactive =
          if in_chain?,
            do: Sanctum.Consent.Authz.authorize_interactive_in_chain(ctx),
            else: Sanctum.Consent.Authz.authorize_interactive(ctx)

        case interactive do
          {:ok, :interactive} -> :ok
          {:error, refusal} -> {:error, {:consent_class_required, refusal}}
        end

      :staging ->
        case Sanctum.Consent.Authz.authorize_staging(ctx) do
          :ok -> :ok
          {:error, refusal} -> {:error, {:consent_class_required, refusal}}
        end
    end
  end

  @doc """
  The outside servers' tools a caller outside a running chain can call
  now, as discovery lists them: of those the proxy port lists for the
  caller's athanor (`c:Sanctum.Proxy.list_external_tools/1`), each the
  gate admits this caller to (`Sanctum.Catalog.authorize_proxied/3`) and
  that resolves on the external plane (`c:Sanctum.Proxy.resolve/4`: its
  server enabled, the tool one the server exposes, the server's `console`
  setting on). A caller with no athanor, or not admitted to outside tools
  at all, is shown none and starts no server.
  """
  @spec external_tools(Context.t()) :: [map()]
  def external_tools(%Context{athanor_id: athanor_id} = ctx)
      when is_binary(athanor_id) and athanor_id != "" do
    # The admission reads no tool name but for its refusal's sentence,
    # which discovery does not show.
    with :ok <- Sanctum.Catalog.authorize_proxied("tools/list", ctx, false),
         {:ok, rows} <- Arca.McpServerStorage.list(Context.actor(ctx)) do
      proxy = Sanctum.Proxy.impl!()
      servers = Map.new(rows, &{&1.name, &1})

      ctx
      |> proxy.list_external_tools()
      |> Enum.filter(fn %{"name" => name} ->
        [server, _tool] = String.split(name, ":", parts: 2)

        Sanctum.Catalog.authorize_proxied(name, ctx, false) == :ok and
          match?({:ok, _}, proxy.resolve(name, ctx, :external, server: Map.get(servers, server)))
      end)
    else
      _refused -> []
    end
  end

  def external_tools(%Context{}), do: []

  @doc """
  Filter tool definitions to only include tools/actions the caller can see.

  - For each tool: prunes the action enum to actions `authorize/4` admits
    this caller to, drops tools with none remaining.
  - Tools with no action enum (external `server:tool` proxies) pass through
    unchanged for authenticated callers and are hidden from anonymous ones.
  """
  @spec filter_for_context([map()], Context.t()) :: [map()]
  def filter_for_context(tools, %Context{} = ctx) do
    tools
    |> Enum.map(&filter_tool(&1, ctx))
    |> Enum.reject(&is_nil/1)
  end

  defp filter_tool(tool_def, ctx) do
    case extract_actions(tool_def) do
      nil ->
        if ctx.authenticated, do: tool_def, else: nil

      actions when is_list(actions) ->
        name = tool_def["name"]
        annotations = Annotations.actions_of(tool_def)
        visible = Enum.filter(actions, &visible_action?(name, Map.get(annotations, &1), ctx))

        case visible do
          [] -> nil
          ^actions -> tool_def
          filtered -> restrict_actions(tool_def, filtered)
        end
    end
  end

  # Unclassified action: invisible, matching the dispatch refusal.
  defp visible_action?(_name, nil, _ctx), do: false

  # A context on the guest plane is a running chain's, which only
  # `Sanctum.Gate.call_in_chain/5` serves, so it is asked as that entry
  # asks.
  defp visible_action?(name, annotation, ctx),
    do:
      plane_visible?(annotation, ctx) and
        authorize(name, annotation, ctx, ctx.plane == :guest) == :ok

  # Outside a running chain, only external-plane actions are served.
  defp plane_visible?(annotation, %Context{plane: :external}),
    do: :external in Map.get(annotation, :planes, [])

  defp plane_visible?(_annotation, _guest_ctx), do: true

  # One shape reaches here. `Sanctum.Catalog` emits the wire
  # spelling for registered tools and `Emissary.External.Proxy` maps a peer's
  # "parameters" onto it at ingest, so this reads "inputSchema" and nothing
  # else — a second accepted spelling only invites a third.
  defp extract_actions(tool_def) do
    case tool_def["inputSchema"] do
      %{"properties" => %{"action" => %{"enum" => actions}}} when is_list(actions) ->
        actions

      _ ->
        nil
    end
  end

  @doc """
  Restrict a discovery tool's schema and annotations to the selected actions.

  Given the tool's operations, the schema is rebuilt from the kept
  declarations, so a property only hidden actions declare disappears with
  them; without them only the action enum narrows. A definition with no
  `inputSchema` keeps its shape.
  """
  @spec restrict_actions(map(), [String.t()], [Prima.Operation.t()] | nil) :: map()
  def restrict_actions(tool_def, actions, operations \\ nil)
      when is_map(tool_def) and is_list(actions) do
    tool_def =
      case tool_def do
        %{"inputSchema" => schema} ->
          Map.put(tool_def, "inputSchema", restrict_schema(schema, actions, operations))

        _ ->
          tool_def
      end

    case tool_def["annotations"] do
      %{actions: declared} = annotations ->
        Map.put(tool_def, "annotations", %{annotations | actions: Map.take(declared, actions)})

      _ ->
        tool_def
    end
  end

  defp restrict_schema(schema, actions, operations) when is_list(operations) do
    kept = Enum.filter(operations, &(&1.action in actions))
    Map.merge(schema, Prima.Operation.schema(kept))
  end

  defp restrict_schema(schema, actions, nil),
    do: Prima.Operation.restrict_schema(schema, actions)
end
