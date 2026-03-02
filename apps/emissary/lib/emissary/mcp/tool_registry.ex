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
  """
  def call(name, %Context{} = ctx, args) when is_map(args) do
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
      {:ok, {module, _meta}} ->
        result =
          try do
            task = Task.async(fn -> module.handle(name, ctx, args) end)

            case Task.yield(task, @tool_timeout_ms) do
              {:ok, result} ->
                result

              nil ->
                Task.shutdown(task, :brutal_kill)
                Logger.error("Tool #{name} timed out after #{@tool_timeout_ms}ms")
                {:error, {:timeout, "Tool #{name} timed out after #{@tool_timeout_ms}ms"}}
            end
          rescue
            e ->
              Logger.error("Tool #{name} crashed: #{Exception.message(e)}")
              {:error, {:crashed, "Tool #{name} crashed: #{Exception.message(e)}"}}
          catch
            :exit, reason ->
              Logger.error("Tool #{name} exited: #{inspect(reason)}")
              {:error, {:exit, "Tool #{name} exited unexpectedly"}}
          end

        if should_log? do
          duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
          case result do
            {:ok, output} ->
              Emissary.MCP.RequestLog.log_completed(request_id, %{
                output: output,
                duration_ms: duration_ms,
                routed_to: inspect(module)
              })
            {:error, reason} ->
              Emissary.MCP.RequestLog.log_failed(request_id, %{
                error: inspect(reason),
                code: -32_603,
                duration_ms: duration_ms,
                routed_to: inspect(module)
              })
          end
        end

        result

      :miss ->
        if should_log? do
          duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
          Emissary.MCP.RequestLog.log_failed(request_id, %{
            error: "Unknown tool: #{name}",
            code: -32_601,
            duration_ms: duration_ms
          })
        end
        {:error, "Unknown tool: #{name}"}
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

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Load all configured providers into Arca.Cache
    load_providers()
    schedule_refresh()

    {:ok, %{}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    # Load new entries first, then clean up stale ones to avoid
    # a window where concurrent requests see missing tools
    old_tools = Arca.Cache.match({:mcp_tool, :_}) |> Enum.map(fn {{:mcp_tool, name}, _} -> name end)
    count = load_providers()
    new_tools = Arca.Cache.match({:mcp_tool, :_}) |> Enum.map(fn {{:mcp_tool, name}, _} -> name end)
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

  # ============================================================================
  # Internal
  # ============================================================================

  defp schedule_refresh do
    Process.send_after(self(), :refresh_cache, @refresh_interval)
  end

  defp load_providers do
    configured_providers = Application.get_env(:emissary, :tool_providers, nil)
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
              annotations: Map.get(tool, :annotations)
            }

            Arca.Cache.put({:mcp_tool, tool.name}, {module, meta}, @cache_ttl)
            tool.name
          end)
        else
          Logger.warning("Tool provider #{inspect(module)} not available — skipping. Check that the application is started and the module exists.")
          []
        end
      end)

    Logger.info("MCP ToolRegistry loaded #{length(tools)} tools from #{length(providers)} providers")
    length(tools)
  end

  defp default_providers do
    [
      Emissary.MCP.Tools.SystemProvider
    ]
  end
end
