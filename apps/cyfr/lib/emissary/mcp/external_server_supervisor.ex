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
  Start an external server process if not already running, restarting it
  when its stored configuration has changed.

  Each server process registers the digest of the config it booted with as
  its Registry value. Callers rebuild the config from the stored row on
  every call, so comparing digests here reconciles a changed URL, header
  template, or timeout by replacing the process — previously a running
  process served its boot-time config for its whole lifetime and
  `mcp_servers.refresh` could never apply a template change.

  Returns `{:ok, pid}` if started, already running, or restarted.
  """
  def ensure_started(config) do
    name = config[:name]
    org_id = Arca.QueryHelpers.normalize_org_id(config[:org_id])
    project_id = Arca.QueryHelpers.normalize_project_id(config[:project_id])
    digest = config_digest(config)

    case Registry.lookup(Emissary.MCP.ExternalServerRegistry, {name, org_id, project_id}) do
      [{pid, ^digest}] ->
        {:ok, pid}

      [{pid, _stale_digest}] ->
        # Config changed since this process booted — replace it. In-flight
        # calls to the old process fail once; the config just changed.
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        start_child(config)

      [] ->
        start_child(config)
    end
  end

  defp start_child(config) do
    case DynamicSupervisor.start_child(
           __MODULE__,
           {Emissary.MCP.ExternalServer, config}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Digest over the config a server process serves — the raw header TEMPLATE
  (names and `secret:` references, never resolved values), url and timeout.
  Secret rotation does not change the digest (`reinitialize` re-resolves
  values); editing the template does.
  """
  def config_digest(config) do
    :erlang.phash2({config[:url], config[:headers] || %{}, config[:timeout_ms]})
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
end
