# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.McpListenSlotReleaseTest do
  use Emissary.Web.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  @moduletag auth: :person

  test "a listen refused by stream admission frees its slot before the next request", %{
    conn: conn
  } do
    Cyfr.Test.Settings.put("mcp_subscription_max_concurrent", 1)
    Cyfr.Test.Settings.put("mcp_subscription_max_ms", 50)

    # The suite's auth provider supplies an authenticated context whose
    # credential deadline has passed. The stream gate refuses that deadline
    # after the controller has reserved a slot; no global clock is changed.
    first =
      conn
      |> authenticate_as(credential_deadline: DateTime.add(DateTime.utc_now(), -60, :second))
      |> listen()

    assert first.status == 401
    assert first.assigns.context.authenticated
    assert [request_id] = get_resp_header(first, "x-request-id")

    assert [%{tool: "stream:mcp_servers.changes", admission: "refused"}] =
             Arca.Repo.all(
               from(d in Arca.Schemas.DecisionLog,
                 where: d.request_id == ^request_id,
                 select: %{tool: d.tool, admission: d.admission}
               )
             )

    # The new context is current, and the earlier refused request opened
    # no stream. Both dispatches use this same still-live HTTP process.
    second = first |> recycle() |> authenticate_as() |> listen()

    assert second.status == 200,
           "the refused listen kept its slot and blocked the next request: " <>
             inspect(second.resp_body)
  end

  defp listen(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> mcp_post(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "subscriptions/listen",
      "params" => %{"notifications" => %{"toolsListChanged" => true}}
    })
  end
end
