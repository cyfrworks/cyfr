# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Subtree do
  @moduledoc """
  The attempt processes running in a runner's VM, as the runner
  (`Opus.Runner`) that owns them tracks the subtree it was assigned. The
  runner keeps three maps in its state — `runners`, each attempt process
  by its monitor; `executions`, each execution id to that monitor; and
  `waiters`, each waiting process's monitor to the attempt it waits for —
  and the functions here move them.

  An attempt process (`Opus.Attempt`) reaches its owner through the
  functions at the top: `start_child/2` starts a runner for a child CYFR
  admitted and claimed for a formula's runner, `track/1` records its
  component process and what that process started, `settled/0` records
  that CYFR has closed its attempt, and `unclean/1` records that a host
  answer was lost, so the subtree's runner is never reused. The owner is
  the runner running in this VM (`owner/0`); with none, a child cannot
  start and the rest is a no-op.

  A child with a waiting process (a formula's synchronous call or spawned
  task) is ended when that process exits before its attempt settles; a
  streamed child, with none, runs until it closes. An attempt process is
  ended by telling it to stop its component call and close its attempt as
  abandoned itself (`Opus.Attempt`), so the subtree goes on with nothing
  left open; the formula tracker is linked to the component process and
  goes with it, taking the spawned tasks.
  """

  alias Cyfr.Assignment
  alias Opus.{Attempt, HostClient}

  @typedoc "What the owner knows of one attempt process."
  @type entry :: %{
          pid: pid(),
          execution_id: String.t(),
          attempt: String.t(),
          runner: String.t(),
          callers: [pid()],
          logger: keyword(),
          waiter: reference() | nil,
          component: pid() | nil,
          cleanup: map()
        }

  @typedoc "The owner's state: the three maps, beside whatever else it keeps."
  @type state :: %{
          :runners => %{reference() => entry()},
          :executions => %{String.t() => reference()},
          :waiters => %{reference() => reference()},
          optional(atom()) => term()
        }

  # ---------------------------------------------------------------------------
  # What an attempt process asks of its owner
  # ---------------------------------------------------------------------------

  @doc "The process tracking this VM's attempts: the runner."
  @spec owner() :: pid() | nil
  def owner do
    case Process.whereis(Opus.Runner) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  @doc """
  Start an attempt process for `child`, a child CYFR admitted and claimed
  for a formula's runner (`t:Opus.HostClient.child/0`). `waiter` is the
  process the runner answers (`Opus.Attempt`), whose exit stops the
  child until it settles, or nil for a child nothing waits for. Answers
  `{:ok, pid}`, or `{:error, :malformed}` when the child's client is not
  for the attempt its assignment names on this worker service, names an
  execution this VM already runs, or no owner is running here.
  """
  @spec start_child(HostClient.child(), pid() | nil) :: {:ok, pid()} | {:error, :malformed}
  def start_child(%{assignment: %Assignment{}, client: %HostClient{}} = child, waiter)
      when is_pid(waiter) or is_nil(waiter) do
    case owner() do
      nil -> {:error, :malformed}
      owner -> GenServer.call(owner, {:start_child, child, waiter, caller()})
    end
  end

  @doc """
  Record, for the calling attempt process, its component process
  (`:component`) or the cleanup references its runtime answered
  (`:cleanup`), which a kill or its exit stops.
  """
  @spec track(%{optional(:component) => pid(), optional(:cleanup) => map()}) :: :ok
  def track(fields) when is_map(fields) do
    case owner() do
      nil -> :ok
      owner -> GenServer.cast(owner, {:track, self(), fields})
    end
  end

  @doc "Record, for the calling attempt process, that CYFR has closed its attempt: its waiter's exit no longer stops it."
  @spec settled() :: :ok
  def settled do
    case owner() do
      nil -> :ok
      owner -> GenServer.call(owner, {:settled, self()})
    end
  end

  @doc """
  Record that a host answer was lost (`reason`), so the runner of this
  subtree completes unclean and is never reused: what the lost call did
  is unknown, and so is what its guest holds.
  """
  @spec unclean(term()) :: :ok
  def unclean(reason) do
    case owner() do
      nil -> :ok
      owner -> GenServer.cast(owner, {:unclean, self(), reason})
    end
  end

  @doc "The calling process's callers and log metadata, carried to the attempt process it starts."
  @spec caller() :: %{callers: [pid()], logger: keyword()}
  def caller do
    %{callers: [self() | Process.get(:"$callers", [])], logger: Cyfr.LoggerContext.capture()}
  end

  # ---------------------------------------------------------------------------
  # The owner's state
  # ---------------------------------------------------------------------------

  @doc "`state` with the three maps, empty."
  @spec new(map()) :: state()
  def new(state) when is_map(state),
    do: Map.merge(state, %{runners: %{}, executions: %{}, waiters: %{}})

  @doc """
  Start an attempt process for `start` (`t:Opus.Attempt.start/0` without
  its caller fields) under the `supervisor`, monitored, and `waiter`'s
  exit too when there is one. `{:error, :malformed}` when the execution
  already runs here.
  """
  @spec start(
          state(),
          Supervisor.supervisor(),
          map(),
          %{callers: [pid()], logger: keyword()},
          pid() | nil
        ) ::
          {:ok, pid(), state()} | {:error, :malformed}
  def start(state, supervisor, start, caller, waiter) do
    execution_id = start.assignment.execution_id

    with false <- Map.has_key?(state.executions, execution_id),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             supervisor,
             {Attempt, Map.merge(start, %{callers: caller.callers, logger: caller.logger})}
           ) do
      ref = Process.monitor(pid)
      waiter_ref = if is_pid(waiter), do: Process.monitor(waiter)

      entry = %{
        pid: pid,
        execution_id: execution_id,
        attempt: start.assignment.attempt,
        runner: start.client.runner,
        callers: caller.callers,
        logger: caller.logger,
        waiter: waiter_ref,
        component: nil,
        cleanup: %{}
      }

      waiters = if waiter_ref, do: Map.put(state.waiters, waiter_ref, ref), else: state.waiters

      {:ok, pid,
       %{
         state
         | runners: Map.put(state.runners, ref, entry),
           executions: Map.put(state.executions, execution_id, ref),
           waiters: waiters
       }}
    else
      _refused -> {:error, :malformed}
    end
  end

  @doc "Record `fields` (`:component`, `:cleanup`) for the attempt process `pid`."
  @spec track(state(), pid(), map()) :: state()
  def track(state, pid, fields) do
    case find(state, pid) do
      {ref, entry} ->
        entry = %{
          entry
          | component: Map.get(fields, :component, entry.component),
            cleanup: Map.get(fields, :cleanup, entry.cleanup)
        }

        %{state | runners: Map.put(state.runners, ref, entry)}

      nil ->
        state
    end
  end

  @doc "Forget the waiter of the attempt process `pid`: CYFR has closed its attempt."
  @spec settle(state(), pid()) :: state()
  def settle(state, pid) do
    case find(state, pid) do
      {ref, entry} ->
        state = forget_waiter_of(state, entry)
        %{state | runners: Map.put(state.runners, ref, %{entry | waiter: nil})}

      nil ->
        state
    end
  end

  @doc "Tell the attempt process running `execution_id` to stop and close its attempt as abandoned; its exit follows as a `:DOWN`."
  @spec kill(state(), String.t()) :: :ok | :not_found
  def kill(state, execution_id) do
    case Map.fetch(state.executions, execution_id) do
      {:ok, ref} ->
        Attempt.cancel(Map.fetch!(state.runners, ref).pid)
        :ok

      :error ->
        :not_found
    end
  end

  @doc "Kill every attempt process and component the owner tracks, on the owner's way out."
  @spec kill_all(state()) :: :ok
  def kill_all(state) do
    for {_ref, entry} <- state.runners do
      kill_component(entry)
      Process.exit(entry.pid, :kill)
    end

    :ok
  end

  @doc """
  What a `:DOWN` with monitor `ref` means: an attempt process ended
  (`{:attempt, entry, state}`, its component killed, its waiter
  forgotten), or a waiting process ended (`{:waiter, state}`, its
  attempt process told to stop unless it had settled, whose exit then
  follows), or nothing the owner tracks (`{:unknown, state}`).
  """
  @spec down(state(), reference()) ::
          {:attempt, entry(), state()} | {:waiter, state()} | {:unknown, state()}
  def down(state, ref) do
    case Map.pop(state.runners, ref) do
      {nil, _runners} ->
        waiter_down(state, ref)

      {entry, runners} ->
        kill_component(entry)

        state = %{
          state
          | runners: runners,
            executions: Map.delete(state.executions, entry.execution_id)
        }

        {:attempt, entry, forget_waiter_of(state, entry)}
    end
  end

  @doc "The attempt ids of every attempt process tracked."
  @spec attempts(state()) :: [String.t()]
  def attempts(state), do: for({_ref, entry} <- state.runners, do: entry.attempt)

  @doc "The entry of the attempt process `pid`, by its monitor."
  @spec find(state(), pid()) :: {reference(), entry()} | nil
  def find(state, pid), do: Enum.find(state.runners, fn {_ref, entry} -> entry.pid == pid end)

  defp waiter_down(state, waiter_ref) do
    case Map.pop(state.waiters, waiter_ref) do
      {nil, _waiters} ->
        {:unknown, state}

      {ref, waiters} ->
        case Map.fetch(state.runners, ref) do
          {:ok, entry} -> Attempt.cancel(entry.pid)
          :error -> :ok
        end

        {:waiter, %{state | waiters: waiters}}
    end
  end

  defp forget_waiter_of(state, %{waiter: nil}), do: state

  defp forget_waiter_of(state, %{waiter: waiter_ref}) do
    Process.demonitor(waiter_ref, [:flush])
    %{state | waiters: Map.delete(state.waiters, waiter_ref)}
  end

  # The component process traps exits, so it is killed by name. Its formula
  # tracker is linked to it and goes with it, taking the spawned tasks; its
  # streaming requests run under a supervisor of their own and are stopped
  # here.
  defp kill_component(entry) do
    if is_pid(entry.component), do: Process.exit(entry.component, :kill)

    if entry.cleanup[:stream_exec_ref],
      do: Opus.HttpStreamHandler.cleanup_registry(entry.cleanup.stream_exec_ref)

    :ok
  end
end
