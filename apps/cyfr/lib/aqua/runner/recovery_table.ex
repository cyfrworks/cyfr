# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.RecoveryTable do
  @moduledoc """
  What a runner does with each open turn it finds when it starts, from
  the rows alone: an accepted turn waits its turn again; a turn paused on
  a card waits for the decision while any card is pending and continues
  once none is; a turn paused on a call whose outcome is unknown waits
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

  # A launch is never replayed (`Arca.Schemas.TurnStep.unresolved/1`):
  # whether the application started is not known from here, and the turn
  # stops on it. The continuation settles any other open step.
  defp settle_launch(ctx, turn, step) do
    with :uncertain <- Arca.Schemas.TurnStep.unresolved(step),
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
