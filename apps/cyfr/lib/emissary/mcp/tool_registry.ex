# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolRegistry do
  @moduledoc """
  Cache-backed registry for MCP tools.

  At startup, discovers all configured tool providers and caches
  them via Arca.Cache for O(1) tool lookup. This follows the OTP pattern of
  "configure in config, initialize in Application".

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │  Emissary.MCP.ToolRegistry (GenServer)                          │
  │  ├── Arca.Cache keys: {:mcp_tool, name}                         │
  │  │   └── {:mcp_tool, "retention"} => {Arca.MCP, %{desc, ...}}   │
  │  │   └── {:mcp_tool, "execution"} => {Opus.MCP, %{...}}        │
  │  └── Providers: [Arca.MCP, Opus.MCP, ...]                       │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Usage

      # List all tools
      ToolRegistry.list_tools()

      # Call a tool
      ToolRegistry.call("retention", context, %{"action" => "get"})

  ## Future: Distributed

  When running multiple workers, this registry will be extended to
  track node availability and route using :pg or Horde.
  """

  use GenServer
  require Logger

  alias Sanctum.Context

  # 24 hours
  @cache_ttl :timer.hours(24)
  # Refresh 1 hour before TTL expires to prevent cache misses
  @refresh_interval :timer.hours(23)
  # Default tool execution timeout (5 minutes)
  @tool_timeout_ms :timer.minutes(5)

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  List all registered tools.

  Returns a list of tool definitions suitable for MCP tools/list response.
  """
  def list_tools do
    Arca.Cache.match({:mcp_tool, :_})
    |> Enum.map(fn {_key, {_module, meta}} ->
      name = meta.name

      %{
        "name" => name,
        "description" => meta.description,
        "inputSchema" => meta.input_schema
      }
      |> maybe_put("title", meta[:title])
      |> maybe_put("icons", meta[:icons])
      |> maybe_put("outputSchema", meta[:output_schema])
      |> maybe_put("annotations", meta[:annotations])
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Get a specific tool's definition.

  Returns `{:ok, tool_def}` or `{:error, :not_found}`.
  """
  def get_tool(name) do
    case Arca.Cache.get({:mcp_tool, name}) do
      {:ok, {_module, meta}} ->
        tool_def =
          %{
            "name" => name,
            "description" => meta.description,
            "inputSchema" => meta.input_schema
          }
          |> maybe_put("title", meta[:title])
          |> maybe_put("icons", meta[:icons])
          |> maybe_put("outputSchema", meta[:output_schema])
          |> maybe_put("annotations", meta[:annotations])

        {:ok, tool_def}

      :miss ->
        {:error, :not_found}
    end
  end

  @doc """
  Call a tool by name.

  Looks up the provider module and delegates to its `handle/3` callback.
  Returns `{:ok, result}` or `{:error, reason}`.

  Options:
  - `:mcp_request_id` - The JSON-RPC request ID, used for cancellation tracking.
  """
  def call(name, ctx, args, opts \\ [])

  def call(name, %Context{} = ctx, args, opts) when is_map(args) do
    # Skip logging for mcp_log tool to avoid infinite recursion,
    # and for calls that already have a request_id (logged by MCP controller)
    should_log? = name != "mcp_log" && is_nil(ctx.request_id)

    {request_id, ctx} =
      if should_log? do
        rid = Emissary.UUID7.request_id()
        {rid, %{ctx | request_id: rid}}
      else
        {ctx.request_id, ctx}
      end

    if should_log? do
      action = args["action"] || args[:action]

      Emissary.MCP.RequestLog.log_started(ctx, request_id, %{
        tool: name,
        action: action,
        method: "tools/call",
        input: args
      })
    end

    start_time = System.monotonic_time()

    case Arca.Cache.get({:mcp_tool, name}) do
      {:ok, {module, meta}} ->
        result =
          if meta.requires_auth and not ctx.authenticated do
            {:error, "Unauthorized: tool '#{name}' requires authentication"}
          else
            execute_tool_call(name, ctx, opts, fn -> module.handle(name, ctx, args) end)
          end

        if should_log? do
          duration_ms =
            System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

          case result do
            {:ok, output} ->
              Emissary.MCP.RequestLog.log_completed(ctx, request_id, %{
                output: output,
                duration_ms: duration_ms,
                routed_to: inspect(module)
              })

            {:error, reason} ->
              Emissary.MCP.RequestLog.log_failed(ctx, request_id, %{
                error: inspect(reason),
                code: -32_603,
                duration_ms: duration_ms,
                routed_to: inspect(module)
              })
          end
        end

        result

      :miss ->
        # Try external provider for namespaced tools (e.g., "notion:create_page")
        has_external? =
          Code.ensure_loaded?(Emissary.MCP.ExternalProvider) and
            function_exported?(Emissary.MCP.ExternalProvider, :try_handle, 3)

        external_result =
          cond do
            not has_external? ->
              {:error, :not_external}

            String.contains?(name, ":") and not ctx.authenticated ->
              # External tools carry no per-tool requires_auth metadata; all
              # of them require authentication. The HTTP router never routes
              # unknown names here, so this guards the in-process callers
              # (FormulaHandler, LiveViews). Bare unknown names fall through
              # so they still produce "Unknown tool".
              {:error, "Unauthorized: tool '#{name}' requires authentication"}

            true ->
              execute_tool_call(name, ctx, opts, fn ->
                Emissary.MCP.ExternalProvider.try_handle(name, ctx, args)
              end)
          end

        case external_result do
          {:error, :not_external} ->
            if should_log? do
              duration_ms =
                System.convert_time_unit(
                  System.monotonic_time() - start_time,
                  :native,
                  :millisecond
                )

              Emissary.MCP.RequestLog.log_failed(ctx, request_id, %{
                error: "Unknown tool: #{name}",
                code: -32_601,
                duration_ms: duration_ms
              })
            end

            {:error, "Unknown tool: #{name}"}

          result ->
            if should_log? do
              duration_ms =
                System.convert_time_unit(
                  System.monotonic_time() - start_time,
                  :native,
                  :millisecond
                )

              case result do
                {:ok, output} ->
                  Emissary.MCP.RequestLog.log_completed(ctx, request_id, %{
                    output: output,
                    duration_ms: duration_ms,
                    routed_to: "external:#{name}"
                  })

                {:error, reason} ->
                  Emissary.MCP.RequestLog.log_failed(ctx, request_id, %{
                    error: inspect(reason),
                    code: -32_603,
                    duration_ms: duration_ms,
                    routed_to: "external:#{name}"
                  })
              end
            end

            result
        end
    end
  end

  @doc """
  Check if a tool exists.
  """
  def exists?(name) do
    case Arca.Cache.get({:mcp_tool, name}) do
      {:ok, _} -> true
      :miss -> false
    end
  end

  @doc """
  Refresh the registry by re-reading from all providers.

  Useful for development/testing. In production, providers are
  loaded once at startup.
  """
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @doc """
  Audit every internal tool provider for missing per-action `kind`
  annotations. For each tool, checks that every value in
  `input_schema.properties.action.enum` has a matching key in
  `annotations.actions` with a non-nil `kind`.

  Skips `Emissary.MCP.ExternalProvider` (its `mcp_servers` definition is
  audited; the upstream-tool proxy is exempt — those are classified as
  `:external` by `Prism.AquaActions.kind_for/2` via namespacing).

  Returns `:ok` when all tools are clean, or `{:error, [missing]}` where
  each entry is `%{provider: module, tool: name, action: verb}`.
  """
  @spec audit_action_kinds() :: :ok | {:error, [map()]}
  def audit_action_kinds do
    providers = Application.get_env(:cyfr, :tool_providers, default_providers())

    missing =
      providers
      |> Enum.flat_map(fn module ->
        if Code.ensure_loaded?(module) and function_exported?(module, :tools, 0) do
          Enum.flat_map(module.tools(), fn tool ->
            audit_tool(module, tool)
          end)
        else
          []
        end
      end)

    case missing do
      [] -> :ok
      _ -> {:error, missing}
    end
  end

  defp audit_tool(module, tool) do
    enum =
      get_in(tool, [Access.key(:input_schema, %{}), "properties", "action", "enum"]) || []

    actions_meta =
      get_in(tool, [Access.key(:annotations, %{}), :actions]) ||
        get_in(tool, [Access.key(:annotations, %{}), "actions"]) ||
        %{}

    Enum.flat_map(enum, fn verb ->
      case Map.get(actions_meta, verb) do
        %{kind: k} when is_atom(k) -> []
        %{"kind" => k} when is_binary(k) -> []
        _ -> [%{provider: module, tool: tool.name, action: verb}]
      end
    end)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Load all configured providers into Arca.Cache
    load_providers()
    schedule_refresh()
    # Audit deferred to handle_continue so a bug in the audit (or in any
    # provider's tools/0) can't take down ToolRegistry at boot. Worst case,
    # a future refactor logs a warning instead of crashing the supervisor.
    {:ok, %{}, {:continue, :audit_action_kinds}}
  end

  @impl true
  def handle_continue(:audit_action_kinds, state) do
    log_action_kinds_audit()
    {:noreply, state}
  end

  # Run the action-kind audit and log any missing :kind annotations. The
  # audit never raises from this hook — drift is surfaced through logs (or,
  # for tests, by calling `audit_action_kinds/0` directly and asserting on
  # the result). Wrapped in try/rescue so a malformed tool definition can't
  # bring down ToolRegistry.
  defp log_action_kinds_audit do
    case audit_action_kinds() do
      :ok ->
        :ok

      {:error, missing} ->
        lines = Enum.map(missing, &"  - #{&1.tool}.#{&1.action} (#{inspect(&1.provider)})")
        Logger.warning("MCP tool actions missing :kind annotation:\n" <> Enum.join(lines, "\n"))
    end
  rescue
    e ->
      Logger.error("[ToolRegistry] action-kinds audit crashed: #{Exception.message(e)}")
      :ok
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    # Load new entries first, then clean up stale ones to avoid
    # a window where concurrent requests see missing tools
    old_tools =
      Arca.Cache.match({:mcp_tool, :_}) |> Enum.map(fn {{:mcp_tool, name}, _} -> name end)

    count = load_providers()

    new_tools =
      Arca.Cache.match({:mcp_tool, :_}) |> Enum.map(fn {{:mcp_tool, name}, _} -> name end)

    stale = old_tools -- new_tools
    for name <- stale, do: Arca.Cache.invalidate({:mcp_tool, name})
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_info(:refresh_cache, state) do
    # Overwrite in-place; load_providers uses Arca.Cache.put which replaces
    # existing entries atomically. Stale tools from removed providers will
    # expire naturally via TTL.
    load_providers()
    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp execute_tool_call(name, ctx, opts, execute_fn) do
    mcp_request_id = Keyword.get(opts, :mcp_request_id)

    try do
      task = Task.async(execute_fn)

      if mcp_request_id,
        do:
          Emissary.MCP.RunningTasks.register(
            mcp_request_id,
            task,
            ctx.user_id,
            ctx.org_id,
            ctx.project_id
          )

      result =
        case Task.yield(task, @tool_timeout_ms) do
          {:ok, result} ->
            result

          nil ->
            Task.shutdown(task, :brutal_kill)
            Logger.error("Tool #{name} timed out after #{@tool_timeout_ms}ms")
            {:error, {:timeout, "Tool #{name} timed out after #{@tool_timeout_ms}ms"}}
        end

      if mcp_request_id, do: Emissary.MCP.RunningTasks.unregister(mcp_request_id)
      result
    rescue
      e ->
        if mcp_request_id, do: Emissary.MCP.RunningTasks.unregister(mcp_request_id)
        Logger.error("Tool #{name} crashed: #{Exception.message(e)}")
        {:error, {:crashed, "Tool #{name} crashed: #{Exception.message(e)}"}}
    catch
      :exit, reason ->
        if mcp_request_id, do: Emissary.MCP.RunningTasks.unregister(mcp_request_id)
        Logger.error("Tool #{name} exited: #{inspect(reason)}")
        {:error, {:exit, "Tool #{name} exited unexpectedly"}}
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_cache, @refresh_interval)
  end

  defp load_providers do
    configured_providers = Application.get_env(:cyfr, :tool_providers, nil)
    defaults = default_providers()
    providers = configured_providers || defaults

    tools =
      providers
      |> Enum.flat_map(fn module ->
        if Code.ensure_loaded?(module) and function_exported?(module, :tools, 0) do
          module.tools()
          |> Enum.map(fn tool ->
            meta = %{
              name: tool.name,
              description: tool.description,
              input_schema: tool.input_schema,
              # MCP 2025-11-25 optional fields
              title: Map.get(tool, :title),
              icons: Map.get(tool, :icons),
              output_schema: Map.get(tool, :output_schema),
              annotations: Map.get(tool, :annotations),
              # Default-deny: tools require ctx.authenticated unless they
              # explicitly opt out via `requires_auth: false`.
              requires_auth: Map.get(tool, :requires_auth, true)
            }

            Arca.Cache.put({:mcp_tool, tool.name}, {module, meta}, @cache_ttl)
            tool.name
          end)
        else
          Logger.warning(
            "Tool provider #{inspect(module)} not available — skipping. Check that the application is started and the module exists."
          )

          []
        end
      end)

    Logger.info(
      "MCP ToolRegistry loaded #{length(tools)} tools from #{length(providers)} providers"
    )

    length(tools)
  end

  defp default_providers do
    [
      Emissary.MCP.Tools.SystemProvider
    ]
  end
end
