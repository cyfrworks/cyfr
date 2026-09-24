# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionAttemptsTest do
  @moduledoc """
  An execution is owned by one attempt at a time: renewal, pause, resume
  and closing match the attempt and the pointer; the sweeper retires a
  lapsed attempt on the lease it observed; a takeover retires the
  predecessor, opens the successor and moves the pointer in one
  transaction; running time is accounted once per interval. A child is
  admitted under its parent's attempt only while that attempt owns its
  running parent, running with no cancel asked of it.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ExecutionAttempts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()
    {:ok, actor: actor}
  end

  defp admit!(actor, opts \\ []) do
    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_att_#{System.unique_integer([:positive])}",
          reference: "catalyst:local.files:0.1.0",
          user_id: actor.user_id,
          athanor_id: actor.athanor_id,
          component_type: "catalyst",
          input: "{}"
        },
        opts ++ Arca.Test.Actor.standing(actor.athanor_id)
      )

    {execution, attempt}
  end

  defp reload(id), do: Arca.Repo.get!(Arca.Schemas.Execution, id)

  test "admission opens the first attempt and points the row at it", %{actor: actor} do
    {execution, attempt} = admit!(actor)

    assert attempt.fence == 1
    assert attempt.state == "running"
    assert %DateTime{} = attempt.running_since
    assert execution.current_attempt == attempt.attempt
    assert reload(execution.id).current_attempt == attempt.attempt
    assert %{attempt: a} = ExecutionAttempts.current(actor, execution.id)
    assert a == attempt.attempt
  end

  test "renewal answers only the owner", %{actor: actor} do
    {_execution, attempt} = admit!(actor)
    until = DateTime.add(DateTime.utc_now(), 300, :second)

    assert {:ok, ^until} =
             ExecutionAttempts.renew(attempt.attempt, until, Arca.Test.Actor.stored())

    assert {:ok, _ran} =
             ExecutionAttempts.close(
               actor,
               attempt.attempt,
               "completed",
               "ok",
               Arca.Test.Actor.stored()
             )

    assert :lost = ExecutionAttempts.renew(attempt.attempt, until, Arca.Test.Actor.stored())

    assert {:error, :attempt_not_owner} =
             ExecutionAttempts.close(
               actor,
               attempt.attempt,
               "failed",
               "error",
               Arca.Test.Actor.stored()
             )
  end

  test "pause and resume account each running interval once, and close works from paused", %{
    actor: actor
  } do
    {_execution, attempt} = admit!(actor)
    Process.sleep(20)

    {:ok, ran} =
      Arca.Repo.transaction(fn ->
        ExecutionAttempts.pause!(actor, attempt.attempt)
      end)

    assert ran >= 20
    paused = ExecutionAttempts.get(actor, attempt.attempt)
    assert paused.state == "paused"
    assert is_nil(paused.running_since)

    # Not the running owner any more: a second pause moves nothing.
    assert {:ok, nil} =
             Arca.Repo.transaction(fn ->
               ExecutionAttempts.pause!(actor, attempt.attempt)
             end)

    until = DateTime.add(DateTime.utc_now(), 300, :second)

    assert {:ok, 1} =
             Arca.Repo.transaction(fn ->
               ExecutionAttempts.resume!(
                 actor,
                 attempt.attempt,
                 until,
                 Arca.Test.Actor.grant(actor.athanor_id)
               )
             end)

    resumed = ExecutionAttempts.get(actor, attempt.attempt)
    assert resumed.state == "running"
    assert %DateTime{} = resumed.running_since
    assert DateTime.compare(resumed.lease_until, until) == :eq

    {:ok, _} =
      Arca.Repo.transaction(fn ->
        ExecutionAttempts.pause!(actor, attempt.attempt)
      end)

    assert {:ok, 0} =
             ExecutionAttempts.close(
               actor,
               attempt.attempt,
               "cancelled",
               "cancelled",
               Arca.Test.Actor.stored()
             )

    assert %{state: "cancelled", outcome: "cancelled", ended_at: %DateTime{}} =
             ExecutionAttempts.get(actor, attempt.attempt)
  end

  test "the sweeper retires an attempt on the lease it observed, and a takeover opens the successor",
       %{actor: actor} do
    {execution, attempt} = admit!(actor)
    lapsed = DateTime.add(DateTime.utc_now(), -10, :second)

    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^attempt.attempt),
        set: [lease_until: lapsed]
      )

    assert [%{attempt: stale}] = ExecutionAttempts.list_stale(DateTime.utc_now())
    assert stale == attempt.attempt

    # A renewal that landed after the scan changes the lease; the sweep's
    # observed value then matches nothing.
    later = DateTime.add(DateTime.utc_now(), 300, :second)
    assert {:ok, nil} = ExecutionAttempts.lapse(attempt.attempt, later, Arca.Test.Actor.stored())

    assert {:ok, ran} = ExecutionAttempts.lapse(attempt.attempt, lapsed, Arca.Test.Actor.stored())
    assert is_integer(ran)

    assert %{state: "lapsed", outcome: "uncertain"} =
             ExecutionAttempts.get(actor, attempt.attempt)

    # The stale attempt cannot complete its work.
    assert {:error, :attempt_not_owner} =
             ExecutionAttempts.close(
               actor,
               attempt.attempt,
               "completed",
               "ok",
               Arca.Test.Actor.stored()
             )

    assert {:ok, %{previous: %{attempt: prev}, attempt: successor}} =
             ExecutionAttempts.takeover(actor, execution.id,
               boot_id: "boot-2",
               lease_until: later,
               grant: :stored,
               verify: &Arca.Test.Actor.admits/1
             )

    assert prev == attempt.attempt
    assert successor.fence == 2
    assert successor.state == "running"
    assert reload(execution.id).current_attempt == successor.attempt
    assert :lost = ExecutionAttempts.renew(attempt.attempt, later, Arca.Test.Actor.stored())
    assert {:ok, _} = ExecutionAttempts.renew(successor.attempt, later, Arca.Test.Actor.stored())

    # A second takeover retires the successor and takes fence 3.
    assert {:ok, %{attempt: third}} =
             ExecutionAttempts.takeover(actor, execution.id,
               boot_id: "boot-3",
               lease_until: later,
               grant: :stored,
               verify: &Arca.Test.Actor.admits/1
             )

    assert third.fence == 3

    assert %{state: "lapsed"} =
             ExecutionAttempts.get(actor, successor.attempt)
  end

  test "the sweep never sees a paused attempt", %{actor: actor} do
    {_execution, attempt} = admit!(actor)

    {:ok, _} =
      Arca.Repo.transaction(fn ->
        ExecutionAttempts.pause!(actor, attempt.attempt)
      end)

    lapsed = DateTime.add(DateTime.utc_now(), -10, :second)

    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^attempt.attempt),
        set: [lease_until: lapsed]
      )

    assert [] = ExecutionAttempts.list_stale(DateTime.utc_now())
  end

  test "the hold and step barriers refuse an admission whose hold or step moved", %{actor: actor} do
    {root, root_attempt} =
      admit!(actor,
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 2}
      )

    reservation = Arca.Repo.get_by!(Arca.Schemas.BudgetReservation, root_execution_id: root.id)

    charge = %{
      id: "chg_child",
      attempt: root_attempt.attempt,
      generation: 0,
      holder_execution_id: "exec_child_1"
    }

    assert :ok =
             Arca.BudgetReservations.charge(actor, reservation.id, charge, 1)

    # The hold is stamped admitted by the barrier.
    assert {:ok, _} =
             Arca.Execution.admit(
               %{
                 id: "exec_child_1",
                 reference: "catalyst:local.files:0.1.0",
                 user_id: actor.user_id,
                 athanor_id: actor.athanor_id,
                 component_type: "catalyst",
                 parent_execution_id: root.id,
                 root_execution_id: root.id
               },
               charge: %{reservation_id: reservation.id, id: "chg_child"},
               grant: Arca.Test.Actor.grant(actor.athanor_id),
               verify: &Arca.Test.Actor.admits/1
             )

    assert {:ok, [%{admitted_at: %DateTime{}}]} =
             Arca.BudgetReservations.charges(actor, reservation.id)

    # An expired hold refuses admission.
    assert :ok =
             Arca.BudgetReservations.charge(
               actor,
               reservation.id,
               %{charge | id: "chg_late", holder_execution_id: "exec_child_2"},
               1
             )

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.BudgetCharge, where: c.id == "chg_late"),
        set: [admit_by: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    assert {:error, :hold_expired} =
             Arca.Execution.admit(
               %{
                 id: "exec_child_2",
                 reference: "catalyst:local.files:0.1.0",
                 user_id: actor.user_id,
                 athanor_id: actor.athanor_id,
                 component_type: "catalyst",
                 parent_execution_id: root.id,
                 root_execution_id: root.id
               },
               charge: %{reservation_id: reservation.id, id: "chg_late"},
               grant: Arca.Test.Actor.grant(actor.athanor_id),
               verify: &Arca.Test.Actor.admits/1
             )

    refute Arca.Repo.get(Arca.Schemas.Execution, "exec_child_2")
  end

  describe "a child admitted under its parent's attempt" do
    defp admit_child(actor, parent, parent_attempt) do
      id = "exec_child_#{System.unique_integer([:positive])}"

      result =
        Arca.Execution.admit(
          %{
            id: id,
            reference: "reagent:local.child:0.1.0",
            user_id: actor.user_id,
            athanor_id: actor.athanor_id,
            component_type: "reagent",
            parent_execution_id: parent.id,
            root_execution_id: parent.id
          },
          parent_attempt: parent_attempt,
          grant: Arca.Test.Actor.grant(actor.athanor_id),
          verify: &Arca.Test.Actor.admits/1
        )

      {result, id}
    end

    test "is admitted while the attempt owns its running parent", %{actor: actor} do
      {parent, attempt} = admit!(actor)

      assert {{:ok, %{execution: child}}, _id} = admit_child(actor, parent, attempt.attempt)
      assert child.parent_execution_id == parent.id

      assert %{fence: 1, state: "running"} =
               ExecutionAttempts.get(actor, attempt.attempt)
    end

    test "is refused once the parent closed, lapsed, was cancelled or taken over", %{actor: actor} do
      ended = [
        fn parent, attempt ->
          {:ok, _} =
            ExecutionAttempts.close(
              actor,
              attempt.attempt,
              "completed",
              "ok",
              Arca.Test.Actor.stored()
            )

          {1, _} =
            Arca.Repo.update_all(from(e in Arca.Schemas.Execution, where: e.id == ^parent.id),
              set: [status: "completed"]
            )
        end,
        fn parent, attempt ->
          {1, _} =
            Arca.Execution.mark_failed_if_running(
              parent.id,
              %{completed_at: DateTime.utc_now(), duration_ms: 0, error_message: "lapsed"},
              attempt: attempt.attempt,
              lease_until: attempt.lease_until,
              event: "execution.lapsed",
              grant: :stored,
              verify: &Arca.Test.Actor.admits/1
            )
        end,
        fn _parent, attempt ->
          {:ok, _} =
            ExecutionAttempts.close(
              actor,
              attempt.attempt,
              "cancelled",
              "cancelled",
              Arca.Test.Actor.stored()
            )
        end,
        fn parent, _attempt ->
          {:ok, _} =
            ExecutionAttempts.takeover(actor, parent.id,
              boot_id: Prima.Boot.id(),
              lease_until: ExecutionAttempts.lease_until(),
              grant: :stored,
              verify: &Arca.Test.Actor.admits/1
            )
        end
      ]

      for end_parent <- ended do
        {parent, attempt} = admit!(actor)
        end_parent.(parent, attempt)

        assert {{:error, :parent_ended}, id} = admit_child(actor, parent, attempt.attempt)
        refute Arca.Repo.get(Arca.Schemas.Execution, id)
      end
    end

    test "is refused under an attempt of another execution", %{actor: actor} do
      {parent, _attempt} = admit!(actor)
      {_other, other_attempt} = admit!(actor)

      assert {{:error, :parent_ended}, id} = admit_child(actor, parent, other_attempt.attempt)
      refute Arca.Repo.get(Arca.Schemas.Execution, id)
    end
  end
end
