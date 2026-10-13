# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.LockWaitTest do
  @moduledoc """
  `Arca.Test.LockWait.await_lock_wait!/3` answers once a backend waits on
  a lock in the statement named, and fails the test within its timeout
  when none does.
  """

  # Its connections are outside the sandbox and lock a table of their own.
  use ExUnit.Case, async: false

  alias Arca.Test.LockWait

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fun)

  # A process holding `LOCK TABLE` on its own connection until told to
  # let go, and one on another connection reading the table behind it.
  defp hold_and_wait(table) do
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            Arca.Repo.query!("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")
            send(parent, :locked)
            receive do: (:release -> :ok)
          end)
        end)
      end)

    assert_receive :locked, 5_000

    waiter =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, backend})
          Arca.Repo.query!("SELECT count(*) FROM #{table}")
        end)
      end)

    assert_receive {:backend, backend}, 5_000
    {holder, waiter, backend}
  end

  defp release({holder, waiter, _backend}) do
    send(holder.pid, :release)
    Task.await(holder, 5_000)
    Task.await(waiter, 5_000)
  end

  describe "on PostgreSQL" do
    @describetag :postgres

    setup do
      table = "lock_wait_probe_#{System.unique_integer([:positive])}"
      unboxed(fn -> Arca.Repo.query!("CREATE TABLE #{table} (id integer)") end)
      on_exit(fn -> unboxed(fn -> Arca.Repo.query!("DROP TABLE IF EXISTS #{table}") end) end)
      %{table: table}
    end

    test "answers :ok once the backend waits on the lock in the statement named", %{table: table} do
      {_holder, _waiter, backend} = held = hold_and_wait(table)

      try do
        assert :ok = LockWait.await_lock_wait!(backend, ["SELECT count(*)", table])
      after
        release(held)
      end
    end

    test "fails within its timeout when the waiting statement is not the one named",
         %{table: table} do
      {_holder, _waiter, backend} = held = hold_and_wait(table)

      try do
        error =
          assert_raise ExUnit.AssertionError, fn ->
            LockWait.await_lock_wait!(backend, ["UPDATE"], timeout_ms: 200)
          end

        assert error.message =~ "backend #{backend}"
        assert error.message =~ ~s(["UPDATE"])
        assert error.message =~ ~s(wait_event_type="Lock")
        assert error.message =~ "SELECT count(*) FROM #{table}"
      after
        release(held)
      end
    end

    test "fails within its timeout when nothing waits" do
      parent = self()

      idle =
        Task.async(fn ->
          unboxed(fn ->
            %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:backend, backend})
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive {:backend, backend}, 5_000
      started = System.monotonic_time(:millisecond)

      try do
        error =
          assert_raise ExUnit.AssertionError, fn ->
            LockWait.await_lock_wait!(backend, [], timeout_ms: 300)
          end

        elapsed = System.monotonic_time(:millisecond) - started
        assert elapsed >= 300 and elapsed < 3_000
        assert error.message =~ "backend #{backend} never waited on a lock"
      after
        send(idle.pid, :release)
        Task.await(idle, 5_000)
      end
    end
  end

  describe "on SQLite" do
    @describetag :sqlite

    test "refuses: only PostgreSQL waits on a lock this way" do
      assert_raise ArgumentError, ~r/only PostgreSQL/, fn -> LockWait.await_lock_wait!(1) end
    end
  end
end
