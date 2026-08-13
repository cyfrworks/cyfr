# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RunningTasks do
  @moduledoc """
  Tracks the process doing the work for an in-flight request, so the transport
  can stop it when the caller goes away.

  Keyed on `%Sanctum.Context{}.request_id` — the server-minted UUID7 that
  `EmissaryWeb.MCPController` stamps on every request. It used to be keyed on
  the *client-supplied* JSON-RPC `id`, which two callers can trivially pick the
  same value for: `{"id": 1}` is the most common request id there is. Two
  concurrent calls then shared one ETS row, so the second registration silently
  evicted the first and a cancellation reached whichever task happened to own
  the key. A server-minted id cannot collide.

  Uses a GenServer to monitor task processes and auto-clean ETS entries when
  tasks die. The main ETS table remains `:public` for fast reads from any process.

  ## Why there is no authorization check

  Cancellation is not reachable from the wire. MCP 2026-07-28 has no
  cancel-someone-else's-request operation: on Streamable HTTP the *only*
  cancellation signal is the caller closing its own response stream, and the
  key needed to act on that is one the transport already holds for the
  connection in front of it. Nothing accepts a request id from a caller, so
  there is no confused deputy to guard against.
  """

  use GenServer
  require Logger

  @table __MODULE__

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register the process doing the work for `request_id`.

  The GenServer monitors it and auto-cleans on exit, so a caller that never
  reaches `unregister/1` — because it crashed, or was killed — leaves nothing
  behind.
  """
  def register(request_id, %Task{pid: pid}) when is_binary(request_id) do
    :ets.insert(@table, {request_id, pid})
    GenServer.cast(__MODULE__, {:monitor, request_id, pid})
    :ok
  end

  @doc """
  Unregister a task after it completes.
  """
  def unregister(request_id) when is_binary(request_id) do
    GenServer.cast(__MODULE__, {:unregister, request_id})
    :ok
  end

  @doc """
  Stop the work registered for `request_id`.

  Returns `:ok` when a task was found and killed, `{:error, :not_found}`
  otherwise — which is the ordinary outcome when the work had already finished
  by the time the caller hung up.
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(request_id) when is_binary(request_id) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, pid}] ->
        Process.exit(pid, :cancelled)
        GenServer.cast(__MODULE__, {:unregister, request_id})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    # monitors: %{monitor_ref => request_id}
    # pids: %{request_id => monitor_ref}
    {:ok, %{monitors: %{}, pids: %{}}}
  end

  @impl true
  def handle_cast({:monitor, request_id, pid}, state) do
    # Clean up any existing monitor for this request_id
    state = do_demonitor(request_id, state)

    ref = Process.monitor(pid)

    state = %{
      state
      | monitors: Map.put(state.monitors, ref, request_id),
        pids: Map.put(state.pids, request_id, ref)
    }

    {:noreply, state}
  end

  @impl true
  def handle_cast({:unregister, request_id}, state) do
    :ets.delete(@table, request_id)
    state = do_demonitor(request_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      request_id ->
        :ets.delete(@table, request_id)

        state = %{
          state
          | monitors: Map.delete(state.monitors, ref),
            pids: Map.delete(state.pids, request_id)
        }

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.monitors, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp do_demonitor(request_id, state) do
    case Map.get(state.pids, request_id) do
      nil ->
        state

      ref ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | monitors: Map.delete(state.monitors, ref),
            pids: Map.delete(state.pids, request_id)
        }
    end
  end
end
