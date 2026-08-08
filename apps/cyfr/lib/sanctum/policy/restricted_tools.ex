# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.RestrictedTools do
  @moduledoc """
  Restricted tools list for formula components.

  Formulas can call MCP tools via `cyfr:formula/invoke`, but certain tools
  must never be accessible to formula execution — even if explicitly listed
  in `allowed_tools`. This module defines the hard-coded restriction list
  and provides validation functions for both save-time and runtime enforcement.

  ## Enforcement Layers

  1. **Save-time** — `PolicyStore.put/2` rejects formula policies that include
     restricted tools in `allowed_tools` (except the `"*"` convenience wildcard).
  2. **Runtime** — `FormulaHandler` checks every tool call against this list
     before dispatching, blocking restricted tools even when policy is nil or
     contains `"*"`.
  """

  @formula_restricted [
    # Auth/identity — formulas must not manage sessions or keys
    "session.*",
    "key.*",
    "permission.*",

    # Policy mutation — reads OK, writes never
    "policy.set",
    "policy.patch",
    "policy.delete",
    "policy.set_type_default",
    "policy.delete_type_default",
    "policy.migrate",

    # Secret mutation — reading granted secrets OK, managing never

    # Audit/log surfaces — internal observability, never guest-readable
    "mcp_log.*",
    "policy_log.*",
    "retention.*",
    "record.*",

    # Registry mutation — search/inspect/register OK, push/delete never
    "component.push",
    "component.delete",

    # Registry identity mutation — a formula runs with its caller's
    # permissions, so without this a wildcard caller's formula could issue
    # push tokens or edit publisher membership
    "registry.tokens_issue",
    "registry.claim_publisher",
    "registry.members_add",
    "registry.members_update",
    "registry.members_remove",

    # Dangerous execution action
    "execution.force_release",

    # Tenant-wide semaphore diagnostics: global counters with no chain
    # grain, so there is nothing meaningful to scope them to in-chain
    "execution.status",

    # System side effects
    "system.notify",

    # Standing ingresses — formulas must not mint or repoint invocation
    # channels that outlive the execution (list/get stay readable)
    "webhook.create",
    "webhook.update",
    "webhook.revoke",
    "webhook.rotate",
    "schedule.create",
    "schedule.update",
    "schedule.delete",
    "schedule.pause",
    "schedule.resume",
    "schedule.re_resolve",

    # Public exposure — formulas must not publish surfaces
    "tincture_visibility.set",

    # The consent plane — a running component must never stage, grant,
    # revoke or enumerate the operator's credentials and profiles; the
    # whole walk is external-ingress by definition (§4.1)
    "vault.list",
    "vault.create",
    "vault.rename",
    "vault.rotate",
    "vault.rebind",
    "vault.authorize",
    "vault.revoke",
    "vault.delete",
    "profile.plan",
    "profile.publish",
    "profile.preview",
    "profile.commit",
    "profile.list",
    "profile.revoke",

    # MCP server management — formulas can call external tools but not
    # create, repoint, or operate the server processes (list/get stay readable)
    "mcp_servers.create",
    "mcp_servers.delete",
    "mcp_servers.enable",
    "mcp_servers.disable",
    "mcp_servers.test",
    "mcp_servers.refresh"
  ]

  @doc """
  Returns the list of restricted tool patterns for the given component type.
  """
  @spec restricted_for(:formula) :: [String.t()]
  def restricted_for(:formula), do: @formula_restricted

  @doc """
  Check whether a specific tool action is restricted for the given component type.

  Returns `:allowed` or `{:restricted, pattern}` where pattern is the
  matching restriction rule.
  """
  @spec check(:formula, String.t()) :: :allowed | {:restricted, String.t()}
  def check(:formula, tool_action) when is_binary(tool_action) do
    case Enum.find(@formula_restricted, &tool_matches?(&1, tool_action)) do
      nil -> :allowed
      pattern -> {:restricted, pattern}
    end
  end

  @doc """
  Validate an `allowed_tools` list against the restricted tools for a component type.

  Returns `:ok` if no violations, or `{:error, violations}` where violations
  is a list of `{tool_entry, restricted_pattern}` tuples.

  The `"*"` wildcard is allowed at save-time — runtime enforcement handles
  blocking restricted tools regardless.
  """
  @spec validate_allowed_tools(:formula, [String.t()]) ::
          :ok | {:error, [{String.t(), String.t()}]}
  def validate_allowed_tools(:formula, tools) when is_list(tools) do
    restricted = @formula_restricted

    violations =
      tools
      |> Enum.reject(&(&1 == "*"))
      |> Enum.flat_map(fn tool_entry ->
        Enum.flat_map(restricted, fn restricted_pattern ->
          if patterns_overlap?(tool_entry, restricted_pattern) do
            [{tool_entry, restricted_pattern}]
          else
            []
          end
        end)
      end)

    case violations do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  @doc """
  Filter a list of MCP tool definitions for formula visibility.

  Takes the raw `tools/list` output (list of tool definition maps) and returns
  only the tools and actions a formula can actually use. Applies two filters:

  1. **Restriction filter** — removes tools/actions on the restricted list
  2. **Policy filter** — if a policy is provided, further limits to `allowed_tools`

  Tool definitions with no remaining actions are removed entirely.
  The action enum inside `inputSchema` is pruned to reflect available actions.

  Pass `nil` for policy to skip the policy filter (shows all non-restricted tools).
  """
  @spec filter_tool_list(:formula, [map()], Sanctum.Policy.t() | nil) :: [map()]
  def filter_tool_list(:formula, tool_defs, policy) when is_list(tool_defs) do
    tool_defs
    |> Enum.map(fn tool_def -> filter_single_tool(:formula, tool_def, policy) end)
    |> Enum.reject(&is_nil/1)
  end

  defp filter_single_tool(:formula, tool_def, policy) do
    name = tool_def["name"] || to_string(Map.get(tool_def, :name, ""))
    actions = extract_actions(tool_def)

    case actions do
      nil ->
        # No action enum — check if entire tool namespace is restricted
        if check(:formula, "#{name}.any") != :allowed and
             namespace_restricted?(:formula, name) do
          nil
        else
          tool_def
        end

      actions when is_list(actions) ->
        available =
          actions
          |> Enum.filter(fn action ->
            tool_action = "#{name}.#{action}"
            check(:formula, tool_action) == :allowed and policy_allows?(policy, tool_action)
          end)

        case available do
          [] -> nil
          ^actions -> tool_def
          filtered -> put_actions(tool_def, filtered)
        end
    end
  end

  defp namespace_restricted?(:formula, name) do
    Enum.any?(@formula_restricted, fn pattern ->
      pattern == "#{name}.*"
    end)
  end

  defp policy_allows?(nil, _tool_action), do: true

  defp policy_allows?(policy, tool_action) do
    Sanctum.Policy.allows_tool?(policy, tool_action)
  end

  defp extract_actions(tool_def) do
    schema = tool_def["inputSchema"] || Map.get(tool_def, :input_schema)

    case schema do
      %{"properties" => %{"action" => %{"enum" => actions}}} when is_list(actions) ->
        actions

      _ ->
        nil
    end
  end

  defp put_actions(tool_def, actions) do
    schema_key = if Map.has_key?(tool_def, "inputSchema"), do: "inputSchema", else: :input_schema
    schema = Map.get(tool_def, schema_key, %{})

    updated_schema =
      put_in(schema, ["properties", "action", "enum"], actions)

    Map.put(tool_def, schema_key, updated_schema)
  end

  # ============================================================================
  # Pattern Matching (shared logic with Sanctum.Policy)
  # ============================================================================

  # Exact match: "session.login" matches pattern "session.login"
  # Wildcard match: "session.login" matches pattern "session.*"
  defp tool_matches?(pattern, tool_action) do
    cond do
      pattern == tool_action ->
        true

      String.ends_with?(pattern, ".*") ->
        prefix = String.slice(pattern, 0..-3//1) <> "."
        String.starts_with?(tool_action, prefix)

      true ->
        false
    end
  end

  @doc """
  Check if two tool patterns overlap.

  Two patterns overlap when any concrete tool action could match both.
  Used at save-time to catch when an allowed_tools entry would grant
  access to a restricted tool.

  Examples:
  - `"session.login"` overlaps `"session.*"` (exact within wildcard)
  - `"session.*"` overlaps `"session.*"` (identical wildcards)
  - `"session.*"` overlaps `"session.login"` (wildcard covers exact)
  - `"component.search"` does NOT overlap `"component.push"` (different actions)
  """
  @spec patterns_overlap?(String.t(), String.t()) :: boolean()
  def patterns_overlap?(pattern_a, pattern_b) do
    cond do
      # Both are exact — must be identical
      not String.ends_with?(pattern_a, ".*") and not String.ends_with?(pattern_b, ".*") ->
        pattern_a == pattern_b

      # A is wildcard, B is exact — B matches A?
      String.ends_with?(pattern_a, ".*") and not String.ends_with?(pattern_b, ".*") ->
        tool_matches?(pattern_a, pattern_b)

      # A is exact, B is wildcard — A matches B?
      not String.ends_with?(pattern_a, ".*") and String.ends_with?(pattern_b, ".*") ->
        tool_matches?(pattern_b, pattern_a)

      # Both are wildcards — same namespace prefix?
      true ->
        prefix_a = String.slice(pattern_a, 0..-3//1)
        prefix_b = String.slice(pattern_b, 0..-3//1)
        prefix_a == prefix_b
    end
  end
end
