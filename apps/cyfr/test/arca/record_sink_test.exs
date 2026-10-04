# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RecordSinkTest do
  # async: false — flips the sink out of inline mode for the duration.
  use ExUnit.Case, async: false

  alias Arca.RecordSink

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    Application.put_env(:arca, :record_sink_inline, false)
    on_exit(fn -> Application.put_env(:arca, :record_sink_inline, true) end)
    :ok
  end

  defp policy_attrs(overrides) do
    Map.merge(
      %{
        id: Prima.UUID7.generate_id("plog"),
        user_id: "u1",
        athanor_id: "ath_a",
        timestamp: DateTime.utc_now(),
        event_type: "allowed_probe",
        decision: "allowed",
        component_ref: "formula:local.x:1.0.0"
      },
      overrides
    )
  end

  test "queued rows land on flush, in one batch" do
    ids = for _ <- 1..5, do: Prima.UUID7.generate_id("plog")
    for id <- ids, do: :ok = RecordSink.enqueue({:policy_log, policy_attrs(%{id: id})})

    # Nothing is written until the sink drains.
    :ok = RecordSink.flush()

    {:ok, rows} = Arca.PolicyLog.list(athanor_id: "ath_a", limit: 100)
    assert Enum.all?(ids, fn id -> Enum.any?(rows, &(&1.id == id)) end)
  end

  test "an invalid row is dropped without taking the batch with it" do
    good = Prima.UUID7.generate_id("plog")
    :ok = RecordSink.enqueue({:policy_log, policy_attrs(%{id: good})})
    :ok = RecordSink.enqueue({:policy_log, %{id: "plog_bad"}})
    :ok = RecordSink.flush()

    {:ok, rows} = Arca.PolicyLog.list(athanor_id: "ath_a", limit: 100)
    assert Enum.any?(rows, &(&1.id == good))
    refute Enum.any?(rows, &(&1.id == "plog_bad"))
  end

  test "vault touches are deduplicated into one update per entry" do
    {:ok, entry} =
      Arca.VaultStorage.put(%Prima.Actor{athanor_id: "ath_a"}, %{
        name: "sink-probe",
        kind: "api_key",
        status: "active",
        sealed_payload: <<4, 2, "k1", 0>>,
        destination: ~s({"hosts":["fixture.test"],"scheme":"https"})
      })

    actor = %Prima.Actor{athanor_id: "ath_a"}

    assert entry.last_used_at == nil
    for _ <- 1..3, do: :ok = Arca.VaultStorage.touch_last_used(actor, entry.id)
    :ok = RecordSink.flush()

    {:ok, touched} = Arca.VaultStorage.get(actor, entry.id)
    assert %DateTime{} = touched.last_used_at
  end

  test "inline mode writes in the caller" do
    Application.put_env(:arca, :record_sink_inline, true)
    id = Prima.UUID7.generate_id("plog")
    :ok = RecordSink.enqueue({:policy_log, policy_attrs(%{id: id})})
    assert {:ok, sink_rows} = Arca.PolicyLog.list(athanor_id: "ath_a", limit: 100)
    assert Enum.any?(sink_rows, &(&1.id == id))
  end

  # The sink starts after the repo (`Cyfr.ApplicationTest` pins that), so
  # it stops before it and `terminate/2` writes what it still holds
  # through a pool that is still open. A row buffered at shutdown is not
  # lost; only casts left in the mailbox are, which is the write-behind's
  # stated cost.
  test "a row still buffered at shutdown is drained by terminate/2, not lost" do
    id = Prima.UUID7.generate_id("plog")
    pid = Process.whereis(Arca.RecordSink)

    :ok = RecordSink.flush()
    :ok = RecordSink.enqueue({:policy_log, policy_attrs(%{id: id})})

    # `:sys.get_state/1` is answered after the cast ahead of it, so the
    # row is in this process's buffer and no drain has run: what follows
    # is about terminate/2 and not about the flush timer.
    assert %{count: count} = :sys.get_state(pid)
    assert count >= 1
    {:ok, before} = Arca.PolicyLog.list(athanor_id: "ath_a", limit: 100)
    refute Enum.any?(before, &(&1.id == id))

    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    {:ok, rows} = Arca.PolicyLog.list(athanor_id: "ath_a", limit: 100)
    assert Enum.any?(rows, &(&1.id == id)), "the buffered row was lost at shutdown"

    assert Enum.any?(1..200, fn _ ->
             Process.sleep(25)
             is_pid(Process.whereis(Arca.RecordSink))
           end),
           "the record sink did not come back"
  end

  # The buffer is bounded by the batch size, but the mailbox is not: a drain
  # runs inside handle_cast, so a stalled database lets casts pile up behind
  # it with nothing pushing back. Bookkeeping must not be able to take the
  # node down, so past a ceiling the sink drops and says so.
  test "a backlogged sink sheds rather than growing without bound" do
    test_pid = self()

    :telemetry.attach(
      "record-sink-drop-test",
      [:cyfr, :record_sink, :dropped],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:dropped, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("record-sink-drop-test") end)

    # Block the sink so its mailbox is the only thing that grows, then fill
    # past the ceiling. `:sys.suspend/1` stops it processing without killing
    # it, which is what a slow transaction looks like from outside.
    pid = Process.whereis(Arca.RecordSink)
    :sys.suspend(pid)

    for _ <- 1..10_050 do
      RecordSink.enqueue({:policy_log, policy_attrs(%{})})
    end

    assert_receive {:dropped, %{count: 1}, %{kind: :policy_log}}, 5_000

    {:message_queue_len, len} = Process.info(pid, :message_queue_len)

    assert len <= 10_051,
           "the sink queued #{len} messages — shedding did not bound the mailbox"

    # Discard the backlog rather than resuming into ten thousand real writes:
    # this is the shared singleton, and draining them would land another
    # test's assertions in the middle of this one's flood. A kill skips
    # terminate/2 (and its flush), and the supervisor brings back an empty one.
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    assert Enum.any?(1..200, fn _ ->
             Process.sleep(25)
             is_pid(Process.whereis(Arca.RecordSink))
           end),
           "the record sink did not come back"
  end
