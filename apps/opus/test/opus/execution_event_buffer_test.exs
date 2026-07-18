# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionEventBufferTest do
  use ExUnit.Case, async: false

  alias Opus.ExecutionEventBuffer

  # Producers must route events under the execution's own tenant, not the
  # "local" sentinel — consumers (AQUA LiveView, SSE replay) subscribe and
  # replay with the record's coordinates, so a sentinel-published event is
  # invisible to any non-local org.

  test "record tenant coordinates route the broadcast and the replay buffer" do
    exec_id = "exec_evt_tenant_#{System.unique_integer([:positive])}"
    record = %{id: exec_id, org_id: "org_evt_x", project_id: "proj_y"}

    ExecutionEventBuffer.subscribe(exec_id, record)

    :ok = ExecutionEventBuffer.push_terminal(exec_id, "complete", %{status: "completed"}, 1, record)
    ExecutionEventBuffer.flush(exec_id)

    assert_receive {:execution_event, %{type: "complete", execution_id: ^exec_id}}

    # Replay under the record's org sees the event; the sentinel key must not.
    assert [%{type: "complete"}] = ExecutionEventBuffer.since(exec_id, 0, "org_evt_x")
    assert [] = ExecutionEventBuffer.since(exec_id, 0, nil)
  end

  test "a Sanctum.Context routes identically to record coordinates" do
    exec_id = "exec_evt_ctx_#{System.unique_integer([:positive])}"
    ctx = %Sanctum.Context{org_id: "org_evt_x", project_id: "proj_y"}
    record = %{id: exec_id, org_id: "org_evt_x", project_id: "proj_y"}

    ExecutionEventBuffer.subscribe(exec_id, ctx)

    :ok = ExecutionEventBuffer.push(exec_id, %{"kind" => "text_delta"}, 1, record)
    ExecutionEventBuffer.flush(exec_id)

    assert_receive {:execution_event, %{type: "emit", execution_id: ^exec_id}}
  end

  test "no coordinates falls back to the local sentinel on both sides" do
    exec_id = "exec_evt_local_#{System.unique_integer([:positive])}"

    ExecutionEventBuffer.subscribe(exec_id)

    :ok = ExecutionEventBuffer.push_terminal(exec_id, "error", %{error: "boom"}, 1)
    ExecutionEventBuffer.flush(exec_id)

    assert_receive {:execution_event, %{type: "error", execution_id: ^exec_id}}
    assert [%{type: "error"}] = ExecutionEventBuffer.since(exec_id, 0, nil)
  end
end
