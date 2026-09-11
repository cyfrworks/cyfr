# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Chain.Charge do
  @moduledoc """
  The durable side of a spawn-shaped child's invoke charge: with a charge
  identity in the call's options (`%{id, attempt, generation,
  holder_execution_id}`, minted by the loop per dispatch), the hold the
  transition charged in the root's budget is a `budget_charges` row too,
  taken before the child runs and given back with the slot. Without an
  identity — a guest formula's own spawn — the slot alone is the hold.
  A row the reservation refuses gives the slot back and refuses the run.
  """

  alias Sanctum.Authority

  @doc "Take the charge row for `opts[:charge]`, or `:ok` when there is none."
  @spec take(Authority.t(), keyword()) :: :ok | {:error, term()}
  def take(%Authority{budget: budget}, opts) do
    with %{id: _} = charge <- Keyword.get(opts, :charge),
         athanor_id when is_binary(athanor_id) <- athanor_of(opts) do
      case Arca.BudgetReservations.charge(athanor_id, budget.id, charge, 1) do
        :ok ->
          :ok

        refusal ->
          Sanctum.Authority.Budget.release(budget)
          {:error, {:invoke_denied, refusal_reason(refusal)}}
      end
    else
      _ -> :ok
    end
  end

  @doc "Give the charge row back, idempotently; nothing without an identity."
  @spec give_back(Authority.t(), keyword()) :: :ok
  def give_back(%Authority{budget: budget}, opts) do
    with %{id: id} <- Keyword.get(opts, :charge),
         athanor_id when is_binary(athanor_id) <- athanor_of(opts) do
      Arca.BudgetReservations.release(athanor_id, budget.id, id)
      :ok
    else
      _ -> :ok
    end
  end

  defp athanor_of(opts) do
    case Keyword.get(opts, :ctx) do
      %Sanctum.Context{athanor_id: athanor_id} -> athanor_id
      _ -> nil
    end
  end

  defp refusal_reason(:exhausted), do: :invoke_budget_exhausted
  defp refusal_reason(:stale_attempt), do: :stale_attempt
  defp refusal_reason(:released), do: :reservation_released
  defp refusal_reason({:error, _}), do: :invoke_budget_exhausted
end
