# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ObjectRevisionsLockTest do
  @moduledoc """
  The row locks of guest objects (`Arca.ObjectRevisions`) under real
  PostgreSQL concurrency: every transaction that locks object rows takes
  them in one ascending path order (ancestors, the path's own row, then
  every row under it), so a host delete and a mark of the same path never
  deadlock, a prefix delete writes only the rows its ordered scan locked,
  and of a file and a path under it settling together, the one that
  settles second waits on the other's row and refuses by the tree shape,
  whichever existed first.

  Each case commits its own transactions outside the sandbox and removes
  its athanor's rows on exit; every transaction carries a statement
  timeout, so a deadlock or a lock that never frees fails the case fast.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ObjectRevisions
  alias Arca.Schemas.ObjectRevision
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres

  @pause_key {__MODULE__, :delete_scan}

  setup do
    previous_base = Application.fetch_env!(:arca, :base_path)
    base = Path.join(System.tmp_dir!(), "or_lock_#{System.unique_integer([:positive])}")
    id = "ath_or_lock_#{System.unique_integer([:positive])}"
    actor = Arca.Test.Actor.local(athanor_id: id)

    on_exit(fn ->
      unboxed(fn ->
        {:ok, _} = Arca.TenantTables.delete_all_for(actor)
        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^id))
      end)

      Arca.Usage.invalidate(actor)
      Application.put_env(:arca, :base_path, previous_base)
      File.rm_rf!(base)
    end)

    Application.put_env(:arca, :base_path, base)
    unboxed(fn -> Arca.Test.Actor.athanor!(id) end)
    Arca.Cache.init()
    Arca.Usage.invalidate(actor)
    {:ok, actor: actor}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  defp backend do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # One transaction of its own, committed outside the sandbox, answering
  # what `fun` answered, or what it raised.
  defp job(fun) do
    task =
      Task.async(fn ->
        unboxed(fn ->
          try do
            Arca.Repo.locking_transaction(fn ->
              Arca.Repo.query!("SET LOCAL statement_timeout = '8s'")
              fun.()
            end)
          rescue
            error -> {:raised, error.__struct__, Map.get(error, :postgres)}
          end
        end)
      end)

    on_exit(fn ->
      ref = Process.monitor(task.pid)
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        2_000 -> :ok
      end
    end)

    task
  end

  defp blocked_by_any?(waiter, holders) do
    unboxed(fn ->
      %{rows: [[blocking]]} = Arca.Repo.query!("SELECT pg_blocking_pids($1)", [waiter])
      Enum.any?(holders, &(&1 in blocking))
    end)
  end

  defp wait_blocked(waiter, holders, what),
    do: Prima.Test.Wait.wait_until(fn -> blocked_by_any?(waiter, holders) end, 5_000, what)

  defp gate(message) do
    receive do
      ^message -> :ok
    after
      8_000 -> raise "the case's gate did not open"
    end
  end

  defp mark(actor, path, content) do
    {:ok, {:ok, mark}} =
      unboxed(fn ->
        Arca.Repo.locking_transaction(fn ->
          ObjectRevisions.mark!(actor, path, :put, %{bytes: byte_size(content), sources: []})
        end)
      end)

    mark
  end

  # Whether the parent's settlement has answered, left in the mailbox.
  defp parent_answered? do
    receive do
      {:parent_answered, _answer} = message ->
        send(self(), message)
        true
    after
      0 -> false
    end
  end

  defp deadlock?({:raised, _module, %{code: :deadlock_detected}}), do: true
  defp deadlock?(_answer), do: false

  test "a host delete and a mark of the same path take their rows in one order and never deadlock",
       %{actor: actor} do
    parent = ["data", "p"]
    child = parent ++ ["c"]

    unboxed(fn ->
      :ok = Arca.put(actor, parent, "old parent", sources: [])
      :ok = Arca.delete(actor, parent)
      :ok = Arca.put(actor, child, "child", sources: [])
    end)

    test = self()

    # `delete/2`'s own transaction, held between its mark and settlement.
    deleting =
      job(fn ->
        {:ok, mark} = ObjectRevisions.mark!(actor, child, :delete, %{bytes: 0, sources: []})
        send(test, {:delete_marked, backend()})
        gate(:settle)
        ObjectRevisions.settle!(actor, mark, [])
      end)

    assert_receive {:delete_marked, deleting_backend}, 5_000

    marking =
      job(fn ->
        send(test, {:marking, backend()})
        ObjectRevisions.mark!(actor, child, :put, %{bytes: 3, sources: []})
      end)

    assert_receive {:marking, marking_backend}, 5_000
    wait_blocked(marking_backend, [deleting_backend], "the mark waits on the delete's rows")
    send(deleting.pid, :settle)

    answers = [Task.await(deleting, 15_000), Task.await(marking, 15_000)]
    refute Enum.any?(answers, &deadlock?/1), "40P01: #{inspect(answers)}"
    assert [{:ok, :settled}, {:ok, {:ok, _mark}}] = answers
    assert {:error, :not_found} = unboxed(fn -> Arca.get(actor, child) end)
  end

  test "a parent first marked while a path under it waits to settle: exactly one of the two publishes",
       %{actor: actor} do
    parent = ["data", "new-parent"]
    child = parent ++ ["c"]
    cm = mark(actor, child, "child")
    :ok = ObjectRevisions.store(actor, cm, "child")
    test = self()

    # A transaction holding the child's row, so its settlement waits after
    # reading ancestors that do not exist yet.
    blocker =
      job(fn ->
        from(r in ObjectRevision, where: r.athanor_id == ^actor.athanor_id and r.path == ^cm.key)
        |> Arca.QueryHelpers.for_update()
        |> Arca.Repo.one!()

        send(test, {:child_locked, backend()})
        gate(:release)
      end)

    assert_receive {:child_locked, blocker_backend}, 5_000

    settling_child =
      job(fn ->
        send(test, {:settling_child, backend()})
        ObjectRevisions.settle!(actor, cm, [])
      end)

    assert_receive {:settling_child, child_backend}, 5_000
    wait_blocked(child_backend, [blocker_backend], "the child's settlement waits on its row")

    # The parent is marked only now, after the child read its ancestors.
    parent_answer =
      case unboxed(fn ->
             Arca.Repo.locking_transaction(fn ->
               ObjectRevisions.mark!(actor, parent, :put, %{bytes: 6, sources: []})
             end)
           end) do
        {:ok, {:ok, pm}} ->
          :ok = ObjectRevisions.store(actor, pm, "parent")

          # Held open after it answers, so a publication that did not wait
          # for the child is still uncommitted while the child settles.
          settling_parent =
            job(fn ->
              send(test, {:settling_parent, backend()})
              answer = ObjectRevisions.settle!(actor, pm, [])
              send(test, {:parent_answered, answer})
              gate(:commit)
              answer
            end)

          assert_receive {:settling_parent, parent_backend}, 5_000

          # It answers, or it meets the fence on the child's row.
          Prima.Test.Wait.wait_until(
            fn ->
              parent_answered?() or
                blocked_by_any?(parent_backend, [blocker_backend, child_backend])
            end,
            5_000,
            "the parent's settlement answers or waits on the child's row"
          )

          send(blocker.pid, :release)
          assert {:ok, :ok} = Task.await(blocker, 15_000)
          child_answered = Task.await(settling_child, 15_000)
          assert_receive {:parent_answered, _answer}, 15_000
          send(settling_parent.pid, :commit)
          {Task.await(settling_parent, 15_000), child_answered}

        {:ok, {:refused, refusal}} ->
          send(blocker.pid, :release)
          assert {:ok, :ok} = Task.await(blocker, 15_000)
          {{:ok, refusal}, Task.await(settling_child, 15_000)}
      end

    {parent_answer, child_answer} = parent_answer
    refute deadlock?(child_answer) or deadlock?(parent_answer)

    answers = [child: child_answer, parent: parent_answer]
    settled = for {who, {:ok, :settled}} <- answers, do: who
    assert [published] = settled, "both or neither published: #{inspect(answers)}"
    [{_other, {:ok, refusal}}] = Keyword.delete(answers, published)
    assert refusal in [:eisdir, :enotdir]

    {parent_read, child_read} =
      unboxed(fn -> {Arca.get(actor, parent), Arca.get(actor, child)} end)

    case published do
      :child -> assert {{:error, :not_found}, {:ok, "child"}} == {parent_read, child_read}
      :parent -> assert {{:ok, "parent"}, {:error, :not_found}} == {parent_read, child_read}
    end
  end

  # Holds the process marked with `@pause_key` right after its first
  # locking read of object rows, the prefix delete's ordered scan, before
  # anything else it does. It changes no query and no answer.
  def hold_scan(_event, _measurements, metadata, test) do
    query = metadata[:query] || ""

    if Process.get(@pause_key) == true and String.starts_with?(query, "SELECT") and
         String.contains?(query, ~s("object_revisions")) and
         String.contains?(query, "FOR UPDATE") do
      Process.delete(@pause_key)
      send(test, {:prefix_scanned, self()})

      receive do
        :continue_delete -> :ok
      after
        8_000 -> raise "the prefix delete's gate did not open"
      end
    end
  end

  test "a prefix delete and a parent added after its scan never take rows in reverse order",
       %{actor: actor} do
    parent = ["data", "p"]
    child = parent ++ ["c"]
    child_mark = mark(actor, child, "child")
    :ok = ObjectRevisions.store(actor, child_mark, "child")
    assert {:error, :not_found} = unboxed(fn -> Arca.get(actor, child) end)
    test = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.hold_scan/4, test)

    # The facade's own prefix delete, held after its scan locked the child.
    deleting =
      job(fn ->
        send(test, {:deleting, backend()})
        Process.put(@pause_key, true)
        Arca.delete_tree(actor, parent)
      end)

    assert_receive {:deleting, deleting_backend}, 5_000
    assert_receive {:prefix_scanned, deleter}, 5_000
    assert deleter == deleting.pid

    # A parent the scan never saw, sorting before the child it locked.
    parent_mark = mark(actor, parent, "parent")
    :ok = ObjectRevisions.store(actor, parent_mark, "parent")

    settling_parent =
      job(fn ->
        send(test, {:settling_parent, backend()})
        ObjectRevisions.settle!(actor, parent_mark, [])
      end)

    assert_receive {:settling_parent, parent_backend}, 5_000

    wait_blocked(
      parent_backend,
      [deleting_backend],
      "the parent holds its row and waits on the delete's child row"
    )

    send(deleter, :continue_delete)
    answers = {Task.await(deleting, 15_000), Task.await(settling_parent, 15_000)}

    refute deadlock?(elem(answers, 0)) or deadlock?(elem(answers, 1)),
           "40P01: #{inspect(answers)}"

    assert {{:ok, :ok}, {:ok, :settled}} = answers

    # The parent the delete never locked publishes; the child stays dead.
    assert {{:ok, "parent"}, {:error, :not_found}} ==
             unboxed(fn -> {Arca.get(actor, parent), Arca.get(actor, child)} end)
  end
end
