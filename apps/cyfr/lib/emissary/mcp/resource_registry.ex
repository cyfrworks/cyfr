# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ResourceRegistry do
  @moduledoc """
  The MCP resource catalogue: a discovery cache derived from the operation
  table, and the lookup that names which declared operation admits a read.

  `resources/list` and `resources/templates/list` read the advertised
  lists (`c:Cyfr.Ops.Provider.resources/0` and
  `c:Cyfr.Ops.Provider.resource_templates/0` of every configured
  provider). `resolve/1` maps a URI's scheme to the one operation that
  declares it in `resource_schemes`, so `resources/read` becomes a call of
  that operation through the catalog's gate
  (`Cyfr.Ops.Catalog.call_external/4`) — this module reads nothing and
  authorizes nothing. That every advertised scheme has exactly one owner
  is `Cyfr.Ops.Catalog.audit_resource_schemes/1`'s boot check.
  """

  use GenServer
  require Logger

  # 24 hours
  @cache_ttl :timer.hours(24)
  # Refresh 1 hour before TTL expires to prevent cache misses
  @refresh_interval :timer.hours(23)

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
  The declared operation that admits a read of `uri`: `{:ok, tool, action}`,
  or a typed argument refusal for a URI that names no scheme or a scheme
  no operation declares.
  """
  @spec resolve(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, {:invalid_argument, String.t()}}
  def resolve(uri) when is_binary(uri) do
    case Cyfr.Ops.Provider.resource_scheme(uri) do
      {:ok, scheme} ->
        case Arca.Cache.get({:mcp_resource_scheme, scheme}) do
          {:ok, {tool, action}} -> {:ok, tool, action}
          :miss -> {:error, {:invalid_argument, "No provider found for scheme: #{scheme}"}}
        end

      :error ->
        {:error, {:invalid_argument, "Invalid URI format: #{uri}"}}
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Derived from the ONE roster (`:tool_providers`): every loadable
    # configured provider, whose advertised resources and declared
    # resource operations are the catalogue.
    providers = Cyfr.Ops.Catalog.available_providers()
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

  # The advertised lists per provider, and the scheme index the operation
  # table declares. A provider whose declarations cannot be read is
  # skipped with a warning rather than taking the catalogue down; the
  # catalog's boot audit is where a broken declaration refuses.
  defp register_providers(providers) do
    for provider <- providers do
      try do
        resources = advertised(provider, :resources)
        Arca.Cache.put({:mcp_resource, provider}, resources, @cache_ttl)

        templates = advertised(provider, :resource_templates)
        Arca.Cache.put({:mcp_resource_template, provider}, templates, @cache_ttl)

        for tool <- provider.tools(),
            %Cyfr.Ops.Operation{} = operation <- Map.get(tool, :operations, []),
            scheme <- operation.resource_schemes do
          Arca.Cache.put(
            {:mcp_resource_scheme, scheme},
            {operation.tool, operation.action},
            @cache_ttl
          )
        end

        Logger.debug(
          "[ResourceRegistry] Registered #{length(resources)} resources and " <>
            "#{length(templates)} resource templates from #{inspect(provider)}"
        )
      rescue
        e ->
          Logger.warning(
            "[ResourceRegistry] Failed to load resources from #{inspect(provider)}: " <>
              inspect(e)
          )
      end
    end
  end

  defp advertised(provider, fun) do
    if function_exported?(provider, fun, 0), do: apply(provider, fun, []), else: []
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
