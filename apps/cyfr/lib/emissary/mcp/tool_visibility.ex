# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolVisibility do
  @moduledoc """
  Derives what a caller may see in `tools/list` — and, for a caller with
  no credential, what they may reach at all — from the same per-action
  access annotations `Emissary.MCP.ToolRegistry` enforces at dispatch.

  Discovery is not a policy of its own. Every question here is answered by
  reading the action's annotation (`auth`, `permission`, `consent`), so a
  caller is shown exactly the doors dispatch would open for them:

  - `auth: :anonymous` actions are visible to everyone, and they are the
    only thing an uncredentialed caller sees or may invoke.
  - `permission:` actions are visible to holders of that permission.
  - `consent:` actions are visible to the surfaces `Sanctum.Consent.Authz`
    admits (`:interactive` → OIDC sessions; `:staging` → OIDC or API key).
    An `:admin` API key being shown `vault.rotate` and then refused on call
    was exactly the drift this derivation exists to prevent.
  - An action with no annotation is visible to no one — the dispatcher
    refuses it too (default-deny at both gates).

  The completeness audit (`Emissary.MCP.ToolRegistry.audit_action_kinds/0`,
  asserted `:ok` in CI) guarantees every registered action carries a full
  declaration, so nothing falls through to an accidental default.

  External tools (namespaced with `:`, no action enum) carry no per-action
  classification: the dispatcher refuses every one of them to a caller with
  no credential, so anonymous callers are shown none and authenticated
  callers pass them through unchanged.
  """

  alias Emissary.MCP.ActionAnnotations
  alias Sanctum.Context

  @doc """
  May a caller with no credential reach this tool action?

  The Router's invocation gate and this module's discovery filter are the
  same question asked at two moments, so both read the action's annotation.
  """
  @spec anonymous_action?(String.t(), String.t()) :: boolean()
  def anonymous_action?(name, action) do
    case Arca.Cache.get({:mcp_tool, name}) do
      {:ok, {_module, meta}} ->
        ActionAnnotations.auth(meta, action) == :anonymous

      :miss ->
        false
    end
  end

  @doc """
  May this caller reach an action with this annotation, as far as
  authentication goes? Authenticated callers always may; `:anonymous`
  actions serve anyone; `:signed_in` actions serve a session that has not
  claimed its namespace yet (`user_id` set, `authenticated: false`).
  """
  @spec admits?(map(), Context.t()) :: boolean()
  def admits?(annotation, %Context{} = ctx) do
    case Map.get(annotation, :auth, :required) do
      :anonymous -> true
      :signed_in -> ctx.authenticated or is_binary(ctx.user_id)
      _ -> ctx.authenticated
    end
  end

  @doc "`admits?/2` by tool and action name, for the Router's invocation gate."
  @spec admits_action?(String.t(), String.t(), Context.t()) :: boolean()
  def admits_action?(name, action, %Context{} = ctx) do
    case Arca.Cache.get({:mcp_tool, name}) do
      {:ok, {_module, meta}} ->
        admits?(ActionAnnotations.annotation(meta, action) || %{}, ctx)

      :miss ->
        false
    end
  end

  @doc """
  Filter tool definitions to only include tools/actions the caller can see.

  - For each tool: prunes the action enum to actions whose annotation admits
    this caller, drops tools with none remaining.
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
        annotations = ActionAnnotations.actions_of(tool_def)
        visible = Enum.filter(actions, &visible_action?(Map.get(annotations, &1), ctx))

        case visible do
          [] -> nil
          ^actions -> tool_def
          filtered -> put_actions(tool_def, filtered)
        end
    end
  end

  # Unclassified action: invisible, matching the dispatch refusal.
  defp visible_action?(nil, _ctx), do: false

  # A caller with no credential — or a session ahead of its claim — sees
  # only what dispatch would let it call.
  defp visible_action?(annotation, %Context{authenticated: false} = ctx),
    do: admits?(annotation, ctx)

  defp visible_action?(annotation, ctx),
    do:
      scope_visible?(annotation, ctx) and permission_visible?(annotation, ctx) and
        consent_visible?(annotation, ctx)

  # Operator-only actions are shown to operators alone (mirrors dispatch).
  defp scope_visible?(annotation, ctx) do
    case Map.get(annotation, :scope) do
      nil -> true
      :platform -> ctx.platform_admin
    end
  end

  defp permission_visible?(annotation, ctx) do
    case Map.get(annotation, :permission) do
      nil -> true
      permission -> Context.has_permission?(ctx, permission)
    end
  end

  # Mirrors Sanctum.Consent.Authz's surface arms — which admit by
  # auth_method, never by permission atom, so `:*` deliberately does not
  # short-circuit here.
  defp consent_visible?(annotation, ctx) do
    case Map.get(annotation, :consent) do
      nil -> true
      :interactive -> ctx.auth_method == :oidc
      :staging -> ctx.auth_method in [:oidc, :api_key]
    end
  end

  # One shape reaches here. `Emissary.MCP.ToolRegistry` emits the wire
  # spelling for registered tools and `ExternalProvider` maps a peer's
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

  defp put_actions(tool_def, actions) do
    schema = Map.get(tool_def, "inputSchema", %{})
    updated_schema = put_in(schema, ["properties", "action", "enum"], actions)
    Map.put(tool_def, "inputSchema", updated_schema)
  end
end
