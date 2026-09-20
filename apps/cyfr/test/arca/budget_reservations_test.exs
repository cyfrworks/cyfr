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
    Sanctum.TestContext.athanor!()
    ctx = Sanctum.TestContext.local()
    budget_id = "bgt_#{System.unique_integer([:positive])}"

    {:ok, %{execution: root, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_root_#{System.unique_integer([:positive])}",
          reference: "formula:local.demo:1.0.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: budget_id, cap: 3}
      )

    {:ok, ctx: ctx, root: root, attempt: attempt, budget: budget_id}
  end

  defp charge(ctx, budget, attempt, id, opts \\ []) do
    BudgetReservations.charge(
      Sanctum.Context.actor(ctx),
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

  defp charged(ctx, budget),
    do: BudgetReservations.lookup(Sanctum.Context.actor(ctx), budget).charged

  defp child!(ctx, root, id) do
    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(%{
        id: id,
        reference: "catalyst:local.files:0.1.0",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        component_type: "catalyst",
        parent_execution_id: root.id,
        root_execution_id: root.id
      })

    attempt
  end

  test "a charge counts once, the cap refuses the fourth, and release is idempotent", %{
    ctx: ctx,
    budget: budget,
    attempt: attempt
  } do
    a = attempt.attempt
    assert :ok = charge(ctx, budget, a, "c1")
    assert :ok = charge(ctx, budget, a, "c1")
    assert charged(ctx, budget) == 1

    assert :ok = charge(ctx, budget, a, "c2")
    assert :ok = charge(ctx, budget, a, "c3")
    assert :exhausted = charge(ctx, budget, a, "c4")
    assert charged(ctx, budget) == 3
    assert {:ok, rows} = BudgetReservations.charges(Sanctum.Context.actor(ctx), budget)
    assert Enum.map(rows, & &1.id) == ["c1", "c2", "c3"]

    assert :ok = BudgetReservations.release(Sanctum.Context.actor(ctx), budget, "c2")
    assert :ok = BudgetReservations.release(Sanctum.Context.actor(ctx), budget, "c2")
    assert charged(ctx, budget) == 2
    assert :ok = charge(ctx, budget, a, "c4")
  end

  test "one slot left, eight concurrent charges: exactly one lands", %{
    ctx: ctx,
    budget: budget,
    attempt: attempt
  } do
    a = attempt.attempt
    :ok = charge(ctx, budget, a, "c1")
    :ok = charge(ctx, budget, a, "c2")

    results =
      1..8
      |> Task.async_stream(fn i -> charge(ctx, budget, a, "race_#{i}") end, max_concurrency: 8)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == :exhausted)) == 7
    assert charged(ctx, budget) == 3
  end

  test "a stale authorizing attempt and a released reservation cannot charge", %{
    ctx: ctx,
    root: root,
    budget: budget,
    attempt: attempt
  } do
    {:ok, _} =
      ExecutionAttempts.close(Sanctum.Context.actor(ctx), attempt.attempt, "completed", "ok")

    assert :stale_attempt = charge(ctx, budget, attempt.attempt, "c1")

    {:ok, %{attempt: successor}} =
      ExecutionAttempts.takeover(Sanctum.Context.actor(ctx), root.id,
        boot_id: "b2",
        lease_until: ExecutionAttempts.lease_until()
      )

    assert :ok = charge(ctx, budget, successor.attempt, "c1")

    {:ok, 1} =
      Arca.Repo.transaction(fn ->
        BudgetReservations.close!(Sanctum.Context.actor(ctx), root.id)
      end)

    assert :released = charge(ctx, budget, successor.attempt, "c2")
  end

  test "reclamation follows the holder's fate, keeps a paused parent's children, and drops dead holds",
       %{ctx: ctx, root: root, budget: budget, attempt: attempt} do
    a = attempt.attempt
    child_attempt = child!(ctx, root, "exec_child_a")

    # An admitted charge whose holder still runs survives the sweep even
    # while the authorizing parent is paused.
    :ok = charge(ctx, budget, a, "held", holder: "exec_child_a")

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.BudgetCharge, where: c.id == "held"),
        set: [admitted_at: DateTime.utc_now()]
      )

    {:ok, _} =
      Arca.Repo.transaction(fn -> ExecutionAttempts.pause!(Sanctum.Context.actor(ctx), a) end)

    assert {:ok, 0} = BudgetReservations.sweep(Sanctum.Context.actor(ctx))
    assert charged(ctx, budget) == 1

    # The holder ends: its failed release is repaired by the sweep.
    {:ok, _} =
      ExecutionAttempts.close(
        Sanctum.Context.actor(ctx),
        child_attempt.attempt,
        "completed",
        "ok"
      )

    assert {:ok, 1} = BudgetReservations.sweep(Sanctum.Context.actor(ctx))
    assert charged(ctx, budget) == 0

    # A hold that never reached admission is dropped once its window
    # passed, and only then.
    :ok = charge(ctx, budget, a, "never", holder: "exec_never")
    assert {:ok, 0} = BudgetReservations.sweep(Sanctum.Context.actor(ctx))

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.BudgetCharge, where: c.id == "never"),
        set: [admit_by: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    assert {:ok, 1} = BudgetReservations.sweep(Sanctum.Context.actor(ctx))

    # A charge with no holder goes with its deadline, or with its
    # authorizing attempt.
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    future = DateTime.add(DateTime.utc_now(), 300, :second)
    :ok = charge(ctx, budget, a, "call_late", holder_deadline: past)
    :ok = charge(ctx, budget, a, "call_live", holder_deadline: future)
    assert {:ok, 1} = BudgetReservations.sweep(Sanctum.Context.actor(ctx))

    assert {:ok, [%{id: "call_live"}]} =
             BudgetReservations.charges(Sanctum.Context.actor(ctx), budget)

    {:ok, _} = ExecutionAttempts.close(Sanctum.Context.actor(ctx), a, "completed", "ok")
    assert {:ok, 1} = BudgetReservations.sweep(Sanctum.Context.actor(ctx))
    assert charged(ctx, budget) == 0
  end

  test "a new generation is a new charge, and the old generation's release cannot touch it", %{
    ctx: ctx,
    budget: budget,
    attempt: attempt
  } do
    a = attempt.attempt
    :ok = charge(ctx, budget, a, "call:t:1:c1:g0", holder: "exec_g0")
    :ok = charge(ctx, budget, a, "call:t:1:c1:g1", generation: 1, holder: "exec_g1")
    assert charged(ctx, budget) == 2

    assert :ok = BudgetReservations.release(Sanctum.Context.actor(ctx), budget, "call:t:1:c1:g0")

    assert {:ok, [%{id: "call:t:1:c1:g1"}]} =
             BudgetReservations.charges(Sanctum.Context.actor(ctx), budget)

    assert charged(ctx, budget) == 1
  end
end
