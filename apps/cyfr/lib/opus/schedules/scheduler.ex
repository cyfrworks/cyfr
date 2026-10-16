# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Schedules.Scheduler do
  @moduledoc """
  The scheduler of recurring component executions: a timer per active
  schedule (`Process.send_after/3`), each firing claiming one occurrence
  and running it as a root (`Opus.run_root/5`).

  Each occurrence fires at most once across the cell:
  `Arca.ScheduleOccurrences.claim/3` advances the schedule's cursor and
  inserts the occurrence row in one transaction, on the cell's clock, and
  the loser is told `:held`. The occurrence is claimed for this BOOT, so
  it is held while this member is live and recoverable once it is not.

  The occurrence row is then the run's record — `started` by the
  execution's own admission (`Arca.Execution.admit/2` moves it inside
  the transaction that admits the row), `completed` or `failed` when the
  run answers, `uncertain` when the runner died with a started
  execution. A schedule's `concurrency` decides overlap: `forbid` leaves
  a due occurrence unclaimed while another is open and checks again
  shortly; `allow` claims it regardless.

  A scheduler recovers what a member that is no longer live left, and
  never a peer's work in hand: `Arca.ScheduleOccurrences.recoverable/1`
  answers only the occurrences whose claimant has dropped out of the
  cell's roster or that were claimed more than two ticks ago, and the
  re-run is admitted by a compare-and-set on the occurrence, so two
  recoverers produce one re-run. An occurrence claimed and never invoked
  runs once, a started one whose execution ended or was swept while the
  occurrence stayed open is `uncertain`.

  A due time the cell missed is handled by the schedule's declared
  `missed_runs`. A due time is missed when, at claim, it is older than the
  missed bound (`missed_bound_ms/0`): the larger of this scheduler's
  jitter (at most 30 s) and the member's slot lease, with a few seconds
  for the timer's delivery, so a timer that
  fires a few seconds late, or a successor that takes over a lapsed slot,
  fires an ordinary occurrence under either policy. Under `skip`, the
  default, a missed time does not fire and the cursor moves on to the
  first time not missed. Under `catch_up` a missed time opens an episode
  that fires at most `catch_up_limit` (1 to `max_catch_up/0`) of the
  missed times, one per claim, oldest first, and then resumes after them;
  the episode is kept on the schedule's row, so a restart or a takeover
  resumes it (`Arca.ScheduleOccurrences.claim/3`). Each fired time is its
  own occurrence, at most once per `(schedule_id, scheduled_for)`.
  Missed has this one meaning whatever kept the time from its claim:
  downtime, a `forbid` schedule held back past the bound by a run that
  overran, or retries after store errors, since why a time waited is not
  kept and a restart during the wait would read as downtime anyway.

  Every write this scheduler makes is gated twice: on the member holding
  its cell slot (`Arca.ControlPlane.held?/0`) and on the generation it
  captured when the work began. A member taken over raises its successor's
  generation, so a task that outlived the take-over stops where it stands
  instead of writing after the successor has begun.

  Those gates read the cached standing, and are the fast path only. The
  writes that take or end an occurrence check for themselves, in their
  own statements: the claim and the run's admission verify the member's
  slot on the database (`:not_owner` otherwise), and an occurrence is
  ended only by a compare-and-set on its claimant and the execution this
  member minted for the run before it spawned it (`:stale` otherwise).

    * A claim refused `:not_owner` wrote nothing and opened no decision:
      the schedule is deferred and looked at again later, and recovery
      is armed.
    * An admission refused `:not_owner`, or `:control_plane_lost` by the
      fast path before it, leaves the claimed occurrence to recovery:
      only the decision this member opened is closed, with the refusal,
      and nothing else is written and no error recorded.
    * An end answered `:stale` found the occurrence another member's: the
      decision this member opened is still closed with the run's answer,
      and nothing else is written, recorded, published or announced.

  An occurrence left to recovery is reached by a recovery pass, even when
  the member that left it is still live. Every task that leaves one (an
  admission refused for the slot, a feed's seq claim or result refused
  `:not_owner`, a task that finds its cached standing gone before it
  starts the run, writes its answer or ends a refused seq, or one whose
  own end of the occurrence did not happen) ends with
  `{:shutdown, :left_to_recovery}`, whatever the standing reads by the
  time the scheduler sees the exit. The task is monitored before it runs
  (`Task.Supervisor.async_nolink/3`), so that reason reaches the
  scheduler; an exit whose reason never did (`:noproc`) is taken for it.
  The scheduler then asks for a pass
  due two ticks and a second after the exit: by then the claim is older
  than the two ticks (`abandoned_before/0`) that make it any member's to
  recover. A task that ends after this member lost its generation asks
  for the same, and so does a dead runner whose occurrence its
  settlement did not end. The scheduler asks for the same pass wherever
  it leaves open, itself, an occurrence it has just claimed or re-taken:
  a run not started because the standing ran out or the task could not
  be spawned, a re-taken occurrence it did not end, a claim or a take
  answered by a store error that may have committed, and a fire or a
  recovery pass cut short by a store error. A scheduler process that
  dies is started again in the same boot, with the runs it left still in
  flight under the task supervisor: the new process watches each of them
  and asks for the pass when one ends, and at its start asks for one
  pass two ticks and a second away, which reaches a claim committed just
  before the death whose run never started. Those requests are the fast
  path: while this member holds its slot, a standing pass runs every two
  ticks and a second whatever was asked, so an occurrence left by a path
  no request names is reached all the same, and a member that does not
  hold its slot runs none. A pass reads the open occurrences through their `(state,
  claimed_at)` index, never their history, and skips only an occurrence
  a run of this process holds in flight; runs are kept by their monitor,
  so a second run of an `allow` schedule never displaces the first. A
  live member's started occurrence whose execution ended, or whose
  execution row is gone, is ended only once the pass's own process has
  seen it so for two ticks on its monotonic clock: a run's own task has at
  least those two ticks after its execution closes to end its occurrence,
  on this member's pass or a peer's, and no member's wall clock enters the
  decision; a task slower than that loses its end to recovery as
  `uncertain`. One whose claimant is no live member is ended as soon as
  its execution has. That includes a task whose lease lapsed with no
  successor before it ended its occurrence: a peer's pass may end it first,
  and the task's own end then answers `:stale`, the stale owner's window,
  accepted. A `forbid` schedule's fire
  that answers `:overlapping` asks for a pass a tick away, so an
  occurrence that holds it back is reached once it is old enough. One
  timer serves every request: the earliest due is armed, the latest is
  kept (`recovery_due`), and the pass that fires re-arms for it while it
  is still ahead. A pass that comes early finds nothing yet, and re-runs
  an occurrence only through `recover/4`'s compare-and-set and the
  fences of the claim and the admission.

  Each fire is one admission decision (`Sanctum.Decisions.open/3`, tool
  `schedule`, action `fire`), recorded before the run under a call id the
  run's context carries, so the root execution's row names it, and
  completed with the run's answer (`Sanctum.Decisions.close/3`). A fire
  whose member lost its generation between the run and its answer records
  no completion — a stale owner emits no result — and neither does one
  whose runner task died: its decision reads as unknown.

  A completed occurrence's outcome is recorded in the outbox in the
  transaction that closes it (`complete/4`, `Prima.OutboxRecord`), the
  durable fact `Aqua.ScheduleNotes` keeps a note from. It is then
  announced on `Cyfr.Bus.schedule_completions/0`
  (`Cyfr.Bus.ScheduleCompleted`) once: only when closing it moved the
  occurrence row, the schedule's run was recorded, and the generation still
  holds when checked again just before the publish. The announcement only
  wakes the consumer; a lost one loses nothing. The row's stored metadata
  says whether the outcome is kept (`keep_outcome/1`).

  A row of kind `feed` (`Opus.Feeds`) fires through the same claim,
  decision, run, profile and options as a schedule, its first occurrence
  included, and its claim is refused `:not_owner` and deferred as a
  schedule's is. Its run task first claims the feed's next seq
  (`Arca.CronSchedule.claim_feed_seq/2`) under the member slot it reads
  then; a refused claim opens no decision and runs nothing. On the run's
  answer the output is accepted under that seq and slot
  (`Opus.Feeds.accept/5`) before the occurrence finishes: accepted,
  stale or removed completes it, and a refused output (not a 2xx envelope,
  or data outside its shape) fails it with the refusal's reason, path and
  any status as its error. A feed announces no completion and no schedule
  update. An accepted result is published on the athanor's feeds topic
  (`Cyfr.Bus.feeds/1`) from the envelope its committed accept answered; a
  stale, refused or failed accept publishes nothing.
  """

  use GenServer
  require Logger
  require Arca.Repo.Errors

  alias Arca.{CronSchedule, ScheduleOccurrences}
  alias Cyfr.Bus.{FeedPublished, ScheduleCompleted, Schedules}
  alias Opus.Schedules.Cron

  @db_load_errors Arca.Repo.Errors.db_errors() ++ [DBConnection.OwnershipError, RuntimeError]
  @db_fire_errors Arca.Repo.Errors.db_errors() ++ [DBConnection.OwnershipError]
  @db_timer_errors Arca.Repo.Errors.db_errors() ++ [DBConnection.OwnershipError, ArgumentError]

  @max_timer_ms 60 * 60 * 1_000
  @max_load_retries 5
  @recheck_ms 30_000
  # The most a timer is pushed past its due time (`jitter_ms/1`).
  @max_jitter_ms 30_000
  # What a fully jittered timer may still arrive past its jitter: the
  # message's own delivery, and a member clock behind the cell's by a few
  # seconds, since the timer is armed on the member's clock and the claim
  # decides on the cell's.
  @missed_slack_ms 5_000
  # The most missed times one catch-up episode fires; the CHECK on
  # `cron_schedules.catch_up_limit` holds the same number on each adapter.
  @max_catch_up 24
  # Two ticks: the grace a live member's lapsed run is given, and the age at
  # which a claim is any member's to recover (`abandoned_before/0`). The
  # standing pass comes a second later than this (`arm_standing/1`).
  @standing_ms 2 * @recheck_ms

  def start_link(opts \\ []) do
    # Long-lived, querying on boot and on timers: under the test sandbox
    # it would keep a lent connection past its owner's exit, so its own
    # suite starts it explicitly and nothing else runs it there.
    if Application.get_env(:cyfr, :cron_scheduler_enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  def add(schedule_id), do: GenServer.cast(__MODULE__, {:add, schedule_id})
  def remove(schedule_id), do: GenServer.cast(__MODULE__, {:remove, schedule_id})
  def pause(schedule_id), do: GenServer.cast(__MODULE__, {:pause, schedule_id})
  def resume(schedule_id), do: GenServer.cast(__MODULE__, {:resume, schedule_id})
  def update(schedule_id), do: GenServer.cast(__MODULE__, {:update, schedule_id})
  def reload, do: GenServer.cast(__MODULE__, :reload)

  @doc "The most missed times a `catch_up` schedule's episode fires (its `catch_up_limit` ceiling)."
  @spec max_catch_up() :: pos_integer()
  def max_catch_up, do: @max_catch_up

  @doc """
  How late a due time may be claimed and still fire as an ordinary
  occurrence: the larger of the jitter a timer adds (`jitter_ms/1`, at
  most 30 s) and the member's slot lease (`Cyfr.Cell.lease_ms/0`), with
  5 s more for a fully jittered timer's own delivery and a member clock
  slightly behind the cell's. A due time older than this at claim was
  missed, and its schedule's `missed_runs` decides it.
  """
  @spec missed_bound_ms() :: pos_integer()
  def missed_bound_ms, do: max(@max_jitter_ms, Cyfr.Cell.lease_ms()) + @missed_slack_ms

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       timers: %{},
       tasks: %{},
       orphans: MapSet.new(),
       load_retry_count: 0,
       recovery_ref: nil,
       recovery_due: nil,
       standing_ref: nil,
       lapsed_seen: %{}
     }, {:continue, :load_schedules}}
  end

  @impl true
  # A start after this process died within the same boot finds the runs
  # its predecessor left in flight, and may follow a claim committed just
  # before the death whose task never started: the surviving runs are
  # watched, and one two-tick pass is asked for beside the pass run now,
  # which finds this boot's young claims not yet abandoned.
  def handle_continue(:load_schedules, state) do
    {:noreply,
     state
     |> adopt_runs()
     |> left_open()
     |> arm_standing()
     |> load_all_schedules()
     |> recover_if_held()}
  end

  @impl true
  def handle_cast({:add, schedule_id}, state), do: {:noreply, schedule_timer(schedule_id, state)}

  def handle_cast({:update, schedule_id}, state),
    do: {:noreply, schedule_timer(schedule_id, state)}

  def handle_cast({:resume, schedule_id}, state),
    do: {:noreply, schedule_timer(schedule_id, state)}

  def handle_cast({:remove, schedule_id}, state), do: {:noreply, cancel_timer(schedule_id, state)}
  def handle_cast({:pause, schedule_id}, state), do: {:noreply, cancel_timer(schedule_id, state)}

  def handle_cast(:reload, state) do
    {:noreply, state |> cancel_all_timers() |> load_all_schedules()}
  end

  @impl true
  # A member that does not hold its cell slot claims no occurrence: the
  # schedule is asked again at the recheck.
  def handle_info({:fire, schedule_id}, state) do
    state = %{state | timers: Map.delete(state.timers, schedule_id)}

    if Arca.ControlPlane.held?(),
      do: {:noreply, fire_schedule(schedule_id, state)},
      else: {:noreply, recheck_later(schedule_id, state)}
  end

  # A pass runs, and the one timer is armed again for the latest due a
  # request recorded while it is still ahead.
  def handle_info(:recover_occurrences, state) do
    if state.recovery_ref, do: Process.cancel_timer(state.recovery_ref)
    {:noreply, state |> rearm_recovery() |> recover_if_held()}
  end

  # The standing pass: every two ticks and a second, while this member holds its slot,
  # whatever any exit asked for. A member that does not hold it runs
  # nothing, and looks again at the next.
  def handle_info(:standing_pass, state) do
    state = arm_standing(state)
    generation = Arca.ControlPlane.generation()

    if still_ours?(generation),
      do: {:noreply, recover_occurrences(state, generation)},
      else: {:noreply, state}
  end

  def handle_info({:recheck, schedule_id}, state) do
    state = %{state | timers: Map.delete(state.timers, schedule_id)}

    if Arca.ControlPlane.held?(),
      do: {:noreply, schedule_timer(schedule_id, state)},
      else: {:noreply, recheck_later(schedule_id, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: {:noreply, run_ended(ref, reason, state)}

  # A run's task answers its alias when its function returns (it was
  # started by `Task.Supervisor.async_nolink/3`); it has ended normally,
  # and its monitor goes with the answer.
  def handle_info({ref, _answer}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, run_ended(ref, :normal, state)}
  end

  def handle_info(:retry_load, state) do
    if state.load_retry_count >= @max_load_retries do
      Logger.error(
        "[Opus.Schedules.Scheduler] max retries (#{@max_load_retries}) exhausted loading schedules — retrying in 5 minutes"
      )

      :telemetry.execute([:cyfr, :schedules, :scheduler, :load_failed], %{count: 1}, %{
        retries: state.load_retry_count
      })

      Process.send_after(self(), :retry_load, 300_000)
      {:noreply, state}
    else
      {:noreply, load_all_schedules(state)}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.timers, fn {_id, ref} -> Process.cancel_timer(ref) end)
    if state.recovery_ref, do: Process.cancel_timer(state.recovery_ref)
    if state.standing_ref, do: Process.cancel_timer(state.standing_ref)

    if map_size(state.tasks) > 0 do
      ids =
        state.tasks
        |> Map.values()
        |> Enum.map(& &1.schedule_id)
        |> Enum.uniq()
        |> Enum.join(", ")

      Logger.info("[Opus.Schedules.Scheduler] shutting down with running schedules: #{ids}")
    end

    :ok
  end

  # A run's end, by its monitor or its answer. A run this process started
  # is settled as its reason says; one a predecessor of this process left
  # in flight (`adopt_runs/1`) is not known here, so whatever it left is
  # reached by the two-tick pass, and so is any other run not known here
  # that ends left to recovery.
  defp run_ended(ref, reason, state) do
    case Map.pop(state.tasks, ref) do
      {%{schedule_id: schedule_id} = task, tasks} ->
        state = %{state | tasks: tasks}

        if still_ours?(task.generation) do
          # A dead runner whose occurrence its settlement did not end
          # leaves it open.
          state =
            if failed_run?(reason),
              do: left_open_unless_ended(state, runner_died(schedule_id, task, reason)),
              else: state

          unless task.feed?, do: broadcast_update(task.ctx, schedule_id)

          # A run left to recovery asks for the pass that reaches it.
          state = if left_to_recovery?(reason), do: left_open(state), else: state

          schedule_timer(schedule_id, state)
        else
          # The generation was lost under the run: whatever it left is
          # reached by the same pass.
          defer_occurrence(schedule_id, left_open(state))
        end

      {nil, _tasks} ->
        cond do
          MapSet.member?(state.orphans, ref) ->
            left_open(%{state | orphans: MapSet.delete(state.orphans, ref)})

          left_to_recovery?(reason) ->
            left_open(state)

          true ->
            state
        end
    end
  end

  # A task exit that is not the run failing: the scheduler is going down,
  # the run left its occurrence to recovery, or its reason was lost
  # (`:noproc`).
  @doc false
  @spec failed_run?(term()) :: boolean()
  def failed_run?(:normal), do: false
  def failed_run?(:noproc), do: false
  def failed_run?(:shutdown), do: false
  def failed_run?({:shutdown, _}), do: false
  def failed_run?(_reason), do: true

  # The exits that leave the run's occurrence open for recovery to reach:
  # the run's own word for it, and an exit whose reason never reached this
  # process (`:noproc`, a run already gone when its monitor was placed),
  # which may have been that word.
  defp left_to_recovery?({:shutdown, :left_to_recovery}), do: true
  defp left_to_recovery?(:noproc), do: true
  defp left_to_recovery?(_reason), do: false

  # The runs a predecessor of this process left in flight under the task
  # supervisor, which outlives it: each is watched, and its end asks for
  # the two-tick pass (`run_ended/3`). They are read from the supervisor's
  # links, every child of a supervisor being linked to it, rather than
  # asked of it: a start never waits on a task supervisor that is busy or
  # held. A run already gone is answered `:noproc` and asks the same; a
  # process linked to the supervisor that is not a run asks at most one
  # pass more. With no task supervisor there is nothing to watch, and the
  # two-tick pass asked for at the start still comes.
  defp adopt_runs(state) do
    with sup when is_pid(sup) <- Process.whereis(Opus.Schedules.TaskSupervisor),
         {:links, links} <- Process.info(sup, :links),
         {:parent, parent} <- Process.info(sup, :parent) do
      orphans =
        for pid <- links,
            is_pid(pid) and pid != parent,
            into: MapSet.new(),
            do: Process.monitor(pid)

      %{state | orphans: orphans}
    else
      _gone -> state
    end
  end

  # ---------------------------------------------------------------------------
  # Loading and recovery
  # ---------------------------------------------------------------------------

  defp load_all_schedules(state) do
    case CronSchedule.active_schedules() do
      {:error, :database_error} ->
        load_retry(state, "storage unavailable")

      {:ok, schedules} ->
        Logger.info("[Opus.Schedules.Scheduler] loading #{length(schedules)} active schedule(s)")

        state = Enum.reduce(schedules, state, &load_one_schedule/2)
        %{state | load_retry_count: 0}
    end
  rescue
    e in @db_load_errors ->
      level = if match?(%DBConnection.OwnershipError{}, e), do: :warning, else: :error
      load_retry(state, Exception.message(e), level)
  catch
    :exit, reason ->
      load_retry(state, Prima.LogFilter.format_exception(:exit, reason), :warning)
  end

  defp load_retry(state, why, level \\ :error) do
    retry_count = state.load_retry_count + 1
    delay_ms = min(5_000 * Integer.pow(2, retry_count - 1), 60_000)

    Logger.log(
      level,
      "[Opus.Schedules.Scheduler] failed to load schedules (#{why}), retry #{retry_count}/#{@max_load_retries} in #{delay_ms}ms"
    )

    Process.send_after(self(), :retry_load, delay_ms)
    %{state | load_retry_count: retry_count}
  end

  # Boot arms timers: the cursor each row carries is the next occurrence,
  # and a cursor already in the past is claimed at once, where its
  # schedule's missed-run policy decides it.
  defp load_one_schedule(schedule, acc) do
    case Cron.parse(schedule.cron_expression) do
      {:ok, _} ->
        schedule_timer(schedule.id, acc)

      {:error, reason} ->
        Logger.warning(
          "[Opus.Schedules.Scheduler] invalid cron for schedule #{schedule.id}: #{reason}"
        )

        acc
    end
  rescue
    e ->
      Logger.warning(
        "[Opus.Schedules.Scheduler] failed to load schedule #{schedule.id}: #{Prima.LogFilter.exception_message(e)}"
      )

      timer_failed(schedule.id, Prima.LogFilter.exception_message(e))
      acc
  catch
    :exit, reason ->
      Logger.warning(
        "[Opus.Schedules.Scheduler] failed to load schedule #{schedule.id}: exited #{Prima.LogFilter.inspect_reason(reason)}"
      )

      timer_failed(schedule.id, Sanctum.Refusals.render(reason))
      acc
  end

  defp recover_if_held(state) do
    generation = Arca.ControlPlane.generation()

    if still_ours?(generation),
      do: recover_occurrences(state, generation),
      else: recover_later(state)
  end

  # This member still holds its cell slot, under the generation the work
  # was started with. Both halves matter: the slot answers "may I act at
  # all", the generation answers "is what I issued still the current
  # holder's". A generation this member could not read authorizes nothing.
  defp still_ours?(expected) do
    known? = expected == :none or match?({:ok, n} when is_integer(n) and n > 0, expected)
    known? and Arca.ControlPlane.held?() and Arca.ControlPlane.generation() == expected
  end

  defp recover_later(state), do: request_recovery(state, @recheck_ms)

  # A live member's started occurrence whose execution ended is ended only
  # once this process has seen it so for two ticks on its own monotonic
  # clock: the run's own task closes its execution before it ends the
  # occurrence, and has at least those two ticks to do it whatever any
  # member's wall clock says. `seen_at` is read after the reads that saw the
  # occurrence, so the grace never starts before the end it waits on: a
  # grace given to another process's run starts late, where the control
  # plane reads its own clock early so that its own belief runs out first.
  # What is no longer answered lapsed is forgotten, so the seen-set is
  # bounded by the open set; a restart forgets it all, and waits two ticks
  # more.
  @doc false
  @spec graced([map()], map(), integer()) :: {[map()], map()}
  def graced(lapsed_live, state, seen_at) do
    seen = Map.new(lapsed_live, &{&1.id, Map.get(state.lapsed_seen, &1.id, seen_at)})
    graced = Enum.filter(lapsed_live, &(seen_at - Map.fetch!(seen, &1.id) >= @standing_ms))
    {graced, %{state | lapsed_seen: seen}}
  end

  # Whether a run this process holds in flight is running `occurrence_id`.
  defp in_flight?(state, occurrence_id),
    do: Enum.any?(state.tasks, fn {_ref, task} -> task.occurrence_id == occurrence_id end)

  # The standing pass's own timer, armed again by each pass a second past the
  # grace (the margin `Arca.ControlPlane` gives up): a sighting is stamped
  # after its pass's reads, so a timer at exactly the grace would come that
  # read's length short of it and leave the end to the pass after.
  defp arm_standing(state) do
    if state.standing_ref, do: Process.cancel_timer(state.standing_ref)
    delay_ms = @standing_ms + Arca.ControlPlane.margin_ms()
    %{state | standing_ref: Process.send_after(self(), :standing_pass, delay_ms)}
  end

  # Two ticks and the margin `Arca.ControlPlane` gives up: the exit comes
  # after the claim on the cell's clock, so a pass at this due finds the
  # claim older than `abandoned_before/0`'s two ticks.
  defp left_to_recovery_ms, do: 2 * @recheck_ms + Arca.ControlPlane.margin_ms()

  # One timer serves every request for a recovery pass. With none armed, a
  # request arms one for its due; with one armed, whichever of the two
  # fires first is kept and the other cancelled. `recovery_due` keeps the
  # latest due any request asked for, on the monotonic clock, so the pass
  # that fires re-arms for it (`rearm_recovery/1`): a pass runs at or after
  # every requested due, and one that runs early finds nothing yet.
  defp request_recovery(state, delay_ms) do
    due = System.monotonic_time(:millisecond) + delay_ms
    state = %{state | recovery_due: max(state.recovery_due || due, due)}

    case state.recovery_ref && Process.read_timer(state.recovery_ref) do
      left when is_integer(left) and left > delay_ms ->
        Process.cancel_timer(state.recovery_ref)
        arm_recovery(state, delay_ms)

      nil ->
        arm_recovery(state, delay_ms)

      # Armed, and firing first, or fired with its message on its way.
      _first ->
        state
    end
  end

  defp rearm_recovery(%{recovery_due: due} = state) when is_integer(due) do
    case due - System.monotonic_time(:millisecond) do
      left when left > 0 -> arm_recovery(state, left)
      _passed -> %{state | recovery_ref: nil, recovery_due: nil}
    end
  end

  defp rearm_recovery(state), do: %{state | recovery_ref: nil, recovery_due: nil}

  defp arm_recovery(state, delay_ms),
    do: %{state | recovery_ref: Process.send_after(self(), :recover_occurrences, delay_ms)}

  # An occurrence this member claimed or re-took and left open, neither
  # run nor ended: the pass that reaches it is asked for, due when its
  # claim is two ticks old.
  defp left_open(state), do: request_recovery(state, left_to_recovery_ms())

  # An end of this member's own occurrence that did not happen leaves it
  # open. Ended, or another member's now (`:stale`), it asks for nothing.
  defp left_open_unless_ended(state, {:ok, _ended}), do: state
  defp left_open_unless_ended(state, {:error, :stale}), do: state
  defp left_open_unless_ended(state, _not_ended), do: left_open(state)

  defp defer_occurrence(schedule_id, state), do: recheck_later(schedule_id, recover_later(state))

  # What a member that is no longer live left open: a claimed occurrence
  # was never invoked and runs once; a started one whose execution is gone
  # is uncertain. A peer's fresh claim is not here to be taken — the cutoff
  # is the cell's clock less two of this scheduler's own ticks, so only a
  # claimant that has dropped out of the roster or stopped making progress
  # is recovered.
  defp recover_occurrences(state, generation) do
    case ScheduleOccurrences.recoverable(abandoned_before()) do
      {:ok, %{never_invoked: never_invoked, lapsed: lapsed, lapsed_live: lapsed_live}} ->
        # Read once the reads that saw these occurrences have returned.
        seen_at = System.monotonic_time(:millisecond)
        {graced, state} = graced(lapsed_live, state, seen_at)

        # A lapsed occurrence a run of this process still holds is that
        # run's to end: its execution closed before the run's own end.
        state =
          Enum.reduce(lapsed ++ graced, state, fn occurrence, acc ->
            cond do
              in_flight?(acc, occurrence.id) ->
                acc

              still_ours?(generation) ->
                Logger.warning(
                  "[Opus.Schedules.Scheduler] occurrence #{occurrence.id} of #{occurrence.schedule_id} started " <>
                    "and its execution ended without it: uncertain"
                )

                # Ended only as it was read: a row another member moved since
                # is `:stale`, and left alone.
                ScheduleOccurrences.finish(
                  Prima.Actor.in_athanor(occurrence.athanor_id),
                  occurrence.id,
                  occurrence.claimed_by,
                  occurrence.execution_id,
                  "uncertain"
                )
                |> logged_stale(occurrence)
                |> case do
                  {:error, :database_error} -> recover_later(acc)
                  _ -> acc
                end

              true ->
                recover_later(acc)
            end
          end)

        # Only the occurrence a run in flight holds is skipped: another of
        # the same schedule, left while that run goes on, is re-run.
        Enum.reduce(never_invoked, state, fn occurrence, acc ->
          if in_flight?(acc, occurrence.id),
            do: acc,
            else: rerun_claimed(occurrence, acc, generation)
        end)

      {:error, :database_error} ->
        recover_later(state)
    end
  rescue
    e in @db_load_errors ->
      Logger.warning(
        "[Opus.Schedules.Scheduler] occurrence recovery failed: #{Exception.message(e)}"
      )

      # Part-way through, perhaps after a take that committed.
      left_open(state)
  catch
    :exit, reason ->
      Logger.warning(
        "[Opus.Schedules.Scheduler] occurrence recovery exited: #{Prima.LogFilter.inspect_reason(reason)}"
      )

      left_open(state)
  end

  # The occurrence is taken from its abandoned claimant in one statement
  # before anything is run under it: of two recoverers reading the same
  # row, one takes it and the other is told `:held` and does nothing.
  #
  # The slot is asked again for each occurrence, not once for the pass: a
  # member whose slot lapsed part-way through a recovery writes nothing
  # more, take included.
  defp rerun_claimed(occurrence, state, generation) do
    if still_ours?(generation),
      do: take_and_rerun(occurrence, state, generation),
      else: recover_later(state)
  end

  # A recovered occurrence runs under the same standing the fire path
  # checks: the schedule's athanor still active and its creator not denied
  # (`Sanctum.Tenancy.channel_active?/2`). One that no longer stands is
  # recorded as the fire path records a skipped run, and failed.
  defp take_and_rerun(occurrence, state, generation) do
    with :ok <- take_over(occurrence),
         {:ok, %{status: "active"} = schedule} <-
           CronSchedule.get_for_daemon(occurrence.schedule_id),
         :ok <- standing(schedule),
         {:ok, exec_reference, input} <- runnable(schedule) do
      ctx = context_of(schedule)

      Logger.info(
        "[Opus.Schedules.Scheduler] occurrence #{occurrence.id} of #{schedule.id} claimed and never run: running it"
      )

      run_occurrence(schedule, occurrence, ctx, exec_reference, input, state, generation)
    else
      :held ->
        # A peer took the occurrence between this member's read and its
        # take: theirs to run, and nothing is written here.
        state

      {:error, :database_error} ->
        # After a take that may have succeeded: the occurrence may be this
        # member's claim now, fresh, so the tick's pass would not reach it.
        state |> recover_later() |> left_open()

      {:error, {:not_standing, schedule}} ->
        Logger.warning(
          "[Opus.Schedules.Scheduler] occurrence #{occurrence.id} of #{schedule.id}: athanor " <>
            "#{schedule.athanor_id} or creator #{inspect(schedule.user_id)} no longer " <>
            "active — not run"
        )

        # The occurrence is ended first, so one that is another member's
        # now records no error and announces no failure. One this member
        # re-took and did not end is left open.
        ended = fail_recovered(occurrence, generation)

        if ended != nil and ended != {:error, :stale} do
          ctx = context_of(schedule)
          record_error(ctx, schedule.id, "Athanor or creator no longer active — run skipped")
          emit_schedule_failed(schedule.id, ctx, "athanor_or_creator_inactive")
        end

        left_open_unless_ended(state, ended)

      _ ->
        left_open_unless_ended(state, fail_recovered(occurrence, generation))
    end
  end

  defp standing(schedule) do
    if Sanctum.Tenancy.channel_active?(schedule.athanor_id, schedule.user_id),
      do: :ok,
      else: {:error, {:not_standing, schedule}}
  end

  # A recovered occurrence that will not run, ended as this member's:
  # `recover/4` made it this member's claim, never started. Answers the
  # end's answer, or nil when the member no longer holds its standing and
  # ends nothing.
  defp fail_recovered(occurrence, generation) do
    if still_ours?(generation) do
      ScheduleOccurrences.finish(
        Prima.Actor.in_athanor(occurrence.athanor_id),
        occurrence.id,
        claimant(),
        nil,
        "failed"
      )
      |> logged_stale(occurrence)
    end
  end

  defp take_over(occurrence) do
    ScheduleOccurrences.recover(
      Prima.Actor.in_athanor(occurrence.athanor_id),
      occurrence.id,
      occurrence.claimed_by,
      claimant()
    )
  end

  # An occurrence claimed before this instant is abandoned whoever claimed
  # it: two of this scheduler's own ticks, which is long enough that a
  # claimant still making progress has moved the row on.
  defp abandoned_before,
    do: DateTime.add(Arca.ServerMetaStorage.now!(), -2 * @recheck_ms, :millisecond)

  # ---------------------------------------------------------------------------
  # Firing
  # ---------------------------------------------------------------------------

  defp fire_schedule(schedule_id, state) do
    case CronSchedule.get_for_daemon(schedule_id) do
      {:error, :not_found} ->
        state

      {:error, :database_error} ->
        retry_later(schedule_id, state)

      {:ok, %{status: "active"} = schedule} ->
        ctx = context_of(schedule)

        if Sanctum.Tenancy.channel_active?(schedule.athanor_id, schedule.user_id) do
          fire_active_schedule(schedule, ctx, state)
        else
          # The athanor is archived or the creator was denied on this
          # server — the run is skipped and recorded, never the schedule
          # deleted: the members who remain decide its fate.
          Logger.warning(
            "[Opus.Schedules.Scheduler] schedule #{schedule_id} athanor #{schedule.athanor_id} or " <>
              "creator #{inspect(schedule.user_id)} no longer active — skipping run"
          )

          record_error(ctx, schedule_id, "Athanor or creator no longer active — run skipped")
          emit_schedule_failed(schedule_id, ctx, "athanor_or_creator_inactive")
          schedule_timer(schedule_id, state)
        end

      {:ok, _other_status} ->
        state
    end
  rescue
    e in @db_fire_errors ->
      Logger.warning(
        "[Opus.Schedules.Scheduler] fire_schedule #{schedule_id} failed (#{Exception.message(e)}), retrying in 30s"
      )

      :telemetry.execute([:cyfr, :schedules, :scheduler, :fire_failed], %{count: 1}, %{
        schedule_id: schedule_id
      })

      # Perhaps after a claim that committed, whose run never started.
      retry_later(schedule_id, left_open(state))
  catch
    :exit, reason ->
      Logger.warning(
        "[Opus.Schedules.Scheduler] fire_schedule #{schedule_id} exited (#{Prima.LogFilter.inspect_reason(reason)}), retrying in 30s"
      )

      retry_later(schedule_id, left_open(state))
  end

  defp fire_active_schedule(schedule, ctx, state) do
    case runnable(schedule) do
      {:error, :unresolved_reference} ->
        Logger.error(
          "[Opus.Schedules.Scheduler] schedule #{schedule.id} has no resolved_reference. " <>
            "Cannot execute with unresolved reference '#{schedule.reference}'. " <>
            "Re-create or update the schedule to pin a resolved version."
        )

        emit_schedule_failed(schedule.id, ctx, :unresolved_reference)
        record_error(ctx, schedule.id, "No resolved reference — re-create or update the schedule")
        schedule_timer(schedule.id, state)

      {:error, :invalid_input} ->
        Logger.error(
          "[Opus.Schedules.Scheduler] schedule #{schedule.id} has invalid JSON input, skipping execution"
        )

        emit_schedule_failed(schedule.id, ctx, :invalid_input)
        record_error(ctx, schedule.id, "Invalid JSON input")
        schedule_timer(schedule.id, state)

      {:ok, exec_reference, input} ->
        case claim(schedule) do
          {:ok, occurrence} ->
            run_occurrence(schedule, occurrence, ctx, exec_reference, input, state)

          :held ->
            # Not due, or another node advanced the cursor first.
            schedule_timer(schedule.id, state)

          :skipped ->
            # Missed under `skip`: nothing ran, and the cursor moved on to
            # the first time not missed.
            Logger.info(
              "[Opus.Schedules.Scheduler] schedule #{schedule.id} missed #{DateTime.to_iso8601(schedule.next_run_at)} — skipped"
            )

            schedule_timer(schedule.id, state)

          :overlapping ->
            # An occurrence of this schedule is still open and the
            # schedule forbids overlap: the due one waits, and is looked
            # at again shortly. A recovery pass is asked for too, so an
            # open occurrence nothing will run is reached once it is old
            # enough; a running one is not touched by it.
            recheck_later(schedule.id, recover_later(state))

          {:error, :not_owner} ->
            # The claim checks the member's slot itself, whatever the
            # row's kind, so the cached standing never stands in for it: a
            # member that lost its slot wrote nothing and recorded no
            # error, and defers as a lost generation does.
            defer_occurrence(schedule.id, state)

          {:error, :database_error} ->
            # The claim's commit may have happened, leaving this member's
            # claim open with no run.
            retry_later(schedule.id, left_open(state))
        end
    end
  end

  # What a run needs of the row, fail-closed: a resolved reference and
  # input that decodes.
  defp runnable(%{resolved_reference: nil}), do: {:error, :unresolved_reference}

  defp runnable(schedule) do
    case decode_json(schedule.input) do
      {:ok, input} -> {:ok, schedule.resolved_reference, input}
      {:error, :invalid_json} -> {:error, :invalid_input}
    end
  end

  # Claiming and advancing are one write, decided on the cell's clock: the
  # claim asks the expression for the time after the one it fires, or
  # after the missed horizon, and the missed bound says which due times
  # are ordinary. An expression that no longer parses cannot yield a next
  # occurrence — nothing is claimed rather than an occurrence nothing can
  # advance past.
  defp claim(schedule) do
    case Cron.parse(schedule.cron_expression) do
      {:ok, parsed} ->
        ScheduleOccurrences.claim(schedule, claimant(), %{
          next_after: &Cron.next_run(parsed, &1),
          missed_bound_ms: missed_bound_ms()
        })

      _unparseable ->
        Logger.warning(
          "[Opus.Schedules.Scheduler] schedule #{schedule.id} has an unusable cron expression — not claiming"
        )

        :held
    end
  end

  defp run_occurrence(
         schedule,
         occurrence,
         ctx,
         exec_reference,
         input,
         state,
         generation \\ Arca.ControlPlane.generation()
       ) do
    # Right after the claim or the take, the claim is this member's and
    # fresh: the tick's pass would find it too young, so the two-tick pass
    # is asked for beside it.
    if still_ours?(generation),
      do: start_occurrence(schedule, occurrence, ctx, exec_reference, input, state, generation),
      else: defer_occurrence(schedule.id, left_open(state))
  end

  # The run's execution id is minted here, before the task is spawned: it
  # is the execution the run is admitted as, and the one every end of the
  # occurrence names, the runner's death included.
  defp start_occurrence(schedule, occurrence, ctx, exec_reference, input, state, generation) do
    logger_metadata = Prima.LoggerContext.capture()
    execution_id = Prima.UUID7.execution_id()

    case spawn_run(fn ->
           Prima.LoggerContext.restore(logger_metadata)

           # A task that starts after the cached standing ran out runs
           # nothing and leaves its claim to recovery.
           if still_ours?(generation),
             do: run(schedule, occurrence, ctx, exec_reference, input, generation, execution_id),
             else: left_to_recovery()

           :ok
         end) do
      {:ok, ref} ->
        if not feed?(schedule) and still_ours?(generation), do: broadcast_update(ctx, schedule.id)

        task = %{
          ref: ref,
          schedule_id: schedule.id,
          occurrence_id: occurrence.id,
          execution_id: execution_id,
          athanor_id: occurrence.athanor_id,
          generation: generation,
          ctx: ctx,
          feed?: feed?(schedule)
        }

        # Keyed by the run's monitor: a second run of an `allow` schedule
        # never replaces the first while it is in flight.
        %{state | tasks: Map.put(state.tasks, ref, task)}

      {:error, reason} ->
        if still_ours?(generation) do
          Logger.error(
            "[Opus.Schedules.Scheduler] failed to spawn task for schedule #{schedule.id}: #{inspect(reason)}"
          )

          # Never started, so the end matches the claim with no execution;
          # an end that did not happen leaves the claim open.
          ended = finish(occurrence, execution_id, "failed")

          unless ended == {:error, :stale} do
            emit_schedule_failed(schedule.id, ctx, {:spawn_failed, reason})
            record_error(ctx, schedule.id, Sanctum.Refusals.render(:unavailable))
          end

          schedule_timer(schedule.id, left_open_unless_ended(state, ended))
        else
          defer_occurrence(schedule.id, left_open(state))
        end
    end
  end

  # A run's task, monitored before its function runs:
  # `Task.Supervisor.async_nolink/3` places the monitor and only then lets
  # the task start, so no exit comes before the monitor and its reason
  # reaches `run_ended/3`. The task supervisor's ceiling on tasks is the
  # one refusal it raises for.
  defp spawn_run(fun) do
    %Task{ref: ref} = Task.Supervisor.async_nolink(Opus.Schedules.TaskSupervisor, fun)
    {:ok, ref}
  rescue
    RuntimeError -> {:error, :max_children}
  end

  # A feed's fire first claims the feed's next seq, the one its result is
  # accepted under, before any decision is opened: a refused claim opens
  # none and runs nothing. A recovered re-run of a never-invoked occurrence
  # takes the same step, so it runs under a seq of its own.
  defp run(schedule, occurrence, ctx, exec_reference, input, generation, execution_id) do
    case claim_seq(schedule, ctx) do
      {:ok, feed} ->
        fire(schedule, occurrence, ctx, exec_reference, input, generation, feed, execution_id)

      {:error, :not_owner} ->
        # This member no longer owns its slot: it writes nothing more, and
        # the claimed occurrence is recovered as one never invoked.
        Logger.warning(
          "[Opus.Schedules.Scheduler] feed #{schedule.id} seq not claimed: this member " <>
            "no longer owns its slot — left to recovery"
        )

        left_to_recovery()

      {:error, reason} ->
        # Refused for another reason, it is ended here while the standing
        # holds; past it, nothing is written and the claim is left to
        # recovery.
        if still_ours?(generation),
          do: seq_refused(schedule, occurrence, ctx, reason, execution_id),
          else: left_to_recovery()
    end
  end

  # A schedule claims no seq. A feed claims its next one under the member
  # slot read now, which its result's acceptance is later fenced by.
  defp claim_seq(%{kind: "feed", id: id}, ctx) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot(),
         {:ok, seq} <- CronSchedule.claim_feed_seq(Sanctum.Context.actor(ctx), id) do
      {:ok, %{seq: seq, slot: slot}}
    end
  end

  defp claim_seq(_schedule, _ctx), do: {:ok, nil}

  # The seq was refused before the run: the occurrence never started, so
  # its end matches the claim with no execution.
  defp seq_refused(schedule, occurrence, ctx, reason, execution_id) do
    ended = finish(occurrence, execution_id, "failed")

    unless ended == {:error, :stale} do
      Logger.warning(
        "[Opus.Schedules.Scheduler] feed #{schedule.id} seq not claimed (#{inspect(reason)}) — not run"
      )

      emit_schedule_failed(schedule.id, ctx, reason)
      record_error(ctx, schedule.id, Sanctum.Refusals.render(reason))
    end

    left_to_recovery_unless_ended(ended)
  end

  # One root run, admitted as `execution_id`, the occurrence joined to the
  # execution by its admission; the occurrence closes with the answer,
  # whichever it is. The fire is one admission decision, recorded before
  # the run under a call id the context carries, so the root's row names
  # it, and completed with the run's answer.
  defp fire(schedule, occurrence, ctx, exec_reference, input, generation, feed, execution_id) do
    request_id = Prima.UUID7.request_id()
    call_id = Prima.UUID7.generate_id("call")
    ctx = %{ctx | request_id: request_id, call_id: call_id}

    decision =
      Prima.Decision.new(
        call_id: call_id,
        request_id: request_id,
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        plane: :external,
        tool: "schedule",
        action: "fire",
        inserted_at: DateTime.utc_now(),
        admission: :admitted
      )

    Sanctum.Decisions.open(ctx, decision, %{
      method: "cron/fire",
      input: %{schedule_id: schedule.id, reference: exec_reference, input: input}
    })

    start_native = System.monotonic_time()

    :telemetry.execute(
      [:cyfr, :schedules, :fired],
      %{system_time: System.system_time()},
      %{
        request_id: request_id,
        schedule_id: schedule.id,
        occurrence_id: occurrence.id,
        reference: exec_reference,
        execution_id: execution_id,
        athanor_id: ctx.athanor_id,
        user_id: ctx.user_id
      }
    )

    # A schedule fires under its bound profile's consent, through the one
    # door into "start a root", whoever is knocking.
    run_result =
      Opus.run_root(ctx, {:id, schedule.profile_id}, exec_reference, input,
        execution_id: execution_id,
        occurrence_id: occurrence.id,
        schedule_id: schedule.id,
        class: :background,
        retention_class: "schedule"
      )

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start_native, :native, :millisecond)

    if still_ours?(generation) do
      case run_result do
        {:ok, result} when is_map(feed) ->
          fired = %{
            call_id: call_id,
            request_id: request_id,
            execution_id: execution_id,
            reference: exec_reference,
            duration_ms: duration_ms
          }

          feed_completed(schedule, occurrence, ctx, feed, Map.get(result, :output, result), fired)

        {:ok, result} ->
          output = Map.get(result, :output, result)

          closed = %{
            result: {:ok, output},
            duration_ms: duration_ms,
            routed_to: Opus.service()
          }

          case complete(schedule, occurrence, execution_id, output) do
            {:error, :stale} ->
              # Another member's occurrence now: this member's decision is
              # still closed, and nothing else is written or announced.
              Sanctum.Decisions.close(ctx, call_id, closed)

            finished ->
              recorded = record_run(ctx, schedule.id, execution_id)
              Sanctum.Decisions.close(ctx, call_id, closed)

              :telemetry.execute(
                [:cyfr, :schedules, :completed],
                %{system_time: System.system_time(), duration_ms: duration_ms},
                %{
                  request_id: request_id,
                  schedule_id: schedule.id,
                  occurrence_id: occurrence.id,
                  reference: exec_reference,
                  execution_id: execution_id,
                  athanor_id: ctx.athanor_id,
                  user_id: ctx.user_id
                }
              )

              completed = %{
                schedule: schedule,
                occurrence: occurrence,
                execution_id: execution_id,
                output: output
              }

              publish_completion(ctx, completed, finished, recorded, generation)

              Logger.debug(
                "[Opus.Schedules.Scheduler] schedule #{schedule.id} completed (#{execution_id})"
              )

              left_to_recovery_unless_ended(finished)
          end

        {:error, reason} when reason in [:not_owner, :control_plane_lost] ->
          # The admission refused the run for the member's slot, in its own
          # transaction or on the fast path before it: nothing was written,
          # the occurrence is still this member's claim, never invoked, and
          # recovery takes it. Only this member's own decision is closed.
          Sanctum.Decisions.close(ctx, call_id, %{
            result: {:error, reason},
            duration_ms: duration_ms,
            routed_to: Opus.service()
          })

          Logger.warning(
            "[Opus.Schedules.Scheduler] schedule #{schedule.id}: this member no longer " <>
              "owns its slot — run not admitted, occurrence left to recovery"
          )

          left_to_recovery()

        {:error, reason} ->
          # An admission that failed left the occurrence claimed; a run
          # that failed left it started, under this run's execution. Either
          # way it ends failed, and nothing was invoked twice.
          ended = finish(occurrence, execution_id, "failed")

          Sanctum.Decisions.close(ctx, call_id, %{
            result: {:error, reason},
            duration_ms: duration_ms,
            routed_to: Opus.service()
          })

          unless ended == {:error, :stale} do
            Logger.warning(
              "[Opus.Schedules.Scheduler] schedule #{schedule.id} failed: #{inspect(reason)}"
            )

            emit_schedule_failed(schedule.id, ctx, reason, execution_id)
            record_error(ctx, schedule.id, Sanctum.Refusals.render(reason))
          end

          left_to_recovery_unless_ended(ended)
      end
    else
      # The run answered after this member's cached standing ran out:
      # nothing of its answer is written, and the occurrence it held is
      # left to recovery, however the standing reads when the scheduler
      # sees the exit.
      left_to_recovery()
    end
  end

  # A feed's run answered. Its decision is closed with the run's answer
  # whatever the acceptance then decides; the result is accepted, fenced by
  # the slot read when the seq was claimed, before the occurrence finishes.
  # An accepted result, a stale one (a later-claimed run's result is
  # already in) and a feed removed during the run each complete the
  # occurrence and record the run; a refused result fails it, and the
  # error names the refusal's reason and path, never the result. A member
  # that lost its slot writes nothing more and leaves the occurrence to
  # recovery. A feed announces no completion and no schedule update; an
  # accepted result alone is published, from the envelope its committed
  # accept answered, before the occurrence ends.
  defp feed_completed(schedule, occurrence, ctx, feed, output, fired) do
    Sanctum.Decisions.close(ctx, fired.call_id, %{
      result: {:ok, output},
      duration_ms: fired.duration_ms,
      routed_to: Opus.service()
    })

    case Opus.Feeds.accept(ctx, schedule.id, feed.seq, output, feed.slot) do
      {:ok, envelope} ->
        publish_feed(ctx, envelope)
        feed_ended(schedule, occurrence, ctx, feed, fired, :accepted)

      {:error, reason} when reason in [:stale, :not_found] ->
        feed_ended(schedule, occurrence, ctx, feed, fired, reason)

      {:error, :not_owner} ->
        Logger.warning(
          "[Opus.Schedules.Scheduler] feed #{schedule.id} seq #{feed.seq}: this member no " <>
            "longer owns its slot — result not accepted, occurrence left to recovery"
        )

        left_to_recovery()

      {:error, {:refused, refusal}} ->
        reason = refused_result(refusal)
        ended = finish(occurrence, fired.execution_id, "failed")

        unless ended == {:error, :stale} do
          Logger.warning(
            "[Opus.Schedules.Scheduler] feed #{schedule.id} seq #{feed.seq} failed: " <>
              Sanctum.Refusals.render(reason)
          )

          emit_schedule_failed(schedule.id, ctx, reason, fired.execution_id)
          record_error(ctx, schedule.id, Sanctum.Refusals.render(reason))
        end

        left_to_recovery_unless_ended(ended)

      {:error, reason} ->
        ended = finish(occurrence, fired.execution_id, "failed")

        unless ended == {:error, :stale} do
          Logger.warning(
            "[Opus.Schedules.Scheduler] feed #{schedule.id} seq #{feed.seq} failed: #{inspect(reason)}"
          )

          emit_schedule_failed(schedule.id, ctx, reason, fired.execution_id)
          record_error(ctx, schedule.id, Sanctum.Refusals.render(reason))
        end

        left_to_recovery_unless_ended(ended)
    end
  end

  # A refused result, named by the refusal's reason, its path in the result
  # and the output's status when it carries one, never by the result. An
  # output that is no 2xx envelope is refused at its root, and named by its
  # reason's sentence.
  defp refused_result(%{path: path, reason: reason} = refusal) do
    status =
      case refusal do
        %{status: status} when is_integer(status) -> " (status #{status})"
        _none -> ""
      end

    named =
      case reason do
        "error" -> Opus.Feeds.reason_sentence(reason)
        code -> "#{code} at #{inspect(path)}"
      end

    {:invalid_argument, "feed result refused: #{named}#{status}"}
  end

  # A feed's occurrence completed: its result accepted, stale (a
  # later-claimed run's result is already in) or its feed removed during
  # the run. An occurrence that is another member's now records no run.
  # The line names the outcome, never the result.
  defp feed_ended(schedule, occurrence, ctx, feed, fired, outcome) do
    ended = finish(occurrence, fired.execution_id, "completed")

    unless ended == {:error, :stale} do
      _ = record_run(ctx, schedule.id, fired.execution_id)

      :telemetry.execute(
        [:cyfr, :schedules, :completed],
        %{system_time: System.system_time(), duration_ms: fired.duration_ms},
        fired_meta(schedule, occurrence, ctx, fired)
      )

      Logger.debug(
        "[Opus.Schedules.Scheduler] feed #{schedule.id} seq #{feed.seq} completed " <>
          "(#{fired.execution_id}): #{outcome}"
      )
    end

    left_to_recovery_unless_ended(ended)
  end

  # The accept committed: its envelope goes on the athanor's feeds topic.
  # A publish that fails is said by the binding id and undoes nothing.
  defp publish_feed(ctx, envelope) do
    actor = Sanctum.Context.actor(ctx)

    case Cyfr.Bus.broadcast(actor, Cyfr.Bus.feeds(actor), FeedPublished.new(actor, envelope)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Opus.Schedules.Scheduler] feed #{envelope["binding"]}'s accepted result " <>
            "was not published: #{inspect(reason)}"
        )
    end
  end

  # This member's end of its own occurrence: its claim, and the execution
  # it minted for the run, or the claim with none when the run never
  # started. `:stale` is logged once here, and its caller writes nothing
  # further.
  defp finish(occurrence, execution_id, state) do
    ScheduleOccurrences.finish(
      Prima.Actor.in_athanor(occurrence.athanor_id),
      occurrence.id,
      claimant(),
      execution_id,
      state
    )
    |> logged_stale(occurrence)
  end

  @doc false
  # A completed run's end of its occurrence (`finish/3`, `claimed_by` this
  # boot), with the outcome's record (`Prima.OutboxRecord`) written in
  # the finish's own transaction (`Arca.ScheduleOccurrences.finish/6`'s
  # `also:`): the output as the run answered it, the schedule's choice to
  # keep it parsed from its metadata as the finish read it, the authority
  # the run fired under and the note revision the occurrence recorded at
  # the run's read. The note is never read here. The record's delivery is
  # `Aqua.ScheduleNotes`'s; the completion broadcast after it only wakes
  # it.
  #
  # `schedule` is the row as this member read it before the run. A read's
  # revision is the revision of the note the schedule named when the run
  # read it, and the occurrence holds no name beside it: so the record
  # copies it only while the schedule row stands at that same revision
  # (`updated_at`, the row's own stored value) when the finish reads it.
  # A row written since — a changed destination among anything else — may
  # name another note than the one read, and the record says `absent`,
  # which publishes only over nothing or over this schedule's own earlier
  # outcome, never over a note the run did not read.
  @spec complete(map(), map(), String.t(), term(), String.t()) ::
          {:ok, 1} | {:error, :stale | :no_athanor | :database_error | term()}
  def complete(schedule, occurrence, execution_id, output, claimed_by \\ claimant()) do
    ScheduleOccurrences.finish(
      Prima.Actor.in_athanor(occurrence.athanor_id),
      occurrence.id,
      claimed_by,
      execution_id,
      "completed",
      also: &record_outcome(&1, schedule, output)
    )
    |> logged_stale(occurrence)
  end

  defp record_outcome(%{occurrence: occurrence} = finished, read_before, output) do
    record =
      Prima.OutboxRecord.schedule_outcome(%{
        occurrence: bound_read(occurrence, read_before, finished.schedule),
        schedule: finished.schedule,
        consent_revision: finished.consent_revision,
        keep: keep_outcome(finished.schedule.metadata),
        output: output
      })

    # A record already there is this finish's own: the occurrence moves
    # once, so a second finish never reaches here.
    case Arca.Outbox.put!(Prima.Actor.in_athanor(occurrence.athanor_id), record) do
      :ok -> :ok
      {:error, :exists} -> :ok
    end
  end

  # The run's read is bound when the schedule row's `updated_at` at the
  # finish equals the stored value read before the run, and is otherwise
  # `absent`, which only creates the note or replaces this schedule's own
  # earlier outcome, so an unread note at a changed destination is a
  # conflict. The limit: a schedule edited during its run, or overlapping
  # runs of one that allows them, deliver as a conflict even where the run
  # read the very note it would update.
  defp bound_read(occurrence, %{updated_at: %DateTime{} = before}, %{
         updated_at: %DateTime{} = now
       }) do
    if DateTime.compare(before, now) == :eq,
      do: occurrence,
      else: %{occurrence | note_revision_read: nil}
  end

  defp bound_read(occurrence, _read_before, _finished),
    do: %{occurrence | note_revision_read: nil}

  # An end answered `:stale` found the occurrence another member's now,
  # or already ended: one line says so, and the answer is handed on.
  defp logged_stale({:error, :stale} = stale, occurrence) do
    Logger.warning(
      "[Opus.Schedules.Scheduler] occurrence #{occurrence.id} of #{occurrence.schedule_id} " <>
        "is stale: another member holds it now, or it was already ended — nothing more written"
    )

    stale
  end

  defp logged_stale(answer, _occurrence), do: answer

  # The run task's end when it leaves its claimed occurrence to recovery:
  # the exit reason tells the scheduler (`handle_info({:DOWN, …})`) to ask
  # for the pass that reaches it. A `{:shutdown, _}` exit is not a failed
  # run (`failed_run?/1`), so the runner is not taken for dead.
  @spec left_to_recovery() :: no_return()
  defp left_to_recovery, do: exit({:shutdown, :left_to_recovery})

  # A task whose own end of its occurrence did not happen leaves it open,
  # and ends left to recovery once it has done the rest. Ended, or another
  # member's now (`:stale`), it ends as it would.
  defp left_to_recovery_unless_ended({:ok, _ended}), do: :ok
  defp left_to_recovery_unless_ended({:error, :stale}), do: :ok
  defp left_to_recovery_unless_ended(_not_ended), do: left_to_recovery()

  defp fired_meta(schedule, occurrence, ctx, fired) do
    %{
      request_id: fired.request_id,
      schedule_id: schedule.id,
      occurrence_id: occurrence.id,
      reference: fired.reference,
      execution_id: fired.execution_id,
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id
    }
  end

  # The runner died without answering: the occurrence it held ends as
  # what the row says — never invoked, or started under the execution this
  # member minted with an unknown end — while it is still this member's.
  # Answers the settlement, so a settlement that did not happen leaves
  # the occurrence open (`left_open_unless_ended/2`).
  defp runner_died(schedule_id, task, reason) do
    Logger.warning(
      "[Opus.Schedules.Scheduler] schedule #{schedule_id} execution failed: " <>
        Prima.LogFilter.inspect_reason(reason)
    )

    settled =
      ScheduleOccurrences.settle_dead(
        Prima.Actor.in_athanor(task.athanor_id),
        task.occurrence_id,
        claimant(),
        task.execution_id
      )
      |> logged_stale(%{id: task.occurrence_id, schedule_id: schedule_id})

    unless settled == {:error, :stale},
      do: record_error(task.ctx, schedule_id, Sanctum.Refusals.render(reason))

    settled
  end

  defp record_run(ctx, schedule_id, execution_id) do
    case CronSchedule.record_run(Sanctum.Context.actor(ctx), schedule_id, execution_id) do
      {:ok, row} ->
        {:ok, row}

      {:error, reason} ->
        Logger.warning(
          "[Opus.Schedules.Scheduler] failed to record_run for #{schedule_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The completion is announced only after both writes committed — the
  # occurrence closed by THIS finish, its outcome recorded with it, and
  # the run recorded — and only while the generation still holds, checked
  # again immediately before the publish: a member taken over announces
  # nothing its successor might announce too. The announcement is a
  # wake-up for the outcome's consumers; the record is the fact. A finish that ended no row answered `:stale` and never
  # reaches here, since that closer's is the only word; the `moved > 0`
  # guard is the shape this clause accepts, and anything else, a finish
  # the store could not answer included, publishes nothing.
  defp publish_completion(ctx, completed, {:ok, moved}, {:ok, row}, generation)
       when is_integer(moved) and moved > 0 do
    %{schedule: schedule, occurrence: occurrence} = completed
    {keep?, note_name} = keep_outcome(schedule.metadata)
    actor = Sanctum.Context.actor(ctx)

    if still_ours?(generation) do
      completion =
        ScheduleCompleted.new(actor, %{
          issuer_member: ScheduleCompleted.issuer(Arca.ControlPlane.held()),
          schedule_id: schedule.id,
          execution_id: completed.execution_id,
          occurrence_id: occurrence.id,
          completed_at: Map.get(row, :last_run_at),
          keep_outcome: keep?,
          note_name: note_name,
          output: completed.output
        })

      case Cyfr.Bus.broadcast_global(Cyfr.Bus.schedule_completions(), completion) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Opus.Schedules.Scheduler] completion of #{schedule.id} not announced: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp publish_completion(_ctx, _completed, _finished, _recorded, _generation), do: :ok

  @doc false
  # Whether a schedule keeps its outcome, and under which note name, read
  # from the row's stored metadata (`Prima.OutboxRecord.keep_pair/1`, the
  # one reading of it). Absent, empty, not a map or not valid JSON is a
  # run nobody asked to keep; invalid JSON is said in one line naming the
  # column and its size, never its bytes.
  @spec keep_outcome(term()) :: {boolean(), String.t() | nil}
  def keep_outcome(metadata) do
    case Prima.OutboxRecord.keep_pair(metadata) do
      {:ok, pair} ->
        pair

      {:error, :invalid_json} ->
        Logger.warning(
          "[Opus.Schedules.Scheduler] stored metadata is not valid JSON (#{byte_size(metadata)} bytes)"
        )

        {false, nil}
    end
  end

  defp record_error(ctx, schedule_id, message) do
    case CronSchedule.record_error(Sanctum.Context.actor(ctx), schedule_id, message) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.warning(
          "[Opus.Schedules.Scheduler] failed to record_error for #{schedule_id}: #{inspect(err)}"
        )

        :telemetry.execute(
          [:cyfr, :schedules, :scheduler, :record_error_failed],
          %{count: 1},
          %{schedule_id: schedule_id, error: err}
        )
    end
  end

  # A schedule that could not run, or ran and failed: one event the tray
  # bridges into the athanor's badges (`Cyfr.TelemetryBridge`).
  defp emit_schedule_failed(schedule_id, ctx, reason, execution_id \\ nil) do
    :telemetry.execute([:cyfr, :schedules, :failed], %{count: 1}, %{
      schedule_id: schedule_id,
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id,
      execution_id: execution_id,
      reason: reason
    })
  end

  defp context_of(schedule),
    do: Sanctum.Context.for_scheduled(schedule.user_id, athanor_id: schedule.athanor_id)

  # ---------------------------------------------------------------------------
  # Timers
  # ---------------------------------------------------------------------------

  # A retry after a failure waits 30 s plus a little noise, so nodes that
  # failed together do not fire together.
  defp retry_later(schedule_id, state) do
    arm(schedule_id, {:fire, schedule_id}, @recheck_ms + jitter_ms(@recheck_ms), state)
  end

  defp recheck_later(schedule_id, state) do
    arm(schedule_id, {:fire, schedule_id}, @recheck_ms + jitter_ms(@recheck_ms), state)
  end

  defp arm(schedule_id, message, delay_ms, state) do
    state = cancel_timer(schedule_id, state)
    timer_ref = Process.send_after(self(), message, delay_ms)
    %{state | timers: Map.put(state.timers, schedule_id, timer_ref)}
  end

  # Up to a tenth of the delay, capped at 30 s: schedules that share a
  # minute boundary spread instead of landing on the same tick. The cap is
  # part of the missed bound (`missed_bound_ms/0`), so a jittered timer
  # never fires a missed time.
  defp jitter_ms(delay_ms) do
    case min(@max_jitter_ms, div(delay_ms, 10)) do
      spread when spread > 0 -> :rand.uniform(spread)
      _ -> 0
    end
  end

  # The occurrence is this BOOT's, not this node's: it is held while this
  # member is live in the cell, and a restarted node is a different boot
  # whose abandoned occurrences a successor may take.
  defp claimant, do: Prima.Boot.id()

  # The timer for the row's cursor. A cursor in the past fires at once;
  # one beyond the longest timer is looked at again later.
  defp schedule_timer(schedule_id, state) do
    state = cancel_timer(schedule_id, state)

    case CronSchedule.get_for_daemon(schedule_id) do
      {:error, :database_error} ->
        retry_later(schedule_id, state)

      {:ok, %{status: "active", next_run_at: %DateTime{} = next_run}} ->
        delay_ms = max(DateTime.diff(next_run, DateTime.utc_now(), :millisecond), 0)

        if delay_ms > @max_timer_ms,
          do: arm(schedule_id, {:recheck, schedule_id}, @max_timer_ms, state),
          else: arm(schedule_id, {:fire, schedule_id}, delay_ms + jitter_ms(delay_ms), state)

      {:ok, %{status: "active"} = schedule} ->
        # No cursor: one is derived from the expression, or the schedule
        # is orphaned until an update touches it — counted where
        # operators look.
        case compute_next_run(schedule.cron_expression) do
          {:ok, next_run} ->
            delay_ms = max(DateTime.diff(next_run, DateTime.utc_now(), :millisecond), 0)
            arm(schedule_id, {:fire, schedule_id}, delay_ms + jitter_ms(delay_ms), state)

          {:error, reason} ->
            Logger.warning("[Opus.Schedules.Scheduler] cannot schedule #{schedule_id}: #{reason}")

            timer_failed(schedule_id, reason)
            state
        end

      _ ->
        state
    end
  rescue
    e in @db_timer_errors ->
      Logger.warning(
        "[Opus.Schedules.Scheduler] schedule_timer #{schedule_id} failed (#{Exception.message(e)}), retrying in 30s"
      )

      timer_failed(schedule_id, Exception.message(e))
      retry_later(schedule_id, state)
  catch
    :exit, reason ->
      Logger.warning(
        "[Opus.Schedules.Scheduler] schedule_timer #{schedule_id} exited (#{Prima.LogFilter.inspect_reason(reason)}), retrying in 30s"
      )

      retry_later(schedule_id, state)
  end

  defp timer_failed(schedule_id, reason) do
    :telemetry.execute([:cyfr, :schedules, :scheduler, :timer_failed], %{count: 1}, %{
      schedule_id: schedule_id,
      reason: reason
    })
  end

  defp cancel_timer(schedule_id, state) do
    case Map.get(state.timers, schedule_id) do
      nil ->
        state

      timer_ref ->
        Process.cancel_timer(timer_ref)
        %{state | timers: Map.delete(state.timers, schedule_id)}
    end
  end

  defp cancel_all_timers(state) do
    Enum.each(state.timers, fn {_id, ref} -> Process.cancel_timer(ref) end)
    %{state | timers: %{}}
  end

  defp compute_next_run(cron_expression) do
    case Cron.parse(cron_expression) do
      {:ok, parsed} -> Cron.next_run(parsed, DateTime.utc_now())
      error -> error
    end
  end

  defp decode_json(nil), do: {:ok, %{}}
  defp decode_json(""), do: {:ok, %{}}

  defp decode_json(json) when is_binary(json) do
    case Prima.Json.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  # A feed is a row of kind `feed`: it fires as a schedule does, and
  # announces no schedule update and no completion.
  defp feed?(%{kind: "feed"}), do: true
  defp feed?(_schedule), do: false

  # An occurrence started or its run ended: the schedules view re-reads.
  defp broadcast_update(ctx, schedule_id) do
    actor = Sanctum.Context.actor(ctx)
    changed = Schedules.new(actor, :changed, schedule_id: schedule_id)

    case Cyfr.Bus.broadcast(actor, Cyfr.Bus.schedules(actor), changed) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Opus.Schedules.Scheduler] schedule update not announced: #{inspect(reason)}"
        )
    end
  end
end
