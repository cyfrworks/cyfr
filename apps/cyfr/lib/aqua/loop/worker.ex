# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Worker do
  @moduledoc """
  Supervised workers owned by a loop or another worker. Results use an
  owner-bound monitor handle, and descendants stop when their owner exits.

  Starts and subtree stops serialize here. Every child is registered
  before its owner can release it to run, so stopping an owner also
  catches children whose start raced the stop. `stop/1` confirms process
  death before returning; it grants no authority and writes no Tape rows.
  """

  use GenServer

  defmodule Handle do
    @moduledoc "A worker's process and result monitor, owned by its caller."
    @enforce_keys [:pid, :ref, :owner]
    defstruct [:pid, :ref, :owner]

    @type t :: %__MODULE__{pid: pid(), ref: reference(), owner: pid()}
  end

  @stop_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Start a worker owned by the caller; its handle receives one result or exit."
  @spec async((-> term())) :: Handle.t()
  def async(fun) when is_function(fun, 0) do
    owner = self()
    callers = [owner | Process.get(:"$callers", [])]

    case GenServer.call(__MODULE__, {:start, fun, callers}) do
      {:ok, pid} when is_pid(pid) ->
        ref = :erlang.monitor(:process, pid, [{:alias, :demonitor}])
        send(pid, {:run, owner, ref})
        %Handle{pid: pid, ref: ref, owner: owner}

      {:error, reason} ->
        exit({:worker_start, reason})
    end
  end

  @doc "Wait up to the timeout for a result or exit; nil leaves the handle pending."
  @spec yield(Handle.t(), timeout()) :: {:ok, term()} | {:exit, term()} | nil
  def yield(%Handle{ref: ref, owner: owner}, timeout) when owner == self() do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:exit, reason}
    after
      timeout -> nil
    end
  end

  @doc "Stop an owner and all its workers, confirming their death within five seconds."
  @spec stop(pid() | nil) :: :ok | {:error, :workers_not_stopped | :workers_unavailable}
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:stop, pid}, @stop_ms + 1_000)
  catch
    :exit, _ -> {:error, :workers_unavailable}
  end

  @doc "Stop a worker and its descendants, then consume its result or exit monitor."
  @spec shutdown(Handle.t()) :: {:ok, term()} | {:exit, term()} | nil
  def shutdown(%Handle{owner: owner} = task) when owner == self() do
    case stop(task.pid) do
      :ok ->
        result = yield(task, 0)
        Process.demonitor(task.ref, [:flush])

        case result do
          {:exit, reason} when reason in [:killed, :noproc, :normal] -> nil
          result -> result
        end

      {:error, reason} ->
        exit(reason)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{children: %{}, refs: %{}, stopping: MapSet.new()}}

  @impl true
  def handle_call({:start, fun, callers}, {owner, _tag}, state) do
    if Process.alive?(owner) and not MapSet.member?(state.stopping, owner) do
      case Task.Supervisor.start_child(Aqua.TaskSupervisor, fn ->
             Process.put(:"$callers", callers)

             receive do
               {:run, ^owner, ref} -> send(ref, {ref, fun.()})
             after
               @stop_ms -> exit(:worker_start_timeout)
             end
           end) do
        {:ok, pid} ->
          children = Map.update(state.children, owner, MapSet.new([pid]), &MapSet.put(&1, pid))
          state = %{state | children: children} |> watch(owner) |> watch(pid)
          {:reply, {:ok, pid}, state}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :owner_stopped}, state}
    end
  end

  def handle_call({:stop, pid}, _from, state) do
    {result, state} = quiesce(state, pid)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if state.refs[pid] == ref do
      {_result, state} = quiesce(state, pid)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, message)
    {:noreply, state}
  end

  defp watch(state, pid) do
    if Map.has_key?(state.refs, pid),
      do: state,
      else: %{state | refs: Map.put(state.refs, pid, Process.monitor(pid))}
  end

  defp subtree(children, pid) do
    [pid | Enum.flat_map(Map.get(children, pid, []), &subtree(children, &1))]
  end

  defp quiesce(state, pid) do
    pids = subtree(state.children, pid)
    stopped = MapSet.new(pids)
    state = %{state | stopping: MapSet.union(state.stopping, stopped)}
    deadline = System.monotonic_time(:millisecond) + @stop_ms

    # Fresh monitors also answer for a parent whose original DOWN this
    # server already consumed. No start can interleave this callback.
    waiting = Map.new(pids, &{Process.monitor(&1), &1})
    Enum.each(pids, &Process.exit(&1, :kill))

    case await_stopped(waiting, deadline) do
      :ok -> {:ok, retire(state, stopped)}
      :timeout -> {{:error, :workers_not_stopped}, state}
    end
  end

  defp await_stopped(waiting, _deadline) when map_size(waiting) == 0, do: :ok

  defp await_stopped(waiting, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ref, :process, _pid, _reason} when is_map_key(waiting, ref) ->
        await_stopped(Map.delete(waiting, ref), deadline)
    after
      remaining ->
        for ref <- Map.keys(waiting), do: Process.demonitor(ref, [:flush])
        :timeout
    end
  end

  defp retire(state, stopped) do
    children =
      for {owner, children} <- state.children,
          not MapSet.member?(stopped, owner),
          remaining = MapSet.difference(children, stopped),
          MapSet.size(remaining) > 0,
          into: %{},
          do: {owner, remaining}

    watched =
      MapSet.new(Map.keys(children) ++ Enum.flat_map(Map.values(children), &Enum.to_list/1))

    {kept, retired} =
      Enum.split_with(state.refs, fn {pid, _ref} -> MapSet.member?(watched, pid) end)

    for {_pid, ref} <- retired, do: Process.demonitor(ref, [:flush])

    %{
      state
      | children: children,
        refs: Map.new(kept),
        stopping: MapSet.difference(state.stopping, stopped)
    }
  end
end
