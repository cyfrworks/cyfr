# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.ExecutionEventsStreamTest do
  use EmissaryWeb.ConnCase, async: false

  alias EmissaryWeb.ExecutionEventsController
  alias Cyfr.Execution.Events

  setup %{conn: conn} do
    ctx = Sanctum.TestContext.local()

    {:ok, %{execution: execution}} =
      Arca.Execution.admit(%{
        id: Cyfr.UUID7.execution_id(),
        reference: "reagent:local.sse:0.1.0",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        component_type: "reagent"
      })

    # The stream's own deadline, short: a test that leaves it open ends.
    prev = Application.get_env(:cyfr, :execution_events_max_ms)
    Application.put_env(:cyfr, :execution_events_max_ms, 3_000)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :execution_events_max_ms, prev),
        else: Application.delete_env(:cyfr, :execution_events_max_ms)
    end)

    {:ok, conn: conn, ctx: ctx, exec: execution}
  end

  defp durable!(exec, type, data \\ %{}) do
    {:ok, row} = Arca.ExecutionEvents.append(exec.athanor_id, exec.id, type, data: data)
    row.seq
  end

  defp publish!(exec, type, seq, data \\ %{}),
    do: :ok = Events.publish(exec.id, exec, type, seq, data)

  defp ids(body) do
    ~r/^id: (\S+)$/m |> Regex.scan(body) |> Enum.map(fn [_, id] -> id end)
  end

  defp stream(conn, exec, headers \\ []) do
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    get(conn, "/api/executions/#{exec.id}/events")
  end

  test "the cursor is <durable> or <durable>.<n>" do
    assert ExecutionEventsController.parse_cursor("40") == {40, 0}
    assert ExecutionEventsController.parse_cursor("40.10") == {40, 10}
    assert ExecutionEventsController.parse_cursor("junk") == {0, 0}
    assert ExecutionEventsController.parse_cursor("-1.2") == {0, 2}
  end

  test "replay is the rows in order, each with its deltas, and Last-Event-ID resumes from either",
       %{conn: conn, exec: exec} do
    # 1 is execution.started (admission). Deltas under it, a step row, a
    # delta under that, the end.
    {:ok, "1.1"} = Events.push(exec.id, %{"i" => 1}, exec)
    two = durable!(exec, "step.closed", %{"step" => "s"})
    publish!(exec, "step.closed", two)
    {:ok, "2.1"} = Events.push(exec.id, %{"i" => 2}, exec)
    three = durable!(exec, "execution.completed", %{"status" => "completed"})
    publish!(exec, "execution.completed", three)
    assert {two, three} == {2, 3}

    body = stream(conn, exec).resp_body
    assert ids(body) == ["1", "1.1", "2", "2.1", "3"]
    assert body =~ "event: execution.completed"

    # A client at 2 wants the deltas under 2 and on; one at 2.1, what follows.
    assert ids(stream(conn, exec, [{"last-event-id", "2"}]).resp_body) == ["2.1", "3"]
    assert ids(stream(conn, exec, [{"last-event-id", "2.1"}]).resp_body) == ["3"]
    assert ids(stream(conn, exec, [{"last-event-id", "3"}]).resp_body) == []
  end

  test "publication out of order is delivered in order: a row overtaken by a later one is not skipped",
       %{conn: conn, exec: exec} do
    # The client connects live; writer A commits row 2 and stalls before
    # publishing; writer B commits row 3 (terminal) and publishes it. The
    # client receives 2 before 3.
    task = Task.async(fn -> stream(conn, exec).resp_body end)
    Process.sleep(300)

    two = durable!(exec, "step.closed", %{"step" => "a"})
    three = durable!(exec, "execution.completed", %{"status" => "completed"})
    publish!(exec, "execution.completed", three)

    body = Task.await(task, 10_000)
    assert ids(body) == ["1", "2", "3"]
    assert {two, three} == {2, 3}
  end

  test "live deltas and rows that follow the cursor go straight out, in order", %{
    conn: conn,
    exec: exec
  } do
    task = Task.async(fn -> stream(conn, exec).resp_body end)
    Process.sleep(300)

    {:ok, "1.1"} = Events.push(exec.id, %{"i" => 1}, exec)
    two = durable!(exec, "step.closed", %{"step" => "a"})
    publish!(exec, "step.closed", two)
    {:ok, "2.1"} = Events.push(exec.id, %{"i" => 2}, exec)
    three = durable!(exec, "execution.failed", %{"status" => "failed"})
    publish!(exec, "execution.failed", three)

    body = Task.await(task, 10_000)
    assert ids(body) == ["1", "1.1", "2", "2.1", "3"]
    assert body =~ "event: execution.failed"
  end
end
