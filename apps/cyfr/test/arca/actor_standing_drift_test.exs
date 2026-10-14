# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ActorStandingDriftTest do
  @moduledoc """
  `Arca.Test.Actor.verify/1` spells `Sanctum.ExecutionStanding.verify/1`'s
  rule for Arca's own suite, which cannot call Sanctum. This suite reaches
  both, so it holds them together: for every standing a grant can meet —
  each clause of either function — both answer the same, and a change to
  either body that the other does not share fails here.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.Athanors

  @verifiers [Arca.Test.Actor, Sanctum.ExecutionStanding]

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    active = athanor!()
    archived = active_then(&archive!/1)
    reopened = active_then(&(&1 |> archive!() |> unarchive!()))

    assert %{status: "active", security_generation: 1} = standing(active)
    assert %{status: "archived", security_generation: 2} = standing(archived)
    assert %{status: "active", security_generation: 3} = standing(reopened)

    {:ok, active: active.id, archived: archived.id, reopened: reopened.id}
  end

  test "both answer the same for every standing a grant meets", ids do
    missing = "ath_drift_missing_#{System.unique_integer([:positive])}"

    rows = [
      {"active at the grant's generation", grant(ids.active, 1), :inside, {:ok, :ok}},
      {"active short of the grant's generation", grant(ids.active, 2), :inside,
       {:ok, {:error, :not_standing}}},
      {"reopened past the grant's generation", grant(ids.reopened, 1), :inside,
       {:ok, {:error, :not_standing}}},
      {"reopened, at its fresh generation", grant(ids.reopened, 3), :inside, {:ok, :ok}},
      {"archived at the grant's generation", grant(ids.archived, 2), :inside,
       {:ok, {:error, :not_standing}}},
      {"no such athanor", grant(missing, 1), :inside, {:ok, {:error, :not_standing}}},
      {"the store cannot answer", grant(ids.active, 1), :broken, {:ok, {:error, :unavailable}}},
      {"outside a transaction", grant(ids.active, 1), :outside, {:raised, ArgumentError}},
      {"not a grant", %{athanor_id: ids.active, generation: 1}, :inside,
       {:raised, FunctionClauseError}}
    ]

    for {label, grant, where, expected} <- rows do
      answers = Map.new(@verifiers, &{&1, answer(&1, grant, where)})

      assert Enum.uniq(Map.values(answers)) == [expected],
             "#{label}: expected #{inspect(expected)} from both, got #{inspect(answers)}"
    end

    # Every broken store was rolled back with its own transaction.
    assert %{status: "active", security_generation: 1} = standing(%{id: ids.active})
  end

  # What `verifier.verify/1` answers for `grant`: inside a locking
  # transaction of its own, as the execution writes ask it, rolled back so
  # nothing leaks into the next answer; with the store unable to answer, by
  # renaming the athanors table inside that transaction; or outside any
  # transaction. The transaction first answers a query, so a store that
  # cannot answer is this one's broken table, never a PostgreSQL
  # transaction an earlier answer left aborted.
  defp answer(verifier, grant, :outside), do: run(verifier, grant)

  defp answer(verifier, grant, where) do
    {:error, {:answered, answer}} =
      Arca.Repo.locking_transaction(fn ->
        %{rows: [[1]]} = Arca.Repo.query!("SELECT 1")

        if where == :broken,
          do: Arca.Repo.query!("ALTER TABLE athanors RENAME TO athanors_away")

        Arca.Repo.rollback({:answered, run(verifier, grant)})
      end)

    answer
  end

  defp run(verifier, grant) do
    {:ok, verifier.verify(grant)}
  rescue
    error -> {:raised, error.__struct__}
  end

  defp grant(athanor_id, generation) do
    {:ok, grant} = Prima.ExecutionGrant.new(athanor_id, generation)
    grant
  end

  defp standing(athanor) do
    {:ok, row} =
      Arca.ExecutionStanding.current(Prima.Actor.in_athanor(athanor.id), athanor.id)

    row
  end

  defp active_then(transition), do: transition.(athanor!())

  defp athanor! do
    {:ok, athanor} =
      Athanors.create(%{
        kind: "group",
        name: "Drift",
        slug: "drift-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    athanor
  end

  defp archive!(athanor) do
    {:ok, archived} = Athanors.archive(athanor, force: true)
    archived
  end

  defp unarchive!(athanor) do
    {:ok, reopened} = Athanors.unarchive(athanor)
    reopened
  end
end
