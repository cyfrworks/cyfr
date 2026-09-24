# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.RecoveryTable do
  @moduledoc """
  What a runner does with each open turn it finds when it starts, from
  the rows alone: an accepted turn waits its turn again; a turn paused on
  a card waits for the decision while any card is pending and continues
  once none is; a turn set down by `turn.suspend` continues on the same
  terms, since what it was paused on is a person's decision and not an
  unknown outcome; a turn paused on a call whose outcome is unknown waits
  for its sender's next line, and continues once one is on the tape; a
  turn paused around a launch that never closed is stopped the same way,
  its launch step the unknown outcome; a running turn a dead runner left
  holding an unacknowledged unknown outcome is set down paused on it; any
  other running turn is taken over (its predecessor's attempt retired, a
  successor opened) and adopted, or ended uncertain past the recovery cap.

  A turn another process on this boot holds (`Aqua.Loop.holder/1`) is
  none of these: it is answered held, and nothing is written for it. Every
  take is made from the fence the turn was read with; a turn whose fence
  moved, or which left the state it was read in, belongs to whoever moved
  it and has no action.

  Every take here goes through the thread's claim, in the transaction
  that counts the recovery (`Aqua.Tape.bump_recovery/2`,
  `pause_recovered/3`, `recover/2`), so a member that did not take the
  claim cannot spend a recovery against a turn a live peer is running.
  `claimed/2` is the same table for a turn whose claim this member has
  already taken and whose recovery it has already counted — `turn.recover`
  — and takes nothing itself.
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @type action ::
          {:queue, Tape.turn()}
          | {:wait, Tape.turn()}
          | {:continue, Tape.turn()}
          | {:adopt, Tape.turn()}
          | {:held, Tape.turn(), pid()}
          | {:uncertain, Tape.turn(), String.t()}

  # A take refused for one of these found the turn moved since it was read.
  @moved [:superseded, :not_open, :not_running]

  @doc """
  The action for every open root turn of the thread, oldest first.
  A store that cannot answer refuses: no plan is not an empty plan.
  """
  @spec plan(Context.t(), String.t()) :: {:ok, [action()]} | {:error, term()}
  def plan(%Context{} = ctx, thread_id), do: plan_turns(ctx, thread_id, fn _turn -> true end)

  @doc """
  `plan/2` for the one root turn `turn_id` of the thread, read again: no
  action once it is over.
  """
  @spec plan_turn(Context.t(), String.t(), String.t()) :: {:ok, [action()]} | {:error, term()}
  def plan_turn(%Context{} = ctx, thread_id, turn_id),
    do: plan_turns(ctx, thread_id, &(&1.id == turn_id))

  defp plan_turns(ctx, thread_id, wanted?) do
    with {:ok, turns} <- Tape.open_turns(ctx, thread_id) do
      {:ok,
       turns
       |> Enum.filter(&(is_nil(&1.parent_turn_id) and wanted?.(&1)))
       |> Enum.flat_map(&List.wrap(action(ctx, &1)))}
    end
  end

  @doc """
  The action for a turn whose thread claim this member has already taken
  and whose recovery it has already counted, in the one transaction that
  did both (`Aqua.Tape.recover/2`) — the wire's `turn.recover`.

  Nothing is taken here: a running turn is already this member's, with
  its successor attempt open, so it is adopted rather than taken over
  again. A running turn holding an uncertainty nobody has acknowledged is
  still set down instead, because continuing past an unknown outcome is
  not something a recovery may decide.
  """
  @spec claimed(Context.t(), Tape.turn()) :: action() | nil
  def claimed(%Context{} = ctx, turn) do
    case Aqua.Loop.holder(turn.id) do
      nil -> classify_claimed(ctx, turn)
      holder -> {:held, turn, holder}
    end
  end

  defp classify_claimed(ctx, %{status: "running"} = turn) do
    if Tape.unacknowledged_episode?(ctx, turn),
      do: set_down(ctx, turn),
      else: {:adopt, turn}
  end

  defp classify_claimed(ctx, turn), do: classify(ctx, turn)

  @doc """
  Whether the authority the turn pinned still stands: the profile's head
  is still at the consent the turn ran under, and the agent still hashes
  to the capability identity the turn was checked against.

  A recovery asked for by hand is a fresh admission of old work, so both
  are read again rather than trusted from the row — a consent that has
  moved or an agent that has changed since is a different thing to run.
  """
  @spec pins_hold(Context.t(), Tape.turn()) :: :ok | {:error, {:superseded, String.t()}}
  def pins_hold(%Context{} = ctx, turn) do
    with :ok <- consent_holds(ctx, turn),
         :ok <- capability_holds(ctx, turn) do
      :ok
    else
      {:error, why} -> {:error, {:superseded, why}}
    end
  end

  # A turn that never pinned a profile pinned no consent either: there is
  # nothing to have moved.
  defp consent_holds(_ctx, %{profile_id: nil}), do: :ok

  defp consent_holds(ctx, turn) do
    case Cyfr.Execution.authority_for(ctx, {:id, turn.profile_id}, source_ref(turn)) do
      {:ok, %{consent_id: consent_id}} when consent_id == turn.consent_id ->
        :ok

      {:ok, _moved} ->
        {:error, "the consent the turn ran under has moved"}

      {:error, reason} ->
        {:error, "the turn's consent could not be loaded: #{Aqua.Ops.render_refusal(reason)}"}
    end
  end

  defp capability_holds(_ctx, %{agent_capability_digest: nil}), do: :ok

  defp capability_holds(ctx, %{agent: name, agent_capability_digest: pinned}) do
    with {:ok, agent} <- Compendium.AquaAgent.get(ctx, name),
         {:ok, ^pinned} <- Compendium.AquaAgent.capability_digest(agent) do
      :ok
    else
      {:ok, _other} -> {:error, "#{name} changed since the turn started"}
      {:error, _} -> {:error, "#{name} is no longer on the roster"}
    end
  end

  defp source_ref(%{agent: name}) do
    if Compendium.AgentSource.soul?(name),
      do: Compendium.AgentSource.soul_ref(),
      else: Compendium.AgentSource.ref(name)
  end

  defp action(ctx, turn) do
    case Aqua.Loop.holder(turn.id) do
      nil -> classify(ctx, turn)
      holder -> {:held, turn, holder}
    end
  end

  defp classify(_ctx, %{status: "accepted"} = turn), do: {:queue, turn}

  defp classify(ctx, %{status: "paused", paused_reason: "uncertain"} = turn),
    do: if(Tape.steer_pending?(ctx, turn), do: {:continue, turn}, else: {:wait, turn})

  defp classify(ctx, %{status: "paused", paused_reason: "launch"} = turn) do
    case turn.launch_step_id && Tape.step(ctx, turn.launch_step_id) do
      {:ok, %{dispatch_state: "dispatched"} = step} -> settle_launch(ctx, turn, step)
      _ -> {:continue, turn}
    end
  end

  defp classify(ctx, %{status: "paused"} = turn) do
    case Tape.pending_approvals(ctx, turn) do
      {:ok, [_ | _]} -> {:wait, turn}
      _ -> {:continue, turn}
    end
  end

  defp classify(ctx, %{status: "running"} = turn) do
    if Tape.unacknowledged_episode?(ctx, turn),
      do: set_down(ctx, turn),
      else: take_over(ctx, turn)
  end

  defp classify(_ctx, turn),
    do: {:uncertain, turn, "the turn is in no state a runner can continue"}

  # A launch is never replayed (`Prima.TurnStep.unresolved/1`):
  # whether the application started is not known from here, and the turn
  # stops on it. The continuation settles any other open step.
  defp settle_launch(ctx, turn, step) do
    with :uncertain <- Prima.TurnStep.unresolved(step),
         {:ok, %{turn: paused}} <-
           Tape.pause_uncertain(ctx, turn, %{
             step_id: step.id,
             generation: step.generation,
             reason: "the server stopped while the application was launched"
           }) do
      classify(ctx, paused)
    else
      {:error, reason} when reason in @moved ->
        nil

      {:error, reason} ->
        {:uncertain, turn, "the launch could not be settled: #{inspect(reason)}"}

      _settled_on_continue ->
        {:continue, turn}
    end
  end

  # Set down, never taken over: a takeover would open a running successor
  # and count a recovery for a turn a person has to continue.
  defp set_down(ctx, turn) do
    case Tape.pause_recovered(
           ctx,
           turn,
           "the server restarted while a call's outcome was unknown"
         ) do
      {:ok, paused} -> {:wait, paused}
      {:error, reason} when reason in @moved -> nil
      {:error, reason} -> {:uncertain, turn, "the turn could not be set down: #{inspect(reason)}"}
    end
  end

  defp take_over(ctx, turn) do
    case Tape.bump_recovery(ctx, turn) do
      {:ok, taken} ->
        _ =
          Tape.append_aborted(ctx, taken, "the server restarted while the assistant was working")

        {:adopt, taken}

      {:error, :recovery_exhausted} ->
        {:uncertain, turn, "the turn was interrupted too many times"}

      {:error, reason} when reason in @moved ->
        nil

      {:error, reason} ->
        {:uncertain, turn, "the turn could not be taken over: #{inspect(reason)}"}
    end
  end
end
