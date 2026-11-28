# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner do
  @moduledoc """
  The process that owns a thread's turns.

  One runner per thread, started on demand under
  `Aqua.RunnerSupervisor` and found through `Aqua.RunnerRegistry`. A
  browser session never owns a turn: the runner admits a send, accepts
  it on the tape with the turn it opens, runs the loop in a worker of
  its own (`Aqua.Loop`, the process that holds the turn's root, which
  dies with the runner — `Aqua.Loop.Worker`), and keeps what a viewer
  joining now needs — whether a turn runs, the tool activity, the usage.
  Every row is the tape's; every viewer reads the same topic.

  ## Admission

  A send is held to, in order: the text and its size; the sender's
  standing; the addressing (`Aqua.Runner.Admission`), which names the
  agent whose turn it is; then the athanor being filled
  (`:not_provisioned`, nothing written), the engine being up
  (`:execution_unavailable`), and the queue having room (`:busy`). Only
  then is the message accepted, atomically with the turn — or attached
  to the running or paused turn as a steer (`steer?/2`), or queued behind
  it as a turn of its own.
  A `client_id` the thread already accepted answers the same identity.

  A send the crew's delivery consumer makes carries its receipt, which
  lands in the acceptance's own transaction, and a reply the requests it
  answers (`Aqua.Tape.accept/3`).

  ## Turns

  One turn runs at a time. The loop ends the turn itself on every
  outcome but a pause; a turn paused around a launch or on an uncertain
  outcome waits for what continues it — the tape tells the runner — and
  continues as the person who sent it
  (`Sanctum.Tenancy.continuation/3`), or ends uncertain when the athanor
  is no longer that person's. A loop that dies without an answer is aborted
  from here (`Aqua.Loop.abort/4`) and its turn ended uncertain, or
  cancelled when a cancel asked for it. A turn whose end could not be
  written is settled as a loop's that died: ended uncertain and, when
  that cannot be written either, left as it stands by a runner that
  stops, with nothing behind it started, to the next start's recovery. An
  end the runner writes on a loop's behalf presents the fence that loop
  acquired, which the runner keeps from the turn's acceptance or
  recovery, never one read again: a turn taken meanwhile is its taker's.

  A turn continued from its rows — a paused turn picked up again, or a
  turn recovered after a restart — continues under the origin its row
  stores (`Prima.Origin`), never one guessed from the person it runs
  as: a programmatic turn resumes as `programmatic`. A turn whose row
  stores an origin outside the vocabulary, damage a hand-edited or
  restored row can carry, is cancelled with that reason and never resumed.

  ## A page's calls

  A call a page in Aqua's browser made (`Aqua.PageCalls`) is held here
  until it is a step: while a turn of the thread runs, it is proposed
  into that turn (`Aqua.Tape.propose_call/3`) and the loop is told; while
  the turn is paused, around a launch or on an uncertain outcome, it
  waits, and is proposed once the turn runs again or opens work of its
  own once the turn ends; with no turn, it opens a turn that asks no
  model, which runs as the person whose turn put the page, under that
  turn's origin, and is queued as any turn. At most `@queue_max` wait; past that a call is
  refused `:busy`, and a stop drops those waiting as it drops the queue.
  Its answer is its step's `page_result` row, heard on the thread's
  topic and handed back through `Opus.Browser.answer/5`; a call whose
  turn ended without answering it is answered as cancelled. A call whose
  request ended, or whose browser is gone, which the runner monitors from
  the moment it takes a call of it, is dropped while it waits here; once
  it has a row, the row records the end (`Aqua.Tape.end_call/4`), so no
  step of it is recorded or dispatched after, however far it had got,
  and its step still proposed is skipped. A runner
  that recovers a thread's turns holds no call of its predecessor, whose
  requests were answered unavailable when it died: their steps still
  proposed are skipped, and a turn one opened that never ran is
  cancelled.

  ## Recovery

  A runner starts only on a member that holds its slot in the cell
  (`Arca.ControlPlane.held?/0`) — started on demand or restarted after a
  crash alike — and only for a thread the row says nobody else is
  running. Finding no local runner is not finding no runner: the thread
  row is read, and a thread whose claim belongs to a turn a live peer
  holds is that peer's, so no runner is started for it, nothing is
  recovered and no recovery is counted against it.

  A runner that does start finds the thread's open turns and does what
  their rows say (`Aqua.Runner.RecoveryTable`), taking a turn only from
  the fence it read it with and only through the thread claim, which is
  taken in the same transaction as the recovery count. A turn another
  process on this boot still holds (`Aqua.Loop.holder/1`) — the loop of a
  runner that just died, until its kill lands — is not taken: the runner
  waits for that process to end, holds the turns behind it, and recovers
  the turn then, while the member still holds its slot.

  Every loop result, notification and timer checks the slot again. If it
  is lost or has expired, the runner stops its loop and exits without
  changing the tape or advancing queued turns. A holding runner recovers
  the open work from its durable rows.

  ## Broadcasts — `Cyfr.Bus.ThreadEvent` on `Cyfr.Bus.thread/2`

  The rows from the tape (`:message`, `:turn_finished`), and from here
  `:turn_starting`, `:turn_started`, `:turn_paused`, `:queued` and
  `:restart_prompt`; the loop
  announces `:usage`, `:tool_activity`, `:intents`, `:consent_required`,
  the running loop's `:turn_fence`, a chat step's streamed text as
  `:delta` and its withdrawal as `:delta_abandoned` (`Aqua.Loop.Stream`),
  which the runner keeps for the running turn's current fence until each
  step's answer lands or is withdrawn. `Cyfr.Bus.ThreadEvent` says what
  each kind's `data` is.

  A `:turn_finished` the runner hears, on whichever member the writer
  was, has it read again the turns it holds: one another writer ended
  under a raised fence (the person's stop of a workspace thread, a
  deletion or an archive of its room, each committed in storage first
  and announced on the thread after) is stopped here then, as
  `stop_cancelled/1` stops it on the writer's own member, not at its
  root's next lease tick (`ended_elsewhere/1`).
  """

  use GenServer, restart: :transient

  require Logger

  alias Aqua.Runner.{Admission, RecoveryTable}
  alias Aqua.Tape
  alias Cyfr.Bus.{Notify, ThreadEvent}
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  @registry Aqua.RunnerRegistry
  @supervisor Aqua.RunnerSupervisor
  @aqua Prima.AgentRef.soul_name()
  @person Admission.person()
  # Turns waiting behind the running one; beyond it a sender is told `:busy`.
  @queue_max 8
  # A runner with nothing to do for this long stops; the next send starts it again.
  @idle_ms :timer.minutes(15)
  @resume_retry_ms 5_000
  # A write refused for one of these found the turn another's, or over.
  @taken [:superseded, :not_open, :already_finished]
  @unwritten "the turn's terminal write did not land"
  @orphaned "the page's request ended with the runner that held it"
  # The boot's recovery scan, retried while the database cannot answer.
  @recovery_backoff_ms [1_000, 4_000, 16_000]

  @type send_result :: %{
          accepted: true,
          message_id: String.t(),
          seq: non_neg_integer(),
          turn_id: String.t() | nil,
          replayed: boolean(),
          admitted: :turn | :steer | :content
        }

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc false
  def start_link({thread_id, athanor_id}) do
    GenServer.start_link(__MODULE__, {thread_id, athanor_id}, name: via(thread_id))
  end

  defp via(thread_id), do: {:via, Registry, {@registry, thread_id}}

  @doc """
  The runner for a thread, started if it is not running. A member that
  holds no cell slot starts none (`{:error, :control_plane_lost}`), and
  neither does one whose thread row says a live peer is running a turn
  there (`{:error, :held_elsewhere}`).
  """
  @spec ensure(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure(thread_id, athanor_id)
      when is_binary(thread_id) and is_binary(athanor_id) do
    case Registry.lookup(@registry, thread_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        with :ok <- held(),
             :ok <- not_a_peers(thread_id, athanor_id),
             do: start_runner(thread_id, athanor_id)
    end
  end

  # Does this member hold its slot in the cell? A term read and an integer
  # comparison (`Arca.ControlPlane.held?/0`), asked again on every entry,
  # every loop result and every timer.
  defp held, do: if(Arca.ControlPlane.held?(), do: :ok, else: {:error, :control_plane_lost})

  # The rule that makes a join harmless to a running turn. A member that
  # finds no local runner has found NOTHING: absence from a registry is
  # never evidence, and "the holder is not on my node" is never evidence
  # that there is no holder. It reads the thread row instead, and a thread
  # whose claim is held by a live peer's turn is that peer's: this member
  # starts no runner for it, so it recovers nothing, counts no recovery
  # against it and does not fence out a turn that is running perfectly
  # well. A thread the row says nobody holds is this member's to pick up.
  #
  # A store that cannot answer admits nothing: the claim is the authority
  # and an unread authority is not a free one.
  defp not_a_peers(thread_id, athanor_id) do
    case Tape.claim_holder(internal_context(athanor_id), thread_id) do
      {:ok, %{live_peer?: false}} -> :ok
      {:ok, %{live_peer?: true}} -> {:error, :held_elsewhere}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp internal_context(athanor_id),
    do: Sanctum.Context.internal(user_id: "_threads", athanor_id: athanor_id, scope: :athanor)

  # A runner that declines to start answers why: the plane was lost in
  # between, or the thread is not an active athanor's.
  defp start_runner(thread_id, athanor_id) do
    case DynamicSupervisor.start_child(
           @supervisor,
           {__MODULE__, {thread_id, athanor_id}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      :ignore -> with :ok <- held(), do: {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The runner's pid when one is running."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(thread_id) do
    case Registry.lookup(@registry, thread_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Whether a turn is running in this thread right now, for a viewer of its
  athanor.

  No local runner is not "no turn": the thread row is asked, and a claim
  a live peer's turn holds is a turn that is running, on another member.
  A caller that acts on this — `thread.delete` refusing under a running
  turn — must be told the truth wherever the turn is.
  """
  @spec turn_running?(Context.t(), String.t()) :: boolean()
  def turn_running?(%Context{athanor_id: athanor_id} = ctx, thread_id) do
    case whereis(thread_id) do
      nil ->
        match?({:ok, %{live_peer?: true}}, Tape.claim_holder(ctx, thread_id))

      pid ->
        answer = GenServer.call(pid, :state)
        answer.running == true and answer.athanor_id == athanor_id
    end
  catch
    :exit, _ -> false
  end

  @doc "Subscribe the calling process to a thread's broadcasts."
  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(thread_id, athanor_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    Cyfr.Bus.subscribe(actor, Cyfr.Bus.thread(actor, thread_id))
  end

  # ---------------------------------------------------------------------------
  # API — every call carries the acting member's context
  # ---------------------------------------------------------------------------

  @doc "The live part of the thread for a viewer joining now."
  @spec state(String.t(), String.t()) :: map() | {:error, term()}
  def state(thread_id, athanor_id) do
    with {:ok, pid} <- ensure(thread_id, athanor_id), do: safe_call(pid, :state)
  end

  @doc """
  Send a message: accepted on the tape and shown to every member; a turn
  is opened when it addresses an agent. `opts`: `:id` (a pre-minted
  message id), `:client_id`, `:attachments` (refs), `:model`, `:room`
  (the room the sender had open, `%{"athanor_id", "thread_id", ...}`)
  and `:choice` (a press of a question's choice, `%{"row", "index"}`,
  its line the label as `Aqua.Choices.press/2` reads it).

  The crew's delivery consumer (`Aqua.Crew`) sends with `:sent_by` (the
  sender's name; `"person"` when absent), `:request` (the request row a
  delivery carries into its member's child thread) with `:crew`
  (`%{options}`, the brain options for the turn it opens), `:reply` (`%{request,
  outcome, answers}` for a member's reply), `:payload` (merged into the
  row's) and `:receipt` (its receipt, written in the acceptance).

  The same consumer delivers a workspace thread's opening with
  `:opening` (the opening row its transaction wrote, on which the turn
  opens, in place of a new row), and a workspace thread's report into a daily thread with `:report`,
  `:kind` (`"report"`) and `:workspace_id` (the thread it reports, which
  must still stand when it lands). Neither steers a turn already there.

  A schedule's turn consumer (`Aqua.ScheduleTurns`) sends with
  `:schedule` (`%{schedule_id, occurrence_id}`) and the schedule's name
  as `:payload`'s `"schedule"`, as the schedule's person under the
  `schedule` origin, into a daily thread or the workspace thread the
  schedule names, which it sends with `:standing` (an archived one
  refuses it, `Arca.TurnStorage.accept_message/3`): the send is a turn of Aqua
  whatever its line names, it never steers a turn already there, its line
  is written in the server's voice, so the person's count counts it, and
  the turn it opens carries the schedule and the occurrence on its
  options, which its root's admission reads (`Aqua.Loop`). No other
  caller passes it: the console and the thread tool build their options
  by name.

  A post of the server's own (`Aqua.Nudge`'s of a workspace thread that
  waits on its person) sends with `:server` and `:sent_by` the server's
  (`Prima.Author.system/0`), as the athanor's person under the
  `schedule` origin, into a daily thread: a turn of Aqua whatever names
  its text holds, in the server's voice, with no schedule's occurrence or
  grants. Unlike a schedule's line it steers a running or paused turn
  whose sender, person, agent and origin are its own, as any send does,
  except one paused on an uncertain call, which a line of the server's
  never acknowledges: it is a turn of its own behind it. `:workspace_id`
  names the workspace thread, `:wait` the wait it must still stand on and
  `:claim` the sending job's claim and slot, all judged in the acceptance
  (`Arca.TurnStorage.accept_message/3`).
  """
  @spec send_message(Context.t(), String.t(), String.t(), keyword()) ::
          {:ok, send_result()} | {:error, term()}
  def send_message(%Context{} = ctx, thread_id, text, opts \\ []) do
    with :ok <- held(), do: call(ctx, thread_id, {:send, ctx, text, opts})
  end

  @doc """
  The server's nudge of a quiet workspace thread (`Aqua.Nudge`), as the
  context's person under its origin, which are the thread's current
  work's (`attrs`: `:content`, `:options`, `:work`, `:quiet`, `:claim`). It is
  decided and accepted in storage under the thread's lock
  (`Aqua.Tape.nudge/3`): it joins the turn that holds the thread when that
  turn is Aqua's and asks a model, whose next model round reads it from
  storage, or with no turn open there opens one, which this runner starts.
  It never acknowledges a stopped turn for its person, never queues, and
  carries no authority of its own. A thread whose turn a live peer holds
  is joined there in storage alone, since that turn reads it from storage
  wherever it runs.
  """
  @spec nudge(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def nudge(%Context{} = ctx, thread_id, attrs) when is_map(attrs) do
    with :ok <- held() do
      case call(ctx, thread_id, {:nudge, ctx, attrs}) do
        {:error, :held_elsewhere} -> Tape.nudge(ctx, thread_id, Map.put(attrs, :join_only, true))
        answer -> answer
      end
    end
  end

  @doc """
  Hand a page's call to the thread's runner (moduledoc): `call` is
  `%{request, name, arguments, user_id, put_turn_id, browser}`, the call
  a model would make for it, the browser's person, the turn that put the
  page and the browser's holder (`Opus.Browser.held/4`). Answers the
  runner that holds it, or why it was refused.
  """
  @spec page_call(String.t(), String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def page_call(thread_id, athanor_id, %{request: _} = call)
      when is_binary(thread_id) and is_binary(athanor_id) do
    with :ok <- open?(athanor_id),
         {:ok, pid} <- ensure(thread_id, athanor_id) do
      case safe_call(pid, {:page_call, call}) do
        :ok -> {:ok, pid}
        {:error, _} = error -> error
      end
    end
  end

  @doc "A page's call whose request ended unanswered: what of it waits runs nothing."
  @spec page_call_ended(String.t(), String.t(), String.t()) :: :ok
  def page_call_ended(thread_id, _athanor_id, request)
      when is_binary(thread_id) and is_binary(request) do
    with pid when is_pid(pid) <- whereis(thread_id),
         do: safe_call(pid, {:page_call_ended, request})

    :ok
  end

  @doc """
  The person's stop: cancel the current running, paused or held turn and
  the turns and a page's calls queued behind it. In a workspace thread it
  stops all of the thread's work, its crew members' included, in one
  transaction (`Aqua.Tape.stop_work/2`): the thread's runner stops what
  it holds of it and refuses a page's calls queued there, and the crew
  threads' runners stop theirs after (`stop_cancelled/1`).
  """
  @spec stop_turn(Context.t(), String.t()) :: :ok | {:error, term()}
  def stop_turn(%Context{} = ctx, thread_id) do
    case call(ctx, thread_id, {:stop, ctx}) do
      {:ok, elsewhere} -> stop_cancelled(elsewhere)
      {:error, _} = refused -> refused
    end
  end

  @doc """
  Stop what still runs of turns storage cancelled with their thread, as
  a crew thread's retirement (`Aqua.Tape.retire/2`) or a room's deletion
  (`Aqua.Tape.delete_thread/2`) answers them: `%{turn_id, thread_id,
  steps}`. The thread's runner on this boot aborts each through the path
  a cancel takes for an ended turn — its loop and every worker under it,
  then each dispatched step's child execution and catalog handler
  (`Aqua.Loop.abort_ended/4`) — and stops once its thread is gone. A turn
  a peer member holds was taken from it by the cancellation's fence and
  released claim, as a takeover takes one.
  """
  @spec stop_cancelled([%{turn_id: String.t(), thread_id: String.t(), steps: [map()]}]) ::
          :ok | {:error, term()}
  def stop_cancelled(cancelled) when is_list(cancelled) do
    cancelled
    |> Enum.group_by(& &1.thread_id)
    |> Enum.reduce(:ok, fn {thread_id, entries}, result ->
      stopped =
        if pid = whereis(thread_id), do: safe_call(pid, {:stop_cancelled, entries}), else: :ok

      if result == :ok, do: stopped, else: result
    end)
  end

  @doc "A consent granted mid-turn applies to future roots: the turn is cut and the sender asked to re-send."
  @spec restart_for_consent(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def restart_for_consent(%Context{} = ctx, thread_id, result) when is_map(result),
    do: call(ctx, thread_id, {:restart_for_consent, ctx, result})

  @doc """
  Start a runner for every thread holding an open turn, while this boot
  owns the control plane.

  A scan the database cannot answer is tried again after each wait of
  `@recovery_backoff_ms`; once the last retry fails too, the recovery is
  abandoned with a log line and `[:cyfr, :aqua, :recovery, :abandoned]`.
  It answers `:ok` either way and never exits abnormally: it runs as a
  transient child of `Aqua.RunnerTree`, and a crash loop would spend that
  tree's restart intensity and take every runner with it.
  """
  @spec recover_all() :: :ok
  def recover_all, do: recover_all(&Process.sleep/1)

  @doc false
  # `wait` spends each wait of `@recovery_backoff_ms`, so a test can
  # observe the waits without sleeping through them.
  @spec recover_all((non_neg_integer() -> term())) :: :ok
  def recover_all(wait) when is_function(wait, 1) do
    if Arca.ControlPlane.held?(), do: recover_open(@recovery_backoff_ms, wait, 1)
    :ok
  end

  defp recover_open(backoff_ms, wait, attempt) do
    case Tape.with_open_turns() do
      {:ok, threads} ->
        Enum.each(threads, fn {athanor_id, thread_id} -> ensure(thread_id, athanor_id) end)

      {:error, :unavailable} ->
        case backoff_ms do
          [ms | rest] ->
            wait.(ms)
            recover_open(rest, wait, attempt + 1)

          [] ->
            abandon_recovery(attempt)
        end
    end
  end

  defp abandon_recovery(attempts) do
    Logger.error(
      "[Aqua.Runner] boot recovery abandoned: the open-turn scan could not read " <>
        "the database in #{attempts} attempts; no runner was recovered on this boot"
    )

    :telemetry.execute([:cyfr, :aqua, :recovery, :abandoned], %{attempts: attempts}, %{})
  end

  defp call(%Context{} = ctx, thread_id, request) do
    with {:ok, thread} <- Tape.thread(ctx, thread_id),
         :ok <- open?(thread.athanor_id),
         {:ok, pid} <- ensure(thread.id, thread.athanor_id) do
      safe_call(pid, request)
    end
  end

  defp safe_call(pid, request, timeout \\ 30_000) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp open?(athanor_id), do: if(Athanors.active?(athanor_id), do: :ok, else: {:error, :archived})

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  # A boot that does not own the control plane starts no runner, a restart
  # after a crash included: it recovers nothing, and the supervisor drops
  # the child rather than retrying it.
  @impl true
  def init({thread_id, athanor_id}) do
    Process.flag(:trap_exit, true)

    ctx = internal_context(athanor_id)

    with :ok <- held(),
         {:ok, thread} <- Tape.thread(ctx, thread_id),
         {:ok, %{status: "active"}} <- Athanors.get(athanor_id) do
      actor = Prima.Actor.in_athanor(athanor_id)
      :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.notify(actor))
      :ok = subscribe(thread.id, athanor_id)

      state =
        touch(%{
          id: thread.id,
          athanor_id: athanor_id,
          ctx: ctx,
          # What admission reads of the thread: its kind, room and member.
          thread: Map.take(thread, [:id, :kind, :parent_id, :agent]),
          # The running loop: its turn, task, sender and agent.
          live: nil,
          # A turn paused around a launch or on an uncertain call, waiting here.
          paused: nil,
          # Turns accepted behind the running one, oldest first.
          queue: [],
          # Open turns another process on this boot still holds: turn id =>
          # its holder and monitor, or nil while a recovery retries.
          held: %{},
          # What the latest turn used, as the rows store it.
          usage: Tape.usage(ctx, thread.id),
          tool_activity: [],
          # The running turn's streamed answers (`Aqua.Loop.Stream`).
          partials: Aqua.Loop.Stream.new(),
          agent: thread.agent,
          idle_ref: nil,
          # A page's calls waiting to become steps, oldest first.
          pages: [],
          # Every page's call handed here and not yet answered: its
          # request => the browser's person, whom the answer goes to, and
          # the monitor of the browser that holds its request.
          answering: %{}
        })

      # What the rows hold is known before the first send is admitted; a
      # runner that cannot read them admits nothing.
      case recover(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, {:unavailable, reason}}
      end
    else
      _ -> :ignore
    end
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, public_state(state), state}

  def handle_call(request, from, state) do
    if Arca.ControlPlane.held?(),
      do: handle_owned_call(request, from, state),
      else: {:stop, :normal, {:error, :control_plane_lost}, retire_runtime(state)}
  end

  defp handle_owned_call({:send, ctx, text, opts}, _from, state) do
    with {:ok, text, opts} <- chosen(ctx, state, text, opts),
         {:ok, {:turn, name}, text} <-
           Admission.check(ctx, state.athanor_id, state.thread, text, opts) do
      admit_turn(state, ctx, name, text, opts)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_owned_call({:nudge, ctx, attrs}, _from, state) do
    with :ok <- line_admitted(ctx),
         {:ok, accepted} <- Tape.nudge(ctx, state.id, attrs) do
      state = if accepted.turn, do: admitted(state, ctx, accepted.turn), else: state
      {:reply, {:ok, accepted}, touch(state)}
    else
      {:error, _} = refused -> {:reply, refused, state}
    end
  end

  defp handle_owned_call({:page_call, call}, _from, state) do
    cond do
      length(state.pages) >= @queue_max ->
        {:reply, {:error, :busy}, state}

      busy?(state) ->
        state = %{state | pages: state.pages ++ [call]} |> answering(call) |> propose()
        {:reply, :ok, touch(state)}

      true ->
        case open_call(answering(state, call), call) do
          {:ok, state} -> {:reply, :ok, touch(state)}
          {:error, reason, state} -> {:reply, {:error, reason}, unanswering(state, call.request)}
        end
    end
  end

  defp handle_owned_call({:page_call_ended, request}, _from, state),
    do: {:reply, :ok, ended_call(state, request)}

  defp handle_owned_call({:stop, ctx}, _from, state) do
    case Admission.standing(ctx, state.athanor_id) do
      :ok when state.thread.kind == "workspace" ->
        stop_work(state, ctx)

      :ok ->
        case cancel_work(state, "stopped", :person) do
          {:ok, state} -> {:reply, {:ok, []}, state}
          {:error, reason, state} -> {:stop, :normal, {:error, reason}, retire_runtime(state)}
        end

      refusal ->
        {:reply, refusal, state}
    end
  end

  # The turns are ended in storage already: what is left is the runtime.
  defp handle_owned_call({:stop_cancelled, entries}, _from, state) do
    entries
    |> Enum.reduce_while({:ok, state}, fn %{turn_id: id, steps: steps}, {:ok, state} ->
      case stop_ended(state, id, steps) do
        :ok -> {:cont, {:ok, retire_turn(state, id)}}
        {:error, reason} -> {:halt, {:error, reason, state}}
      end
    end)
    |> case do
      {:ok, state} ->
        case Tape.thread(state.ctx, state.id) do
          {:error, :not_found} -> {:stop, :normal, :ok, state}
          _ -> {:reply, :ok, start_next(state)}
        end

      {:error, reason, state} ->
        {:stop, :normal, {:error, reason}, retire_runtime(state)}
    end
  end

  defp handle_owned_call({:restart_for_consent, ctx, _result}, _from, state) do
    case Admission.standing(ctx, state.athanor_id) do
      :ok ->
        # The cut turn's own line is offered to the person who granted only
        # as the pane offers any stored line again (`Aqua.Tape.again_text/2`).
        prompt =
          with %{turn_id: turn_id} <- state.live || state.paused,
               {:ok, turn} <- Tape.turn(state.ctx, turn_id),
               {:ok, row} <- Tape.message(state.ctx, turn.message_id) do
            Tape.again_text(row, ctx.user_id)
          else
            _ -> nil
          end

        case cancel_work(state, "restart required", :person) do
          {:ok, state} ->
            if prompt,
              do: broadcast(state, :restart_prompt, %{text: prompt, user_id: ctx.user_id})

            {:reply, :ok, state}

          {:error, reason, state} ->
            {:stop, :normal, {:error, reason}, retire_runtime(state)}
        end

      refusal ->
        {:reply, refusal, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Admitting a turn
  # ---------------------------------------------------------------------------

  # A press (`thread.send`'s `choice`) is the person's answer to Aqua,
  # whatever its label says: the row it names is read again under the
  # person's context, its line is the label as the server reads it, and
  # its payload the press (`Aqua.Choices.press/2`); it lands only in a
  # room, where the card is. A resend under the press's `client_id` is
  # the same send only when it names the same row and index; any other
  # send under that id, a press or not, is refused, as a different send
  # under a taken id is (`Aqua.Tape.accept/3`), even when its words read
  # alike.
  defp chosen(ctx, state, text, opts) do
    case Keyword.get(opts, :choice) do
      nil ->
        with :ok <- not_a_press(ctx, state, Keyword.get(opts, :client_id)),
             do: {:ok, text, opts}

      _choice when state.thread.kind not in ["daily", "workspace"] ->
        {:error, :no_choice}

      choice ->
        with {:ok, pressed} <- pressed(ctx, state, choice, Keyword.get(opts, :client_id)) do
          payload = Map.put(Keyword.get(opts, :payload, %{}), "choice", pressed)
          {:ok, pressed["label"], Keyword.put(opts, :payload, payload)}
        end
    end
  end

  # A send that is no press under a press's client id is another send.
  defp not_a_press(_ctx, _state, nil), do: :ok

  defp not_a_press(ctx, state, client_id) do
    case Tape.accepted(ctx, state.id, client_id) do
      {:ok, %{message: row}} ->
        if Aqua.Choices.pressed(row), do: {:error, :client_id_reused}, else: :ok

      _not_taken ->
        :ok
    end
  end

  defp pressed(ctx, _state, choice, nil), do: Aqua.Choices.press(ctx, choice)

  defp pressed(ctx, state, choice, client_id) do
    case Tape.accepted(ctx, state.id, client_id) do
      {:ok, %{message: row}} ->
        with %{} = pressed <- Aqua.Choices.pressed(row),
             true <- Map.take(pressed, ["row", "index"]) == Map.take(choice, ["row", "index"]) do
          {:ok, pressed}
        else
          _other -> {:error, :client_id_reused}
        end

      {:error, :not_found} ->
        Aqua.Choices.press(ctx, choice)

      {:error, _} = refused ->
        refused
    end
  end

  defp admit_turn(state, ctx, name, text, opts) do
    cond do
      opened_before?(state, ctx, opts) ->
        accept_turn(state, ctx, name, text, opts)

      # A schedule's fire, an opening and a report are each a turn of
      # their own, never a steer of another.
      not own_turn?(opts) and steer?(state, ctx, name, opts) ->
        steer(state, ctx, name, text, opts)

      Sanctum.Provisioning.ready(ctx) != :ok ->
        {:reply, {:error, :not_provisioned}, state}

      not Opus.available?() ->
        {:reply, {:error, :execution_unavailable}, state}

      busy?(state) and length(state.queue) >= @queue_max ->
        {:reply, {:error, :busy}, state}

      true ->
        accept_turn(state, ctx, name, text, opts)
    end
  end

  defp own_turn?(opts), do: Enum.any?([:schedule, :opening, :report], &Keyword.has_key?(opts, &1))

  # A `client_id` that already opened a turn is offered as that turn's
  # opener again, never as a steer of it or a turn behind it: the tape
  # answers the identity it accepted, while the turn runs or after.
  defp opened_before?(state, ctx, opts) do
    case Keyword.get(opts, :client_id) do
      client_id when is_binary(client_id) ->
        match?(
          {:ok, %{message: %{id: id}, turn: %{message_id: id}}},
          Tape.accepted(ctx, state.id, client_id)
        )

      _ ->
        false
    end
  end

  defp steer?(%{live: %{} = live}, ctx, name, opts), do: steer?(live, send_of(ctx, name, opts))

  # A turn paused on an uncertain call goes on at its sender's next line,
  # which acknowledges it (`acknowledge/2`); a post of the server's never
  # acknowledges one, so it is a turn of its own behind it.
  defp steer?(%{live: nil, paused: %{} = paused}, ctx, name, opts) do
    not (Map.get(paused, :reason) == :uncertain and Keyword.get(opts, :server) == true) and
      steer?(paused, send_of(ctx, name, opts))
  end

  defp steer?(_state, _ctx, _name, _opts), do: false

  defp send_of(%Context{} = ctx, name, opts) do
    %{
      user_id: ctx.user_id,
      sent_by: Keyword.get(opts, :sent_by, @person),
      agent: name,
      origin: ctx.origin,
      job: job(Keyword.get(opts, :crew))
    }
  end

  @doc """
  Whether a send steers `turn`, the running or paused turn as the runner
  holds it from its row: the user, sender, agent, origin and job options
  all match. Each job Aqua hands over opens its own turn. A paused or
  recovered turn uses the same rule.
  """
  @spec steer?(map(), %{
          user_id: String.t(),
          sent_by: String.t(),
          agent: String.t(),
          origin: atom(),
          job: job()
        }) ::
          boolean()
  def steer?(
        %{user_id: user_id, sent_by: sent_by, agent: agent, job: job} = turn,
        %{user_id: user_id, sent_by: sent_by, agent: agent, origin: origin, job: job}
      )
      when is_binary(sent_by) and (sent_by != @aqua or agent == @aqua),
      do: same_origin?(origin, turn)

  def steer?(_turn, _send), do: false

  @typedoc """
  What a turn was asked to work under beyond its agent: the brain options
  a crew request set. Every member is offered the same tools on every
  job (`Aqua.Offered`).
  """
  @type job :: %{options: map()}

  # The job a send carries, or a turn's row names in its options.
  defp job(nil), do: %{options: %{}}
  defp job(%{} = crew), do: %{options: crew[:options] || %{}}

  defp job_of(%{options: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = options} -> %{options: options["brain_options"] || %{}}
      _ -> job(nil)
    end
  end

  defp job_of(_turn), do: job(nil)

  # Whether a line's admission origin is the one the turn's row records
  # (its wire spelling). A context with no origin drives nothing.
  defp same_origin?(%Context{origin: origin}, turn), do: same_origin?(origin, turn)

  defp same_origin?(origin, %{origin: stored}) when is_binary(stored),
    do: Prima.Origin.origin?(origin) and Prima.Origin.to_wire(origin) == stored

  defp same_origin?(_origin, _turn), do: false

  defp busy?(%{live: nil, paused: nil, held: held}) when map_size(held) == 0, do: false
  defp busy?(_state), do: true

  defp steer(state, ctx, name, text, opts) do
    %{turn_id: turn_id} = state.live || state.paused
    attrs = crew_attrs(%{message: message(ctx, text, opts, name), steer_turn_id: turn_id}, opts)

    case Tape.accept(ctx, state.id, attrs) do
      {:ok, %{message: row, replayed: replayed}} ->
        {:reply, {:ok, result(row, turn_id, replayed, :steer)}, touch(acknowledge(state, ctx))}

      # The turn ended before its end reached this process: the line opens
      # the next turn, queued behind the end.
      {:error, :turn_over} ->
        accept_turn(state, ctx, name, text, opts)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # A turn stopped on a call whose outcome is unknown continues on its
  # sender's next line — the one past the boundary the stop moved, sent
  # under the origin the turn records; a replayed earlier line is not
  # that, and neither is a line of another origin.
  defp acknowledge(
         %{live: nil, paused: %{reason: :uncertain, turn_id: turn_id} = paused} = state,
         ctx
       ) do
    with true <- same_origin?(ctx, paused),
         {:ok, %{status: "paused"} = turn} <- Tape.turn(state.ctx, turn_id),
         true <- Tape.steer_pending?(state.ctx, turn) do
      continue(%{state | paused: nil}, entry_of(paused), :resume)
    else
      _ -> state
    end
  end

  defp acknowledge(state, _ctx), do: state

  defp entry_of(paused),
    do:
      paused
      |> Map.take([:turn_id, :user_id, :sent_by, :agent, :origin, :job, :fence])
      |> Map.put(:ctx, nil)

  defp accept_turn(state, ctx, name, text, opts) do
    attrs =
      %{
        message: message(ctx, text, opts, name),
        turn: %{
          agent: name,
          requested_by: ctx.user_id,
          model: Keyword.get(opts, :model),
          options: options(name, opts)
        }
      }
      |> crew_attrs(opts)
      |> put_present(:opening_id, opts |> Keyword.get(:opening) |> opening_id())

    case Tape.accept(ctx, state.id, attrs) do
      {:ok, %{message: row, turn: turn, replayed: true}} ->
        {:reply, {:ok, result(row, turn && turn.id, true, :turn)}, touch(state)}

      # A crew member's answer to a request the person's stop ended: a
      # row, and no turn (`Arca.TurnStorage.accept_message/3`).
      {:ok, %{message: row, turn: nil}} ->
        {:reply, {:ok, result(row, nil, false, :content)}, touch(state)}

      {:ok, %{message: row, turn: turn}} ->
        state = admitted(%{state | agent: name}, ctx, turn)
        {:reply, {:ok, result(row, turn.id, false, :turn)}, touch(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # A turn accepted for this thread, started now or queued behind the one
  # that runs.
  defp admitted(state, ctx, turn) do
    entry = %{
      turn_id: turn.id,
      user_id: ctx.user_id,
      sent_by: turn.sent_by,
      job: job_of(turn),
      ctx: ctx,
      agent: turn.agent,
      # What a continuation of this turn resumes under: the origin its
      # row stores, never the context's as it stands later.
      origin: turn.origin,
      # What an end written on its loop's behalf presents.
      fence: turn.fence
    }

    if busy?(state) do
      state = %{state | queue: state.queue ++ [entry]}
      broadcast(state, :queued, length(state.queue))
      state
    else
      start(state, entry)
    end
  end

  # What a server's line asks before it opens a turn: the athanor filled
  # and the engine up, as a send's turn asks (`admit_turn/5`).
  defp line_admitted(ctx) do
    cond do
      Sanctum.Provisioning.ready(ctx) != :ok -> {:error, :not_provisioned}
      not Opus.available?() -> {:error, :execution_unavailable}
      true -> :ok
    end
  end

  # A person's line is theirs; anything an agent sends is the agent's; a
  # schedule's line, sent for its person, and a post of the server's own
  # are in the server's voice.
  defp message(ctx, text, opts, addressee) do
    sent_by = Keyword.get(opts, :sent_by, Admission.person())
    reply = Keyword.get(opts, :reply)

    %{
      author: author(ctx, sent_by, opts),
      sent_by: sent_by,
      addressee: addressee,
      reply_to: reply && reply.request.id,
      outcome: reply && reply.outcome,
      content: text,
      id: Keyword.get(opts, :id),
      client_id: Keyword.get(opts, :client_id),
      payload: payload(opts)
    }
    |> put_present(:kind, Keyword.get(opts, :kind))
    |> put_present(:workspace_id, Keyword.get(opts, :workspace_id))
  end

  defp author(ctx, sent_by, opts) do
    cond do
      Keyword.has_key?(opts, :schedule) or Keyword.get(opts, :server) == true ->
        Prima.Author.system()

      sent_by == Admission.person() ->
        ctx.user_id

      true ->
        Prima.Author.agent()
    end
  end

  defp payload(opts) do
    attachments =
      case Keyword.get(opts, :attachments, []) do
        [] -> %{}
        refs -> %{"attachments" => refs}
      end

    case Map.merge(attachments, Keyword.get(opts, :payload, %{})) do
      empty when map_size(empty) == 0 -> nil
      payload -> payload
    end
  end

  # What a delivery adds to an acceptance: the reply address of the turn a
  # delivered request opens, the requests a reply answers, the consumer's
  # receipt, and for a post of the server's the wait it stands on and the
  # sending job's claim.
  defp crew_attrs(attrs, opts) do
    attrs
    |> put_present(:standing, Keyword.get(opts, :standing))
    |> put_present(:receipt, Keyword.get(opts, :receipt))
    |> put_present(:wait, Keyword.get(opts, :wait))
    |> put_present(:claim, Keyword.get(opts, :claim))
    |> put_present(:answers, opts |> Keyword.get(:reply) |> answers())
    |> put_present(:reply_address, opts |> Keyword.get(:request) |> reply_address())
  end

  defp answers(%{answers: [_ | _] = ids}), do: ids
  defp answers(_reply), do: nil

  defp reply_address(%{id: request_id, thread_id: room}),
    do: %{asking_thread_id: room, request_id: request_id}

  defp reply_address(_request), do: nil

  defp opening_id(%{id: id}), do: id
  defp opening_id(nil), do: nil

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  # The turn's options: its agent, the room the sender had open, and for a
  # delivered request the brain options it sets.
  defp options(name, opts) do
    crew = Keyword.get(opts, :crew, %{})

    %{
      "agent" => name,
      "room" => Keyword.get(opts, :room),
      "brain_options" => Map.get(crew, :options),
      "schedule" => Keyword.get(opts, :schedule)
    }
    |> Aqua.AgentConfig.stringify_deep()
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == %{} end)
  end

  defp result(row, turn_id, replayed?, admitted) do
    %{
      accepted: true,
      message_id: row.id,
      seq: row.seq,
      turn_id: turn_id,
      replayed: replayed?,
      admitted: admitted
    }
  end

  # ---------------------------------------------------------------------------
  # Running the loop
  # ---------------------------------------------------------------------------

  defp start(state, %{turn_id: turn_id, ctx: ctx} = entry) do
    run(state, entry, fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn_id) end)
  end

  # A turn continued from its rows runs as its sender under the origin its
  # row stores. A row whose stored origin is outside the vocabulary is
  # cancelled with that reason: it is never resumed under an origin guessed
  # from the sender.
  defp continue(state, %{turn_id: turn_id} = entry, mode) do
    case Sanctum.Tenancy.continuation(entry.user_id, state.athanor_id, entry.origin) do
      {:ok, actor} ->
        run(state, %{entry | ctx: actor}, fn ->
          Aqua.Loop.run_nested(ctx: actor, turn_id: turn_id, mode: mode)
        end)

      {:error, :no_origin} ->
        state
        |> end_turn(entry, "cancelled", unresumable(:no_origin), :recovery)
        |> start_next()

      {:error, reason} ->
        state
        |> end_turn(entry, "uncertain", unresumable(reason))
        |> start_next()
    end
  end

  # Why a turn cannot continue from its rows.
  defp unresumable(:no_origin),
    do: "the turn's stored origin is outside the vocabulary, nothing to resume under (no_origin)"

  defp unresumable(reason), do: "the athanor is no longer the sender's (#{reason})"

  # Viewers hear the turn start before the loop can announce anything of it.
  # The loop is a worker of this process: it, and every worker under it,
  # is killed when the runner ends.
  defp run(state, entry, fun) do
    broadcast(state, :turn_starting, entry.user_id)
    broadcast(state, :turn_started, entry.turn_id)
    task = Aqua.Loop.Worker.async(fun)

    state = %{
      state
      | live: Map.merge(entry, %{task: task}),
        paused: nil,
        usage: %{input: 0, output: 0},
        tool_activity: [],
        partials: Aqua.Loop.Stream.new()
    }

    touch(state)
  end

  defp start_next(%{queue: [], pages: []} = state), do: touch(answer_ended(state))

  # The call is still waiting when the ended turn's calls are answered,
  # so that end does not answer it.
  defp start_next(%{queue: [], pages: [call | pages]} = state) do
    case open_call(%{answer_ended(state) | pages: pages}, call) do
      {:ok, state} -> touch(state)
      {:error, reason, state} -> state |> refuse_call(call, reason) |> start_next()
    end
  end

  defp start_next(%{queue: [entry | rest]} = state) do
    state = %{answer_ended(state) | queue: rest}
    broadcast(state, :queued, length(rest))

    cond do
      not Users.own_athanor?(entry.user_id, state.athanor_id) ->
        state
        |> end_turn(
          entry,
          "cancelled",
          "the athanor is no longer the sender's",
          :recovery
        )
        |> start_next()

      # Queued from its row by a recovery: it runs as its sender's continuation.
      is_nil(entry.ctx) ->
        recovered_start(state, entry)

      true ->
        start(state, entry)
    end
  end

  # ---------------------------------------------------------------------------
  # What the loop answers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(message, state) do
    if Arca.ControlPlane.held?() do
      handle_owned_info(message, state)
    else
      # Stop local work without aborting or settling its durable turn. The
      # owning boot recovers those rows; process exit retires subscriptions,
      # held monitors and timers addressed to this runner.
      {:stop, :normal, retire_runtime(state)}
    end
  end

  defp handle_owned_info(
         {ref, result},
         %{live: %{task: %Aqua.Loop.Worker.Handle{ref: ref}}} = state
       ) do
    Process.demonitor(ref, [:flush])

    case Aqua.Loop.Worker.stop(state.live.task.pid) do
      :ok -> returned(state, result)
      {:error, _} -> {:stop, :normal, retire_runtime(state)}
    end
  end

  defp handle_owned_info(
         {:DOWN, ref, :process, _pid, reason},
         %{live: %{task: %Aqua.Loop.Worker.Handle{ref: ref}}} = state
       ) do
    case Aqua.Loop.Worker.stop(state.live.task.pid) do
      :ok -> crashed(state, reason)
      {:error, _} -> {:stop, :normal, retire_runtime(state)}
    end
  end

  # The browser that holds a page's call is gone: the call's request
  # ended. The process that held a turn is gone: the turn is recovered now.
  defp handle_owned_info({:DOWN, ref, :process, _pid, _reason} = msg, state) do
    with nil <- Enum.find(state.answering, &match?({_request, %{monitor: ^ref}}, &1)),
         nil <- Enum.find(state.held, fn {_turn_id, held} -> match?(%{ref: ^ref}, held) end) do
      Prima.LoggerContext.unexpected(__MODULE__, msg)
      {:noreply, state}
    else
      {request, %{monitor: ^ref}} ->
        {:noreply, ended_call(state, request)}

      {turn_id, %{pid: holder}} ->
        case Aqua.Loop.Worker.stop(holder) do
          :ok -> {:noreply, recover_held(state, turn_id)}
          {:error, _} -> {:stop, :normal, retire_runtime(state)}
        end
    end
  end

  defp handle_owned_info(%ThreadEvent{kind: :usage, data: usage}, state),
    do: {:noreply, %{state | usage: usage}}

  defp handle_owned_info(%ThreadEvent{kind: :tool_activity, data: list}, state),
    do: {:noreply, %{state | tool_activity: list}}

  # The loop announces its fence as it starts and as it takes its root
  # back after a launch: a page's call waiting here becomes a step now.
  defp handle_owned_info(
         %ThreadEvent{kind: :turn_fence, data: %{turn_id: turn_id, fence: fence}},
         %{live: %{turn_id: turn_id}} = state
       ),
       do:
         {:noreply, propose(%{state | partials: Aqua.Loop.Stream.advance(state.partials, fence)})}

  defp handle_owned_info(
         %ThreadEvent{kind: :delta_abandoned, data: %{turn_id: turn_id} = marker},
         %{live: %{turn_id: turn_id}} = state
       ),
       do: {:noreply, %{state | partials: Aqua.Loop.Stream.abandoned(state.partials, marker)}}

  defp handle_owned_info(
         %ThreadEvent{kind: :delta, data: %{turn_id: turn_id} = delta},
         %{live: %{turn_id: turn_id}} = state
       ),
       do: {:noreply, %{state | partials: Aqua.Loop.Stream.add(state.partials, delta)}}

  defp handle_owned_info(%ThreadEvent{kind: :message, data: %{kind: "page_result"} = row}, state),
    do: {:noreply, answer(state, row)}

  defp handle_owned_info(%ThreadEvent{kind: :message, data: row}, state) do
    told(state)
    {:noreply, %{state | partials: Aqua.Loop.Stream.landed(state.partials, row)}}
  end

  defp handle_owned_info(%ThreadEvent{kind: :turn_finished}, state) do
    case ended_elsewhere(state) do
      {:gone, state} -> {:stop, :normal, state}
      {:stopped, state} -> {:noreply, start_next(state)}
      {:kept, state} -> {:noreply, state}
    end
  end

  defp handle_owned_info(%ThreadEvent{}, state), do: {:noreply, state}

  defp handle_owned_info({:resume, turn_id}, %{paused: %{turn_id: turn_id}} = state),
    do: {:noreply, settle_paused(state)}

  defp handle_owned_info({:resume, _turn_id}, state), do: {:noreply, state}

  defp handle_owned_info({:recover, turn_id}, %{held: held} = state)
       when is_map_key(held, turn_id) and :erlang.map_get(turn_id, held) == nil,
       do: {:noreply, recover_held(state, turn_id)}

  defp handle_owned_info({:recover, _turn_id}, state), do: {:noreply, state}

  # The athanor changed: an archive ends the runner, its turns cut.
  defp handle_owned_info(%Notify{kind: :athanor_changed}, state) do
    case Athanors.get(state.athanor_id) do
      {:ok, %{status: "archived"}} ->
        case cancel_work(state, "the athanor was archived", :person) do
          {:ok, state} -> {:stop, :normal, state}
          {:error, _reason, state} -> {:stop, :normal, retire_runtime(state)}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp handle_owned_info(%Notify{}, state), do: {:noreply, state}
  defp handle_owned_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp handle_owned_info(:idle, %{live: nil, paused: nil, queue: [], held: held} = state)
       when map_size(held) == 0,
       do: {:stop, :normal, state}

  defp handle_owned_info(:idle, state), do: {:noreply, touch(state)}

  defp handle_owned_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  defp retry_timer(timer, state) do
    Process.send_after(self(), timer, @resume_retry_ms)
    state
  end

  # A turn's end that could not be written, by its loop or here for the
  # refusal it answered, is settled as a loop's that died.
  defp returned(state, {:unwritten, _result}), do: unwritten(state)

  defp returned(%{live: live} = state, {:error, reason} = refused) when reason != :held do
    Logger.warning("[Aqua.Runner] turn #{live.turn_id} did not run: #{inspect(reason)}")

    case write_end(state, live, "failed", describe(reason)) do
      :ok -> {:noreply, after_loop(state, refused)}
      {:error, _unwritten} -> unwritten(state)
    end
  end

  defp returned(state, result), do: {:noreply, after_loop(state, result)}

  defp unwritten(%{live: live} = state),
    do: died(state, Tape.turn(state.ctx, live.turn_id), @unwritten, "uncertain")

  defp after_loop(%{live: live} = state, result) do
    state = recount(%{state | live: nil})

    case result do
      {:paused, reason} ->
        state = %{
          state
          | paused: %{
              turn_id: live.turn_id,
              user_id: live.user_id,
              sent_by: live.sent_by,
              job: live.job,
              agent: live.agent,
              origin: live.origin,
              fence: live.fence,
              reason: reason
            }
        }

        broadcast(state, :turn_paused, %{turn_id: live.turn_id, reason: reason})
        settle_paused(state)

      {:error, :held} ->
        hold_back(state, live.turn_id)

      _ended ->
        start_next(state)
    end
  end

  # The loop died without answering. A turn the rows already show paused
  # committed its stop before the process went: it is picked up as
  # paused and its local cleanup finished here. Otherwise what it left
  # is settled from the rows, the turn ended cancelled when a cancel
  # asked for it and uncertain otherwise. The root's slot went with the
  # process.
  defp crashed(%{live: live} = state, reason) do
    Logger.warning(
      "[Aqua.Runner] turn #{live.turn_id} stopped without an answer: " <>
        Prima.LogFilter.inspect_reason(reason)
    )

    case Tape.turn(state.ctx, live.turn_id) do
      {:ok, %{status: "paused"} = turn} ->
        paused = %{
          turn_id: live.turn_id,
          user_id: live.user_id,
          sent_by: live.sent_by,
          job: live.job,
          agent: live.agent,
          origin: turn.origin,
          fence: live.fence,
          reason: pause_reason(turn)
        }

        state = %{state | live: nil, paused: paused}
        broadcast(state, :turn_paused, %{turn_id: live.turn_id, reason: paused.reason})
        {:noreply, settle_paused(state)}

      read ->
        status = if match?({:cancel_requested, _}, reason), do: "cancelled", else: "uncertain"
        died(state, read, describe(reason), status)
    end
  end

  # Ended under the fence the loop acquired, not the one just read. When
  # that is not written the runner stops and starts nothing behind it.
  defp died(%{live: live} = state, read, reason, status) do
    cancelled =
      with {:ok, turn} <- read,
           do: cancel_turn(state, %{turn | fence: live.fence}, reason, status)

    case cancelled do
      :ok -> {:noreply, state |> retire_turn(live.turn_id) |> start_next()}
      {:error, _reason} -> {:stop, :normal, retire_runtime(state)}
    end
  end

  # A turn ended, by its own loop (`after_loop/2`) or by a stop, a cancel
  # or a crash (`retire_turn/2`): what the latest turn used is told as the
  # rows store it, which a program that counted nothing leaves unknown,
  # never zero. The loop's own counts reached this process before its end
  # did (both sent from the loop's process), so only a usage they did not
  # tell is told again.
  defp recount(state) do
    usage = Tape.usage(state.ctx, state.id)
    if usage != state.usage, do: broadcast(state, :usage, usage)
    %{state | usage: usage}
  end

  # A paused turn: stopped on a call whose outcome is unknown it waits for
  # its sender's next line, unless one is already on the tape past the
  # stop; paused around a launch it continues as its sender.
  defp settle_paused(%{paused: %{turn_id: turn_id} = paused} = state) do
    case Tape.turn(state.ctx, turn_id) do
      {:ok, %{status: "paused", paused_reason: "uncertain"} = turn} ->
        if Tape.steer_pending?(state.ctx, turn),
          do: continue(%{state | paused: nil}, entry_of(paused), :resume),
          else: touch(state)

      {:ok, %{status: "paused"}} ->
        continue(%{state | paused: nil}, entry_of(paused), :resume)

      {:ok, %{status: "running"}} ->
        # The loop is still taking the root back around its launch.
        Process.send_after(self(), {:resume, turn_id}, @resume_retry_ms)
        state

      _ ->
        # Ended meanwhile (a failed pin, a stop): nothing to continue.
        start_next(%{state | paused: nil})
    end
  end

  # ---------------------------------------------------------------------------
  # Cutting turns short
  # ---------------------------------------------------------------------------

  # A workspace thread's work stopped in storage first, all of it at once
  # (`Aqua.Tape.stop_work/2`); then what this runner holds of it, and a
  # page's calls queued here, which the stop refuses. Answers the turns of
  # the crew threads under it, whose runners the caller stops.
  defp stop_work(state, ctx) do
    with {:ok, %{cancelled: cancelled}} <- Tape.stop_work(ctx, state.id),
         {own, elsewhere} = Enum.split_with(cancelled, &(&1.thread_id == state.id)),
         {:ok, stopped} <- stop_entries(state, own) do
      {:reply, {:ok, elsewhere}, drop_pages(stopped, "stopped")}
    else
      # A runtime that could not stop what it held retires; a stop storage
      # refused leaves the runner as it was.
      {:error, reason, held} -> {:stop, :normal, {:error, reason}, retire_runtime(held)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp stop_entries(state, entries) do
    Enum.reduce_while(entries, {:ok, state}, fn %{turn_id: id, steps: steps}, {:ok, state} ->
      case stop_ended(state, id, steps) do
        :ok -> {:cont, {:ok, retire_turn(state, id)}}
        {:error, reason} -> {:halt, {:error, reason, state}}
      end
    end)
  end

  # The turns this runner holds that another writer ended, stopped here
  # as `stop_cancelled/1` stops them: each the store reads ended, or
  # gone with its thread, whose end this runner did not write. The
  # running turn's own loop ends it under the fence it announced, and its
  # result retires it, so the running turn is another's only when the
  # store's fence passed the loop's; a paused or queued turn this runner
  # ends it retires in the handler that ends it, before any announcement
  # of the end reaches it. Answers whether the thread is gone, and
  # whether anything was stopped.
  defp ended_elsewhere(state) do
    held =
      Enum.flat_map([state.live, state.paused], fn
        nil -> []
        entry -> [entry.turn_id]
      end) ++ Map.keys(state.held) ++ Enum.map(state.queue, & &1.turn_id)

    stopped =
      Enum.reduce(held, state, fn id, state ->
        case Tape.turn(state.ctx, id) do
          {:ok, turn} ->
            if another_end?(state, turn),
              do: stop_another(state, turn),
              else: state

          {:error, :not_found} ->
            stop_another(state, %{id: id, steps: []})

          {:error, _unread} ->
            state
        end
      end)

    cond do
      match?({:error, :not_found}, Tape.thread(stopped.ctx, stopped.id)) -> {:gone, stopped}
      stopped == state -> {:kept, state}
      true -> {:stopped, stopped}
    end
  end

  # A stop, a deletion or an archive ends a turn `cancelled`, under a
  # raised fence. The running turn's own loop ends it any other way,
  # before or after announcing its fence: it halts cancelled only on a
  # fence that moved, under which its end never lands. A held turn's
  # holder may end it too, and its exit retires it here.
  defp another_end?(state, turn) do
    cond do
      not Tape.terminal?(turn) -> false
      live?(state, turn.id) -> turn.status == "cancelled" and fence_passed?(state, turn)
      Map.has_key?(state.held, turn.id) -> turn.status == "cancelled"
      true -> true
    end
  end

  defp live?(%{live: %{turn_id: id}}, id), do: true
  defp live?(_state, _id), do: false

  # The loop announces its fence as it starts and as it takes its root;
  # a cancel before any announcement is another writer's.
  defp fence_passed?(%{partials: %{fence: fence}}, turn) when is_integer(fence),
    do: turn.fence > fence

  defp fence_passed?(_state, _turn), do: true

  # What the runner holds of a turn the store ended: its loop and every
  # worker under it, then the child execution and catalog handler of each
  # step the end cancel-marked; a turn gone with its thread has no steps
  # left to read.
  defp stop_another(state, %{steps: []} = gone) do
    case stop_ended(state, gone.id, []) do
      :ok -> retire_turn(state, gone.id)
      {:error, _reason} -> state
    end
  end

  defp stop_another(state, turn) do
    with {:ok, steps} <- Tape.steps(state.ctx, turn),
         :ok <- stop_ended(state, turn.id, Enum.filter(steps, & &1.cancel_requested_at)) do
      retire_turn(state, turn.id)
    else
      _not_stopped -> state
    end
  end

  # The target set belongs to this handler invocation. Retire each local
  # entry only after its durable cancellation succeeds; a later send is
  # processed after this call and opens new work. `by` is who cancelled
  # the turns, which their end names (`Arca.TurnStorage.finish/4`).
  defp cancel_work(state, reason, by) do
    targets =
      Enum.uniq(
        Enum.flat_map([state.live, state.paused], fn
          nil -> []
          entry -> [entry.turn_id]
        end) ++ Map.keys(state.held) ++ Enum.map(state.queue, & &1.turn_id)
      )

    Enum.reduce_while(targets, {:ok, state}, fn id, {:ok, state} ->
      cancelled =
        with :ok <- held(),
             {:ok, turn} <- Tape.turn(state.ctx, id),
             do: cancel_turn(state, turn, reason, "cancelled", by)

      case cancelled do
        :ok -> {:cont, {:ok, retire_turn(state, id)}}
        {:error, error} -> {:halt, {:error, error, state}}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, drop_pages(state, reason)}
      error -> error
    end
  end

  defp cancel_turn(state, %{id: id} = turn, reason, status, by \\ nil) do
    if Tape.terminal?(turn) do
      with {:ok, steps} <- Tape.steps(state.ctx, turn),
           do: stop_ended(state, id, Enum.filter(steps, & &1.cancel_requested_at))
    else
      with {:ok, aborted} <-
             Aqua.Loop.abort(state.ctx, turn, reason, fn ->
               Aqua.Loop.Worker.stop(local_holder(state, id))
             end),
           :ok <- held(),
           {:ok, _} <- Tape.finish(state.ctx, aborted, status, ended(reason, by)) do
        :ok
      else
        {:error, :not_open} -> terminal_target(state, id)
        error -> error
      end
    end
  end

  defp ended(reason, nil), do: %{error: reason}
  defp ended(reason, by), do: %{error: reason, ended_by: by}

  # A turn whose end storage has written, by a cancellation of its thread
  # or a concurrent completion: its loop and every worker under it, then
  # the child execution and catalog handler of each step it had dispatched
  # and storage cancel-marked.
  defp stop_ended(state, id, steps) do
    Aqua.Loop.abort_ended(state.ctx, id, steps, fn ->
      Aqua.Loop.Worker.stop(local_holder(state, id))
    end)
  end

  # A concurrent ordinary completion is already settled. A fence loss is
  # never handled here and never followed by a write under a reread fence.
  defp terminal_target(state, id) do
    case Tape.turn(state.ctx, id) do
      {:ok, turn} ->
        if Tape.terminal?(turn), do: :ok, else: {:error, :not_open}

      error ->
        error
    end
  end

  defp local_holder(%{live: %{turn_id: id, task: task}}, id), do: task.pid
  defp local_holder(state, id), do: get_in(state.held, [id, :pid])

  defp retire_turn(state, id) do
    if match?(%{turn_id: ^id}, state.live), do: Process.demonitor(state.live.task.ref, [:flush])

    if held = state.held[id], do: Process.demonitor(held.ref, [:flush])

    state = %{
      state
      | live: if(match?(%{turn_id: ^id}, state.live), do: nil, else: state.live),
        paused: if(match?(%{turn_id: ^id}, state.paused), do: nil, else: state.paused),
        held: Map.delete(state.held, id),
        queue: Enum.reject(state.queue, &(&1.turn_id == id))
    }

    broadcast(state, :queued, length(state.queue))
    state |> recount() |> touch()
  end

  defp retire_runtime(state) do
    if state.live, do: Aqua.Loop.Worker.stop(state.live.task.pid)
    state
  end

  # `by` names who cancelled it: `:recovery` for a turn the server can
  # neither resume nor start for its sender, which its workspace thread
  # reads as an error.
  defp end_turn(state, entry, status, error, by \\ nil) do
    _ = write_end(state, entry, status, error, by)
    touch(state)
  end

  # The entry's fence is the loop's: only a take raises one, and a turn
  # taken since is its taker's to end.
  defp write_end(state, %{turn_id: id, fence: fence}, status, error, by \\ nil) do
    turn = %{id: id, thread_id: state.id, fence: fence}

    case Tape.finish(state.ctx, turn, status, ended(error, by)) do
      {:error, reason} when reason not in @taken ->
        Logger.warning("[Aqua.Runner] turn #{id} not ended: #{inspect(reason)}")
        {:error, reason}

      _ended_or_anothers ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Recovery
  # ---------------------------------------------------------------------------

  defp recover(state) do
    with {:ok, actions} <- RecoveryTable.plan(state.ctx, state.id) do
      {:ok, Enum.reduce(actions, state, &recover_one/2)}
    end
  end

  defp recover_one(action, state) do
    case orphaned(action, state) do
      {:skip, state} -> state
      state -> recovered(action, state)
    end
  end

  # What a predecessor runner held of a page's calls died with it.
  defp orphaned({:queue, turn}, state) do
    if opened_on_call?(state, turn),
      do:
        {:skip, end_turn(state, %{turn_id: turn.id, fence: turn.fence}, "cancelled", @orphaned)},
      else: state
  end

  defp orphaned({mode, turn}, state) when mode in [:wait, :continue, :adopt] do
    with {:ok, steps} <- Tape.steps(state.ctx, turn),
         [_ | _] = ids <-
           for(%{purpose: "page", dispatch_state: "proposed", id: id} <- steps, do: id) do
      _ = Tape.skip_steps(state.ctx, turn, @orphaned, ids)
    end

    state
  end

  defp orphaned(_action, state), do: state

  defp opened_on_call?(state, %{message_id: id}) when is_binary(id),
    do: match?({:ok, %{kind: "page_call"}}, Tape.message(state.ctx, id))

  defp opened_on_call?(_state, _turn), do: false

  defp recovered(action, state) do
    case action do
      {:queue, turn} ->
        entry = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          sent_by: turn.sent_by,
          job: job_of(turn),
          ctx: nil,
          agent: turn.agent,
          origin: turn.origin,
          fence: turn.fence
        }

        recovered_start(state, entry)

      {:wait, turn} ->
        paused = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          sent_by: turn.sent_by,
          job: job_of(turn),
          agent: turn.agent,
          origin: turn.origin,
          fence: turn.fence,
          reason: pause_reason(turn)
        }

        settle_paused(%{state | paused: paused})

      {:continue, turn} ->
        entry = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          sent_by: turn.sent_by,
          job: job_of(turn),
          ctx: nil,
          agent: turn.agent,
          origin: turn.origin,
          fence: turn.fence
        }

        if busy?(state),
          do: %{state | queue: state.queue ++ [entry]},
          else: continue(state, entry, :resume)

      {:adopt, turn} ->
        entry = %{
          turn_id: turn.id,
          user_id: turn.requested_by,
          sent_by: turn.sent_by,
          job: job_of(turn),
          ctx: nil,
          agent: turn.agent,
          origin: turn.origin,
          fence: turn.fence
        }

        if busy?(state),
          do: %{state | queue: state.queue ++ [entry]},
          else: continue(state, entry, :adopt)

      {:held, turn, holder} ->
        %{
          state
          | held: Map.put(state.held, turn.id, %{pid: holder, ref: Process.monitor(holder)})
        }

      {:uncertain, turn, why} ->
        give_up(state, turn, why)
    end
  end

  # A turn recovery cannot continue is aborted from the fence it was read
  # with and ended under the fence the abort raised. A fence that moved in
  # between belongs to whoever moved it, and the turn is left to them.
  defp give_up(state, turn, why) do
    with {:ok, aborted} <- Aqua.Loop.abort(state.ctx, turn, why),
         {:ok, _ended} <- Tape.finish(state.ctx, aborted, "uncertain", %{error: why}) do
      touch(state)
    else
      {:error, reason} ->
        Logger.warning("[Aqua.Runner] turn #{turn.id} not ended: #{inspect(reason)}")
        touch(state)
    end
  end

  # A loop refused a turn another process on this boot holds: the turn
  # waits for that holder like one found at start.
  defp hold_back(state, turn_id) do
    case Aqua.Loop.holder(turn_id) do
      nil ->
        recover_held(%{state | held: Map.put(state.held, turn_id, nil)}, turn_id)

      holder ->
        %{
          state
          | held: Map.put(state.held, turn_id, %{pid: holder, ref: Process.monitor(holder)})
        }
    end
  end

  # A held turn whose holder is gone, planned again from its row. When the
  # rows cannot be read, retry later and keep the turns behind it waiting.
  defp recover_held(state, turn_id) do
    state = %{state | held: Map.put(state.held, turn_id, nil)}

    case RecoveryTable.plan_turn(state.ctx, state.id, turn_id) do
      {:ok, actions} ->
        state = %{state | held: Map.delete(state.held, turn_id)}
        state = Enum.reduce(actions, state, &recover_one/2)
        if busy?(state), do: touch(state), else: start_next(state)

      _unreadable ->
        retry_timer({:recover, turn_id}, state)
    end
  end

  defp pause_reason(%{paused_reason: "launch"}), do: :launch
  defp pause_reason(%{paused_reason: "uncertain"}), do: :uncertain

  # A queued turn recovered from its row runs as its sender's
  # continuation, under the origin its row stores; one that cannot is
  # cancelled with its reason, and the turns behind it go on.
  defp recovered_start(state, entry) do
    if busy?(state) do
      %{state | queue: state.queue ++ [entry]}
    else
      case Sanctum.Tenancy.continuation(entry.user_id, state.athanor_id, entry.origin) do
        {:ok, actor} ->
          start(state, %{entry | ctx: actor})

        {:error, reason} ->
          state
          |> end_turn(entry, "cancelled", unresumable(reason), :recovery)
          |> start_next()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # A page's calls
  # ---------------------------------------------------------------------------

  defp answering(state, call) do
    answering = %{user_id: call.user_id, monitor: Process.monitor(call.browser)}
    %{state | answering: Map.put(state.answering, call.request, answering)}
  end

  defp unanswering(state, request) do
    case Map.pop(state.answering, request) do
      {nil, _answering} ->
        state

      {%{monitor: monitor}, answering} ->
        Process.demonitor(monitor, [:flush])
        %{state | answering: answering}
    end
  end

  # A page's call whose request ended, or whose browser is gone: dropped
  # while it waits, its step withdrawn while still proposed.
  defp ended_call(state, request) do
    case Enum.split_with(state.pages, &(&1.request == request)) do
      {[_ended], pages} ->
        unanswering(%{state | pages: pages}, request)

      {[], _pages} ->
        state =
          if Map.has_key?(state.answering, request), do: withdraw(state, request), else: state

        unanswering(state, request)
    end
  end

  # The waiting calls become steps of the running turn, in order, and its
  # loop is told. A turn that is not running takes none, nor one whose
  # loop has not announced its fence yet: they wait. A step is written
  # under the fence the loop announced, never one read since, so a turn
  # another holder took writes none.
  defp propose(%{live: %{turn_id: turn_id}, partials: %{fence: fence}, pages: [_ | _]} = state)
       when is_integer(fence) do
    with {:ok, %{status: "running"} = turn} <- Tape.turn(state.ctx, turn_id) do
      {pages, proposed?, state} = propose_all(state, %{turn | fence: fence}, state.pages, false)

      if proposed?, do: moved(turn.id)

      %{state | pages: pages}
    else
      _not_running -> state
    end
  end

  defp propose(state), do: state

  # The thread moved: the loop of every turn this runner runs, waits on or
  # finds held by another process on this boot is told, and says to its
  # harness what it is owed (`Aqua.Loop`).
  defp told(state) do
    for %{turn_id: turn_id} <- [state.live, state.paused], is_binary(turn_id), do: moved(turn_id)
    for {turn_id, _holder} <- state.held, do: moved(turn_id)
    :ok
  end

  defp moved(turn_id) do
    with pid when is_pid(pid) <- Aqua.Loop.holder(turn_id), do: send(pid, {:moved, turn_id})
  end

  defp propose_all(state, _turn, [], proposed?), do: {[], proposed?, state}

  defp propose_all(state, turn, [call | rest] = pages, proposed?) do
    proposal = Aqua.PageCalls.proposal(turn, Aqua.PageCalls.row(call))

    case Tape.propose_call(state.ctx, turn, proposal) do
      {:ok, _step} -> propose_all(state, turn, rest, true)
      {:error, :illegal_transition} -> {pages, proposed?, state}
      {:error, reason} -> state |> refuse_call(call, reason) |> propose_all(turn, rest, proposed?)
    end
  end

  # A turn of its own for a call with no turn to join: it asks no model,
  # and runs as the person whose turn put the page, under that turn's
  # origin.
  defp open_call(state, call) do
    with true <- Opus.available?() || {:error, :execution_unavailable},
         {:ok, put} <- Tape.turn(state.ctx, call.put_turn_id),
         {:ok, actor} <-
           Sanctum.Tenancy.continuation(put.requested_by, state.athanor_id, put.origin),
         {:ok, %{turn: turn}} <-
           Tape.accept(actor, state.id, %{
             message: %{
               author: Prima.Author.agent(),
               sent_by: put.agent,
               kind: "page_call",
               content: call.name,
               payload: Aqua.PageCalls.row(call),
               client_id: call.request
             },
             turn: %{
               agent: put.agent,
               requested_by: put.requested_by,
               model: put.model,
               options: put |> options_of() |> Map.delete("schedule")
             }
           }) do
      entry = %{
        turn_id: turn.id,
        user_id: put.requested_by,
        sent_by: turn.sent_by,
        job: job_of(turn),
        ctx: actor,
        agent: put.agent,
        origin: turn.origin,
        fence: turn.fence
      }

      {:ok, start(state, entry)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp options_of(%{options: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = options} -> options
      _ -> %{}
    end
  end

  defp options_of(_turn), do: %{}

  # A page's calls waiting here are queued work like any turn: what cuts
  # the turns drops them, each answered with its reason.
  defp drop_pages(state, reason),
    do: %{Enum.reduce(state.pages, state, &refuse_call(&2, &1, reason)) | pages: []}

  defp refuse_call(state, call, reason) do
    {status, body} =
      Aqua.PageCalls.answered(%{content: describe(reason), payload: %{"skipped" => true}})

    Opus.Browser.answer(state.athanor_id, call.user_id, call.request, status, body)
    unanswering(state, call.request)
  end

  defp answer(state, row) do
    payload = Tape.payload(row)
    request = payload["tool_call_id"]

    case Map.fetch(state.answering, request) do
      {:ok, %{user_id: user_id}} ->
        {status, body} = Aqua.PageCalls.answered(%{content: row.content, payload: payload})
        Opus.Browser.answer(state.athanor_id, user_id, request, status, body)
        unanswering(state, request)

      :error ->
        state
    end
  end

  # A turn ended: a call it held that no row answered is answered as
  # cancelled; the calls still waiting here are not its.
  defp answer_ended(state) do
    waiting = MapSet.new(state.pages, & &1.request)

    Enum.reduce(state.answering, state, fn {request, %{user_id: user_id}}, state ->
      if MapSet.member?(waiting, request) or state.paused != nil do
        state
      else
        refuse_call(
          state,
          %{request: request, user_id: user_id},
          "the turn ended before the call ran"
        )
      end
    end)
  end

  # A request that ended: no step of it is recorded or dispatched from
  # now on, and its step still proposed is skipped, which the tape
  # announces to no runner: a paused turn whose step it skipped is
  # settled here.
  defp withdraw(state, request) do
    with {:ok, %{turn_id: turn_id, skipped: [_ | _]}} <-
           Tape.end_call(state.ctx, state.id, request, "the page's request ended"),
         %{paused: %{turn_id: ^turn_id}} <- state do
      settle_paused(state)
    else
      _ -> state
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp public_state(state) do
    current = state.live || state.paused

    %{
      running: state.live != nil,
      paused: state.paused != nil,
      paused_reason: state.paused && state.paused.reason,
      athanor_id: state.athanor_id,
      turn_id: current && current.turn_id,
      # A viewer joining draws what a live pane draws, which clears a
      # turn's text and calls when it hears the turn end or pause.
      partials: if(state.live, do: state.partials, else: Aqua.Loop.Stream.new()),
      tool_activity: if(state.live, do: state.tool_activity, else: []),
      usage: state.usage,
      agent: state.agent && %{"name" => state.agent, "title" => state.agent},
      turn_user: current && current.user_id,
      queued: length(state.queue)
    }
  end

  defp broadcast(state, kind, data), do: Tape.announce(state.ctx, state.id, kind, data)

  defp touch(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)
    %{state | idle_ref: Process.send_after(self(), :idle, @idle_ms)}
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: Aqua.Ops.render_refusal(reason)
end
