# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServerReconciler do
  @moduledoc """
  Makes vault mutations and archives bite immediately for external MCP
  servers.

  Server processes cache resolved header credentials for their lifetime,
  and the MCP bridge holds a stdio server's resolved env for its lease, so
  a rotate, rebind, revoke, delete or rename of a referenced entry would
  otherwise keep flowing until a restart. This listener watches the global
  vault signal and acts on the names it carries — a signal that names no
  entry matches every template:

    1. in memory first, the bridge controller releases every live stdio
       owner of the athanor whose env templates reference a changed name
       (`Emissary.MCP.Bridge.release_referencing/2`), which needs no store;
    2. then the tenant's servers whose header or env templates reference one
       (`Emissary.MCP.VaultRef.names/1`) have their processes stopped —
       which ends their calls in flight and releases their backends — and
       their epochs raised, so no grant issued before the change is honoured
       again; the tenant caches are dropped. The next call re-resolves
       fresh, or fails closed if the credential is gone.

  A rename belongs in that set even though it touches no material: header
  templates reference an entry by NAME and resolve at request time, so moving
  a name between entries changes what a live server sends.

  An archived athanor (`Cyfr.Bus.athanor_archived_global/0`) has every one
  of its server processes stopped.

  Reconcile failures are **not** swallowed: a raise or transient storage error
  emits `[:cyfr, :emissary, :external_server, :reconcile_failed]` telemetry and is
  retried (fast retries, then a periodic sweep), because dropping one would
  leave a revoked credential flowing until the server process restarts.

  A signal can also be lost — delivered to a member that was restarting,
  or dropped by the PubSub itself. The periodic sweep therefore also walks
  every live server process on this member
  (`Emissary.MCP.ExternalServerSupervisor.live/0`), rereads the revision
  tokens of the entries it resolved against
  (`Emissary.MCP.ExternalServer.vault_revisions/2`,
  `Sanctum.VaultReader.revisions/2`: the payload revision and the binding
  digest) and restarts, as above, any whose token moved — a rotation or a
  rebind — or whose entry is no longer active. A lost signal of any
  relevant verb costs at most one sweep interval.
  """

  use GenServer

  require Logger

  alias Cyfr.Bus.{AthanorArchived, VaultEntryChanged}

  @relevant_verbs [:rotate, :rebind, :revoke, :delete, :rename]

  @doc "The vault verbs this reconciler acts on — pinned by `Sanctum.VaultTest`."
  @spec relevant_verbs() :: [atom()]
  def relevant_verbs, do: @relevant_verbs

  # A reconcile that raises or hits a transient storage error is retried
  # instead of being dropped: a swallowed failure leaves a revoked credential
  # flowing until the server process restarts. Fast retries cover blips; the
  # periodic sweep drains anything still failing so a longer outage recovers.
  @max_fast_retries 5
  @retry_backoff_ms 2_000
  @sweep_interval_ms :timer.minutes(5)

  def start_link(opts \\ []) do
    if Application.get_env(:cyfr, :external_server_reconciler_enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl GenServer
  def init(_opts) do
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.vault_changed_global())
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.athanor_archived_global())
    schedule_sweep()
    {:ok, %{pending: %{}}}
  end

  @impl GenServer
  def handle_info(%VaultEntryChanged{kind: verb} = changed, state)
      when verb in @relevant_verbs do
    meta = %{name: changed.name, old_name: changed.old_name}
    {:noreply, attempt(state, {changed.athanor_id, changed.entry_id}, meta, 0)}
  end

  # A vault change with a verb we don't reconcile (e.g. :create) — expected;
  # ignore without the catch-all's warning.
  def handle_info(%VaultEntryChanged{}, state), do: {:noreply, state}

  def handle_info(%AthanorArchived{athanor_id: athanor_id}, state) do
    Emissary.MCP.ExternalServerSupervisor.stop_athanor(athanor_id)

    Emissary.MCP.ExternalProvider.invalidate_external_tools_cache(
      Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)
    )

    {:noreply, state}
  end

  def handle_info({:retry, key, meta, attempt_no}, state) do
    {:noreply, attempt(state, key, meta, attempt_no)}
  end

  def handle_info(:sweep, state) do
    # Re-run every reconcile still pending (received but not yet succeeded), on
    # the slow cadence, so a persistent failure eventually resolves.
    state =
      Enum.reduce(state.pending, state, fn {key, %{meta: meta}}, acc ->
        attempt(acc, key, meta, 0)
      end)

    # Then catch what no signal said: a live server whose vault revisions
    # moved under it.
    _ = while_held(&sweep_revisions/0)

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(message, state) do
    Cyfr.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # A reconcile stops server processes and raises epochs, which is work a
  # member admits, so it runs only while this member holds its cell slot
  # (`Arca.ControlPlane.held?/0`) and is asked on every attempt rather than
  # once: a member that loses the slot mid-retry stops here.
  defp attempt(state, {athanor_id, entry_id} = key, meta, attempt_no) do
    case while_held(fn -> reconcile(athanor_id, entry_id, meta) end) do
      # Kept pending: the next sweep asks again.
      :not_owner ->
        %{state | pending: Map.put(state.pending, key, %{attempts: attempt_no, meta: meta})}

      :ok ->
        %{state | pending: Map.delete(state.pending, key)}

      {:error, reason} ->
        :telemetry.execute(
          [:cyfr, :emissary, :external_server, :reconcile_failed],
          %{count: 1},
          # As data: `Arca.AuditHandler` redacts this metadata by key, and
          # key-based redaction cannot see inside a flattened string.
          %{athanor_id: athanor_id, entry_id: entry_id, reason: reason}
        )

        if attempt_no < @max_fast_retries do
          Process.send_after(self(), {:retry, key, meta, attempt_no + 1}, @retry_backoff_ms)
        else
          Logger.warning(
            "[ExternalServerReconciler] reconcile of #{entry_id} still failing after " <>
              "#{attempt_no} retries; will retry on the next sweep"
          )
        end

        %{state | pending: Map.put(state.pending, key, %{attempts: attempt_no + 1, meta: meta})}
    end
  end

  defp while_held(fun), do: if(Arca.ControlPlane.held?(), do: fun.(), else: :not_owner)

  @spec reconcile(String.t(), String.t(), map()) :: :ok | {:error, term()}
  defp reconcile(athanor_id, entry_id, meta) do
    ctx = Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)
    names = changed_names(meta)

    _released = Emissary.MCP.Bridge.release_referencing(athanor_id, names)

    with {:ok, servers} <- Arca.McpServerStorage.list(Sanctum.Context.actor(ctx)) do
      stop_affected(servers, names, athanor_id, entry_id, ctx)
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  # The names a live template may spell for the changed entry: its name and,
  # on a rename, the one it vacated. A signal naming none matches every
  # template.
  defp changed_names(meta) do
    case Enum.filter([meta[:name], meta[:old_name]], &is_binary/1) do
      [] -> :any
      names -> names
    end
  end

  # A server whose epoch could not be raised is retried whole: stopping a
  # process and raising an epoch again are both harmless.
  defp stop_affected(servers, names, athanor_id, entry_id, ctx) do
    servers
    |> Enum.filter(&references?(&1, names))
    |> stop_servers(athanor_id, entry_id, ctx)
  end

  defp stop_servers(affected, athanor_id, entry_id, ctx) do
    results =
      Enum.map(affected, fn server ->
        Logger.info(
          "[ExternalServerReconciler] restarting '#{server.name}' — " <>
            "a referenced vault entry changed"
        )

        Emissary.MCP.ExternalServerSupervisor.stop(server.name, athanor_id)
        bumped = Arca.McpServerStorage.bump_epoch(Sanctum.Context.actor(ctx), server.id)

        :telemetry.execute(
          [:cyfr, :emissary, :external_server, :reconciled],
          %{count: 1},
          %{server: server.name, athanor_id: athanor_id, entry_id: entry_id}
        )

        bumped
      end)

    if affected != [], do: Emissary.MCP.ExternalProvider.invalidate_external_tools_cache(ctx)

    case Enum.find(results, &match?({:error, reason} when reason != :not_found, &1)) do
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  @doc false
  # The revision pass, one athanor at a time. A server that is not
  # connected resolved nothing and is skipped; an athanor whose revisions
  # or rows cannot be read is left for the next pass, counted.
  @spec sweep_revisions() :: :ok
  def sweep_revisions do
    Emissary.MCP.ExternalServerSupervisor.live()
    |> Enum.flat_map(fn {name, athanor_id, pid} ->
      case Emissary.MCP.ExternalServer.vault_revisions(pid) do
        {:ok, recorded} when map_size(recorded) > 0 -> [{athanor_id, name, recorded}]
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.each(fn {athanor_id, held} -> sweep_athanor(athanor_id, held) end)
  end

  defp sweep_athanor(athanor_id, held) do
    names = held |> Enum.flat_map(fn {_athanor, _name, recorded} -> Map.keys(recorded) end)

    with {:ok, current} <- Sanctum.VaultReader.revisions(athanor_id, Enum.uniq(names)),
         [_ | _] = moved <- moved(held, current) do
      ctx = Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)
      moved_names = moved |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()
      _released = Emissary.MCP.Bridge.release_referencing(athanor_id, moved_names)

      with {:ok, servers} <- Arca.McpServerStorage.list(Sanctum.Context.actor(ctx)) do
        server_names = MapSet.new(moved, &elem(&1, 0))
        affected = Enum.filter(servers, &MapSet.member?(server_names, &1.name))
        stop_servers(affected, athanor_id, nil, ctx)
      end
    end
    |> case do
      {:error, reason} ->
        :telemetry.execute(
          [:cyfr, :emissary, :external_server, :reconcile_failed],
          %{count: 1},
          %{athanor_id: athanor_id, entry_id: nil, reason: reason}
        )

      _ ->
        :ok
    end
  rescue
    error ->
      :telemetry.execute(
        [:cyfr, :emissary, :external_server, :reconcile_failed],
        %{count: 1},
        %{athanor_id: athanor_id, entry_id: nil, reason: Exception.message(error)}
      )
  end

  # Each live server with the names whose revision token is no longer the
  # one it resolved against: rotated, rebound, or no longer active.
  defp moved(held, current) do
    for {_athanor, name, recorded} <- held,
        stale = for({entry, rev} <- recorded, Map.get(current, entry) != rev, do: entry),
        stale != [],
        do: {name, stale}
  end

  defp references?(server, names) do
    config = Arca.McpServerStorage.config(server)

    headers =
      case config["headers"] do
        %{} = headers -> Emissary.MCP.VaultRef.names(headers)
        _ -> []
      end

    referenced = headers ++ Emissary.MCP.BackendDefinition.entry_names(config["backends"])

    case names do
      :any -> referenced != []
      names -> Enum.any?(referenced, &(&1 in names))
    end
  end
end
