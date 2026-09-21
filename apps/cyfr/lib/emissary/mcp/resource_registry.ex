# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ResourceRegistry do
  @moduledoc """
  Registry for MCP resource providers.

  Discovers and aggregates resources from all configured providers.
  Handles routing of `resources/read` calls to the appropriate provider.

  ## Configuration

  Resource providers derive from `config :cyfr, :tool_providers`: a
  provider must export `read/2` and declare a non-empty resource surface.

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
  # Timeout for resource read calls (matches Cyfr.Ops.Catalog)
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
            logger_metadata = Cyfr.LoggerContext.capture()

            task =
              Task.Supervisor.async_nolink(Emissary.TaskSupervisor, fn ->
                Cyfr.LoggerContext.restore(logger_metadata)
                provider.read(ctx, uri)
              end)

            case Task.yield(task, @resource_timeout_ms) ||
                   Task.shutdown(task, :brutal_kill) do
              {:ok, result} ->
                result

              {:exit, reason} ->
                Logger.error("[ResourceRegistry] read crashed for #{uri}: #{inspect(reason)}")
                {:error, "Resource read failed for #{uri}"}

              nil ->
                Logger.error(
                  "[ResourceRegistry] read timed out after #{@resource_timeout_ms}ms for #{uri}"
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
    # Derived from the ONE roster (`:tool_providers`): the providers that
    # actually serve resources are the configured tool providers exporting
    # `read/2` with a non-empty resource surface. The separate
    # `:resource_providers` key was set by nothing anywhere and fell back
    # to a second, shorter hardcoded list.
    providers = resource_providers()
    # Watched before the catalogue is written, for the reason `handle_info
    # (:rebuild_cache, …)` gives: an owner lost mid-load must leave a
    # `:DOWN` in the mailbox, not a live monitor over a half-written table.
    state = watch_cache_owner(%{providers: providers})
    register_providers(providers)
    schedule_refresh()

    {:ok, state}
  end

  # The catalogue lives in `Arca.Cache`, whose table dies with its owner,
  # `Arca.Cache.Sweeper`. That owner is started by the `arca` application,
  # one app below this one, so no supervisor here can hold both it and
  # this registry — the `:rest_for_one` group that used to restart the two
  # together cannot span two applications. A monitor keeps the same
  # guarantee: when the owner goes, the catalogue goes with it, and this
  # rebuilds into the table the replacement owner creates rather than
  # answering an empty catalogue until the next refresh, a day later.
  @cache_owner_retry_ms 100

  defp watch_cache_owner(state) do
    case Arca.Cache.monitor_owner() do
      nil ->
        # No table to watch: it is gone, or not created yet. Come back and
        # REBUILD rather than only re-arm — an owner that died while this
        # was repopulating leaves nothing to monitor, and a monitor alone
        # would wait for a `:DOWN` that has already happened while the
        # catalogue stayed lost.
        Process.send_after(self(), :rebuild_cache, @cache_owner_retry_ms)
        Map.put(state, :cache_owner, nil)

      ref ->
        Map.put(state, :cache_owner, ref)
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{cache_owner: ref} = state) do
    send(self(), :rebuild_cache)
    {:noreply, state}
  end

  @impl true
  def handle_info(:rebuild_cache, %{providers: providers} = state) do
    # `ensure_table/0` is a call on the table's owner, so it answers only
    # once the supervisor has restarted it and the table is back. Until
    # then it says the cache is unavailable, and this waits rather than
    # writing a catalogue into a table about to be replaced.
    case Arca.Cache.Sweeper.ensure_table() do
      :ok ->
        # Watch the replacement owner BEFORE writing the catalogue into its
        # table. An owner killed while `register_providers/1` is halfway
        # through takes the entries written so far with it; the rest land in
        # the next owner's table, and a monitor armed AFTERWARDS finds that
        # owner alive and waits for a `:DOWN` that will never come, leaving
        # the catalogue permanently short. Armed first, the `:DOWN` is
        # already queued and the rebuild runs again as soon as this returns.
        state = watch_cache_owner(state)
        register_providers(providers)
        {:noreply, state}

      {:error, :cache_unavailable} ->
        Process.send_after(self(), :rebuild_cache, @cache_owner_retry_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:refresh_cache, %{providers: providers} = state) do
    register_providers(providers)
    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_refresh do
    Process.send_after(self(), :refresh_cache, @refresh_interval)
  end

  defp resource_providers do
    Cyfr.Ops.Catalog.available_providers()
    |> Enum.filter(fn provider ->
      function_exported?(provider, :read, 2) and
        (non_empty?(provider, :resources) or non_empty?(provider, :resource_templates))
    end)
  end

  defp non_empty?(provider, fun) do
    function_exported?(provider, fun, 0) and provider |> apply(fun, []) |> Enum.any?()
  end

  defp register_providers(providers) do
    for provider <- providers do
      if ResourceProvider.implements?(provider) do
        try do
          resources = provider.resources()
          Arca.Cache.put({:mcp_resource, provider}, resources, @cache_ttl)

          Logger.debug(
            "[ResourceRegistry] Registered #{length(resources)} resources from #{provider}"
          )

          # Also cache resource templates if the provider implements them
          if function_exported?(provider, :resource_templates, 0) do
            templates = provider.resource_templates()
            Arca.Cache.put({:mcp_resource_template, provider}, templates, @cache_ttl)

            Logger.debug(
              "[ResourceRegistry] Registered #{length(templates)} resource templates from #{provider}"
            )
          end
        rescue
          e ->
            Logger.warning(
              "[ResourceRegistry] Failed to load resources from #{provider}: #{inspect(e)}"
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
        Map.get(resource, :mimeType) || Map.get(resource, "mimeType") || Cyfr.MediaType.json()
    }
  end

  defp format_resource_template(template) do
    %{
      "uriTemplate" => Map.get(template, :uriTemplate) || Map.get(template, "uriTemplate"),
      "name" => Map.get(template, :name) || Map.get(template, "name"),
      "description" => Map.get(template, :description) || Map.get(template, "description"),
      "mimeType" =>
        Map.get(template, :mimeType) || Map.get(template, "mimeType") || Cyfr.MediaType.json()
    }
  end
end
