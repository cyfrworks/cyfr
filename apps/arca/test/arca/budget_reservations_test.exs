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

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
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
          component_type: "formula",
          origin: :programmatic
        },
        reservation: %{budget_id: budget_id, cap: 3},
        grant: Arca.Test.Actor.grant(actor.athanor_id),
        verify: &Arca.Test.Actor.admits/1
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
      Arca.Execution.admit(
        %{
          id: id,
          reference: "catalyst:local.files:0.1.0",
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          component_type: "catalyst",
          parent_execution_id: root.id,
          root_execution_id: root.id
        },
        Arca.Test.Actor.standing(actor.athanor_id)
      )

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
      ExecutionAttempts.close(actor, attempt.attempt, "completed", "ok", Arca.Test.Actor.stored())

    assert :stale_attempt = charge(actor, budget, attempt.attempt, "c1")

    {:ok, %{attempt: successor}} =
      ExecutionAttempts.takeover(actor, root.id,
        boot_id: "b2",
        lease_until: ExecutionAttempts.lease_until(),
        grant: :stored,
        verify: &Arca.Test.Actor.admits/1
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
        "ok",
        Arca.Test.Actor.stored()
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

    {:ok, _} = ExecutionAttempts.close(actor, a, "completed", "ok", Arca.Test.Actor.stored())
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

defmodule Arca.BudgetReservationsRaceTest do
  @moduledoc """
  The sweep against a charge and against a give-back of the same
  reservation, on PostgreSQL: each runs outside the sandbox on a
  connection of its own, the other's writes held open until the sweep is
  seen waiting on them.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.BudgetReservations
  alias Arca.Schemas.{BudgetCharge, BudgetReservation, Execution, ExecutionAttempt}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres
  @moduletag timeout: 60_000

  setup do
    actor = Arca.Test.Actor.local()
    budget = "bgt_race_#{System.unique_integer([:positive])}"
    id = "exec_race_#{System.unique_integer([:positive])}"
    on_exit(fn -> unboxed(fn -> delete_run!(id) end) end)

    {:ok, _admitted} =
      unboxed(fn ->
        Arca.Execution.admit(
          %{
            id: id,
            reference: "formula:local.demo:1.0.0",
            user_id: actor.user_id,
            athanor_id: actor.athanor_id,
            component_type: "formula",
            origin: :programmatic
          },
          reservation: %{budget_id: budget, cap: 3},
          grant: Arca.Test.Actor.grant(actor.athanor_id),
          verify: &Arca.Test.Actor.admits/1
        )
      end)

    {:ok, actor: actor, budget: budget}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  defp delete_run!(execution_id) do
    Arca.Repo.delete_all(from(a in ExecutionAttempt, where: a.execution_id == ^execution_id))

    Arca.Repo.delete_all(
      from(r in BudgetReservation, where: r.root_execution_id == ^execution_id)
    )

    Arca.Repo.delete_all(from(e in Execution, where: e.id == ^execution_id))
  end

  defp charge_row(actor, budget, id, fields \\ []) do
    struct!(
      %BudgetCharge{
        id: id,
        athanor_id: actor.athanor_id,
        reservation_id: budget,
        attempt: "att_race",
        n: 1,
        runner_id: "boot_race",
        inserted_at: DateTime.utc_now()
      },
      fields
    )
  end

  defp add_charged(budget, n),
    do:
      Arca.Repo.update_all(from(r in BudgetReservation, where: r.id == ^budget),
        inc: [charged: n]
      )

  defp charged(budget), do: unboxed(fn -> Arca.Repo.get!(BudgetReservation, budget).charged end)

  # `writes` in a transaction of its own, held open until released.
  defp holding(writes) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            writes.()
            send(test, :held)

            receive do
              :release -> :ok
            after
              30_000 -> Arca.Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive :held, 5_000
    task
  end

  defp release(task) do
    send(task.pid, :release)
    assert {:ok, :ok} = Task.await(task, 10_000)
  end

  defp sweeping(actor) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
          send(test, {:sweep, backend})
          BudgetReservations.sweep(actor)
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {:sweep, backend}, 5_000
    {task, backend}
  end

  test "a charge whose increment commits while the sweep recounts is counted", %{
    actor: actor,
    budget: budget
  } do
    charging =
      holding(fn ->
        Arca.Repo.insert!(charge_row(actor, budget, "racing"))
        add_charged(budget, 1)
      end)

    {sweep, backend} = sweeping(actor)
    Arca.Test.LockWait.await_lock_wait!(backend, ["budget_reservations"])
    release(charging)

    assert {:ok, 0} = Task.await(sweep, 10_000)
    assert charged(budget) == 1
  end

  test "a charge a give-back releases while the sweep reclaims it is released once", %{
    actor: actor,
    budget: budget
  } do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    unboxed(fn ->
      Arca.Repo.insert!(
        charge_row(actor, budget, "late", holder_execution_id: "exec_never", admit_by: past)
      )

      add_charged(budget, 1)
    end)

    giving_back =
      holding(fn ->
        Arca.Repo.delete_all(from(c in BudgetCharge, where: c.id == "late"))
        add_charged(budget, -1)
      end)

    {sweep, backend} = sweeping(actor)
    Arca.Test.LockWait.await_lock_wait!(backend, ["budget_charges"])
    release(giving_back)

    assert {:ok, 0} = Task.await(sweep, 10_000)
    assert charged(budget) == 0
  end
end
