# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.LockWaitTest do
  @moduledoc """
  `Arca.Test.LockWait.await_lock_wait!/3` answers once a backend waits on
  a lock in the statement named, and on the lock event named when one is,
  and fails the test within its timeout when none does.
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

  # The table's one row is updated behind an advisory gate: its row
  # trigger takes `pg_advisory_lock(key)`, so the `UPDATE` waits on the
  # advisory lock while another connection holds the key, and on the row
  # while another connection holds the row. The statement seen waiting is
  # the same `UPDATE` either way.
  defp install_gate!(table, key) do
    unboxed(fn ->
      Arca.Repo.query!("INSERT INTO #{table} (id) VALUES (1)")

      Arca.Repo.query!("""
      CREATE FUNCTION #{table}_gate() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM pg_advisory_lock(#{key});
        PERFORM pg_advisory_unlock(#{key});
        RETURN NEW;
      END $$
      """)

      Arca.Repo.query!(
        "CREATE TRIGGER #{table}_gate BEFORE UPDATE ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION #{table}_gate()"
      )
    end)
  end

  # A process holding `lock` (a statement whose lock its transaction
  # keeps) until told to let go, and the gated `UPDATE` on another
  # connection.
  defp hold_and_update(table, lock) do
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            Arca.Repo.query!(lock)
            send(parent, :locked)
            receive do: (:release -> :ok)
          end)
        end)
      end)

    assert_receive :locked, 5_000

    updater =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, backend})
          Arca.Repo.query!("UPDATE #{table} SET id = id")
        end)
      end)

    assert_receive {:backend, backend}, 5_000
    {holder, updater, backend}
  end

  describe "a wait at an advisory gate, on PostgreSQL" do
    @describetag :postgres

    setup do
      table = "lock_wait_gate_#{System.unique_integer([:positive])}"
      key = System.unique_integer([:positive])
      unboxed(fn -> Arca.Repo.query!("CREATE TABLE #{table} (id integer)") end)

      on_exit(fn ->
        unboxed(fn ->
          Arca.Repo.query!("DROP TABLE IF EXISTS #{table}")
          Arca.Repo.query!("DROP FUNCTION IF EXISTS #{table}_gate()")
        end)
      end)

      install_gate!(table, key)
      %{table: table, key: key}
    end

    test "matches event: \"advisory\" once the statement waits on the advisory lock",
         %{table: table, key: key} do
      {_holder, _updater, backend} =
        held = hold_and_update(table, "SELECT pg_advisory_xact_lock(#{key})")

      try do
        assert :ok =
                 LockWait.await_lock_wait!(backend, ["UPDATE", table], event: "advisory")
      after
        release(held)
      end
    end

    test "a row wait in the same statement does not match event: \"advisory\"",
         %{table: table} do
      {_holder, _updater, backend} =
        held = hold_and_update(table, "SELECT id FROM #{table} FOR UPDATE")

      try do
        # The fragments alone are met: the statement waits, on the row.
        assert :ok = LockWait.await_lock_wait!(backend, ["UPDATE", table])

        error =
          assert_raise ExUnit.AssertionError, fn ->
            LockWait.await_lock_wait!(backend, ["UPDATE", table],
              event: "advisory",
              timeout_ms: 300
            )
          end

        assert error.message =~ ~s|never waited on a lock (wait_event="advisory")|
        # It last saw the statement waiting on the row, not at the gate.
        assert [_, seen] =
                 Regex.run(
                   ~r/last seen: wait_event_type="Lock" wait_event="([^"]+)"/,
                   error.message
                 )

        refute seen == "advisory"
      after
        release(held)
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