end

defmodule Arca.RecordSinkRevisionRaceTest do
  @moduledoc """
  A batch of last-used touches and a consent revision binding the same
  entries, on connections of their own: inside the sandbox one shared
  connection would serialize the two. The batch updates the rows in the
  order the revision holds them in, so neither waits on the other in a
  cycle and both land. The case works in an athanor of its own, purged
  when it ends.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arca.ConsentStorage
  alias Arca.RecordSink
  alias Ecto.Adapters.SQL.Sandbox

  @ingress "reagent:local.sink-race|@ingress|default"
  @named "reagent:local.sink-race|@ingress|name:second"

  setup do
    athanor = "ath_sink_race_#{System.unique_integer([:positive])}"
    on_exit(fn -> unboxed(fn -> Arca.TenantTables.delete_all_for(actor(athanor)) end) end)
    {:ok, athanor: athanor}
  end

  # Holds the batch inside its transaction once it has updated its first
  # entry, in the process that marked itself the batch. Runs once.
  def hold_batch(_event, _measurements, meta, %{test: test}) do
    if Process.get(:sink_batch) == true and meta[:source] == "vault_entries" and
         String.starts_with?(meta[:query] || "", "UPDATE") do
      Process.delete(:sink_batch)
      send(test, {:holding, self()})

      receive do
        :go -> :ok
      end
    end
  end

  test "a batch touching two entries and a revision binding both land, whatever order the " <>
         "touches arrived in",
       %{athanor: athanor} do
    {low, high, profile} =
      unboxed(fn ->
        [low, high] = Enum.sort([entry!(athanor), entry!(athanor)])

        profile = "prof_sink_race_#{System.unique_integer([:positive])}"

        {:ok, _} =
          Arca.ProfileStorage.put(%{
            id: profile,
            athanor_id: athanor,
            source_ref: "reagent:local.sink-race",
            kind: "owner",
            label: "default",
            status: "active"
          })

        {low, high, profile}
      end)

    handler = {__MODULE__, :hold_batch, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.hold_batch/4, %{
        test: self()
      })

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      capture_log(fn ->
        # The touches arrive the higher id first.
        batch =
          Task.async(fn ->
            Process.put(:sink_batch, true)

            unboxed(fn ->
              RecordSink.write([{:vault_touch, athanor, high}, {:vault_touch, athanor, low}])
            end)
          end)

        assert_receive {:holding, holder}, 15_000

        test = self()

        revision =
          Task.async(fn ->
            unboxed(fn ->
              if postgres?(), do: send(test, {:backend, backend_pid()})

              ConsentStorage.insert_revision(
                attrs(athanor, profile),
                [ref(@ingress, low), ref(@named, high)],
                nil
              )
            end)
          end)

        # The batch holds a row the revision locks: the revision waits on it.
        if postgres?() do
          assert_receive {:backend, backend}, 15_000
          await_lock_wait(backend)
        else
          refute Task.yield(revision, 300), "the revision did not wait for the batch"
        end

        send(holder, :go)
        assert :ok = Task.await(batch, 30_000)
        assert {:ok, _consent} = Task.await(revision, 30_000)
      end)

    :telemetry.detach(handler)
    refute log =~ "deadlock"
    refute log =~ "batch rolled back"

    touched =
      unboxed(fn ->
        for id <- [low, high] do
          {:ok, entry} = Arca.VaultStorage.get(actor(athanor), id)
          entry.last_used_at
        end
      end)

    assert Enum.all?(touched, &match?(%DateTime{}, &1))
  end

  defp entry!(athanor) do
    {:ok, entry} =
      Arca.VaultStorage.put(actor(athanor), %{
        name: "sink-race-#{System.unique_integer([:positive])}",
        kind: "api_key",
        sealed_payload: "sealed",
        destination: ~s({"hosts":["api.example.com"],"scheme":"https"})
      })

    entry.id
  end

  defp ref(key, entry_id) do
    %{binding_key: key, scope: "athanor", vault_entry_id: entry_id, binding_digest: "sha256:b"}
  end

  defp attrs(athanor, profile) do
    %{
      athanor_id: athanor,
      profile_id: profile,
      revision: 1,
      scope: "versionless",
      pinned_version: "",
      invoke_mode: "open_inert",
      shape_digest: "sha256:shape",
      commit_digest: "sha256:commit",
      blob_digest: Prima.JCS.hash_binary("{}"),
      resolved_policy: "{}",
      activation: "{}",
      admitted_origins: [:interactive],
      granted_by: "test",
      granted_via: "bootstrap"
    }
  end

  # The backend of the current connection, so another can watch it wait.
  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # Holds until `pid`'s backend waits on a lock: an observed state, bounded
  # by `tries`, never a timing. Only PostgreSQL shows one; SQLite's
  # immediate transaction waits for the one writer and has none to show.
  defp await_lock_wait(pid, tries \\ 500)

  defp await_lock_wait(_pid, 0), do: flunk("the waiting backend never waited on a lock")

  defp await_lock_wait(pid, tries) do
    %{rows: rows} =
      unboxed(fn ->
        Arca.Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid])
      end)

    if rows == [["Lock"]] do
      :ok
    else
      Process.sleep(20)
      await_lock_wait(pid, tries - 1)
    end
  end

  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  defp actor(athanor), do: Prima.Actor.in_athanor(athanor)
  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end
