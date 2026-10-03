# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerService do
  @moduledoc """
  The worker service: it takes each assignment CYFR dispatches, hands it
  to a runner, kills runners, and reports each runner that exits leaving
  attempts open. It implements `Prima.WorkerAPI` and runs no guest code.

  Its service id, its worker key and where CYFR is are its credentials
  (`Opus.Credentials`, from `config :opus`), loaded when it starts; a
  missing or malformed one refuses the boot. Its boot id, minted when it
  starts, is carried on every header beside its service id. Every
  assignment it accepts must name both: one addressed to another boot of
  this service was dispatched to an incarnation that no longer runs, and
  is refused. A restarted service holds none of its predecessor's
  attempts: their runners are gone with it, and CYFR lapses them through
  the lease.

  CYFR reaches `start/3`, `kill/1` and `status/0` through
  `Opus.WorkerListener`. `start/3` reads the assignment
  (`Prima.Assignment.read/1`), refuses it as `:malformed` unless it names
  this service and boot, its input matches its `input_digest` and is a
  JSON object, and the sealed keys open under this worker service's
  dispatch seal key as the attempt it names, on this worker service
  (`Prima.WorkerAuth.open_attempt_keys/2`). The dispatch seal key never
  leaves this process: the runner is handed the opened keys.

  ## Runners

  A runner is an OS process of the pool (`Opus.RunnerPool`) the service
  never shares a VM with, and the service loads no component. `start/3`
  takes a runner of the assignment's athanor from the pool, binds the
  runner's relay to the attempt (`Opus.Relay`) and sends it the `assign`
  over `Prima.RunnerControl`. The runner has no network: every host call
  it makes and every pinned fetch its guests make leave through that
  relay, which verifies each call under the attempt's keys and posts it,
  and performs each fetch under the attempt's bounds. The runner attaches,
  runs the subtree with its formula children and reports `complete`,
  clean or not, or `exit` with the attempts still open. A runner that reports
  `exit`, whose channel closes or process ends with the subtree still
  assigned, or that completes unclean after a `cancel_child` for a child
  it held, is reported at once to the member that assigned its subtree —
  every attempt one runner holds was issued by one member, and no other
  lapses them — naming that member and the runner, and signed with the
  service's dispatch key (`Opus.HostClient.runner_exited/5`). The report
  names every attempt the service assigned that runner: the subtree's
  root, then every child the runner said it started, then what its `exit`
  lists that the service does not hold. A runner leaves a cancelled child
  out of its own `exit`, and a child's attempt that its runner attached to
  is stopped only by this report, so the service names it whatever the
  runner listed; an attempt already closed is named harmlessly, since CYFR
  lapses only a running attempt that runner still holds. A runner is
  reported once. A report runs beside the service, which never waits on
  CYFR, and `await_reports/1` answers once none is in flight. A
  `start` no runner can be found for answers `{:error, :unavailable}`,
  and while the keeper refuses runners `{:error, {:unavailable, sentence}}`
  with the keeper's account of why; the listener refuses either `503`,
  the second naming the sentence. The pool may hand out a runner whose
  clean completion it has read and sent here but the service has not yet
  read: that assignment is forgotten then, as its completion would forget
  it, before the runner is assigned again, so a kill of the old root is
  `:ok` and never ends the new subtree. CYFR reads a `503` naming a sentence as
  a definite refusal and closes the run failed with it; one naming none it
  reconciles against the attempt's claim (`c:Prima.WorkerAPI.start/3`),
  since the listener answers that too when its call into this service
  timed out. Its status counts the pool's runners and carries the bound
  its keeper holds each to and the keeper's refusal
  (`Opus.RunnerPool.status/1`).

  A runner tells the service each child it starts (`child`), so the
  service knows which runner holds which child. `kill/1` for the root of
  a runner's subtree taints the runner and ends it through the keeper,
  with the grace to report its open attempts; for a child a runner said
  it holds, that runner is sent a `cancel_child`, kills the child and
  completes unclean, and the service reports its end naming the child.
  Either kill is `:ok`, and `:ok` again for an
  execution a runner of this boot already ended; the ids of the last ten
  thousand roots and children ended are remembered for it. A kill of an
  execution no runner of this boot holds or held is `:not_found`, however
  busy the runners are, so CYFR counts no kill that reached nothing; it
  is still offered to every busy runner, in case one started it too
  recently for its word to have arrived. The ids of the last ten
  thousand kills offered so are remembered, each stamped from a
  service-wide sequence, as each assignment is when it starts: a runner
  whose assignment started before the kill, and so was sent it, and that
  then says it started that execution holds it as a child the service
  cancelled, and the id leaves that memory, so the runner's unclean
  completion is reported naming it. A runner assigned after the kill
  never received it, and its word changes nothing. A kill of what no
  runner holds changes no runner's cancelled children itself. Those are only children the runner said it
  holds, so they are never more than its live children, and they are
  forgotten with its assignment. A runner that ends without an `exit` is
  reported holding its subtree's root and every child it said it
  started.

  ## What one report can name

  A report names at most `Prima.WorkerWire.max_report_attempts/0`
  attempts, root included, so it fits the body CYFR reads whatever its
  identifiers. The bound counts every child one assignment started over
  its lifetime, not the ones running at once, since no frame tells the
  service a child ended: a subtree that starts more children than that
  in one assignment ends, whether or not they overlapped. A runner whose
  `child` would take what the service holds for it, its root and every
  child it started, past that bound is ended as a kill of its root ends
  it, and the child is not added: the service logs the runner and the
  bound, and its report names what the service held. That child, and any
  the runner says it started after it, are remembered as ended, so a
  kill of one is `:ok`, as for any execution a runner of this boot held.
  A guest that fans out past the bound fails its run, as it would past a
  memory bound, and never grows the report. The ids an `exit` lists that
  the service does not hold follow the ones it holds, and whatever is
  past the bound is left out and counted in the log. An attempt a report
  does not name is not lost: its row lapses on its own lease, and the
  report only makes that happen sooner.
  """

  @behaviour Prima.WorkerAPI

  use GenServer

  require Logger

  alias Prima.{Assignment, WorkerAuth}
  alias Opus.{HostClient, RunnerPool, RunnerProcess, Subtree}

  @attempt_fields [:athanor_id, :execution_id, :attempt, :fence, :generation]
  @remembered 10_000
  @max_report_attempts Prima.WorkerWire.max_report_attempts()

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Prima.WorkerAPI
  def start(token, input, sealed_keys)
      when is_binary(token) and is_binary(input) and is_binary(sealed_keys) do
    GenServer.call(__MODULE__, {:start, token, input, sealed_keys, Subtree.caller()})
  end

  @impl Prima.WorkerAPI
  def kill(execution_id) when is_binary(execution_id),
    do: GenServer.call(__MODULE__, {:kill, execution_id})

  @impl Prima.WorkerAPI
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Answer once every runner exit this service is reporting has been
  answered by CYFR or given up on (`Opus.HostClient.runner_exited/5`
  bounds each); at once when none is in flight. For a caller that must
  know no report of the runners it ended still lands after it moved on,
  as a test's end does. Exits if that takes longer than `timeout_ms`.
  """
  @spec await_reports(timeout()) :: :ok
  def await_reports(timeout_ms \\ 70_000),
    do: GenServer.call(__MODULE__, :await_reports, timeout_ms)

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    credentials = Opus.Credentials.load!()
    :ok = Opus.Credentials.install(credentials)
    settings = Opus.Settings.pool!()
    boot = "#{node()}#" <> Prima.UUID7.generate_id("boot")

    :ok =
      RunnerPool.serve(
        RunnerPool,
        %{service_id: credentials.service_id, boot: boot, host_url: credentials.host_url},
        self()
      )

    {:ok,
     %{
       credentials: credentials,
       service: credentials.service_id,
       boot: boot,
       settings: settings,
       assigned: %{},
       executions: %{},
       ended: %{ids: %{}, order: :queue.new()},
       offered: %{ids: %{}, order: :queue.new()},
       seq: 0,
       reports: %{},
       report_waiters: []
     }}
  end

  @impl true
  def handle_call({:start, token, input, sealed_keys, caller}, _from, state) do
    with {:ok, assignment} <- Assignment.read(token),
         true <- assignment.service == state.service and assignment.boot == state.boot,
         true <- Prima.Digest.sha256(input) == assignment.input_digest,
         {:ok, %{attempt: attempt} = keys} <-
           WorkerAuth.open_attempt_keys(state.credentials.dispatch_seal_key, sealed_keys),
         true <-
           attempt ==
             assignment |> Map.take(@attempt_fields) |> Map.put(:service, state.service),
         {:ok, %{} = _decoded} <- Jason.decode(input) do
      start_pooled(state, token, assignment, input, keys, caller)
    else
      _refused -> {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call({:kill, execution_id}, _from, state) do
    cond do
      pid = Map.get(state.executions, execution_id) ->
        :ok = RunnerPool.taint(RunnerPool, pid, state.settings.release_grace_ms)
        {:reply, :ok, state}

      pid = holder(state, execution_id) ->
        :ok = RunnerPool.cancel_child(RunnerPool, pid, execution_id)
        {:reply, :ok, cancelled(state, pid, execution_id)}

      ended?(state, execution_id) ->
        {:reply, :ok, state}

      map_size(state.assigned) > 0 ->
        # A child a runner started so recently that its word has not
        # arrived is still reached; the kill found no runner holding it,
        # so it is remembered until one says it started it (`child/5`).
        :ok = RunnerPool.cancel_child(RunnerPool, execution_id)
        {seq, state} = next_seq(state)

        {:reply, {:error, :not_found},
         %{state | offered: remember(state.offered, execution_id, seq)}}

      true ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:await_reports, from, state),
    do: {:noreply, reported(%{state | report_waiters: [from | state.report_waiters]})}

  def handle_call(:status, _from, state) do
    status =
      Map.merge(RunnerPool.status(RunnerPool), %{
        service: state.service,
        boot: state.boot,
        attempts: held(state)
      })

    {:reply, {:ok, status}, state}
  end

  # A report in flight has been answered, or given up on.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.reports, ref) do
    {:noreply, reported(%{state | reports: Map.delete(state.reports, ref)})}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state),
    do: {:noreply, gone(state, pid, {:handle_down, reason})}

  # An unclean completion after a cancel of one of the runner's children
  # ends the runner with that child's attempt still open at CYFR: it is
  # reported, as an exit is.
  def handle_info({RunnerPool, pid, {:complete, execution_id, clean}}, state) do
    case Map.get(state.assigned, pid) do
      %{execution_id: ^execution_id} = assignment ->
        state =
          if not clean and cancelled_child?(assignment),
            do: report(state, assignment.runner, assignment, []),
            else: state

        {:noreply, forget(state, pid)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({RunnerPool, pid, {:exit, runner, open}}, state) do
    case Map.get(state.assigned, pid) do
      nil ->
        {:noreply, state}

      assignment ->
        state = report(state, runner, assignment, open)
        {:noreply, forget(state, pid)}
    end
  end

  def handle_info({RunnerPool, pid, {:child, execution_id, attempt}}, state) do
    case Map.get(state.assigned, pid) do
      nil -> {:noreply, state}
      assignment -> {:noreply, child(state, pid, assignment, execution_id, attempt)}
    end
  end

  def handle_info({RunnerPool, pid, {:gone, reason}}, state),
    do: {:noreply, gone(state, pid, reason)}

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  # The credentials hold this service's keys, which no status or crash
  # report shows.
  @impl true
  def format_status(status), do: Map.update(status, :state, nil, &Map.delete(&1, :credentials))

  # ---------------------------------------------------------------------------
  # Starting
  # ---------------------------------------------------------------------------

  defp start_pooled(state, token, assignment, input, keys, caller) do
    execution_id = assignment.execution_id

    if Map.has_key?(state.executions, execution_id) do
      {:reply, {:error, :malformed}, state}
    else
      case RunnerPool.take(RunnerPool, assignment.athanor_id, execution_id) do
        {:ok, pid, runner} ->
          state = completed_unread(state, pid, runner, execution_id)

          case assign(state, pid, token, input, keys) do
            :ok ->
              Process.monitor(pid)
              {started, state} = next_seq(state)

              assigned = %{
                runner: runner,
                execution_id: execution_id,
                attempt: assignment.attempt,
                athanor: assignment.athanor_id,
                at: HostClient.at(assignment, state.credentials.host_url),
                started: started,
                children: %{},
                cancelled: MapSet.new(),
                over_bound: false,
                callers: caller.callers,
                logger: caller.logger
              }

              {:reply, :ok,
               %{
                 state
                 | assigned: Map.put(state.assigned, pid, assigned),
                   executions: Map.put(state.executions, execution_id, pid)
               }}

            {:error, :malformed} ->
              :ok = RunnerPool.taint(RunnerPool, pid, 0)
              {:reply, {:error, :malformed}, state}

            {:error, reason} ->
              Logger.error(
                "[Opus.WorkerService] the assign of #{execution_id} was not sent: #{inspect(reason)}"
              )

              :ok = RunnerPool.taint(RunnerPool, pid, 0)
              {:reply, {:error, :unavailable}, state}
          end

        {:error, {:refused, refusal}} ->
          {:reply, {:error, {:unavailable, refusal.message}}, state}

        {:error, reason} ->
          Logger.error("[Opus.WorkerService] no runner for #{execution_id}: #{inspect(reason)}")
          {:reply, {:error, :unavailable}, state}
      end
    end
  end

  # A runner the service still holds an assignment on has completed it
  # cleanly: the pool makes a runner idle only once it has read its clean
  # `complete`, and it forwards every frame the runner sent, that
  # `complete` last, before it answers the `take` that hands the runner out
  # again (`Opus.RunnerPool`). So every frame of the previous subtree is
  # already in this mailbox, behind this start. They are read now, in
  # order, against that subtree, up to its `complete`, which ends it as it
  # always does: a `child` it announced joins it and is ended with it, and
  # none of its frames can reach the new subtree. Should the `complete` not
  # be there, the pool's order was broken: the assignment is forgotten all
  # the same, so the new subtree never inherits it, and the break is logged.
  defp completed_unread(state, pid, runner, execution_id) do
    case Map.get(state.assigned, pid) do
      nil ->
        state

      assignment ->
        Logger.info(
          "[Opus.WorkerService] runner #{runner} was handed out for #{execution_id} before " <>
            "its clean completion of #{assignment.execution_id} was read; its frames are read first"
        )

        state = read_queued_frames(state, pid)

        if Map.has_key?(state.assigned, pid) do
          Logger.warning(
            "[Opus.WorkerService] runner #{runner} was handed out with no clean completion of " <>
              "#{assignment.execution_id} queued; that assignment is forgotten"
          )

          forget(state, pid)
        else
          state
        end
    end
  end

  # The runner's frames already queued here, read in order while it still
  # holds its previous assignment; the read stops once that assignment has
  # ended, and never waits for a frame not yet sent. A `child` read here
  # belongs to a subtree whose clean `complete` is already queued, so it has
  # ended with it: it is only remembered as ended, never counted against the
  # bound or answered by ending the runner, which the pool has already taken
  # for the next subtree. Every other frame is read as it always is.
  defp read_queued_frames(state, pid) do
    receive do
      {RunnerPool, ^pid, {:child, execution_id, _attempt}} ->
        read_queued_frames(refused_child(state, execution_id), pid)

      {RunnerPool, ^pid, _frame} = message ->
        {:noreply, state} = handle_info(message, state)

        if Map.has_key?(state.assigned, pid),
          do: read_queued_frames(state, pid),
          else: state
    after
      0 -> state
    end
  end

  # The service-wide sequence an assignment's start and an offered kill are
  # stamped from, so one can be told to precede the other.
  defp next_seq(%{seq: seq} = state), do: {seq, %{state | seq: seq + 1}}

  # The assign as the protocol spells it, the runner's relay bound to its
  # attempt first; a value the protocol refuses (the input past its bound)
  # is the caller's, and refuses the start.
  defp assign(state, pid, token, input, keys) do
    RunnerProcess.assign(pid, token, input, keys, state.credentials.host_url)
  rescue
    ArgumentError -> {:error, :malformed}
  end

  # ---------------------------------------------------------------------------
  # Runners' ends
  # ---------------------------------------------------------------------------

  # A runner gone with its subtree assigned is reported holding the
  # subtree's root and every child it said it started: the attempts the
  # service knows it held. CYFR lapses the ones still running.
  defp gone(state, pid, _reason) do
    case Map.get(state.assigned, pid) do
      nil ->
        state

      assignment ->
        state
        |> report(assignment.runner, assignment, [])
        |> forget(pid)
    end
  end

  # A child the runner said it started joins what the service holds for
  # it, unless it would take the subtree's root and every child it started
  # past what one report can name. Then the child is not added but
  # remembered as ended, and the runner is ended once, as a kill of its
  # root ends it: its report names what the service held.
  defp child(state, pid, assignment, execution_id, attempt) do
    cond do
      is_map_key(assignment.children, execution_id) or
          map_size(assignment.children) + 2 <= @max_report_attempts ->
        children = Map.put(assignment.children, execution_id, attempt)
        state = put_assignment(state, pid, %{assignment | children: children})

        if offered_before?(state, assignment, execution_id),
          do: offered_to(state, pid, execution_id),
          else: state

      assignment.over_bound ->
        refused_child(state, execution_id)

      true ->
        :ok = RunnerPool.taint(RunnerPool, pid, state.settings.release_grace_ms)

        log(
          :warning,
          assignment,
          "[Opus.WorkerService] runner #{assignment.runner} (#{assignment.execution_id}) " <>
            "started a child past the #{@max_report_attempts} attempts one report can " <>
            "name, and is ended"
        )

        state
        |> put_assignment(pid, %{assignment | over_bound: true})
        |> refused_child(execution_id)
    end
  end

  # A child the service did not add was still started by a runner of this
  # boot, which is ending: a kill of it is `:ok`, as for any child ended.
  defp refused_child(state, execution_id),
    do: %{state | ended: remember(state.ended, execution_id)}

  defp put_assignment(state, pid, assignment),
    do: %{state | assigned: Map.put(state.assigned, pid, assignment)}

  # The subtree's root and its children are ended for this boot: a kill of
  # any of them is `:ok` from now on.
  defp forget(state, pid) do
    {assignment, assigned} = Map.pop(state.assigned, pid)

    ended =
      Enum.reduce(
        [assignment.execution_id | Map.keys(assignment.children)],
        state.ended,
        &remember(&2, &1)
      )

    %{
      state
      | assigned: assigned,
        executions: Map.delete(state.executions, assignment.execution_id),
        ended: ended
    }
  end

  # The runner that said it started the child `execution_id`.
  defp holder(state, execution_id) do
    Enum.find_value(state.assigned, fn {pid, assignment} ->
      if is_map_key(assignment.children, execution_id), do: pid
    end)
  end

  # Every attempt a runner of this boot holds: each subtree's root and the
  # children its runner said it started.
  defp held(state) do
    for {_pid, assignment} <- state.assigned, attempt <- held_by(assignment), do: attempt
  end

  # Every attempt the service assigned one runner: its subtree's root and
  # the children it said it started.
  defp held_by(assignment),
    do: Enum.uniq([assignment.attempt | Map.values(assignment.children)])

  # The runner `pid` was sent a `cancel_child` for `execution_id`, a child
  # it says it holds, which it may still be reported holding. The set is
  # forgotten with the assignment, so it never outgrows the children.
  defp cancelled(state, pid, execution_id) do
    assignment = Map.fetch!(state.assigned, pid)

    put_assignment(state, pid, %{
      assignment
      | cancelled: MapSet.put(assignment.cancelled, execution_id)
    })
  end

  # Whether the service cancelled a child of the runner's: it cancels no
  # other in it.
  defp cancelled_child?(assignment), do: MapSet.size(assignment.cancelled) > 0

  # `execution_id` joins a memory of the last ten thousand ids, the oldest
  # dropped first, with `stamp`: the ended roots and children, or the kills
  # offered to every busy runner, stamped with when. An id remembered again
  # keeps its place and takes the new stamp.
  defp remember(%{ids: ids, order: order}, execution_id, stamp \\ true) do
    if is_map_key(ids, execution_id) do
      %{ids: Map.put(ids, execution_id, stamp), order: order}
    else
      ids = Map.put(ids, execution_id, stamp)
      order = :queue.in(execution_id, order)

      if map_size(ids) > @remembered do
        {{:value, oldest}, order} = :queue.out(order)
        %{ids: Map.delete(ids, oldest), order: order}
      else
        %{ids: ids, order: order}
      end
    end
  end

  defp ended?(state, execution_id), do: is_map_key(state.ended.ids, execution_id)

  # Whether a kill of `execution_id` was offered to every busy runner after
  # `assignment` started, so its runner was sent the `cancel_child`; a
  # runner assigned later never was.
  defp offered_before?(state, assignment, execution_id) do
    case Map.fetch(state.offered.ids, execution_id) do
      {:ok, offered} -> assignment.started < offered
      :error -> false
    end
  end

  # The runner `pid` says it started `execution_id`, whose kill was offered
  # to it before that word arrived: it holds a child the service cancelled,
  # and the kill is no longer anyone's to remember.
  defp offered_to(state, pid, execution_id) do
    %{ids: ids, order: order} = state.offered
    offered = %{ids: Map.delete(ids, execution_id), order: :queue.delete(execution_id, order)}
    cancelled(%{state | offered: offered}, pid, execution_id)
  end

  # A report of the end of `runner`, which held `assignment` and whose
  # `exit` listed `open`, runs beside the service, which never waits on
  # CYFR, and is watched until it is answered, so `await_reports/1` can
  # wait for it.
  defp report(%{credentials: credentials, boot: boot} = state, runner, assignment, open) do
    {attempts, left_out} = named(assignment, open)

    {_pid, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", assignment.callers)
        Prima.LoggerContext.restore(assignment.logger)

        if left_out > 0 do
          Logger.warning(
            "[Opus.WorkerService] the exit of runner #{runner} (#{assignment.execution_id}) " <>
              "leaves #{left_out} attempts out of its report, past the " <>
              "#{@max_report_attempts} one report can name; they lapse on their own leases"
          )
        end

        case HostClient.runner_exited(credentials, assignment.at, boot, runner, attempts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[Opus.WorkerService] the exit of runner #{runner} (#{assignment.execution_id}) " <>
                "was not reported: #{inspect(reason)}"
            )
        end
      end)

    %{state | reports: Map.put(state.reports, ref, true)}
  end

  # What the report of one runner's end names: the subtree's root, then the
  # children the runner said it started, then what its `exit` lists that
  # the service does not hold, cut at what one report can name
  # (`Prima.WorkerWire.max_report_attempts/0`); and how many were cut. What
  # the service holds is never past that bound (`child/5`).
  defp named(assignment, open) do
    held = held_by(assignment)
    holds = MapSet.new(held)
    unheld = open |> Enum.uniq() |> Enum.reject(&MapSet.member?(holds, &1))
    {named, left_out} = Enum.split(held ++ unheld, @max_report_attempts)
    {named, length(left_out)}
  end

  # A line about one runner's subtree carries the logger context its start
  # was made under (`Prima.LoggerContext.capture/0`), as its report's do.
  defp log(level, assignment, line), do: Logger.log(level, line, assignment.logger)

  # Whoever waits for the reports in flight is answered once none is.
  defp reported(%{reports: reports} = state) when map_size(reports) > 0, do: state

  defp reported(state) do
    for from <- state.report_waiters, do: GenServer.reply(from, :ok)
    %{state | report_waiters: []}
  end
end
