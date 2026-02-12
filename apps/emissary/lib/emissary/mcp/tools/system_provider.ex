defmodule Emissary.MCP.Tools.SystemProvider do
  @moduledoc """
  MCP tool provider for system-wide operations.

  Provides a unified `system` tool with action-based pattern:
  - `status` - Health check for CYFR services (with optional scope filter)
  - `notify` - Send webhook notifications

  This provider stays in Emissary because it needs cross-service visibility.
  """

  @behaviour Emissary.MCP.ToolProvider

  alias Sanctum.Context
  require Logger

  @version Mix.Project.config()[:version] || "0.1.0"

  @valid_scopes ["all", "opus", "sanctum", "compendium", "emissary", "arca"]

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

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Status Action
  # ============================================================================

  defp handle_status(ctx, "all") do
    services = check_all_services(ctx)
    overall = if Enum.all?(services, fn {_k, v} -> v in ["ok", "stub"] end), do: "ok", else: "degraded"

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
       services: %{String.to_atom(scope) => service_status}
     }}
  end

  defp handle_status(_ctx, scope) do
    {:error, "Invalid scope: #{scope}. Valid scopes: #{Enum.join(@valid_scopes, ", ")}"}
  end

  defp check_service_by_scope(_ctx, "emissary"), do: "ok"
  defp check_service_by_scope(ctx, "sanctum"), do: check_service(Sanctum.MCP, "session", %{"action" => "whoami"}, ctx)
  defp check_service_by_scope(ctx, "arca"), do: check_service(Arca.MCP, "storage", %{"action" => "list", "path" => ""}, ctx)
  defp check_service_by_scope(ctx, "opus"), do: check_service(Opus.MCP, "execution", %{"action" => "list"}, ctx)
  defp check_service_by_scope(_ctx, "compendium"), do: check_service_loaded(Compendium.MCP)

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
  # Health Checks
  # ============================================================================

  defp check_all_services(ctx) do
    %{
      emissary: "ok",
      sanctum: check_service(Sanctum.MCP, "session", %{"action" => "whoami"}, ctx),
      arca: check_service(Arca.MCP, "storage", %{"action" => "list", "path" => ""}, ctx),
      opus: check_service(Opus.MCP, "execution", %{"action" => "list"}, ctx),
      compendium: check_service_loaded(Compendium.MCP)
    }
  end

  defp check_service(module, tool, args, ctx) do
    if Code.ensure_loaded?(module) and function_exported?(module, :handle, 3) do
      case module.handle(tool, ctx, args) do
        {:ok, _} -> "ok"
        {:error, _} -> "error"
      end
    else
      "not_loaded"
    end
  rescue
    _ -> "error"
  end

  defp check_service_loaded(module) do
    if Code.ensure_loaded?(module) do
      "stub"
    else
      "not_loaded"
    end
  end

  # ============================================================================
  # Webhook
  # ============================================================================

  defp send_webhook(target, notification) do
    body = Jason.encode!(notification)

    headers = [
      {~c"Content-Type", ~c"application/json"},
      {~c"User-Agent", ~c"CYFR/0.1.0"}
    ]

    case :httpc.request(
           :post,
           {String.to_charlist(target), headers, ~c"application/json", String.to_charlist(body)},
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

  # ============================================================================
  # Helpers
  # ============================================================================

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
