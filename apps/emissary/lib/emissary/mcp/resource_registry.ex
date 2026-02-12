defmodule Emissary.MCP.ResourceRegistry do
  @moduledoc """
  Registry for MCP resource providers.

  Discovers and aggregates resources from all configured providers.
  Handles routing of `resources/read` calls to the appropriate provider.

  ## Configuration

      config :emissary, :resource_providers, [
        Arca.MCP,
        Opus.MCP
      ]

  Providers must implement the `Emissary.MCP.ResourceProvider` behaviour.
  """

  use GenServer
  require Logger

  alias Emissary.MCP.ResourceProvider
  alias Sanctum.Context

  # 24 hours
  @cache_ttl :timer.hours(24)

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  List all available resources from all providers.

  Returns a list of resource descriptors for MCP `resources/list`.
  """
  def list_resources do
    Arca.Cache.match({:mcp_resource, :_})
    |> Enum.flat_map(fn {_key, resources} -> resources end)
    |> Enum.map(&format_resource/1)
  end

  @doc """
  Read a resource by URI.

  Routes the request to the appropriate provider based on URI scheme.
  """
  def read(%Context{} = ctx, uri) when is_binary(uri) do
    case parse_uri_scheme(uri) do
      {:ok, scheme} ->
        case find_provider_for_scheme(scheme) do
          {:ok, provider} ->
            provider.read(ctx, uri)

          {:error, :not_found} ->
            {:error, "No provider found for scheme: #{scheme}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Load providers from config
    providers = Application.get_env(:emissary, :resource_providers, default_providers())
    register_providers(providers)

    {:ok, %{providers: providers}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp default_providers do
    [
      Arca.MCP,
      Opus.MCP,
      Compendium.MCP,
      Sanctum.MCP
    ]
  end

  defp register_providers(providers) do
    for provider <- providers do
      if ResourceProvider.implements?(provider) and function_exported?(provider, :resources, 0) do
        try do
          resources = provider.resources()
          Arca.Cache.put({:mcp_resource, provider}, resources, @cache_ttl)
          Logger.debug("ResourceRegistry: Registered #{length(resources)} resources from #{provider}")
        rescue
          e ->
            Logger.warning("ResourceRegistry: Failed to load resources from #{provider}: #{inspect(e)}")
        end
      end
    end
  end

  defp find_provider_for_scheme(scheme) do
    result =
      Arca.Cache.match({:mcp_resource, :_})
      |> Enum.find(fn {_key, resources} ->
        Enum.any?(resources, fn r ->
          uri = Map.get(r, :uri) || Map.get(r, "uri") || ""
          String.starts_with?(uri, "#{scheme}://")
        end)
      end)

    case result do
      {{:mcp_resource, provider}, _resources} -> {:ok, provider}
      nil -> {:error, :not_found}
    end
  end

  defp parse_uri_scheme(uri) do
    case String.split(uri, "://", parts: 2) do
      [scheme, _rest] when byte_size(scheme) > 0 -> {:ok, scheme}
      _ -> {:error, "Invalid URI format: #{uri}"}
    end
  end

  defp format_resource(resource) do
    %{
      "uri" => Map.get(resource, :uri) || Map.get(resource, "uri"),
      "name" => Map.get(resource, :name) || Map.get(resource, "name"),
      "description" => Map.get(resource, :description) || Map.get(resource, "description"),
      "mimeType" => Map.get(resource, :mimeType) || Map.get(resource, "mimeType") || "application/json"
    }
  end
end
