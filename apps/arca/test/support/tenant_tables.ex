# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.TenantTables do
  @moduledoc """
  A test's erasure of one athanor's rows, over the closed roster
  `Arca.TenantTables` keeps and the boot checks against the live schema
  (`Arca.TenantTables.verify_roster!/1`), so it reaches every
  athanor-scoped table. Nothing in the product deletes an athanor; a test
  uses it to clean up the rows it made.
  """

  import Ecto.Query

  @doc """
  Delete every row this athanor owns, in one transaction: the tables
  reached through a parent first (`Arca.TenantTables.by_parent/0`), then
  the roster, children first. Answers `{:ok, %{table => count}}`. Rows
  with no athanor (`memberships`, `sessions` and `decision_logs` may hold
  them) stay, and blobs are another store's.
  """
  @spec delete_all_for(Prima.Actor.t()) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, term()}
  def delete_all_for(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.transaction(fn ->
      parent_counts =
        Map.new(Arca.TenantTables.by_parent(), fn {table, fk, parent} ->
          parent_ids = from(p in parent, where: p.athanor_id == ^athanor_id, select: p.id)

          {count, _} =
            from(t in table, where: field(t, ^fk) in subquery(parent_ids))
            |> Arca.Repo.delete_all()

          {table, count}
        end)

      Enum.reduce(Arca.TenantTables.roster(), parent_counts, fn table, acc ->
        {count, _} =
          from(t in table, where: t.athanor_id == ^athanor_id)
          |> Arca.Repo.delete_all()

        Map.put(acc, table, count)
      end)
    end)
  end

  def delete_all_for(%Prima.Actor{}), do: {:error, :no_athanor}
end
