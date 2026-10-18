# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.ExecutionEventsSlotReleaseTest do
  use CyfrWeb.ConnCase, async: false

  @moduletag auth: :person

  test "a completed execution stream releases its reservation while the HTTP process stays alive",
       %{
         conn: conn
       } do
    Cyfr.Test.Settings.put("opus_events_max_concurrent", 1)
    ctx = Sanctum.TestContext.local()

    {:ok, %{execution: execution}} =
      Arca.Execution.admit(
        %{
          id: Prima.UUID7.execution_id(),
          reference: "reagent:local.sse:0.1.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "reagent",
          origin: :programmatic
        },
        Cyfr.Test.AttemptFixtures.standing(ctx.athanor_id)
      )

    {:ok, _event} =
      Arca.ExecutionEvents.append(
        Prima.Actor.in_athanor(execution.athanor_id),
        execution.id,
        "execution.completed",
        data: %{"status" => "completed"}
      )

    path = "/api/executions/#{execution.id}/events"
    first = get(conn, path)
    assert first.status == 200
    assert first.resp_body =~ "execution.completed"

    # Both dispatches run in this still-live process, as HTTP/1 keep-alive
    # does. The completed first response must not fill the second's cap.
    second = first |> recycle() |> get(path)

    assert second.status == 200,
           "the completed first stream still holds its slot: " <> inspect(second.resp_body)

    assert second.resp_body =~ "execution.completed"
  end
end
