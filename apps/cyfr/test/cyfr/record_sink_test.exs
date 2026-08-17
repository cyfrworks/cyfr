# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RecordSinkTest do
  # async: false — flips the sink out of inline mode for the duration.
  use ExUnit.Case, async: false

  alias Cyfr.RecordSink

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    Application.put_env(:cyfr, :record_sink_inline, false)
    on_exit(fn -> Application.put_env(:cyfr, :record_sink_inline, true) end)
    :ok
  end

  defp policy_attrs(overrides) do
    Map.merge(
      %{
        id: Emissary.UUID7.generate_id("plog"),
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
    ids = for _ <- 1..5, do: Emissary.UUID7.generate_id("plog")
    for id <- ids, do: :ok = RecordSink.enqueue({:policy_log, policy_attrs(%{id: id})})

    # Nothing is written until the sink drains.
    :ok = RecordSink.flush()

    rows = Arca.PolicyLog.list(athanor_id: "ath_a", limit: 100)
    assert Enum.all?(ids, fn id -> Enum.any?(rows, &(&1.id == id)) end)
  end

  test "an invalid row is dropped without taking the batch with it" do
    good = Emissary.UUID7.generate_id("plog")
    :ok = RecordSink.enqueue({:policy_log, policy_attrs(%{id: good})})
    :ok = RecordSink.enqueue({:policy_log, %{id: "plog_bad"}})
    :ok = RecordSink.flush()

    rows = Arca.PolicyLog.list(athanor_id: "ath_a", limit: 100)
    assert Enum.any?(rows, &(&1.id == good))
    refute Enum.any?(rows, &(&1.id == "plog_bad"))
  end

  test "an MCP log completion reaches the started row" do
    ctx = Sanctum.TestContext.local()
    call_id = Emissary.UUID7.generate_id("call")

    :ok =
      Emissary.MCP.RequestLog.log_started(ctx, call_id, %{
        tool: "system",
        action: "status",
        input: %{}
      })

    :ok = Emissary.MCP.RequestLog.log_completed(ctx, call_id, %{duration_ms: 3, output: %{}})
    assert Arca.McpLog.get_tenant(ctx, call_id).status == "pending"

    :ok = RecordSink.flush()
    assert Arca.McpLog.get_tenant(ctx, call_id).status == "success"
  end

  test "vault touches are deduplicated into one update per entry" do
    {:ok, entry} =
      Arca.VaultStorage.put(%{
        athanor_id: "ath_a",
        name: "sink-probe",
        kind: "api_key",
        status: "active",
        sealed_payload: <<4, 2, "k1", 0>>
      })

    assert entry.last_used_at == nil
    for _ <- 1..3, do: :ok = Arca.VaultStorage.touch_last_used("ath_a", entry.id)
    :ok = RecordSink.flush()

    {:ok, touched} = Arca.VaultStorage.get("ath_a", entry.id)
    assert %DateTime{} = touched.last_used_at
  end

  test "inline mode writes in the caller" do
    Application.put_env(:cyfr, :record_sink_inline, true)
    id = Emissary.UUID7.generate_id("plog")
    :ok = RecordSink.enqueue({:policy_log, policy_attrs(%{id: id})})
    assert Enum.any?(Arca.PolicyLog.list(athanor_id: "ath_a", limit: 100), &(&1.id == id))
  end
end
