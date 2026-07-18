# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RunningTasks do
  @moduledoc """
  Tracks running tool executions by MCP request ID for cancellation support.

  Uses a GenServer to monitor task processes and auto-clean ETS entries when
  tasks die. The main ETS table remains `:public` for fast reads from any process.
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
  Register a running task for a given MCP request ID, tracking the owning user and org.
  The GenServer will monitor the task process and auto-clean on exit.
  """
  def register(request_id, %Task{pid: pid}, user_id \\ nil, org_id \\ nil, project_id \\ nil)
      when is_binary(request_id) or is_integer(request_id) do
    :ets.insert(@table, {request_id, pid, user_id, org_id, project_id})
    GenServer.cast(__MODULE__, {:monitor, request_id, pid})
    :ok
  end

  @doc """
  Unregister a task after it completes.
  """
  def unregister(request_id) when is_binary(request_id) or is_integer(request_id) do
    GenServer.cast(__MODULE__, {:unregister, request_id})
    :ok
  end

  @doc """
  Cancel a running task by its MCP request ID with ownership verification.

  Only the user who owns the task (or an admin with wildcard permissions) can cancel it.
  Returns `:ok` if found and cancelled, `{:error, :not_found}` if no task is running,
  or `{:error, :unauthorized}` if the caller doesn't own the task.
  """
  def cancel(request_id, %Sanctum.Context{} = ctx) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, pid, owner_id, task_org_id, task_project_id}] ->
        if authorized_to_cancel?(ctx, task_org_id, task_project_id) do
          Process.exit(pid, :cancelled)
          GenServer.cast(__MODULE__, {:unregister, request_id})
          :ok
        else
          Logger.warning(
            "[RunningTasks] Unauthorized cancel attempt: " <>
              "user=#{ctx.user_id} request_id=#{request_id} owner=#{owner_id}"
          )

          {:error, :unauthorized}
        end

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

  # Project members are interchangeable: any member of the same org+project with
  # :execute (or admin/*) may cancel a running task. An unresolved org/project
  # (the nil/"" sentinel) = single-user / no tenant concept, so skip that side
  # of the check; a configured (multi-tenant) deployment resolves real coords
  # upstream (the tenant gate) before a request reaches here.
  defp authorized_to_cancel?(%Sanctum.Context{} = ctx, task_org_id, task_project_id) do
    org_matches =
      task_org_id in [nil, ""] or ctx.org_id in [nil, ""] or ctx.org_id == task_org_id

    project_matches =
      task_project_id in [nil, ""] or ctx.project_id in [nil, ""] or
        ctx.project_id == task_project_id

    org_matches and project_matches and
      (Sanctum.Context.has_permission?(ctx, :execute) or
         Sanctum.Context.has_permission?(ctx, :*) or
         Sanctum.Context.has_permission?(ctx, :admin))
  end
end
