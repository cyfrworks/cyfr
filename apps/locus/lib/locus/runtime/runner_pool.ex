# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RunnerPool do
  @moduledoc """
  The worker service's runners, each an OS process (`Locus.Runtime.RunnerProcess`
  over `Locus.Runtime.Keeper`), in the four states `Prima.WorkerAPI` counts:

    * `fresh` — spawned ahead, or spawning, and never assigned: it
      belongs to no athanor. The pool keeps the warm floor's
      (`Prima.LocusPool.floor_runners/0`) of them.
    * `idle` — completed a subtree cleanly for one athanor, and kept up
      to `:idle_ttl_ms` for that athanor's next subtree only, giving way
      before then when the keeper needs its memory or a spawn its uid.
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
  `{Locus.Runtime.RunnerPool, pid, event}`: `{:child, execution_id, attempt}` for
  each child it starts, `{:complete, execution_id, clean}`,
  `{:exit, runner_id, open}` or `{:gone, reason}` (its channel closed, its
  process exited or its keeper failed with the subtree still assigned).
  The pool moves the runner itself: a clean completion to idle, anything
  else to tainted, released through the keeper at once, a clean
  completion whose place its keeper did not make warm again among them,
  in the same move as its completion is heard; `taint/4` does
  the same for a kill, with the grace the runner is given to report, of a
  runner that still runs the execution it names: one that has completed
  it, or been taken for another since, is left alone. A runner tainted
  while its process still waits for its place, which reads no release
  then, has its handle ended at once: the handle is the place's owner, so
  the keeper's client drops the place (`Locus.Launcher`, "Places") and the
  starts queued behind it for room move, and the runner is held as one
  whose handle died is, below, with no retirement bound, which the wait
  for room would outlast.
  `cancel_child/3` sends one busy runner a `cancel_child`, and
  `cancel_child/2` every busy runner; one that does not run the child
  ignores it.

  Every runner runs in a place of its keeper's named by the runner's id,
  which the runner's process makes before it spawns and assigns itself
  (`Locus.Runtime.RunnerProcess`): `warm` and no athanor's while the runner
  is fresh, `run` for the work's athanor once the keeper has answered the
  assign the work then follows, and `warm`, still that athanor's, from its
  clean completion, before the pool hears it. The pool never waits on the
  keeper for a place: the runner's process does, for the keeper's room,
  and tells the pool the memory bound the keeper placed it with, which
  `status/1` reports. The keeper may ask, unasked, that an idle runner give
  way to a start that waits for room: the pool releases the runner it
  names, as an idle runner's time running out releases it, only while it
  is still idle for its athanor or fresh with no take on it, and leaves a
  busy, taken or ending one alone.

  ## Uids

  Every runner the pool holds holds one of its role's uids
  (`Prima.LocusRoles`, `:uids`, the keeper's `--pool`), or will once it
  spawns, until the keeper reports it released. A take or a refill that
  needs a spawn while every uid is held waits for one: for that of a
  runner already being ended that no start waits on yet, or else of the
  oldest kept runner, which is released for it. A take so waits on that
  runner, by its own deadline, and `withdraw/2` ends its wait, as it ends
  a wait on a spawn; the runner released for it stays released. At the
  runner's release the takes waiting are taken again first, then the pool
  fills. A busy or fresh runner never gives way for a uid: with every uid
  held by them a take spawns all the same, and the keeper's refusal for
  want of a uid answers it.

  A tainted runner leaves the pool only once the keeper reports it
  retired, its handle stopped then: what a runner holds, its uid and its
  place, is given back on the keeper's word alone. One its keeper has not
  retired within its release's grace and the retirement bound is said so
  once, with an error naming it, and its assignee, if it still had one,
  hears `{:gone, :retire_bound}`; the runner stays, tainted, until the
  report. The pool is every runner's heir (`Locus.Launcher`), so a runner
  whose handle dies, its owner gone with it, is held the same way: said
  so once, its assignee told `{:gone, {:handle_down, reason}}`, and
  tainted until its release reaches the pool, or until the keeper says it
  holds no spawn of it (`c:Locus.Runtime.Keeper.fence/2`), none having
  been written and none to be, when it is forgotten. A runner whose spawn
  went unanswered may yet have been written: its handle is stopped, and
  it is held as a dead handle's runner is. Every runner held, being
  ended or refused after it was made, is counted `tainted` in
  `status/1`. A keeper that fails takes the pool with it through their
  common supervisor, and every busy runner's assignee hears `{:gone, _}`
  first.

  ## A keeper that refuses runners

  A runner the keeper refuses to start (`{:refused, reason}` from its
  handle: no process of it ever ran, so there is nothing to retire) leaves
  the pool at once, and its assignee, if it had one, hears
  `{:gone, {:refused, refusal}}`, the keeper's own code and sentence for
  it (`c:Locus.Runtime.Keeper.refusal/1`). A place the keeper refused for
  room (`no_memory`) of a runner a take was given or waits on is that
  take's alone, refused after its wait, and the rest of this section does
  not apply to it: the pool remembers no refusal, backs off nothing, and
  fills again as after any runner's end. One of a runner nobody took, a
  fresh one the keeper refuses at once because no empty pool could hold
  it, is the pool's refusal as any other. One the keeper refused after it made
  something of it (`{:refused, reason, :release_follows}`) is told of the
  same way but stays, `refused`, until the keeper reports it released:
  never handed out, counted `tainted` in `status/1` and asked no
  release, it keeps its place among the runners spawned ahead, so the
  pool starts none in its stead while the keeper still holds its uid and
  place. The pool remembers the refusal, the keeper's own account of
  why (`c:Locus.Runtime.Keeper.refusal/1`), which `status/1` reports, and
  it paces the pool's own spawning ahead and nothing else: the pool
  spawns one runner at a time, after a wait that doubles from one second
  to half a minute, one wait at a time, and once no runner it refused after making is held,
  and never hands out a runner still spawning nor counts it in
  `status/1`. A `take/4` no fresh or idle runner can serve spawns one, as
  it does when no refusal stands, and is never answered from the
  remembered refusal: it waits, by its deadline, for that spawn's own
  answer, and is given the runner once it attached, or refused with the
  keeper's account of why it refused that spawn, so a start during a lack
  that lasts is refused with the reason of that moment and leaves no
  run. `withdraw/2` ends such a wait for a start a kill reached: the take
  is answered `{:error, :killed}`, and its runner, while its process
  still waits for its place, has its handle ended as a tainted one's is
  (below), so the place leaves the keeper's queue then. A runner refused after the keeper made it is held, as above, until
  the keeper releases it, which it does at once, so a start holds at most
  one such runner. With no refusal remembered a take answers at once, its
  runner spawning or not. The first runner that attaches ends the refusal, and
  so does the release of any runner but one the keeper refused after
  making it, which frees a uid the refusal may have lacked: the pool then
  fills again at once, around any runner still held.
  """

  use GenServer

  require Logger

  alias Locus.Runtime.RunnerProcess

  @refill_backoff_ms 1_000
  # The room past a take's deadline for the pool's answer; a take whose
  # caller names no deadline waits for a spawn's place, its room's wait
  # included (`Locus.Launcher.place_wait_ms/0`), and this much more.
  @take_answer_ms 500
  @spawn_wait_ms 5_000
  @retire_bound_ms 10_000
  @max_backoff_ms 30_000

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Start the pool. Options: `:settings` (`t:Locus.Runtime.Settings.pool/0`),
  `:keeper` (the keeper module), `:keeper_opts` (the options the keeper
  was started with, default none), `:supervisor` (the `DynamicSupervisor`
  the handles run under), `:command` (`t:Locus.Runtime.Release.command/0`, default
  this boot's), `:retire_bound_ms` (how long past a release's grace the
  pool waits for the keeper to retire the runner before it says so,
  default #{@retire_bound_ms}), `:uids` (how many uids the keeper's pool
  for runners has, default its role's, `Prima.LocusRoles`), `:clock` (the
  monotonic milliseconds an idle runner's time is read on, default the
  system's), `:name` (default `#{inspect(__MODULE__)}`).
  """
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Serve `service` (`%{service_id, boot}`), telling `assignee` what busy runners report; the pool fills."
  @spec serve(GenServer.server(), map(), pid()) :: :ok
  def serve(pool, %{service_id: _, boot: _} = service, assignee)
      when is_pid(assignee),
      do: GenServer.call(pool, {:serve, service, assignee})

  @doc """
  Take a runner for a subtree of `athanor` running `execution_id` by
  `deadline` (monotonic milliseconds): its handle and its id, spawning one
  when none is fresh or idle for it. While the pool remembers a refusal,
  a take that spawns its runner is answered only once that spawn is: the
  runner once attached, `{:error, {:refused, refusal}}` with the keeper's
  account of why it refused that spawn, or `{:error, :past_deadline}`.
  """
  @spec take(GenServer.server(), String.t(), String.t(), integer()) ::
          {:ok, pid(), String.t()}
          | {:error,
             {:refused, Prima.WorkerAPI.refusal()}
             | :past_deadline
             | :killed
             | :not_serving
             | {:spawn_failed, term()}}
  def take(pool, athanor, execution_id, deadline \\ now() + take_wait_ms())
      when is_binary(athanor) and is_binary(execution_id) and is_integer(deadline),
      do:
        GenServer.call(
          pool,
          {:take, athanor, execution_id, deadline},
          max(deadline - now(), 0) + @take_answer_ms
        )

  @doc """
  `take/4` asked without waiting for its answer: the request joins
  `requests` (`:gen_server.reqids_new/0`'s) under `label`, and its answer,
  as `take/4` answers, reaches the caller as a message
  `:gen_server.check_response/3` reads. The pool sends it after every
  event it told its assignee before it, so an assignee that asks reads
  every event of the runner's last work before the runner is its again.
  """
  @spec request_take(
          GenServer.server(),
          String.t(),
          String.t(),
          integer(),
          term(),
          :gen_server.request_id_collection()
        ) :: :gen_server.request_id_collection()
  def request_take(pool, athanor, execution_id, deadline, label, requests)
      when is_binary(athanor) and is_binary(execution_id) and is_integer(deadline),
      do:
        :gen_server.send_request(pool, {:take, athanor, execution_id, deadline}, label, requests)

  @doc """
  Taint the runner `pid` and end it, with `grace_ms` to report what it
  holds, while it runs the subtree of `execution_id`: a runner that has
  completed it, or been taken for another since, is left alone, so an ask
  read after the runner was handed out again never ends the new subtree.
  """
  @spec taint(GenServer.server(), pid(), non_neg_integer(), String.t()) :: :ok
  def taint(pool, pid, grace_ms, execution_id)
      when is_pid(pid) and is_integer(grace_ms) and grace_ms >= 0 and is_binary(execution_id),
      do: GenServer.call(pool, {:taint, pid, grace_ms, execution_id})

  @doc """
  Withdraw the take that waits on a runner's spawn for `execution_id`, if
  one does: it is answered `{:error, :killed}`, and the runner spawned for
  it, while it still waits for its place, has its handle ended, which
  drops the place from the keeper's queue; one already placed stays the
  pool's, spawned ahead.
  """
  @spec withdraw(GenServer.server(), String.t()) :: :ok
  def withdraw(pool, execution_id) when is_binary(execution_id),
    do: GenServer.call(pool, {:withdraw, execution_id})

  @doc "Send every busy runner a `cancel_child` for `execution_id`."
  @spec cancel_child(GenServer.server(), String.t()) :: :ok
  def cancel_child(pool, execution_id) when is_binary(execution_id),
    do: GenServer.call(pool, {:cancel_child, :busy, execution_id})

  @doc "Send the runner `pid`, if it is busy, a `cancel_child` for `execution_id`."
  @spec cancel_child(GenServer.server(), pid(), String.t()) :: :ok
  def cancel_child(pool, pid, execution_id) when is_pid(pid) and is_binary(execution_id),
    do: GenServer.call(pool, {:cancel_child, pid, execution_id})

  @doc """
  The pool's part of `t:Prima.WorkerAPI.status/0`: its runners counted by
  state, the memory bound the keeper last placed a runner with (nil
  before any, and from a keeper that applies none), and the keeper's
  refusal while it refuses runners.
  """
  @spec status(GenServer.server()) :: %{
          runners: %{
            fresh: non_neg_integer(),
            idle: non_neg_integer(),
            busy: non_neg_integer(),
            tainted: non_neg_integer()
          },
          memory_bytes: pos_integer() | nil,
          refusal: Prima.WorkerAPI.refusal() | nil
        }
  def status(pool), do: GenServer.call(pool, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       settings: Keyword.fetch!(opts, :settings),
       keeper: Keyword.fetch!(opts, :keeper),
       keeper_opts: Keyword.get(opts, :keeper_opts, []),
       memory_bytes: nil,
       supervisor: Keyword.fetch!(opts, :supervisor),
       command: Keyword.get_lazy(opts, :command, &Locus.Runtime.Release.runner_command/0),
       retire_bound_ms: Keyword.get(opts, :retire_bound_ms, @retire_bound_ms),
       uids: Keyword.get_lazy(opts, :uids, &role_uids/0),
       clock: Keyword.get(opts, :clock, &now/0),
       service: nil,
       assignee: nil,
       runners: %{},
       refill_scheduled: false,
       refusal: nil,
       backoff_ms: @refill_backoff_ms
     }}
  end

  @impl true
  def handle_call({:serve, service, assignee}, _from, state) do
    {:reply, :ok, refill(%{state | service: service, assignee: assignee})}
  end

  def handle_call({:take, _athanor, _execution_id, _deadline}, _from, %{service: nil} = state),
    do: {:reply, {:error, :not_serving}, state}

  def handle_call({:take, athanor, execution_id, deadline}, from, state) do
    take = %{from: from, athanor: athanor, execution_id: execution_id, deadline: deadline}
    {:noreply, take_for(state, take)}
  end

  def handle_call({:taint, pid, grace_ms, execution_id}, _from, state) do
    case state.runners[pid] do
      %{execution_id: ^execution_id} = entry ->
        {:reply, :ok, taint_runner(state, pid, entry, grace_ms)}

      _done_or_another ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:withdraw, execution_id}, _from, state) do
    waiting =
      Enum.find(state.runners, fn {_pid, e} ->
        e.waiter != nil and e.waiter.execution_id == execution_id
      end)

    case waiting do
      {pid, entry} ->
        state = answer(state, pid, entry, {:error, :killed})

        case state.runners[pid] do
          %{state: :spawning, placed: false} = entry ->
            {:reply, :ok, taint_runner(state, pid, entry, 0)}

          _placed_or_going ->
            {:reply, :ok, state}
        end

      nil ->
        {:reply, :ok, state}
    end
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
          :fresh ->
            Map.update!(counts, :fresh, &(&1 + 1))

          # A runner still spawning is counted fresh when a take could be
          # given it (`pick/2`): not while the keeper refuses runners, when
          # it is the pool's next try and no runner the pool holds.
          :spawning when state.refusal == nil ->
            Map.update!(counts, :fresh, &(&1 + 1))

          :spawning ->
            counts

          :idle ->
            Map.update!(counts, :idle, &(&1 + 1))

          :busy ->
            Map.update!(counts, :busy, &(&1 + 1))

          # Every runner held until the keeper releases it.
          held when held in [:tainted, :retiring, :refused] ->
            Map.update!(counts, :tainted, &(&1 + 1))
        end
      end)

    {:reply, %{runners: counts, memory_bytes: state.memory_bytes, refusal: state.refusal}, state}
  end

  @impl true
  def handle_info({RunnerProcess, pid, {:placed, memory_bytes}}, state) do
    case state.runners[pid] do
      nil ->
        {:noreply, state}

      entry ->
        state = put_runner(state, pid, %{entry | placed: true})
        {:noreply, %{state | memory_bytes: memory_bytes}}
    end
  end

  # The keeper's ask that a runner give way to a start waiting for room:
  # one still idle, or fresh with no take on it, is released as an idle
  # runner whose time ran out is; a busy, taken or ending one is left alone.
  # The keeper asks an idle runner to give way: one kept for its athanor
  # goes, and a fresh one only while another fresh one stays for the floor,
  # so an ask that comes after the floor's runner was taken ends nothing. A
  # runner taken, still spawning or already going is left as it is: the
  # keeper asks again at its next second if it is still short.
  def handle_info({RunnerProcess, pid, :give_way}, state) do
    case state.runners[pid] do
      %{state: :idle} = entry ->
        {:noreply, refill(retire_resting(state, pid, entry))}

      %{state: :fresh} = entry ->
        if Enum.count(state.runners, fn {_pid, e} -> e.state == :fresh end) >
             Prima.LocusPool.floor_runners(),
           do: {:noreply, refill(retire_resting(state, pid, entry))},
           else: {:noreply, state}

      _taken_spawning_or_ending ->
        {:noreply, state}
    end
  end

  def handle_info({RunnerProcess, pid, event}, state) do
    case state.runners[pid] do
      nil ->
        {:noreply, state}

      %{state: :spawning, waiter: waiter} = entry when waiter != nil ->
        {:noreply, waited(event, pid, entry, state)}

      entry ->
        {:noreply, on_event(event, pid, entry, state)}
    end
  end

  # A start that waits on its runner's spawn, or for the uid of a runner
  # going, its deadline passed first, is answered so; the runner stays the
  # pool's, spawned ahead, or going as it was.
  def handle_info({:take_due, pid}, state) do
    case state.runners[pid] do
      %{waiter: %{from: from}} = entry ->
        GenServer.reply(from, {:error, :past_deadline})
        {:noreply, put_runner(state, pid, %{entry | waiter: nil})}

      _answered ->
        {:noreply, state}
    end
  end

  # An idle runner's time is read on the pool's clock: a timer armed for an
  # earlier keeping of it, which ends before this one's, ends nothing.
  def handle_info({:idle_expired, pid}, state) do
    case state.runners[pid] do
      %{state: :idle, kept_at: kept_at} = entry ->
        if state.clock.() - kept_at >= state.settings.idle_ttl_ms,
          do: {:noreply, refill(retire_resting(state, pid, entry))},
          else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # A runner its keeper has not retired within its release's grace and the
  # bound is said so once and kept: only the keeper's report gives back
  # what it holds. A timer of a runner retired since, or of an earlier
  # release, names a ref no held entry carries, and is ignored.
  def handle_info({:retire_due, pid, ref}, state) do
    case state.runners[pid] do
      %{state: ending, retire_timer: ^ref} = entry when ending in [:tainted, :retiring] ->
        Logger.error(
          "[Locus.Runtime.RunnerPool] runner #{entry.id} was not retired by its keeper " <>
            "within the retirement bound; held until it is"
        )

        # Its timer has fired and is kept, so a later taint arms none.
        {:noreply, told(state, pid, entry, {:gone, :retire_bound})}

      _ ->
        {:noreply, state}
    end
  end

  # The keeper's word, to the runner's heir, that nothing of it is left.
  # A runner whose handle died leaves the pool on it; one whose handle
  # lives leaves on the handle's own `:released`, which follows, and the
  # word is kept for a handle that dies before it tells.
  def handle_info({_launcher, {:heir, {__MODULE__, id}}, :released}, state) do
    case Enum.find(state.runners, fn {_pid, entry} -> entry.id == id end) do
      nil -> {:noreply, state}
      {pid, %{down: true} = entry} -> {:noreply, released(state, pid, entry)}
      {pid, entry} -> {:noreply, put_runner(state, pid, %{entry | released: true})}
    end
  end

  # The one backoff timer the pool holds; one a release or an earlier
  # wait left behind does nothing.
  def handle_info({:refill, timer}, %{refill_scheduled: timer} = state),
    do: {:noreply, refill(%{state | refill_scheduled: false})}

  def handle_info({:refill, _stale}, state), do: {:noreply, state}

  # A handle that died leaves its runner to the keeper, which releases a
  # dead owner's spawn: the runner is held, tainted, until that release
  # reaches the pool as its heir. One refused after it was made keeps its
  # place among the runners ahead until then.
  def handle_info({:DOWN, _monitor, :process, pid, reason}, state) do
    case state.runners[pid] do
      nil ->
        {:noreply, state}

      # The start hears its runner's handle ended; why is the pool's own
      # log line's (`handle_down/4`). One that waits for the uid of a
      # runner already going waits on: the runner is held until its
      # release all the same.
      %{state: :spawning, waiter: waiter} = entry when waiter != nil ->
        state = answer(state, pid, entry, {:error, {:spawn_failed, :handle_down}})
        {:noreply, handle_down(state, pid, state.runners[pid], reason)}

      entry ->
        {:noreply, handle_down(state, pid, entry, reason)}
    end
  end

  # The keeper's account of a dead handle's runner: none of it was or will
  # be spawned, and it is forgotten, or its release reaches the pool as the
  # runner's heir. One the keeper did not answer stays held.
  def handle_info({:fenced, id, :none}, state) do
    case Enum.find(state.runners, fn {_pid, entry} -> entry.id == id end) do
      {pid, %{down: true} = entry} -> {:noreply, refill(resume(forget(state, pid), entry))}
      _held -> {:noreply, state}
    end
  end

  def handle_info({:fenced, _id, _pending_or_unanswered}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # What a runner reports
  # ---------------------------------------------------------------------------

  # The start a runner's spawn is waited on for hears that spawn's own
  # answer: the runner once it attached, or the keeper's refusal of it,
  # with the keeper's reason of that moment, or the failure that ended it
  # first. Then the event is the pool's as any runner's is.
  defp waited(:ready, pid, %{waiter: waiter} = entry, state) do
    Process.cancel_timer(waiter.timer)
    GenServer.reply(waiter.from, {:ok, pid, entry.id})

    entry = %{
      entry
      | state: :busy,
        athanor: waiter.athanor,
        execution_id: waiter.execution_id,
        waiter: nil
    }

    state |> put_runner(pid, entry) |> started()
  end

  defp waited({:refused, reason} = event, pid, entry, state),
    do: on_event(event, pid, entry, answer(state, pid, entry, refused_take(state, reason)))

  defp waited({:refused, reason, :release_follows} = event, pid, entry, state),
    do: on_event(event, pid, entry, answer(state, pid, entry, refused_take(state, reason)))

  defp waited(event, pid, entry, state),
    do: on_event(event, pid, entry, answer(state, pid, entry, {:error, {:spawn_failed, event}}))

  # The keeper's refusal of the start's own runner, never one remembered.
  defp refused_take(state, reason), do: {:error, {:refused, state.keeper.refusal(reason)}}

  defp answer(state, pid, %{waiter: waiter} = entry, reply) do
    Process.cancel_timer(waiter.timer)
    GenServer.reply(waiter.from, reply)
    put_runner(state, pid, %{entry | waiter: nil})
  end

  defp on_event(:ready, pid, %{state: :spawning} = entry, state),
    do: state |> put_runner(pid, %{entry | state: :fresh}) |> started()

  defp on_event(:ready, _pid, _entry, state), do: started(state)

  # No process of the runner ran: one the keeper made nothing of leaves the
  # pool at once, with nothing for the keeper to retire; one it made is the
  # keeper's until its release, and keeps its place among the runners
  # ahead until then. The pool refuses until one starts.
  # A spawn whose answer never came may still have been written: its
  # handle is stopped, and the runner held as a dead handle's is.
  defp on_event({:refused, {:keeper_unavailable, :timeout} = reason}, pid, entry, state) do
    state = told(state, pid, entry, {:gone, {:refused, state.keeper.refusal(reason)}})
    _ = DynamicSupervisor.terminate_child(state.supervisor, pid)
    refused(state, reason)
  end

  # A place the keeper refused for room after a take's wait for it is that
  # take's alone: the keeper still starts runners, so the pool neither
  # refuses nor backs off for it, and fills again at its usual pace. One
  # nobody took is the keeper refusing the floor itself (no empty pool
  # could hold a runner), which the pool remembers and backs off.
  defp on_event({:refused, reason}, pid, entry, state) do
    refusal = state.keeper.refusal(reason)
    state = told(state, pid, entry, {:gone, {:refused, refusal}})
    _ = DynamicSupervisor.terminate_child(state.supervisor, pid)
    taken? = entry.execution_id != nil or entry.waiter != nil

    if refusal.reason == "no_memory" and taken?,
      do: refill_later(forget(state, pid)),
      else: refused(forget(state, pid), reason)
  end

  defp on_event({:refused, reason, :release_follows}, pid, entry, state) do
    state = told(state, pid, entry, {:gone, {:refused, state.keeper.refusal(reason)}})
    refused(put_runner(state, pid, %{state.runners[pid] | state: :refused}), reason)
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
        Process.send_after(self(), {:idle_expired, pid}, state.settings.idle_ttl_ms)
        put_runner(state, pid, %{entry | state: :idle, kept_at: state.clock.()})

      true ->
        taint_runner(state, pid, entry, 0)
    end
  end

  # A clean completion whose place its keeper did not make warm again: the
  # completion is heard as it was, and the runner ends in the same move,
  # never offered.
  defp on_event({:message, %{type: :complete} = message, {:error, reason}}, pid, entry, state) do
    Logger.warning("[Locus.Runtime.RunnerPool] runner #{entry.id}: #{inspect(reason)}")
    state = told(state, pid, entry, {:complete, message.execution_id, message.clean})
    gone(state, pid, state.runners[pid], reason)
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
    taint_runner(state, pid, state.runners[pid], 0)
  end

  defp on_event({:message, message}, pid, entry, state) do
    Logger.warning(
      "[Locus.Runtime.RunnerPool] runner #{entry.id} sent #{message.type} while #{entry.state}"
    )

    gone(state, pid, entry, {:protocol, message.type})
  end

  defp on_event(:closed, pid, entry, state), do: gone(state, pid, entry, :closed)
  defp on_event({:exited, how}, pid, entry, state), do: gone(state, pid, entry, {:exited, how})

  defp on_event({:error, reason}, pid, entry, state) do
    Logger.warning("[Locus.Runtime.RunnerPool] runner #{entry.id}: #{inspect(reason)}")
    gone(state, pid, entry, reason)
  end

  defp on_event(:released, pid, entry, state) do
    _ = DynamicSupervisor.terminate_child(state.supervisor, pid)
    released(state, pid, entry)
  end

  defp handle_down(state, pid, %{released: true} = entry, _reason),
    do: released(state, pid, entry)

  defp handle_down(state, pid, entry, reason) do
    # A runner tainted before it was placed had its handle ended by the
    # pool itself (`taint_runner/4`), which is no failure.
    unless entry.state == :tainted and not entry.placed do
      Logger.error(
        "[Locus.Runtime.RunnerPool] runner #{entry.id}'s handle ended " <>
          "(#{Prima.LogFilter.inspect_reason(reason)}); held until its keeper retires it"
      )
    end

    state = told(state, pid, entry, {:gone, {:handle_down, reason}})
    entry = %{state.runners[pid] | down: true, kept_at: nil}
    entry = if entry.state == :refused, do: entry, else: %{entry | state: :tainted}
    fence(state, entry.id)
    refill_later(put_runner(state, pid, entry))
  end

  # The keeper released the runner, freeing its uid: a start that waited
  # for that uid is taken again before the pool fills. A refusal the pool
  # remembers may have lacked it, so the refusal ends and the pool fills at
  # once. The release of a runner the keeper refused after making it frees
  # only what its own refusal held, and the refusal stands.
  defp released(state, pid, entry) do
    state = forget(state, pid)

    state =
      if state.refusal != nil and entry.state != :refused do
        Logger.info("[Locus.Runtime.RunnerPool] a runner's release ends the keeper's refusal")
        %{state | refusal: nil, backoff_ms: @refill_backoff_ms, refill_scheduled: false}
      else
        state
      end

    state |> resume(entry) |> refill()
  end

  # The runner is no longer usable: what it was running is gone, and the
  # keeper is asked to end whatever is left of it.
  defp gone(state, pid, entry, reason) do
    state = told(state, pid, entry, {:gone, reason})
    entry = state.runners[pid]

    case entry.state do
      ending when ending in [:retiring, :tainted, :refused] -> state
      _ -> taint_runner(state, pid, entry, 0)
    end
  end

  defp refused(state, reason) do
    refusal = state.keeper.refusal(reason)

    if state.refusal == nil,
      do:
        Logger.error(
          "[Locus.Runtime.RunnerPool] the keeper refuses runners (#{refusal.reason}); " <>
            "trying one again from #{state.backoff_ms} ms, backing off"
        )

    back_off(%{state | refusal: refusal})
  end

  # An assignment is told of once: the first of its complete, its exit or
  # the runner's end ends it for the assignee.
  defp told(state, _pid, %{execution_id: nil}, _event), do: state

  defp told(state, pid, entry, event) do
    tell(state, pid, event)
    put_runner(state, pid, %{entry | execution_id: nil})
  end

  # An idle timer left running is harmless: a runner no longer idle, or
  # kept again since, is not yet due by the clock and ignores it.
  # A runner already released keeps the retirement timer its first release
  # armed: its handle releases it once, so a later taint asks the keeper
  # for nothing and must not put its deadline off. One refused after it was
  # made is the keeper's to free, and waits for that with no deadline.
  defp taint_runner(state, _pid, %{state: ending}, _grace_ms) when ending in [:tainted, :refused],
    do: state

  # A runner whose process still waits for its place reads no release
  # until the keeper answers, and holds its turn in the keeper's queue
  # meanwhile: its handle, the place's owner, is ended, so the keeper's
  # client drops the place at once, and the runner is held as a dead
  # handle's is (`handle_down/4`), with no retirement bound.
  defp taint_runner(state, pid, %{placed: false} = entry, _grace_ms) do
    Process.exit(pid, :kill)
    refill_later(put_runner(state, pid, %{entry | state: :tainted, kept_at: nil}))
  end

  defp taint_runner(state, pid, entry, grace_ms) do
    RunnerProcess.release(pid, grace_ms)
    timer = entry.retire_timer || retire_due(state, pid, grace_ms)

    refill_later(
      put_runner(state, pid, %{entry | state: :tainted, kept_at: nil, retire_timer: timer})
    )
  end

  # A runner at rest, which holds no work, released at once and held until
  # the keeper retires it.
  defp retire_resting(state, pid, entry) do
    RunnerProcess.release(pid, 0)

    put_runner(state, pid, %{
      entry
      | state: :retiring,
        kept_at: nil,
        retire_timer: retire_due(state, pid, 0)
    })
  end

  # The deadline of a release: its grace, then the bound for the keeper to
  # report the runner retired.
  defp retire_due(state, pid, grace_ms) do
    ref = make_ref()
    Process.send_after(self(), {:retire_due, pid, ref}, grace_ms + state.retire_bound_ms)
    ref
  end

  defp tell(%{assignee: assignee}, pid, event) when is_pid(assignee),
    do: send(assignee, {__MODULE__, pid, event})

  defp tell(_state, _pid, _event), do: :ok

  # ---------------------------------------------------------------------------
  # Picking and spawning
  # ---------------------------------------------------------------------------

  # A take, from its call or again once the uid it waited for is free: an
  # idle runner of its athanor or a fresh one; otherwise a spawn, on a uid
  # free, or once one is: it waits for the uid of a runner already going,
  # or of the oldest kept runner, which gives way for it. With every uid
  # held by runners at work it spawns all the same, and the keeper's
  # refusal for want of a uid answers it.
  defp take_for(state, take) do
    case pick(state, take.athanor) do
      {:ok, pid, entry} ->
        entry = %{
          entry
          | state: :busy,
            athanor: take.athanor,
            execution_id: take.execution_id,
            kept_at: nil
        }

        GenServer.reply(take.from, {:ok, pid, entry.id})
        refill(put_runner(state, pid, entry))

      :none ->
        case uid_for(state) do
          {:wait, pid, state} ->
            put_runner(state, pid, %{state.runners[pid] | waiter: waiter(take, pid)})

          _free_or_none ->
            spawn_for(state, take)
        end
    end
  end

  defp spawn_for(state, take) do
    case spawn_runner(state) do
      {:ok, pid, entry} when state.refusal != nil ->
        refill(put_runner(state, pid, %{entry | waiter: waiter(take, pid)}))

      {:ok, pid, entry} ->
        entry = %{entry | state: :busy, athanor: take.athanor, execution_id: take.execution_id}
        GenServer.reply(take.from, {:ok, pid, entry.id})
        refill(put_runner(state, pid, entry))

      {:error, reason} ->
        GenServer.reply(take.from, {:error, reason})
        state
    end
  end

  # A take's wait on the runner `pid`, by its own deadline.
  defp waiter(take, pid) do
    Map.put(
      take,
      :timer,
      Process.send_after(self(), {:take_due, pid}, max(take.deadline - now(), 0))
    )
  end

  # A start that waited for the uid of a runner now gone is taken again.
  defp resume(state, %{waiter: nil}), do: state

  defp resume(state, %{waiter: waiter}) do
    Process.cancel_timer(waiter.timer)
    take_for(state, Map.delete(waiter, :timer))
  end

  # Where a spawn's uid comes from: one free, or that of a runner going
  # that no start waits on yet, or of the oldest kept runner, released for
  # it; or none, every uid held by a runner at work, fresh or waited on.
  # Every runner the pool holds holds a uid of its role, or will once it
  # spawns, until the keeper reports it released.
  defp uid_for(state) do
    if map_size(state.runners) < state.uids do
      :free
    else
      case Enum.find(state.runners, fn {_pid, e} -> going?(e) and e.waiter == nil end) do
        {pid, _entry} ->
          {:wait, pid, state}

        nil ->
          case oldest_kept(state) do
            {pid, entry} -> {:wait, pid, retire_resting(state, pid, entry)}
            nil -> :none
          end
      end
    end
  end

  defp going?(entry), do: entry.state in [:retiring, :tainted, :refused]

  defp oldest_kept(state) do
    state.runners
    |> Enum.filter(fn {_pid, e} -> e.state == :idle end)
    |> Enum.min_by(fn {_pid, e} -> e.kept_at end, fn -> nil end)
  end

  # Kept runners give way, oldest first, for the uids `short` spawns lack
  # beyond those that runners already going, and waited on by no start,
  # will free.
  defp make_way(state, short) do
    coming = Enum.count(state.runners, fn {_pid, e} -> going?(e) and e.waiter == nil end)

    Enum.reduce_while(1..max(short - coming, 0)//1, state, fn _n, state ->
      case oldest_kept(state) do
        {pid, entry} -> {:cont, retire_resting(state, pid, entry)}
        nil -> {:halt, state}
      end
    end)
  end

  # The uids of the role whose runners the pool spawns, as the keeper's
  # `--pool` names them (`Prima.LocusRoles`).
  defp role_uids, do: Enum.count(Prima.LocusRoles.role!(:runtime).uids)

  # An idle runner of the athanor, then a fresh one (attached or still
  # spawning, since an assign waits for the channel, unless the keeper
  # refuses runners and the one spawning is likely refused too).
  defp pick(state, athanor) do
    idle = Enum.find(state.runners, fn {_pid, e} -> e.state == :idle and e.athanor == athanor end)

    fresh =
      idle ||
        Enum.find(state.runners, fn {_pid, e} -> e.state == :fresh end) ||
        (state.refusal == nil &&
           Enum.find(state.runners, fn {_pid, e} -> e.state == :spawning and e.waiter == nil end))

    case fresh do
      {pid, entry} -> {:ok, pid, entry}
      _none -> :none
    end
  end

  defp forget(state, pid), do: %{state | runners: Map.delete(state.runners, pid)}

  # Asked of the keeper in a process of its own, so the pool never waits
  # on it; the answer comes as `{:fenced, id, answer}`.
  defp fence(state, id) do
    pool = self()
    %{keeper: keeper, keeper_opts: opts} = state

    {:ok, _asker} =
      Task.start(fn -> send(pool, {:fenced, id, keeper.fence({__MODULE__, id}, opts)}) end)

    :ok
  end

  defp spawn_runner(%{service: service} = state) do
    id = Prima.UUID7.generate_id("runner")

    env =
      Map.merge(
        state.command.env,
        Locus.Runtime.Settings.runner_environment(%{
          runner_id: id,
          service_id: service.service_id,
          boot: service.boot,
          watchdog_grace_ms: state.settings.watchdog_grace_ms
        })
      )

    spec = %{runner: id, argv: state.command.argv, env: env, heir: {self(), {__MODULE__, id}}}

    case DynamicSupervisor.start_child(
           state.supervisor,
           {RunnerProcess,
            id: id,
            keeper: state.keeper,
            keeper_opts: state.keeper_opts,
            spec: spec,
            owner: self()}
         ) do
      {:ok, pid} ->
        Process.monitor(pid)

        {:ok, pid,
         %{
           id: id,
           state: :spawning,
           athanor: nil,
           execution_id: nil,
           # When it was last kept idle, on the pool's clock; nil unless idle.
           kept_at: nil,
           retire_timer: nil,
           # Its handle died, and the keeper's release reaches the pool as
           # the runner's heir.
           down: false,
           # The keeper's release reached the pool as the runner's heir.
           released: false,
           # The start that waits on this runner: on its spawn while it
           # spawns (the pool remembers a refusal), for its uid while it goes.
           waiter: nil,
           # The keeper placed it: its process no longer waits for room.
           placed: false
         }}

      {:error, reason} ->
        Logger.error(
          "[Locus.Runtime.RunnerPool] a runner could not be started: #{inspect(reason)}"
        )

        {:error, {:spawn_failed, reason}}
    end
  end

  defp refill(%{service: nil} = state), do: state

  # While the keeper refuses runners, one is spawned at a time, when the
  # wait since the last refusal is over, to learn whether it starts them
  # again.
  defp refill(%{refusal: refusal, refill_scheduled: timer} = state)
       when refusal != nil and timer != false,
       do: state

  # A runner refused after it was made holds its uid and place at the
  # keeper until its release, so it counts among the runners ahead. A
  # spawn no uid is free for waits for one: kept runners give way for it,
  # and the pool fills at their release.
  defp refill(state) do
    ahead =
      Enum.count(state.runners, fn {_pid, e} -> e.state in [:fresh, :spawning, :refused] end)

    wanted = max(target(state) - ahead, 0)
    free = max(state.uids - map_size(state.runners), 0)
    state = make_way(state, wanted - free)

    Enum.reduce_while(1..min(wanted, free)//1, state, fn _n, state ->
      case spawn_runner(state) do
        {:ok, pid, entry} -> {:cont, put_runner(state, pid, entry)}
        {:error, _reason} -> {:halt, refill_later(state)}
      end
    end)
  end

  defp target(%{refusal: nil}), do: Prima.LocusPool.floor_runners()
  defp target(_refusing), do: 1

  defp refill_later(state, delay_ms \\ @refill_backoff_ms)

  defp refill_later(%{refill_scheduled: timer} = state, _delay_ms) when timer != false,
    do: state

  defp refill_later(state, delay_ms) do
    timer = make_ref()
    Process.send_after(self(), {:refill, timer}, delay_ms)
    %{state | refill_scheduled: timer}
  end

  # The next try after a refusal waits twice as long as the last, up to
  # the most; a refusal that arrives while one is already scheduled (the
  # rest of a fill) waits for it.
  defp back_off(%{refill_scheduled: timer} = state) when timer != false, do: state

  defp back_off(state) do
    state
    |> refill_later(state.backoff_ms)
    |> Map.put(:backoff_ms, min(state.backoff_ms * 2, @max_backoff_ms))
  end

  # A runner attached: the keeper starts runners, and the pool fills.
  defp started(%{refusal: nil} = state), do: state

  defp started(state) do
    Logger.info("[Locus.Runtime.RunnerPool] the keeper starts runners again")
    refill(%{state | refusal: nil, backoff_ms: @refill_backoff_ms})
  end

  defp put_runner(state, pid, entry), do: %{state | runners: Map.put(state.runners, pid, entry)}

  defp take_wait_ms, do: Locus.Launcher.place_wait_ms() + @spawn_wait_ms

  defp now, do: System.monotonic_time(:millisecond)
end
