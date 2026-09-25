# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.RunningTasks do
  @moduledoc """
  Tracks the process doing the work for an in-flight request, so the transport
  can stop it when the caller goes away.

  Keyed by the server-minted `Sanctum.Context.request_id`, stamped by
  `EmissaryWeb.MCPController`. Client JSON-RPC ids may repeat across callers
  and must not identify running tasks.

  ## Why one request may hold several tasks

  A server-minted id cannot collide *across* requests, but one request can
  hold more than one task at a time: an in-chain tool call inherits its
  root's `request_id` rather than minting a new one (`Grimoire.Catalog` mints one
  only when no transport did), which is what
  keeps a whole chain attributable to the ingress that started it.

  Each task under a request holds a claim of its own. The caller claims
  before it starts the task (`claim_request/1`), and the task registers
  its pid against that claim from inside itself, before its handler runs
  (`register/3`). A cancel that reaches a claim not yet registered marks
  it, and the registration that follows answers `:cancelled`, so the
  handler never runs. `unregister/2` drops one claim, and `cancel/1` stops
  every task the request still holds. The registered pids are kept in a
  protected ETS bag for reads from any process.

  ## Handles

  A caller that holds no request id names its call by a handle of its
  own. A handle's row lives from its claim to its release: `:pending`,
  then the task's pid, or `:cancelled` once cancelled.

  ## Lifetimes

  Every change to a claim or a handle's row is made by this process, one
  at a time, so a cancel, a registration and a release never interleave:
  a cancel that reaches a row the release already deleted finds nothing
  and writes nothing, and a registration never overwrites a cancel. A
  registration against a claim that no longer exists answers `:released`
  and records nothing, and its task does not run.

  This process monitors each claimer and each registered task. A task's
  death deletes its row. A claimer's death deletes its row only while no
  task is registered under it: a registered task keeps its row, so a
  cancel that follows the claimer's death (an aborted turn's settlement)
  still reaches it, and the task's own death then deletes it. No row
  outlives both its claimer and its task.

  ## Why there is no authorization check

  Cancellation is not reachable from the wire. MCP 2026-07-28 has no
  cancel-someone-else's-request operation: on Streamable HTTP the *only*
  cancellation signal is the caller closing its own response stream, and the
  key needed to act on that is one the transport already holds for the
  connection in front of it. Nothing accepts a request id from a caller, so
  there is no confused deputy to guard against.
  """

  use GenServer
  @table __MODULE__
  @handles Module.concat(__MODULE__, Handles)

  @typedoc "A caller-owned name for one in-chain call, keyed alone: the caller need not know the request id."
  @type handle :: term()

  @typedoc "One task's claim under a request id, taken by its caller before the task starts."
  @type claim :: reference()

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Claim a place under `request_id` for a task the caller is about to start.

  The caller is monitored: if it dies before a task registers under the
  claim, the claim goes with it.
  """
  @spec claim_request(String.t()) :: claim()
  def claim_request(request_id) when is_binary(request_id),
    do: GenServer.call(__MODULE__, {:claim_request, request_id, self()})

  @doc """
  Register the process doing the work for `claim`, from inside that process
  before its handler runs.

  A request may hold several tasks at once — an in-chain call runs under its
  root's request id — so this adds one, it does not replace what is there.
  `:cancelled` when the request was cancelled after the claim, `:released`
  when the claim is gone (its caller released it or died); either way
  nothing is registered and the handler must not run. A registered task
  is monitored and its row is deleted when it exits.
  """
  @spec register(String.t(), claim(), pid()) :: :ok | :cancelled | :released
  def register(request_id, claim, pid)
      when is_binary(request_id) and is_reference(claim) and is_pid(pid),
      do: GenServer.call(__MODULE__, {:register, request_id, claim, pid})

  @doc """
  Drop one claim after its task completes, leaving any sibling or parent task
  of the same request registered.
  """
  @spec unregister(String.t(), claim()) :: :ok
  def unregister(request_id, claim) when is_binary(request_id) and is_reference(claim) do
    GenServer.cast(__MODULE__, {:unregister, request_id, claim})
    :ok
  end

  @doc """
  Stop every task still registered for `request_id`, and mark every claim
  not yet registered so its task never runs.

  Returns `:ok` when at least one task was killed or claim marked, `{:error,
  :not_found}` otherwise — which is the ordinary outcome when the work had
  already finished by the time the caller hung up, and a second cancel's.
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(request_id) when is_binary(request_id),
    do: GenServer.call(__MODULE__, {:cancel, request_id})

  @doc """
  Claim `handle` before the task it names starts: `:ok`, or `:cancelled`
  when the claimed call was cancelled before its release, in which case
  the handler must not run. The caller is monitored as the handle's
  claimer.
  """
  @spec claim(handle()) :: :ok | :cancelled
  def claim(handle), do: GenServer.call(__MODULE__, {:claim, handle, self()})

  @doc """
  Register the task doing the work for `handle`, from inside that task
  before its handler runs: `:cancelled` when the caller cancelled it in
  between, `:released` when the handle holds no row (released, its
  claimer dead, or never claimed), and in either case the task exits
  without running the handler and nothing is written. A registered task
  is monitored and the handle's row is deleted when it exits.
  """
  @spec register_handle(handle(), pid()) :: :ok | :cancelled | :released
  def register_handle(handle, pid) when is_pid(pid),
    do: GenServer.call(__MODULE__, {:register_handle, handle, pid})

  @doc """
  Cancel the work named by `handle` while its row lives: a registered
  task is killed, and a claimed one not yet registered is refused when
  it registers. A handle already cancelled, released or never claimed
  has no work to stop, and nothing is written for it. Nothing else under
  the same request is touched.
  """
  @spec cancel_handle(handle()) :: :ok
  def cancel_handle(handle), do: GenServer.call(__MODULE__, {:cancel_handle, handle})

  @doc "Forget `handle` once its caller is done with it: its row is deleted."
  @spec release_handle(handle()) :: :ok
  def release_handle(handle), do: GenServer.call(__MODULE__, {:release_handle, handle})

  @doc false
  # The tasks currently registered for a request — for tests and diagnostics.
  @spec pids(String.t()) :: [pid()]
  def pids(request_id) when is_binary(request_id) do
    @table
    |> :ets.lookup(request_id)
    |> Enum.map(fn {^request_id, pid} -> pid end)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      # A `:bag` because one request may hold a chain of tasks, not a
      # single one. Written only here, read from any process.
      :ets.new(@table, [:named_table, :protected, :bag, read_concurrency: true])
    end

    if :ets.whereis(@handles) == :undefined do
      # Written only here (`handle_call/3`), so each change is atomic.
      :ets.new(@handles, [:named_table, :protected, :set, read_concurrency: true])
    end

    # requests: %{claim => %{request_id, status, claimer, task}}, status
    #           `:pending | :cancelled | pid`, claimer and task monitor refs
    # handles:  %{handle => %{claimer, task}}, the row's status in `@handles`
    # monitors: %{monitor_ref => {:claimer | :task, {:request, claim} | {:handle, handle}}}
    {:ok, %{requests: %{}, handles: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:claim_request, request_id, claimer}, _from, state) do
    claim = make_ref()
    {mref, state} = monitor(state, claimer, {:claimer, {:request, claim}})

    entry = %{request_id: request_id, status: :pending, claimer: mref, task: nil}
    {:reply, claim, put_in(state.requests[claim], entry)}
  end

  def handle_call({:register, request_id, claim, pid}, _from, state) do
    case Map.fetch(state.requests, claim) do
      {:ok, %{request_id: ^request_id, status: :pending} = entry} ->
        :ets.insert(@table, {request_id, pid})
        {mref, state} = monitor(state, pid, {:task, {:request, claim}})
        entry = %{entry | status: pid, task: mref}
        {:reply, :ok, put_in(state.requests[claim], entry)}

      {:ok, %{request_id: ^request_id, status: ^pid}} ->
        {:reply, :ok, state}

      {:ok, %{request_id: ^request_id, status: :cancelled}} ->
        {:reply, :cancelled, state}

      _ ->
        {:reply, :released, state}
    end
  end

  def handle_call({:cancel, request_id}, _from, state) do
    {found?, state} =
      state.requests
      |> Enum.filter(fn {_claim, entry} -> entry.request_id == request_id end)
      |> Enum.reduce({false, state}, fn {claim, entry}, {found?, state} ->
        case entry.status do
          :cancelled ->
            {found?, state}

          # Every task under the request, innermost included: the caller has
          # gone, so nothing this request started should keep running. The
          # row goes now; the entry goes with the task's `DOWN`.
          pid when is_pid(pid) ->
            Process.exit(pid, :cancelled)
            :ets.delete_object(@table, {request_id, pid})
            {true, put_in(state.requests[claim].status, :cancelled)}

          :pending ->
            {true, put_in(state.requests[claim].status, :cancelled)}
        end
      end)

    {:reply, if(found?, do: :ok, else: {:error, :not_found}), state}
  end

  def handle_call({:claim, handle, claimer}, _from, state) do
    case :ets.lookup(@handles, handle) do
      [{_, :cancelled}] ->
        {:reply, :cancelled, state}

      [] ->
        :ets.insert(@handles, {handle, :pending})
        {mref, state} = monitor(state, claimer, {:claimer, {:handle, handle}})
        {:reply, :ok, put_in(state.handles[handle], %{claimer: mref, task: nil})}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:register_handle, handle, pid}, _from, state) do
    case :ets.lookup(@handles, handle) do
      [{_, :pending}] ->
        :ets.insert(@handles, {handle, pid})
        {mref, state} = monitor(state, pid, {:task, {:handle, handle}})
        {:reply, :ok, put_in(state.handles[handle].task, mref)}

      [{_, ^pid}] ->
        {:reply, :ok, state}

      [{_, :cancelled}] ->
        {:reply, :cancelled, state}

      # No row: released, its claimer dead, or never claimed here.
      _ ->
        {:reply, :released, state}
    end
  end

  def handle_call({:cancel_handle, handle}, _from, state) do
    case :ets.lookup(@handles, handle) do
      # The row stays until the task's `DOWN`.
      [{_, pid}] when is_pid(pid) ->
        Process.exit(pid, :cancelled)
        :ets.insert(@handles, {handle, :cancelled})

      [{_, :pending}] ->
        :ets.insert(@handles, {handle, :cancelled})

      # Already cancelled, or no row: released, or never claimed here.
      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:release_handle, handle}, _from, state) do
    {:reply, :ok, drop_handle(state, handle)}
  end

  @impl true
  def handle_cast({:unregister, request_id, claim}, state) do
    case Map.fetch(state.requests, claim) do
      {:ok, %{request_id: ^request_id}} -> {:noreply, drop_request(state, claim)}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, mref) do
      {nil, _} ->
        {:noreply, state}

      {{:task, {:request, claim}}, monitors} ->
        {:noreply, drop_request(%{state | monitors: monitors}, claim)}

      {{:task, {:handle, handle}}, monitors} ->
        {:noreply, drop_handle(%{state | monitors: monitors}, handle)}

      {{:claimer, {:request, claim}}, monitors} ->
        state = %{state | monitors: monitors}

        case state.requests[claim] do
          # A registered task keeps its entry until its own exit.
          %{task: task} when is_reference(task) ->
            {:noreply, put_in(state.requests[claim].claimer, nil)}

          _ ->
            {:noreply, drop_request(state, claim)}
        end

      {{:claimer, {:handle, handle}}, monitors} ->
        state = %{state | monitors: monitors}

        case state.handles[handle] do
          %{task: task} when is_reference(task) ->
            {:noreply, put_in(state.handles[handle].claimer, nil)}

          _ ->
            {:noreply, drop_handle(state, handle)}
        end
    end
  end

  @impl true
  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.monitors, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    if :ets.whereis(@handles) != :undefined, do: :ets.delete(@handles)
    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp monitor(state, pid, key) do
    mref = Process.monitor(pid)
    {mref, put_in(state.monitors[mref], key)}
  end

  defp demonitor(state, nil), do: state

  defp demonitor(state, mref) do
    Process.demonitor(mref, [:flush])
    %{state | monitors: Map.delete(state.monitors, mref)}
  end

  defp drop_request(state, claim) do
    case Map.pop(state.requests, claim) do
      {nil, _} ->
        state

      {entry, requests} ->
        if is_pid(entry.status), do: :ets.delete_object(@table, {entry.request_id, entry.status})

        %{state | requests: requests}
        |> demonitor(entry.claimer)
        |> demonitor(entry.task)
    end
  end

  defp drop_handle(state, handle) do
    :ets.delete(@handles, handle)

    case Map.pop(state.handles, handle) do
      {nil, _} ->
        state

      {entry, handles} ->
        %{state | handles: handles}
        |> demonitor(entry.claimer)
        |> demonitor(entry.task)
    end
  end
end
