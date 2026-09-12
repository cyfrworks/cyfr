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
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @type action ::
          {:queue, Tape.turn()}
          | {:wait, Tape.turn()}
          | {:continue, Tape.turn()}
          | {:adopt, Tape.turn()}
          | {:uncertain, Tape.turn(), String.t()}

  @doc """
  The action for every open root turn of the conversation, oldest first.
  A store that cannot answer refuses: no plan is not an empty plan.
  """
  @spec plan(Context.t(), String.t()) :: {:ok, [action()]} | {:error, term()}
  def plan(%Context{} = ctx, conversation_id) do
    with {:ok, turns} <- Tape.open_turns(ctx, conversation_id) do
      {:ok, turns |> Enum.reject(& &1.parent_turn_id) |> Enum.map(&classify(ctx, &1))}
    end
  end

  defp classify(_ctx, %{status: "accepted"} = turn), do: {:queue, turn}

  defp classify(ctx, %{status: "paused", paused_reason: "uncertain"} = turn),
    do: if(Tape.steer_pending?(ctx, turn), do: {:continue, turn}, else: {:wait, turn})

  defp classify(ctx, %{status: "paused", paused_reason: "launch"} = turn) do
    case turn.launch_step_id && Tape.step(ctx, turn.launch_step_id) do
      {:ok, %{dispatch_state: "dispatched"} = step} ->
        # A launch is never replayed: whether the application started is
        # not known from here, and the turn stops on it.
        case Tape.pause_uncertain(ctx, turn, %{
               step_id: step.id,
               generation: step.generation,
               reason: "the server stopped while the application was launched"
             }) do
          {:ok, %{turn: paused}} ->
            classify(ctx, paused)

          {:error, reason} ->
            {:uncertain, turn, "the launch could not be settled: #{inspect(reason)}"}
        end

      _ ->
        {:continue, turn}
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

  # Set down, never taken over: a takeover would open a running successor
  # and count a recovery for a turn a person has to continue.
  defp set_down(ctx, turn) do
    case Tape.pause_recovered(
           ctx,
           turn,
           "the server restarted while a call's outcome was unknown"
         ) do
      {:ok, paused} -> {:wait, paused}
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

      {:error, reason} ->
        {:uncertain, turn, "the turn could not be taken over: #{inspect(reason)}"}
    end
  end
end
