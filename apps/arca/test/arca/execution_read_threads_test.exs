# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionReadThreadsTest do
  @moduledoc """
  A run's read threads on `executions.read_threads`: seeded in the
  admission transaction (a root's as its admission names them, a child's
  from its parent's as they stand, any its admission adds joined into its
  ancestors first), joined up the admission chain root first and below a
  turn root no further, and read as none where the stored text does not
  read.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.Execution
  alias Arca.Schemas.Execution, as: Row

  @athanor Arca.Test.Actor.athanor_id()

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp actor, do: Prima.Actor.in_athanor(@athanor)

  defp admit!(attrs) do
    {:ok, %{execution: row}} =
      Execution.admit(
        Map.merge(
          %{
            id: "exec_threads_#{System.unique_integer([:positive])}",
            reference: "catalyst:local.threads:1.0.0",
            user_id: "user_test",
            athanor_id: @athanor,
            component_type: "catalyst",
            origin: :programmatic
          },
          attrs
        )
        |> then(&Map.put_new(&1, :root_execution_id, &1[:parent_execution_id])),
        Arca.Test.Actor.standing(@athanor)
      )

    row
  end

  defp read_threads!(id) do
    {:ok, threads} = Execution.read_threads(actor(), id)
    threads
  end

  defp started_data(id) do
    Ecto.Query.from(e in Arca.Schemas.ExecutionEvent,
      where: e.execution_id == ^id and e.type == "execution.started",
      select: e.data
    )
    |> Arca.Repo.one()
    |> Jason.decode!()
  end

  test "a root is seeded as its admission names it, stored sorted once each, and the started event records only the attempt" do
    root = admit!(%{read_threads: ["thr_b", "thr_a", "thr_b"]})

    assert read_threads!(root.id) == ["thr_a", "thr_b"]
    assert Arca.Repo.get!(Row, root.id).read_threads == ~s(["thr_a","thr_b"])
    assert started_data(root.id) == %{"attempt" => root.current_attempt}

    bare = admit!(%{})
    assert read_threads!(bare.id) == []
    assert Arca.Repo.get!(Row, bare.id).read_threads == "[]"
  end

  test "a child starts from its parent's read threads as they stand, and what its admission adds reaches its ancestors first" do
    root = admit!(%{read_threads: ["thr_a"]})
    child = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})
    assert read_threads!(child.id) == ["thr_a"]

    proxy =
      admit!(%{
        parent_execution_id: child.id,
        root_execution_id: root.id,
        kind: "tool_call",
        component_type: "tool_server",
        read_threads: ["thr_b"]
      })

    assert read_threads!(proxy.id) == ["thr_a", "thr_b"]
    assert read_threads!(child.id) == ["thr_a", "thr_b"]
    assert read_threads!(root.id) == ["thr_a", "thr_b"]
  end

  test "a child's admission ignores no parent growth: a later child sees what its parent read since" do
    root = admit!(%{})
    first = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})
    assert read_threads!(first.id) == []

    assert :ok = Execution.join_threads(actor(), root.id, ["thr_a"])
    second = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})

    assert read_threads!(second.id) == ["thr_a"]
    assert read_threads!(first.id) == []
  end

  test "a join reaches the run and every ancestor, never a sibling, and only grows" do
    root = admit!(%{})
    parent = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})
    child = admit!(%{parent_execution_id: parent.id, root_execution_id: root.id})
    sibling = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})

    assert :ok = Execution.join_threads(actor(), child.id, ["thr_b"])
    assert :ok = Execution.join_threads(actor(), child.id, ["thr_a"])
    assert :ok = Execution.join_threads(actor(), parent.id, [])

    for id <- [child.id, parent.id, root.id], do: assert(read_threads!(id) == ["thr_a", "thr_b"])
    assert read_threads!(sibling.id) == []

    assert Execution.join_threads(actor(), "exec_none", ["thr_a"]) == {:error, :not_found}
  end

  test "a join stops below a turn root, whose read threads are its turns'" do
    turn_root = admit!(%{kind: "turn", component_type: "agent"})
    hand = admit!(%{parent_execution_id: turn_root.id, root_execution_id: turn_root.id})

    assert :ok = Execution.join_threads(actor(), hand.id, ["thr_a"])

    assert read_threads!(hand.id) == ["thr_a"]
    assert Arca.Repo.get!(Row, turn_root.id).read_threads == "[]"
    # No turn runs on it yet: its turns' read threads are none.
    assert read_threads!(turn_root.id) == []
  end

  test "a stored text that does not read holds no read threads, and a child inherits none from it" do
    root = admit!(%{})

    {1, _} =
      Arca.Repo.update_all(Ecto.Query.from(e in Row, where: e.id == ^root.id),
        set: [read_threads: "not json"]
      )

    assert read_threads!(root.id) == []

    child = admit!(%{parent_execution_id: root.id, root_execution_id: root.id})
    assert read_threads!(child.id) == []
  end

  test "read threads admitted that are not a list of thread ids refuse the admission, writing nothing" do
    for named <- [[%{"id" => "thr_a"}], ["thr_a", :thr_b], "thr_a"] do
      id = "exec_threads_bad_#{System.unique_integer([:positive])}"

      assert {:error, :invalid_read_threads} =
               Execution.admit(
                 %{
                   id: id,
                   root_execution_id: id,
                   reference: "catalyst:local.threads:1.0.0",
                   user_id: "user_test",
                   athanor_id: @athanor,
                   component_type: "catalyst",
                   origin: :programmatic,
                   read_threads: named
                 },
                 Arca.Test.Actor.standing(@athanor)
               )

      assert is_nil(Arca.Repo.get(Row, id))
    end
  end

  # Outside the sandbox: the case below needs transactions of its own that
  # wait on each other's locks.
  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fun)

  defp backend! do
    %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  @tag :postgres
  @tag timeout: 60_000
  test "a join made while a terminal write waits on its attempt waits for that write, " <>
         "and the completion carries the row the write left" do
    id = "exec_threads_terminal_#{System.unique_integer([:positive])}"
    joined = "thr_joined_during_close"
    parent = self()

    on_exit(fn ->
      unboxed(fn ->
        for schema <- [Arca.Schemas.ExecutionEvent, Arca.Schemas.ExecutionAttempt] do
          Arca.Repo.delete_all(Ecto.Query.from(r in schema, where: r.execution_id == ^id))
        end

        Arca.Repo.delete_all(Ecto.Query.from(e in Row, where: e.id == ^id))
      end)
    end)

    attempt = unboxed(fn -> admit!(%{id: id}) end).current_attempt

    # The attempt is held, so the terminal write waits on it mid-way.
    blocker =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            Ecto.Query.from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^attempt)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one!()

            send(parent, :held)
            receive do: (:release -> :ok), after: (30_000 -> Arca.Repo.rollback(:timeout))
          end)
        end)
      end)

    assert_receive :held, 5_000

    ending =
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:ending, backend!()})

          Execution.record_end(
            actor(),
            id,
            "completed",
            %{completed_at: DateTime.utc_now(), duration_ms: 1},
            attempt,
            Arca.Test.Actor.stored()
          )
        end)
      end)

    assert_receive {:ending, ending_backend}, 5_000
    Arca.Test.LockWait.await_lock_wait!(ending_backend, ["execution_attempts"])

    joining =
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:joining, backend!()})
          Execution.join_threads(actor(), id, [joined])
        end)
      end)

    # The terminal write holds the row: the join waits on it, never lands
    # between the write's read and its update.
    assert_receive {:joining, joining_backend}, 5_000
    Arca.Test.LockWait.await_lock_wait!(joining_backend, ["executions"])

    send(blocker.pid, :release)
    assert {:ok, :ok} = Task.await(blocker)
    assert {:ok, terminal} = Task.await(ending)
    assert :ok = Task.await(joining)

    # The completion carries the read threads the run ended with; the
    # join, made after, is the row's alone.
    assert Execution.row_threads(terminal) == []
    assert read_threads!(id) == [joined]
  end
end
