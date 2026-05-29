# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServerSupervisor do
  @moduledoc """
  DynamicSupervisor for external MCP server connections.

  Manages `ExternalServer` GenServer processes. Servers are started
  on-demand when `tools/list` is called or a tool is invoked — no
  eager startup loading.
  """

  @doc """
  Start an external server process if not already running.

  Returns `{:ok, pid}` if started or already running.
  """
  def ensure_started(config) do
    name = config[:name]
    org_id = Arca.QueryHelpers.normalize_org_id(config[:org_id])
    project_id = Arca.QueryHelpers.normalize_project_id(config[:project_id])

    case Registry.lookup(Emissary.MCP.ExternalServerRegistry, {name, org_id, project_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               __MODULE__,
               {Emissary.MCP.ExternalServer, config}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Stop an external server process.
  """
  def stop(name, org_id, project_id) do
    org_id = Arca.QueryHelpers.normalize_org_id(org_id)
    project_id = Arca.QueryHelpers.normalize_project_id(project_id)

    case Registry.lookup(Emissary.MCP.ExternalServerRegistry, {name, org_id, project_id}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        :ok
    end
  end

  @doc """
  Stop all external server processes for a given tenant.
  """
  def stop_all_for_tenant(org_id, project_id) do
    org_id = Arca.QueryHelpers.normalize_org_id(org_id)
    project_id = Arca.QueryHelpers.normalize_project_id(project_id)

    Emissary.MCP.ExternalServerRegistry
    |> Registry.select([
      {{{:"$1", :"$2", :"$3"}, :"$4", :_},
       [{:==, :"$2", org_id}, {:==, :"$3", project_id}], [:"$4"]}
    ])
    |> Enum.each(&DynamicSupervisor.terminate_child(__MODULE__, &1))
  end
end