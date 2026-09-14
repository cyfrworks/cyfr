# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Chain.Charge do
  @moduledoc """
  The durable side of a spawn-shaped child's invoke charge: the hold the
  transition charged in the root's budget is a `budget_charges` row too
  (`Arca.BudgetReservations`), taken before the child runs and given back
  with the slot, and the reservation row is the authority — a row it
  refuses gives the slot back and refuses the run.

  The charge identity (`%{id, attempt, generation, holder_execution_id}`)
  is the loop's per dispatch; a spawn without one but under a known
  attempt — a guest formula's own child — is given one by `identify/1`:
  a fresh charge id, the caller's attempt, and the child's execution id,
  minted here so admission's hold barrier can name it. A spawn under no
  attempt at all holds the slot alone.
  """

  alias Cyfr.Authority

  @doc """
  The call's options with a charge identity: the given one, or, for a
  spawn under a known attempt, one derived from `:attempt` (with
  `:execution_id` minted for the child when absent). A synchronous call,
  which takes no charge, and a spawn under no attempt are left unchanged.
  """
  @spec identify(keyword()) :: keyword()
  def identify(opts) do
    case {Keyword.get(opts, :charge), Keyword.get(opts, :attempt), Keyword.get(opts, :guest_fn)} do
      {%{id: _}, _, _} ->
        opts

      {nil, attempt, :spawn} when is_binary(attempt) ->
        execution_id = Keyword.get(opts, :execution_id) || Cyfr.Execution.Record.generate_id()

        opts
        |> Keyword.put(:execution_id, execution_id)
        |> Keyword.put(:charge, %{
          id: Cyfr.UUID7.generate_id("chg"),
          attempt: attempt,
          generation: 0,
          holder_execution_id: execution_id
        })

      _ ->
        opts
    end
  end

  @doc "Take the charge row for `opts[:charge]`, or `:ok` when there is none."
  @spec take(Authority.t(), keyword()) :: :ok | {:error, term()}
  def take(%Authority{budget: budget}, opts) do
    with %{id: _} = charge <- Keyword.get(opts, :charge),
         athanor_id when is_binary(athanor_id) <- athanor_of(opts) do
      case Arca.BudgetReservations.charge(athanor_id, budget.id, charge, 1) do
        :ok ->
          :ok

        refusal ->
          Sanctum.Authority.BudgetCounter.release(budget)
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
