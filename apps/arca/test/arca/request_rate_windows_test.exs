# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RequestRateWindowsTest do
  @moduledoc """
  Pre-authentication limits: a fixed window per bucket and hashed key,
  counted on the database's clock and shared by every caller, admitting at
  most the cap; a claim at or past the cap answers from a read and writes
  nothing; only the platform's own actor claims, under a bucket spelled in
  code; and cleanup of spent windows is bounded.
  """

  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias Arca.RequestRateWindows
  alias Arca.Schemas.RequestRateWindow

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()
  defp key, do: "203.0.113.#{System.unique_integer([:positive])}"

  # Every statement this process runs from here on, as SQL text.
  defp watch_statements! do
    handler = "rrw-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == parent, do: send(parent, {:statement, meta[:query]})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp statements(acc \\ []) do
    receive do
      {:statement, sql} -> statements([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "admits up to the cap in a window, then refuses with the time left" do
    source = key()
    for _ <- 1..3, do: assert(:ok = RequestRateWindows.claim(server(), :pairing_source, source, 3, 60_000))

    assert {:error, {:rate_limited, retry_after}} =
             RequestRateWindows.claim(server(), :pairing_source, source, 3, 60_000)

    assert retry_after > 0 and retry_after <= 60_000

    # Another key, and another bucket, count on their own.
    assert :ok = RequestRateWindows.claim(server(), :pairing_source, key(), 3, 60_000)
    assert :ok = RequestRateWindows.claim(server(), :directory_source, source, 3, 60_000)
  end

  test "a flood past the cap answers from a read and writes nothing" do
    source = key()
    :ok = RequestRateWindows.claim(server(), :flood, source, 1, 60_000)
    watch_statements!()

    for _ <- 1..50 do
      assert {:error, {:rate_limited, _}} = RequestRateWindows.claim(server(), :flood, source, 1, 60_000)
    end

    written =
      Enum.filter(statements(), &(&1 =~ ~r/^\s*(INSERT|UPDATE|DELETE)/i))

    assert written == []
    assert [%{count: 1}] = Arca.Repo.all(from(w in RequestRateWindow, where: w.bucket == "flood"))
  end

  test "a window that ran out starts over, and a new width opens its own window" do
    source = key()
    :ok = RequestRateWindows.claim(server(), :rolling, source, 1, 60_000)
    assert {:error, _} = RequestRateWindows.claim(server(), :rolling, source, 1, 60_000)

    {1, _} =
      Arca.Repo.update_all(from(w in RequestRateWindow, where: w.bucket == "rolling"),
        set: [window_start: DateTime.add(DateTime.utc_now(), -61, :second)]
      )

    assert :ok = RequestRateWindows.claim(server(), :rolling, source, 1, 60_000)
    assert :ok = RequestRateWindows.claim(server(), :rolling, source, 1, 30_000)
  end

  test "the key is stored as its hash, never as given" do
    source = key()
    :ok = RequestRateWindows.claim(server(), :hashed, source, 2, 60_000)
    [row] = Arca.Repo.all(from(w in RequestRateWindow, where: w.bucket == "hashed"))
    assert row.key_hash == Prima.Digest.sha256(source)
    refute row.key_hash =~ source
  end

  test "cleanup of spent windows is bounded per claim" do
    long_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)

    rows =
      for n <- 1..20 do
        %{
          id: "rrw_old_#{n}_#{System.unique_integer([:positive])}",
          bucket: "sweep",
          key_hash: Prima.Digest.sha256("old-#{n}-#{System.unique_integer()}"),
          window_start: long_ago,
          window_ms: 60_000,
          count: 1,
          inserted_at: long_ago,
          updated_at: long_ago
        }
      end

    {20, _} = Arca.Repo.insert_all(RequestRateWindow, rows)
    :ok = RequestRateWindows.claim(server(), :sweep, key(), 5, 60_000)

    # The claim's own window, and the 4 spent ones beyond the batch of 16.
    assert Arca.Repo.aggregate(from(w in RequestRateWindow, where: w.bucket == "sweep"), :count) == 5
  end

  test "only the platform's own actor claims, under a bucket spelled in code" do
    assert {:error, :cross_tenant} =
             RequestRateWindows.claim(Prima.Actor.in_athanor("ath_test"), :b, key(), 1, 1_000)

    assert_raise FunctionClauseError, fn ->
      apply(RequestRateWindows, :claim, [server(), "from-a-request", key(), 1, 1_000])
    end

    assert_raise FunctionClauseError, fn ->
      apply(RequestRateWindows, :claim, [server(), :b, key(), 0, 1_000])
    end
  end
end

defmodule Arca.RequestRateWindowsRaceTest do
  @moduledoc """
  Two claims racing for the last place under a window's cap, on real
  connections outside the sandbox. Both pass the read a claim starts
  with; the count is taken by one conditional write, so the claim that
  waits for the other's write reads the window full and is refused, and
  the cap holds across members. On PostgreSQL the first claim is held with
  the window's row locked (a trigger waits on an advisory lock the test
  holds) and the second blocks on the same row; on SQLite both queue
  behind a transaction holding the write lock and run one after the other.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.RequestRateWindows
  alias Arca.Schemas.RequestRateWindow
  alias Ecto.Adapters.SQL.Sandbox

  @gate 7_310_005
  @cap 2

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  setup do
    source = "198.51.100.#{System.unique_integer([:positive])}"
    key_hash = Prima.Digest.sha256(source)

    on_exit(fn ->
      unboxed(fn -> Arca.Repo.delete_all(where(RequestRateWindow, key_hash: ^key_hash)) end)
    end)

    # One place left under the cap.
    :ok = unboxed(fn -> claim(source) end)
    {:ok, source: source, key_hash: key_hash}
  end

  # The connection's backend, on PostgreSQL, for the test to watch it wait.
  defp backend do
    if postgres?(), do: hd(hd(Arca.Repo.query!("SELECT pg_backend_pid()").rows))
  end

  # On PostgreSQL, `backend` is blocked on a lock, at the gate (`:gate`) or
  # in a statement naming every one of `fragments`.
  defp await_wait!(backend, at, tries \\ 250) do
    [[type, event, query]] =
      unboxed(fn ->
        Arca.Repo.query!(
          "SELECT wait_event_type, wait_event, query FROM pg_stat_activity WHERE pid = $1",
          [backend]
        ).rows
      end)

    waiting? =
      type == "Lock" and
        case at do
          :gate -> event == "advisory"
          fragments -> event != "advisory" and Enum.all?(fragments, &String.contains?(query, &1))
        end

    cond do
      waiting? -> :ok
      tries == 0 -> flunk("backend #{backend} is not waiting at #{inspect(at)}: #{type} #{event} #{query}")
      true -> retry_wait!(backend, at, tries)
    end
  end

  defp retry_wait!(backend, at, tries) do
    Process.sleep(20)
    await_wait!(backend, at, tries - 1)
  end

  # A trigger that holds a connection which set `arca_test.gate` before
  # `table`'s next `event` statement (`level` "STATEMENT") or at its next
  # row, once the row is locked (`level` "ROW"), until the test opens the
  # gate.
  defp install_gate!(table, event, level) do
    unboxed(fn ->
      Arca.Repo.query!("""
      CREATE OR REPLACE FUNCTION arca_test_gate() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF current_setting('arca_test.gate', true) = 'on' THEN
          PERFORM pg_advisory_lock(#{@gate});
          PERFORM pg_advisory_unlock(#{@gate});
        END IF;
        IF TG_LEVEL = 'ROW' THEN RETURN NEW; END IF;
        RETURN NULL;
      END $$
      """)

      Arca.Repo.query!(
        "CREATE TRIGGER arca_test_gate BEFORE #{event} ON #{table} " <>
          "FOR EACH #{level} EXECUTE FUNCTION arca_test_gate()"
      )
    end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.query!("DROP TRIGGER IF EXISTS arca_test_gate ON #{table}")
        Arca.Repo.query!("DROP FUNCTION IF EXISTS arca_test_gate()")
      end)
    end)
  end

  defp close_gate! do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.query!("SELECT pg_advisory_lock($1)", [@gate])
          send(test, :gate_closed)

          receive do
            :open -> Arca.Repo.query!("SELECT pg_advisory_unlock($1)", [@gate])
          end
        end)
      end)

    assert_receive :gate_closed, 5_000
    holder
  end

  defp open_gate!(holder) do
    send(holder.pid, :open)
    Task.await(holder)
  end

  defp gated(fun) do
    Arca.Repo.query!("SELECT set_config('arca_test.gate', 'on', false)")

    try do
      fun.()
    after
      Arca.Repo.query!("SELECT set_config('arca_test.gate', '', false)")
    end
  end

  # On SQLite, a transaction holding the one write lock until released, so
  # the writers started behind it queue at their transactions' entry.
  defp hold_write_lock! do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            send(test, :write_lock_held)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :write_lock_held, 5_000
    holder
  end

  defp release_write_lock!(holder) do
    send(holder.pid, :release)
    Task.await(holder)
  end

  defp claim(source), do: RequestRateWindows.claim(server(), :race, source, @cap, 60_000)

  defp claimant(source, gate?) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:claimant, backend()})
          if gate?, do: gated(fn -> claim(source) end), else: claim(source)
        end)
      end)

    assert_receive {:claimant, pid}, 5_000
    {task, pid}
  end

  test "two claims for the last place: the one that waits reads the window full", %{
    source: source,
    key_hash: key_hash
  } do
    results =
      if postgres?() do
        install_gate!("request_rate_windows", "UPDATE", "ROW")
        gate = close_gate!()
        {first, holding} = claimant(source, true)
        await_wait!(holding, :gate)

        {second, waiting} = claimant(source, false)
        await_wait!(waiting, [~s(UPDATE "request_rate_windows")])
        refute Task.yield(second, 300), "the second claim decided while the first held the window"

        open_gate!(gate)
        [Task.await(first, 25_000), Task.await(second, 25_000)]
      else
        holder = hold_write_lock!()
        {first, _} = claimant(source, false)
        {second, _} = claimant(source, false)
        refute Task.yield(first, 300)
        refute Task.yield(second, 300)

        release_write_lock!(holder)
        [Task.await(first, 25_000), Task.await(second, 25_000)]
      end

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:error, {:rate_limited, _}}, &1)) == 1

    assert [%{count: @cap}] =
             unboxed(fn -> Arca.Repo.all(where(RequestRateWindow, key_hash: ^key_hash)) end)
  end
end
