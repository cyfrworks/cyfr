defmodule Emissary.MCP.ToolVisibility do
  @moduledoc """
  Filters `tools/list` results based on the caller's API key permissions.

  Actions listed in `@action_permissions` require the mapped permission atom.
  Actions NOT in the map are public — visible to all callers (including unauthenticated).

  External tools (namespaced with `:`, no action enum) pass through unchanged.
  """

  alias Sanctum.Context

  # "tool.action" => required permission atom
  # Actions not listed here are public (visible to all callers).
  @action_permissions %{
    # :execute
    "execution.run" => :execute,
    "execution.run_stream" => :execute,
    "execution.list" => :execute,
    "execution.logs" => :execute,
    "execution.cancel" => :execute,
    "execution.status" => :execute,
    "schedule.create" => :execute,
    "schedule.list" => :execute,
    "schedule.get" => :execute,
    "schedule.update" => :execute,
    "schedule.pause" => :execute,
    "schedule.resume" => :execute,
    "schedule.delete" => :execute,
    "schedule.re-resolve" => :execute,
    "build.compile" => :execute,

    # :admin
    "execution.force_release" => :admin,
    "key.create" => :admin,
    "key.get" => :admin,
    "key.list" => :admin,
    "key.revoke" => :admin,
    "key.rotate" => :admin,
    "retention.cleanup" => :admin,
    "session.login" => :admin,
    "session.logout" => :admin,
    "session.device-init" => :admin,
    "session.device-poll" => :admin,
    "session.registry-login" => :admin,

    # :secrets_read
    "secret.list" => :secrets_read,
    "secret.get" => :secrets_read,
    "secret.can_access" => :secrets_read,
    "secret.list_component_grants" => :secrets_read,

    # :secrets_write
    "secret.set" => :secrets_write,
    "secret.delete" => :secrets_write,
    "secret.grant" => :secrets_write,
    "secret.revoke" => :secrets_write,

    # :component_read
    "component.get_blob" => :component_read,
    "component.discover" => :component_read,

    # :component_manage
    "component.pull" => :component_manage,
    "component.publish" => :component_manage,
    "component.register" => :component_manage,
    "component.remove" => :component_manage,
    "component.new" => :component_manage,

    # :policy_read
    "policy.get" => :policy_read,
    "policy.list" => :policy_read,
    "policy.get_effective" => :policy_read,
    "policy.get_ceiling" => :policy_read,
    "policy.check_rate_limit" => :policy_read,
    "policy.get_type_default" => :policy_read,
    "policy.list_type_defaults" => :policy_read,

    # :policy_manage
    "policy.set" => :policy_manage,
    "policy.update_field" => :policy_manage,
    "policy.delete" => :policy_manage,
    "policy.set_type_default" => :policy_manage,
    "policy.delete_type_default" => :policy_manage,
    "policy.migrate_to_name_level" => :policy_manage,

    # :users_read
    "permission.get" => :users_read,
    "permission.list" => :users_read,

    # :users_manage
    "permission.set" => :users_manage,

    # :storage_read
    "record.get" => :storage_read,
    "record.list" => :storage_read,
    "mcp_log.list" => :storage_read,
    "mcp_log.get" => :storage_read,
    "policy_log.list" => :storage_read,
    "policy_log.get" => :storage_read,
    "retention.get" => :storage_read,

    # :storage_write
    "retention.set" => :storage_write
  }

  @doc """
  Filter tool definitions to only include tools/actions the caller can see.

  - Wildcard (`:*`) permission → returns tools unmodified
  - For each tool: prunes action enum to permitted actions, drops tools with none remaining
  - Tools with no action enum (external tools, etc.) pass through unchanged
  """
  @spec filter_for_context([map()], Context.t()) :: [map()]
  def filter_for_context(tools, %Context{} = ctx) do
    if Context.has_permission?(ctx, :*) do
      tools
    else
      tools
      |> Enum.map(&filter_tool(&1, ctx))
      |> Enum.reject(&is_nil/1)
    end
  end

  defp filter_tool(tool_def, ctx) do
    name = tool_def["name"] || to_string(Map.get(tool_def, :name, ""))
    actions = extract_actions(tool_def)

    case actions do
      nil ->
        # No action enum (external tools, etc.) — pass through
        tool_def

      actions when is_list(actions) ->
        visible =
          Enum.filter(actions, fn action ->
            case Map.get(@action_permissions, "#{name}.#{action}") do
              nil -> true
              perm -> Context.has_permission?(ctx, perm)
            end
          end)

        case visible do
          [] -> nil
          ^actions -> tool_def
          filtered -> put_actions(tool_def, filtered)
        end
    end
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
    schema_key =
      if Map.has_key?(tool_def, "inputSchema"), do: "inputSchema", else: :input_schema

    schema = Map.get(tool_def, schema_key, %{})
    updated_schema = put_in(schema, ["properties", "action", "enum"], actions)
    Map.put(tool_def, schema_key, updated_schema)
  end
end
