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
  """

  use GenServer

  require Logger

  @topic "sanctum:vault_changed"
  @relevant_verbs [:rotate, :rebind, :revoke, :delete]

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
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:vault_entry_changed_global, org_id, project_id, entry_id, verb}, state)
      when verb in @relevant_verbs do
    reconcile(org_id, project_id, entry_id)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reconcile(org_id, project_id, entry_id) do
    ctx = Sanctum.Context.internal(org_id: org_id, project_id: project_id, scope: :project)

    with {:ok, entry} <- Arca.VaultStorage.get(org_id, entry_id),
         {:ok, servers} <- Arca.McpServerStorage.list(ctx) do
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
    else
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning("[ExternalServerReconciler] reconcile failed: #{Exception.message(error)}")
  end

  defp references?(server, ref) do
    headers =
      case Jason.decode(server.config_json || "{}") do
        {:ok, %{"headers" => %{} = headers}} -> headers
        _ -> %{}
      end

    Enum.any?(headers, fn {_name, template} -> template == ref end)
  end
end
