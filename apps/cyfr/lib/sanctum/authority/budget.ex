# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Authority.Budget do
  @moduledoc """
  The root-keyed invoke budget: how many spawns a root's tree may have in
  flight at once.

  An Authority names its budget by *identity* — `%Budget{id, cap}` — and
  the counter itself lives in a node-local table keyed by that id. The
  struct is plain data (it crosses the wire; a copy is the same budget),
  the count is shared by every Authority in the tree that carries the id,
  and a slot released back to zero deletes its row, so the table holds
  only budgets with work in flight.
  """

  import Bitwise, only: [<<<: 2]

  @table __MODULE__

  @type t :: %__MODULE__{id: String.t(), cap: non_neg_integer()}
  @enforce_keys [:id, :cap]
  defstruct [:id, :cap]

  @doc """
  Create the counter table. Called once by `Cyfr.Application` from a
  process that lives as long as the application — an ETS table dies with
  its owner, and a budget table that vanished would count from zero again,
  which is looser, never stricter. Public, so any process may charge.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @doc "A fresh budget of `cap` slots, nothing in flight."
  @spec new(non_neg_integer()) :: t()
  def new(cap) when is_integer(cap) and cap >= 0 do
    %__MODULE__{id: unique_id(), cap: cap}
  end

  @doc "Take one slot; `{:error, :invoke_budget_exhausted}` when none is free."
  @spec try_acquire(t()) :: :ok | {:error, :invoke_budget_exhausted}
  def try_acquire(%__MODULE__{id: id, cap: cap}) do
    in_flight = :ets.update_counter(@table, id, {2, 1}, {id, 0})

    if in_flight > cap do
      release_one(id)
      {:error, :invoke_budget_exhausted}
    else
      :ok
    end
  end

  @doc "Give a slot back."
  @spec release(t()) :: :ok
  def release(%__MODULE__{id: id}), do: release_one(id)

  @doc "What is in flight against the cap."
  @spec snapshot(t()) :: %{in_flight: non_neg_integer(), cap: non_neg_integer()}
  def snapshot(%__MODULE__{id: id, cap: cap}) do
    in_flight =
      case :ets.lookup(@table, id) do
        [{^id, n}] -> max(n, 0)
        [] -> 0
      end

    %{in_flight: in_flight, cap: cap}
  end

  # A count back at zero drops its row; `delete_object` only removes the
  # exact `{id, 0}`, so a concurrent acquire that already moved it on is
  # untouched.
  defp release_one(id) do
    case :ets.update_counter(@table, id, {2, -1, 0, 0}, {id, 0}) do
      0 -> :ets.delete_object(@table, {id, 0})
      _ -> :ok
    end

    :ok
  end

  defp unique_id do
    "bgt_" <>
      Base.url_encode64(
        <<System.unique_integer([:positive, :monotonic])::64, :rand.uniform(1 <<< 32)::32>>,
        padding: false
      )
  end
end
