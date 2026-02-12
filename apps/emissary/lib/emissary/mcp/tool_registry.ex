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
  │  │   └── {:mcp_tool, "storage"} => {Arca.MCP, %{desc, ...}}     │
  │  │   └── {:mcp_tool, "execution"} => {Opus.MCP, %{...}}        │
  │  └── Providers: [Arca.MCP, Opus.MCP, ...]                       │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Usage

      # List all tools
      ToolRegistry.list_tools()

      # Call a tool
      ToolRegistry.call("storage", context, %{"path" => ["test"]})

  ## Future: Distributed

  When running multiple workers, this registry will be extended to
  track node availability and route using :pg or Horde.
  """

  use GenServer
  require Logger

  alias Sanctum.Context

  # 24 hours
  @cache_ttl :timer.hours(24)

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
    case Arca.Cache.get({:mcp_tool, name}) do
      {:ok, {module, _meta}} ->
        try do
          module.handle(name, ctx, args)
        rescue
          e ->
            Logger.error("Tool #{name} crashed: #{Exception.message(e)}")
            {:error, "Internal error: #{Exception.message(e)}"}
        end

      :miss ->
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

    {:ok, %{}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    Arca.Cache.delete_match({:mcp_tool, :_})
    count = load_providers()
    {:reply, {:ok, count}, state}
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp load_providers do
    providers = Application.get_env(:emissary, :tool_providers, default_providers())

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
          Logger.warning("Tool provider #{inspect(module)} not available")
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
