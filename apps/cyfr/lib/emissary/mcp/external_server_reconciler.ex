# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServerReconciler do
  @moduledoc """
  Makes vault mutations bite immediately for external MCP servers.

  Server processes cache resolved header credentials for their lifetime,
  so a rotate, rebind, revoke or delete of a referenced entry would
  otherwise keep flowing until a restart. This listener watches the
  global vault signal, finds the tenant's servers whose header templates
  reference the changed entry (`vault:<name>`), stops their processes and
  drops the tenant caches — the next call re-resolves fresh, or fails
  closed if the credential is gone.

  Reconcile failures are **not** swallowed: a raise or transient storage error
  emits `[:emissary, :external_server, :reconcile_failed]` telemetry and is
  retried (fast retries, then a periodic sweep), because dropping one would
  leave a revoked credential flowing until the server process restarts.
  """

  use GenServer

  require Logger

  @topic "sanctum:vault_changed"
  @relevant_verbs [:rotate, :rebind, :revoke, :delete]

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
  def handle_info({:vault_entry_changed_global, org_id, project_id, entry_id, verb}, state)
      when verb in @relevant_verbs do
    {:noreply, attempt(state, {org_id, project_id, entry_id}, 0)}
  end

  # A vault change with a verb we don't reconcile (e.g. :create) — expected;
  # ignore without the catch-all's warning.
  def handle_info({:vault_entry_changed_global, _org, _proj, _entry, _verb}, state) do
    {:noreply, state}
  end

  def handle_info({:retry, key, attempt_no}, state) do
    {:noreply, attempt(state, key, attempt_no)}
  end

  def handle_info(:sweep, state) do
    # Re-run every reconcile still pending (received but not yet succeeded), on
    # the slow cadence, so a persistent failure eventually resolves.
    state =
      Enum.reduce(Map.keys(state.pending), state, fn key, acc -> attempt(acc, key, 0) end)

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  defp attempt(state, {org_id, project_id, entry_id} = key, attempt_no) do
    case reconcile(org_id, project_id, entry_id) do
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
          [:emissary, :external_server, :reconcile_failed],
          %{count: 1},
          %{org_id: org_id, project_id: project_id, entry_id: entry_id, reason: inspect(reason)}
        )

        if attempt_no < @max_fast_retries do
          Process.send_after(self(), {:retry, key, attempt_no + 1}, @retry_backoff_ms)
        else
          Logger.warning(
            "[ExternalServerReconciler] reconcile of #{entry_id} still failing after " <>
              "#{attempt_no} retries; will retry on the next sweep"
          )
        end

        %{state | pending: Map.put(state.pending, key, attempt_no + 1)}
    end
  end

  @spec reconcile(String.t(), String.t(), String.t()) ::
          :ok | {:error, :unresolvable | term()}
  defp reconcile(org_id, project_id, entry_id) do
    ctx = Sanctum.Context.internal(org_id: org_id, project_id: project_id, scope: :project)

    case Arca.VaultStorage.get(org_id, entry_id) do
      {:ok, entry} ->
        with {:ok, servers} <- Arca.McpServerStorage.list(ctx) do
          stop_affected(servers, entry, org_id, project_id, entry_id, ctx)
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

  defp stop_affected(servers, entry, org_id, project_id, entry_id, ctx) do
    ref = "vault:#{entry.name}"
    affected = Enum.filter(servers, &references?(&1, ref))

    if affected != [] do
      org = Arca.QueryHelpers.normalize_org_id(org_id)
      proj = Arca.QueryHelpers.normalize_project_id(project_id)

      Enum.each(affected, fn server ->
        Logger.info(
          "[ExternalServerReconciler] restarting '#{server.name}' — " <>
            "a referenced vault entry changed"
        )

        Emissary.MCP.ExternalServerSupervisor.stop(server.name, org, proj)

        :telemetry.execute(
          [:emissary, :external_server, :reconciled],
          %{count: 1},
          %{server: server.name, org_id: org, project_id: proj, entry_id: entry_id}
        )
      end)

      Emissary.MCP.ExternalProvider.invalidate_external_tools_cache(ctx)
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp references?(server, ref) do
    headers =
      case Jason.decode(server.config_json || "{}") do
        {:ok, %{"headers" => %{} = headers}} -> headers
        _ -> %{}
      end

    Enum.any?(headers, fn {_name, template} -> template == ref end)
  end
end
