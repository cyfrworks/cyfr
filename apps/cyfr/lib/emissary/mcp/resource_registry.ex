# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ResourceRegistry do
  @moduledoc """
  Registry for MCP resource providers.

  Discovers and aggregates resources from all configured providers.
  Handles routing of `resources/read` calls to the appropriate provider.

  ## Configuration

  Optional. When `:resource_providers` is unset (the default), the built-in list
  `[Arca.MCP, Opus.MCP, Compendium.MCP, Sanctum.MCP]` is used, filtered to the
  modules that are loaded. Set the key only to override that list:

      config :cyfr, :resource_providers, [Arca.MCP, Opus.MCP]

  Providers must implement the `Emissary.MCP.ResourceProvider` behaviour.
  """

  use GenServer
  require Logger

  alias Emissary.MCP.ResourceProvider
  alias Sanctum.Context

  # 24 hours
  @cache_ttl :timer.hours(24)
  # Refresh 1 hour before TTL expires to prevent cache misses
  @refresh_interval :timer.hours(23)
  # Timeout for resource read calls (matches ToolRegistry)
  @resource_timeout_ms :timer.minutes(5)

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
  List all available resource templates from all providers.

  Returns a list of resource template descriptors for MCP `resources/templates/list`.
  """
  def list_resource_templates do
    Arca.Cache.match({:mcp_resource_template, :_})
    |> Enum.flat_map(fn {_key, templates} -> templates end)
    |> Enum.map(&format_resource_template/1)
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
            # `async_nolink`, not `Task.async`: the caller is the request process
            # and does not trap exits, so a linked provider crash would kill the
            # request instead of returning an error. Unlinked, it arrives here as
            # `{:exit, reason}`.
            task =
              Task.Supervisor.async_nolink(Emissary.TaskSupervisor, fn ->
                provider.read(ctx, uri)
              end)

            case Task.yield(task, @resource_timeout_ms) ||
                   Task.shutdown(task, :brutal_kill) do
              {:ok, result} ->
                result

              {:exit, reason} ->
                Logger.error("ResourceRegistry: read crashed for #{uri}: #{inspect(reason)}")
                {:error, "Resource read failed for #{uri}"}

              nil ->
                Logger.error(
                  "ResourceRegistry: read timed out after #{@resource_timeout_ms}ms for #{uri}"
                )

                {:error, "Resource read timed out after #{@resource_timeout_ms}ms"}
            end

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
    providers = Application.get_env(:cyfr, :resource_providers, default_providers())
    register_providers(providers)
    schedule_refresh()

    {:ok, %{providers: providers}}
  end

  @impl true
  def handle_info(:refresh_cache, %{providers: providers} = state) do
    register_providers(providers)
    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_refresh do
    Process.send_after(self(), :refresh_cache, @refresh_interval)
  end

  defp default_providers do
    [
      Arca.MCP,
      Opus.MCP,
      Compendium.MCP,
      Sanctum.MCP
    ]
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  defp register_providers(providers) do
    for provider <- providers do
      if ResourceProvider.implements?(provider) do
        try do
          resources = provider.resources()
          Arca.Cache.put({:mcp_resource, provider}, resources, @cache_ttl)

          Logger.debug(
            "ResourceRegistry: Registered #{length(resources)} resources from #{provider}"
          )

          # Also cache resource templates if the provider implements them
          if function_exported?(provider, :resource_templates, 0) do
            templates = provider.resource_templates()
            Arca.Cache.put({:mcp_resource_template, provider}, templates, @cache_ttl)

            Logger.debug(
              "ResourceRegistry: Registered #{length(templates)} resource templates from #{provider}"
            )
          end
        rescue
          e ->
            Logger.warning(
              "ResourceRegistry: Failed to load resources from #{provider}: #{inspect(e)}"
            )
        end
      end
    end
  end

  defp find_provider_for_scheme(scheme) do
    # Check concrete resources first
    result =
      Arca.Cache.match({:mcp_resource, :_})
      |> Enum.find(fn {_key, resources} ->
        Enum.any?(resources, fn r ->
          uri = Map.get(r, :uri) || Map.get(r, "uri") || ""
          String.starts_with?(uri, "#{scheme}://")
        end)
      end)

    case result do
      {{:mcp_resource, provider}, _resources} ->
        {:ok, provider}

      nil ->
        # Fall back to template cache (templates still need routing for resources/read)
        template_result =
          Arca.Cache.match({:mcp_resource_template, :_})
          |> Enum.find(fn {_key, templates} ->
            Enum.any?(templates, fn t ->
              uri = Map.get(t, :uriTemplate) || Map.get(t, "uriTemplate") || ""
              String.starts_with?(uri, "#{scheme}://")
            end)
          end)

        case template_result do
          {{:mcp_resource_template, provider}, _templates} -> {:ok, provider}
          nil -> {:error, :not_found}
        end
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
      "mimeType" =>
        Map.get(resource, :mimeType) || Map.get(resource, "mimeType") || "application/json"
    }
  end

  defp format_resource_template(template) do
    %{
      "uriTemplate" => Map.get(template, :uriTemplate) || Map.get(template, "uriTemplate"),
      "name" => Map.get(template, :name) || Map.get(template, "name"),
      "description" => Map.get(template, :description) || Map.get(template, "description"),
      "mimeType" =>
        Map.get(template, :mimeType) || Map.get(template, "mimeType") || "application/json"
    }
  end
end
