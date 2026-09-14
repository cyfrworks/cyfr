# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Launch do
  @moduledoc """
  The one dispatcher of an approved launch. A `launch` step — an
  `execution.run` of something that is neither a hand nor an agent,
  approved by a member — becomes an external-plane `execution.run` as
  that member: the application roots its own consent, and the turn's
  pinned authority is never widened into it.

  The input is the durable step alone. The approver's context is rebuilt
  from the approval's `decided_by` (`Sanctum.Tenancy.continuation/2`), so
  a launch consumed after a restart runs as the person who decided it, or
  not at all: a person no longer seated refuses it. The loop marks the
  step dispatched before calling here, which is what makes a launch
  happen once.
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @launch_actions ~w(run run_stream)

  @doc """
  Run the launch the step was approved for, as its approver. Answers the
  execution the application started (`execution_id` is nil when the
  answer names none) with the tool's whole result, or the refusal.
  """
  @spec dispatch(Context.t(), Tape.step()) ::
          {:ok, %{execution_id: String.t() | nil, result: map()}} | {:error, term()}
  def dispatch(%Context{} = ctx, %{approval_id: approval_id}) when is_binary(approval_id) do
    with {:ok, approval} <- Tape.approval(ctx, approval_id),
         :ok <- approved_launch(approval),
         {:ok, card} <- Tape.message(ctx, approval.message_id),
         {:ok, args} <- launch_args(card),
         {:ok, approver} <- approver(ctx, approval) do
      case Aqua.Ops.call_tool("execution", approver, args) do
        {:ok, result} -> {:ok, %{execution_id: execution_id(result), result: result}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def dispatch(_ctx, _step), do: {:error, :not_approved}

  defp approved_launch(%{status: "approved", resolution_kind: "launch"}), do: :ok
  defp approved_launch(_approval), do: {:error, :not_approved}

  # The proposal the card carried, as the model wrote it and the person
  # saw it. The assistant itself is never launched, and a wrapped
  # catalyst is a hand, not a launch — both are decided again at this
  # last door, whatever the card said.
  defp launch_args(card) do
    case get_in(Arca.ThreadStorage.payload(card), ["intent", "proposal"]) do
      %{"tool" => "execution", "action" => action, "args" => args}
      when action in @launch_actions and is_map(args) ->
        reference = args["reference"]

        cond do
          not is_binary(reference) ->
            {:error, {:invalid_argument, "execution.#{action} needs a reference"}}

          Compendium.AgentSource.agent_ref?(reference) ->
            {:error, {:invalid_argument, "an agent is not a tool to run"}}

          Aqua.Hands.hand_catalyst?(reference) ->
            {:error, {:invalid_argument, "#{reference} is a hand, not a launch"}}

          true ->
            {:ok,
             args
             |> Map.put("action", action)
             |> Map.drop(["parent_execution_id", "root_execution_id", "thread_id"])}
        end

      _ ->
        {:error, {:invalid_argument, "the card carries no launch"}}
    end
  end

  defp approver(%Context{} = ctx, %{decided_by: user_id}) when is_binary(user_id) do
    case Sanctum.Tenancy.continuation(user_id, Context.athanor!(ctx)) do
      {:ok, approver} -> {:ok, approver}
      {:error, reason} -> {:error, {:approver_unavailable, reason}}
    end
  end

  defp approver(_ctx, _approval), do: {:error, {:approver_unavailable, :denied}}

  defp execution_id(%{execution_id: id}) when is_binary(id), do: id
  defp execution_id(%{"execution_id" => id}) when is_binary(id), do: id
  defp execution_id(_result), do: nil
end
