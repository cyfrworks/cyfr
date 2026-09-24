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

  Registers each server's configuration digest. A changed transport, URL,
  header template, backend, epoch or timeout replaces the process before the
  next call.

  Returns `{:ok, pid}` if started, already running, or restarted.
  """
  def ensure_started(config) do
    name = config[:name]
    athanor_id = Emissary.MCP.ExternalServer.athanor_id!(config)
    digest = config_digest(config)

    case Registry.lookup(Emissary.MCP.ExternalServerRegistry, {name, athanor_id}) do
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
  Digest over the config a server process serves — the row it serves, its
  transport and epoch, the raw header TEMPLATE and backend definitions
  (names and vault references, never resolved values), url and timeout.
  Every write to a row raises its epoch, so any change to the row, a row
  deleted and recreated under the same name, or a stdio server restarted
  changes the digest.
  """
  def config_digest(config) do
    :erlang.phash2(
      {config[:id], config[:transport], config[:epoch], config[:url], config[:headers] || %{},
       config[:backends] || [], config[:timeout_ms]}
    )
  end

  @doc """
  Every external server process running on this member, as
  `{name, athanor_id, pid}`: what the reconciler's periodic pass walks.
  """
  @spec live() :: [{String.t(), String.t(), pid()}]
  def live do
    Registry.select(Emissary.MCP.ExternalServerRegistry, [
      {{{:"$1", :"$2"}, :"$3", :_}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  @doc "Stop every external server process serving `athanor_id`."
  @spec stop_athanor(String.t()) :: :ok
  def stop_athanor(athanor_id) when is_binary(athanor_id) do
    Emissary.MCP.ExternalServerRegistry
    |> Registry.select([{{{:"$1", athanor_id}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {_name, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid) end)
  end

  @doc """
  Stop an external server process.
  """
  def stop(name, athanor_id) do
    case Registry.lookup(Emissary.MCP.ExternalServerRegistry, {name, athanor_id}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        :ok
    end
  end
end
