# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Tools.SystemProvider do
  @moduledoc """
  MCP tool provider for system-wide operations.

  Provides:
  - `system` tool: Health checks (`status`) and webhook notifications (`notify`)
  - `tools` tool: Tool discovery (`list`) — returns all registered tools and schemas

  This provider stays in Emissary because it needs cross-service visibility.
  """

  @behaviour Emissary.MCP.ToolProvider

  alias Sanctum.Context
  require Logger

  @version Mix.Project.config()[:version] || "0.1.0"

  @valid_scopes ["all", "opus", "sanctum", "compendium", "emissary", "arca", "registry"]

  # ============================================================================
  # ToolProvider Callbacks
  # ============================================================================

  @impl true
  def tools do
    [
      %{
        name: "system",
        title: "System",
        description: "System health checks and notifications",
        # Anonymous-allowed: `status` action is a health check that callers
        # need before logging in. The `notify` action is auth-checked at the
        # handler level via existing permission gates.
        requires_auth: false,
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            "status" => %{kind: :read},
            "notify" => %{kind: :write}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["status", "notify"],
              "description" => "Action to perform"
            },
            "scope" => %{
              "type" => "string",
              "enum" => @valid_scopes,
              "description" => "For status: which service(s) to check. Default: all"
            },
            "event" => %{
              "type" => "string",
              "description" => "For notify: event type (e.g., 'build.complete')"
            },
            "target" => %{
              "type" => "string",
              "description" => "For notify: webhook URL destination"
            },
            "payload" => %{
              "type" => "object",
              "description" => "For notify: additional data to include"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "tools",
        title: "Tools",
        description:
          "Discover available MCP tools and their schemas. Optionally pass a component_ref to see the filtered view for that component (respects restricted tools and policy).",
        # Tool discovery is anonymous-safe by design: the dispatcher returns
        # only public metadata, and per-tool handlers still gate any
        # destructive actions.
        requires_auth: false,
        annotations: %{
          readOnlyHint: true,
          destructiveHint: false,
          actions: %{
            "list" => %{kind: :read}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["list"],
              "description" => "Action to perform"
            },
            "component_ref" => %{
              "type" => "string",
              "description" =>
                "For list: preview available tools as seen by this component (e.g. 'formula:local.my-agent:0.1.0'). Applies restricted tools and policy filtering."
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  @impl true
  def handle("system", %Context{} = ctx, %{"action" => "status"} = args) do
    scope = args["scope"] || "all"
    handle_status(ctx, scope)
  end

  @impl true
  def handle("system", %Context{} = ctx, %{"action" => "notify"} = args) do
    handle_notify(ctx, args)
  end

  def handle("system", _ctx, %{"action" => action}) do
    {:error, "Unknown action: #{action}"}
  end

  def handle("system", _ctx, _args) do
    {:error, "Missing required parameter: action"}
  end

  @impl true
  def handle("tools", %Context{} = ctx, %{"action" => "list"} = args) do
    tools = Emissary.MCP.ToolRegistry.list_tools()

    # Augment with tenant-specific external MCP server tools
    external_tools =
      if Code.ensure_loaded?(Emissary.MCP.ExternalProvider) and
           function_exported?(Emissary.MCP.ExternalProvider, :list_external_tools, 1) do
        Emissary.MCP.ExternalProvider.list_external_tools(ctx)
      else
        []
      end

    all_tools = tools ++ external_tools
    all_tools = Emissary.MCP.ToolVisibility.filter_for_context(all_tools, ctx)

    case args["component_ref"] do
      nil ->
        {:ok, %{tools: all_tools}}

      component_ref when is_binary(component_ref) ->
        handle_tools_list_for(all_tools, ctx, component_ref)
    end
  end

  def handle("tools", _ctx, %{"action" => action}) do
    {:error, "Unknown action: #{action}"}
  end

  def handle("tools", _ctx, _args) do
    {:error, "Missing required parameter: action"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Status Action
  # ============================================================================

  defp handle_status(ctx, "all") do
    services = check_all_services(ctx)

    overall =
      if Enum.all?(services, fn {_k, v} -> v in ["ok", "stub"] end), do: "ok", else: "degraded"

    {:ok,
     %{
       status: overall,
       version: @version,
       uptime_seconds: uptime(),
       services: services,
       mcp: %{
         protocol_version: Emissary.MCP.protocol_version(),
         tools_count: tool_count(),
         resources_count: resource_count()
       }
     }}
  end

  defp handle_status(ctx, scope) when scope in @valid_scopes do
    service_status = check_service_by_scope(ctx, scope)

    {:ok,
     %{
       status: if(service_status in ["ok", "stub"], do: "ok", else: "degraded"),
       version: @version,
       uptime_seconds: uptime(),
       services: %{String.to_existing_atom(scope) => service_status}
     }}
  end

  defp handle_status(_ctx, scope) do
    {:error, "Invalid scope: #{scope}. Valid scopes: #{Enum.join(@valid_scopes, ", ")}"}
  end

  defp check_service_by_scope(_ctx, "emissary"), do: "ok"

  defp check_service_by_scope(ctx, "sanctum"),
    do: check_service(Sanctum.MCP, "session", %{"action" => "ping"}, ctx)

  defp check_service_by_scope(ctx, "arca"),
    do: check_service(Arca.MCP, "retention", %{"action" => "ping"}, ctx)

  defp check_service_by_scope(ctx, "opus"),
    do: check_service(Opus.MCP, "execution", %{"action" => "ping"}, ctx)

  defp check_service_by_scope(ctx, "compendium"),
    do: check_service(Compendium.MCP, "component", %{"action" => "ping"}, ctx)

  defp check_service_by_scope(_ctx, "registry"), do: check_registry_health()

  # ============================================================================
  # Notify Action
  # ============================================================================

  defp handle_notify(ctx, args) do
    target = args["target"]
    event = args["event"]

    cond do
      is_nil(target) ->
        {:error, "Missing required parameter: target"}

      is_nil(event) ->
        {:error, "Missing required parameter: event"}

      true ->
        payload = args["payload"] || %{}

        notification = %{
          event: event,
          payload: payload,
          source: "cyfr",
          user_id: ctx.user_id,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        case send_webhook(target, notification) do
          {:ok, status} ->
            {:ok,
             %{
               delivered: true,
               target: target,
               event: event,
               status_code: status
             }}

          {:error, reason} ->
            {:ok,
             %{
               delivered: false,
               target: target,
               event: event,
               error: reason
             }}
        end
    end
  end

  # ============================================================================
  # Tools List Filtering
  # ============================================================================

  defp handle_tools_list_for(tools, ctx, component_ref) do
    case Sanctum.ComponentRef.parse(component_ref) do
      {:ok, %{type: "formula"}} ->
        policy =
          case Sanctum.Policy.get_effective(ctx, component_ref) do
            {:ok, policy, _meta} -> policy
            _ -> nil
          end

        filtered = Sanctum.Policy.RestrictedTools.filter_tool_list(:formula, tools, policy)
        {:ok, %{tools: filtered, component_ref: component_ref, filtered: true}}

      {:ok, %{type: type}} ->
        # Non-formula types have no restricted tools today — return full list
        {:ok,
         %{tools: tools, component_ref: component_ref, component_type: type, filtered: false}}

      {:error, reason} ->
        {:error, "Invalid component_ref: #{reason}"}
    end
  end

  # ============================================================================
  # Health Checks
  # ============================================================================

  defp check_all_services(ctx) do
    %{
      emissary: "ok",
      sanctum: check_service(Sanctum.MCP, "session", %{"action" => "ping"}, ctx),
      arca: check_service(Arca.MCP, "retention", %{"action" => "ping"}, ctx),
      opus: check_service(Opus.MCP, "execution", %{"action" => "ping"}, ctx),
      compendium: check_service(Compendium.MCP, "component", %{"action" => "ping"}, ctx),
      registry: check_registry_health()
    }
  end

  defp check_registry_health do
    url = registry_url()

    case :httpc.request(
           :get,
           {~c"https://#{url}/health", []},
           [{:timeout, 3_000}, {:connect_timeout, 3_000}],
           []
         ) do
      {:ok, {{_version, 200, _reason}, _headers, _body}} ->
        "ok"

      {:ok, {{_version, status_code, _reason}, _headers, _body}} ->
        Logger.warning("Registry health check returned status #{status_code}")
        "error"

      {:error, reason} ->
        Logger.warning("Registry health check failed: #{inspect(reason)}")
        "unreachable"
    end
  rescue
    e ->
      Logger.warning("[SystemProvider] Registry health check exception: #{Exception.message(e)}")
      "error"
  end

  defp check_service(module, tool, args, ctx) do
    if Code.ensure_loaded?(module) and function_exported?(module, :handle, 3) do
      case module.handle(tool, ctx, args) do
        {:ok, _} ->
          "ok"

        {:error, reason} ->
          Logger.warning(
            "[SystemProvider] Service #{inspect(module)} returned error: #{inspect(reason)}"
          )

          "error"
      end
    else
      "not_loaded"
    end
  rescue
    e ->
      Logger.error("[SystemProvider] Service #{inspect(module)} crashed: #{Exception.message(e)}")
      "crashed"
  end

  # ============================================================================
  # Webhook
  # ============================================================================

  defp send_webhook(target, notification) do
    with :ok <- Cyfr.Network.validate_redirect_url(target) do
      case Jason.encode(notification) do
        {:error, _} ->
          {:error, "Failed to encode webhook payload"}

        {:ok, body} ->
          headers = [
            {~c"Content-Type", ~c"application/json"},
            {~c"User-Agent", ~c"CYFR/0.1.0"}
          ]

          case :httpc.request(
                 :post,
                 {String.to_charlist(target), headers, ~c"application/json",
                  String.to_charlist(body)},
                 [{:timeout, 10_000}, {:connect_timeout, 5_000}],
                 []
               ) do
            {:ok, {{_version, status_code, _reason}, _headers, _body}} ->
              Logger.debug("Webhook sent to #{target}: status #{status_code}")
              {:ok, status_code}

            {:error, reason} ->
              Logger.warning("Webhook failed to #{target}: #{inspect(reason)}")
              {:error, inspect(reason)}
          end
      end
    else
      {:error, reason} ->
        Logger.warning("[SystemProvider] Webhook URL blocked: #{reason}")
        {:error, "Webhook URL validation failed: #{reason}"}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp registry_url do
    Application.get_env(:cyfr, :oci_registry_url, "registry.cyfr.run")
  end

  defp uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end

  defp tool_count do
    if Process.whereis(Emissary.MCP.ToolRegistry) do
      Emissary.MCP.ToolRegistry.list_tools() |> length()
    else
      0
    end
  end

  defp resource_count do
    if Process.whereis(Emissary.MCP.ResourceRegistry) do
      Emissary.MCP.ResourceRegistry.list_resources() |> length()
    else
      0
    end
  end
end