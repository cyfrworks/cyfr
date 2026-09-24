# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RunningTasks do
  @moduledoc """
  Tracks the process doing the work for an in-flight request, so the transport
  can stop it when the caller goes away.

  Keyed by the server-minted `Sanctum.Context.request_id`, stamped by
  `EmissaryWeb.MCPController`. Client JSON-RPC ids may repeat across callers
  and must not identify running tasks.

  ## Why one request may hold several tasks

  A server-minted id cannot collide *across* requests, but one request can
  hold more than one task at a time: an in-chain tool call inherits its
  root's `request_id` rather than minting a new one (`Cyfr.Ops.Catalog` mints one
  only when no transport did), which is what
  keeps a whole chain attributable to the ingress that started it.

  The ETS bag stores every active task for a request. `unregister/2`
  removes one task, and `cancel/1` stops all tasks still held by the request.

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
  @table __MODULE__
  @handles Module.concat(__MODULE__, Handles)

  @typedoc "A caller-owned name for one in-chain call, keyed alone: the caller need not know the request id."
  @type handle :: term()

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register the process doing the work for `request_id`.

  A request may hold several tasks at once — an in-chain call runs under its
  root's request id — so this adds one, it does not replace what is there.

  The GenServer monitors it and auto-cleans on exit, so a caller that never
  reaches `unregister/2` — because it crashed, or was killed — leaves nothing
  behind.
  """
  @spec register(String.t(), Task.t()) :: :ok
  def register(request_id, %Task{pid: pid}) when is_binary(request_id) do
    :ets.insert(@table, {request_id, pid})
    GenServer.cast(__MODULE__, {:monitor, request_id, pid})
    :ok
  end

  @doc """
  Unregister one task after it completes, leaving any sibling or parent task
  of the same request registered.
  """
  @spec unregister(String.t(), Task.t() | pid()) :: :ok
  def unregister(request_id, %Task{pid: pid}), do: unregister(request_id, pid)

  def unregister(request_id, pid) when is_binary(request_id) and is_pid(pid) do
    GenServer.cast(__MODULE__, {:unregister, request_id, pid})
    :ok
  end

  @doc """
  Stop every task still registered for `request_id`.

  Returns `:ok` when at least one task was found and killed, `{:error,
  :not_found}` otherwise — which is the ordinary outcome when the work had
  already finished by the time the caller hung up.
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(request_id) when is_binary(request_id) do
    case :ets.lookup(@table, request_id) do
      [] ->
        {:error, :not_found}

      entries ->
        # Every task under the request, innermost included: the caller has
        # gone, so nothing this request started should keep running.
        Enum.each(entries, fn {^request_id, pid} ->
          Process.exit(pid, :cancelled)
          GenServer.cast(__MODULE__, {:unregister, request_id, pid})
        end)

        :ok
    end
  end

  @doc """
  Claim `handle` before the task it names starts: `:ok`, or `:cancelled`
  when the caller already cancelled it, in which case the handler must
  not run.
  """
  @spec claim(handle()) :: :ok | :cancelled
  def claim(handle) do
    case :ets.lookup(@handles, handle) do
      [{_, :cancelled}] -> :cancelled
      _ -> if :ets.insert_new(@handles, {handle, :pending}), do: :ok, else: :ok
    end
  end

  @doc """
  Register the task doing the work for `handle`, from inside that task
  before its handler runs: `:cancelled` when the caller cancelled it in
  between, and the task exits without running the handler.
  """
  @spec register_handle(handle(), pid()) :: :ok | :cancelled
  def register_handle(handle, pid) when is_pid(pid) do
    case :ets.lookup(@handles, handle) do
      [{_, :cancelled}] ->
        :cancelled

      _ ->
        :ets.insert(@handles, {handle, pid})
        :ok
    end
  end

  @doc """
  Cancel the work named by `handle`, whether it has started or not: a
  registered task is killed, a pending or unclaimed one is refused when
  it registers or claims. Nothing else under the same request is touched.
  """
  @spec cancel_handle(handle()) :: :ok
  def cancel_handle(handle) do
    case :ets.lookup(@handles, handle) do
      [{_, pid}] when is_pid(pid) -> Process.exit(pid, :cancelled)
      _ -> :ok
    end

    :ets.insert(@handles, {handle, :cancelled})
    :ok
  end

  @doc "Forget `handle` once its caller is done with it."
  @spec release_handle(handle()) :: :ok
  def release_handle(handle) do
    :ets.delete(@handles, handle)
    :ok
  end

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
      # Written on every MCP request from the request processes themselves;
      # both flags, like the limiter tables. A `:bag` because one request may
      # hold a chain of tasks, not a single one.
      :ets.new(@table, [
        :named_table,
        :public,
        :bag,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    if :ets.whereis(@handles) == :undefined do
      :ets.new(@handles, [:named_table, :public, :set, read_concurrency: true])
    end

    # monitors: %{monitor_ref => {request_id, pid}}
    # refs:     %{{request_id, pid} => monitor_ref}
    {:ok, %{monitors: %{}, refs: %{}}}
  end

  @impl true
  def handle_cast({:monitor, request_id, pid}, state) do
    # Only a re-registration of this exact task replaces a monitor; a sibling
    # or nested task of the same request keeps its own.
    state = do_demonitor({request_id, pid}, state)

    ref = Process.monitor(pid)

    state = %{
      state
      | monitors: Map.put(state.monitors, ref, {request_id, pid}),
        refs: Map.put(state.refs, {request_id, pid}, ref)
    }

    {:noreply, state}
  end

  @impl true
  def handle_cast({:unregister, request_id, pid}, state) do
    :ets.delete_object(@table, {request_id, pid})
    state = do_demonitor({request_id, pid}, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      {request_id, pid} = key ->
        :ets.delete_object(@table, {request_id, pid})

        state = %{
          state
          | monitors: Map.delete(state.monitors, ref),
            refs: Map.delete(state.refs, key)
        }

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Cyfr.LoggerContext.unexpected(__MODULE__, msg)
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

  defp do_demonitor(key, state) do
    case Map.get(state.refs, key) do
      nil ->
        state

      ref ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | monitors: Map.delete(state.monitors, ref),
            refs: Map.delete(state.refs, key)
        }
    end
  end
end
