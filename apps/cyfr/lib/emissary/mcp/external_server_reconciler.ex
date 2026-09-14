# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServerReconciler do
  @moduledoc """
  Makes vault mutations bite immediately for external MCP servers.

  Server processes cache resolved header credentials for their lifetime,
  so a rotate, rebind, revoke, delete or rename of a referenced entry would
  otherwise keep flowing until a restart. This listener watches the
  global vault signal, finds the tenant's servers whose header templates
  reference the changed entry (`vault:<name>`), stops their processes and
  drops the tenant caches — the next call re-resolves fresh, or fails
  closed if the credential is gone.

  A rename belongs in that set even though it touches no material: header
  templates reference an entry by NAME and resolve at request time, so moving
  a name between entries changes what a live server sends.

  Reconcile failures are **not** swallowed: a raise or transient storage error
  emits `[:cyfr, :emissary, :external_server, :reconcile_failed]` telemetry and is
  retried (fast retries, then a periodic sweep), because dropping one would
  leave a revoked credential flowing until the server process restarts.
  """

  use GenServer

  require Logger

  @topic Cyfr.Bus.vault_changed_global()
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
    Phoenix.PubSub.subscribe(Emissary.PubSub, @topic)
    schedule_sweep()
    {:ok, %{pending: %{}}}
  end

  @impl GenServer
  def handle_info({:vault_entry_changed_global, athanor_id, entry_id, verb, meta}, state)
      when verb in @relevant_verbs do
    {:noreply, attempt(state, {athanor_id, entry_id}, meta, 0)}
  end

  # A vault change with a verb we don't reconcile (e.g. :create) — expected;
  # ignore without the catch-all's warning.
  def handle_info({:vault_entry_changed_global, _athanor, _entry, _verb, _meta}, state) do
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

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(message, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, message)
    {:noreply, state}
  end

  defp attempt(state, {athanor_id, entry_id} = key, meta, attempt_no) do
    case Cyfr.ControlPlane.when_owner(fn -> reconcile(athanor_id, entry_id, meta) end) do
      # Kept pending: the next sweep asks again.
      :not_owner ->
        %{state | pending: Map.put(state.pending, key, %{attempts: attempt_no, meta: meta})}

      :ok ->
        %{state | pending: Map.delete(state.pending, key)}

      {:error, :unresolvable} ->
        # The changed entry cannot be identified (hard-deleted row); a retry
        # cannot help, so stop tracking it.
        Logger.warning(
          "[ExternalServerReconciler] cannot resolve changed vault entry #{entry_id}; dropping"
        )

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

  @spec reconcile(String.t(), String.t(), map()) :: :ok | {:error, :unresolvable | term()}
  defp reconcile(athanor_id, entry_id, meta) do
    ctx = Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)

    case Arca.VaultStorage.get(athanor_id, entry_id) do
      {:ok, entry} ->
        with {:ok, servers} <- Arca.McpServerStorage.list(ctx) do
          stop_affected(servers, entry, meta, athanor_id, entry_id, ctx)
          :ok
        end

      # The row is gone entirely — its name is unknown, so no server can be
      # matched. Terminal, not retryable.
      {:error, :not_found} ->
        {:error, :unresolvable}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp stop_affected(servers, entry, meta, athanor_id, entry_id, ctx) do
    # Reconcile servers referencing both the current and vacated vault-entry names.
    refs =
      [entry.name | List.wrap(meta[:old_name])]
      |> Enum.uniq()
      |> Enum.map(&Emissary.MCP.VaultRef.build/1)

    affected = Enum.filter(servers, fn server -> Enum.any?(refs, &references?(server, &1)) end)

    if affected != [] do
      Enum.each(affected, fn server ->
        Logger.info(
          "[ExternalServerReconciler] restarting '#{server.name}' — " <>
            "a referenced vault entry changed"
        )

        Emissary.MCP.ExternalServerSupervisor.stop(server.name, athanor_id)

        :telemetry.execute(
          [:cyfr, :emissary, :external_server, :reconciled],
          %{count: 1},
          %{server: server.name, athanor_id: athanor_id, entry_id: entry_id}
        )
      end)

      Emissary.MCP.ExternalProvider.invalidate_external_tools_cache(ctx)
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp references?(server, ref) do
    headers =
      case Arca.McpServerStorage.config(server) do
        %{"headers" => %{} = headers} -> headers
        _ -> %{}
      end

    Enum.any?(headers, fn {_name, template} -> template == ref end)
  end
end
