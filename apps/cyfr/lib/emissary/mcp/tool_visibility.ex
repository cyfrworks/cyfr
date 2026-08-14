# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolVisibility do
  @moduledoc """
  Filters `tools/list` results based on the caller's API key permissions.

  Default-deny: an action in `@action_permissions` requires the mapped
  permission atom; an action in `@public_actions` is visible to everyone;
  an action in NEITHER is visible to no one. The completeness audit
  (`test/emissary/mcp/tool_visibility_test.exs`) asserts every registered
  action is deliberately classified in one of the two maps, so a forgotten
  action fails loudly at test time instead of silently disappearing from
  (or leaking into) discovery.

  External tools (namespaced with `:`, no action enum) pass through unchanged.
  """

  alias Sanctum.Context

  # "tool.action" => required permission atom
  # Actions in neither this map nor @public_actions are visible to no one.
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
    "schedule.re_resolve" => :execute,
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
    "session.device_init" => :admin,
    "session.device_poll" => :admin,
    "mcp_servers.create" => :admin,
    "mcp_servers.delete" => :admin,
    "mcp_servers.enable" => :admin,
    "mcp_servers.disable" => :admin,
    "mcp_servers.test" => :admin,
    "mcp_servers.refresh" => :admin,
    "system.notify" => :admin,

    # registry READ/bootstrap actions (probe, claim_personal, get_namespace,
    # whoami, legal_*) stay public-visible: they run before a session exists
    # or are public reads per the cyfr.run spec, and hiding them from
    # tool-discovery breaks LLMs calling them. The identity MUTATIONS are
    # listed under :component_manage below, mirroring RegistryTool's gate.

    # :component_read
    "component.get_blob" => :component_read,
    "component.discover" => :component_read,

    # :component_manage
    "component.pull" => :component_manage,
    "component.push" => :component_manage,
    "component.register" => :component_manage,
    "component.create" => :component_manage,
    "component.fork" => :component_manage,
    "component.delete" => :component_manage,
    "component.deprecate" => :component_manage,
    "component.yank" => :component_manage,

    # :component_manage — registry identity mutations (mirrors RegistryTool's
    # @identity_mutations gate; bootstrap actions stay public)
    "registry.claim_publisher" => :component_manage,
    "registry.verify_publisher" => :component_manage,
    "registry.tokens_issue" => :component_manage,
    "registry.tokens_revoke" => :component_manage,
    "registry.members_add" => :component_manage,
    "registry.members_update" => :component_manage,
    "registry.members_remove" => :component_manage,

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
    "retention.set" => :storage_write,

    # :execute — tincture visibility write is an operator action
    "tincture_visibility.set" => :execute,

    # :storage_read — tincture visibility read
    "tincture_visibility.get" => :storage_read,

    # Credential / consent operator surfaces. These authorize through the
    # consent Authz plane (oidc / interactive), not a permission atom, so they
    # were absent from this map and fell through to public discovery. Gate their
    # DISCOVERY to :admin so anonymous callers never see the schemas; actual
    # invocation is still governed by the consent path.
    "vault.authorize" => :admin,
    "vault.create" => :admin,
    "vault.delete" => :admin,
    "vault.list" => :admin,
    "vault.rebind" => :admin,
    "vault.rename" => :admin,
    "vault.revoke" => :admin,
    "vault.rotate" => :admin,
    "profile.plan" => :admin,
    "profile.preview" => :admin,
    "profile.commit" => :admin,
    "profile.publish" => :admin,
    "profile.list" => :admin,
    "profile.revoke" => :admin,
    "webhook.create" => :admin,
    "webhook.get" => :admin,
    "webhook.list" => :admin,
    "webhook.revoke" => :admin,
    "webhook.rotate" => :admin,
    "webhook.update" => :admin,
    "oauth.set_client" => :admin,

    # Audit correlate/fan_outs/stats join their list/get siblings.
    "mcp_log.correlate" => :storage_read,
    "mcp_log.fan_outs" => :storage_read,
    "mcp_log.stats" => :storage_read,
    "policy_log.correlate" => :storage_read
  }

  # Actions intentionally visible to every caller (including unauthenticated):
  # pre-session bootstrap, cyfr.run spec reads, and discovery/guide reads an LLM
  # calls before any session exists. Split out from @action_permissions so the
  # completeness audit (test/emissary/mcp/tool_visibility_test.exs) can assert
  # every registered action is deliberately classified as gated OR public — a
  # new action fails that test until it is placed here or in the gate map.
  @public_actions MapSet.new([
                    "aqua.create",
                    "aqua.delete",
                    "aqua.get",
                    "aqua.list",
                    "aqua.update",
                    "build.toolchains",
                    "build.validate",
                    "component.categories",
                    "component.inspect",
                    "component.list",
                    "component.search",
                    "component.setup_plan",
                    "mcp_servers.get",
                    "mcp_servers.list",
                    "registry.appeal",
                    "registry.claim_personal",
                    "registry.get_namespace",
                    "registry.legal_accept",
                    "registry.legal_page",
                    "registry.legal_version",
                    "registry.list_my_reports",
                    "registry.members_list",
                    "registry.probe",
                    "registry.report",
                    "registry.tokens_list",
                    "registry.whoami",
                    "session.whoami",
                    "system.status",
                    "tools.list"
                  ])

  @doc false
  def action_permissions, do: @action_permissions
  @doc false
  def public_actions, do: @public_actions

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
            key = "#{name}.#{action}"

            case Map.get(@action_permissions, key) do
              nil -> MapSet.member?(@public_actions, key)
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
