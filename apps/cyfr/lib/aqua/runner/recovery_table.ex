# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.RecoveryTable do
  @moduledoc """
  What a runner does with each open turn it finds when it starts, from
  the rows alone: an accepted turn waits its turn again; a turn paused on
  a card waits for the decision while any card is pending and continues
  once none is; a turn paused around a launch continues, its launch step
  marked uncertain when it never closed; a running turn is taken over
  (its predecessor's attempt retired, a successor opened) and adopted,
  or ended uncertain past the recovery cap.
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

  defp classify(ctx, %{status: "paused", paused_reason: "launch"} = turn) do
    case turn.launch_step_id && Tape.step(ctx, turn.launch_step_id) do
      {:ok, %{dispatch_state: "dispatched"} = step} ->
        # A launch is never replayed: whether the application started is
        # not known from here.
        _ =
          Tape.mark_uncertain(ctx, step, "the server stopped while the application was launched")

        {:continue, turn}

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

  defp classify(_ctx, turn),
    do: {:uncertain, turn, "the turn is in no state a runner can continue"}
end
