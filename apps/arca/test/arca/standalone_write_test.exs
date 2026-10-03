# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StandaloneWriteTest do
  @moduledoc """
  A write run outside a transaction: `insert`, `update`, `delete` and their
  bang forms, `insert_or_update`, `insert_all`, `update_all` and
  `delete_all`. On SQLite each is a transaction of its one statement, whose
  lock step takes the write lock first; inside a transaction, and on
  PostgreSQL, it is Ecto's own statement. Each case reads the statements
  its own process issued, on node rows of its own.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.CellLease
  alias Ecto.Changeset

  @sqlite? Arca.Repo.adapter() == Ecto.Adapters.SQLite3
  # `Arca.Repo`'s longest wait inside the driver for one attempt, and the
  # write that takes the lock.
  @quantum "PRAGMA busy_timeout = 100"
  @lock ~s(UPDATE "schema_migrations" SET version = version WHERE 0)

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    node = "node-standalone-#{System.unique_integer([:positive])}"
    {:ok, node: node, rows: from(l in CellLease, where: like(l.node, ^"#{node}%"))}
  end

  test "each write outside a transaction is a transaction of its statement on SQLite, " <>
         "its lock step first, and Ecto's own statement on PostgreSQL",
       %{node: node, rows: rows} do
    {{:ok, a}, issued} = statements(fn -> Arca.Repo.insert(lease(node <> "-a")) end)
    assert_one_statement(issued, ~r/^INSERT INTO "cell_leases"/)

    {b, issued} = statements(fn -> Arca.Repo.insert!(lease(node <> "-b")) end)
    assert_one_statement(issued, ~r/^INSERT INTO "cell_leases"/)

    {{:ok, a}, issued} = statements(fn -> Arca.Repo.update(Changeset.change(a, fence: 2)) end)
    assert_one_statement(issued, ~r/^UPDATE "cell_leases"/)

    {b, issued} = statements(fn -> Arca.Repo.update!(Changeset.change(b, fence: 2)) end)
    assert_one_statement(issued, ~r/^UPDATE "cell_leases"/)

    {{:ok, c}, issued} =
      statements(fn -> Arca.Repo.insert_or_update(Changeset.change(lease(node <> "-c"))) end)

    assert_one_statement(issued, ~r/^INSERT INTO "cell_leases"/)

    {c, issued} = statements(fn -> Arca.Repo.insert_or_update!(Changeset.change(c, fence: 2)) end)
    assert_one_statement(issued, ~r/^UPDATE "cell_leases"/)

    {{2, nil}, issued} =
      statements(fn ->
        Arca.Repo.insert_all(CellLease, [entry(node <> "-d"), entry(node <> "-e")])
      end)

    assert_one_statement(issued, ~r/^INSERT INTO "cell_leases"/)

    # The caller's options reach the statement.
    {{5, nil}, issued} =
      statements(fn -> Arca.Repo.update_all(rows, [set: [owner: "boot_b"]], log: false) end)

    assert_one_statement(issued, ~r/^UPDATE "cell_leases"/)

    {{:ok, _a}, issued} = statements(fn -> Arca.Repo.delete(a) end)
    assert_one_statement(issued, ~r/^DELETE FROM "cell_leases"/)

    {_b, issued} = statements(fn -> Arca.Repo.delete!(b) end)
    assert_one_statement(issued, ~r/^DELETE FROM "cell_leases"/)

    {{3, nil}, issued} = statements(fn -> Arca.Repo.delete_all(rows) end)
    assert_one_statement(issued, ~r/^DELETE FROM "cell_leases"/)

    assert c.fence == 2
    assert Arca.Repo.all(rows) == []
  end

  test "inside a transaction a write is Ecto's own statement, under the transaction's one lock",
       %{node: node, rows: rows} do
    {{:ok, {1, nil}}, issued} =
      statements(fn ->
        Arca.Repo.transaction(fn ->
          Arca.Repo.insert!(lease(node <> "-a"))
          Arca.Repo.update_all(rows, set: [fence: 2])
          Arca.Repo.delete_all(rows)
        end)
      end)

    {lock_step, [insert, update, delete, "commit"]} =
      Enum.split(issued, if(@sqlite?, do: 4, else: 1))

    assert lock_step ==
             if(@sqlite?, do: ["begin", @quantum, @lock, pool_wait()], else: ["begin"])

    assert insert =~ ~r/^INSERT INTO "cell_leases"/
    assert update =~ ~r/^UPDATE "cell_leases"/
    assert delete =~ ~r/^DELETE FROM "cell_leases"/
  end

  test "an invalid changeset is refused as it is, with no statement and no lock", %{node: node} do
    invalid = node |> lease() |> Changeset.change() |> Changeset.add_error(:owner, "is invalid")

    assert {{:error, %Changeset{valid?: false}}, []} =
             statements(fn -> Arca.Repo.insert(invalid) end)

    assert {{:error, %Changeset{valid?: false}}, []} =
             statements(fn -> Arca.Repo.insert_or_update(invalid) end)

    assert {%Ecto.InvalidChangesetError{}, []} =
             statements(fn ->
               assert_raise Ecto.InvalidChangesetError, fn -> Arca.Repo.insert!(invalid) end
             end)
  end

  test "a constraint the changeset names answers its error, and nothing is written", %{
    node: node,
    rows: rows
  } do
    {:ok, _row} = Arca.Repo.insert(lease(node))

    duplicate =
      node
      |> lease()
      |> Map.put(:owner, "boot_b")
      |> Changeset.change()
      |> Changeset.unique_constraint(:node, name: node_constraint())

    {{:error, changeset}, issued} = statements(fn -> Arca.Repo.insert(duplicate) end)
    assert {"has already been taken", _meta} = changeset.errors[:node]

    if @sqlite? do
      assert ["begin", @quantum, @lock, _pool, insert, "rollback"] = issued
      assert insert =~ ~r/^INSERT INTO "cell_leases"/
    end

    # Unnamed, it raises as before, rolled back.
    assert_raise Ecto.ConstraintError, fn ->
      Arca.Repo.insert!(%{lease(node) | owner: "boot_c"})
    end

    assert [%CellLease{owner: "boot"}] = Arca.Repo.all(rows)
  end

  # ---- helpers ------------------------------------------------------------------

  @doc false
  # What `fun` returned, and the statements this process issued while it ran,
  # in order. `Arca.StandaloneWriteLockTest` reads them too.
  def statements(fun) do
    test = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test, do: send(test, {handler, meta.query})
        end,
        nil
      )

    try do
      result = fun.()
      {result, issued(handler, [])}
    after
      :telemetry.detach(handler)
    end
  end

  defp issued(handler, acc) do
    receive do
      {^handler, query} -> issued(handler, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # On SQLite the transaction of the one statement: the lock step, the
  # statement, the commit. On PostgreSQL the statement alone.
  defp assert_one_statement(issued, statement) do
    if @sqlite? do
      pool = pool_wait()
      assert ["begin", @quantum, @lock, ^pool, issued_statement, "commit"] = issued
      assert issued_statement =~ statement
    else
      assert [issued_statement] = issued
      assert issued_statement =~ statement
    end
  end

  defp pool_wait, do: "PRAGMA busy_timeout = #{Arca.Repo.busy_timeout_ms()}"

  # The name each adapter reports for a second row under one node.
  defp node_constraint, do: if(@sqlite?, do: "cell_leases_node_index", else: "cell_leases_pkey")

  defp lease(node) do
    now = DateTime.utc_now()

    %CellLease{
      node: node,
      owner: "boot",
      generation: 1,
      fence: 1,
      lease_until: now,
      taken_at: now
    }
  end

  defp entry(node) do
    now = DateTime.utc_now()

    %{
      node: node,
      owner: "boot",
      generation: 1,
      fence: 1,
      lease_until: now,
      taken_at: now,
      inserted_at: now,
      updated_at: now
    }
  end
end

defmodule Arca.StandaloneWriteLockTest do
  @moduledoc """
  A standalone write's wait for SQLite's write lock, outside the sandbox.

  A write run outside a transaction waits for the lock through the lock
  step, inside the driver a quantum at a time, so a burst of them waiting
  leaves a renewal that holds the lock free to step: one waiting for the
  whole busy timeout inside the driver would hold a dirty I/O scheduler
  throughout, and sixteen hold every one. It refuses as busy past the busy
  timeout, or past what its own pool timeout leaves. PostgreSQL has no such
  lock, so the file runs on SQLite only.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.Schemas.CellLease
  alias Ecto.Adapters.SQL.Sandbox
  alias Exqlite.Sqlite3

  if Arca.Repo.adapter() != Ecto.Adapters.SQLite3 do
    @moduletag skip: "SQLite's one write lock; PostgreSQL locks rows"
  end

  # A lock-wait deadline short enough to run out inside a case.
  @short_ms 300
  # Production's (`apps/arca/config/config.exs`), and a renewal's deadline.
  @busy_timeout_ms 5_000
  @writers 16
  @writer_pool :arca_standalone_writers
  @closing_pool :arca_standalone_closing
  @timeout_pool :arca_standalone_timeout
  # How long the write's statement steps, well past its pool timeout.
  @slow_ms 2_000
  # The renewal that stops once its lock step has taken the lock.
  @hold {__MODULE__, :hold}

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    node = "node-standalone-lock-#{System.unique_integer([:positive])}"
    config = Application.fetch_env!(:arca, Arca.Repo)

    on_exit(fn ->
      Application.put_env(:arca, Arca.Repo, config)

      unboxed(fn ->
        Arca.Repo.delete_all(from(l in CellLease, where: like(l.node, ^"#{node}%")))
      end)
    end)

    {:ok,
     node: node, config: config, rows: from(l in CellLease, where: like(l.node, ^"#{node}%"))}
  end

  test "a standalone write that cannot take the lock in time refuses as busy and writes nothing",
       %{node: node, config: config, rows: rows} do
    {:ok, row} = unboxed(fn -> Arca.Repo.insert(lease(node <> "-kept")) end)
    changed = Ecto.Changeset.change(row, fence: 2)
    pool = config[:busy_timeout]

    writes = [
      insert: fn -> Arca.Repo.insert(lease(node <> "-new")) end,
      insert!: fn -> Arca.Repo.insert!(lease(node <> "-new")) end,
      update: fn -> Arca.Repo.update(changed) end,
      update!: fn -> Arca.Repo.update!(changed) end,
      delete: fn -> Arca.Repo.delete(row) end,
      delete!: fn -> Arca.Repo.delete!(row) end,
      insert_or_update: fn -> Arca.Repo.insert_or_update(changed) end,
      insert_or_update!: fn -> Arca.Repo.insert_or_update!(changed) end,
      insert_all: fn -> Arca.Repo.insert_all(CellLease, [entry(node <> "-all")]) end,
      update_all: fn -> Arca.Repo.update_all(rows, set: [fence: 9]) end,
      delete_all: fn -> Arca.Repo.delete_all(rows) end
    ]

    raw = hold_lock!()
    Application.put_env(:arca, Arca.Repo, Keyword.put(config, :busy_timeout, @short_ms))

    try do
      unboxed(fn ->
        try do
          for {name, write} <- writes do
            started = System.monotonic_time(:millisecond)
            error = assert_raise Arca.Repo.BusyTimeoutError, write
            waited = System.monotonic_time(:millisecond) - started
            assert error.deadline_ms == @short_ms, "#{name} waited #{error.deadline_ms} ms"
            assert waited >= @short_ms, "#{name} refused after #{waited} ms"
          end
        after
          Arca.Repo.query!("PRAGMA busy_timeout = #{pool}")
        end
      end)
    after
      Application.put_env(:arca, Arca.Repo, config)
      release!(raw)
    end

    assert [%CellLease{fence: 1}] = unboxed(fn -> Arca.Repo.all(rows) end)
  end

  test "a write Ecto answers without a statement answers at once while the lock is held", %{
    node: node,
    config: config,
    rows: rows
  } do
    {:ok, row} = unboxed(fn -> Arca.Repo.insert(lease(node)) end)
    unchanged = Ecto.Changeset.change(row)
    pool = config[:busy_timeout]

    raw = hold_lock!()
    Application.put_env(:arca, Arca.Repo, Keyword.put(config, :busy_timeout, @short_ms))

    try do
      unboxed(fn ->
        try do
          # An update with nothing to change, as an update or as an
          # `insert_or_update` of loaded data, and an `insert_all` of no
          # entries: each answered as Ecto answers it, and no statement.
          for {name, write, answer} <- [
                {:update, fn -> Arca.Repo.update(unchanged) end, {:ok, row}},
                {:update!, fn -> Arca.Repo.update!(unchanged) end, row},
                {:insert_or_update, fn -> Arca.Repo.insert_or_update(unchanged) end, {:ok, row}},
                {:insert_or_update!, fn -> Arca.Repo.insert_or_update!(unchanged) end, row},
                {:insert_all, fn -> Arca.Repo.insert_all(CellLease, []) end, {0, nil}},
                {:insert_all_returning,
                 fn -> Arca.Repo.insert_all(CellLease, [], returning: true) end, {0, []}}
              ] do
            {answered, issued} = Arca.StandaloneWriteTest.statements(write)
            assert answered == answer, "#{name} answered #{inspect(answered)}"
            assert issued == [], "#{name} issued #{inspect(issued)}"
          end

          # Forced, the same update is a statement, and waits for the lock.
          assert_raise Arca.Repo.BusyTimeoutError, fn ->
            Arca.Repo.update(unchanged, force: true)
          end
        after
          Arca.Repo.query!("PRAGMA busy_timeout = #{pool}")
        end
      end)
    after
      Application.put_env(:arca, Arca.Repo, config)
      release!(raw)
    end

    assert [%CellLease{fence: 1}] = unboxed(fn -> Arca.Repo.all(rows) end)
  end

  describe "a caller's own timeout" do
    # A pool of its own, outside the sandbox, so the write's `timeout:` is
    # the pool's deadline for it, and the pool's disconnects are told to
    # the case.
    setup do
      start_supervised!(
        Supervisor.child_spec(
          {Arca.Repo,
           name: @timeout_pool,
           pool: DBConnection.ConnectionPool,
           pool_size: 1,
           connection_listeners: [self()]},
          id: @timeout_pool
        )
      )

      assert_receive {:connected, _conn}, 5_000
      :ok
    end

    test "a timeout of 500 ms or less still takes a free lock, and the write lands", %{
      node: node,
      rows: rows
    } do
      {:ok, _row} = unboxed(fn -> Arca.Repo.insert(lease(node)) end)

      for timeout <- [100, 400, 500] do
        assert {1, nil} =
                 on_pool(@timeout_pool, fn ->
                   Arca.Repo.update_all(rows, [set: [fence: timeout]], timeout: timeout)
                 end)

        assert [%CellLease{fence: ^timeout}] = unboxed(fn -> Arca.Repo.all(rows) end)
      end

      refute_received {:disconnected, _conn}
    end

    test "with the lock held it is refused within its timeout, before the pool acts", %{
      node: node,
      rows: rows
    } do
      {:ok, _row} = unboxed(fn -> Arca.Repo.insert(lease(node)) end)
      raw = hold_lock!()

      try do
        # The lock wait is what the timeout leaves once the commit's slack
        # is kept: half the timeout, or 500 ms past a timeout of a second.
        for {timeout, slack} <- [{400, 200}, {1_500, 500}] do
          started = System.monotonic_time(:millisecond)

          error =
            on_pool(@timeout_pool, fn ->
              assert_raise Arca.Repo.BusyTimeoutError, fn ->
                Arca.Repo.update_all(rows, [set: [fence: 9]], timeout: timeout)
              end
            end)

          waited = System.monotonic_time(:millisecond) - started
          assert error.deadline_ms in 1..(timeout - slack), "#{timeout}: #{error.deadline_ms}"
          assert waited >= error.deadline_ms and waited < timeout, "#{timeout}: #{waited} ms"
        end
      after
        release!(raw)
      end

      # Refused before the pool's deadline: the pool closed no connection.
      refute_received {:disconnected, _conn}
      assert [%CellLease{fence: 1}] = unboxed(fn -> Arca.Repo.all(rows) end)
    end

    test "however short the timeout, no lock attempt is still inside the driver when " <>
           "the pool acts",
         %{node: node, rows: rows} do
      # A connection the pool closes under a statement still waiting inside
      # the driver can crash the VM: each attempt's wait and pause are cut
      # to the time left, so the step answers busy before the pool's
      # deadline even when that deadline is shorter than one quantum.
      {:ok, _row} = unboxed(fn -> Arca.Repo.insert(lease(node)) end)
      raw = hold_lock!()

      try do
        for timeout <- [50, 100, 150], _round <- 1..5 do
          on_pool(@timeout_pool, fn ->
            assert_raise Arca.Repo.BusyTimeoutError, fn ->
              Arca.Repo.update_all(rows, [set: [fence: 9]], timeout: timeout)
            end
          end)
        end
      after
        release!(raw)
      end

      refute_received {:disconnected, _conn}
      assert [%CellLease{fence: 1}] = unboxed(fn -> Arca.Repo.all(rows) end)
    end
  end

  describe "a connection the pool closes under a write" do
    # The pool's deadline passes while the write's statement steps, so the
    # pool takes the connection back and closes it. The close is held until
    # the case lets it go, so the case decides whether the writer reads its
    # row count before the close or after it.
    setup do
      test = self()
      # Only the first close is held: the one the deadline causes.
      gate = :atomics.new(1, [])

      hold = fn _error, _state ->
        if :atomics.exchange(gate, 1, 1) == 0 do
          send(test, {:closing, self()})
          receive do: (:close -> :ok), after: (30_000 -> :ok)
        end
      end

      start_supervised!(
        Supervisor.child_spec(
          {Arca.Repo,
           name: @closing_pool,
           pool: DBConnection.ConnectionPool,
           pool_size: 1,
           connection_listeners: [test],
           before_disconnect: hold},
          id: @closing_pool
        )
      )

      assert_receive {:connected, conn}, 5_000
      {:ok, conn: conn}
    end

    @tag capture_log: true
    test "inside a caller's transaction a count read off the closed connection answers " <>
           "database_error, never a count",
         %{node: node, rows: rows, conn: conn} do
      {:ok, _row} = unboxed(fn -> Arca.Repo.insert(lease(node)) end)
      slow = slow(node)
      watch_counts!()

      writer =
        on_closing_pool(fn ->
          Arca.Repo.Errors.with_db_rescue("Arca.StandaloneWriteLockTest", fn ->
            Arca.Repo.locking_transaction(
              fn ->
                case Arca.Repo.update_all(slow, set: [fence: 2]) do
                  {1, _} -> :renewed
                  {0, _} -> :taken
                end
              end,
              timeout: 300
            )
          end)
        end)

      close_before_count!(writer, conn)

      assert {:error, :database_error} = Task.await(writer, 30_000)
      assert_received {:counted, nil}
      assert [%CellLease{fence: 1}] = unboxed(fn -> Arca.Repo.all(rows) end)
    end

    @tag capture_log: true
    test "a standalone write whose count is read off the closed connection raises it", %{
      node: node,
      rows: rows,
      conn: conn
    } do
      {:ok, _row} = unboxed(fn -> Arca.Repo.insert(lease(node)) end)
      slow = slow(node)
      watch_counts!()
      writer = standalone_update(slow)

      close_before_count!(writer, conn)

      assert {:raised, "connection closed"} = Task.await(writer, 30_000)
      assert_received {:counted, nil}
      assert [%CellLease{fence: 1}] = unboxed(fn -> Arca.Repo.all(rows) end)
    end

    @tag capture_log: true
    test "a standalone write whose count is read before the close raises it, uncommitted", %{
      node: node,
      rows: rows,
      conn: conn
    } do
      {:ok, _row} = unboxed(fn -> Arca.Repo.insert(lease(node)) end)
      slow = slow(node)
      watch_counts!()
      writer = standalone_update(slow)

      # The pool has taken the connection back, and the close waits: the
      # writer's statement ends and answers its count on the open
      # connection, and its commit finds the connection gone.
      assert_receive {:closing, ^conn}, 10_000
      assert {:raised, "connection closed"} = Task.await(writer, 30_000)
      assert_received {:counted, 1}

      send(conn, :close)
      assert_receive {:disconnected, ^conn}, 30_000
      assert [%CellLease{fence: 1}] = unboxed(fn -> Arca.Repo.all(rows) end)
    end
  end

  describe "beside the control plane's renewal" do
    setup %{config: config} do
      saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
      pool = Application.get_env(:arca, :control_plane_pool)
      turn = Application.get_env(:arca, :write_turn)

      on_exit(fn ->
        Application.put_env(:arca, :control_plane_pool, pool)
        Application.put_env(:arca, :write_turn, turn)

        for {key, value} <- saved do
          if value == :absent,
            do: :persistent_term.erase(key),
            else: :persistent_term.put(key, value)
        end
      end)

      # A deployment's lock-wait deadline, its control plane on a pool of
      # its own, its writers taking turns at the write lock, and sixteen
      # standalone writers on a pool of theirs.
      Application.put_env(:arca, Arca.Repo, Keyword.put(config, :busy_timeout, @busy_timeout_ms))
      Application.put_env(:arca, :control_plane_pool, true)
      Application.put_env(:arca, :write_turn, true)

      start_supervised!(
        ControlPlane.pool_spec(pool: DBConnection.ConnectionPool, busy_timeout: @busy_timeout_ms)
      )

      start_supervised!(
        Supervisor.child_spec(
          {Arca.Repo,
           name: @writer_pool,
           pool: DBConnection.ConnectionPool,
           pool_size: @writers,
           busy_timeout: @busy_timeout_ms},
          id: @writer_pool
        )
      )

      :ok
    end

    @tag timeout: 120_000
    test "a renewal holding the lock lands within its deadline while 16 standalone writers " <>
           "keep writing",
         %{node: node} do
      {:ok, _slot} = ControlPlane.take(node, "boot_a", 60_000)
      waiting = :ets.new(:standalone_waiting, [:public, :set])
      handler = {__MODULE__, :lock_steps}

      :ok =
        :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.lock_step/4, %{
          test: self(),
          waiting: waiting
        })

      on_exit(fn -> :telemetry.detach(handler) end)

      renewal =
        Task.async(fn ->
          Process.put(@hold, true)
          started = System.monotonic_time(:millisecond)
          answer = ControlPlane.renew(60_000)
          {answer, System.monotonic_time(:millisecond) - started}
        end)

      # The renewal holds the lock, and stops there until the burst waits
      # for it.
      assert_receive {:holding, renewer}, 5_000
      noise = node <> "-noise"

      writers =
        for _ <- 1..@writers do
          Task.async(fn ->
            Arca.Repo.put_dynamic_repo(@writer_pool)
            standalone_writes(noise, [])
          end)
        end

      # Every writer waits for that lock: its lock step was told busy.
      await(fn -> Enum.all?(writers, &:ets.member(waiting, &1.pid)) end)

      released = System.monotonic_time(:millisecond)
      send(renewer, :go)
      {answer, took} = Task.await(renewal, 60_000)
      landed = System.monotonic_time(:millisecond) - released

      for writer <- writers, do: send(writer.pid, :stop)
      writes = Enum.flat_map(writers, &Task.await(&1, 60_000))
      :telemetry.detach(handler)
      refused = for {:busy, ms} <- writes, do: ms

      IO.puts(
        "standalone burst: a renewal holding the lock landed #{landed} ms after #{@writers} " <>
          "standalone writers waited for it (#{took} ms in all, deadline #{@busy_timeout_ms} ms); " <>
          "#{length(writes)} writes, #{length(refused)} refused busy"
      )

      assert {:ok, _slot} = answer
      assert took < @busy_timeout_ms, "the renewal took #{took} ms"
      assert ControlPlane.held?()
    end
  end

  # `fun` in a task on the pool whose connection the case closes.
  defp on_closing_pool(fun) do
    Task.async(fn ->
      Arca.Repo.put_dynamic_repo(@closing_pool)
      fun.()
    end)
  end

  # What `fun` answers in a process of its own on `pool`.
  defp on_pool(pool, fun) do
    Task.async(fn ->
      Arca.Repo.put_dynamic_repo(pool)
      fun.()
    end)
    |> Task.await(30_000)
  end

  # The pool has taken the writer's connection back while its statement
  # steps, and holds the close. The writer, suspended, goes no further than
  # its statement; the close, let go, waits inside the driver for the
  # statement and then closes the connection; the writer, resumed once the
  # pool says so, reads its row count off the closed connection.
  defp close_before_count!(writer, conn) do
    assert_receive {:closing, ^conn}, 10_000
    true = :erlang.suspend_process(writer.pid)
    send(conn, :close)
    assert_receive {:disconnected, ^conn}, 30_000
    true = :erlang.resume_process(writer.pid)
  end

  # A standalone `update_all` of `query` on the pool whose connection the
  # case closes, whose own timeout leaves its lock step 300 ms of the 800
  # once the commit's slack is kept; the lock is free. What it raised.
  defp standalone_update(query) do
    on_closing_pool(fn ->
      try do
        Arca.Repo.update_all(query, [set: [fence: 2]], timeout: 800)
      rescue
        e in DBConnection.ConnectionError -> {:raised, e.message}
      end
    end)
  end

  # The row count each update of the case's rows answered, as
  # `{:counted, num_rows}` to the test, whichever process ran it.
  defp watch_counts! do
    test = self()
    handler = {__MODULE__, :counts}

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, %{query: query, result: result}, _config ->
          with true <- String.starts_with?(query, ~s(UPDATE "cell_leases")),
               {:ok, %{num_rows: num_rows}} <- result do
            send(test, {:counted, num_rows})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # The case's row, by a query that steps about `@slow_ms` before it
  # matches: a recursive count, sized by one measured on this machine.
  defp slow(node) do
    rows = rows_for(@slow_ms)

    from(l in CellLease,
      where:
        l.node == ^node and
          fragment(
            "(WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < ?) SELECT count(*) FROM c) > 0",
            ^rows
          )
    )
  end

  defp rows_for(ms) do
    {:ok, raw} = Sqlite3.open(Arca.Repo.config()[:database])

    {us, :ok} =
      :timer.tc(fn ->
        Sqlite3.execute(
          raw,
          "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 500000) " <>
            "SELECT count(*) FROM c"
        )
      end)

    :ok = Sqlite3.close(raw)
    max(div(ms * 500_000 * 1_000, max(us, 1)), 500_000)
  end

  @doc false
  # Each lock step's attempt, from any process: a busy answer marks its
  # process as waiting, and the renewal stops once its own attempt has taken
  # the lock, until the test lets it go on.
  def lock_step(_event, _measurements, %{query: query, result: result}, %{
        test: test,
        waiting: waiting
      }) do
    if String.ends_with?(query, "WHERE 0") do
      case result do
        {:ok, _taken} ->
          if Process.delete(@hold) do
            send(test, {:holding, self()})
            receive do: (:go -> :ok)
          end

        {:error, _busy} ->
          :ets.insert(waiting, {self()})
      end
    end
  end

  # Standalone writes until told to stop, each answered or refused busy,
  # with how long it took.
  defp standalone_writes(node, answered) do
    receive do
      :stop -> answered
    after
      0 ->
        started = System.monotonic_time(:millisecond)

        answer =
          try do
            Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node),
              set: [updated_at: DateTime.utc_now()]
            )

            :ok
          rescue
            _e in Arca.Repo.BusyTimeoutError ->
              {:busy, System.monotonic_time(:millisecond) - started}
          end

        standalone_writes(node, [answer | answered])
    end
  end

  defp await(fun, within_ms \\ 10_000),
    do: await_until(fun, System.monotonic_time(:millisecond) + within_ms)

  defp await_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the condition never held")

      true ->
        Process.sleep(1)
        await_until(fun, deadline)
    end
  end

  # The write lock, held by a connection outside every pool.
  defp hold_lock! do
    {:ok, raw} = Sqlite3.open(Arca.Repo.config()[:database])
    :ok = Sqlite3.execute(raw, "PRAGMA busy_timeout = 0")
    :ok = Sqlite3.execute(raw, "BEGIN IMMEDIATE")
    raw
  end

  defp release!(raw) do
    :ok = Sqlite3.execute(raw, "ROLLBACK")
    :ok = Sqlite3.close(raw)
  end

  defp lease(node) do
    now = DateTime.utc_now()

    %CellLease{
      node: node,
      owner: "boot",
      generation: 1,
      fence: 1,
      lease_until: now,
      taken_at: now
    }
  end

  defp entry(node) do
    now = DateTime.utc_now()

    %{
      node: node,
      owner: "boot",
      generation: 1,
      fence: 1,
      lease_until: now,
      taken_at: now,
      inserted_at: now,
      updated_at: now
    }
  end
end
