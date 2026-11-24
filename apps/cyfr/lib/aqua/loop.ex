# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop do
  @moduledoc """
  The agent loop: one turn, run by the process that holds its root.

  The loop decides and runs every call of a turn: each is decided
  (`Aqua.Loop.Policy`) and nothing is asked, a refusal is closed as its
  own result, reads run beside each other and everything else alone, each
  in a worker of its own. A launch stands on its component's grant:
  `Aqua.Launch` consumes it while the root is paused around it, so the
  application takes a root of its own, and holds it to what the decision
  read; the pause ends when the launch does, and a continuation resumes
  the turn from the rows. A launch naming an account its app's own
  profile does not bind ends the turn as setup required, naming the app
  and the account: the person grants it there, and the retry is a new
  turn, since this one's authority never widens.

  Every turn, Aqua's and each crew member's, claims its root under the
  crew's one grant, Aqua's (`Compendium.AgentSource`): toward CYFR the
  caller is Aqua, and the member whose turn it is stays the worker the
  turn's row, its posts and its usage name.

  Every write goes through `Aqua.Tape` under the actor's guest-planed
  context; the loop process never runs a child on itself. A loop writes
  only under the fence it acquired: it never reads the fence again from
  the turn's row, and each row it writes, a failure's sentence among them,
  presents that fence in the transaction that writes it, so a loop whose
  turn was taken writes nothing: it is cancelled, or refused its resume.

  ## A turn's harness

  Every turn but one a page's call opened is answered by its harness
  (`Aqua.Harness`): the model's through its catalyst, or a program's. The
  loop opens it, through its own start when it asks for one, decided as
  any call is, holds its handle in this process's registration, says
  that the rows moved whenever the thread moves (`{:moved, turn_id}`, from
  the runner) or the loop waits, decides and runs what it asks, and waits
  on what it says. The loop never asks which harness it holds. It
  lives while a loop holds the turn, a launch's wait and a steer at the
  finish included: whatever way the loop returns, an end or a pause, it
  is stopped and its session's close waited on first
  (`c:Aqua.Harness.stop/1`). A close that was not answered is Opus's: it
  owes it and retries it, and the next start is admitted or refused on
  what is true then. Aqua knows nothing else of a process.

  ## A scheduled turn

  A turn a schedule's line started (origin `schedule`, `Aqua.ScheduleTurns`)
  runs as any turn of its member. A refused call is no question, so the
  turn goes on without it.

  ## The turn's read threads

  Every way a turn reads a thread's posts joins that thread to the turn's
  read threads (`turns.read_threads`) before they are read, so deleting a
  thread finds every turn that read it. A request's rows, and what a
  program is given, go through the one rule before they are worded
  (`Aqua.Reader.join/5`, `Arca.TurnStorage.join_read/3`), which reads
  them again as they stand, says which the turn is handed, and records
  the threads those depend on. A call's result closes with the threads
  it carries (`Aqua.Loop.Policy.threads_of/3`). The room excerpt is the
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
  alias Aqua.Loop.{Clock, Policy, Turn}
  alias Aqua.{Reader, Tape}
  alias Sanctum.Context

  # A root turn's holder on this boot registers here (`holder/1`).
  @holders Aqua.RunnerRegistry
  # The source every turn of the crew claims its root under, Aqua's and
  # each crew member's alike: the crew's one grant (`Compendium.AgentSource`).
  # The member stays the worker the turn's row names (`turns.agent`).
  @grant Prima.AgentRef.soul_ref()
  @resume_backoff_ms [500, 2_000, 8_000]
  @aborted_content "a call's outcome is unknown; tools may have partially executed"
  # What a harness tells of its work that any of the loop's waits takes
  # (`harness_event/2`); an ask and an end wait for the harness's own wait.
  @told [:took, :usage, :activity, :text]
  # A write refused for one of these found the turn taken or over: whoever
  # took it says what became of it.
  @taken [:superseded, :not_open, :already_finished]
  @refused_key "authentication"
  # A note flush's step runs `notes.keep` alone (`Aqua.Loop.Policy.flush_call/0`),
  # each note this large at most.
  @flush_call Aqua.Loop.Policy.flush_call()
  @flush_note_max_bytes 64 * 1024

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :spec,
      :claim,
      :turn,
      # The turn's active time, which its harness reads (`Aqua.Loop.Clock`).
      :clock,
      activity: [],
      # The places in `activity` of a program brain's own tools still shown
      # running (`own_activity/3`), settled when its native turn or its
      # session ends (`settle_own/1`).
      own: [],
      # A call's outcome is unknown: only replay-safe reads run from here.
      restricted?: false,
      # The turn's harness (`Aqua.Harness`), `{module, handle}`, and this
      # loop's monitor of it, from its open to the loop's return.
      harness: nil,
      watch: nil,
      # What the engine reads of the turn's harness, from its pin
      # (`Aqua.Harness.facts/1`), set as the turn's spec is built.
      facts: nil,
      # A write on the turn's path failed (`:unkept`), or was refused for a
      # moved fence (`:taken`): the loop returns, and its return is an end
      # that could not be written, or cancelled, whatever it was
      # (`conclude/2`).
      unkept: nil
    ]
  end

  @type result ::
          :completed
          | {:paused, :launch | :uncertain}
          | {:failed, term()}
          | :cancelled
          | {:uncertain, term()}
          | {:unwritten, result()}

  # ---------------------------------------------------------------------------
  # Entry points
  # ---------------------------------------------------------------------------

  @doc """
  Run an accepted turn as its root: claim the root on this process,
  start the turn with its pins, and loop. `opts`: `:ctx` (the actor's
  external-plane context), `:turn_id`. Ends the turn itself on every
  outcome but a pause: `{:unwritten, result}` is an end that could not be
  written, which its caller settles as a loop's that died. A turn another
  process on this boot holds is
  refused `{:error, :held}` before anything is read (`holder/1`).
  """
  @spec run(keyword()) :: result() | {:error, term()}
  def run(opts) do
    ctx = Keyword.fetch!(opts, :ctx)
    turn_id = Keyword.fetch!(opts, :turn_id)

    hold(ctx, turn_id, fn ->
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

          # The source has no consent to run under, or one that no longer
          # covers what the crew may use: the person is asked for it.
          {:error, :no_profile} ->
            setup_required(ctx, turn)

          {:error, {:consent_required, _}} ->
            setup_required(ctx, turn)

          {:error, {:profile_unavailable, _}} ->
            setup_required(ctx, turn)

          {:error, reason} ->
            reason = unclaimed(ctx, turn, reason)
            say_unrun(ctx, turn, reason)
            finish = Tape.finish(ctx, turn, "failed", %{error: describe(reason)})
            unrun(turn, {:failed, reason}, finish)
        end
      end
    end)
  end

  # Why a root was not claimed, as the person can act on it. Every turn of
  # the crew claims under Aqua's grant, and Aqua's file that is refused has
  # no row to grant (`Compendium.AgentSource` projects only what parses),
  # so the root of every turn is refused as an unknown component before a
  # file is read: Aqua's own refusal is the reason then, and a file still
  # holding the retired `tool_policy`, or a `tools` entry that names no
  # one action, gets its line.
  defp unclaimed(ctx, _turn, reason) do
    case Aqua.AgentConfig.roster_and_soul(ctx) do
      {:ok, _roster, refused} -> if soul_line?(refused), do: refused, else: reason
      _other -> reason
    end
  end

  defp soul_line?(:tool_policy_retired), do: true
  defp soul_line?(:seat_has_brain), do: true
  defp soul_line?({:tools_invalid_entry, _entry}), do: true
  defp soul_line?(_refused), do: false

  # The root is held but the turn never ran: ended with the actor's own
  # context, since no spec was built to carry it, and the root closed by
  # the release when the turn never came to carry it. A brain not set up
  # is said as the brain's own state (`Aqua.Loop.Turn`), a line that
  # points at the Aqua page.
  defp never_ran(ctx, claim, turn, reason) do
    say_unrun(ctx, turn, reason)
    end_unrun(ctx, claim, turn, reason)
  end

  # A turn that never ran says why in the thread where the person can act
  # on it: a brain whose provider refused its key, in the provider's
  # words, a member whose file still holds the retired `tool_policy`
  # or a `tools` entry that names no one action, and a soul's file that
  # names a brain of its own, in the sentence that says what to change,
  # and Aqua whose crew member does not stand, or a program brain whose
  # row does not, in the sentence the Aqua page says.
  defp say_unrun(ctx, turn, {:model_refused, _catalyst, %{"type" => @refused_key} = error}),
    do: unrun_line(ctx, turn, Prima.Refusal.message({:model_key_refused, error["message"]}))

  defp say_unrun(ctx, turn, :tool_policy_retired),
    do: unrun_line(ctx, turn, Prima.AgentRef.tool_policy_retired())

  defp say_unrun(ctx, turn, :seat_has_brain),
    do: unrun_line(ctx, turn, Prima.AgentRef.seat_has_brain())

  # Aqua whose crew member does not stand, and a brain that is a program
  # whose row does not, in the sentence the Aqua page says too.
  defp say_unrun(ctx, turn, {:aqua_runs_on, _state, _member} = reason),
    do: unrun_line(ctx, turn, describe(reason))

  defp say_unrun(ctx, turn, {:crew_unready, _member, _state} = reason),
    do: unrun_line(ctx, turn, describe(reason))

  defp say_unrun(ctx, turn, {:tools_invalid_entry, _entry} = reason),
    do: unrun_line(ctx, turn, describe(reason))

  defp say_unrun(_ctx, _turn, _reason), do: :ok

  defp unrun_line(ctx, turn, line), do: Tape.append_line(ctx, turn, line)

  defp end_unrun(ctx, claim, turn, reason) do
    error = describe(reason)
    Opus.suspend_lease_watch(claim.keeper)
    finish = Tape.finish(ctx, turn, "failed", %{error: error})
    ended = unrun(turn, {:failed, reason}, finish)

    # A root closed as failed takes no successor, and recovery adopts a
    # turn whose end was not written by opening one.
    failed = if match?({:unwritten, _result}, ended), do: nil, else: error
    Opus.release_turn_root(ctx, claim.execution_id, claim: claim, failed: failed)
    ended
  end

  defp setup_required(ctx, turn) do
    finish = Tape.finish(ctx, turn, "failed", %{error: "setup_required"})

    Tape.announce(ctx, turn.thread_id, :consent_required, %{
      ref: @grant,
      user_id: ctx.user_id
    })

    unrun(turn, {:failed, :setup_required}, finish)
  end

  # A turn that never ran answers why, whoever wrote its end: only an end
  # that could not be written is answered as one.
  defp unrun(_turn, result, {:error, reason}) when reason in @taken, do: result
  defp unrun(turn, result, finish), do: finished(turn, "failed", result, finish)

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

    hold(ctx, turn_id, fn ->
      with {:ok, turn} <- Tape.turn(ctx, turn_id),
           {:ok, claim, turn} <- reclaim(ctx, turn, mode),
           {:ok, spec} <- rebuilt(ctx, turn) do
        turn = spec.turn

        state = %State{
          spec: spec,
          facts: Aqua.Harness.facts(spec),
          claim: claim,
          turn: turn,
          clock: Clock.new(turn.active_ms)
        }

        Aqua.Loop.Stream.announce_fence(spec.guest, turn)

        case settle(state) do
          {:continue, state} -> conclude(state, loop(state))
          {:halt, result, state} -> conclude(state, {result, state})
        end
      end
    end)
  end

  # The spec of a continued turn, built from its row alone. A pin that no
  # longer loads, Aqua's or its brain's, bound again or taken back, ends
  # the turn as one that moved on, said in its thread as it is mid-turn;
  # the runner ends it with the same sentence as its error.
  defp rebuilt(ctx, turn) do
    with {:ok, authority} <- pinned_authority(ctx, turn),
         {:ok, spec} <- Turn.build(ctx, turn, authority: authority, excerpt?: false) do
      {:ok, spec}
    else
      {:error, :consent_moved} = moved ->
        _ = unrun_line(ctx, turn, describe(:consent_moved))
        moved

      refused ->
        refused
    end
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
  # awaits this loop can start the turn's next loop at once. Its
  # registration holds the turn's harness once one is open (`Aqua.Harness`),
  # which lives while this loop holds the turn: it is stopped before the
  # loop returns, and one whose loop died stops by itself.
  defp hold(%Context{}, turn_id, fun) do
    key = {:turn, turn_id}

    case Registry.register(@holders, key, nil) do
      {:ok, _} ->
        try do
          fun.()
        after
          :ok = stop_harness(turn_id)
          Registry.unregister(@holders, key)
        end

      {:error, {:already_registered, _holder}} ->
        {:error, :held}
    end
  end

  # The harness this process holds for `turn_id`, if one is open.
  defp held_harness(turn_id) do
    case Registry.lookup(@holders, {:turn, turn_id}) do
      [{_pid, {module, handle}}] -> {module, handle}
      _none -> nil
    end
  end

  # The turn's harness on this boot is stopped (`c:Aqua.Harness.stop/1`):
  # its session is closed, its writes first.
  defp stop_harness(turn_id) do
    case held_harness(turn_id) do
      {module, handle} -> module.stop(handle)
      nil -> :ok
    end
  end

  @doc """
  Abort a turn from outside its process: the fence of the turn is raised;
  the turn's harness is stopped, so that it writes nothing more;
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
         :ok <- stop_harness(turn.id),
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
    with :ok <- stop_harness(turn_id),
         :ok <- stop_aborted(stop, holder(turn_id)) do
      Enum.reduce(steps, :ok, fn step, result ->
        case cancel_dispatched(ctx, %{id: turn_id}, step) do
          :ok -> result
          error -> if result == :ok, do: error, else: result
        end
      end)
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
             @grant,
             [turn_id: turn.id, thread_id: turn.thread_id, envelope: %{"turn" => turn.id}] ++
               fire_of(turn)
           ) do
      with {:ok, snapshot} <- Compendium.agent_snapshot(ctx, turn.agent),
           :ok <- consented_release(ctx, claim.authority, snapshot),
           # A server's line that no longer stands as its turn first starts
           # asks no model: the turn ends with nothing run. A store that
           # cannot say ends it as any store failure after the claim does.
           {:ok, stands?} <- Tape.line_stands(ctx, turn),
           # The brain's own grant is on the turn's row from its start, in
           # the write that holds Aqua's, so no runner's death leaves a
           # started turn whose recovery could choose a brain grant: a turn
           # that asks no model pins none and loads none.
           {:ok, brain} <-
             Turn.brain_pin(
               ctx,
               turn,
               snapshot.agent,
               claim.budget_id,
               stands? and asks_model?(ctx, turn)
             ),
           {:ok, started} <-
             Tape.start_turn(
               ctx,
               turn,
               Map.merge(brain, %{
                 root_execution_id: claim.execution_id,
                 attempt: claim.attempt,
                 budget_id: claim.budget_id,
                 profile_id: claim.authority.profile_id,
                 consent_id: claim.authority.consent_id,
                 agent_revision_digest: snapshot.revision_digest,
                 agent_capability_digest: snapshot.capability_digest,
                 recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
               })
             ),
           {:ok, spec} <- Turn.build(ctx, started, authority: claim.authority) do
        {:ok,
         %State{
           facts: Aqua.Harness.facts(spec),
           spec: spec,
           claim: claim,
           turn: spec.turn,
           clock: Clock.new(started.active_ms)
         }}
      else
        {:error, reason} -> {:error, {:after_claim, claim, turn, reason}}
      end
    end
  end

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
    case Opus.authority_for(ctx, {:id, profile_id}, @grant, budget_id: turn.budget_id) do
      {:ok, %{consent_id: consent_id} = authority} when consent_id == turn.consent_id ->
        {:ok, authority}

      {:ok, _moved} ->
        {:error, :consent_moved}

      {:error, _} = error ->
        error
    end
  end

  defp pinned_authority(_ctx, _turn), do: {:error, :no_pin}

  # The tools the turn pinned must be those of the release the loaded
  # grant names for its source, Aqua's, as the tree and the brains stand
  # once the file is pinned, and the grant's tool servers exactly those
  # its outside entries (`server:tool`) name, each with exactly the tools
  # named of it as its patterns: Aqua's file edited past its
  # grant is refused, never run under the old grant, whichever member's
  # turn it is. A crew member's own file is in no grant, so its edit
  # refuses nothing here.
  defp consented_release(ctx, %{activation: activation} = authority, %{agent: agent}) do
    with {:ok, row} <- Compendium.crew_grant_row(ctx),
         consented when is_binary(consented) <- Map.get(activation, @grant),
         true <- consented == row.release_digest,
         true <- Enum.sort(agent.tools) == row.manifest["caps"]["tools"],
         true <- granted_servers(authority) == listed_servers(agent.tools) do
      :ok
    else
      {:error, reason} when reason != :not_found -> {:error, reason}
      _moved -> {:error, :agent_changed}
    end
  end

  defp granted_servers(%{resources: %{tool_servers: servers}}) when is_list(servers),
    do: servers |> Enum.map(&{&1.server_name, Enum.sort(&1.tool_patterns)}) |> Enum.sort()

  defp granted_servers(_none), do: []

  defp listed_servers(tools) do
    pairs =
      for key <- tools, [server, tool] <- [String.split(key, ":", parts: 2)], do: {server, tool}

    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {server, tools} -> {server, tools |> Enum.uniq() |> Enum.sort()} end)
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # Ending
  # ---------------------------------------------------------------------------

  # The one terminal transaction, then the local cleanup — from this
  # process, which holds the slot. A paused turn already let it go. The
  # keeper is suspended before the write, so no renewal finds the root
  # ended and exits this process before the release stops it; a steer that
  # keeps the turn going resumes it. Every return of the loop comes here,
  # and here alone decides what a write on the turn's path that was not
  # kept makes of it (`kept/2`).
  defp conclude(%State{} = state, {result, ended}) do
    case kept(result, ended) do
      {:paused, _} = result ->
        unwatch(ended)
        result

      # The turn's harness was stopped by its Stop (`abort/4`,
      # `abort_ended/4`), which moved the turn's fence or ended it in
      # storage first: whatever this loop wrote would be refused, so it
      # writes nothing and leaves the turn to the Stop, as a loop the Stop
      # killed would. Nothing of it can then be stopped in a write.
      :stopped ->
        unwatch(ended)
        :cancelled

      # A write on the turn's path that failed is never dropped: the runner
      # settles the turn as a loop's that died (`Aqua.Runner`).
      {:unwritten, _} = result ->
        unwatch(ended)
        release(ended)
        result

      result ->
        {status, error} = terminal(result)
        if status != "completed", do: skip_pages(ended)
        suspend_keeper(ended)

        case Tape.finish(ctx(state), ended.turn, status, %{error: error}) do
          # A steer landed while the last answer was written: the turn goes
          # on to answer it.
          {:error, :steer_pending} ->
            resume_keeper(ended)
            conclude(state, loop(ended))

          # A page's call was proposed after the last look: the turn goes
          # on to dispatch it.
          {:error, :call_pending} ->
            resume_keeper(ended)
            conclude(state, loop(ended))

          finish ->
            final = finished(ended.turn, status, result, finish)
            unwatch(ended)
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

  defp finished(turn, status, result, finish) do
    case finish do
      {:ok, _} ->
        result

      # A moved fence wins: the loop is cancelled.
      {:error, reason} when reason in @taken ->
        :cancelled

      other ->
        # Saying "completed" while the row still says "running" puts the
        # runtime and the rows in disagreement, and the runner would take
        # the next message believing this one had landed. The runner
        # settles it as a loop's that died (`Aqua.Runner`).
        Logger.error(
          "[Aqua.Loop] turn #{turn.id} could not be finished as #{status}: " <>
            "#{inspect(other)}"
        )

        {:unwritten, result}
    end
  end

  defp terminal(:completed), do: {"completed", nil}
  defp terminal(:cancelled), do: {"cancelled", "stopped"}
  defp terminal({:failed, reason}), do: {"failed", describe(reason)}
  defp terminal({:uncertain, reason}), do: {"uncertain", describe(reason)}

  # The loop waits on its harness no more, whose end is now its own stop.
  defp unwatch(%State{watch: watch}) when is_reference(watch),
    do: Process.demonitor(watch, [:flush])

  defp unwatch(%State{}), do: :ok

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

  # What the loop returns once a write on its turn's path was not kept,
  # whichever way it returns, an end or a pause: a write refused for a
  # moved fence leaves the turn to whoever took it, this loop cancelled,
  # and any other is an end that could not be written, which the runner
  # settles as a loop's that died (`Aqua.Runner`).
  defp kept(:stopped, %State{}), do: :stopped
  defp kept(result, %State{unkept: nil}), do: result
  defp kept(_result, %State{unkept: :taken}), do: :cancelled
  defp kept({:unwritten, _} = result, %State{unkept: :unkept}), do: result
  defp kept(result, %State{unkept: :unkept}), do: {:unwritten, result}

  @doc false
  def loop(%State{} = state) do
    case step(state) do
      {:continue, %State{unkept: nil} = state} -> loop(state)
      # A write on the turn's path was not kept: the loop goes no further.
      {:continue, state} -> {{:failed, :write_failed}, state}
      {:halt, result, state} -> {result, state}
    end
  end

  # One step for every turn: a page's calls and what was asked, then the
  # turn's harness.
  defp step(%State{} = state) do
    case page_round(state) do
      {:continue, %State{unkept: nil} = state} -> harness_round(state)
      continued_or_halt -> continued_or_halt
    end
  end

  # The harness's round: once its handle is held, the turn waits on it
  # (`harness_wait/1`). Until then the rows say how it opens: first, with
  # nothing admitted; again, with the start it was admitted (a turn that
  # goes on in another process); or not at all, for a turn a page's call
  # opened, which ends with what its steps did. A start that failed says
  # why in the thread's own line, as an end after the hand-over does: the
  # start's result is a step's, which the thread never draws as a post.
  defp harness_round(%State{harness: {_module, _handle}} = state), do: harness_wait(owe(state))

  defp harness_round(%State{} = state) do
    case admission(state) do
      {:ok, nil} ->
        if asks_model?(guest(state), state.turn),
          do: opened_round(state, opened(state, nil)),
          else: {:halt, :completed, state}

      {:ok, %{dispatch_state: "closed", outcome: "ok"} = start} ->
        opened_round(state, opened(state, start))

      {:ok, %{dispatch_state: "closed", error: error}} when is_binary(error) ->
        harness_failed(state, error)

      {:ok, _unstarted} ->
        harness_ended(state, harness_reason(state, {:start_failed, :unstarted}))

      {:error, _unread} ->
        unkept(state)
    end
  end

  # An open that asked for its start goes round, so the step that decides
  # every call decides it (`page_round/1`).
  defp opened_round(_state, {:ok, %State{harness: nil} = state}), do: {:continue, state}
  defp opened_round(_state, {:ok, %State{} = state}), do: harness_round(state)
  defp opened_round(_state, {:end, %State{} = state, finish}), do: harness_end(state, finish)
  defp opened_round(%State{} = state, {:error, reason}), do: {:halt, {:failed, reason}, state}

  defp harness_reason(%State{} = state, kind), do: {:harness, title(state), kind}

  defp harness_ended(%State{} = state, reason),
    do: harness_failed(state, Prima.Refusal.message(reason))

  # A moved fence wins: the sentence's own write presents the loop's, and
  # one refused so leaves the turn to whoever took it, this loop cancelled.
  # Nothing of a turn the engine ends is left proposed or dispatched: what
  # its harness left open is settled first with its true outcome, as an
  # abort settles it (`settle_aborted/3`). The sentence is written before
  # the turn's end, and one not kept, or a settling not kept, is an end that
  # could not be written: its end is then not written either.
  defp harness_failed(%State{} = state, sentence) do
    with :ok <- settle_aborted(ctx(state), state.turn, sentence),
         {:ok, _row} <- system_row(state, sentence) do
      {:halt, {:failed, sentence}, state}
    else
      {:error, reason} when reason in @taken -> {:halt, :cancelled, state}
      {:error, _unkept} -> {:halt, {:unwritten, {:failed, sentence}}, state}
    end
  end

  # The store did not keep a write of the turn's, or did not answer a read
  # of it, the fence unmoved: the loop writes nothing more, neither a line
  # nor an end, and returns unwritten (`conclude/2`), which the runner
  # settles as a loop that died, whose recovery takes up what is open.
  defp unkept(%State{} = state),
    do: {:halt, {:failed, :write_failed}, %{state | unkept: :unkept}}

  # How the harness's work ended (`t:Aqua.Harness.finish/0`), whenever it
  # ends, at its open too. A start not yet taken closes with the end: as
  # started for work done, with the end's sentence for any other. A
  # harness the store did not answer ends unwritten, as the loop does.
  defp harness_end(%State{} = state, {:lost, {:harness, _member, :write_failed}}),
    do: unkept(state)

  defp harness_end(%State{} = state, :done) do
    case admission(state) do
      {:ok, %{dispatch_state: "dispatched"} = start} ->
        case close(state, start, nil, {:ok, "#{title(state)} started"}) do
          {:ok, _} -> {:halt, :completed, state}
          {:error, taken} when taken in @taken -> {:halt, :cancelled, state}
          _unkept -> {:halt, {:unwritten, :completed}, state}
        end

      {:ok, _taken_or_none} ->
        {:halt, :completed, state}

      {:error, _unread} ->
        {:halt, {:unwritten, :completed}, state}
    end
  end

  defp harness_end(%State{} = state, {_refused_or_lost, reason}) do
    sentence = Prima.Refusal.message(reason)

    case admission(state) do
      {:ok, %{dispatch_state: "dispatched"} = start} ->
        case Tape.close_step(guest(state), state.turn, start, "error", %{error: sentence}) do
          {:ok, _} -> harness_failed(state, sentence)
          {:error, taken} when taken in @taken -> {:halt, :cancelled, state}
          _unkept -> {:halt, {:unwritten, {:failed, sentence}}, state}
        end

      {:ok, _taken_or_none} ->
        harness_failed(state, sentence)

      {:error, _unread} ->
        {:halt, {:unwritten, {:failed, sentence}}, state}
    end
  end

  # The harness opened with its admitted start (`c:Aqua.Harness.open/1`):
  # its handle goes in this loop's registration, where a Stop finds it, and
  # is watched from here to the loop's return, through the calls between.
  # One that ends, whenever it does, ends the turn's wait and is never
  # replaced, as the harness's job is over with it.
  defp opened(%State{} = state, start) do
    module = Aqua.Harness.of(state.spec)
    take_open(state, module, module.open(work(state, start)))
  end

  @doc false
  # A harness's answer to its open (`c:Aqua.Harness.open/1`), every one
  # 2.3 names: its handle, published in this loop's registration before the
  # harness is said anything, so it holds nothing a Stop cannot find; its
  # own start, proposed for the loop to decide; or its end.
  @spec take_open(State.t(), module(), term()) ::
          {:ok, State.t()} | {:end, State.t(), Aqua.Harness.finish()} | {:error, term()}
  def take_open(%State{} = state, module, {:ok, handle, facts}) do
    {_, _} = Registry.update_value(@holders, {:turn, state.turn.id}, fn _ -> {module, handle} end)
    {:ok, %{state | harness: {module, handle}, watch: Process.monitor(handle), facts: facts}}
  end

  # The step that admits a harness's start is the engine's, by the key the
  # engine gives it (`Aqua.Tape.admission_key/1`), and a turn has one: a
  # harness that asks again leaves its start as the rows hold it.
  def take_open(%State{} = state, _module, {:admit, proposal}) do
    proposal = Map.put(proposal, :idempotency_key, Tape.admission_key(state.turn.id))

    case admission(state) do
      {:ok, nil} ->
        with {:ok, _step} <- Tape.propose_call(guest(state), state.turn, proposal),
             do: {:ok, state}

      {:ok, _admitted} ->
        {:ok, state}

      {:error, _unread} = unread ->
        unread
    end
  end

  def take_open(%State{} = state, _module, {:end, finish}), do: {:end, state, finish}

  # The one wait on the harness: what the thread's movement and the
  # harness say, until a page's or the harness's call is proposed, or its
  # work ends. What it tells of its own work is taken here and while a
  # call runs (`harness_event/2`).
  # The thread's movement goes round again, which says it to the harness
  # once (`harness_round/1`), and an event whose write was not kept ends
  # the wait (`loop/1`).
  defp harness_wait(%State{watch: watch} = state) do
    turn_id = state.turn.id

    receive do
      {:moved, ^turn_id} ->
        {:continue, state}

      {Aqua.Harness, ^turn_id, {:ask, _steps}} ->
        {:continue, state}

      {Aqua.Harness, ^turn_id, {:end, finish}} ->
        harness_end(state, finish)

      {Aqua.Harness, ^turn_id, event} ->
        case harness_event(state, event) do
          %State{unkept: nil} = state -> harness_wait(state)
          unkept -> {:continue, unkept}
        end

      # Stopped on purpose: Stop stops the harness before it stops the
      # turn, which says nothing more in the thread (`conclude/2`).
      {:DOWN, ^watch, :process, _pid, :normal} ->
        {:halt, :stopped, state}

      {:DOWN, ^watch, :process, _pid, _reason} ->
        harness_ended(state, harness_reason(state, :ended))
    end
  end

  # What the harness tells of its work, whichever wait takes it: its start
  # taken, its usage, its own tools and its text, which committed already.
  # A start's close that could not be written, or read, is never dropped:
  # the loop returns at its next step, an end that could not be written
  # (`conclude/2`).
  defp harness_event(%State{} = state, {:took, taken}) do
    Enum.reduce(taken, state, fn {id, how}, state ->
      case admission(state) do
        {:ok, %{id: ^id, dispatch_state: "dispatched"} = start} ->
          word = if how == :started, do: "started", else: "went on"

          case close(state, start, nil, {:ok, "#{title(state)} #{word}"}) do
            {:ok, _} -> state
            {:error, taken} when taken in @taken -> %{state | unkept: :taken}
            _unkept -> %{state | unkept: :unkept}
          end

        {:ok, _closed_or_none} ->
          state

        {:error, _unread} ->
          %{state | unkept: :unkept}
      end
    end)
  end

  defp harness_event(%State{} = state, {:usage, _usage}) do
    announce(state, :usage, Tape.usage(guest(state), state.turn.thread_id))
    state
  end

  defp harness_event(%State{} = state, {:activity, activity}), do: native(state, activity)
  defp harness_event(%State{} = state, _text_or_ask), do: state

  # The harness is told that the turn's rows moved, once for each time the
  # loop is woken or waits again: it reads what it is owed from the rows
  # itself (`c:Aqua.Harness.moved/1`).
  defp owe(%State{harness: {module, handle}} = state) do
    :ok = module.moved(handle)
    state
  end

  defp owe(%State{} = state), do: state

  # The step that admits the turn's harness, if one was proposed.
  defp admission(%State{} = state) do
    key = Tape.admission_key(state.turn.id)

    case Tape.steps(guest(state), state.turn) do
      {:ok, steps} -> {:ok, Enum.find(steps, &(&1.idempotency_key == key))}
      {:error, _} = unread -> unread
    end
  end

  # What the harness is handed of the turn (`t:Aqua.Harness.work/0`): its
  # contexts, the turn as built and as this loop holds it, whose fence is
  # the one it acquired, the admitted step, what the work runs with, the
  # turn's active time and the turn's rows as it reads them.
  defp work(%State{spec: spec} = state, admitted) do
    %{
      ctx: spec.ctx,
      guest: spec.guest,
      spec: spec,
      turn: state.turn,
      admitted: admitted,
      program: spec.program,
      agent: state.turn.agent,
      title: title(state),
      config: config(spec),
      system: spec.system,
      facts: spec.facts,
      tools: spec.tools,
      active_ms: fn -> Clock.read(state.clock) end,
      history: history(spec.guest, state.turn)
    }
  end

  # The turn's rows `keep?` keeps, and `handed`, rows to hand over beside
  # them, joined to the turn in one join before they are read
  # (`Aqua.Reader.join/5`), with their reading.
  defp history(guest, turn) do
    fn keep?, handed ->
      with {:ok, rows} <- Tape.projection(guest, turn),
           {:ok, joined} <- Reader.join(guest, turn, handed ++ Enum.filter(rows, keep?)),
           do: {:ok, %{rows: joined.rows, reading: joined.reading}}
    end
  end

  defp title(%State{spec: spec}),
    do: spec.agent["title"] || spec.agent["name"]

  # The whole configuration the harness runs with: the agent's model and
  # every option its file and the turn name, none dropped, so a narrowing
  # option reaches the turn's start, which refuses, before writing, one the
  # wire does not take. An absent member is the harness's default.
  defp config(spec) do
    spec.brain_options
    |> Map.put("model", spec.model)
    |> Enum.reject(fn {_member, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  @doc false
  # What a step records of a call as it was bound, a model's (`ask/4`) or a
  # page's (`Aqua.PageCalls.proposal/3`): one recording, so a page's call is
  # recorded as Aqua's call of its kind is.
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
        {:continue, state}
    end
  end

  # A launch the turn ends on decides nothing after it: what is left of
  # the response is skipped with the turn.
  defp decide(_state, _item, {_runnable, _state_acc, setup} = acc) when setup != nil, do: acc

  # An ask names a tool its harness was handed, by the whole name it asked
  # by, or it is refused before anything else reads it: before it resolves,
  # so an unhanded ask that would not resolve is refused as unhanded too.
  # The refusal names the tool as the person's list does, by the key an
  # outside name spells (`Binding.host_name/1`), any other as it was asked.
  defp decide(_state, %{step: step} = item, {runnable, state, setup} = acc) do
    name = Map.get(item, :asked)

    if unhanded?(state, step, name) do
      close(
        state,
        step,
        resolved(item),
        {:error, {:denied, "#{listed_as(name)} is not one of the tools this work has"}}
      )

      {runnable, state, setup}
    else
      decide_handed(state, item, acc)
    end
  end

  # A restricted turn runs replay-safe reads and nothing else — before the
  # policy can say otherwise.
  defp decide_handed(
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

  defp decide_handed(_state, item, acc), do: decide_open(item, acc)

  defp listed_as(name) do
    case Binding.host_name(name) do
      {:ok, key} -> key
      :error -> name
    end
  end

  defp resolved(%{call: {:ok, %Call{} = call}}), do: call
  defp resolved(_item), do: nil

  # A call refused as it resolved never ran: it closes denied, as the
  # policy closes a call it refuses, in the refusal's sentence, and a page
  # is answered the refusal's class (`Aqua.PageCalls.answer/3`).
  defp decide_open(%{step: step, call: {:error, reason}}, {runnable, state, setup}) do
    close(state, step, nil, {:error, {:denied, reason}})
    {runnable, state, setup}
  end

  defp decide_open(%{step: step, call: {:ok, %Call{} = call}} = item, {runnable, state, setup}) do
    decision =
      cond do
        refusal = flush_refusal(step, call) ->
          {:deny, refusal}

        true ->
          Policy.decide(call, state.spec.offered, place(state, step))
      end

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

      {refused, message} when refused in [:deny, :refuse] ->
        close(state, step, call, {:error, {:denied, message}})
        {runnable, state, setup}
    end
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

  defp run_group(%State{} = state, {:exclusive, %{step: step} = item}) do
    if admission?(state, step), do: admit(state, item), else: run_exclusive(state, item)
  end

  defp run_group(%State{} = state, {:concurrent, items}) do
    state = activity(state, items, :running)
    cap = max(state.spec.authority.budget.cap, 1)
    {outcome, state} = run_concurrent(state, items, min(length(items), cap))
    state = activity(state, items, :done)

    case outcome do
      {:uncertain, step, reason, rest} -> stop_uncertain(state, step, reason, rest)
      :ok -> {:ok, state}
    end
  end

  # The harness's own start, decided as any call is (`Aqua.Harness`):
  # dispatched here, in the loop's process, which holds the harness it
  # opens. Its step closes when the harness takes the work
  # (`harness_event/2`), or with the reason it could not open.
  defp admit(%State{} = state, %{step: step} = item) do
    state = activity(state, [item], :running)

    case Tape.mark_dispatched(guest(state), state.turn, step) do
      {:ok, step} ->
        case opened(state, step) do
          {:ok, state} ->
            {:ok, activity(state, [item], :done)}

          {:error, reason} ->
            {:halt, {:failed, reason}, state}

          {:end, state, :done} ->
            harness_end(state, :done)

          {:end, state, {_refused_or_lost, reason}} ->
            sentence = Prima.Refusal.message(reason)

            case close(state, step, unwrap(item.call), {:error, sentence}) do
              {:ok, _} -> {:ok, activity(state, [item], :done)}
              {:error, taken} when taken in @taken -> {:halt, :cancelled, state}
              _unkept -> {:halt, {:unwritten, {:failed, sentence}}, state}
            end
        end

      {:error, :not_proposed} ->
        {:ok, activity(state, [item], :done)}

      {:error, reason} ->
        {:halt, {:failed, reason}, state}
    end
  end

  defp run_exclusive(%State{} = state, item) do
    state = activity(state, [item], :running)
    {answer, state} = worker(state, fn -> run_one(state, item) end)

    outcome =
      case answer do
        {:ok, {:uncertain, step, reason}} -> {:uncertain, step, reason}
        {:ok, _} -> :ok
        {:exit, reason} -> settle_dead(state, item, reason)
      end

    state = activity(state, [item], :done)

    case outcome do
      # A note's unknown outcome is recorded on it, and neither stops nor
      # restricts the turn.
      {:uncertain, %{purpose: "flush"} = step, reason} ->
        _ =
          close(
            state,
            step,
            unwrap(item.call),
            {:unknown, "the note's outcome is unknown: #{reason}"}
          )

        {:ok, state}

      {:uncertain, step, reason} ->
        stop_uncertain(state, step, reason, [])

      _ ->
        {:ok, state}
    end
  end

  # The reads of a group run beside each other, at most `cap` at once,
  # each in a worker of its own, waited for as `worker/2` waits: every
  # answer and death is attributed to its step as it arrives. The first
  # unknown outcome stops
  # the group — nothing more is started, and what still runs is handed
  # back to be cancelled once the turn's stop is durable.
  defp run_concurrent(%State{} = state, items, cap) do
    collect(state, items, %{}, cap)
  end

  defp collect(state, [], running, _cap) when map_size(running) == 0, do: {:ok, state}

  defp collect(state, pending, running, cap) when map_size(running) < cap and pending != [] do
    [item | rest] = pending
    task = Aqua.Loop.Worker.async(fn -> run_one(state, item) end)
    collect(state, rest, Map.put(running, task.ref, %{item: item, task: task}), cap)
  end

  defp collect(state, pending, running, cap) do
    turn_id = state.turn.id

    receive do
      {ref, result} when is_map_key(running, ref) ->
        Process.demonitor(ref, [:flush])
        {%{item: item}, running} = Map.pop(running, ref)

        case result do
          {:uncertain, step, reason} ->
            {{:uncertain, step, reason, Map.values(running) ++ pending_items(pending)}, state}

          _ ->
            collect(state, pending, running, cap)
        end
        |> tap(fn _ -> item end)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        {%{item: item}, running} = Map.pop(running, ref)

        case settle_dead(state, item, reason) do
          {:uncertain, step, why} ->
            {{:uncertain, step, why, Map.values(running) ++ pending_items(pending)}, state}

          _ ->
            collect(state, pending, running, cap)
        end

      {:moved, ^turn_id} ->
        state |> owe() |> collect(pending, running, cap)

      {Aqua.Harness, ^turn_id, {kind, _} = event} when kind in @told ->
        state |> harness_event(event) |> collect(pending, running, cap)
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
  # dispatches, on the offered set as it stands now.
  defp still_offered(%State{spec: spec} = state, item, %Call{} = call) do
    case Policy.decide(call, Turn.current_offered(spec), place(state, item.step)) do
      :run -> :ok
      {:run, _decided} -> :ok
      {:setup_required, _app, _need} -> {:denied, "#{call.tool}.#{call.action} is not allowed"}
      {_refused, message} -> {:denied, message}
    end
  end

  # Where a call is made (`Aqua.Loop.Policy.decide/3`): the member's title
  # a refusal names and the member's context a launch's account is
  # resolved under. The host's `program.start` of a program brain is the
  # brain's own start, not a call of its job, so no offered set refuses it.
  defp place(%State{} = state, step) do
    if admission?(state, step),
      do: Keyword.put(place(state), :host_start, true),
      else: place(state)
  end

  defp place(%State{spec: spec}), do: [title: spec.agent["title"], ctx: spec.ctx]

  # The harness's own start (`Aqua.Harness`), a rule about the step: the
  # turn's admission, by its key.
  defp admission?(%State{turn: turn}, %{idempotency_key: key}),
    do: key == Tape.admission_key(turn.id)

  defp admission?(_state, _step), do: false

  # An ask is decided only if the whole name it asked by is one of the
  # tools the engine handed its harness at its open (`work.tools`),
  # whatever the harness was started with: checked each time it is decided,
  # first. A page's call is no ask, the admission is the harness's own
  # start, and a call whose row names nothing is answered as it resolves.
  defp unhanded?(%State{spec: spec} = state, %{purpose: purpose} = step, name)
       when purpose != "page" and is_binary(name) do
    not admission?(state, step) and not Enum.any?(spec.tools, &(&1["name"] == name))
  end

  defp unhanded?(_state, _step, _name), do: false

  # An ask of a note flush's step (`Aqua.Harness.Api`) runs `notes.keep`
  # alone, a note this large at most: a rule of the asking step's purpose.
  defp flush_refusal(
         %{purpose: "flush"},
         %Call{kind: :catalog, tool: tool, action: action} = call
       )
       when {tool, action} == @flush_call do
    content = call.args["content"]

    if is_binary(content) and byte_size(content) > @flush_note_max_bytes,
      do: "a note kept before a summary holds at most #{@flush_note_max_bytes} bytes"
  end

  defp flush_refusal(%{purpose: "flush"}, %Call{}),
    do: "only #{elem(@flush_call, 0)}.#{elem(@flush_call, 1)} runs while the thread is summarized"

  defp flush_refusal(_step, _call), do: nil

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
  # The turn's harness is stopped first: a call it runs is stopped and its
  # step closed before the pause is written (`c:Aqua.Harness.stop/1`).
  defp stop_uncertain(%State{} = state, step, reason, rest) do
    :ok = stop_harness(state.turn.id)

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

        {:ok,
         %{state | turn: paused, claim: nil, clock: Clock.paused(state.clock, paused.active_ms)}}

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
  # (`still_offered/3`): one no longer offered runs nothing.
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

    # The root is let go and the launch dispatched in one write, which the
    # rows refuse while a step whose run is a child of the root runs: the
    # launch stays proposed, and runs once the rows move
    # (`Arca.TurnStorage.pause/3`).
    case pause_root(state, :launch, step.id) do
      {:ok, state} ->
        step = %{step | dispatch_state: "dispatched"}
        {answer, state} = worker(state, fn -> Aqua.Launch.run(ctx(state), step, decided) end)

        case answer do
          {:ok, {:ok, %{execution_id: id, result: result}}} ->
            state |> close_launch(step, unwrap(call), {:ok, id, result}) |> resumed()

          {:ok, {:refused, reason}} ->
            state |> close_launch(step, unwrap(call), {:refused, reason}) |> resumed()

          # The application's run ended with its outcome unknown: the turn
          # stops here as it does on a launch whose start is not known.
          {:ok, {:error, reason}} ->
            case normalise({:error, reason}) do
              {:uncertain, why} ->
                launch_unknown(state, step, why)

              _failed ->
                state |> close_launch(step, unwrap(call), {:error, reason}) |> resumed()
            end

          # Whether the application started is not known: the turn stops
          # here, its root already let go.
          {:exit, reason} ->
            launch_unknown(state, step, reason)
        end

      {:error, reason} when reason in [:child_running, :not_proposed] ->
        {:ok, state}

      # The root did not let go: the launch never started.
      {:error, reason} ->
        with {:ok, step} <- Tape.mark_dispatched(guest, state.turn, step),
             do: close(state, step, unwrap(call), {:error, describe(reason)})

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

    closed =
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

    {closed, state}
  end

  defp close_launch(state, step, call, {:refused, reason}),
    do: failed_launch(state, step, call, reason, [])

  defp close_launch(state, step, call, {:error, reason}),
    do: failed_launch(state, step, call, reason, read_threads(state, step.child_execution_id))

  # A launch that did not run is closed in its sentence, its reason kept
  # for a page's answer. A page's call of a component that is not granted
  # asks the person for the grant, as a model's asks with request_setup.
  defp failed_launch(state, step, call, reason, threads) do
    closed = close(state, step, call, {:error, {:launch, reason}}, threads)

    with {:ok, _closed} <- closed,
         "page" <- step.purpose,
         %Call{target: ref} <- call,
         %Prima.Refusal{class: :consent_required} <- Sanctum.Refusals.classify(reason),
         do: announce(state, :consent_required, %{ref: ref, user_id: ctx(state).user_id})

    {closed, state}
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
        {:ok,
         %{state | turn: paused, claim: nil, clock: Clock.paused(state.clock, paused.active_ms)}}

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
  # launch. A launch's result the store did not keep takes nothing back:
  # the loop ends unwritten, the turn paused around the launch.
  defp resumed({{:ok, _closed}, %State{} = state}), do: resumed(state)

  defp resumed({{:error, taken}, %State{} = state}) when taken in @taken,
    do: {:halt, :cancelled, %{state | unkept: :taken}}

  defp resumed({{:error, _unkept}, %State{} = state}), do: unkept(state)

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
        {:ok,
         %{
           state
           | turn: resumed,
             claim: claim,
             clock: Clock.running(state.clock, resumed.active_ms)
         }}

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
  # its own, and the runner tells this process of it (`{:moved,
  # turn_id}`): the notice only wakes the loop, and the rows decide what
  # runs. Each is decided and dispatched as a model's call is, by the same
  # code. They run before each model round (`page_round/1`), and while the
  # model answers (`model_wait/5`). A turn with a page's call still
  # proposed does not complete: storage refuses it (`:call_pending`, which
  # covers a call proposed after the last look) and the loop goes round
  # again. A turn opened on a page's call asks no model (`open_call/1`).

  # A turn opened on a page's call records that call as its first step,
  # now that the turn runs, and opens no harness (`harness_round/1`). A
  # call whose request ended is recorded as no step, and the turn ends
  # with nothing run. Every other turn's harness opens at its first round.
  defp open_call(%State{turn: %{message_id: id}} = state) when is_binary(id) do
    case Tape.message(guest(state), id) do
      {:ok, %{kind: "page_call"} = row} ->
        proposal = Aqua.PageCalls.proposal(state.turn, Tape.payload(row), message_id: row.id)

        case Tape.propose_call(guest(state), state.turn, proposal) do
          {:ok, _step} -> {:ok, state}
          {:error, :call_ended} -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:ok, state}
    end
  end

  defp open_call(%State{} = state), do: {:ok, state}

  # A turn opened on a page's call asks no model, so its start pins no
  # brain grant (`Turn.brain_pin/5`).
  defp asks_model?(ctx, %{message_id: id}) when is_binary(id),
    do: not match?({:ok, %{kind: "page_call"}}, Tape.message(ctx, id))

  defp asks_model?(_ctx, _turn), do: true

  # The calls proposed in the turn are decided and run, and those proposed
  # while they ran after them, each once a round: a launch the rows
  # deferred waits for the next round (`launch_within/2`).
  defp page_round(%State{} = state, taken \\ []) do
    drain_notices(state.turn.id)

    case proposed_calls(state) do
      {:ok, items} ->
        case Enum.reject(items, &(&1.step.id in taken)) do
          [] ->
            {:continue, state}

          fresh ->
            case dispatch(state, fresh) do
              {:continue, %State{unkept: nil} = state} ->
                page_round(state, taken ++ Enum.map(fresh, & &1.step.id))

              continued_or_halt ->
                continued_or_halt
            end
        end

      # A harness waits on the answer to what it asked, so a failed read
      # of that is never read as nothing asked.
      {:error, _unread} ->
        unkept(state)
    end
  end

  defp drain_notices(turn_id) do
    receive do
      {:moved, ^turn_id} -> drain_notices(turn_id)
    after
      0 -> :ok
    end
  end

  # The calls still proposed in the turn, a page's and what its harness
  # asked, in the order the rows hold them.
  defp proposed_calls(%State{} = state) do
    with {:ok, steps} <- Tape.steps(guest(state), state.turn) do
      {:ok,
       for(
         %{kind: kind, dispatch_state: "proposed"} = step <- steps,
         kind not in ["model", "input"],
         do: item(state, step)
       )}
    end
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
      {open, unkept} =
        Enum.reduce(steps, {[], nil}, fn
          # A write of the settling that was not kept settles no more.
          _step, {_open, unkept} = acc when unkept != nil ->
            acc

          # A delivery to a program brain is reconciled by its attendant
          # with what the resumed transcript holds (`Aqua.Harness.Program`), before
          # any of this, and never read as an uncertain call.
          %{dispatch_state: "dispatched", kind: "input"}, acc ->
            acc

          %{dispatch_state: "dispatched"} = step, {open, nil} ->
            interrupted(state, step)

            case Prima.TurnStep.unresolved(step) do
              :unanswered ->
                guest
                |> Tape.close_step(state.turn, step, "error", %{error: "not reproducible"})
                |> settled(open)

              :replay ->
                guest
                |> Tape.next_generation(state.turn, step, Prima.UUID7.execution_id())
                |> settled(open)

              :unknown ->
                state
                |> close(
                  step,
                  unwrap(recall(state, step)),
                  {:unknown, "the turn was interrupted"}
                )
                |> settled(open)

              :uncertain ->
                {[step | open], nil}
            end

          %{dispatch_state: "proposed", purpose: "flush"} = step, {open, nil} ->
            state
            |> close(step, unwrap(recall(state, step)), {:skipped, "the turn was interrupted"})
            |> settled(open)

          _step, acc ->
            acc
        end)

      open = Enum.reverse(open)

      state = %{state | restricted?: open != [] or Tape.restricted?(guest, state.turn)}

      cond do
        # A write of the settling that was not kept is never dropped: the
        # loop returns, and its return says so (`conclude/2`).
        unkept != nil ->
          {:halt, {:failed, :write_failed}, %{state | unkept: unkept}}

        open != [] ->
          [first | others] = open
          rest = Enum.map(others, &%{item: item(state, &1), task: nil})
          stop_uncertain(state, first, "the turn was interrupted", rest)

        steered?(state) ->
          _ = Tape.skip_steps(guest, state.turn, "a newer message arrived")
          {:continue, state}

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

  # A settling write, kept or not (`settle/1`).
  defp settled({:ok, _written}, open), do: {open, nil}
  defp settled({:error, taken}, open) when taken in @taken, do: {open, :taken}
  defp settled({:error, _unkept}, open), do: {open, :unkept}

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
        item(state, step)
      end
    else
      _ -> []
    end
  end

  # A proposed step as the loop decides it: the step, the name its call
  # was asked by and what that name resolves to.
  defp item(%State{} = state, step) do
    {name, call} = asked(state, step)
    %{step: step, asked: name, call: call}
  end

  defp recall(%State{} = state, step), do: state |> asked(step) |> elem(1)

  # The call a proposed step was recorded for, from its tool_call row: the
  # name it was asked by, and the call that name resolves to.
  defp asked(%State{} = state, %{message_id: message_id}) when is_binary(message_id) do
    case Tape.message(guest(state), message_id) do
      {:ok, row} ->
        payload = Tape.payload(row)

        {payload["name"],
         Binding.resolve(payload["name"] || "", payload["arguments"] || %{},
           tool_call_id: payload["tool_call_id"]
         )}

      _ ->
        {nil, {:error, "the call's row is gone"}}
    end
  end

  defp asked(_state, _step), do: {nil, {:error, "the step names no call"}}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp replay_safe?(%Call{} = call), do: Policy.replay_safe?(call)

  # A post no step carried yet skips what a model turn had not run, since
  # the model answers the newer message instead; one a round took in before
  # it died is such a post, so the round is run again (`settle/1`). A
  # harness a newer post does not supersede (`Aqua.Harness`) is handed it
  # as it works, so none skips a step of it.
  defp steered?(%State{facts: %{supersedes?: false}}), do: false
  defp steered?(%State{} = state), do: Tape.steer_pending?(guest(state), state.turn)

  # Each entry names the call's tool and the sentence a person reads for
  # it, from the one table a kept step is worded by too (`Aqua.Steps`).
  defp activity(%State{} = state, items, status) do
    named =
      Enum.map(items, fn %{call: call} = item ->
        purpose = item[:step] && item.step.purpose

        case call do
          {:ok, call} ->
            {label(state, item, call), Aqua.Steps.sentence(call.tool, call.action, purpose)}

          _unbound ->
            {"tool", Aqua.Steps.sentence(nil, nil, purpose)}
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
          Enum.reduce(named, state.activity, &(&2 |> mark_done(&1, cyfr?(state)) |> elem(0)))
      end

    announce(state, :tool_activity, activity)
    %{state | activity: activity}
  end

  # An entry's label is its call's tool, but for a program brain's host
  # start, which ends once the program has taken the work: it is labelled
  # as that hand-over, so its end reads true while the program works.
  defp label(state, %{step: %{} = step}, call) do
    if admission?(state, step),
      do: "Work handed to #{title(state)}",
      else: call.model_name
  end

  defp label(_state, _item, call), do: call.model_name

  # What a program brain's attendant tells of the open work while the
  # turn waits on it or on a call (`Aqua.Harness.Program`): its own tools as they
  # start and end, and the native turn's end and the session's, after
  # either of which none of them runs.
  defp native(%State{} = state, {:own, name, phase}), do: own_activity(state, name, phase)
  defp native(%State{} = state, :idle), do: settle_own(state)
  defp native(%State{} = state, :session_ended), do: settle_own(state)

  # A program brain's own tool, by the name its attendant gives, running
  # from its start to its end: an entry of the same list, worded as a tool
  # no step names, since none is kept of it (`Aqua.Harness.Program`).
  defp own_activity(%State{} = state, name, phase) do
    sentence = Aqua.Steps.sentence(nil, nil, nil)

    {activity, own} =
      case phase do
        "start" ->
          {state.activity ++ [%{tool: name, sentence: sentence, status: :running, preview: nil}],
           state.own ++ [length(state.activity)]}

        "end" ->
          {activity, place} = mark_done(state.activity, {name, sentence}, &(&1 in state.own))
          {activity, List.delete(state.own, place)}
      end

    announce(state, :tool_activity, activity)
    %{state | activity: activity, own: own}
  end

  # The program brain's native turn or its session ended: none of its own
  # tools runs any more, and each still shown running is done.
  defp settle_own(%State{own: []} = state), do: state

  defp settle_own(%State{own: own} = state) do
    activity =
      Enum.reduce(own, state.activity, fn place, activity ->
        List.update_at(activity, place, &%{&1 | status: :done})
      end)

    announce(state, :tool_activity, activity)
    %{state | activity: activity, own: []}
  end

  # The places of the list that are CYFR's calls, not a program's own tools.
  defp cyfr?(%State{own: own}), do: &(&1 not in own)

  # The newest running entry for `tool` at a place `among?` takes is done;
  # none running adds a done one. Answers the list and the place marked.
  defp mark_done(activity, {tool, sentence}, among?) do
    place =
      activity
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {entry, i} ->
        entry.tool == tool and entry.status == :running and among?.(i) and i
      end)

    case place do
      nil ->
        {activity ++ [%{tool: tool, sentence: sentence, status: :done, preview: nil}],
         length(activity)}

      i ->
        {List.update_at(activity, i, &%{&1 | status: :done}), i}
    end
  end

  defp system_row(%State{} = state, text),
    do: Tape.append_line(guest(state), state.turn, text)

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
  # holder's death stops its workers (`Aqua.Loop.Worker`). What the turn's
  # harness tells of its work meanwhile (`harness_event/2`) is taken while
  # the call runs, and the state answered goes on with it.
  defp worker(%State{} = state, fun), do: awaiting(state, Aqua.Loop.Worker.async(fun))

  defp awaiting(%State{} = state, %Aqua.Loop.Worker.Handle{ref: ref} = task) do
    turn_id = state.turn.id

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {{:ok, result}, state}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {{:exit, reason}, state}

      {:moved, ^turn_id} ->
        state |> owe() |> awaiting(task)

      {Aqua.Harness, ^turn_id, {kind, _} = event} when kind in @told ->
        state |> harness_event(event) |> awaiting(task)
    end
  end

  @doc false
  # What a reason reads as in the turn's error and its line, for the loop
  # and its harnesses.
  @spec describe(term()) :: String.t()
  def describe({:model_refused, _catalyst, %{"message" => message}}) when is_binary(message),
    do: "The model could not be described: #{message}"

  def describe({:setup_required, {app, _need, account}}),
    do: "setup_required: the account #{inspect(account)} is not granted to #{app}"

  def describe({:unknown_model, model}), do: "#{model} is not a model its catalyst knows"

  def describe(:tool_policy_retired), do: Prima.AgentRef.tool_policy_retired()

  def describe(:seat_has_brain), do: Prima.AgentRef.seat_has_brain()

  def describe({:aqua_runs_on, _state, _member} = reason), do: Prima.Refusal.message(reason)

  def describe({:crew_unready, _member, _state} = reason), do: Prima.Refusal.message(reason)

  def describe({:tools_invalid_entry, entry}),
    do: Prima.AgentRef.tools_entry_invalid(entry)

  def describe(:no_model), do: "The agent names no model"

  # A schedule's turn whose fire another turn already took up: on another
  # server after a takeover, or by the turn that started it first.
  def describe(:occurrence_not_claimed),
    do: "This scheduled run was already taken up by another turn, so this one did not start."

  def describe(:read_threads_unrecorded),
    do: "What the model read could not be recorded on the turn, so its answer was not used"

  def describe(reason) when is_binary(reason), do: reason

  # A refusal for ownership (this server has not won its slot, or has lost
  # it), a component index still catching up with its files, or a pinned
  # grant that moved, reads as its declared sentence, which says to retry:
  # the turn did not run on, and the message can be sent again.
  def describe(reason)
      when reason in [
             :not_owner,
             :control_plane_lost,
             :slot_not_held,
             :projection_unavailable,
             :consent_moved
           ],
      do: Prima.Refusal.message(reason)

  def describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  def describe(reason), do: Aqua.Ops.render_refusal(reason)

  # This member still holds its slot in the cell. Asked again at each point
  # of the abort that would write, never once for the whole of it: a
  # member that lost its slot between two writes must not take the second,
  # and the rows are the holder's to settle.
  defp held do
    if Arca.ControlPlane.held?(), do: :ok, else: {:error, :control_plane_lost}
  end

  defp guest(%State{spec: %Turn{guest: guest}}), do: guest
  defp ctx(%State{spec: %Turn{ctx: ctx}}), do: ctx
end
