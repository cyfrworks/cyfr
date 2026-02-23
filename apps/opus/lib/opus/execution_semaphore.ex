defmodule Opus.ExecutionSemaphore do
  @moduledoc """
  Counting semaphore that limits concurrent WASM executions.

  Prevents dirty scheduler exhaustion by capping how many WASM executions
  can run simultaneously. Callers that crash are automatically released
  via process monitoring.

  ## Configuration

      config :opus, :max_concurrent_executions, 16

  Defaults to `System.schedulers_online() * 2` when not configured.
  Can also be set via the `CYFR_MAX_CONCURRENT_EXECUTIONS` env var.
  """

  use GenServer

  require Logger

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    max = Keyword.get(opts, :max, System.schedulers_online() * 2)
    GenServer.start_link(__MODULE__, max, name: __MODULE__)
  end

  @doc """
  Acquire an execution slot. Blocks until a slot is available or timeout.

  Returns `:ok` if a slot was acquired, `{:error, :at_capacity}` if the
  semaphore is full and no slot became available within `timeout` ms.
  """
  @spec acquire(timeout()) :: :ok | {:error, :at_capacity}
  def acquire(timeout \\ 30_000) do
    try do
      GenServer.call(__MODULE__, :acquire, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :at_capacity}
    end
  end

  @doc """
  Release an execution slot. Must be called by the same process that acquired.
  """
  @spec release() :: :ok
  def release do
    GenServer.cast(__MODULE__, {:release, self()})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(max) when is_integer(max) and max > 0 do
    Logger.info("[Opus.ExecutionSemaphore] Started with max_concurrent_executions=#{max}")
    {:ok, %{max: max, count: 0, monitors: %{}}}
  end

  @impl true
  def handle_call(:acquire, {caller_pid, _tag}, %{count: count, max: max} = state) when count < max do
    mon_ref = Process.monitor(caller_pid)
    new_monitors = Map.put(state.monitors, caller_pid, mon_ref)
    {:reply, :ok, %{state | count: count + 1, monitors: new_monitors}}
  end

  def handle_call(:acquire, _from, state) do
    {:reply, {:error, :at_capacity}, state}
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    {:noreply, do_release(state, pid)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, do_release(state, pid)}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp do_release(%{monitors: monitors, count: count} = state, pid) do
    case Map.pop(monitors, pid) do
      {nil, _monitors} ->
        # Already released or unknown caller — no-op
        state

      {mon_ref, new_monitors} ->
        Process.demonitor(mon_ref, [:flush])
        %{state | count: max(count - 1, 0), monitors: new_monitors}
    end
  end
end
