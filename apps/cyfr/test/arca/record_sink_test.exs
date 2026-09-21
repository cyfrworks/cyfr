# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RecordSinkTest do
  # async: false — flips the sink out of inline mode for the duration.
  import Ecto.Query, only: [from: 2]

  use ExUnit.Case, async: false

  alias Arca.RecordSink

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    Application.put_env(:arca, :record_sink_inline, false)
    on_exit(fn -> Application.put_env(:arca, :record_sink_inline, true) end)
    :ok
  end

  defp policy_attrs(overrides) do
    Map.merge(
      %{
        id: Cyfr.UUID7.generate_id("plog"),
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
    ids = for _ <- 1..5, do: Cyfr.UUID7.generate_id("plog")
    for id <- ids, do: :ok = RecordSink.enqueue({:policy_log, policy_attrs(%{id: id})})

    # Nothing is written until the sink drains.
    :ok = RecordSink.flush()

    {:ok, rows} = Arca.PolicyLog.list(athanor_id: "ath_a", limit: 100)
    assert Enum.all?(ids, fn id -> Enum.any?(rows, &(&1.id == id)) end)
  end

  test "an invalid row is dropped without taking the batch with it" do
    good = Cyfr.UUID7.generate_id("plog")
    :ok = RecordSink.enqueue({:policy_log, policy_attrs(%{id: good})})
    :ok = RecordSink.enqueue({:policy_log, %{id: "plog_bad"}})
    :ok = RecordSink.flush()

    {:ok, rows} = Arca.PolicyLog.list(athanor_id: "ath_a", limit: 100)
    assert Enum.any?(rows, &(&1.id == good))
    refute Enum.any?(rows, &(&1.id == "plog_bad"))
  end

  test "an MCP log completion reaches the started row" do
    ctx = Sanctum.TestContext.local()
    call_id = Cyfr.UUID7.generate_id("call")

    :ok =
      Emissary.MCP.RequestLog.log_started(ctx, call_id, %{
        tool: "system",
        action: "status",
        input: %{}
      })

    :ok = Emissary.MCP.RequestLog.log_completed(ctx, call_id, %{duration_ms: 3, output: %{}})
    assert Arca.McpLog.get_tenant(Sanctum.Context.actor(ctx), call_id).status == "pending"

    :ok = RecordSink.flush()
    assert Arca.McpLog.get_tenant(Sanctum.Context.actor(ctx), call_id).status == "success"
  end

  test "vault touches are deduplicated into one update per entry" do
    {:ok, entry} =
      Arca.VaultStorage.put(%Cyfr.Actor{athanor_id: "ath_a"}, %{
        name: "sink-probe",
        kind: "api_key",
        status: "active",
        sealed_payload: <<4, 2, "k1", 0>>
      })

    actor = %Cyfr.Actor{athanor_id: "ath_a"}

    assert entry.last_used_at == nil
    for _ <- 1..3, do: :ok = Arca.VaultStorage.touch_last_used(actor, entry.id)
    :ok = RecordSink.flush()

    {:ok, touched} = Arca.VaultStorage.get(actor, entry.id)
    assert %DateTime{} = touched.last_used_at
  end

  test "inline mode writes in the caller" do
    Application.put_env(:arca, :record_sink_inline, true)
    id = Cyfr.UUID7.generate_id("plog")
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
    id = Cyfr.UUID7.generate_id("plog")
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

  describe "an in-process call's row" do
    defp started_row(id) do
      %{
        id: id,
        request_id: id,
        user_id: "usr_x",
        athanor_id: "ath_test",
        timestamp: DateTime.utc_now(),
        tool: "athanor",
        action: "get",
        method: "tools/call",
        status: "pending",
        input: "{}"
      }
    end

    test "a close that lands before its start, or without it, leaves one complete row" do
      id = "call_#{System.unique_integer([:positive])}"
      close = %{status: "success", duration_ms: 3, routed_to: "x", output: "{}"}

      Arca.RecordSink.enqueue({:mcp_log_close, started_row(id), close})
      :ok = Arca.RecordSink.flush()

      assert %{status: "success", duration_ms: 3, tool: "athanor"} =
               Arca.Repo.get(Arca.McpLog, id)

      # The start, shed or late, does not reopen the row.
      Arca.RecordSink.enqueue({:mcp_log_started, started_row(id)})
      :ok = Arca.RecordSink.flush()
      assert %{status: "success", duration_ms: 3} = Arca.Repo.get(Arca.McpLog, id)
      assert 1 == Arca.Repo.aggregate(from(l in Arca.McpLog, where: l.id == ^id), :count)
    end

    test "a start then its close, in one batch or two, is the same row" do
      id = "call_#{System.unique_integer([:positive])}"
      Arca.RecordSink.enqueue({:mcp_log_started, started_row(id)})

      Arca.RecordSink.enqueue(
        {:mcp_log_close, started_row(id), %{status: "error", error_code: -1, error: "no"}}
      )

      :ok = Arca.RecordSink.flush()
      assert %{status: "error", error_code: -1, error: "no"} = Arca.Repo.get(Arca.McpLog, id)
    end
  end
end
