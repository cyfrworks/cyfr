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
    on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)

    # The lease can be lost after the endpoint's ownership check. Separate
    # authentication from controller dispatch to put that loss between them.
    authenticated =
      conn
      |> CyfrWeb.Plugs.CallIdentity.call([])
      |> CyfrWeb.Plugs.ControlPlaneOwnership.call([])
      |> CyfrWeb.Plugs.Authenticate.call(
        CyfrWeb.Plugs.Authenticate.init(errors: Emissary.Web.MCPError)
      )

    refute authenticated.halted
    assert authenticated.assigns.context.authenticated
    assert is_binary(authenticated.assigns.context.session_token_hash)

    Arca.ControlPlane.record(:lost)
    first = Emissary.Web.MCPController.handle(authenticated, message())

    assert first.status == 400

    assert json_response(first, 400)["error"]["code"] ==
             Prima.MCP.Message.error_code(:not_owner)

    assert [request_id] = get_resp_header(first, "x-request-id")

    assert [%{tool: "stream:mcp_servers.changes", admission: "refused"}] =
             Arca.Repo.all(
               from(d in Arca.Schemas.DecisionLog,
                 where: d.request_id == ^request_id,
                 select: %{tool: d.tool, admission: d.admission}
               )
             )

    Arca.ControlPlane.record(:unclaimed)

    # Keep both the credential and the HTTP process, which own the slot.
    second = first |> recycle() |> mcp_post(message())

    assert second.status == 200,
           "the refused listen kept its slot and blocked the next request: " <>
             inspect(second.resp_body)
  end

  defp message do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "subscriptions/listen",
      "params" => %{"notifications" => %{"toolsListChanged" => true}}
    }
  end
end
