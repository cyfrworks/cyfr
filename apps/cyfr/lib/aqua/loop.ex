# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop do
  @moduledoc """
  The agent loop: one turn, run by the process that holds its root.

  A round drains the steer, projects the tape, plans the request (a
  compaction first when the window is full, preceded by a note flush when
  the agent keeps notes without asking), records the model call
  before making it, makes it in a worker, persists the whole response
  before any of its calls runs, and dispatches the calls: each is
  decided under the member's mode (`Aqua.Loop.Policy`) and nothing is
  asked, a refusal is closed as its own result, reads run beside each
  other and everything else alone, each in a worker of its own. A round
  with no calls ends the turn. The first call a read-only member is
  refused in a turn also writes that sentence once as a line in the
  thread. A launch stands on its component's grant: `Aqua.Launch`
  consumes it while the root is paused around it, so the application
  takes a root of its own, and holds it to what the decision read; the
  pause ends when the launch does, and a continuation resumes the turn
  from the rows. A launch naming an account its
  app's own profile does not bind ends the turn as setup required, naming
  the app and the account: the person grants it there, and the retry is a
  new turn, since this one's authority never widens.

  Every write goes through `Aqua.Tape` under the actor's guest-planed
  context; the loop process never runs a child on itself.

  ## A scheduled turn

  A turn a schedule's line started (origin `schedule`, `Aqua.ScheduleTurns`)
  runs as any turn of its member's mode. A refused call is no question,
  so the turn goes on without it.

  ## The turn's read threads

  Every way a turn reads a thread's posts joins that thread to the turn's
  read threads (`turns.read_threads`) in the transaction that writes the
  step it belongs to, so deleting a thread finds every turn that read it.
  A model step opens with the read threads of every earlier turn whose
  rows the request sends, compaction summaries among them, and each other
  thread whose posts its rows bring in (a workspace thread's pointer or
  report, the daily thread an opening refers to), with the read threads a
  report kept of the turn that reported, those of the turns that wrote
  the posts an opening refers to, and those every copied file carries
  from the post it came from; a call's result closes with the threads it
  carries (`Aqua.Loop.Policy.threads_of/3`). The room excerpt is the
  athanor's own members' words and joins nothing.

  A model, hand or launched child's read threads join its turn when its
  step closes, before anything of its answer is used — a model's before
  its reply, its calls, a kept note or a summary is written, a hand's and
  a launch's in the transaction that writes the step's result. They
  arrive by the first carrier that holds them: the completion result's
  `read_threads`, as the child's terminal write left them; else the
  child's row, read by the id the loop minted for it. A row no longer held
  or unreadable adds none. A join that cannot be written leaves the answer
  unused.

  `Aqua.Launch` seeds a launched root with the turn's read threads as its
  row holds them when the launch is dispatched.
  """

  require Logger

  alias Aqua.Loop.Binding
  alias Aqua.Loop.Binding.Call
  alias Aqua.Loop.{Planner, Policy, Request, Turn}
  alias Aqua.Tape
  alias Sanctum.Context

  # A root turn's holder on this boot registers here (`holder/1`).
  @holders Aqua.RunnerRegistry
  @max_steps 30
  @retry_delays_ms [2_000, 8_000, 20_000]
  # `{"operation":"chat","params":}` around the request, which is what
  # `Opus.Admission` encodes and weighs against the node's cap.
  @envelope_bytes 30
  @resume_backoff_ms [500, 2_000, 8_000]
  # A retry opens a new step at a higher ordinal, and the refused step is
  # abandoned, so text a refused step streamed is withdrawn, never shown
  # beside the retry's (`Aqua.Loop.Stream`).
  @recoverable ~w(rate_limited overloaded incomplete_stream)
  @aborted_content "a call's outcome is unknown; tools may have partially executed"
  # A refusal for want of a key bound to the brain asks the person for its
  # consent; a key the provider refused (`authentication`) is the
  # provider's to say, as a line in the thread, since the grant would bind
  # the same key again.
  @setup ~w(secret_denied)
  @refused_key "authentication"
  # The refusal of a session the brain no longer holds (`Prima.Model`). A
  # step the turn forgot its thread's session on closes with this type as
  # its error, as a retried step closes with its own, so a continued turn
  # reads from its steps that it forgot one (`forgot_session?/1`).
  @session_gone "unknown_session"
  # A note flush offers this action alone, and keeps a note this large at most.
  @flush_tool "notes"
  @flush_action "keep"
  @flush_key "#{@flush_tool}.#{@flush_action}"
  @flush_note_max_bytes 64 * 1024
  @flush_instruction "The older part of this thread is about to be summarized, and what " <>
                       "the summary leaves out will be gone. Keep anything worth remembering " <>
                       "beyond it — a decision, a preference, a fact the work will need — with " <>
                       "notes.keep now. Reply with nothing else."

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :spec,
      :claim,
      :turn,
      # The brain's session for the thread, as its last response named it.
      :session,
      # The thread's session generation the turn keeps a session under: as
      # the turn was built, so a forget since (a reset program home) keeps
      # out what the brain answers with, or as the turn's own forget raised
      # it (`Arca.TurnStorage`).
      :generation,
      # The turn forgot its thread's session once, on its brain's word that
      # the session was gone: the next such refusal ends it. A continued
      # turn reads it from its steps, as it reads their count (`settle/1`).
      forgot_session?: false,
      steps: 0,
      usage: %{input: 0, output: 0},
      activity: [],
      since: nil,
      active_ms: 0,
      observed: nil,
      # The highest seq the measured request carried, so rows appended since
      # can be counted. A bare token count says nothing about which rows it
      # was a count of.
      observed_seq: 0,
      sent_upto: 0,
      excerpt_sent?: false,
      # A call's outcome is unknown: only replay-safe reads run from here.
      restricted?: false,
      # The turn's line that its member is read-only was written: once per
      # turn, and once across a continuation by the line's own id
      # (`say_read_only/2`).
      read_only_said?: false,
      # Whether the next round asks the model: not once its answer called
      # nothing, so a page's call proposed after it runs and the turn ends
      # without asking again, and never in a turn opened on a page's call.
      model?: true,
      # The program row a program brain runs on (`Aqua.Loop.Turn`), whose
      # session `Aqua.Program` attends: such a turn asks no model, has no
      # deadline and no step cap.
      program: nil
    ]
  end

  @type result ::
          :completed
          | {:paused, :launch | :uncertain}
          | {:failed, term()}
          | :cancelled
          | {:uncertain, term()}

  # ---------------------------------------------------------------------------
  # Entry points
  # ---------------------------------------------------------------------------

  @doc """
  Run an accepted turn as its root: claim the root on this process,
  start the turn with its pins, and loop. `opts`: `:ctx` (the actor's
  external-plane context), `:turn_id`. Ends the turn itself on every
  outcome but a pause. A turn another process on this boot holds is
  refused `{:error, :held}` before anything is read (`holder/1`).
  """
  @spec run(keyword()) :: result() | {:error, term()}
  def run(opts) do
    ctx = Keyword.fetch!(opts, :ctx)
    turn_id = Keyword.fetch!(opts, :turn_id)

    hold(turn_id, fn ->
      with {:ok, turn} <- Tape.turn(ctx, turn_id) do
        case claim_and_start(ctx, turn) do
          {:ok, state} ->
            Aqua.Loop.Stream.announce_fence(state.spec.guest, state.turn)

            case open_call(state) do
              {:ok, state} -> conclude(state, loop(state))
              {:error, :superseded} -> conclude(state, {:cancelled, state})
              {:error, reason} -> conclude(state, {{:failed, reason}, state})
            end

          {:error, {:after_claim, claim, turn, reason}} ->
            never_ran(ctx, claim, turn, reason)

          # The source has no consent to run under: the person is asked for it.
          {:error, :no_profile} ->
            setup_required(ctx, turn)

          {:error, {:profile_unavailable, _}} ->
            setup_required(ctx, turn)

          {:error, reason} ->
            reason = unclaimed(ctx, turn, reason)
            say_unrun(ctx, turn, reason)
            _ = Tape.finish(ctx, turn, "failed", %{error: describe(reason)})
            {:failed, reason}
        end
      end
    end)
  end

  # Why a root was not claimed, as the person can act on it. A soul whose
  # file is refused has no registry row (`Compendium.AgentIndex` indexes
  # only what parses), so its root is refused as an unknown component
  # before the file is read: the soul's own refusal is the reason then,
  # and a file still holding the retired `tool_policy`, or a `tools`
  # entry that names no one action, gets its line.
  defp unclaimed(ctx, %{agent: agent}, reason) do
    with true <- Prima.AgentRef.soul?(agent),
         {:ok, _roster, refused} <- Aqua.AgentConfig.roster_and_soul(ctx),
         true <- soul_line?(refused) do
      refused
    else
      _other -> reason
    end
  end

  defp soul_line?(:tool_policy_retired), do: true
  defp soul_line?({:tools_invalid_entry, _entry}), do: true
  defp soul_line?(_refused), do: false

  # The root is held but the turn never ran: ended with the actor's own
  # context, since no spec was built to carry it, and the root closed by
  # the release when the turn never came to carry it. A model its catalyst
  # could not describe for want of a key asks the person for the
  # catalyst's consent.
  defp never_ran(ctx, claim, turn, reason) do
    case needs_setup(reason) do
      nil ->
        say_unrun(ctx, turn, reason)
        end_unrun(ctx, claim, turn, describe(reason))
        {:failed, reason}

      catalyst ->
        end_unrun(ctx, claim, turn, "setup_required")

        Tape.announce(ctx, turn.thread_id, :consent_required, %{
          ref: catalyst,
          user_id: ctx.user_id
        })

        {:failed, :setup_required}
    end
  end

  # A turn that never ran says why in the thread where the person can act
  # on it: a brain whose provider refused its key, in the provider's
  # words, and a member whose file still holds the retired `tool_policy`
  # or a `tools` entry that names no one action, in the sentence that
  # says what to change.
  defp say_unrun(ctx, turn, {:model_refused, _catalyst, %{"type" => @refused_key} = error}),
    do: unrun_line(ctx, turn, refused_key_line(error))

  defp say_unrun(ctx, turn, :tool_policy_retired),
    do: unrun_line(ctx, turn, Prima.AgentRef.tool_policy_retired())

  defp say_unrun(ctx, turn, {:tools_invalid_entry, _entry} = reason),
    do: unrun_line(ctx, turn, describe(reason))

  defp say_unrun(ctx, turn, {:read_only_unheld, _title, _brain} = reason),
    do: unrun_line(ctx, turn, describe(reason))

  defp say_unrun(_ctx, _turn, _reason), do: :ok

  defp unrun_line(ctx, turn, line) do
    Tape.append(ctx, turn.thread_id, %{
      author: Prima.Author.system(),
      sent_by: turn.agent,
      kind: "system",
      content: line,
      turn_id: turn.id,
      execution_id: turn.root_execution_id
    })
  end

  defp refused_key_line(%{"message" => message}) when is_binary(message),
    do: "The model refused its key: #{message}"

  defp refused_key_line(_error), do: "The model refused its key."

  defp end_unrun(ctx, claim, turn, error) do
    Opus.suspend_lease_watch(claim.keeper)
    _ = Tape.finish(ctx, turn, "failed", %{error: error})
    Opus.release_turn_root(ctx, claim.execution_id, claim: claim, failed: error)
  end

  defp needs_setup({:setup_required, catalyst}), do: catalyst

  defp needs_setup({:model_refused, catalyst, %{"type" => type}}) when type in @setup,
    do: catalyst

  defp needs_setup(_reason), do: nil

  defp setup_required(ctx, turn) do
    _ = Tape.finish(ctx, turn, "failed", %{error: "setup_required"})

    Tape.announce(ctx, turn.thread_id, :consent_required, %{
      ref: source_ref(turn),
      user_id: ctx.user_id
    })

    {:failed, :setup_required}
  end

  @doc """
  Continue a turn on this process: `:resume` a paused turn (the root is
  taken back first; a refusal leaves it paused), or `:adopt` a running
  turn whose successor attempt a takeover already opened. `opts`: `:ctx`,
  `:turn_id`, `:mode`. Open steps are settled before the loop goes on. A
  turn another process on this boot holds is refused `{:error, :held}`
  before anything is read (`holder/1`).
  """
  @spec run_nested(keyword()) :: result() | {:error, term()}
  def run_nested(opts) do
    ctx = Keyword.fetch!(opts, :ctx)
    mode = Keyword.get(opts, :mode, :resume)
    turn_id = Keyword.fetch!(opts, :turn_id)

    hold(turn_id, fn ->
      with {:ok, turn} <- Tape.turn(ctx, turn_id),
           {:ok, claim, turn} <- reclaim(ctx, turn, mode),
           {:ok, authority} <- pinned_authority(ctx, turn),
           {:ok, spec} <-
             Turn.build(ctx, turn,
               authority: authority,
               excerpt?: false,
               asks_model?: asks_model?(ctx, turn)
             ),
           {:ok, turn} <- pin_brain(ctx, turn, spec) do
        spec = Turn.with_turn(spec, turn)

        state = %State{
          spec: spec,
          program: spec.program,
          claim: claim,
          turn: turn,
          session: spec.thread.brain_session,
          generation: spec.thread.brain_generation,
          since: now(),
          active_ms: turn.active_ms
        }

        Aqua.Loop.Stream.announce_fence(spec.guest, turn)

        case settle(state) do
          {:continue, state} -> conclude(state, loop(state))
          {:halt, result, state} -> conclude(state, {result, state})
        end
      end
    end)
  end

  @doc """
  The process on this boot that holds the root turn `turn_id`, or nil. A
  loop holds its turn from the moment `run/1` or `run_nested/1` is entered
  until it returns or its process ends; the pid answered may already be
  exiting, and a monitor on it says when it has.
  """
  @spec holder(String.t()) :: pid() | nil
  def holder(turn_id) when is_binary(turn_id) do
    case Registry.lookup(@holders, {:turn, turn_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # The hold is let go before the result is returned, so the process that
  # awaits this loop can start the turn's next loop at once.
  defp hold(turn_id, fun) do
    key = {:turn, turn_id}

    case Registry.register(@holders, key, nil) do
      {:ok, _} ->
        try do
          fun.()
        after
          Registry.unregister(@holders, key)
        end

      {:error, {:already_registered, _holder}} ->
        {:error, :held}
    end
  end

  @doc """
  Abort a turn from outside its process: the fence of the turn is raised;
  then `stop` is called, with which the caller stops the turn's process if
  one still runs, and with it every worker under it
  (`Aqua.Loop.Worker`); then the dispatched steps of the turn are
  cancel-marked, every child execution and every in-process catalog
  handler is cancelled, dispatched steps settle by
  `Prima.TurnStep.unresolved/1` — a call whose effect is unknown is
  marked `uncertain`, since a cancel does not prove the effect never
  happened — unstarted steps are skipped, and the aborted mark is
  written. The caller then ends the turn.

  `stop` runs after the fence is raised and before any child is cancelled,
  since a cancelled child answers the call waiting on it. The local holder
  and its workers are confirmed stopped before settlement. A failed fence,
  shutdown or storage transition is returned to the caller.
  """
  @spec abort(Context.t(), Tape.turn(), String.t(), (-> term())) ::
          {:ok, Tape.turn()} | {:error, term()}
  def abort(%Context{} = ctx, turn, reason, stop \\ fn -> :ok end) when is_function(stop, 0) do
    guest = Context.enter_guest(ctx)
    holder = holder(turn.id)

    with :ok <- held(),
         {:ok, superseded} <- Tape.supersede(guest, turn),
         :ok <- close_program(ctx, turn),
         :ok <- stop_aborted(stop, holder),
         :ok <- held(),
         :ok <- settle_aborted(ctx, superseded, reason),
         {:ok, _} <- Tape.append_aborted(guest, superseded, reason) do
      {:ok, superseded}
    end
  end

  @doc """
  Stop what still runs of a turn storage has already ended, as an archive
  or a room's deletion ends it (`Arca.TurnStorage.cancel_open!/4`): `stop`
  and the turn's holder on this boot as `abort/4` stops them, then the
  child execution and the in-process catalog handler of each step in
  `steps`, the ones it had dispatched. Storage settled those steps and
  wrote the end; nothing here writes the turn. The first failure is
  answered after every step was tried.
  """
  @spec abort_ended(Context.t(), String.t(), [map()], (-> term())) :: :ok | {:error, term()}
  def abort_ended(%Context{} = ctx, turn_id, steps, stop \\ fn -> :ok end)
      when is_binary(turn_id) and is_list(steps) and is_function(stop, 0) do
    with :ok <- close_program_of(ctx, turn_id),
         :ok <- stop_aborted(stop, holder(turn_id)) do
      Enum.reduce(steps, :ok, fn step, result ->
        case cancel_dispatched(ctx, %{id: turn_id}, step) do
          :ok -> result
          error -> if result == :ok, do: error, else: result
        end
      end)
    end
  end

  # A program brain's session ends before anything of its turn stops, so
  # it is written nothing after the fence moved: Stop closes the session.
  defp close_program(%Context{} = ctx, %{program: row} = turn) when is_binary(row),
    do: Aqua.Program.close(ctx.athanor_id, turn.thread_id, turn.agent)

  defp close_program(_ctx, _turn), do: :ok

  defp close_program_of(ctx, turn_id) do
    case Tape.turn(Context.enter_guest(ctx), turn_id) do
      {:ok, turn} -> close_program(ctx, turn)
      {:error, _gone} -> :ok
    end
  end

  defp stop_aborted(stop, holder) do
    case stop.() do
      {:error, _} = error -> error
      _ -> Aqua.Loop.Worker.stop(holder)
    end
  end

  defp settle_aborted(ctx, turn, reason) do
    guest = Context.enter_guest(ctx)

    with :ok <- held(),
         {:ok, steps} <- Tape.steps(guest, turn),
         :ok <- settle_aborted_steps(ctx, turn, steps, reason),
         {:ok, _} <- Tape.skip_steps(guest, turn, reason) do
      :ok
    end
  end

  defp settle_aborted_steps(ctx, turn, steps, reason) do
    steps
    |> Enum.filter(&(&1.dispatch_state == "dispatched"))
    |> Enum.reduce_while(:ok, fn step, :ok ->
      with :ok <- held(),
           :ok <- cancel_dispatched(ctx, turn, step) do
        guest = Context.enter_guest(ctx)

        result =
          case Prima.TurnStep.unresolved(step) do
            :uncertain -> Tape.mark_uncertain(guest, turn, step, reason)
            :unknown -> Tape.close_step(guest, turn, step, "uncertain", %{error: reason})
            _ -> Tape.close_step(guest, turn, step, "error", %{error: reason})
          end

        case result do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        error -> {:halt, error}
      end
    end)
  end

  # The child a stopped or settled step's run is cancelled by. A launched
  # app is a root of its own, run as the turn's person: its row carries
  # the step's id so the step's close can read its read threads, and the
  # turn's end cancels nothing it started.
  defp cancellable(%{kind: "launch"}), do: nil
  defp cancellable(%{child_execution_id: id}), do: id

  # What runs for a dispatched step outside the turn's own process: its
  # child execution and its in-process catalog handler.
  defp cancel_dispatched(ctx, turn, step) do
    with :ok <- cancel_aborted_child(ctx, cancellable(step)) do
      Aqua.Ops.cancel_call(handle(turn, step))
      :ok
    end
  end

  defp cancel_aborted_child(_ctx, nil), do: :ok

  defp cancel_aborted_child(ctx, id) do
    case Opus.cancel(ctx, id) do
      {:ok, _} -> :ok
      {:error, reason} when reason in [:not_found, :not_cancellable] -> :ok
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Claiming
  # ---------------------------------------------------------------------------

  defp claim_and_start(ctx, turn) do
    with {:ok, claim} <-
           Opus.claim_turn_root(
             ctx,
             source_ref(turn),
             [turn_id: turn.id, thread_id: turn.thread_id, envelope: %{"turn" => turn.id}] ++
               fire_of(turn)
           ) do
      with {:ok, snapshot} <- Compendium.agent_snapshot(ctx, turn.agent),
           :ok <- consented_release(claim.authority, turn, snapshot),
           {:ok, started} <-
             Tape.start_turn(ctx, turn, %{
               root_execution_id: claim.execution_id,
               attempt: claim.attempt,
               budget_id: claim.budget_id,
               profile_id: claim.authority.profile_id,
               consent_id: claim.authority.consent_id,
               agent_revision_digest: snapshot.revision_digest,
               agent_capability_digest: snapshot.capability_digest,
               agent_mode: snapshot.agent.mode,
               recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
             }),
           # A server's line that no longer stands as its turn first starts
           # asks no model: the turn ends with nothing run. A store that
           # cannot say ends it as any store failure after the claim does.
           {:ok, stands?} <- Tape.line_stands(ctx, started),
           {:ok, spec} <-
             Turn.build(ctx, started,
               authority: claim.authority,
               asks_model?: stands? and asks_model?(ctx, started)
             ),
           {:ok, started} <- pin_brain(ctx, started, spec) do
        {:ok,
         %State{
           model?: stands?,
           program: spec.program,
           spec: Turn.with_turn(spec, started),
           claim: claim,
           turn: started,
           session: spec.thread.brain_session,
           generation: spec.thread.brain_generation,
           since: now(),
           active_ms: started.active_ms
         }}
      else
        {:error, reason} -> {:error, {:after_claim, claim, turn, reason}}
      end
    end
  end

  # The brain the turn runs on, pinned once: its program row, or its
  # catalyst release.
  defp pin_brain(ctx, turn, %Turn{program: %{row: row}}), do: Tape.pin_program(ctx, turn, row)
  defp pin_brain(ctx, turn, %Turn{catalyst: catalyst}), do: Tape.pin_catalyst(ctx, turn, catalyst)

  # A schedule's turn admits its root as that schedule's fire, which starts
  # its occurrence (`Opus.TurnRoot`).
  defp fire_of(turn) do
    case Tape.schedule_of(turn) do
      %{schedule_id: schedule_id, occurrence_id: occurrence_id} ->
        [schedule_id: schedule_id, occurrence_id: occurrence_id]

      nil ->
        []
    end
  end

  defp reclaim(ctx, turn, :resume) do
    case Opus.resume_turn_root(ctx, turn.root_execution_id,
           turn_id: turn.id,
           fence: turn.fence
         ) do
      {:ok, %{turn: resumed} = claim} -> {:ok, claim, resumed}
      {:error, _} = error -> error
    end
  end

  defp reclaim(ctx, turn, :adopt) do
    with {:ok, claim} <-
           Opus.adopt_turn_root(ctx, turn.root_execution_id, attempt: turn.attempt) do
      {:ok, claim, turn}
    end
  end

  # The turn's pinned authority, loaded again: the profile at its head
  # must still be at the pinned consent, and the budget is the turn's
  # reservation.
  defp pinned_authority(ctx, %{profile_id: profile_id} = turn) when is_binary(profile_id) do
    case Opus.authority_for(ctx, {:id, profile_id}, source_ref(turn), budget_id: turn.budget_id) do
      {:ok, %{consent_id: consent_id} = authority} when consent_id == turn.consent_id ->
        {:ok, authority}

      {:ok, _moved} ->
        {:error, :consent_moved}

      {:error, _} = error ->
        error
    end
  end

  defp pinned_authority(_ctx, _turn), do: {:error, :no_pin}

  # The source a turn runs as: the soul, or the crew member it runs.
  defp source_ref(%{agent: name}) do
    if Prima.AgentRef.soul?(name),
      do: Prima.AgentRef.soul_ref(),
      else: Prima.AgentRef.ref(name)
  end

  # The file the turn pins must be the release the loaded consent names
  # for its own node; a file edited past its consent is refused, never
  # run under the old grant.
  defp consented_release(%{activation: activation}, turn, %{agent: agent}) do
    consented = Map.get(activation, source_ref(turn))

    if is_binary(consented) and consented == Compendium.agent_row(agent).release_digest,
      do: :ok,
      else: {:error, :agent_changed}
  end

  # ---------------------------------------------------------------------------
  # Ending
  # ---------------------------------------------------------------------------

  # The one terminal transaction, then the local cleanup — from this
  # process, which holds the slot. A paused turn already let it go. The
  # keeper is suspended before the write, so no renewal finds the root
  # ended and exits this process before the release stops it; a steer that
  # keeps the turn going resumes it.
  defp conclude(%State{} = state, {result, ended}) do
    case result do
      {:paused, _} ->
        result

      _ ->
        {status, error} = terminal(result)
        if status != "completed", do: skip_pages(ended)
        suspend_keeper(ended)

        case Tape.finish(ctx(state), ended.turn, status, %{error: error}) do
          # A steer landed while the last answer was written: the turn goes
          # on to answer it.
          {:error, :steer_pending} ->
            resume_keeper(ended)
            conclude(state, loop(%{ended | model?: true}))

          # A page's call was proposed after the last look: the turn goes
          # on to dispatch it.
          {:error, :call_pending} ->
            resume_keeper(ended)
            conclude(state, loop(ended))

          finish ->
            final = finished(ended, status, result, finish)
            release_program(ended, status)
            release(ended)
            final
        end
    end
  end

  # A turn that ends otherwise than completed runs none of the page's
  # calls still proposed in it: each is skipped, and its result row
  # answers the page.
  defp skip_pages(%State{} = state) do
    with {:ok, steps} <- Tape.steps(guest(state), state.turn) do
      case for(
             %{purpose: purpose, dispatch_state: "proposed", id: id} <- steps,
             purpose in ["page", "brain"],
             do: id
           ) do
        [] ->
          :ok

        ids ->
          Tape.skip_steps(guest(state), state.turn, "the turn ended before the call ran", ids)
      end
    end
  end

  defp finished(ended, status, result, finish) do
    case finish do
      {:ok, _} ->
        result

      other ->
        # Saying "completed" while the row still says "running" puts the
        # runtime and the rows in disagreement, and the runner would take
        # the next message believing this one had landed. The row is left
        # for recovery, which is what owns a turn nobody finished.
        Logger.error(
          "[Aqua.Loop] turn #{ended.turn.id} could not be finished as #{status}: " <>
            "#{inspect(other)}"
        )

        {:uncertain, "the turn's terminal write did not land"}
    end
  end

  defp terminal(:completed), do: {"completed", nil}
  defp terminal(:cancelled), do: {"cancelled", "stopped"}
  defp terminal({:failed, reason}), do: {"failed", describe(reason)}
  defp terminal({:uncertain, reason}), do: {"uncertain", describe(reason)}

  # A program turn that completed leaves its session for the next turn of
  # the thread; one that ended otherwise closes it, and the next resumes.
  defp release_program(%State{program: %{}, turn: turn} = state, status) do
    Aqua.Program.release(
      ctx(state).athanor_id,
      turn.thread_id,
      turn.agent,
      turn.id,
      status != "completed"
    )
  end

  defp release_program(_state, _status), do: :ok

  defp release(%State{claim: %{execution_id: execution_id} = claim} = state) do
    Opus.release_turn_root(ctx(state), execution_id, claim: claim)
  end

  defp release(_state), do: :ok

  defp suspend_keeper(%State{claim: %{keeper: keeper}}), do: Opus.suspend_lease_watch(keeper)
  defp suspend_keeper(_state), do: :ok

  defp resume_keeper(%State{claim: %{keeper: keeper}}), do: Opus.resume_lease_watch(keeper)
  defp resume_keeper(_state), do: :ok

  # ---------------------------------------------------------------------------
  # The loop
  # ---------------------------------------------------------------------------

  @doc false
  def loop(%State{} = state) do
    case step(state) do
      {:continue, state} -> loop(state)
      {:halt, result, state} -> {result, state}
    end
  end

  defp step(%State{program: %{}} = state) do
    case page_round(state) do
      {:continue, state} -> program_round(state)
      halt -> halt
    end
  end

  defp step(%State{} = state) do
    cond do
      state.steps >= @max_steps ->
        {:halt, {:failed, :step_cap}, state}

      over_deadline?(state) ->
        {:halt, {:failed, :deadline}, state}

      true ->
        case page_round(state) do
          {:continue, %State{model?: true} = state} -> model_round(state)
          {:continue, state} -> {:halt, :completed, state}
          halt -> halt
        end
    end
  end

  # A program turn's round: once its start is admitted and attended, the
  # turn waits on the attendant, which proposes the program's asks (the
  # next page round decides and runs them), says when the native turn
  # ended (the turn may complete) and when its job ended.
  defp program_round(%State{} = state) do
    case start_step(state) do
      {:ok, %{dispatch_state: "closed", outcome: "ok"} = start} ->
        attended(state, start)

      {:ok, %{dispatch_state: "closed", error: error}} ->
        {:halt, {:failed, error || "the program did not start"}, state}

      _unstarted ->
        {:halt, {:failed, "the program did not start"}, state}
    end
  end

  # The attendant is watched while the turn waits on it: one that ends
  # ends the turn's wait, as the program's job is over with it, and says
  # so unless it was closed on purpose. Meanwhile the program's own tools
  # it tells of join the turn's one list of what runs.
  defp attended(%State{} = state, start) do
    case Aqua.Program.watch(program_work(state, start.id), self()) do
      {:ok, attendant} -> attending(state, Process.monitor(attendant))
      {:error, sentence} -> {:halt, {:failed, sentence}, state}
    end
  end

  defp attending(%State{} = state, monitor) do
    turn_id = state.turn.id

    receive do
      {:page_call, ^turn_id} ->
        Process.demonitor(monitor, [:flush])
        {:continue, state}

      {Aqua.Program, ^turn_id, {:own, name, phase}} ->
        state |> own_activity(name, phase) |> attending(monitor)

      {Aqua.Program, ^turn_id, :idle} ->
        Process.demonitor(monitor, [:flush])
        {:halt, :completed, state}

      {Aqua.Program, ^turn_id, {:ended, {:failed, sentence}}} ->
        Process.demonitor(monitor, [:flush])
        _ = system_row(state, sentence)
        {:halt, {:failed, sentence}, state}

      # Closed on purpose: Stop closes the session before it stops the
      # turn, which says nothing more in the thread.
      {:DOWN, ^monitor, :process, _pid, :normal} ->
        {:halt, :cancelled, state}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        sentence = "#{program_title(state)} stopped before it finished."
        _ = system_row(state, sentence)
        {:halt, {:failed, sentence}, state}
    end
  end

  defp start_step(%State{} = state) do
    key = Tape.brain_start_key(state.turn.id)

    case Tape.steps(guest(state), state.turn) do
      {:ok, steps} -> {:ok, Enum.find(steps, &(&1.idempotency_key == key))}
      {:error, _} = unread -> unread
    end
  end

  # What the attendant needs of the turn: its contexts, the turn as its
  # row stands, the admitting step, the row, the thread's session
  # generation as stored now, and what the work runs with.
  defp program_work(%State{spec: spec, program: program} = state, start_id) do
    generation =
      case Tape.brain(spec.guest, state.turn.thread_id) do
        {:ok, %{generation: generation}} -> generation
        {:error, _} -> state.generation
      end

    turn =
      case Tape.turn(spec.guest, state.turn.id) do
        {:ok, turn} -> turn
        {:error, _} -> state.turn
      end

    %{
      ctx: spec.ctx,
      guest: spec.guest,
      turn: turn,
      start: start_id,
      program: program,
      agent: state.turn.agent,
      title: program_title(state),
      generation: generation,
      config: program_config(spec),
      system: spec.system,
      tools: spec.tools
    }
  end

  defp program_title(%State{spec: spec, program: program}),
    do: spec.agent["title"] || program.name || spec.agent["name"]

  # The whole configuration the harness runs with: the agent's model and
  # every option its file and the turn name, none dropped, so a narrowing
  # option reaches the holder, which compares the whole of it at each
  # `work` and refuses, before writing, one the wire does not take
  # (`Aqua.Program`). An absent member is the harness's default.
  defp program_config(spec) do
    spec.brain_options
    |> Map.put("model", spec.model)
    |> Enum.reject(fn {_member, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp model_round(%State{} = state) do
    with {:ok, _drained} <- Tape.drain_steer(guest(state), state.turn),
         {:ok, rows} <- Tape.projection(guest(state), state.turn),
         removed = removed_files(state.spec.ctx, rows),
         files = later_files(state, rows),
         {:ok, planned, rows} <- compact(state, rows, removed, files),
         cited = cited(planned, rows),
         {:ok, step, planned} <- open_model_step(planned, "chat", rows, cited) do
      excerpt = if planned.excerpt_sent?, do: nil, else: planned.spec.excerpt
      request = request(planned, rows, excerpt, cited, removed, files)
      planned = %{planned | sent_upto: highest_seq(rows)}

      if excerpt do
        _ =
          Tape.mark_excluded(guest(planned), planned.turn, step, %{
            excluded: ["room_excerpt"],
            request_digest: digest(request)
          })
      end

      ask_model(%{planned | excerpt_sent?: true}, step, request, retained(request, excerpt), 0)
    else
      {:error, :superseded} -> {:halt, :cancelled, state}
      {:error, reason} -> {:halt, {:failed, reason}, state}
    end
  end

  # Every round carries the sender's attachments, and those of each later
  # post written into the turn (`files`, `later_files/2`): the projection
  # renders text, and an image or a document exists only as these typed
  # blocks, so a round without them would not show the model what it was
  # asked about.
  defp request(%State{spec: spec} = state, rows, excerpt, cited, removed, files) do
    rows = Planner.prune(rows)
    authors = rows |> Enum.map(& &1.author) |> Enum.uniq() |> Enum.reject(&agent_or_system?/1)
    multi? = length(authors) > 1

    names =
      if multi?, do: Map.new(authors, &{&1, Sanctum.Tenancy.Users.display_name(&1)}), else: %{}

    messages =
      Request.messages(rows, removed,
        me: spec.agent["name"],
        names: names,
        multi_author?: multi?,
        excerpt: excerpt,
        attachments: spec.attachments,
        task_message_id: state.turn.message_id,
        files: files,
        refs: Map.new(cited, &{&1.id, &1})
      )

    Request.build(
      model: spec.model,
      system: spec.system,
      messages: messages,
      tools: spec.tools,
      capabilities: spec.capabilities,
      offers_search?: offers_search?(spec),
      session: state.session,
      options: spec.brain_options
    )
  end

  defp agent_or_system?(author),
    do: author in Prima.Author.reserved()

  # By row id, the refs of each row's files the person deleted from Files
  # (`Aqua.Attachments.as_kept/2`): read once a round, before the size
  # estimate, which the dispatch shares, and only for the rows the request
  # carries to the model (`Request.carried/1`), one listing per row that
  # holds files. A compaction this round makes keeps a subset of them.
  defp removed_files(ctx, rows) do
    for row <- rows |> Planner.prune() |> Request.carried(),
        Aqua.Attachments.refs_of(row) != [],
        removed = Enum.filter(Aqua.Attachments.as_kept(ctx, row), &(&1["removed"] == true)),
        removed != [],
        into: %{},
        do: {row.id, removed}
  end

  # By row id, the files of each post written into the turn after the one
  # that opened it (a drained steer), as blocks the brain takes, made as the
  # opening post's are (`Turn.file_blocks/3`). Read once a round, beside
  # `removed_files/2`, and only for the rows the request carries; the turn's
  # own rows are its agent's, and the opening post's ride `spec.attachments`.
  defp later_files(%State{spec: spec, turn: turn}, rows) do
    for row <- rows |> Planner.prune() |> Request.carried(),
        row.turn_id == turn.id and row.id != turn.message_id and row.sent_by != turn.agent,
        Aqua.Attachments.refs_of(row) != [],
        into: %{},
        do: {row.id, Turn.file_blocks(spec.ctx, row, spec.capabilities.media_types)}
  end

  # The model step is dispatched before the call: a recovery finds it
  # without a response and never replays it.
  # Every model step opened — a chat round, its retry, a compaction —
  # counts against the turn's cap, before it opens; the count is the
  # turn's, rebuilt from its rows on a continuation.
  #
  # The step opens with the threads its rows carry, and with the read
  # threads of the earlier turns whose rows it sends, joined in the step's
  # own transaction.
  defp open_model_step(state, purpose, rows \\ [], cited \\ [])

  defp open_model_step(%State{steps: steps}, _purpose, _rows, _cited) when steps >= @max_steps,
    do: {:error, :step_cap}

  defp open_model_step(%State{} = state, purpose, rows, cited) do
    with {:ok, step} <-
           Tape.record_model_intent(guest(state), state.turn, %{
             idempotency_key:
               "model:#{state.turn.id}:#{System.unique_integer([:positive, :monotonic])}",
             child_execution_id: Prima.UUID7.execution_id(),
             tool: state.spec.catalyst,
             action: "chat",
             purpose: purpose,
             threads: Tape.carried_threads(rows),
             threads_from: earlier_turns(state, rows ++ cited)
           }),
         {:ok, step} <- Tape.mark_dispatched(guest(state), state.turn, step) do
      {:ok, step, %{state | steps: state.steps + 1}}
    end
  end

  # The request offers web search when the policy turns it on, the grant
  # carries it and the model has the tool.
  defp offers_search?(spec),
    do: Request.offers_search?(spec.offered, spec.authority, spec.capabilities)

  # The daily thread's posts the openings among `rows` refer to, read as
  # they stand now and never copied: a post of another thread, or one
  # deleted since, reads as nothing.
  defp cited(%State{} = state, rows) do
    rows
    |> Enum.filter(&(&1.kind == "opening"))
    |> Enum.flat_map(fn row ->
      case Tape.payload(row) do
        %{"from" => %{"thread" => daily}, "refs" => [_ | _] = ids} when is_binary(daily) ->
          Enum.flat_map(Enum.uniq(ids), fn id ->
            case is_binary(id) && Tape.message(guest(state), id) do
              {:ok, %{thread_id: ^daily} = cited} -> [cited]
              _gone -> []
            end
          end)

        _no_refs ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end

  # The earlier turns whose rows a request sends: every row's turn but
  # this one's, and the turn a crew row came from — a delivered request's
  # asking turn, a reply's member turn — whose words it carries. An
  # unattached row of a person's names none.
  defp earlier_turns(%State{turn: turn}, rows),
    do: rows |> Tape.writing_turns() |> Enum.reject(&(&1 == turn.id))

  defp ask_model(%State{} = state, step, request, retained, retries) do
    answer = model_call(state, step, request, retained, true)
    forget? = forgets?(state, request, answer)

    case answer do
      {:ok, data} ->
        on_response(state, step, data)

      # A page's call that ran while the model answered has an unknown
      # outcome: the model was stopped, and the turn stops on the call.
      {:uncertain, page_step, reason, rest} ->
        stop_uncertain(state, page_step, reason, rest)

      # The turn's fence moved before the model's read threads could join it.
      {:error, :superseded} ->
        {:halt, :cancelled, state}

      # The retry continues the session the refusal named, as the next
      # turn would.
      {:error, %{"type" => type} = error}
      when type in @recoverable and retries < length(@retry_delays_ms) ->
        closed = refused(state, error, type)
        _ = Tape.close_step(guest(state), state.turn, step, "error", closed)
        Process.sleep(Enum.at(@retry_delays_ms, retries))
        state = %{state | session: closed[:session] || state.session}
        request = continued(request, closed[:session])
        retained = retained && continued(retained, closed[:session])

        case open_model_step(state, "chat") do
          {:ok, again, state} -> ask_model(state, again, request, retained, retries + 1)
          {:error, reason} -> {:halt, {:failed, reason}, state}
        end

      # The brain no longer holds the session the request named, and
      # refused before it took anything of the request (`Prima.Model`), so
      # asking again repeats nothing. A refusal of that type the turn does
      # not forget on (`forgets?/3`) ends it as any other does, the thread's
      # session left as it is.
      {:error, %{"type" => @session_gone} = error} when forget? ->
        ask_without_session(state, step, error, request, retained, retries)

      {:error, %{"type" => type} = error} when type in @setup ->
        _ =
          Tape.close_step(
            guest(state),
            state.turn,
            step,
            "error",
            refused(state, error, error["message"])
          )

        announce(state, :consent_required, %{
          ref: state.spec.catalyst,
          user_id: ctx(state).user_id
        })

        {:halt, {:failed, :setup_required}, state}

      {:error, %{"type" => @refused_key} = error} ->
        _ =
          Tape.close_step(
            guest(state),
            state.turn,
            step,
            "error",
            refused(state, error, error["message"])
          )

        _ = system_row(state, refused_key_line(error))
        {:halt, {:failed, refused_key_line(error)}, state}

      {:error, %{"type" => _type, "message" => message} = error} ->
        _ =
          Tape.close_step(guest(state), state.turn, step, "error", refused(state, error, message))

        _ = system_row(state, "The model could not answer: #{message}")
        {:halt, {:failed, message}, state}

      # A model request that died left nothing a person must judge
      # (`Prima.TurnStep.unresolved/1`): it ends the turn like a refusal.
      {failure, reason} when failure in [:error, :exit] ->
        text = describe(reason)
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: text})
        _ = system_row(state, "The model could not be reached: #{text}")
        {:halt, {:failed, reason}, state}
    end
  end

  defp continued(request, nil), do: request
  defp continued(request, session), do: Map.put(request, "session", session)

  # Whether the turn forgets its thread's session on this answer and asks
  # again, once in a turn: the brain refused the session the request named
  # as one it no longer holds, by a refusal that holds to the contract (one
  # that names a session is off it, `Prima.Model`), and the turn has not
  # forgotten a session before. A retry may have put a newer session into
  # the request, so the turn's own mark decides, not the request.
  defp forgets?(
         %State{forgot_session?: false},
         %{"session" => _named},
         {:error, %{"type" => @session_gone} = error}
       ),
       do: Prima.Model.response_session(error) == {:ok, nil}

  defp forgets?(%State{}, _request, _answer), do: false

  # A step the turn forgot its thread's session on, as its row tells it.
  defp forgot_session?(%{kind: "model", purpose: "chat", outcome: "error", error: @session_gone}),
    do: true

  defp forgot_session?(_step), do: false

  # The refused step closes with the mark that the turn forgot a session
  # (`@session_gone`), the thread forgets the session its brain no longer
  # holds, and the same request is asked once more without it, which opens
  # a new session. Each write is required before the next: a mark that was
  # not written forgets nothing and asks nothing, since a continued turn
  # would find no mark and forget again. The turn keeps the new session
  # under the generation its forget answers: the raised one, or the one it
  # read when the thread was forgotten from outside meanwhile, under which
  # nothing it answers with is kept (`Arca.TurnStorage.forget_session/3`).
  defp ask_without_session(%State{} = state, step, error, request, retained, retries) do
    marked = refused(state, error, @session_gone)

    with {:ok, _closed} <- Tape.close_step(guest(state), state.turn, step, "error", marked),
         {:ok, generation} <- Tape.forget_session(guest(state), state.turn, state.generation),
         forgot = %{state | session: nil, generation: generation, forgot_session?: true},
         {:ok, again, asking} <- open_model_step(forgot, "chat") do
      request = Map.delete(request, "session")
      ask_model(asking, again, request, retained && Map.delete(retained, "session"), retries)
    else
      {:error, :superseded} -> {:halt, :cancelled, state}
      {:error, reason} -> {:halt, {:failed, reason}, state}
    end
  end

  # A refused model step closes with the brain's session its refusal
  # names, kept on the thread as a response's is (`Prima.Model`), so the
  # next request continues it, under the thread's generation the turn
  # keeps a session under (`State`). A session off the contract is not
  # kept, and the refusal ends the turn as it would.
  defp refused(%State{} = state, error, text) do
    case Prima.Model.response_session(error) do
      {:ok, session} -> %{error: text, session: session, generation: state.generation}
      {:error, _invalid} -> %{error: text}
    end
  end

  # The catalyst runs as a child of the root, in a worker: the answer is
  # the contract's data, a typed refusal, the engine's refusal, or the
  # worker's death. The worker is waited for until the run ends, as every
  # worker of the loop is (`worker/1`). A chat step's text streams to the
  # thread while it runs, and is withdrawn when the step lands no text row;
  # a flush or a compaction streams nothing.
  #
  # Whatever it answers, the child's read threads join the step's turn
  # before the answer is handed back (`model_threads/3`): every use of a
  # model's output — a chat reply, a flush's notes, a compaction's
  # summary, a refusal's text — passes through here, and none happens
  # unless the join was written. A turn whose fence moved answers
  # `:superseded`.
  defp model_call(%State{spec: spec} = state, step, request, retained, pages? \\ false) do
    input = %{"operation" => "chat", "params" => request}
    retained_input = retained && %{"operation" => "chat", "params" => retained}
    guest = guest(state)
    turn = state.turn
    streamed = stream_attrs(state, step)
    stream = streamed && Aqua.Loop.Stream.open(guest, step.child_execution_id, streamed)

    run = fn ->
      Opus.run_child(spec.authority, spec.catalyst, nil, input,
        ctx: guest,
        execution_id: step.child_execution_id,
        step_id: step.id,
        parent_execution_id: turn.root_execution_id,
        root_execution_id: turn.root_execution_id,
        declared_needs: [],
        retention_class: "chat_step",
        retained_input: retained_input,
        charge: Binding.charge(step, turn),
        guest_fn: :spawn,
        envelope: true
      )
    end

    answer =
      try do
        if pages?, do: model_worker(state, step, run), else: worker(run)
      after
        Aqua.Loop.Stream.close(stream)
      end

    result =
      case answer do
        {:uncertain, _page_step, _reason, _rest} = stopped ->
          stopped

        answer ->
          case Tape.join_threads(guest, turn, model_threads(state, step, answer)) do
            :ok -> model_result(answer)
            {:error, :superseded} -> {:error, :superseded}
            {:error, _unwritten} -> {:error, :read_threads_unrecorded}
          end
      end

    if streamed && not lands_text?(result), do: Aqua.Loop.Stream.abandon(guest, streamed)
    result
  end

  defp model_result({:ok, {:ok, %{output: output}}}), do: Prima.Model.decode_envelope(output)
  defp model_result({:ok, {:ok, output}}), do: Prima.Model.decode_envelope(output)
  defp model_result({:ok, {:error, reason}}), do: {:error, reason}
  defp model_result({:exit, reason}), do: {:exit, reason}

  # The read threads a model child's answer brings into its turn: what its
  # completion result carries, else its row's, read by the id the step
  # minted for it — a worker that died included, since its child may have
  # read before it did.
  defp model_threads(state, step, {:ok, answer}),
    do: child_threads(state, step.child_execution_id, answer)

  defp model_threads(state, step, {:exit, _reason}),
    do: read_threads(state, step.child_execution_id)

  # A child's read threads by the first carrier that holds them
  # (`Aqua.Loop.Policy.child_threads/1`): its completion result's, none
  # for a refusal made before any attempt existed, else its row's.
  defp child_threads(state, child_id, answer) do
    case Policy.child_threads(answer) do
      {:carried, threads} -> threads
      :nothing_ran -> []
      :unknown -> read_threads(state, child_id)
    end
  end

  # A child's read threads read from its row by the id the loop minted for
  # it. A row no longer held — retention prunes a terminal child while its
  # turn still runs — or one that cannot be read adds none.
  defp read_threads(state, child_id) when is_binary(child_id) do
    case Opus.read_threads(ctx(state), child_id) do
      {:ok, threads} -> threads
      {:error, _gone_or_unreadable} -> []
    end
  end

  defp read_threads(_state, _no_id), do: []

  # A turn's text streams under its own fence, named by its agent when
  # that is not the soul.
  defp stream_attrs(%State{} = state, %{purpose: "chat"} = step) do
    %{
      thread_id: state.turn.thread_id,
      turn_id: state.turn.id,
      fence: state.turn.fence,
      source: state.turn.id,
      step_id: step.id,
      ordinal: state.steps,
      role: if(state.spec.soul?, do: nil, else: state.spec.agent["name"])
    }
  end

  defp stream_attrs(_state, _step), do: nil

  defp lands_text?({:ok, data}),
    do:
      Enum.any?(
        List.wrap(data["content"]),
        &(&1["type"] == "text" and &1["text"] not in [nil, ""])
      )

  defp lands_text?(_result), do: false

  # The whole response lands before any call runs.
  defp on_response(%State{} = state, step, data) do
    content = List.wrap(data["content"])
    text = content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("", & &1["text"])
    {resolved, tool_calls} = resolve_calls(state, step, content)
    usage = data["usage"] || %{}

    with {:ok, session} <- Prima.Model.response_session(data),
         {:ok, %{calls: recorded}} <-
           Tape.record_response(guest(state), state.turn, step, %{
             text: if(text == "", do: nil, else: text),
             usage: usage,
             stop_reason: data["stop_reason"],
             session: session,
             generation: state.generation,
             tool_calls: tool_calls
           }) do
      state = count_usage(%{state | session: session || state.session}, usage)

      items =
        Enum.zip_with(recorded, resolved, fn %{step: call_step}, {_block, call} ->
          %{step: call_step, call: call}
        end)

      # A page's waiting calls are placed in front of the round's own,
      # with reads among them running beside each other as any batch's
      # reads do.
      # An answer that calls nothing asks the model nothing more.
      # A page's calls alone start no further model round.
      state = %{state | model?: items != []}
      items = page_items(state) ++ items

      if items == [],
        do: {:halt, :completed, state},
        else: dispatch(state, items)
    else
      {:error, :superseded} ->
        {:halt, :cancelled, state}

      {:error, reason} ->
        {:halt, {:failed, reason}, state}
    end
  end

  defp resolve_calls(%State{} = state, step, content) do
    resolved =
      for %{"type" => "tool_call"} = block <- content do
        name = block["name"] || ""
        args = if is_map(block["arguments"]), do: block["arguments"], else: %{}

        {block, Binding.resolve(name, args, tool_call_id: block["id"])}
      end

    {resolved, Enum.map(resolved, fn {block, call} -> call_attrs(state, step, block, call) end)}
  end

  defp call_attrs(%State{} = state, model_step, block, call) do
    name = block["name"] || ""
    args = if is_map(block["arguments"]), do: block["arguments"], else: %{}
    id = block["id"] || Prima.UUID7.generate_id("call")

    recorded = recorded(name, call)

    Map.merge(recorded, %{
      tool_call_id: id,
      name: name,
      arguments: args,
      provider_data: block["provider_data"],
      idempotency_key: "call:#{state.turn.id}:#{model_step.id}:#{id}"
    })
  end

  @doc false
  # What a step records of a call as it was bound, a model's
  # (`call_attrs/4`) or a page's (`Aqua.PageCalls.proposal/3`): one
  # recording, so a page's call is recorded as Aqua's call of its kind is.
  @spec recorded(String.t(), {:ok, Call.t()} | {:error, term()}) :: map()
  def recorded(name, call) do
    {tool, action, kind, recovery, child, step_kind} =
      case call do
        {:ok, %Call{} = call} ->
          {call.tool, call.action, kind_of(call), recovery_of(call), child_id_for(call),
           step_kind(call)}

        {:error, _} ->
          {name, nil, "unknown", nil, nil, "tool"}
      end

    %{
      tool: tool,
      action: action,
      kind: kind,
      recovery: recovery,
      child_execution_id: child,
      step_kind: step_kind
    }
  end

  defp kind_of(%Call{kind: :hand, tool: tool, action: action}),
    do: to_string(Aqua.Kinds.kind_for(tool, action) || "unknown")

  defp kind_of(%Call{kind: :catalog, tool: tool, action: action}),
    do: to_string(Aqua.Kinds.kind_for(tool, action) || "unknown")

  defp kind_of(%Call{kind: :external}), do: "external"
  defp kind_of(%Call{kind: :launch}), do: "execute"
  defp kind_of(%Call{kind: kind}), do: to_string(kind)

  defp recovery_of(%Call{} = call), do: if(replay_safe?(call), do: "replay_safe", else: nil)

  defp child_id_for(%Call{kind: kind}) when kind in [:hand, :launch, :external],
    do: Prima.UUID7.execution_id()

  defp child_id_for(_call), do: nil

  defp step_kind(%Call{kind: :launch}), do: "launch"
  defp step_kind(%Call{kind: :ui}), do: "ui"
  defp step_kind(_call), do: "tool"

  defp count_usage(%State{} = state, usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    totals = %{input: state.usage.input + input, output: state.usage.output + output}
    announce(state, :usage, totals)

    if input > 0 do
      %{state | usage: totals, observed: input, observed_seq: state.sent_upto}
    else
      %{state | usage: totals}
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  # The runnable steps in source order; a group of reads runs beside
  # itself, everything else alone; a steer that arrived skips what has
  # not started. A launch naming an account its app's profile does not
  # bind ends the turn as setup required, with nothing else of the
  # response started.
  defp dispatch(%State{} = state, items) do
    {runnable, state, setup} =
      Enum.reduce(items, {[], state, nil}, fn item, {_runnable, state, _setup} = acc ->
        decide(state, item, acc)
      end)

    runnable = Enum.reverse(runnable)

    case setup do
      nil -> run_dispatched(state, runnable)
      setup -> end_for_account(state, setup)
    end
  end

  defp run_dispatched(%State{} = state, runnable) do
    case run_groups(state, Policy.group(runnable)) do
      {:halt, result, state} ->
        {:halt, result, state}

      {:ok, state} ->
        if over_deadline?(state),
          do: {:halt, {:failed, :deadline}, state},
          else: {:continue, state}
    end
  end

  # A launch the turn ends on decides nothing after it: what is left of
  # the response is skipped with the turn.
  defp decide(_state, _item, {_runnable, _state_acc, setup} = acc) when setup != nil, do: acc

  # A restricted turn runs replay-safe reads and nothing else — before the
  # policy can say otherwise.
  defp decide(
         %State{restricted?: true},
         %{step: step, call: {:ok, %Call{} = call}} = item,
         {_runnable, state, _setup} = acc
       ) do
    if Policy.replay_safe?(call) do
      decide_open(item, acc)
    else
      close(
        state,
        step,
        call,
        {:error,
         {:denied,
          "#{call.tool}.#{call.action} may not run: an earlier call's outcome is unknown, " <>
            "and until a new turn starts only replay-safe reads run"}}
      )

      acc
    end
  end

  defp decide(_state, item, acc), do: decide_open(item, acc)

  # A call refused as it resolved never ran: it closes denied, as the
  # policy closes a call it refuses, in the refusal's sentence, and a page
  # is answered the refusal's class (`Aqua.PageCalls.answer/3`).
  defp decide_open(%{step: step, call: {:error, reason}}, {runnable, state, setup}) do
    close(state, step, nil, {:error, {:denied, reason}})
    {runnable, state, setup}
  end

  defp decide_open(%{step: step, call: {:ok, %Call{} = call}} = item, {runnable, state, setup}) do
    decision =
      if not_offered?(state, step, call),
        do: {:deny, "#{call.model_name} is not one of the tools this work has"},
        else: Policy.decide(call, state.spec.offered, state.spec.mode, place(state, step))

    case decision do
      :run ->
        {[item | runnable], state, setup}

      # A launch carries what its decision read to its dispatch, which
      # holds the run to it (`Aqua.Launch.run/3`).
      {:run, decided} ->
        {[Map.put(item, :decided, decided) | runnable], state, setup}

      # Closed before it ran, as the policy closes a call it refuses.
      {:setup_required, app, {need, account}} ->
        close(state, step, call, {:error, {:denied, not_granted(app, account)}})
        {runnable, state, setup || {app, need, account}}

      {:read_only, message} ->
        close(state, step, call, {:error, {:denied, message}})
        {runnable, say_read_only(state, message), setup}

      {refused, message} when refused in [:deny, :refuse] ->
        close(state, step, call, {:error, {:denied, message}})
        {runnable, state, setup}
    end
  end

  # The first call a read-only member is refused in a turn writes the
  # sentence once as a line in the thread, by the writer a refused key's
  # line uses. The line carries the turn's own id as its sender id, which
  # the thread holds once, so a continued turn writes no second.
  defp say_read_only(%State{read_only_said?: true} = state, _message), do: state

  defp say_read_only(%State{turn: turn} = state, message) do
    _ =
      Tape.append(ctx(state), turn.thread_id, %{
        author: Prima.Author.system(),
        sent_by: turn.agent,
        kind: "system",
        content: message,
        client_id: "read-only:" <> turn.id,
        turn_id: turn.id,
        execution_id: turn.root_execution_id
      })

    %{state | read_only_said?: true}
  end

  # What a launch naming an account its app does not bind answers: the
  # account and the app, never an entry.
  defp not_granted(app, account),
    do:
      "The account #{inspect(account)} is not granted to #{app}: a person grants it on the " <>
        "app's profile, and the launch is asked again in a new turn"

  # The turn ends on a launch naming an account its app's profile does not
  # bind: nothing else of the response starts, and the person is asked to
  # grant that account on the app's own profile. The retry is a new turn.
  defp end_for_account(%State{} = state, {app, need, account} = setup) do
    _ =
      Tape.skip_steps(
        guest(state),
        state.turn,
        "the turn ended: #{app} needs the account #{inspect(account)} granted"
      )

    announce(state, :consent_required, %{
      ref: app,
      user_id: ctx(state).user_id,
      account: %{name: account, need: need},
      message_id: state.turn.message_id
    })

    {:halt, {:failed, {:setup_required, setup}}, state}
  end

  # Every group's outcome rides out: a group that stopped the turn on an
  # unknown outcome halts the dispatch with the pause it established.
  defp run_groups(%State{} = state, groups) do
    Enum.reduce_while(groups, {:ok, state}, fn group, {:ok, state} ->
      cond do
        over_deadline?(state) ->
          _ = Tape.skip_steps(guest(state), state.turn, "the turn ran out of time")
          {:halt, {:ok, state}}

        steered?(state) ->
          _ = Tape.skip_steps(guest(state), state.turn, "a newer message arrived")
          {:halt, {:ok, state}}

        true ->
          case run_group(state, group) do
            {:ok, state} -> {:cont, {:ok, state}}
            {:halt, _result, _state} = halt -> {:halt, halt}
          end
      end
    end)
  end

  defp run_group(%State{} = state, {:launch, item}), do: run_launch(state, item)

  defp run_group(%State{} = state, {:exclusive, item}) do
    state = activity(state, [item], :running)

    outcome =
      case worker(fn -> run_one(state, item) end) do
        {:ok, {:uncertain, step, reason}} -> {:uncertain, step, reason}
        {:ok, _} -> :ok
        {:exit, reason} -> settle_dead(state, item, reason)
      end

    state = activity(state, [item], :done)

    case outcome do
      {:uncertain, step, reason} -> stop_uncertain(state, step, reason, [])
      _ -> {:ok, state}
    end
  end

  defp run_group(%State{} = state, {:concurrent, items}) do
    state = activity(state, items, :running)
    cap = max(state.spec.authority.budget.cap, 1)
    outcome = run_concurrent(state, items, min(length(items), cap))
    state = activity(state, items, :done)

    case outcome do
      {:uncertain, step, reason, rest} -> stop_uncertain(state, step, reason, rest)
      :ok -> {:ok, state}
    end
  end

  # The reads of a group run beside each other, at most `cap` at once,
  # each in a worker of its own, waited for as `worker/1` waits: every
  # answer and death is attributed to its step as it arrives. The first
  # unknown outcome stops
  # the group — nothing more is started, and what still runs is handed
  # back to be cancelled once the turn's stop is durable.
  defp run_concurrent(%State{} = state, items, cap) do
    collect(state, items, %{}, cap)
  end

  defp collect(_state, [], running, _cap) when map_size(running) == 0, do: :ok

  defp collect(state, pending, running, cap) when map_size(running) < cap and pending != [] do
    [item | rest] = pending
    task = Aqua.Loop.Worker.async(fn -> run_one(state, item) end)
    collect(state, rest, Map.put(running, task.ref, %{item: item, task: task}), cap)
  end

  defp collect(state, pending, running, cap) do
    receive do
      {ref, result} when is_map_key(running, ref) ->
        Process.demonitor(ref, [:flush])
        {%{item: item}, running} = Map.pop(running, ref)

        case result do
          {:uncertain, step, reason} ->
            {:uncertain, step, reason, Map.values(running) ++ pending_items(pending)}

          _ ->
            collect(state, pending, running, cap)
        end
        |> tap(fn _ -> item end)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        {%{item: item}, running} = Map.pop(running, ref)

        case settle_dead(state, item, reason) do
          {:uncertain, step, why} ->
            {:uncertain, step, why, Map.values(running) ++ pending_items(pending)}

          _ ->
            collect(state, pending, running, cap)
        end
    end
  end

  defp pending_items(pending), do: Enum.map(pending, &%{item: &1, task: nil})

  # In a worker: the step is dispatched, run, and closed with what it
  # answered. A step that is no longer proposed (skipped, superseded)
  # runs nothing. An outcome that cannot be known is not closed here: it
  # is reported, and the loop stops the turn on it.
  defp run_one(%State{} = state, %{step: step, call: {:ok, %Call{} = call}} = item) do
    case still_offered(state, item, call) do
      :ok -> dispatch_one(state, step, call)
      {:denied, message} -> settle_denied(state, step, call, message)
    end
  end

  # The loop decides from a snapshot `Turn.build/3` took. The person's
  # browser setting is live, and reaches no loop already running — so the
  # window between a response landing and its calls dispatching, and the
  # window while an earlier call of the same response runs, belonged to a
  # setting that may have gone. Every call is decided again as it
  # dispatches, on the offered set as it stands now; the mode is pinned.
  # A call outside the tools its job was narrowed to runs on no answer.
  defp still_offered(%State{spec: spec} = state, item, %Call{} = call) do
    if not host_start?(state, item.step) and not Policy.within?(call, spec.narrowed) do
      {:denied, Policy.outside(call)}
    else
      case Policy.decide(call, Turn.current_offered(spec), spec.mode, place(state, item.step)) do
        :run -> :ok
        {:run, _decided} -> :ok
        {:setup_required, _app, _need} -> {:denied, "#{call.tool}.#{call.action} is not allowed"}
        {_refused, message} -> {:denied, message}
      end
    end
  end

  # Where a call is made (`Aqua.Loop.Policy.decide/4`): the job's
  # narrowing, the member's title a read-only refusal names and the
  # member's context a launch's account is resolved under. The host's `program.start`
  # of a program brain is the brain's own start, not a call of its job, so
  # no narrowing covers it and the mode does not refuse it: the holder
  # starts it as the mode says (`Opus.Brain`).
  defp place(%State{} = state, step) do
    if host_start?(state, step),
      do: place(state) |> Keyword.put(:narrowed, nil) |> Keyword.put(:host_start, true),
      else: place(state)
  end

  defp place(%State{spec: spec}) do
    [narrowed: spec.narrowed, title: spec.agent["title"], ctx: spec.ctx]
  end

  # The host's own `program.start` of a program brain's turn.
  defp host_start?(%State{program: %{}, turn: turn}, %{idempotency_key: key}),
    do: key == Tape.brain_start_key(turn.id)

  defp host_start?(_state, _step), do: false

  # An ask of a program brain names one of the tools the turn offers,
  # whatever the native session was started with: checked each time it is
  # decided, beside the policy.
  defp not_offered?(%State{program: %{}, spec: spec} = state, %{purpose: "brain"} = step, call) do
    not host_start?(state, step) and
      not Enum.any?(spec.tools, &(&1["name"] == call.model_name))
  end

  defp not_offered?(_state, _step, _call), do: false

  defp settle_denied(%State{} = state, step, %Call{} = call, message) do
    case close(state, step, call, {:error, {:denied, message}}) do
      {:ok, _closed} -> :ok
      other -> {:uncertain, step, describe({:result_lost, other})}
    end
  end

  defp dispatch_one(%State{} = state, step, %Call{} = call) do
    case Tape.mark_dispatched(guest(state), state.turn, step) do
      {:ok, step} ->
        case normalise(execute(state, step, call)) do
          # A hand's child read what its row holds whatever its outcome: an
          # unknown one joins it too, as a dead worker's does.
          {:uncertain, reason} ->
            _ = Tape.join_threads(guest(state), state.turn, unknown_threads(state, step, call))
            {:uncertain, step, describe(reason)}

          result ->
            case close(state, step, call, result, result_threads(state, step, call, result)) do
              {:ok, _closed} ->
                :ok

              other ->
                # The canonical result is what the next round reads. Without
                # it the step stays dispatched, the model is handed a
                # synthetic "outcome is unknown", and the turn finishes as
                # though the call had answered. That is the uncertain path,
                # and it stops the turn.
                {:uncertain, step, describe({:result_lost, other})}
            end
        end

      {:error, :not_proposed} ->
        :skipped

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The setup form is the consent sheet for the ref, opened on the sender's
  # page as a launch that needs consent opens it.
  defp execute(%State{} = state, _step, %Call{kind: :ui, tool: "request_setup", args: args}) do
    with ref when is_binary(ref) <- Map.get(args, "component_ref"),
         {:ok, _parsed} <- Prima.ComponentRef.parse(ref) do
      announce(state, :consent_required, %{ref: ref, user_id: ctx(state).user_id})
      {:ok, "The setup form for #{ref} is open for the person"}
    else
      _invalid ->
        {:error, "request_setup.open: component_ref must be a component reference"}
    end
  end

  defp execute(%State{} = state, _step, %Call{kind: :ui, args: args}) do
    case Aqua.Intents.validate(args) do
      {:ok, intent} ->
        announce(state, :intents, %{intents: [intent], user_id: ctx(state).user_id})
        {:ok, "done"}

      {:error, message} ->
        {:error, message}
    end
  end

  # The host's `program.start` of a program brain attends its session: the
  # harness starts, or resumes its native session, and takes the turn's
  # work. A model's `program.start` is the terminal start below.
  defp execute(%State{program: %{}} = state, %{purpose: "brain"} = step, %Call{} = call)
       when call.tool == "program" and call.action == "start" do
    if host_start?(state, step) do
      case Aqua.Program.attend(program_work(state, step.id), holder(state.turn.id) || self()) do
        :ok -> {:ok, "#{program_title(state)} started"}
        {:error, sentence} -> {:error, sentence}
      end
    else
      dispatch_call(state, step, call)
    end
  end

  defp execute(%State{} = state, step, %Call{} = call), do: dispatch_call(state, step, call)

  defp dispatch_call(%State{spec: spec} = state, step, %Call{} = call) do
    Binding.dispatch(call, %{
      ctx: guest(state),
      authority: spec.authority,
      root_execution_id: state.turn.root_execution_id,
      call_id: spec.call_id,
      attempt: state.turn.attempt,
      thread_id: state.turn.thread_id,
      charge: Binding.charge(step, state.turn),
      execution_id: step.child_execution_id,
      step_id: step.id,
      step: %{id: step.id, generation: step.generation},
      cancel_handle: handle(state, step)
    })
  end

  # The threads a dispatched call's result joins to its turn.
  defp result_threads(state, step, call, result),
    do: Policy.threads_of(call, result, guest(state)) ++ unread_threads(state, step, call, result)

  # A hand's child read threads its answer does not carry
  # (`Policy.threads_of/3` joins carried ones): read from the child's row,
  # none when the row is gone or unreadable. A refusal made before any
  # attempt existed reads nothing.
  defp unread_threads(state, step, %Call{kind: :hand}, result) do
    case Policy.child_threads(result) do
      :unknown -> read_threads(state, step.child_execution_id)
      _carried_or_nothing_ran -> []
    end
  end

  defp unread_threads(_state, _step, %Call{}, _result), do: []

  defp unknown_threads(state, step, %Call{kind: :hand}),
    do: read_threads(state, step.child_execution_id)

  defp unknown_threads(_state, _step, %Call{}), do: []

  # One outcome vocabulary at the loop's boundary: an effect that may
  # have happened with no result (`uncertain`), one that happened whose
  # result could not be kept (`result_lost`), one whose ending could not
  # be recorded (`not_recorded`) — all unknown outcomes to the turn.
  defp normalise({:error, {:uncertain, reason}}), do: {:uncertain, reason}
  defp normalise({:error, {:result_lost, reason}}), do: {:uncertain, reason}
  defp normalise({:error, {:not_recorded, reason}}), do: {:uncertain, reason}
  defp normalise(other), do: other

  # The step's result row and outcome: `ok`, `error`, `denied` for a
  # refusal by the policy or the chain, `skipped` for a call not started,
  # or `uncertain` for a call closed with its outcome unknown — with the
  # threads the result carries, joined in the same transaction.
  defp close(%State{} = state, step, call, result, threads \\ []) do
    {outcome, text, error?} =
      case result do
        {:unknown, message} ->
          {"uncertain", message, true}

        {:skipped, message} ->
          {"skipped", message, true}

        {:error, {:denied, reason}} ->
          {"denied", describe(reason), true}

        # The chain's authority denied the call, answered by the child's
        # admission or refused by the gate: the step closes `denied`, in
        # the table's sentence for it.
        {:error, {:invoke_denied, _reason} = denied} ->
          {"denied", Prima.Refusal.message(denied), true}

        {:error, %Prima.Refusal{stage: :admission, reason: {:invoke_denied, _}} = refusal} ->
          {"denied", refusal.message, true}

        {:error, {:launch, reason}} ->
          {"error", describe(reason), true}

        {:error, message} when is_binary(message) ->
          {"error", message, true}

        {:error, %Prima.Refusal{stage: :admission, reason: message}} when is_binary(message) ->
          {"error", message, true}

        {:ok, text} when is_binary(text) ->
          {"ok", text, false}

        other ->
          %{text: text, is_error: error?} = render(call, other)
          {if(error?, do: "error", else: "ok"), text, error?}
      end

    Tape.close_step(guest(state), state.turn, step, outcome, %{
      result:
        result_row(step, outcome, page_value(call, result), text, %{
          "tool_call_id" => call && call.tool_call_id,
          "name" => call && call.model_name,
          "is_error" => error?
        }),
      execution_id: step.child_execution_id,
      error: if(error?, do: text, else: nil),
      threads: threads
    })
  end

  # A page's call is answered in the wire's shape (`Aqua.PageCalls.answer/3`):
  # its result row is the answer the page is handed.
  defp result_row(%{purpose: "page"}, outcome, result, text, payload) do
    {status, body} = Aqua.PageCalls.answer(outcome, result, text)
    %{content: body, payload: Map.put(payload, "status", status)}
  end

  defp result_row(_step, _outcome, _result, text, payload), do: %{content: text, payload: payload}

  defp page_value(%Call{kind: :hand}, {:ok, %{output: output}}),
    do: {:ok, Aqua.PageCalls.data(output)}

  defp page_value(%Call{kind: :hand}, {:ok, output}), do: {:ok, Aqua.PageCalls.data(output)}
  defp page_value(_call, result), do: result

  defp render(nil, {:error, reason}), do: %{text: describe(reason), is_error: true}

  defp render(%Call{kind: :launch} = call, result),
    do: Binding.render(%{call | kind: :hand}, result)

  defp render(%Call{} = call, result), do: Binding.render(call, result)

  # A worker that died: a step it never dispatched is
  # skipped; a dispatched one has what it started stopped, then settles by
  # `Prima.TurnStep.unresolved/1` — one safe to run again closes as an
  # error the model may retry, a flush's closes with its outcome unknown, and one whose effect is unknown is reported
  # (`:report`, the default) so the loop stops the turn on it, or marked in
  # place (`:mark`) once the turn's stop already covers it.
  defp settle_dead(%State{} = state, %{step: step, call: call}, reason, mode \\ :report) do
    guest = guest(state)

    case Tape.step(guest, step.id) do
      {:ok, %{dispatch_state: "proposed"} = fresh} ->
        _ =
          Tape.close_step(guest, state.turn, fresh, "skipped", %{
            result: %{content: "the call was not started", payload: %{"skipped" => true}}
          })

        :ok

      {:ok, %{dispatch_state: "dispatched"} = fresh} ->
        # What the step started stops before the step settles: its child
        # execution, and the in-process handler the gate runs under the
        # step's handle. The handler also stops with the worker that
        # claimed it (`Sanctum.RunningTasks`), on that server's own
        # schedule; the cancel here orders its stop before the settlement.
        # The handle is the dead worker's own generation's, so a successor
        # generation's call is untouched.
        if id = cancellable(fresh), do: Opus.cancel(ctx(state), id)
        Aqua.Ops.cancel_call(handle(state, step))

        why = describe(reason)
        # A dead waiter handed back no completion result, so what its run
        # read comes from the child's row.
        threads = read_threads(state, fresh.child_execution_id)

        case Prima.TurnStep.unresolved(fresh) do
          :uncertain ->
            _ = Tape.join_threads(guest, state.turn, threads)
            unknown(state, fresh, why, mode)

          :unknown ->
            _ =
              close(
                state,
                fresh,
                unwrap(call),
                {:unknown, "the outcome is unknown: #{why}"},
                threads
              )

            :ok

          _replay ->
            _ =
              close(
                state,
                fresh,
                unwrap(call),
                {:error, "the call did not finish: #{why}"},
                threads
              )

            :ok
        end

      _ ->
        :ok
    end
  end

  defp unknown(_state, step, reason, :report), do: {:uncertain, step, reason}

  defp unknown(%State{} = state, step, reason, :mark) do
    _ = Tape.mark_uncertain(guest(state), state.turn, step, reason)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Stopping on an unknown outcome
  # ---------------------------------------------------------------------------

  # The one sequence for every path. A root turn: the durable stop first
  # — the step's mark, the cancel-marks, the skips, the covering aborted
  # row and the pause in one transaction — then the siblings still
  # running are cancelled and settled against it, and the pause rides out
  # of the dispatch.
  defp stop_uncertain(%State{} = state, step, reason, rest) do
    case pause_uncertain(state, step, reason) do
      {:ok, state} ->
        cancel_rest(state, rest)
        {:halt, {:paused, :uncertain}, %{state | restricted?: true}}

      {:error, error} ->
        {:halt, {:failed, error}, state}
    end
  end

  # The root held: the slot and the keeper go with the rows. The root
  # already let go around a launch: the rows alone.
  defp pause_uncertain(%State{claim: %{execution_id: id} = claim} = state, step, reason) do
    uncertain = %{
      step_id: step.id,
      generation: step.generation,
      reason: reason,
      content: @aborted_content
    }

    case Opus.pause_turn_root(ctx(state), id,
           claim: claim,
           turn_id: state.turn.id,
           fence: state.turn.fence,
           reason: "uncertain",
           uncertain: uncertain
         ) do
      {:ok, %{turn: paused} = moved} ->
        if moved[:aborted],
          do: announce(state, :message, moved.aborted)

        {:ok, %{state | turn: paused, claim: nil, since: nil, active_ms: paused.active_ms}}

      {:error, _} = error ->
        error
    end
  end

  defp pause_uncertain(%State{claim: nil, turn: %{status: "paused"}} = state, step, reason) do
    case Tape.pause_uncertain(guest(state), state.turn, %{
           step_id: step.id,
           generation: step.generation,
           reason: reason,
           content: @aborted_content
         }) do
      {:ok, %{turn: paused}} -> {:ok, %{state | turn: paused}}
      {:error, _} = error -> error
    end
  end

  defp pause_uncertain(%State{} = state, _step, _reason), do: {:error, {:no_claim, state.turn.id}}

  # What the group still had in flight when it stopped: each worker killed
  # before its child execution is cancelled, since a cancelled child answers
  # the worker waiting on it; each nested handler stopped by its handle;
  # then the step settled against the boundary.
  defp cancel_rest(%State{} = state, rest) do
    Enum.each(rest, fn %{item: %{step: step} = item, task: task} ->
      if task, do: Aqua.Loop.Worker.shutdown(task)
      if id = cancellable(step), do: Opus.cancel(ctx(state), id)
      Aqua.Ops.cancel_call(handle(state, step))
      _ = settle_dead(state, item, :cancelled, :mark)
      Aqua.Ops.release_call(handle(state, step))
    end)
  end

  # The caller-owned name of one in-chain call, for cancelling its
  # handler without the request id the loop does not hold.
  defp handle(%State{} = state, step), do: handle(state.turn, step)
  defp handle(%{id: turn_id}, step), do: {turn_id, step.id, step.generation}

  # ---------------------------------------------------------------------------
  # Launches: the root is let go around the application's own root
  # ---------------------------------------------------------------------------

  # A launch is decided again as it dispatches, as every call is
  # (`still_offered/3`): one outside the tools its job was narrowed to, or
  # no longer offered, runs nothing.
  defp run_launch(%State{} = state, %{step: step, call: {:ok, %Call{} = launch}} = item) do
    case still_offered(state, item, launch) do
      :ok ->
        launch_within(state, item)

      {:denied, message} ->
        case settle_denied(state, step, launch, message) do
          :ok -> {:ok, state}
          {:uncertain, step, reason} -> stop_uncertain(state, step, reason, [])
        end
    end
  end

  defp run_launch(%State{} = state, item), do: launch_within(state, item)

  # What a launch's decision read rides to `Aqua.Launch`, which holds the
  # run to it.
  defp launch_within(%State{} = state, %{step: step, call: call} = item) do
    guest = guest(state)
    decided = Map.get(item, :decided)

    case Tape.mark_dispatched(guest, state.turn, step) do
      {:ok, step} ->
        case pause_root(state, :launch, step.id) do
          {:ok, state} ->
            case worker(fn -> Aqua.Launch.run(ctx(state), step, decided) end) do
              {:ok, {:ok, %{execution_id: id, result: result}}} ->
                state |> close_launch(step, unwrap(call), {:ok, id, result}) |> resumed()

              {:ok, {:refused, reason}} ->
                state |> close_launch(step, unwrap(call), {:refused, reason}) |> resumed()

              # The application's run ended with its outcome unknown: the
              # turn stops here as it does on a launch whose start is not
              # known.
              {:ok, {:error, reason}} ->
                case normalise({:error, reason}) do
                  {:uncertain, why} ->
                    launch_unknown(state, step, why)

                  _failed ->
                    state |> close_launch(step, unwrap(call), {:error, reason}) |> resumed()
                end

              # Whether the application started is not known: the turn
              # stops here, its root already let go.
              {:exit, reason} ->
                launch_unknown(state, step, reason)
            end

          # The root did not let go: the launch never started.
          {:error, reason} ->
            _ = close(state, step, unwrap(call), {:error, describe(reason)})
            {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  # A launch whose outcome is unknown: what its tree read joins the turn,
  # from its root's row, and the turn stops on the step, its root already
  # let go.
  defp launch_unknown(%State{} = state, step, reason) do
    _ = Tape.join_threads(guest(state), state.turn, read_threads(state, step.child_execution_id))
    stop_uncertain(state, step, describe(reason), [])
  end

  # The launched tree's read threads join the turn in the transaction that
  # writes the step's result: on success as its completion result carries
  # them (`execution.run`'s `read_threads`), else read from its root's row;
  # on a failure read from the root's row by the id its launch was stamped
  # with. A launch refused before its run was asked for joins nothing.
  defp close_launch(state, step, call, {:ok, id, result}) do
    text = Jason.encode!(result, pretty: true)

    _ =
      Tape.close_step(guest(state), state.turn, step, "ok", %{
        result:
          result_row(step, "ok", {:ok, output(result)}, text, %{
            "tool_call_id" => call && call.tool_call_id,
            "name" => call && call.model_name,
            "is_error" => false
          }),
        execution_id: id,
        threads: launched_threads(state, step, id, result)
      })

    state
  end

  defp close_launch(state, step, call, {:refused, reason}),
    do: failed_launch(state, step, call, reason, [])

  defp close_launch(state, step, call, {:error, reason}),
    do: failed_launch(state, step, call, reason, read_threads(state, step.child_execution_id))

  # A launch that did not run is closed in its sentence, its reason kept
  # for a page's answer. A page's call of a component that is not granted
  # asks the person for the grant, as a model's asks with request_setup.
  defp failed_launch(state, step, call, reason, threads) do
    close(state, step, call, {:error, {:launch, reason}}, threads)

    with "page" <- step.purpose,
         %Call{target: ref} <- call,
         %Prima.Refusal{class: :consent_required} <- Sanctum.Refusals.classify(reason),
         do: announce(state, :consent_required, %{ref: ref, user_id: ctx(state).user_id})

    state
  end

  # What the launched component answered, which a page's call is handed
  # as the endpoint hands a frame's.
  defp output(%{result: output}), do: output
  defp output(result), do: result

  defp launched_threads(state, step, id, %{} = result) do
    case Map.get(result, :read_threads) do
      threads when is_list(threads) -> threads
      _not_carried -> read_threads(state, id || step.child_execution_id)
    end
  end

  defp launched_threads(state, step, id, _result),
    do: read_threads(state, id || step.child_execution_id)

  defp unwrap({:ok, %Call{} = call}), do: call
  defp unwrap(_), do: nil

  # The slot and the keeper go, then the rows: this process holds both.
  defp pause_root(
         %State{claim: %{execution_id: execution_id} = claim} = state,
         reason,
         launch_step_id
       ) do
    case Opus.pause_turn_root(ctx(state), execution_id,
           claim: claim,
           turn_id: state.turn.id,
           fence: state.turn.fence,
           reason: Atom.to_string(reason),
           launch_step_id: launch_step_id
         ) do
      {:ok, %{turn: paused}} ->
        {:ok, %{state | turn: paused, claim: nil, since: nil, active_ms: paused.active_ms}}

      {:error, _} = error ->
        error
    end
  end

  defp pause_root(state, _reason, _step), do: {:error, {:no_claim, state.turn.id}}

  # The launch's step is closed; the group goes on only once the root is
  # taken back. A root that cannot be taken back leaves the turn paused
  # around its launch, as its rows already say, and stops the group: no
  # call after the launch, and no model round, runs without the root's
  # slot. The runner continues the paused turn from its rows.
  # The fence is announced again once the root is back, so the runner
  # records a page's call it held while the turn was paused around the
  # launch.
  defp resumed(%State{} = state) do
    case resume_root(state, 0) do
      {:ok, state} ->
        Aqua.Loop.Stream.announce_fence(state.spec.guest, state.turn)
        {:ok, state}

      {:error, _reason} ->
        {:halt, {:paused, :launch}, state}
    end
  end

  defp resume_root(%State{} = state, tries) do
    case Opus.resume_turn_root(ctx(state), state.turn.root_execution_id,
           turn_id: state.turn.id,
           fence: state.turn.fence
         ) do
      {:ok, %{turn: resumed} = claim} ->
        {:ok, %{state | turn: resumed, claim: claim, since: now(), active_ms: resumed.active_ms}}

      {:error, _reason} when tries < length(@resume_backoff_ms) ->
        Process.sleep(Enum.at(@resume_backoff_ms, tries))
        resume_root(state, tries + 1)

      {:error, reason} = error ->
        Logger.warning(
          "[Aqua.Loop] turn #{state.turn.id} stays paused after its launch: #{inspect(reason)}"
        )

        error
    end
  end

  # ---------------------------------------------------------------------------
  # A page's calls: steps the host proposed
  # ---------------------------------------------------------------------------

  # A call a page in Aqua's browser made is a step the runner proposed
  # into the running turn (`Aqua.PageCalls`), with its call in a row of
  # its own, and the runner tells this process of it (`{:page_call,
  # turn_id}`): the notice only wakes the loop, and the rows decide what
  # runs. Each is decided and dispatched as a model's call is, by the same
  # code. They run before each model round (`page_round/1`), and while the
  # model answers (`model_wait/5`). A turn with a page's call still
  # proposed does not complete: storage refuses it (`:call_pending`, which
  # covers a call proposed after the last look) and the loop goes round
  # again. A turn opened on a page's call asks no model (`open_call/1`).

  # A turn opened on a page's call records that call as its first step,
  # now that the turn runs, and asks no model. A call whose request ended
  # is recorded as no step, and the turn ends with nothing run.
  defp open_call(%State{turn: %{message_id: id}} = state) when is_binary(id) do
    case Tape.message(guest(state), id) do
      {:ok, %{kind: "page_call"} = row} ->
        proposal = Aqua.PageCalls.proposal(state.turn, Tape.payload(row), message_id: row.id)

        case Tape.propose_call(guest(state), state.turn, proposal) do
          {:ok, _step} -> {:ok, %{state | model?: false}}
          {:error, :call_ended} -> {:ok, %{state | model?: false}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        open_program(state)
    end
  end

  defp open_call(%State{} = state), do: open_program(state)

  # A turn on a program brain opens with the host's `program.start` of the
  # brain's row at its epoch, recorded with its call's `tool_call` row as a
  # model's is (`Opus.Brain` reads the admitting call there) and decided by
  # the code that decides every call: it runs in either mode, and the
  # holder starts the program as the turn's mode says. Its dispatch attends the session
  # (`Aqua.Program`), never the terminal start a model's call makes.
  defp open_program(%State{program: %{row: row, epoch: epoch}} = state) do
    args = %{"action" => "start", "program" => row, "epoch" => epoch}
    call = Binding.resolve("program", args, tool_call_id: "start")
    recorded = recorded("program", call)

    # Replay safe: attending again reattaches to the held session, or
    # opens one, and sets the work and the configuration it runs with; it
    # never replays an input or a tool's effect, and each write is checked
    # again against the admission (`Opus.Brain`). Before a session's
    # identity is committed, another start may make a fresh session.
    proposal = %{
      kind: recorded.step_kind,
      purpose: "brain",
      tool: "program",
      action: "start",
      recovery: "replay_safe",
      idempotency_key: Tape.brain_start_key(state.turn.id),
      call: %{
        kind: "tool_call",
        content: "program",
        payload: %{
          "tool_call_id" => "start",
          "name" => "program",
          "tool" => "program",
          "action" => "start",
          "arguments" => args,
          "kind" => recorded.kind
        }
      }
    }

    with :ok <- join_startup(state),
         {:ok, _step} <- Tape.propose_call(guest(state), state.turn, proposal) do
      {:ok, %{state | model?: false}}
    end
  end

  defp open_program(%State{} = state), do: {:ok, state}

  # What the program is given before its first answer joins the turn's
  # read threads before its start is decided, as a model step's request
  # joins what it reads, so a thread's deletion finds the turn: the threads
  # the turn's posts carry, and for a thread with no native session those
  # of the thread so far a fresh session's first post carries
  # (`Aqua.Program.context_rows/2`), with the read threads of the turns
  # whose words those rows are.
  defp join_startup(%State{} = state) do
    guest = guest(state)

    with {:ok, posts} <- Tape.brain_posts(guest, state.turn),
         {:ok, context} <- startup_context(state, posts) do
      rows = posts ++ context
      read = Enum.flat_map(earlier_turns(state, rows), &Tape.turn_threads(guest, &1))
      Tape.join_threads(guest, state.turn, Tape.carried_threads(rows) ++ read)
    end
  end

  defp startup_context(%State{spec: spec} = state, [first | _]) do
    case Tape.brain(guest(state), spec.thread.id) do
      {:ok, %{session: nil}} ->
        with {:ok, rows} <- Tape.projection(guest(state), state.turn),
             do: {:ok, Aqua.Program.context_rows(rows, first.seq)}

      {:ok, _resumed} ->
        {:ok, []}

      {:error, _} = unread ->
        unread
    end
  end

  defp startup_context(_state, []), do: {:ok, []}

  defp opened_on_call?(%State{} = state), do: not asks_model?(guest(state), state.turn)

  # A turn opened on a page's call asks no model, so its brain is not
  # described when the turn is built (`Turn.build/3`).
  defp asks_model?(ctx, %{message_id: id}) when is_binary(id),
    do: not match?({:ok, %{kind: "page_call"}}, Tape.message(ctx, id))

  defp asks_model?(_ctx, _turn), do: true

  # Whether the model's last answer called nothing: no step but a page's
  # came after it.
  defp answered?(steps) do
    case steps |> Enum.reverse() |> Enum.drop_while(&(&1.purpose == "page")) do
      [%{kind: "model", purpose: "chat", dispatch_state: "closed", outcome: "ok"} | _] -> true
      _ -> false
    end
  end

  defp page_round(%State{} = state) do
    drain_notices(state.turn.id)

    case page_items(state) do
      [] -> {:continue, state}
      items -> dispatch(state, items)
    end
  end

  defp drain_notices(turn_id) do
    receive do
      {:page_call, ^turn_id} -> drain_notices(turn_id)
    after
      0 -> :ok
    end
  end

  # The page's and the program brain's calls still proposed in the turn.
  defp page_items(%State{} = state) do
    case Tape.steps(guest(state), state.turn) do
      {:ok, steps} ->
        for %{purpose: purpose, dispatch_state: "proposed"} = step <- steps,
            purpose in ["page", "brain"],
            do: %{step: step, call: recall(state, step)}

      _unread ->
        []
    end
  end

  # The model is waited for as `worker/1` waits. Meanwhile a page's call
  # the runner proposed is taken as it arrives (`take_calls/2`): one that
  # runs runs in a worker of its own beside the model, and one that is
  # refused closes. A launch, a call that needs its account set up and a
  # call that does not bind wait for the model's answer and run before the
  # round's own calls, since a launch lets the root go and the root is
  # never let go under the model's run. Once the model
  # answered no call is taken, and the page's workers still running are
  # waited for. A page's call whose outcome is unknown stops the turn at
  # once, as the group's first one does (`stop_uncertain/4`): the model's
  # worker is stopped and its child cancelled first, its read threads join
  # the turn and its step closes with no answer used.
  defp model_worker(%State{} = state, step, fun) do
    model_wait(state, step, Aqua.Loop.Worker.async(fun), nil, %{})
  end

  defp model_wait(_state, _step, nil, answer, running) when map_size(running) == 0, do: answer

  defp model_wait(%State{} = state, step, task, answer, running) do
    model_ref = task && task.ref
    turn_id = state.turn.id

    receive do
      {^model_ref, result} when model_ref != nil ->
        Process.demonitor(model_ref, [:flush])
        model_wait(state, step, nil, {:ok, result}, running)

      {:DOWN, ^model_ref, :process, _pid, reason} when model_ref != nil ->
        model_wait(state, step, nil, {:exit, reason}, running)

      {:page_call, ^turn_id} when model_ref != nil ->
        model_wait(state, step, task, answer, take_calls(state, running))

      {ref, result} when is_map_key(running, ref) ->
        Process.demonitor(ref, [:flush])
        {_done, rest} = Map.pop(running, ref)

        case result do
          {:uncertain, page_step, reason} ->
            {:uncertain, page_step, reason, stop_model(state, step, task, rest)}

          _ ->
            model_wait(state, step, task, answer, rest)
        end

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        {%{item: item}, rest} = Map.pop(running, ref)

        case settle_dead(state, item, reason) do
          {:uncertain, page_step, why} ->
            {:uncertain, page_step, why, stop_model(state, step, task, rest)}

          _ ->
            model_wait(state, step, task, answer, rest)
        end
    end
  end

  defp take_calls(%State{} = state, running) do
    taken = MapSet.new(running, fn {_ref, %{item: %{step: step}}} -> step.id end)

    state
    |> page_items()
    |> Enum.reject(&MapSet.member?(taken, &1.step.id))
    |> Enum.reduce(running, &take_call(state, &1, &2))
  end

  defp take_call(%State{} = state, %{step: step, call: {:ok, %Call{} = call}} = item, running) do
    if state.restricted? and not Policy.replay_safe?(call) do
      running
    else
      case Policy.decide(call, state.spec.offered, state.spec.mode, place(state, step)) do
        :run ->
          task = Aqua.Loop.Worker.async(fn -> run_one(state, item) end)
          Map.put(running, task.ref, %{item: item, task: task})

        # A launch lets the root go around its run: it runs once the model
        # has answered.
        {:run, _decided} ->
          running

        # Decided again with the round's own calls, which write the line.
        {:read_only, _message} ->
          running

        {refused, message} when refused in [:deny, :refuse] ->
          close(state, step, call, {:error, {:denied, message}})
          running

        _later ->
          running
      end
    end
  end

  defp take_call(_state, _item, running), do: running

  # What the model's worker started stops before the turn's stop: the
  # worker, then its child, whose read threads join the turn as a dead
  # worker's do, and its step closes as a model request that died does.
  # Answers what of the page's work still runs, for `cancel_rest/2`.
  defp stop_model(%State{} = state, step, task, rest) do
    if task, do: Aqua.Loop.Worker.shutdown(task)
    Opus.cancel(ctx(state), step.child_execution_id)
    _ = Tape.join_threads(guest(state), state.turn, read_threads(state, step.child_execution_id))

    _ =
      Tape.close_step(guest(state), state.turn, step, "error", %{
        error: "stopped: a page's call's outcome is unknown"
      })

    Map.values(rest)
  end

  # ---------------------------------------------------------------------------
  # Settling open steps on a continuation
  # ---------------------------------------------------------------------------

  # A step found open has what it started stopped (`interrupted/2`), then
  # settles by `Prima.TurnStep.unresolved/1`: a model step without its
  # response closes as an error (its request cannot be rebuilt); a
  # dispatched call that is safe to run again is opened afresh;
  # a flush's dispatched call closes with its outcome unknown and its
  # unstarted ones are skipped; a dispatched call whose effect is unknown
  # stops the turn on it — a person continues, never a replay; an
  # unstarted step is decided and dispatched once; a steer that arrived while a
  # model's turn was away skips them all (`steered?/1`).
  defp settle(%State{} = state) do
    guest = guest(state)

    with {:ok, steps} <- Tape.steps(guest, state.turn) do
      open =
        Enum.reduce(steps, [], fn
          # A delivery to a program brain is reconciled by its attendant
          # with what the resumed transcript holds (`Aqua.Program`), before
          # any of this, and never read as an uncertain call.
          %{dispatch_state: "dispatched", kind: "input"}, open ->
            open

          %{dispatch_state: "dispatched"} = step, open ->
            interrupted(state, step)

            case Prima.TurnStep.unresolved(step) do
              :unanswered ->
                _ =
                  Tape.close_step(guest, state.turn, step, "error", %{error: "not reproducible"})

                open

              :replay ->
                _ = Tape.next_generation(guest, state.turn, step, Prima.UUID7.execution_id())
                open

              :unknown ->
                _ =
                  close(
                    state,
                    step,
                    unwrap(recall(state, step)),
                    {:unknown, "the turn was interrupted"}
                  )

                open

              :uncertain ->
                [step | open]
            end

          %{dispatch_state: "proposed", purpose: "flush"} = step, open ->
            _ =
              close(
                state,
                step,
                unwrap(recall(state, step)),
                {:skipped, "the turn was interrupted"}
              )

            open

          _step, open ->
            open
        end)
        |> Enum.reverse()

      state = %{
        state
        | restricted?: open != [] or Tape.restricted?(guest, state.turn),
          steps: Enum.count(steps, &(&1.kind == "model")),
          forgot_session?: Enum.any?(steps, &forgot_session?/1),
          model?: not opened_on_call?(state) and not answered?(steps)
      }

      cond do
        open != [] ->
          [first | others] = open
          rest = Enum.map(others, &%{item: %{step: &1, call: recall(state, &1)}, task: nil})
          stop_uncertain(state, first, "the turn was interrupted", rest)

        steered?(state) ->
          _ = Tape.skip_steps(guest, state.turn, "a newer message arrived")
          {:continue, %{state | model?: true}}

        true ->
          case proposed_items(state) do
            [] -> {:continue, state}
            items -> dispatch(state, items)
          end
      end
    else
      {:error, reason} -> {:halt, {:failed, reason}, state}
    end
  end

  # What an interrupted step started stops before the step is settled,
  # advanced or closed: its child execution, and the in-process handler
  # the gate runs under the step's handle, if one still runs (it stops
  # with the worker that claimed it, `Sanctum.RunningTasks`). The handle
  # names the step's own generation, so no other turn's call or successor
  # generation is touched.
  defp interrupted(%State{} = state, step) do
    if id = cancellable(step), do: Opus.cancel(ctx(state), id)
    Aqua.Ops.cancel_call(handle(state, step))
    Aqua.Ops.release_call(handle(state, step))
  end

  defp proposed_items(%State{} = state) do
    guest = guest(state)

    with {:ok, steps} <- Tape.steps(guest, state.turn) do
      # A page's call waits for the next page round, after what was
      # decided has run: decided now, a launch would stamp the turn's read
      # threads before an earlier launch's join them, and find them stale.
      for %{dispatch_state: "proposed", kind: kind} = step <- steps,
          kind not in ["model", "input"],
          step.purpose != "page" do
        %{step: step, call: recall(state, step)}
      end
    else
      _ -> []
    end
  end

  # The call a proposed step was recorded for, from its tool_call row.
  defp recall(%State{} = state, %{message_id: message_id}) when is_binary(message_id) do
    with {:ok, row} <- Tape.message(guest(state), message_id) do
      payload = Tape.payload(row)

      Binding.resolve(payload["name"] || "", payload["arguments"] || %{},
        tool_call_id: payload["tool_call_id"]
      )
    else
      _ -> {:error, "the call's row is gone"}
    end
  end

  defp recall(_state, _step), do: {:error, "the step names no call"}

  # ---------------------------------------------------------------------------
  # Compaction
  # ---------------------------------------------------------------------------

  defp compact(%State{spec: spec} = state, rows, removed, files, flush? \\ true) do
    # Size the request the way the executor will: it encodes the input and
    # refuses it past the consented cap of the node being entered, which for
    # a model call is the catalyst, not the agent. Without this the turn
    # fails at admission on a request compaction could have made fit.
    excerpt = if state.excerpt_sent?, do: nil, else: spec.excerpt
    probe = request(state, rows, excerpt, cited(state, rows), removed, files)

    case Planner.plan(rows,
           capabilities: spec.capabilities,
           max_tokens: Request.max_tokens(spec.capabilities),
           observed_tokens: state.observed,
           new_bytes: appended_bytes(rows, state.observed_seq),
           request_bytes: encoded_size(probe),
           max_request_size: spec.request_cap
         ) do
      :fit ->
        {:ok, state, rows}

      {:compact, %{summarized_through_seq: 0}} ->
        # Nothing older than the boundary: a summary of no rows costs a model
        # call and writes a row that stands for nothing. The estimate counts
        # only transcript rows, so on a small window the system prompt and
        # tool definitions alone can ask for this every round.
        {:ok, state, rows}

      {:compact, boundary} when flush? ->
        # The flush's rows are newer than any boundary, so the plan is made
        # again over the rows as they now stand.
        case flush(state, rows, probe) do
          {:flushed, state} ->
            with {:ok, rows} <- Tape.projection(guest(state), state.turn),
                 do: compact(state, rows, removed, files, false)

          {:skipped, state} ->
            summarize(state, rows, boundary, removed)

          {:error, :superseded} = superseded ->
            superseded
        end

      {:compact, boundary} ->
        summarize(state, rows, boundary, removed)
    end
  end

  # One silent request before older rows are summarized away, so the model
  # can keep notes: `notes.keep` alone, when the member's mode runs it and
  # its offered set holds it, in a turn no unknown outcome
  # restricts, with room left for the flush, the summary and the next chat
  # request, and only when the request fits the catalyst's cap.
  defp flush(%State{spec: spec} = state, rows, probe) do
    cap = spec.request_cap

    with true <- flush_room?(state.steps, state.restricted?),
         offered = Turn.current_offered(spec),
         true <- flush_runs?(state, offered),
         request = flush_request(probe, Map.put(offered, @flush_key, "offered")),
         size when is_integer(size) and (is_nil(cap) or size <= cap) <- encoded_size(request),
         {:ok, step, opened} <- open_model_step(state, "flush", rows) do
      keep_notes(%{opened | sent_upto: highest_seq(rows)}, step, request)
    else
      {:error, :superseded} = superseded -> superseded
      _not_flushed -> {:skipped, state}
    end
  end

  # A flush runs only where a keep would: the member is offered it and is
  # in `auto`. Each kept note is decided again as it dispatches.
  defp flush_runs?(%State{} = state, offered) do
    probe = %Call{
      kind: :catalog,
      tool: @flush_tool,
      action: @flush_action,
      args: %{},
      model_name: @flush_key
    }

    Policy.decide(probe, offered, state.spec.mode, place(state)) == :run
  end

  # The gate a flush passes before the offered set is read: a turn no
  # unknown outcome restricts, with room for the flush, the summary and the
  # next chat request under the step cap.
  defp flush_room?(steps, restricted?), do: not restricted? and steps + 3 <= @max_steps

  # The flush keeps notes of the rows a summary is about to replace, so it
  # is sent without the room excerpt: nothing of the room reaches it, and
  # the request the store keeps is the one sent.
  defp flush_request(probe, offered) do
    %{"messages" => messages} = Request.without_excerpt(probe)

    %{
      probe
      | "tools" => Request.catalog_tools(Map.take(offered, [@flush_key])),
        "provider_tools" => [],
        "messages" => Request.instruct(messages, @flush_instruction)
    }
  end

  # The reply's text is not the turn's and is not recorded; its calls are.
  # The flush continues the brain's session, so the session its answer or
  # its refusal names is kept as a chat round's is (`on_response/3`,
  # `refused/3`), and the next request continues it: a brain that counts
  # its usage against the session it is handed counts the flush once.
  defp keep_notes(%State{} = state, step, request) do
    case model_call(state, step, request, nil) do
      {:ok, data} ->
        {resolved, tool_calls} = resolve_calls(state, step, List.wrap(data["content"]))
        usage = data["usage"] || %{}

        with {:ok, session} <- Prima.Model.response_session(data),
             {:ok, %{calls: recorded}} <-
               Tape.record_response(guest(state), state.turn, step, %{
                 text: nil,
                 usage: usage,
                 stop_reason: data["stop_reason"],
                 session: session,
                 generation: state.generation,
                 tool_calls: tool_calls
               }) do
          state = count_usage(%{state | session: session || state.session}, usage)

          Enum.zip_with(recorded, resolved, fn %{step: call_step}, {_block, call} ->
            keep_note(state, call_step, call)
          end)

          {:flushed, state}
        else
          {:error, :superseded} = superseded ->
            superseded

          {:error, reason} ->
            _ =
              Tape.close_step(guest(state), state.turn, step, "error", %{error: describe(reason)})

            {:skipped, state}
        end

      {:error, :superseded} = superseded ->
        superseded

      {:error, %{"type" => _} = error} ->
        closed = refused(state, error, describe(error))
        _ = Tape.close_step(guest(state), state.turn, step, "error", closed)
        {:skipped, %{state | session: closed[:session] || state.session}}

      {failure, reason} when failure in [:error, :exit] ->
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: describe(reason)})
        {:skipped, state}
    end
  end

  # A flush runs `notes.keep` and nothing else: it is decided again as the
  # call dispatches, and an unknown outcome is
  # recorded on the call without stopping or restricting the turn.
  defp keep_note(
         %State{} = state,
         step,
         {:ok, %Call{kind: :catalog, tool: @flush_tool, action: @flush_action} = call}
       ) do
    content = call.args["content"]

    if is_binary(content) and byte_size(content) > @flush_note_max_bytes do
      close(
        state,
        step,
        call,
        {:error,
         {:denied, "a note kept before a summary holds at most #{@flush_note_max_bytes} bytes"}}
      )
    else
      item = %{step: step, call: {:ok, call}}

      case worker(fn -> run_one(state, item) end) do
        {:ok, {:uncertain, step, reason}} ->
          close(state, step, call, {:unknown, "the note's outcome is unknown: #{reason}"})

        {:ok, _settled} ->
          :ok

        {:exit, reason} ->
          settle_dead(state, item, reason)
      end
    end
  end

  defp keep_note(%State{} = state, step, {:ok, %Call{} = call}),
    do:
      close(
        state,
        step,
        call,
        {:error, {:denied, "only #{@flush_key} runs while the thread is summarized"}}
      )

  defp keep_note(%State{} = state, step, {:error, message}),
    do: close(state, step, nil, {:error, message})

  # `removed` is the round's read (`removed_files/2`): the rows a summary
  # stands for are among those the round's request carried, so a
  # compaction lists nothing of its own.
  defp summarize(%State{spec: spec} = state, rows, boundary, removed) do
    previous = rows |> Enum.filter(&(&1.kind == "compaction")) |> List.last()

    # Only what the previous summary does not already stand for, and
    # never a compaction row: `Request.messages/2` renders the latest one
    # as a summary block, so leaving it in sends the previous summary
    # twice — once rendered, once as `previous_summary` below.
    since = if previous, do: Tape.payload(previous)["first_kept_seq"] || 0, else: 0

    older =
      Enum.filter(rows, fn row ->
        row.kind != "compaction" and row.seq >= since and
          row.seq < boundary.first_kept_seq
      end)

    request =
      Planner.summary_request(Request.messages(older, removed),
        model: spec.model,
        previous_summary: previous && previous.content
      )

    case open_model_step(state, "compaction", rows) do
      {:error, :step_cap} -> {:error, :step_cap}
      {:error, reason} -> skip_compaction(state, rows, reason)
      {:ok, step, state} -> commit_summary(state, rows, boundary, request, step)
    end
  end

  defp commit_summary(%State{} = state, rows, boundary, request, step) do
    with {:ok, data} <- model_call(state, step, request, nil),
         summary =
           data["content"]
           |> List.wrap()
           |> Enum.filter(&(&1["type"] == "text"))
           |> Enum.map_join("", & &1["text"]),
         {:ok, summary} <- Planner.summary_text(summary),
         {:ok, _} <-
           Tape.record_response(guest(state), state.turn, step, %{
             text: nil,
             usage: data["usage"] || %{},
             stop_reason: data["stop_reason"],
             tool_calls: []
           }),
         {:ok, _} <-
           Tape.append_compaction(guest(state), state.turn, %{
             summary: summary,
             first_kept_seq: boundary.first_kept_seq,
             summarized_through_seq: boundary.summarized_through_seq,
             step_id: step.id
           }),
         {:ok, projected} <- Tape.projection(guest(state), state.turn) do
      {:ok, %{state | observed: nil}, projected}
    else
      {:error, :superseded} ->
        {:error, :superseded}

      other ->
        # The summary request answered nothing the turn can commit; a step
        # already closed by its response stays as it closed.
        _ = Tape.close_step(guest(state), state.turn, step, "error", %{error: failure(other)})
        skip_compaction(state, rows, other)
    end
  end

  defp highest_seq([]), do: 0
  defp highest_seq(rows), do: rows |> Enum.map(& &1.seq) |> Enum.max()

  # What has arrived since the response whose token count we are reusing —
  # a steer, a tool result, a reply. Counting the estimate alone
  # would price the request as it stood one round ago.
  defp appended_bytes(rows, since) do
    rows
    |> Enum.filter(&(&1.seq > since))
    |> Enum.map(fn row ->
      byte_size(row.content || "") +
        byte_size(if(is_binary(row.payload), do: row.payload, else: ""))
    end)
    |> Enum.sum()
  end

  # nil rather than a guess when the request cannot be encoded: the byte
  # trigger stands down and the token estimate decides alone.
  defp encoded_size(request) do
    case Jason.encode(request) do
      # What the executor weighs is the invocation envelope, not the bare
      # request, so the envelope's own bytes are counted here too. Without
      # them a request just under the cap passes this check and is refused
      # where it is enforced.
      {:ok, json} -> byte_size(json) + @envelope_bytes
      {:error, _} -> nil
    end
  end

  defp failure({kind, reason}) when kind in [:error, :exit], do: describe(reason)
  defp failure(other), do: describe(other)

  # A compaction that did not land leaves the rows as they were; the
  # model step it opened stays counted.
  defp skip_compaction(%State{} = state, rows, reason) do
    Logger.warning("[Aqua.Loop] compaction skipped for turn #{state.turn.id}: #{inspect(reason)}")
    {:ok, state, rows}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp replay_safe?(%Call{} = call), do: Policy.replay_safe?(call)

  # A post past a model turn's boundary skips what the turn had not run,
  # since the model answers the newer message instead. A program turn's
  # posts are deliveries its attendant writes once the turn's start is
  # allowed (`Aqua.Program`), so none skips a step of it, its start least.
  defp steered?(%State{program: %{}}), do: false
  defp steered?(%State{} = state), do: Tape.steer_pending?(guest(state), state.turn)

  # A program brain's turn has no deadline: its job ends on Stop, with its
  # thread, or after the program's own silence (`Aqua.Program`).
  defp over_deadline?(%State{program: %{}}), do: false

  defp over_deadline?(%State{since: since, active_ms: active_ms, spec: %Turn{deadline_ms: limit}}) do
    running = if since, do: now() - since, else: 0
    active_ms + running >= limit
  end

  defp over_deadline?(_state), do: false

  # Each entry names the call's tool and the sentence a person reads for
  # it, from the one table a kept step is worded by too (`Aqua.Steps`).
  defp activity(%State{} = state, items, status) do
    named =
      Enum.map(items, fn %{call: call} = item ->
        purpose = item[:step] && item.step.purpose

        case call do
          {:ok, call} -> {call.model_name, Aqua.Steps.sentence(call.tool, call.action, purpose)}
          _unbound -> {"tool", Aqua.Steps.sentence(nil, nil, purpose)}
        end
      end)

    activity =
      case status do
        :running ->
          state.activity ++
            Enum.map(named, fn {tool, sentence} ->
              %{tool: tool, sentence: sentence, status: :running, preview: nil}
            end)

        :done ->
          Enum.reduce(named, state.activity, &mark_done(&2, &1))
      end

    announce(state, :tool_activity, activity)
    %{state | activity: activity}
  end

  # A program brain's own tool, by the name its attendant gives, running
  # from its start to its end: an entry of the same list, worded as a tool
  # no step names, since none is kept of it (`Aqua.Program`).
  defp own_activity(%State{} = state, name, phase) do
    sentence = Aqua.Steps.sentence(nil, nil, nil)

    activity =
      case phase do
        "start" ->
          state.activity ++ [%{tool: name, sentence: sentence, status: :running, preview: nil}]

        "end" ->
          mark_done(state.activity, {name, sentence})
      end

    announce(state, :tool_activity, activity)
    %{state | activity: activity}
  end

  # The newest running entry for `tool` is done; none running adds a done one.
  defp mark_done(activity, {tool, sentence}) do
    index =
      activity
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {entry, i} ->
        entry.tool == tool and entry.status == :running and i
      end)

    case index do
      nil -> activity ++ [%{tool: tool, sentence: sentence, status: :done, preview: nil}]
      i -> List.update_at(activity, i, &%{&1 | status: :done})
    end
  end

  defp system_row(%State{} = state, text) do
    Tape.append(guest(state), state.turn.thread_id, %{
      author: Prima.Author.system(),
      sent_by: state.turn.agent,
      kind: "system",
      content: text,
      turn_id: state.turn.id,
      execution_id: state.turn.root_execution_id
    })
  end

  defp announce(%State{} = state, kind, data),
    do: Tape.announce(guest(state), state.turn.thread_id, kind, data)

  # A worker is waited for until it answers or dies, with no clock of the
  # loop's over it, since what it runs is bounded where it runs. A
  # catalyst run, a hand's, a brain's or a launched root's, ends at the
  # deadline admission gave it (`Opus.Admission`), which the worker
  # service enforces and reports, so its expiry closes the run lost and
  # costs the athanor nothing (`Opus.Attempt`), where a waiter stopped by
  # a clock here would be a kill counted against it; a worker service
  # that stops answering is lapsed (`Opus.WorkerWatch`), and a run whose
  # exit is never reported is stopped once its lease expires
  # (`Opus.Sweeper`). A catalog or external call's handler is answered by
  # the gate's own bound (`Sanctum.Dispatch`, "A handler that does not
  # answer"). The `ui` event and the step's own rows are host calls under
  # the store's bounds. A person's cancel stops the holder at once
  # (`abort/4`), a lost lease kills it (`Opus.LeaseWatch`), and the
  # holder's death stops its workers (`Aqua.Loop.Worker`).
  defp worker(fun) do
    fun |> Aqua.Loop.Worker.async() |> Aqua.Loop.Worker.yield(:infinity)
  end

  # The request the store keeps: the one sent, less the room excerpt the
  # builder placed last — sent to the model, recorded as excluded on the
  # step, never retained.
  defp retained(_request, nil), do: nil
  defp retained(request, _excerpt), do: Request.without_excerpt(request)

  defp digest(request) do
    case Prima.JCS.hash(request) do
      {:ok, digest} -> digest
      _ -> nil
    end
  end

  defp describe({:model_refused, _catalyst, %{"message" => message}}) when is_binary(message),
    do: "The model could not be described: #{message}"

  defp describe({:setup_required, {app, _need, account}}),
    do: "setup_required: the account #{inspect(account)} is not granted to #{app}"

  defp describe({:unknown_model, model}), do: "#{model} is not a model its catalyst knows"

  defp describe({:read_only_unheld, title, brain}), do: Aqua.Models.unheld_sentence(title, brain)

  defp describe(:tool_policy_retired), do: Prima.AgentRef.tool_policy_retired()

  defp describe({:tools_invalid_entry, entry}),
    do: Prima.AgentRef.tools_entry_invalid(entry)

  defp describe(:no_model), do: "The agent names no model"

  # A schedule's turn whose fire another turn already took up: on another
  # server after a takeover, or by the turn that started it first.
  defp describe(:occurrence_not_claimed),
    do: "This scheduled run was already taken up by another turn, so this one did not start."

  defp describe(:read_threads_unrecorded),
    do: "What the model read could not be recorded on the turn, so its answer was not used"

  defp describe(reason) when is_binary(reason), do: reason

  # A refusal for ownership (this server has not won its slot, or has lost
  # it) reads as its declared sentence, which says to retry: the turn did
  # not run, and the message can be sent again.
  defp describe(reason) when reason in [:not_owner, :control_plane_lost, :slot_not_held],
    do: Prima.Refusal.message(reason)

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: Aqua.Ops.render_refusal(reason)

  # This member still holds its slot in the cell. Asked again at each point
  # of the abort that would write, never once for the whole of it: a
  # member that lost its slot between two writes must not take the second,
  # and the rows are the holder's to settle.
  defp held do
    if Arca.ControlPlane.held?(), do: :ok, else: {:error, :control_plane_lost}
  end

  defp guest(%State{spec: %Turn{guest: guest}}), do: guest
  defp ctx(%State{spec: %Turn{ctx: ctx}}), do: ctx
  defp now, do: System.monotonic_time(:millisecond)
end
