# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AsyncTracker do
  @moduledoc """
  Per-formula async task tracker backed by Task.Supervisor.

  Manages spawned sub-invocations for a single formula execution.
  Provides spawn/await/await-all/await-any/poll primitives. On
  termination, all orphaned tasks are killed via Task.Supervisor shutdown.

  ## Process Tree

      Formula Execution
      ├── Task.Supervisor    (owns all spawned sub-tasks)
      └── AsyncTracker       (GenServer — manages task state, handles await/poll)

  ## Design

  - `spawn` launches a task via `Task.Supervisor.async_nolink` and returns a task_id
  - Completed tasks auto-store results via `handle_info({ref, result})`
  - `await/poll` checks stored results first (instant return if already done)
  - `terminate/2` stops the Task.Supervisor, killing all orphans
  """
  use GenServer

  require Logger

  defstruct [
    :supervisor,
    :parent_execution_id,
    :max_tasks,
    :batch_timeout_ms,
    # task_id => %{task: %Task{}, ref: reference, started_at: ms, reference: str}
    tasks: %{},
    # task_id => {:ok, result} | {:error, reason}
    results: %{},
    next_id: 1
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start an AsyncTracker linked to the calling process.

  ## Options

  - `:parent_execution_id` - The formula's execution ID
  - `:max_tasks` - Maximum concurrent spawned tasks (from policy)
  - `:batch_timeout_ms` - Default timeout for await-all/await-any (from policy)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Spawn an async task. Returns `{:ok, task_id}` or `{:error, reason}`.
  """
  @spec spawn_task(pid(), (-> term()), String.t()) :: {:ok, String.t()} | {:error, term()}
  def spawn_task(tracker, fun, reference) do
    GenServer.call(tracker, {:spawn, fun, reference})
  end

  @doc """
  Block until a specific task completes. Returns the task result.
  """
  @spec await_task(pid(), String.t(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def await_task(tracker, task_id, timeout_ms) do
    GenServer.call(tracker, {:await, task_id, timeout_ms}, :infinity)
  end

  @doc """
  Block until ALL tasks complete. Returns all results (with timeout placeholders).
  """
  @spec await_all(pid(), [String.t()], non_neg_integer()) :: {:ok, list()}
  def await_all(tracker, task_ids, timeout_ms) do
    GenServer.call(tracker, {:await_all, task_ids, timeout_ms}, :infinity)
  end

  @doc """
  Block until FIRST task succeeds. Returns its result and remaining pending IDs.
  """
  @spec await_any(pid(), [String.t()], non_neg_integer()) ::
          {:ok, String.t(), term(), [String.t()]} | {:error, :timeout}
  def await_any(tracker, task_ids, timeout_ms) do
    GenServer.call(tracker, {:await_any, task_ids, timeout_ms}, :infinity)
  end

  @doc """
  Cancel a spawned task. Returns `:ok` if cancelled, `{:error, reason}` otherwise.
  """
  @spec cancel_task(pid(), String.t()) :: :ok | {:error, term()}
  def cancel_task(tracker, task_id) do
    GenServer.call(tracker, {:cancel, task_id})
  end

  @doc """
  Non-blocking check if a task is done.
  """
  @spec poll(pid(), String.t()) :: {:ok, :pending} | {:ok, term()} | {:error, term()}
  def poll(tracker, task_id) do
    GenServer.call(tracker, {:poll, task_id})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    parent_execution_id = Keyword.get(opts, :parent_execution_id, "unknown")
    max_tasks = Keyword.get(opts, :max_tasks, 10)
    batch_timeout_ms = Keyword.get(opts, :batch_timeout_ms, 300_000)

    case Task.Supervisor.start_link() do
      {:ok, supervisor} ->
        {:ok,
         %__MODULE__{
           supervisor: supervisor,
           parent_execution_id: parent_execution_id,
           max_tasks: max_tasks,
           batch_timeout_ms: batch_timeout_ms
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:spawn, fun, reference}, _from, state) do
    active_count = map_size(state.tasks)

    if state.max_tasks > 0 and active_count >= state.max_tasks do
      {:reply, {:error, :max_tasks_exceeded}, state}
    else
      task_id = "task_#{state.next_id}"
      task = Task.Supervisor.async_nolink(state.supervisor, fun)

      task_entry = %{
        task: task,
        ref: task.ref,
        started_at: System.monotonic_time(:millisecond),
        reference: reference
      }

      new_state = %{
        state
        | tasks: Map.put(state.tasks, task_id, task_entry),
          next_id: state.next_id + 1
      }

      {:reply, {:ok, task_id}, new_state}
    end
  end

  @impl true
  def handle_call({:await, task_id, timeout_ms}, _from, state) do
    cond do
      # Already completed
      Map.has_key?(state.results, task_id) ->
        {result, new_results} = Map.pop(state.results, task_id)
        {:reply, result, %{state | results: new_results}}

      # Still pending
      Map.has_key?(state.tasks, task_id) ->
        task_entry = state.tasks[task_id]
        {result, new_state} = yield_single(state, task_id, task_entry, timeout_ms)
        {:reply, result, new_state}

      # Unknown task
      true ->
        {:reply, {:error, :unknown_task}, state}
    end
  end

  @impl true
  def handle_call({:await_all, task_ids, timeout_ms}, _from, state) do
    {immediate_results, pending_ids} = split_completed(task_ids, state)

    if pending_ids == [] do
      # All already completed
      results = build_ordered_results(task_ids, immediate_results, %{})
      new_state = cleanup_results(state, task_ids)
      {:reply, {:ok, results}, new_state}
    else
      # Yield on pending tasks
      pending_tasks =
        Enum.map(pending_ids, fn id ->
          {id, state.tasks[id].task}
        end)

      task_structs = Enum.map(pending_tasks, fn {_id, task} -> task end)
      yield_results = Task.yield_many(task_structs, timeout_ms)

      # Map yield results back to task_ids
      yielded =
        pending_tasks
        |> Enum.zip(yield_results)
        |> Enum.reduce(%{}, fn {{id, _task}, {_task2, result}}, acc ->
          case result do
            {:ok, value} ->
              Map.put(acc, id, {:ok, value})

            {:exit, reason} ->
              Map.put(acc, id, {:error, format_crash_reason(reason)})

            nil ->
              Map.put(acc, id, {:error, :timeout})
          end
        end)

      # Shutdown timed-out tasks — yield_many returns nil for tasks that
      # didn't complete within the timeout but does NOT kill them.
      for {task, nil} <- yield_results do
        Task.shutdown(task, :brutal_kill)
      end

      # Build ordered results
      all_results = Map.merge(immediate_results, yielded)
      results = build_ordered_results(task_ids, all_results, %{})

      # Clean up state
      new_state =
        state
        |> remove_tasks(task_ids)
        |> cleanup_results(task_ids)

      {:reply, {:ok, results}, new_state}
    end
  end

  @impl true
  def handle_call({:await_any, task_ids, timeout_ms}, _from, state) do
    # Check if any already completed
    case find_first_completed(task_ids, state) do
      {:ok, task_id, result} ->
        pending = Enum.reject(task_ids, &(&1 == task_id))
        new_state = cleanup_results(state, [task_id])
        {:reply, {:ok, task_id, result, pending}, new_state}

      :none ->
        # Wait for first completion using a receive loop
        pending_tasks =
          for id <- task_ids, Map.has_key?(state.tasks, id) do
            {id, state.tasks[id]}
          end

        case yield_first(pending_tasks, timeout_ms) do
          {:ok, task_id, result} ->
            pending = Enum.reject(task_ids, &(&1 == task_id))

            new_state =
              store_result(state, task_id, {:ok, result})
              |> remove_tasks([task_id])
              |> cleanup_results([task_id])

            {:reply, {:ok, task_id, {:ok, result}, pending}, new_state}

          {:error, task_id, reason} ->
            pending = Enum.reject(task_ids, &(&1 == task_id))

            new_state =
              store_result(state, task_id, {:error, reason})
              |> remove_tasks([task_id])
              |> cleanup_results([task_id])

            {:reply, {:ok, task_id, {:error, reason}, pending}, new_state}

          :timeout ->
            {:reply, {:error, :timeout}, state}
        end
    end
  end

  @impl true
  def handle_call({:cancel, task_id}, _from, state) do
    cond do
      # Already completed — can't cancel
      Map.has_key?(state.results, task_id) ->
        {:reply, {:error, :already_completed}, state}

      # Still pending — shut it down
      Map.has_key?(state.tasks, task_id) ->
        task_entry = state.tasks[task_id]
        Task.shutdown(task_entry.task, :brutal_kill)

        new_state =
          state
          |> store_result(task_id, {:error, :cancelled})
          |> remove_tasks([task_id])

        {:reply, :ok, new_state}

      # Unknown
      true ->
        {:reply, {:error, :unknown_task}, state}
    end
  end

  @impl true
  def handle_call({:poll, task_id}, _from, state) do
    cond do
      Map.has_key?(state.results, task_id) ->
        {:reply, state.results[task_id], state}

      Map.has_key?(state.tasks, task_id) ->
        {:reply, {:ok, :pending}, state}

      true ->
        {:reply, {:error, :unknown_task}, state}
    end
  end

  # Task completed successfully
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Demonitor and flush — Task.async_nolink sends result then DOWN
    Process.demonitor(ref, [:flush])

    case find_task_by_ref(ref, state) do
      {task_id, _task_entry} ->
        new_state =
          state
          |> store_result(task_id, {:ok, result})
          |> remove_tasks([task_id])

        {:noreply, new_state}

      nil ->
        {:noreply, state}
    end
  end

  # Task crashed
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_task_by_ref(ref, state) do
      {task_id, _task_entry} ->
        error_reason = format_crash_reason(reason)

        new_state =
          state
          |> store_result(task_id, {:error, error_reason})
          |> remove_tasks([task_id])

        {:noreply, new_state}

      nil ->
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
    if state.supervisor && Process.alive?(state.supervisor) do
      Supervisor.stop(state.supervisor)
    end

    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp find_task_by_ref(ref, state) do
    Enum.find(state.tasks, fn {_id, entry} -> entry.ref == ref end)
  end

  defp split_completed(task_ids, state) do
    Enum.reduce(task_ids, {%{}, []}, fn id, {completed, pending} ->
      if Map.has_key?(state.results, id) do
        {Map.put(completed, id, state.results[id]), pending}
      else
        {completed, pending ++ [id]}
      end
    end)
  end

  defp find_first_completed(task_ids, state) do
    Enum.find_value(task_ids, :none, fn id ->
      case Map.fetch(state.results, id) do
        {:ok, result} -> {:ok, id, result}
        :error -> nil
      end
    end)
  end

  defp yield_single(state, task_id, task_entry, timeout_ms) do
    case Task.yield(task_entry.task, timeout_ms) do
      {:ok, result} ->
        Process.demonitor(task_entry.ref, [:flush])
        new_state = remove_tasks(state, [task_id])
        {{:ok, result}, new_state}

      {:exit, reason} ->
        new_state = remove_tasks(state, [task_id])
        {{:error, format_crash_reason(reason)}, new_state}

      nil ->
        Task.shutdown(task_entry.task, :brutal_kill)
        new_state = remove_tasks(state, [task_id])
        {{:error, :timeout}, new_state}
    end
  end

  defp yield_first([], _timeout_ms), do: :timeout

  defp yield_first(pending_tasks, timeout_ms) do
    # Build a map of ref -> {task_id, task_entry}
    ref_map = Map.new(pending_tasks, fn {id, entry} -> {entry.ref, {id, entry}} end)
    refs = Map.keys(ref_map)

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_yield_first(refs, ref_map, deadline)
  end

  defp do_yield_first([], _ref_map, _deadline), do: :timeout

  defp do_yield_first(_refs, ref_map, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining <= 0 do
      :timeout
    else
      receive do
        {ref, result} when is_reference(ref) ->
          case Map.fetch(ref_map, ref) do
            {:ok, {task_id, _entry}} ->
              Process.demonitor(ref, [:flush])
              {:ok, task_id, result}

            :error ->
              # Not one of our tasks — put it back and keep waiting
              send(self(), {ref, result})
              do_yield_first(nil, ref_map, deadline)
          end

        {:DOWN, ref, :process, _pid, reason} when is_reference(ref) ->
          case Map.fetch(ref_map, ref) do
            {:ok, {task_id, _entry}} ->
              {:error, task_id, format_crash_reason(reason)}

            :error ->
              send(self(), {:DOWN, ref, :process, nil, reason})
              do_yield_first(nil, ref_map, deadline)
          end
      after
        remaining -> :timeout
      end
    end
  end

  defp build_ordered_results(task_ids, results_map, _opts) do
    Enum.map(task_ids, fn id ->
      result = Map.get(results_map, id, {:error, :unknown_task})
      {id, result}
    end)
  end

  defp store_result(state, task_id, result) do
    %{state | results: Map.put(state.results, task_id, result)}
  end

  defp remove_tasks(state, task_ids) do
    %{state | tasks: Map.drop(state.tasks, task_ids)}
  end

  defp cleanup_results(state, task_ids) do
    %{state | results: Map.drop(state.results, task_ids)}
  end

  defp format_crash_reason(:normal), do: "task exited normally"
  defp format_crash_reason(:killed), do: "task was killed"
  defp format_crash_reason({:shutdown, reason}), do: "task shutdown: #{inspect(reason)}"
  defp format_crash_reason(reason), do: "task crashed: #{inspect(reason)}"
end