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

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
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
          input: "{}",
          origin: :programmatic
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

  describe "a guest object's write" do
    # A storage root of the test's own and an attempt claimed by `@runner`
    # at fence 1, whose run has read `sources`.
    defp writer!(actor, sources \\ []) do
      dir = Path.join(System.tmp_dir!(), "attempt_objects_#{System.unique_integer([:positive])}")
      previous = Application.get_env(:arca, :base_path)

      on_exit(fn ->
        Application.put_env(:arca, :base_path, previous)
        File.rm_rf!(dir)
      end)

      File.mkdir_p!(dir)
      Application.put_env(:arca, :base_path, dir)
      Arca.Cache.init()
      Arca.Usage.invalidate(actor)

      {execution, attempt} = admit!(actor)

      :ok =
        ExecutionAttempts.claim(actor, attempt.attempt, 1, "runner_o", Arca.Test.Actor.stored())

      :ok = Arca.Execution.join_sources(actor, execution.id, sources)
      %{actor: actor, execution: execution, attempt: attempt.attempt}
    end

    defp held(w, write), do: held(w, write, "runner_o")

    defp held(w, write, runner),
      do:
        ExecutionAttempts.while_held(
          w.actor,
          w.attempt,
          1,
          runner,
          write,
          Arca.Test.Actor.stored()
        )

    # A put whose store call stores at the mark's key, then runs `also`.
    defp put(path, bytes, also) do
      %{
        op: :put,
        path: path,
        bytes: byte_size(bytes),
        io: fn mark ->
          result = Arca.put(Arca.Test.Actor.local(), path, bytes, mark: mark)
          also.(mark)
          result
        end
      }
    end

    defp revision(actor, path),
      do: Arca.Repo.get_by(Arca.Schemas.ObjectRevision, athanor_id: actor.athanor_id, path: path)

    defp intents(w), do: ExecutionAttempts.write_intents(w.actor, w.attempt)

    defp cancel!(w) do
      {:ok, _} =
        Arca.Execution.record_end(
          w.actor,
          w.execution.id,
          "cancelled",
          %{completed_at: DateTime.utc_now(), duration_ms: 1},
          w.attempt,
          Arca.Test.Actor.stored()
        )

      :ok
    end

    test "marks its generation on the intent, stores at the generation's key, never at the path, and settles with the run's ledger",
         %{actor: actor} do
      w = writer!(actor, [Prima.Source.new(:filed)])
      path = ["data", "g.txt"]

      # The ledger also grows while the store is in flight: the settlement
      # carries what the run had read by then.
      grow = fn _mark ->
        :ok = Arca.Execution.join_sources(actor, w.execution.id, [Prima.Source.outside("x.test")])
      end

      assert {:ok, {:confirmed, :ok}} = held(w, put(path, "bytes", grow))

      assert [%{state: "confirmed", generation: generation}] = intents(w)
      assert %{settled_generation: ^generation} = revision(actor, "data/g.txt")

      assert %{sources: recorded} =
               Arca.Repo.get_by(Arca.Schemas.ObjectGeneration,
                 athanor_id: actor.athanor_id,
                 path: "data/g.txt",
                 generation: generation
               )

      assert Prima.Source.decode(recorded) == [Prima.Source.new(:filed)]

      assert {:ok, "bytes", sources} = Arca.ObjectRevisions.read(actor, path)
      assert sources == [Prima.Source.new(:filed), Prima.Source.outside("x.test")]

      assert {:ok, "bytes"} =
               Arca.Adapters.Local.get(actor, ["objects", "#{generation}" | path])

      refute File.exists?(Arca.Adapters.Local.build_path(actor, path))
    end

    test "whose hold ends while the store is in flight is uncertain, and its generation is never read",
         %{actor: actor} do
      w = writer!(actor)
      path = ["data", "h.txt"]
      :ok = Arca.put(actor, path, "before", sources: [])

      assert {:ok, {:uncertain, :hold_lost}} =
               held(w, put(path, "after", fn _mark -> cancel!(w) end))

      assert [%{state: "uncertain", generation: generation}] = intents(w)
      assert %{settled_generation: settled} = revision(actor, "data/h.txt")
      assert settled < generation
      assert {:ok, "before"} = Arca.get(actor, path)
    end

    test "marked before another writer's delete is failed dead, and the path stays deleted",
         %{actor: actor} do
      w = writer!(actor)
      path = ["data", "d.txt"]
      :ok = Arca.put(actor, path, "v1", sources: [])

      assert {:ok, {:failed, {:error, :dead}}} =
               held(w, put(path, "late", fn _mark -> :ok = Arca.delete(actor, path) end))

      assert [%{state: "failed", reason: "dead"}] = intents(w)
      assert {:error, :not_found} = Arca.get(actor, path)
      assert %{deleted: true, settled_generation: nil} = revision(actor, "data/d.txt")
    end

    test "under a file settled while it was in flight is failed by its shape, and nothing of it published",
         %{actor: actor} do
      w = writer!(actor)
      child = ["data", "shape", "c.txt"]

      settle_parent = fn _mark ->
        :ok = Arca.put(actor, ["data", "shape"], "a file now", sources: [])
      end

      assert {:ok, {:failed, {:error, :enotdir}}} = held(w, put(child, "child", settle_parent))
      assert [%{state: "failed", reason: "enotdir"}] = intents(w)
      assert {:ok, "a file now"} = Arca.get(actor, ["data", "shape"])
      assert {:error, :not_found} = Arca.get(actor, child)
    end

    test "a delete stores nothing and tombstones the row at its settlement", %{actor: actor} do
      w = writer!(actor)
      path = ["data", "gone.txt"]
      :ok = Arca.put(actor, path, "v1", sources: [])

      assert {:ok, {:confirmed, :ok}} =
               held(w, %{op: :delete, path: path, io: fn _mark -> :ok end})

      assert [%{state: "confirmed", generation: generation}] = intents(w)

      assert %{deleted: true, deleted_at_generation: ^generation} =
               revision(actor, "data/gone.txt")

      assert {:error, :not_found} = Arca.get(actor, path)

      assert {:ok, {:failed, {:error, :not_found}}} =
               held(w, %{op: :delete, path: path, io: fn _mark -> flunk("stored") end})
    end

    test "an append whose base moves under its store re-derives under a fresh generation on the same intent",
         %{actor: actor} do
      w = writer!(actor)
      path = ["data", "a.log"]
      :ok = Arca.put(actor, path, "base;", sources: [])
      moved = :counters.new(1, [])

      append = %{
        op: :append,
        path: path,
        bytes: 6,
        io: fn mark ->
          # The first store finds another writer has settled over its base.
          if :counters.get(moved, 1) == 0 do
            :counters.add(moved, 1, 1)
            :ok = Arca.put(actor, path, "moved;", sources: [])
          end

          Arca.append(actor, path, "suffix", mark: mark)
        end
      }

      assert {:ok, {:confirmed, :ok}} = held(w, append)
      assert {:ok, "moved;suffix"} = Arca.get(actor, path)
      assert [%{state: "confirmed", generation: generation}] = intents(w)
      assert %{settled_generation: ^generation} = revision(actor, "data/a.log")
    end

    test "an append whose base moves at every attempt is failed precondition_failed past the bound, nothing of it landed",
         %{actor: actor} do
      w = writer!(actor)
      path = ["data", "c.log"]
      :ok = Arca.put(actor, path, "base;", sources: [])
      moves = :counters.new(1, [])

      append = %{
        op: :append,
        path: path,
        bytes: 6,
        io: fn mark ->
          :counters.add(moves, 1, 1)
          :ok = Arca.put(actor, path, "moved-#{:counters.get(moves, 1)};", sources: [])
          Arca.append(actor, path, "suffix", mark: mark)
        end
      }

      assert {:ok, {:failed, {:error, :precondition_failed}}} = held(w, append)
      assert :counters.get(moves, 1) == Arca.ObjectRevisions.append_attempts()
      assert [%{state: "failed", reason: "precondition_failed"}] = intents(w)
      assert {:ok, bytes} = Arca.get(actor, path)
      refute bytes =~ "suffix"
    end

    test "a read joins the object's settled sources into the run's ledger before answering its bytes",
         %{actor: actor} do
      w = writer!(actor)
      path = ["data", "r.txt"]
      :ok = Arca.put(actor, path, "disclosed", sources: [Prima.Source.new(:vault_disclosed)])

      assert {:ok, []} = Arca.Execution.sources(actor, w.execution.id)
      assert {:ok, {:read, {:ok, "disclosed"}}} = held(w, %{op: :read, path: path})

      assert {:ok, [%Prima.Source{class: :vault_disclosed}]} =
               Arca.Execution.sources(actor, w.execution.id)

      assert {:ok, {:read, {:error, :not_found}}} =
               held(w, %{op: :read, path: ["data", "missing.txt"]})

      # A runner that does not hold the attempt reads nothing.
      assert {:error, :lost} = held(w, %{op: :read, path: path}, "runner_other")
    end

    test "while its intent is pending, retention keeps its generation and object", %{actor: actor} do
      w = writer!(actor)
      path = ["data", "p.txt"]
      test = self()

      task =
        Task.async(fn ->
          held(
            w,
            put(path, "pending", fn _mark ->
              send(test, {:stored, self()})

              receive do
                :settle -> :ok
              end
            end)
          )
        end)

      assert_receive {:stored, store}, 5_000

      # A later mark leaves the pending write's generation behind the row's
      # last one, so only its intent says it may still settle.
      {:ok, {:ok, _later_mark}} =
        Arca.Repo.transaction(fn ->
          Arca.ObjectRevisions.mark!(actor, path, :put, %{bytes: 1, sources: []})
        end)

      later = DateTime.add(DateTime.utc_now(), 86_400, :second)
      assert {:ok, 0} = Arca.ObjectRevisions.collect(actor, later, false)
      assert [%{state: "pending", generation: generation}] = intents(w)

      assert {:ok, "pending"} =
               Arca.Adapters.Local.get(actor, ["objects", "#{generation}" | path])

      send(store, :settle)
      assert {:ok, {:confirmed, :ok}} = Task.await(task)
      assert {:ok, "pending"} = Arca.get(actor, path)
    end

    test "a store call taking a mark is refused outside data/, and one taking none under it",
         %{actor: actor} do
      w = writer!(actor)

      assert_raise ArgumentError, fn ->
        held(w, %{op: :put, path: ["threads", "x.txt"], bytes: 1, io: fn _mark -> :ok end})
      end

      # An unmarked store would write the path itself, which nothing reads.
      assert_raise ArgumentError, fn ->
        held(w, %{op: :put, path: ["data", "x.txt"], bytes: 1, io: fn -> flunk("stored") end})
      end

      assert [] = intents(w)
    end
  end
end
