# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.Provider do
  @moduledoc """
  MCP tool provider for system-wide operations.

  Provides:
  - `system` tool: Health checks (`status`) and webhook notifications (`notify`)
  - `tools` tool: Tool discovery (`list`) — returns all registered tools and schemas
  - `resource` tool: `read` admits an MCP `resources/read` of an
    `arca://files/{path}` URI, the resource template this provider
    advertises

  This provider is Grimoire's because it needs cross-service visibility.

  ## The files resource

  `resource.read` requires `:storage_read`, and the gate decides it with
  the caller's context like any other operation. The handler then chooses
  which roots the caller reads — every tenant root
  (`Arca.Storage.tenant_roots/0`) for a caller holding `:admin` (a
  person's session holds every permission), only `threads/` and `data/`
  (`Arca.Storage.key_read_roots/0`) for a narrower key — and hands the
  projected actor, the URI and those roots to
  `Arca.Providers.Records.read/3`. The roots come from the admitted
  context and nothing the caller sends.
  """

  @behaviour Prima.Provider

  @impl true
  def service, do: "grimoire"

  alias Sanctum.Context
  require Logger

  # The status scopes are derived from the provider roster, with "all".
  defp scope_enum, do: ["all"] ++ service_scopes()
  defp service_scopes, do: Grimoire.Services.service_names()

  # ============================================================================
  # ToolProvider Callbacks
  # ============================================================================

  @impl true
  def tools do
    alias Prima.{Arg, Operation}
    # Anonymous-allowed: the health check a client calls before
    # logging in.
    # Authenticated-only, matching the HTTP surface (which has always
    # 401'd an anonymous tools.list): an uncredentialed caller's
    # discovery is the anonymous action set, nothing more.
    [
      Operation.tool(
        [
          Operation.new(
            "system",
            "status",
            "Status system",
            [
              Arg.new("scope", :string,
                description: "For status: which service(s) to check. Default: all",
                enum: scope_enum()
              )
            ],
            auth: :anonymous,
            kind: :read,
            planes: [:external, :in_chain]
          ),
          Operation.new(
            "system",
            "notify",
            "Notify system",
            [
              Arg.new("target", :string,
                required: true,
                description: "For notify: webhook URL destination"
              ),
              Arg.new("event", :string,
                required: true,
                description: "For notify: event type (e.g., 'build.complete')"
              ),
              Arg.new("payload", {:map, Arg.new(nil, :json)},
                description: "For notify: additional data to include"
              )
            ],
            kind: :write,
            planes: [:external],
            permission: :admin
          )
        ],
        description: "System health checks and notifications",
        title: "System"
      ),
      Operation.tool(
        [
          Operation.new(
            "tools",
            "list",
            "List tools",
            [
              Arg.new("component_ref", :string,
                description:
                  "For list: preview available tools as seen by this component (e.g. 'formula:local.my-agent:0.1.0'). A formula sees its in-chain plane; other types see the full list."
              )
            ],
            kind: :read,
            planes: [:external, :in_chain]
          )
        ],
        description:
          "Discover available MCP tools and their schemas. Optionally pass a component_ref to see the filtered view for that component (formulas see their in-chain plane).",
        title: "Tools"
      ),
      Operation.tool(
        [
          Operation.new(
            "resource",
            "read",
            "Read an arca://files/{path} resource",
            [
              Arg.new("uri", :string,
                required: true,
                description: "The resource URI, like arca://files/data/reports/q3.csv"
              )
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read,
            recovery: :replay_safe,
            resource_schemes: ["arca"]
          )
        ],
        description:
          "Read a file of the athanor's storage by its arca://files/{path} resource URI",
        title: "Resources"
      )
    ]
  end

  @impl true
  def resources, do: []

  @impl true
  def resource_templates do
    [
      %{
        uriTemplate: "arca://files/{path}",
        name: "Arca Files",
        description:
          "Read a file in the athanor's storage by path. A person reads every root (" <>
            Enum.map_join(Arca.Storage.tenant_roots(), ", ", &(&1 <> "/")) <>
            "); a key scoped to :storage_read reaches " <>
            Enum.map_join(Arca.Storage.key_read_roots(), " and ", &(&1 <> "/")),
        mimeType: Prima.MediaType.binary()
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
    tools = Grimoire.Catalog.list_tools()

    # Augment with tenant-specific external MCP server tools
    external_tools = Grimoire.Proxy.impl!().list_external_tools(ctx)

    all_tools = tools ++ external_tools
    all_tools = Grimoire.Visibility.filter_for_context(all_tools, ctx)

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

  def handle("resource", %Context{} = ctx, %{"action" => "read", "uri" => uri})
      when is_binary(uri) do
    roots =
      if Context.has_permission?(ctx, :admin),
        do: Arca.Storage.tenant_roots(),
        else: Arca.Storage.key_read_roots()

    Arca.Providers.Records.read(Context.actor(ctx), uri, roots)
  end

  def handle("resource", _ctx, %{"action" => "read"}) do
    {:error, {:invalid_argument, "Missing required argument: uri"}}
  end

  def handle("resource", _ctx, %{"action" => action}) do
    {:error, {:unknown_action, "resource.#{action}"}}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Status Action
  # ============================================================================

  defp handle_status(ctx, "all") do
    services = check_all_services(ctx)

    {:ok,
     %{
       status: overall(services),
       version: Prima.Version.current(),
       uptime_seconds: uptime(),
       services: services,
       mcp: %{
         protocol_version: Emissary.MCP.Protocol.version(),
         tools_count: tool_count(),
         resources_count: resource_count()
       }
     }}
  end

  defp handle_status(_ctx, scope) do
    if scope in service_scopes() do
      services = service_status(scope)

      {:ok,
       %{
         status: overall(services),
         version: Prima.Version.current(),
         uptime_seconds: uptime(),
         services: services
       }}
    else
      {:error, "Invalid scope: #{scope}. Valid scopes: #{Enum.join(scope_enum(), ", ")}"}
    end
  end

  # "unknown" is a probe that deliberately did not run (test env) — not
  # evidence of degradation.
  defp overall(services) do
    if Enum.all?(services, fn {_k, v} -> v in ["ok", "stub", "unknown"] end),
      do: "ok",
      else: "degraded"
  end

  # A service is answering when every configured provider it owns is; the
  # first provider that is not carries the answer.
  defp check_service_named(service) do
    service
    |> Grimoire.Services.providers_for()
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
            # pinned request path (SSRF refusals) or a refusal of the
            # table, rendered as its sentence — never a raw term.
            {:error, "notification delivery to #{target} failed: #{reason_text(reason)}"}
        end
    end
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: Grimoire.Error.render(reason)

  # ============================================================================
  # Tools List Filtering
  # ============================================================================

  defp handle_tools_list_for(tools, component_ref) do
    case Prima.ComponentRef.parse(component_ref) do
      {:ok, %{type: "formula"}} ->
        filtered = Grimoire.Catalog.in_chain_view(tools)
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
    Enum.reduce(service_scopes(), %{}, &Map.merge(&2, service_status(&1)))
  end

  # A service's own check merged with the states its providers report of
  # what they depend on (`c:Prima.Provider.status/0`). A provider without
  # the callback adds nothing; one whose answer raises, exits or is not a
  # map of strings reads "crashed" under its service — the report degrades,
  # the call never fails. Service names come from the configured roster and
  # state names from provider code, so the atom table stays bounded.
  defp service_status(service) do
    service_key = String.to_atom(service)

    {states, crashed?} =
      service
      |> Grimoire.Services.providers_for()
      |> Enum.reduce({%{}, false}, fn module, {states, crashed?} ->
        case provider_status(module) do
          {:ok, reported} -> {Map.merge(states, reported), crashed?}
          :crashed -> {states, true}
        end
      end)

    own = if crashed?, do: "crashed", else: check_service_named(service)
    Map.put(states, service_key, own)
  end

  defp provider_status(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :status, 0) do
      module.status() |> reported_states(module)
    else
      {:ok, %{}}
    end
  rescue
    # Its shape only: a provider's message can carry the values it probed.
    e ->
      Logger.error(
        "[Grimoire.Provider] #{inspect(module)}.status/0 raised #{inspect(e.__struct__)}"
      )

      :crashed
  catch
    kind, _reason ->
      Logger.error("[Grimoire.Provider] #{inspect(module)}.status/0 failed (#{kind})")
      :crashed
  end

  defp reported_states(states, module) when is_map(states) do
    if Enum.all?(states, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, Map.new(states, fn {name, state} -> {String.to_atom(name), state} end)}
    else
      Logger.error("[Grimoire.Provider] #{inspect(module)}.status/0 answered a malformed map")
      :crashed
    end
  end

  defp reported_states(_states, module) do
    Logger.error("[Grimoire.Provider] #{inspect(module)}.status/0 answered no map")
    :crashed
  end

  # Status reports whether the module is loaded and implements the
  # provider contract; it does not probe downstream service health.
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
      Logger.error(
        "[Grimoire.Provider] Service #{inspect(module)} crashed: #{Exception.message(e)}"
      )

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
          {"user-agent", "CYFR/" <> Prima.Version.current()}
        ]

        # The pinned path resolves-validates once, connects to the validated
        # IP, and never follows redirects — a target that 302s toward a
        # metadata endpoint goes nowhere. Private targets stay blocked
        # unconditionally, as they always were on this surface.
        case Sanctum.Egress.pinned_request(:post, target, headers, body,
               receive_timeout: 10_000,
               # Only the status is read; a hostile target still must not
               # flood the host with a response body.
               max_response_bytes: 1024 * 1024
             ) do
          {:ok, status_code, _resp_headers, _resp_body} ->
            Logger.debug("[Grimoire.Provider] Webhook sent to #{target}: status #{status_code}")
            {:ok, status_code}

          {:error, reason} when is_binary(reason) ->
            Logger.warning("[Grimoire.Provider] Webhook URL blocked: #{reason}")
            {:error, "Webhook URL validation failed: #{reason}"}

          {:error, reason} ->
            Logger.warning("[Grimoire.Provider] Webhook failed to #{target}: #{inspect(reason)}")
            {:error, {:unavailable, "The webhook target"}}
        end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end

  defp tool_count, do: length(Grimoire.Catalog.list_tools())

  defp resource_count, do: length(Grimoire.Resources.list_resources())
end
