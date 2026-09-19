# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RunnerPool do
  @moduledoc """
  The worker service's runners, each an OS process (`Opus.RunnerProcess`
  over `Opus.Keeper`), in the four states `Cyfr.WorkerAPI` counts:

    * `fresh` — spawned ahead, or spawning, and never assigned: it
      belongs to no athanor. The pool keeps `:pool_size` of them.
    * `idle` — completed a subtree cleanly for one athanor, and kept for
      `:idle_ttl_ms` for that athanor's next subtree only.
    * `busy` — running a subtree.
    * `tainted` — being terminated after a kill, an unclean completion,
      an exit with attempts open, or a failure of its channel or keeper;
      never assigned again.

  `serve/3` tells the pool which service and boot its runners present
  from, and whom to tell what they do; nothing is spawned before. `take/2`
  hands out an idle runner of the athanor first, a fresh one otherwise,
  spawning one when none is ready, and refills the fresh ones behind it;
  the assign the caller then sends is held by the handle until the
  channel attaches. What a busy runner reports reaches the assignee as
  `{Opus.RunnerPool, pid, event}`: `{:child, execution_id, attempt}` for
  each child it starts, `{:complete, execution_id, clean}`,
  `{:exit, runner_id, open}` or `{:gone, reason}` (its channel closed, its
  process exited or its keeper failed with the subtree still assigned).
  The pool moves the runner itself: a clean completion to idle, anything
  else to tainted, released through the keeper at once; `taint/3` does
  the same for a kill, with the grace the runner is given to report.
  `cancel_child/3` sends one busy runner a `cancel_child`, and
  `cancel_child/2` every busy runner; one that does not run the child
  ignores it.

  A tainted runner leaves the pool once the keeper reports it retired;
  its handle is stopped then. `retire_busy/2` taints every busy runner
  with no grace and answers once none is left being ended, keeping the
  fresh and idle ones pooled. A keeper that fails takes the pool with it
  through their common supervisor, and every busy runner's assignee
  hears `{:gone, _}` first.

  ## A keeper that refuses runners

  A runner the keeper refuses to start (`{:refused, reason}` from its
  handle: no process of it ever ran, so there is nothing to retire) leaves
  the pool at once, and its assignee, if it had one, hears
  `{:gone, {:refused, reason}}`. The pool then refuses until a runner
  starts again: it spawns one runner at a time, after a wait that doubles
  from one second to half a minute, never hands out a runner still
  spawning nor counts it in `status/1`, and answers a `take/3` no fresh or
  idle runner can serve `{:error, {:refused, refusal}}`, the keeper's own
  account of why (`c:Opus.Keeper.refusal/1`), which `status/1` reports
  too. The first runner that attaches ends the refusal and the pool fills
  again.
  """

  use GenServer

  require Logger

  alias Opus.RunnerProcess

  @refill_backoff_ms 1_000
  @max_backoff_ms 30_000

  @typedoc "One runner as the pool sees it."
  @type runner :: %{
          pid: pid(),
          id: String.t(),
          state: :spawning | :fresh | :idle | :busy | :tainted | :retiring,
          athanor: String.t() | nil,
          execution_id: String.t() | nil
        }

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Start the pool. Options: `:settings` (`t:Opus.Settings.pool/0`),
  `:keeper` (the keeper module), `:keeper_opts` (the options the keeper
  was started with, default none), `:supervisor` (the `DynamicSupervisor`
  the handles run under), `:command` (`t:Opus.Release.command/0`, default
  this boot's), `:name` (default `#{inspect(__MODULE__)}`).
  """
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Serve `service` (`%{service_id, boot, host_url}`), telling `assignee` what busy runners report; the pool fills."
  @spec serve(GenServer.server(), map(), pid()) :: :ok
  def serve(pool, %{service_id: _, boot: _, host_url: _} = service, assignee)
      when is_pid(assignee),
      do: GenServer.call(pool, {:serve, service, assignee})

  @doc """
  Take a runner for a subtree of `athanor` running `execution_id`: its
  handle and its id, or `{:error, {:refused, refusal}}` while the keeper
  refuses runners and none is fresh or idle for it.
  """
  @spec take(GenServer.server(), String.t(), String.t()) ::
          {:ok, pid(), String.t()}
          | {:error,
             {:refused, Cyfr.WorkerAPI.refusal()} | :not_serving | {:spawn_failed, term()}}
  def take(pool, athanor, execution_id) when is_binary(athanor) and is_binary(execution_id),
    do: GenServer.call(pool, {:take, athanor, execution_id})

  @doc "Taint the runner `pid` and end it, with `grace_ms` to report what it holds."
  @spec taint(GenServer.server(), pid(), non_neg_integer()) :: :ok
  def taint(pool, pid, grace_ms) when is_pid(pid) and is_integer(grace_ms) and grace_ms >= 0,
    do: GenServer.call(pool, {:taint, pid, grace_ms})

  @doc """
  Taint every busy runner and end it at once, with no grace, and answer
  once every runner being ended has been retired by the keeper; fresh and
  idle runners stay pooled. For a caller that must know no runner of the
  work it started is left, as a test's end does: a runner still running
  a subtree could otherwise make its next host call after the caller
  moved on. Exits if that takes longer than `timeout_ms`.
  """
  @spec retire_busy(GenServer.server(), timeout()) :: :ok
  def retire_busy(pool, timeout_ms \\ 30_000),
    do: GenServer.call(pool, :retire_busy, timeout_ms)

  @doc "Send every busy runner a `cancel_child` for `execution_id`."
  @spec cancel_child(GenServer.server(), String.t()) :: :ok
  def cancel_child(pool, execution_id) when is_binary(execution_id),
    do: GenServer.call(pool, {:cancel_child, :busy, execution_id})

  @doc "Send the runner `pid`, if it is busy, a `cancel_child` for `execution_id`."
  @spec cancel_child(GenServer.server(), pid(), String.t()) :: :ok
  def cancel_child(pool, pid, execution_id) when is_pid(pid) and is_binary(execution_id),
    do: GenServer.call(pool, {:cancel_child, pid, execution_id})

  @doc """
  The pool's part of `t:Cyfr.WorkerAPI.status/0`: its runners counted by
  state, the memory bound its keeper holds every runner to, and the
  keeper's refusal while it refuses runners.
  """
  @spec status(GenServer.server()) :: %{
          runners: %{
            fresh: non_neg_integer(),
            idle: non_neg_integer(),
            busy: non_neg_integer(),
            tainted: non_neg_integer()
          },
          memory_bytes: pos_integer() | nil,
          refusal: Cyfr.WorkerAPI.refusal() | nil
        }
  def status(pool), do: GenServer.call(pool, :status)

  @doc "Every runner the pool holds (`t:runner/0`)."
  @spec runners(GenServer.server()) :: [runner()]
  def runners(pool), do: GenServer.call(pool, :runners)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    keeper = Keyword.fetch!(opts, :keeper)

    {:ok,
     %{
       settings: Keyword.fetch!(opts, :settings),
       keeper: keeper,
       memory_bytes: keeper.memory_bytes(Keyword.get(opts, :keeper_opts, [])),
       supervisor: Keyword.fetch!(opts, :supervisor),
       command: Keyword.get_lazy(opts, :command, &Opus.Release.runner_command/0),
       service: nil,
       assignee: nil,
       runners: %{},
       refill_scheduled: false,
       refusal: nil,
       backoff_ms: @refill_backoff_ms,
       retirees: []
     }}
  end

  @impl true
  def handle_call({:serve, service, assignee}, _from, state) do
    {:reply, :ok, refill(%{state | service: service, assignee: assignee})}
  end

  def handle_call({:take, _athanor, _execution_id}, _from, %{service: nil} = state),
    do: {:reply, {:error, :not_serving}, state}

  def handle_call({:take, athanor, execution_id}, _from, state) do
    case pick(state, athanor) do
      {:ok, pid, entry} ->
        entry = %{
          entry
          | state: :busy,
            athanor: athanor,
            execution_id: execution_id,
            idle_timer: nil
        }

        state = put_runner(state, pid, entry)
        {:reply, {:ok, pid, entry.id}, refill(state)}

      :none when state.refusal != nil ->
        {:reply, {:error, {:refused, state.refusal}}, state}

      :none ->
        case spawn_runner(state) do
          {:ok, pid, entry} ->
            entry = %{entry | state: :busy, athanor: athanor, execution_id: execution_id}
            {:reply, {:ok, pid, entry.id}, refill(put_runner(state, pid, entry))}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:taint, pid, grace_ms}, _from, state) do
    case state.runners[pid] do
      nil -> {:reply, :ok, state}
      entry -> {:reply, :ok, taint(state, pid, entry, grace_ms)}
    end
  end

  def handle_call(:retire_busy, from, state) do
    state =
      Enum.reduce(state.runners, state, fn
        {pid, %{state: :busy} = entry}, state -> taint(state, pid, entry, 0)
        _runner, state -> state
      end)

    {:noreply, retired(%{state | retirees: [from | state.retirees]})}
  end

  def handle_call({:cancel_child, to, execution_id}, _from, state) do
    for {pid, %{state: :busy}} <- state.runners, to == :busy or to == pid do
      _ = RunnerProcess.send_message(pid, %{type: :cancel_child, execution_id: execution_id})
    end

    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    counts =
      Enum.reduce(state.runners, %{fresh: 0, idle: 0, busy: 0, tainted: 0}, fn {_pid, entry},
                                                                               counts ->
        case entry.state do
          :fresh -> Map.update!(counts, :fresh, &(&1 + 1))
          # A runner still spawning is counted fresh when a take could be
          # given it (`pick/2`): not while the keeper refuses runners, when
          # it is the pool's next try and no runner the pool holds.
          :spawning when state.refusal == nil -> Map.update!(counts, :fresh, &(&1 + 1))
          :spawning -> counts
          :idle -> Map.update!(counts, :idle, &(&1 + 1))
          :busy -> Map.update!(counts, :busy, &(&1 + 1))
          :tainted -> Map.update!(counts, :tainted, &(&1 + 1))
          :retiring -> counts
        end
      end)

    {:reply, %{runners: counts, memory_bytes: state.memory_bytes, refusal: state.refusal}, state}
  end

  def handle_call(:runners, _from, state) do
    runners =
      for {pid, entry} <- state.runners,
          do: %{
            pid: pid,
            id: entry.id,
            state: entry.state,
            athanor: entry.athanor,
            execution_id: entry.execution_id
          }

    {:reply, runners, state}
  end

  @impl true
  def handle_info({RunnerProcess, pid, event}, state) do
    case state.runners[pid] do
      nil -> {:noreply, state}
      entry -> {:noreply, retired(on_event(event, pid, entry, state))}
    end
  end

  def handle_info({:idle_expired, pid, timer}, state) do
    case state.runners[pid] do
      %{state: :idle, idle_timer: ^timer} = entry ->
        RunnerProcess.release(pid, 0)
        {:noreply, refill(put_runner(state, pid, %{entry | state: :retiring, idle_timer: nil}))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:refill, state), do: {:noreply, refill(%{state | refill_scheduled: false})}

  def handle_info({:DOWN, _monitor, :process, pid, reason}, state) do
    case Map.pop(state.runners, pid) do
      {nil, _runners} ->
        {:noreply, state}

      {entry, runners} ->
        if entry.execution_id, do: tell(state, pid, {:gone, {:handle_down, reason}})
        {:noreply, retired(refill_later(%{state | runners: runners}))}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # What a runner reports
  # ---------------------------------------------------------------------------

  defp on_event(:ready, pid, %{state: :spawning} = entry, state),
    do: state |> put_runner(pid, %{entry | state: :fresh}) |> started()

  defp on_event(:ready, _pid, _entry, state), do: started(state)

  # No process of the runner ran: it leaves the pool at once, with nothing
  # for the keeper to retire, and the pool refuses until one starts.
  defp on_event({:refused, reason}, pid, entry, state) do
    state = told(state, pid, entry, {:gone, {:refused, reason}})
    _ = DynamicSupervisor.terminate_child(state.supervisor, pid)
    refusal = state.keeper.refusal(reason)

    if state.refusal == nil,
      do:
        Logger.error(
          "[Opus.RunnerPool] the keeper refuses runners (#{refusal.reason}); " <>
            "trying one again from #{state.backoff_ms} ms, backing off"
        )

    back_off(%{state | runners: Map.delete(state.runners, pid), refusal: refusal})
  end

  # A complete from a runner already tainted (killed while it finished)
  # is heard, since its attempts are closed, but the runner stays tainted.
  defp on_event({:message, %{type: :complete} = message}, pid, entry, state) do
    state = told(state, pid, entry, {:complete, message.execution_id, message.clean})
    entry = state.runners[pid]

    cond do
      entry.state != :busy ->
        state

      message.clean ->
        timer = make_ref()
        Process.send_after(self(), {:idle_expired, pid, timer}, state.settings.idle_ttl_ms)
        put_runner(state, pid, %{entry | state: :idle, idle_timer: timer})

      true ->
        taint(state, pid, entry, 0)
    end
  end

  # A child the runner started for the subtree it runs: its assignee
  # learns which runner holds it. One heard after the subtree was told of
  # (the runner killed as it started the child) is the runner's end's.
  defp on_event({:message, %{type: :child} = message}, pid, entry, state) do
    if entry.execution_id, do: tell(state, pid, {:child, message.execution_id, message.attempt})
    state
  end

  defp on_event({:message, %{type: :exit} = message}, pid, entry, state) do
    state = told(state, pid, entry, {:exit, message.runner, message.open})
    taint(state, pid, state.runners[pid], 0)
  end

  defp on_event({:message, message}, pid, entry, state) do
    Logger.warning(
      "[Opus.RunnerPool] runner #{entry.id} sent #{message.type} while #{entry.state}"
    )

    gone(state, pid, entry, {:protocol, message.type})
  end

  defp on_event(:closed, pid, entry, state), do: gone(state, pid, entry, :closed)
  defp on_event({:exited, how}, pid, entry, state), do: gone(state, pid, entry, {:exited, how})

  defp on_event({:error, reason}, pid, entry, state) do
    Logger.warning("[Opus.RunnerPool] runner #{entry.id}: #{inspect(reason)}")
    gone(state, pid, entry, reason)
  end

  defp on_event(:released, pid, _entry, state) do
    _ = DynamicSupervisor.terminate_child(state.supervisor, pid)
    refill(%{state | runners: Map.delete(state.runners, pid)})
  end

  # The runner is no longer usable: what it was running is gone, and the
  # keeper is asked to end whatever is left of it.
  defp gone(state, pid, entry, reason) do
    state = told(state, pid, entry, {:gone, reason})
    entry = state.runners[pid]

    case entry.state do
      :retiring -> state
      :tainted -> state
      _ -> taint(state, pid, entry, 0)
    end
  end

  # An assignment is told of once: the first of its complete, its exit or
  # the runner's end ends it for the assignee.
  defp told(state, _pid, %{execution_id: nil}, _event), do: state

  defp told(state, pid, entry, event) do
    tell(state, pid, event)
    put_runner(state, pid, %{entry | execution_id: nil})
  end

  # An idle timer left running is harmless: its message names the timer
  # it was armed with, and a runner no longer idle on that timer ignores it.
  defp taint(state, _pid, %{state: :tainted}, _grace_ms), do: state

  defp taint(state, pid, entry, grace_ms) do
    RunnerProcess.release(pid, grace_ms)
    refill_later(put_runner(state, pid, %{entry | state: :tainted, idle_timer: nil}))
  end

  # Whoever waits for the busy runners' ends is answered once no runner is
  # being ended.
  defp retired(%{retirees: []} = state), do: state

  defp retired(state) do
    if Enum.any?(state.runners, fn {_pid, e} -> e.state in [:tainted, :retiring] end) do
      state
    else
      for from <- state.retirees, do: GenServer.reply(from, :ok)
      %{state | retirees: []}
    end
  end

  defp tell(%{assignee: assignee}, pid, event) when is_pid(assignee),
    do: send(assignee, {__MODULE__, pid, event})

  defp tell(_state, _pid, _event), do: :ok

  # ---------------------------------------------------------------------------
  # Picking and spawning
  # ---------------------------------------------------------------------------

  # An idle runner of the athanor, then a fresh one (attached or still
  # spawning, since an assign waits for the channel, unless the keeper
  # refuses runners and the one spawning is likely refused too).
  defp pick(state, athanor) do
    idle = Enum.find(state.runners, fn {_pid, e} -> e.state == :idle and e.athanor == athanor end)

    fresh =
      idle ||
        Enum.find(state.runners, fn {_pid, e} -> e.state == :fresh end) ||
        (state.refusal == nil &&
           Enum.find(state.runners, fn {_pid, e} -> e.state == :spawning end))

    case fresh do
      {pid, entry} -> {:ok, pid, entry}
      _none -> :none
    end
  end

  defp spawn_runner(%{service: service} = state) do
    id = Cyfr.UUID7.generate_id("runner")

    env =
      Map.merge(
        state.command.env,
        Opus.Settings.runner_environment(%{
          runner_id: id,
          service_id: service.service_id,
          boot: service.boot,
          host_url: service.host_url,
          watchdog_grace_ms: state.settings.watchdog_grace_ms
        })
      )

    spec = %{runner: id, argv: state.command.argv, env: env}

    case DynamicSupervisor.start_child(
           state.supervisor,
           {RunnerProcess, id: id, keeper: state.keeper, spec: spec, owner: self()}
         ) do
      {:ok, pid} ->
        Process.monitor(pid)
        {:ok, pid, %{id: id, state: :spawning, athanor: nil, execution_id: nil, idle_timer: nil}}

      {:error, reason} ->
        Logger.error("[Opus.RunnerPool] a runner could not be started: #{inspect(reason)}")
        {:error, {:spawn_failed, reason}}
    end
  end

  defp refill(%{service: nil} = state), do: state

  # While the keeper refuses runners, one is spawned at a time, when the
  # wait since the last refusal is over, to learn whether it starts them
  # again.
  defp refill(%{refusal: refusal, refill_scheduled: true} = state) when refusal != nil,
    do: state

  defp refill(state) do
    ahead = Enum.count(state.runners, fn {_pid, e} -> e.state in [:fresh, :spawning] end)

    Enum.reduce_while(1..max(target(state) - ahead, 0)//1, state, fn _n, state ->
      case spawn_runner(state) do
        {:ok, pid, entry} -> {:cont, put_runner(state, pid, entry)}
        {:error, _reason} -> {:halt, refill_later(state)}
      end
    end)
  end

  defp target(%{refusal: nil, settings: settings}), do: settings.pool_size
  defp target(_refusing), do: 1

  defp refill_later(state, delay_ms \\ @refill_backoff_ms)

  defp refill_later(%{refill_scheduled: true} = state, _delay_ms), do: state

  defp refill_later(state, delay_ms) do
    Process.send_after(self(), :refill, delay_ms)
    %{state | refill_scheduled: true}
  end

  # The next try after a refusal waits twice as long as the last, up to
  # the most; a refusal that arrives while one is already scheduled (the
  # rest of a fill) waits for it.
  defp back_off(%{refill_scheduled: true} = state), do: state

  defp back_off(state) do
    state
    |> refill_later(state.backoff_ms)
    |> Map.put(:backoff_ms, min(state.backoff_ms * 2, @max_backoff_ms))
  end

  # A runner attached: the keeper starts runners, and the pool fills.
  defp started(%{refusal: nil} = state), do: state

  defp started(state) do
    Logger.info("[Opus.RunnerPool] the keeper starts runners again")
    refill(%{state | refusal: nil, backoff_ms: @refill_backoff_ms})
  end

  defp put_runner(state, pid, entry), do: %{state | runners: Map.put(state.runners, pid, entry)}
end
