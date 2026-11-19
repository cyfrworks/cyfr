# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Approvals do
  @moduledoc """
  The approvals still on the tape: whether one was opened for exactly a
  proposal (`proposal?/2`), and every pending one past its expiry settled
  `expired`, its step closed denied with a tool result for the model and
  the turn told (`expire_due/1`).
  """

  require Logger

  alias Aqua.Tape
  alias Sanctum.Context

  @doc """
  Whether `approval` was opened for exactly `proposal`: its digest is the
  proposal's. An approval without a digest matches nothing.
  """
  @spec proposal?(
          %{required(:proposal_digest) => String.t() | nil, optional(atom()) => term()},
          term()
        ) ::
          boolean()
  def proposal?(%{proposal_digest: digest}, proposal)
      when is_binary(digest) and digest != "" and is_map(proposal),
      do: Aqua.Loop.Policy.proposal_digest(proposal) == digest

  def proposal?(_approval, _proposal), do: false

  @doc """
  Resolve every pending approval of the athanor past its expiry as
  `expired`. Answers how many were settled.
  """
  @spec expire_due(Context.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def expire_due(%Context{} = ctx) do
    with {:ok, approvals} <- Tape.expired_approvals(ctx) do
      settled =
        Enum.count(approvals, fn approval ->
          with {:ok, turn} <- Tape.turn(ctx, approval.turn_id),
               {:ok, card} <- Tape.message(ctx, approval.message_id) do
            intent = Arca.ThreadStorage.payload(card)["intent"] || %{}

            match?(
              {:ok, _},
              settle(ctx, turn, approval, "expired", %{
                resolution_kind: "expired",
                reason: "expired",
                denied_result: denied_result(intent, "the card expired before it was decided")
              })
            )
          else
            _ -> false
          end
        end)

      {:ok, settled}
    end
  end

  # ---------------------------------------------------------------------------
  # Settling
  # ---------------------------------------------------------------------------

  # The one transaction, then the telemetry.
  defp settle(ctx, turn, approval, decision, attrs) do
    attrs = Map.put_new(attrs, :decided_by, ctx.user_id)

    case Tape.resolve_approval(ctx, turn, approval.id, decision, attrs) do
      {:ok, %{approval: resolved, step: step}} ->
        telemetry(ctx, turn, resolved, step, attrs)
        {:ok, outcome(ctx, resolved, step, false)}

      {:error, {:already_resolved, resolved}} ->
        with {:ok, step} <- Tape.step(ctx, resolved.step_id),
             do: {:ok, outcome(ctx, resolved, step, true)}

      {:error, _} = error ->
        error
    end
  end

  defp outcome(ctx, approval, step, replayed?) do
    pending =
      case Tape.turn(ctx, approval.turn_id) do
        {:ok, turn} ->
          case Tape.pending_approvals(ctx, turn) do
            {:ok, rows} -> length(rows)
            _ -> 0
          end

        _ ->
          0
      end

    %{
      approval_id: approval.id,
      turn_id: approval.turn_id,
      step_id: step.id,
      thread_id: approval.thread_id,
      decision: approval.status,
      resolution_kind: approval.resolution_kind,
      replayed: replayed?,
      pending: pending
    }
  end

  # ---------------------------------------------------------------------------
  # Rows and telemetry
  # ---------------------------------------------------------------------------

  # What a refused step leaves for the model: its tool result, an error.
  defp denied_result(intent, why) do
    proposal = intent["proposal"] || %{}

    %{
      content: why,
      payload: %{
        "tool_call_id" => intent["tool_call_id"],
        "name" => proposal["tool"] && "#{proposal["tool"]}.#{proposal["action"]}",
        "is_error" => true
      }
    }
  end

  defp telemetry(ctx, turn, approval, _step, attrs) do
    :telemetry.execute([:cyfr, :aqua, :approval], %{count: 1}, %{
      id: approval.id,
      decision: approval.status,
      scope: Aqua.ApprovalScope.parse(approval.scope),
      resolution_kind: approval.resolution_kind,
      thread_id: turn.thread_id,
      turn_id: turn.id,
      user_id: ctx.user_id,
      athanor_id: Context.athanor!(ctx),
      agent: turn.agent,
      reason: attrs[:reason]
    })
  rescue
    # An approval decision's telemetry is compliance-relevant: dropping it
    # leaves a trace, and never fails the decision.
    e ->
      Logger.warning(
        "[Aqua.Approvals] approval telemetry dropped: " <> Prima.LogFilter.exception_message(e)
      )

      :ok
  end
end
