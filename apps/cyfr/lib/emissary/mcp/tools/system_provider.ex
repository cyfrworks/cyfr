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

  # The status scopes are derived from the provider roster — "all" and the
  # registry (an HTTP peer, not a provider) are the two extras.
  defp scope_enum, do: ["all"] ++ service_scopes()
  defp service_scopes, do: Emissary.MCP.Services.service_names() ++ ["registry"]

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
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            # Anonymous-allowed: the health check a client calls before
            # logging in.
            "status" => %{kind: :read, planes: [:external, :in_chain], auth: :anonymous},
            "notify" => %{kind: :write, planes: [:external], permission: :admin}
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
              "enum" => scope_enum(),
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
          "Discover available MCP tools and their schemas. Optionally pass a component_ref to see the filtered view for that component (formulas see their in-chain plane).",
        annotations: %{
          readOnlyHint: true,
          destructiveHint: false,
          actions: %{
            # Authenticated-only, matching the HTTP surface (which has always
            # 401'd an anonymous tools.list): an uncredentialed caller's
            # discovery is the anonymous action set, nothing more.
            "list" => %{kind: :read, planes: [:external, :in_chain]}
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
                "For list: preview available tools as seen by this component (e.g. 'formula:local.my-agent:0.1.0'). A formula sees its in-chain plane; other types see the full list."
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
    # Emits platform notification events — an operator action, and the one
    # write on this otherwise-read-only tool.
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
    external_tools = Emissary.MCP.ExternalProvider.list_external_tools(ctx)

    all_tools = tools ++ external_tools
    all_tools = Emissary.MCP.ToolVisibility.filter_for_context(all_tools, ctx)

    case args["component_ref"] do
      nil ->
        {:ok, %{tools: all_tools}}

      component_ref when is_binary(component_ref) ->
        handle_tools_list_for(all_tools, component_ref)
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

    # "unknown" is a probe that deliberately did not run (test env) — not
    # evidence of degradation.
    overall =
      if Enum.all?(services, fn {_k, v} -> v in ["ok", "stub", "unknown"] end),
        do: "ok",
        else: "degraded"

    {:ok,
     %{
       status: overall,
       version: Cyfr.Version.current(),
       uptime_seconds: uptime(),
       services: services,
       mcp: %{
         protocol_version: Emissary.MCP.Protocol.version(),
         tools_count: tool_count(),
         resources_count: resource_count()
       }
     }}
  end

  defp handle_status(ctx, scope) do
    if scope in service_scopes() do
      service_status = check_service_by_scope(ctx, scope)

      {:ok,
       %{
         status: if(service_status in ["ok", "stub", "unknown"], do: "ok", else: "degraded"),
         version: Cyfr.Version.current(),
         uptime_seconds: uptime(),
         # `scope` was just checked against the closed derived set, so the
         # atom table stays bounded.
         services: %{String.to_atom(scope) => service_status}
       }}
    else
      {:error, "Invalid scope: #{scope}. Valid scopes: #{Enum.join(scope_enum(), ", ")}"}
    end
  end

  defp check_service_by_scope(_ctx, "registry"), do: check_registry_health()
  defp check_service_by_scope(_ctx, scope), do: check_service_named(scope)

  # A service is answering when every configured provider it owns is; the
  # first provider that is not carries the answer.
  defp check_service_named(service) do
    service
    |> Emissary.MCP.Services.providers_for()
    |> Enum.map(&check_service/1)
    |> Enum.find("ok", &(&1 != "ok"))
  end

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
            # A failed delivery is a failed tool call — {:ok, delivered:
            # false} rendered as isError: false, so the caller's happy
            # path swallowed it. The reason is a crafted string from the
            # pinned request path (SSRF refusals, transport prose), never
            # a raw term.
            {:error, "notification delivery to #{target} failed: #{reason_text(reason)}"}
        end
    end
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(Sanctum.Sanitizer.sanitize(reason))

  # ============================================================================
  # Tools List Filtering
  # ============================================================================

  defp handle_tools_list_for(tools, component_ref) do
    case Sanctum.ComponentRef.parse(component_ref) do
      {:ok, %{type: "formula"}} ->
        filtered = Emissary.MCP.ToolRegistry.in_chain_view(tools)
        {:ok, %{tools: filtered, component_ref: component_ref, filtered: true}}

      {:ok, %{type: type}} ->
        # Only formulas have an in-chain plane to narrow to — return full list
        {:ok,
         %{tools: tools, component_ref: component_ref, component_type: type, filtered: false}}

      {:error, reason} ->
        {:error, "Invalid component_ref: #{reason}"}
    end
  end

  # ============================================================================
  # Health Checks
  # ============================================================================

  defp check_all_services(_ctx) do
    Emissary.MCP.Services.service_names()
    |> Map.new(fn service -> {String.to_atom(service), check_service_named(service)} end)
    |> Map.put(:registry, check_registry_health())
  end

  # Memoized: this is an outbound HTTPS probe with 3s connect + 3s read
  # timeouts, and system/status is called from the dev topbar on page
  # loads — per-call probing put that latency on the page and hammered
  # the registry. Registry health does not change per request.
  @registry_health_ttl_ms 30_000

  defp check_registry_health do
    case Arca.Cache.get(:registry_health) do
      {:ok, cached} ->
        cached

      :miss ->
        health = probe_registry_health()
        Arca.Cache.put(:registry_health, health, @registry_health_ttl_ms)
        health
    end
  end

  defp probe_registry_health do
    if Application.get_env(:cyfr, :registry_health_probe, true) do
      do_probe_registry_health()
    else
      # The test env turns the probe off: a real DNS + TLS round-trip with
      # a 3s timeout inside a test is 3s of wall clock and a straggling
      # socket at test exit, and the answer means nothing there.
      "unknown"
    end
  end

  defp do_probe_registry_health do
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

  # "ok" means the provider module is loaded and answers the provider
  # contract — nothing deeper. (An optional health/0 callback once offered
  # more; nothing ever implemented it, so status reported loadedness while
  # reading as health. Before that, this called `handle/3` with an
  # undeclared "ping" action — an entry point absent from every schema,
  # invisible to the action audit and unreachable from the wire.)
  defp check_service(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        "not_loaded"

      function_exported?(module, :handle, 3) ->
        "ok"

      true ->
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
    case Jason.encode(notification) do
      {:error, _} ->
        {:error, "Failed to encode webhook payload"}

      {:ok, body} ->
        headers = [
          {"content-type", "application/json"},
          {"user-agent", "CYFR/" <> Cyfr.Version.current()}
        ]

        # The pinned path resolves-validates once, connects to the validated
        # IP, and never follows redirects — a target that 302s toward a
        # metadata endpoint goes nowhere. Private targets stay blocked
        # unconditionally, as they always were on this surface.
        case Cyfr.Network.pinned_request(:post, target, headers, body, receive_timeout: 10_000) do
          {:ok, status_code, _resp_headers, _resp_body} ->
            Logger.debug("Webhook sent to #{target}: status #{status_code}")
            {:ok, status_code}

          {:error, reason} when is_binary(reason) ->
            Logger.warning("[SystemProvider] Webhook URL blocked: #{reason}")
            {:error, "Webhook URL validation failed: #{reason}"}

          {:error, reason} ->
            Logger.warning("Webhook failed to #{target}: #{inspect(reason)}")
            {:error, inspect(reason)}
        end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp registry_url, do: Compendium.RegistryHost.canonical_host()

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
