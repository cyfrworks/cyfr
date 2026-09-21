# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.BudgetReservationsTest do
  @moduledoc """
  A charge is one dispatch's hold: inserted first so a retry conflicts
  instead of charging twice, incremented under the cap atomically,
  released idempotently, and reclaimed by the holder's fate — never by
  the parent's alone, never by age when a deadline is what the store
  enforces.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.BudgetReservations
  alias Arca.ExecutionAttempts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()
    budget_id = "bgt_#{System.unique_integer([:positive])}"

    {:ok, %{execution: root, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_root_#{System.unique_integer([:positive])}",
          reference: "formula:local.demo:1.0.0",
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: budget_id, cap: 3}
      )

    {:ok, actor: actor, root: root, attempt: attempt, budget: budget_id}
  end

  defp charge(actor, budget, attempt, id, opts \\ []) do
    BudgetReservations.charge(
      actor,
      budget,
      %{
        id: id,
        attempt: attempt,
        generation: Keyword.get(opts, :generation, 0),
        holder_execution_id: Keyword.get(opts, :holder)
      },
      1,
      Keyword.take(opts, [:holder_deadline])
    )
  end

  defp charged(actor, budget),
    do: BudgetReservations.lookup(actor, budget).charged

  defp child!(actor, root, id) do
    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(%{
        id: id,
        reference: "catalyst:local.files:0.1.0",
        user_id: actor.user_id,
        athanor_id: actor.athanor_id,
        component_type: "catalyst",
        parent_execution_id: root.id,
        root_execution_id: root.id
      })

    attempt
  end

  test "a charge counts once, the cap refuses the fourth, and release is idempotent", %{
    actor: actor,
    budget: budget,
    attempt: attempt
  } do
    a = attempt.attempt
    assert :ok = charge(actor, budget, a, "c1")
    assert :ok = charge(actor, budget, a, "c1")
    assert charged(actor, budget) == 1

    assert :ok = charge(actor, budget, a, "c2")
    assert :ok = charge(actor, budget, a, "c3")
    assert :exhausted = charge(actor, budget, a, "c4")
    assert charged(actor, budget) == 3
    assert {:ok, rows} = BudgetReservations.charges(actor, budget)
    assert Enum.map(rows, & &1.id) == ["c1", "c2", "c3"]

    assert :ok = BudgetReservations.release(actor, budget, "c2")
    assert :ok = BudgetReservations.release(actor, budget, "c2")
    assert charged(actor, budget) == 2
    assert :ok = charge(actor, budget, a, "c4")
  end

  test "one slot left, eight concurrent charges: exactly one lands", %{
    actor: actor,
    budget: budget,
    attempt: attempt
  } do
    a = attempt.attempt
    :ok = charge(actor, budget, a, "c1")
    :ok = charge(actor, budget, a, "c2")

    results =
      1..8
      |> Task.async_stream(fn i -> charge(actor, budget, a, "race_#{i}") end, max_concurrency: 8)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == :exhausted)) == 7
    assert charged(actor, budget) == 3
  end

  test "a stale authorizing attempt and a released reservation cannot charge", %{
    actor: actor,
    root: root,
    budget: budget,
    attempt: attempt
  } do
    {:ok, _} =
      ExecutionAttempts.close(actor, attempt.attempt, "completed", "ok")

    assert :stale_attempt = charge(actor, budget, attempt.attempt, "c1")

    {:ok, %{attempt: successor}} =
      ExecutionAttempts.takeover(actor, root.id,
        boot_id: "b2",
        lease_until: ExecutionAttempts.lease_until()
      )

    assert :ok = charge(actor, budget, successor.attempt, "c1")

    {:ok, 1} =
      Arca.Repo.transaction(fn ->
        BudgetReservations.close!(actor, root.id)
      end)

    assert :released = charge(actor, budget, successor.attempt, "c2")
  end

  test "reclamation follows the holder's fate, keeps a paused parent's children, and drops dead holds",
       %{actor: actor, root: root, budget: budget, attempt: attempt} do
    a = attempt.attempt
    child_attempt = child!(actor, root, "exec_child_a")

    # An admitted charge whose holder still runs survives the sweep even
    # while the authorizing parent is paused.
    :ok = charge(actor, budget, a, "held", holder: "exec_child_a")

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.BudgetCharge, where: c.id == "held"),
        set: [admitted_at: DateTime.utc_now()]
      )

    {:ok, _} =
      Arca.Repo.transaction(fn -> ExecutionAttempts.pause!(actor, a) end)

    assert {:ok, 0} = BudgetReservations.sweep(actor)
    assert charged(actor, budget) == 1

    # The holder ends: its failed release is repaired by the sweep.
    {:ok, _} =
      ExecutionAttempts.close(
        actor,
        child_attempt.attempt,
        "completed",
        "ok"
      )

    assert {:ok, 1} = BudgetReservations.sweep(actor)
    assert charged(actor, budget) == 0

    # A hold that never reached admission is dropped once its window
    # passed, and only then.
    :ok = charge(actor, budget, a, "never", holder: "exec_never")
    assert {:ok, 0} = BudgetReservations.sweep(actor)

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.BudgetCharge, where: c.id == "never"),
        set: [admit_by: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    assert {:ok, 1} = BudgetReservations.sweep(actor)

    # A charge with no holder goes with its deadline, or with its
    # authorizing attempt.
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    future = DateTime.add(DateTime.utc_now(), 300, :second)
    :ok = charge(actor, budget, a, "call_late", holder_deadline: past)
    :ok = charge(actor, budget, a, "call_live", holder_deadline: future)
    assert {:ok, 1} = BudgetReservations.sweep(actor)

    assert {:ok, [%{id: "call_live"}]} =
             BudgetReservations.charges(actor, budget)

    {:ok, _} = ExecutionAttempts.close(actor, a, "completed", "ok")
    assert {:ok, 1} = BudgetReservations.sweep(actor)
    assert charged(actor, budget) == 0
  end

  test "a new generation is a new charge, and the old generation's release cannot touch it", %{
    actor: actor,
    budget: budget,
    attempt: attempt
  } do
    a = attempt.attempt
    :ok = charge(actor, budget, a, "call:t:1:c1:g0", holder: "exec_g0")
    :ok = charge(actor, budget, a, "call:t:1:c1:g1", generation: 1, holder: "exec_g1")
    assert charged(actor, budget) == 2

    assert :ok = BudgetReservations.release(actor, budget, "call:t:1:c1:g0")

    assert {:ok, [%{id: "call:t:1:c1:g1"}]} =
             BudgetReservations.charges(actor, budget)

    assert charged(actor, budget) == 1
  end
end
