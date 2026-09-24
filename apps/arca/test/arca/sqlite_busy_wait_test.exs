# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SqliteBusyWaitTest do
  @moduledoc """
  SQLite's write lock, taken by `Arca.Repo.prepare_transaction/2` as every
  transaction starts, with the wait inside the driver bounded to a
  quantum and the rest of it spent in Elixir.

  The driver waits out a busy lock inside the NIF holding its
  connection's mutex, and a statement of that connection freed by another
  process takes the same mutex on that process's scheduler. A holder that
  freed a waiter's statements while the waiter sat out the whole busy
  timeout inside the driver would starve, still holding the lock, until
  the waiter gave up. Every case runs under real connections, outside the
  sandbox. PostgreSQL has no such lock, so the file runs on SQLite only.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Arca.Schemas.JobClaim
  alias Ecto.Adapters.SQL.Sandbox
  alias Exqlite.Sqlite3

  if Arca.Repo.adapter() != Ecto.Adapters.SQLite3 do
    @moduletag skip: "SQLite's one write lock; PostgreSQL locks rows"
  end

  # `Arca.Repo`'s longest wait inside the driver for one attempt.
  @quantum_ms 100
  # How many statements of the waiter's connection the holder frees.
  @statements 3
  # A lock-wait deadline short enough to run out inside a case.
  @short_ms 300

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    key = "busy-wait-#{System.unique_integer([:positive])}"
    {:ok, claim} = unboxed(fn -> Arca.JobClaims.claim("retention", key, "boot_lock", 60_000) end)
    on_exit(fn -> unboxed(fn -> Arca.Repo.delete_all(where(JobClaim, key: ^key)) end) end)
    {:ok, claim: claim}
  end

  # Each statement of the lock-taking step, from any process, as
  # `{:lock_step, pid, step, outcome}` to the test.
  defp watch_lock_steps! do
    test = self()
    handler = "sqlite-busy-wait-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if meta.query =~ ~r/^PRAGMA busy_timeout = \d+$|WHERE 0$/,
            do: send(test, {:lock_step, self(), step(meta.query), outcome(meta.result)})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp step("PRAGMA busy_timeout = " <> ms), do: {:busy_timeout, String.to_integer(ms)}
  defp step(_write_where_0), do: :take_lock

  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, %Exqlite.Error{message: message}}), do: {:error, message}
  defp outcome({:error, error}), do: {:error, error}

  # The steps `pid` has reported so far, in order. A process reports each
  # before its call returns, so after its result is in they are all here.
  defp lock_steps(pid) do
    receive do
      {:lock_step, ^pid, step, outcome} -> [{step, outcome} | lock_steps(pid)]
    after
      0 -> []
    end
  end

  defp one_acquisition(pool),
    do: [{{:busy_timeout, @quantum_ms}, :ok}, {:take_lock, :ok}, {{:busy_timeout, pool}, :ok}]

  # A connection of its own, outside the pool, that never waits for a lock.
  defp raw_connection! do
    {:ok, raw} = Sqlite3.open(Arca.Repo.config()[:database])
    :ok = Sqlite3.execute(raw, "PRAGMA busy_timeout = 0")
    on_exit(fn -> Sqlite3.close(raw) end)
    raw
  end

  # A locking transaction that holds the write lock until told to let go.
  defp hold_lock do
    test = self()

    Task.async(fn ->
      unboxed(fn ->
        Arca.Repo.locking_transaction(fn ->
          send(test, :holding)

          receive do
            :release -> :ok
          end
        end)
      end)
    end)
  end

  # Statements of the calling process's pooled connection, prepared
  # through the pool as Ecto prepares its own, and kept in `table` as
  # Ecto's query cache keeps them.
  defp prepare_on_own_connection!(table) do
    %{pid: pool, opts: opts} = Ecto.Adapter.lookup_meta(Arca.Repo)

    for i <- 1..@statements do
      query = Exqlite.Query.build(statement: "SELECT #{i}")
      {:ok, prepared, _result} = DBConnection.prepare_execute(pool, query, [], opts)
      true = :ets.insert(table, {i, prepared})
    end

    :ok
  end

  # The holder's scheduler, bound: a bound process is never stolen by an
  # idle scheduler, so it waits for the one it released the statements on,
  # as it does whenever no other scheduler is free to take it.
  defp bind_to_first_scheduler, do: apply(:erlang, :process_flag, [:scheduler, 1])

  test "a holder that frees a waiting connection's statements commits within two quanta", %{
    claim: claim
  } do
    started = System.monotonic_time(:millisecond)
    test = self()
    watch_lock_steps!()
    statements = :ets.new(:waiter_statements, [:public, :set])

    holder =
      Task.async(fn ->
        bind_to_first_scheduler()

        unboxed(fn ->
          result =
            Arca.Repo.locking_transaction(fn ->
              {1, _} =
                Arca.Repo.update_all(where(JobClaim, id: ^claim.id), set: [detail: "holder"])

              send(test, :holding)

              receive do
                :release -> :ok
              end

              released = System.monotonic_time(:millisecond)

              # The last reference to each goes here, as an overwritten
              # cache row lets go of it: each statement is finalized on
              # this process's scheduler, taking the waiter's mutex.
              for i <- 1..@statements, do: :ets.update_element(statements, i, {2, nil})

              Arca.Repo.query!("SELECT 1")
              released
            end)

          {result, System.monotonic_time(:millisecond)}
        end)
      end)

    assert_receive :holding, 5_000

    waiter =
      Task.async(fn ->
        unboxed(fn ->
          prepare_on_own_connection!(statements)
          # The table now holds the only reference to each statement.
          :erlang.garbage_collect()
          send(test, :waiting)

          Arca.Repo.locking_transaction(fn ->
            detail =
              Arca.Repo.one(from(c in JobClaim, where: c.id == ^claim.id, select: c.detail))

            {1, _} = Arca.Repo.update_all(where(JobClaim, id: ^claim.id), set: [detail: "waiter"])
            detail
          end)
        end)
      end)

    assert_receive :waiting, 5_000
    waiter_pid = waiter.pid

    # The waiter is inside its wait once the lock answers it busy. The
    # bound lets a waiter that waits some other way (the whole busy
    # timeout inside the driver) reach the release, and show its cost.
    told_busy? =
      receive do
        {:lock_step, ^waiter_pid, :take_lock, {:error, _busy}} -> true
      after
        5 * @quantum_ms -> false
      end

    # Back inside the driver for its next attempt: its pause is at most
    # 25 ms, and the attempt that follows holds the mutex for a quantum.
    Process.sleep(30)
    send(holder.pid, :release)

    assert {{:ok, released}, committed} = Task.await(holder, 25_000)

    assert committed - released <= 2 * @quantum_ms,
           "the holder took #{committed - released} ms to commit after freeing the waiter's statements"

    # The waiter acted on the holder's commit.
    assert {:ok, "holder"} = Task.await(waiter, 25_000)
    assert System.monotonic_time(:millisecond) - started < 1_000

    # Busy, retried from Elixir, then taken; the pool's timeout restored.
    assert told_busy?
    pool = Arca.Repo.busy_timeout_ms()
    assert [{{:busy_timeout, @quantum_ms}, :ok} | rest] = lock_steps(waiter_pid)
    assert {retries, [{:take_lock, :ok}, {{:busy_timeout, ^pool}, :ok}]} = Enum.split(rest, -2)
    assert Enum.all?(retries, &match?({:take_lock, {:error, _busy}}, &1))
  end

  test "the lock-taking step alone holds the one write lock until the transaction ends" do
    watch_lock_steps!()
    raw = raw_connection!()
    holder = hold_lock()
    assert_receive :holding, 5_000

    # The holder's transaction has run nothing but the step.
    assert lock_steps(holder.pid) == one_acquisition(Arca.Repo.busy_timeout_ms())
    assert {:error, locked} = Sqlite3.execute(raw, "BEGIN IMMEDIATE")
    assert locked =~ "locked"

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 5_000)

    assert :ok = Sqlite3.execute(raw, "BEGIN IMMEDIATE")
    assert :ok = Sqlite3.execute(raw, "ROLLBACK")
  end

  test "a nested transaction and a read transaction take no lock of their own" do
    watch_lock_steps!()

    assert {:ok, {:ok, {:ok, :inner}}} =
             unboxed(fn ->
               Arca.Repo.locking_transaction(fn ->
                 Arca.Repo.transaction(fn -> Arca.Repo.read_transaction(fn -> :inner end) end)
               end)
             end)

    assert lock_steps(self()) == one_acquisition(Arca.Repo.busy_timeout_ms())

    assert {:ok, :read} = unboxed(fn -> Arca.Repo.read_transaction(fn -> :read end) end)
    assert lock_steps(self()) == []
  end

  test "a read transaction leaves the write lock to a writer", %{claim: claim} do
    test = self()
    raw = raw_connection!()

    reader =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.read_transaction(fn ->
            detail =
              Arca.Repo.one(from(c in JobClaim, where: c.id == ^claim.id, select: c.detail))

            send(test, :reading)

            receive do
              :done -> detail
            end
          end)
        end)
      end)

    assert_receive :reading, 5_000
    assert :ok = Sqlite3.execute(raw, "BEGIN IMMEDIATE")
    assert :ok = Sqlite3.execute(raw, "ROLLBACK")

    send(reader.pid, :done)
    assert {:ok, nil} = Task.await(reader, 5_000)
  end

  test "a multi takes the lock as its first step, the one key it adds" do
    multi =
      Ecto.Multi.run(Ecto.Multi.new(), :seen, fn _repo, changes -> {:ok, Map.keys(changes)} end)

    assert {:ok, changes} = unboxed(fn -> Arca.Repo.locking_transaction(multi) end)
    assert changes == %{arca_lock: :acquired, seen: [:arca_lock]}

    refusing = Ecto.Multi.run(multi, :refuse, fn _repo, _changes -> {:error, :refused} end)

    assert {:error, :refuse, :refused, so_far} =
             unboxed(fn -> Arca.Repo.locking_transaction(refusing) end)

    assert so_far == %{arca_lock: :acquired, seen: [:arca_lock]}
  end

  test "the connection waits the pool's deadline again before the caller's work and after it" do
    pool = Arca.Repo.busy_timeout_ms()
    assert pool == Arca.Repo.config()[:busy_timeout]

    unboxed(fn ->
      assert {:ok, %{rows: [[^pool]]}} =
               Arca.Repo.locking_transaction(fn -> Arca.Repo.query!("PRAGMA busy_timeout") end)

      assert %{rows: [[^pool]]} = Arca.Repo.query!("PRAGMA busy_timeout")
    end)
  end

  test "out of time, the step raises before the caller's work, and a facade answers database_error" do
    test = self()
    pool = Arca.Repo.busy_timeout_ms()
    holder = hold_lock()
    assert_receive :holding, 5_000

    config = Application.fetch_env!(:arca, Arca.Repo)
    on_exit(fn -> Application.put_env(:arca, Arca.Repo, config) end)
    Application.put_env(:arca, Arca.Repo, Keyword.put(config, :busy_timeout, @short_ms))

    try do
      unboxed(fn ->
        try do
          error =
            assert_raise Arca.Repo.BusyTimeoutError, fn ->
              Arca.Repo.locking_transaction(fn -> send(test, :ran) end)
            end

          refute_received :ran
          assert Exception.message(error) =~ "within #{@short_ms} ms"
          refute Exception.message(error) =~ ~r/UPDATE|schema_migrations|WHERE/i

          # The connection's own wait is the pool's deadline again, not
          # the quantum.
          assert %{rows: [[@short_ms]]} = Arca.Repo.query!("PRAGMA busy_timeout")

          log =
            capture_log(fn ->
              assert {:error, :database_error} =
                       Arca.Members.seat(Cyfr.Actor.in_athanor("ath_busy_wait"), %{
                         user_id: "usr_busy_wait",
                         added_by: "x"
                       })
            end)

          assert log =~ "within #{@short_ms} ms"
          refute log =~ ~r/UPDATE|schema_migrations/
        after
          Application.put_env(:arca, Arca.Repo, config)
          Arca.Repo.query!("PRAGMA busy_timeout=#{pool}")
        end
      end)
    after
      send(holder.pid, :release)
    end

    assert {:ok, :ok} = Task.await(holder, 5_000)
  end

  test "a fresh database migrates through the hook, its first transaction taking the lock" do
    watch_lock_steps!()
    dir = Path.join(System.tmp_dir!(), "arca-fresh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    repo =
      start_supervised!(
        {Arca.Repo,
         name: nil,
         database: Path.join(dir, "fresh.db"),
         pool: DBConnection.ConnectionPool,
         pool_size: 2}
      )

    previous = Arca.Repo.put_dynamic_repo(repo)

    try do
      assert [_ | _] =
               Ecto.Migrator.run(Arca.Repo, Arca.Repo.migrations_path(), :up,
                 all: true,
                 dynamic_repo: repo,
                 log: false
               )

      assert %{rows: [[1]]} = Arca.Repo.query!("SELECT count(*) FROM server_meta")
    after
      Arca.Repo.put_dynamic_repo(previous)
    end

    # The baseline's transaction took the lock before the table it creates
    # existed: on the table the migrator made first.
    assert_received {:lock_step, _migrator, :take_lock, :ok}
  end
end
