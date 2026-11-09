# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Status do
  @moduledoc """
  How an athanor's CYFR stands (`Cyfr.Bus.SystemStatus`), read for the
  stream `system.changes` (`Aqua.Providers.Status`), and the watch that
  tells it on the athanor's `Cyfr.Bus.system/1` when it moves.

  `read/1` reads every field from its one source, under the context it
  is handed; a source that does not answer leaves its fields nil:

  | field | source |
  |---|---|
  | `health` | `low_storage` while the storage reserve is spent (`Arca.StorageReserve.depleted?/0`); otherwise the gate's own `system.status`, `ok` when it answers `ok` and `degraded` for any other answer |
  | `storage_used` | the athanor's stored bytes (`Arca.Usage.athanor_bytes/1`) |
  | `storage_cap` | the athanor storage cap (`Sanctum.Tenancy.Caps.get/1`), nil when off |
  | `model_connected`, `crew_ready`, `crew_total` | the brains (`Aqua.Crew.brains/1`) |
  | `version` | `Prima.Version.current/0` |
  | `update_available` | the release channel (`Cyfr.ReleaseChannel.update_available/0`) |

  ## The watch

  One process per server, holding the athanors whose status a refresh
  read (`watch/2`): for each, the latest opening context, an expiry the
  stream's deadline bound after that opening, and the status last told.
  It hears the athanor's vault entries and components, which move a
  brain's readiness, and reads the status again a second after a burst of
  them settles; it reads every watched athanor's status again on a
  minute's tick, after the kept context is established again
  (`Sanctum.Tenancy.revalidate/1`): a context that no longer stands, or
  an expired opening, drops the athanor. A status that differs from the
  one last told is published, and only then. A read runs on
  `Aqua.TaskSupervisor` and is abandoned after a few seconds, and a read
  that fails publishes nothing, so the watch outlives every read.

  Options: `:enabled`, false for a watch that starts nothing (the
  suite's, `:status_watch_enabled`: under the test sandbox a tick would
  read on another test's connection, so the suite starts its own); and
  `:bound_ms`, the expiry after an opening, the stream's deadline bound
  by default.
  """

  use GenServer

  require Logger

  alias Cyfr.Bus.{Components, SystemStatus, VaultEntry}
  alias Sanctum.Context

  @tick_ms 60_000
  @settle_ms 1_000
  @read_ms 5_000

  @doc "How the context's athanor stands, each field from its source (the moduledoc's)."
  @spec read(Context.t()) :: SystemStatus.t()
  def read(%Context{} = ctx) do
    brains =
      case Aqua.Crew.brains(ctx) do
        {:ok, brains} -> brains
        {:error, _unread} -> %{}
      end

    SystemStatus.new(Context.actor(ctx), :changed, %{
      health: health(ctx),
      storage_used: answered(Arca.Usage.athanor_bytes(Context.actor(ctx))),
      storage_cap: answered(Sanctum.Tenancy.Caps.get(:athanor_storage_bytes)),
      model_connected: brains[:model_connected],
      crew_ready: brains[:crew_ready],
      crew_total: brains[:crew_total],
      version: Prima.Version.current(),
      update_available: Cyfr.ReleaseChannel.update_available()
    })
  end

  @doc """
  Watch the context's athanor from now: keep `ctx` as its latest opening
  and `status` as what was last told of it. A status that differs from the
  one already told is published, so the subscribers that opened earlier
  hear it too. Answers at once.
  """
  @spec watch(Context.t(), SystemStatus.t()) :: :ok
  def watch(%Context{} = ctx, %SystemStatus{} = status),
    do: GenServer.cast(__MODULE__, {:watch, ctx, status})

  defp health(ctx) do
    if Arca.StorageReserve.depleted?() do
      "low_storage"
    else
      case Aqua.Ops.call_tool("system", ctx, %{"action" => "status"}) do
        {:ok, %{status: "ok"}} -> "ok"
        {:ok, _answered} -> "degraded"
        {:error, _unanswered} -> nil
      end
    end
  end

  defp answered({:ok, value}), do: value
  defp answered({:error, _unread}), do: nil

  # ---------------------------------------------------------------------------
  # The watch
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    if Keyword.get(opts, :enabled, true),
      do: GenServer.start_link(__MODULE__, opts, name: __MODULE__),
      else: :ignore
  end

  @impl true
  def init(opts) do
    [%Prima.Provider.Stream{deadline_bound: bound}] = Aqua.Providers.Status.streams()

    {:ok,
     %{
       bound_ms: Keyword.get(opts, :bound_ms, bound * 1_000),
       watched: %{},
       reading: %{},
       settling: MapSet.new(),
       tick: Process.send_after(self(), :tick, @tick_ms)
     }}
  end

  @impl true
  def handle_cast({:watch, %Context{athanor_id: id} = ctx, status}, state) do
    expires = now() + state.bound_ms

    watched =
      case state.watched do
        %{^id => entry} ->
          if status != entry.told, do: publish(ctx, status)
          %{entry | ctx: ctx, expires: expires, told: status}

        _new ->
          actor = Context.actor(ctx)
          :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.vault_entries(actor))
          :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.components(actor))
          %{ctx: ctx, expires: expires, told: status}
      end

    {:noreply, put_in(state.watched[id], watched)}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.cancel_timer(state.tick)
    now = now()

    state =
      Enum.reduce(state.watched, state, fn {id, entry}, state ->
        if now >= entry.expires, do: drop(state, id), else: start_read(state, id)
      end)

    {:noreply, %{state | tick: Process.send_after(self(), :tick, @tick_ms)}}
  end

  def handle_info(%VaultEntry{athanor_id: id}, state), do: {:noreply, settle(state, id)}
  def handle_info(%Components{athanor_id: id}, state), do: {:noreply, settle(state, id)}

  def handle_info({:settled, id}, state) do
    state = %{state | settling: MapSet.delete(state.settling, id)}

    cond do
      not Map.has_key?(state.watched, id) -> {:noreply, state}
      Map.has_key?(state.reading, id) -> {:noreply, settle(state, id)}
      true -> {:noreply, start_read(state, id)}
    end
  end

  def handle_info({ref, answer}, state) when is_reference(ref) do
    case reading(state, ref) do
      {:ok, id, timer} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(timer)
        {:noreply, read_done(%{state | reading: Map.delete(state.reading, id)}, id, answer)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case reading(state, ref) do
      {:ok, id, timer} ->
        Process.cancel_timer(timer)
        {:noreply, %{state | reading: Map.delete(state.reading, id)}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:abandon, ref}, state) do
    case reading(state, ref) do
      {:ok, id, _timer} ->
        {pid, ^ref} = Map.fetch!(state.reading, id).task
        Process.demonitor(ref, [:flush])
        _ = Task.Supervisor.terminate_child(Aqua.TaskSupervisor, pid)

        Logger.info(
          "[Aqua.Status] a status read of #{id} outran #{@read_ms} ms and was abandoned"
        )

        {:noreply, %{state | reading: Map.delete(state.reading, id)}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  # A burst of changes is read once, a second after its first message.
  defp settle(state, id) do
    if Map.has_key?(state.watched, id) and not MapSet.member?(state.settling, id) do
      Process.send_after(self(), {:settled, id}, @settle_ms)
      %{state | settling: MapSet.put(state.settling, id)}
    else
      state
    end
  end

  # One read at a time per athanor: a tick that finds one running leaves
  # it be, and a settled burst waits for it.
  defp start_read(state, id) do
    if Map.has_key?(state.reading, id) do
      state
    else
      ctx = state.watched[id].ctx
      task = Task.Supervisor.async_nolink(Aqua.TaskSupervisor, fn -> reread(ctx) end)
      timer = Process.send_after(self(), {:abandon, task.ref}, @read_ms)
      put_in(state.reading[id], %{task: {task.pid, task.ref}, timer: timer})
    end
  end

  # The kept context established again before it reads: one that no
  # longer stands in its athanor drops it, and a store that cannot say
  # reads nothing this round.
  defp reread(%Context{athanor_id: id} = ctx) do
    case Sanctum.Tenancy.revalidate(ctx) do
      {:ok, %Context{authenticated: true, athanor_id: ^id} = current} -> {:read, read(current)}
      {:ok, _fallen} -> :fallen
      {:error, :unavailable} -> :unread
    end
  end

  defp read_done(state, id, {:read, status}) do
    case state.watched do
      %{^id => %{told: ^status}} ->
        state

      %{^id => entry} ->
        publish(entry.ctx, status)
        put_in(state.watched[id].told, status)

      _dropped ->
        state
    end
  end

  defp read_done(state, id, :fallen), do: drop(state, id)
  defp read_done(state, _id, _unread), do: state

  defp drop(state, id) do
    case state.watched do
      %{^id => %{ctx: ctx}} ->
        actor = Context.actor(ctx)
        _ = Cyfr.Bus.unsubscribe(actor, Cyfr.Bus.vault_entries(actor))
        _ = Cyfr.Bus.unsubscribe(actor, Cyfr.Bus.components(actor))
        %{state | watched: Map.delete(state.watched, id)}

      _gone ->
        state
    end
  end

  defp publish(ctx, status) do
    actor = Context.actor(ctx)
    _ = Cyfr.Bus.broadcast(actor, Cyfr.Bus.system(actor), status)
    :ok
  end

  defp reading(state, ref) do
    Enum.find_value(state.reading, :error, fn
      {id, %{task: {_pid, ^ref}, timer: timer}} -> {:ok, id, timer}
      _other -> nil
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
