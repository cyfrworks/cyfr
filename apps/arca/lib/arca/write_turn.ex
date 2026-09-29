# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WriteTurn do
  @moduledoc """
  The order in which SQLite's writers of two kinds reach the one write
  lock: the decision log's audit writers (`:audit`) and the control
  plane's claim, renewal and release (`:control_plane`), so that audit
  traffic cannot consume the capacity renewal needs (`ARCHITECTURE.md`
  §6.4). One process per node; a SQLite store has exactly one member, so
  that is the whole order. PostgreSQL asks for no turn: the control
  plane's own connection alone serves there.

  ## What a turn is

  A turn orders writers; it does not make any write correct. SQLite's
  write lock and the lease's live fence stay the only mutual exclusion,
  and a turn only decides that a renewal goes next. A writer asks for its
  turn once it holds its connection and before any mutating statement —
  inside `Arca.Repo`'s lock step, which then takes the lock as it always
  does — and gives it back once its transaction has committed or rolled
  back (`Arca.Repo.locking_transaction/2`, `write_turn:`). A turn holder
  therefore never waits for a pool, and the wait for a turn spends the
  writer's own absolute deadline, never restarting it.

  Turns are issued one at a time in the order asked, except that a
  waiting control-plane request is issued the next turn, ahead of every
  queued audit request. A turn already issued is never revoked, so at most
  one turn issued before a renewal asked precedes it, bounded by its
  holder's own deadline.

  The issue is a reply from this one process, so no check-then-act gap
  lets a queued writer reach the lock ahead of a renewal.

  ## Holders that stop

  Every holder and waiter is monitored. A holder's exit frees its turn and
  a waiter's exit drops its request. A waiter that gives up cancels its
  request, and a turn issued to it just before the cancel arrived is
  released by the cancel itself, so no turn stays with a process that is
  not using it. No holder is ever killed to free a turn: an exit does not
  stop a dirty NIF, and a killed holder's native call can still take the
  lock after its monitor has fired. So a holder releases its own turn
  after its transaction has returned, and that release is the only proof
  that a turn's work has ended; a fault's exit frees the turn with the
  native call possibly still running, bounded by the connection's cleanup
  (`Arca.DecisionLog`'s moduledoc).

  ## Generations

  Each start of this process is a new generation, and every turn carries
  the generation that issued it. Its waiters see it go and ask the next
  generation within their unchanged deadlines; its holders keep their
  turns and their deadlines, and their releases, naming an earlier
  generation, free nothing of the current one. The priority holds within
  one generation.

  ## Capacity

  The audit queue has a fixed capacity: the decision log's writer cap
  (`Arca.DecisionLog.max_writers/0`), since each of those writers asks
  for at most one turn at a time. An audit request past it is refused
  (`Arca.WriteTurn.CapacityError` in the lock step). Control-plane
  requests are bounded by the connections they are asked on.

  ## Where turns are taken

  Everywhere but under the SQL sandbox (`enabled?/0`). A sandboxed test's
  connection holds SQLite's write lock from its first write until the
  test ends, and its own audit writer runs on that connection: a writer
  of another sandbox holding the turn while it waits for that lock, and
  this writer waiting for the turn, would wait on each other until a
  deadline. Outside the sandbox no writer waits for a lock its own caller
  holds: audit writes never run inside a caller's transaction, and the
  control plane's run on their own pool. The arbiter runs either way.
  """

  use GenServer

  @kinds [:audit, :control_plane]

  # Where a process keeps the turn it holds.
  @held {__MODULE__, :held}

  # How often a waiter looks for the next generation while the supervisor
  # starts it.
  @restart_poll_ms 5

  @typedoc "Who asks: an audit writer, or the control plane's lease writes, which go first."
  @type kind :: :audit | :control_plane

  @typedoc "A turn held: the arbiter that issued it, the request and the generation."
  @type turn :: {GenServer.server(), reference(), pos_integer()}

  defmodule CapacityError do
    @moduledoc """
    An audit writer's request for a turn past the queue's fixed capacity.
    Raised in the lock step before any statement, so it rolls back nothing
    but the attempt.
    """

    defexception message: "the audit write queue is at its fixed capacity"
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 5_000
    }
  end

  @doc """
  Start the arbiter. `:name` (default `#{inspect(__MODULE__)}`) and
  `:capacity`, the audit queue's (default `Arca.DecisionLog.max_writers/0`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    capacity = Keyword.get(opts, :capacity, Arca.DecisionLog.max_writers())
    GenServer.start_link(__MODULE__, capacity, name: name)
  end

  # ---- a writer's side --------------------------------------------------------

  @doc """
  Whether the lock step asks for turns. The in-code default is true, and
  no environment variable reads it; only an explicit `false` turns it off,
  which the test configurations set for the SQL sandbox (see the
  moduledoc).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:arca, :write_turn, true) != false

  @doc """
  Ask for a turn and wait for it until `deadline`, an absolute instant on
  `System.monotonic_time(:millisecond)`. The turn is kept in the calling
  process until `release/0`; a process that already holds one is answered
  it again.

  `{:error, :timeout}` once the deadline passes with no turn issued, and
  then the request is cancelled; `{:error, :capacity}` for an audit
  request past the queue's capacity. A generation that stops while this
  waits is asked again, in the next, within the same deadline.
  """
  @spec acquire(kind(), integer(), GenServer.server()) ::
          {:ok, turn()} | {:error, :timeout | :capacity}
  def acquire(kind, deadline, server \\ __MODULE__)
      when kind in @kinds and is_integer(deadline) do
    case Process.get(@held) do
      nil -> ask(kind, deadline, server)
      turn -> {:ok, turn}
    end
  end

  @doc "Whether the calling process holds a turn."
  @spec holding?() :: boolean()
  def holding?, do: Process.get(@held) != nil

  @doc """
  Give back the turn the calling process holds, if any. Called once the
  holder's transaction has committed or rolled back. A turn of an earlier
  generation frees nothing of the current one.
  """
  @spec release() :: :ok
  def release do
    case Process.delete(@held) do
      nil -> :ok
      {server, ref, generation} -> GenServer.cast(server, {:release, ref, generation})
    end
  end

  @doc """
  The arbiter as it stands: its generation, the holder's kind and pid, and
  how many requests of each kind wait. For measurement and tests.
  """
  @spec status(GenServer.server()) :: %{
          generation: pos_integer(),
          holder: nil | %{kind: kind(), pid: pid()},
          waiting: %{audit: non_neg_integer(), control_plane: non_neg_integer()},
          capacity: pos_integer()
        }
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # The request goes to the generation running now, under a monitor that is
  # also the reply's alias: once the monitor goes, so does the alias, and a
  # turn issued after that is never delivered. The cancel sent first is
  # what gives such a turn back.
  defp ask(kind, deadline, server) do
    case GenServer.whereis(server) do
      nil -> between_generations(kind, deadline, server)
      pid -> ask(kind, deadline, server, pid)
    end
  end

  defp ask(kind, deadline, server, pid) do
    ref = :erlang.monitor(:process, pid, [{:alias, :demonitor}])
    GenServer.cast(pid, {:ask, ref, self(), kind})

    receive do
      {^ref, :turn, generation} ->
        Process.demonitor(ref, [:flush])
        turn = {server, ref, generation}
        Process.put(@held, turn)
        {:ok, turn}

      {^ref, :refused} ->
        Process.demonitor(ref, [:flush])
        {:error, :capacity}

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        ask(kind, deadline, server)
    after
      left(deadline) ->
        GenServer.cast(pid, {:cancel, ref})
        Process.demonitor(ref, [:flush])

        receive do
          {^ref, :turn, _generation} -> :ok
          {^ref, :refused} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp between_generations(kind, deadline, server) do
    case left(deadline) do
      0 ->
        {:error, :timeout}

      left ->
        Process.sleep(min(@restart_poll_ms, left))
        ask(kind, deadline, server)
    end
  end

  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # ---- the arbiter --------------------------------------------------------------

  @impl true
  def init(capacity) when is_integer(capacity) and capacity > 0 do
    {:ok,
     %{
       generation: System.unique_integer([:positive, :monotonic]),
       capacity: capacity,
       holder: nil,
       control_plane: [],
       audit: []
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    holder =
      case state.holder do
        nil -> nil
        %{kind: kind, pid: pid} -> %{kind: kind, pid: pid}
      end

    {:reply,
     %{
       generation: state.generation,
       holder: holder,
       waiting: %{audit: length(state.audit), control_plane: length(state.control_plane)},
       capacity: state.capacity
     }, state}
  end

  @impl true
  def handle_cast({:ask, ref, pid, kind}, state) when kind in @kinds do
    if kind == :audit and length(state.audit) >= state.capacity do
      send(ref, {ref, :refused})
      {:noreply, state}
    else
      request = %{ref: ref, pid: pid, kind: kind, monitor: Process.monitor(pid)}
      {:noreply, state |> Map.update!(kind, &(&1 ++ [request])) |> issue()}
    end
  end

  # A cancel that finds its request already issued is a waiter that gave up
  # as its turn went out: the turn comes back at once.
  def handle_cast({:cancel, ref}, state), do: {:noreply, drop(state, &(&1.ref == ref))}

  def handle_cast({:release, ref, generation}, %{generation: generation} = state),
    do: {:noreply, drop_holder(state, &(&1.ref == ref))}

  # An earlier generation's release: that holder's turn died with the
  # generation that issued it.
  def handle_cast({:release, _ref, _generation}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state),
    do: {:noreply, drop(state, &(&1.monitor == monitor))}

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  defp drop(state, match?) do
    case state.holder do
      %{} = holder ->
        if match?.(holder),
          do: drop_holder(state, match?),
          else: drop_waiter(state, match?)

      nil ->
        drop_waiter(state, match?)
    end
  end

  defp drop_holder(%{holder: %{} = holder} = state, match?) do
    if match?.(holder) do
      Process.demonitor(holder.monitor, [:flush])
      issue(%{state | holder: nil})
    else
      state
    end
  end

  defp drop_holder(state, _match?), do: state

  defp drop_waiter(state, match?) do
    Enum.reduce(@kinds, state, fn kind, acc ->
      {gone, kept} = Enum.split_with(Map.fetch!(acc, kind), match?)
      Enum.each(gone, &Process.demonitor(&1.monitor, [:flush]))
      Map.put(acc, kind, kept)
    end)
  end

  # The next turn: a waiting control-plane request first, then the audit
  # queue in the order asked.
  defp issue(%{holder: nil, control_plane: [next | rest]} = state),
    do: issued(%{state | control_plane: rest}, next)

  defp issue(%{holder: nil, audit: [next | rest]} = state),
    do: issued(%{state | audit: rest}, next)

  defp issue(state), do: state

  defp issued(state, request) do
    send(request.ref, {request.ref, :turn, state.generation})
    %{state | holder: request}
  end
end
