# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.HeadlessTest do
  @moduledoc """
  A headless node keeps the API and MCP and shows no face: every browser
  route answers 404 while `/api`, `/mcp` and `/t` go on serving.
  """
  use EmissaryWeb.ConnCase, async: false

  setup do
    Application.put_env(:cyfr, :headless, true)
    on_exit(fn -> Application.delete_env(:cyfr, :headless) end)
    :ok
  end

  test "browser routes are gone; the machine surfaces stay", %{conn: conn} do
    for path <- [
          "/",
          "/login",
          "/a",
          "/auth/github",
          "/claim-namespace",
          "/legal/accept",
          # a chat attachment is a page surface too: its bytes are for a
          # member reading the thread in a browser
          "/a/home/attachments/msg_1/file.png"
        ] do
      resp = get(build_conn(), path)
      assert resp.status == 404, "#{path} answered #{resp.status} on a headless node"
      assert resp.resp_body =~ "headless"
    end

    assert get(build_conn(), "/api/health").status == 200

    mcp =
      conn
      |> put_req_header("content-type", "application/json")
      |> mcp_post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert json_response(mcp, 200)["result"]["tools"]

    # a public tincture URL reaches the tincture pipeline (a 404 for an
    # unknown tincture is the controller's answer, not the headless plug's)
    tincture = get(build_conn(), "/t/nobody/local/none")
    refute tincture.resp_body =~ "headless"
  end

  test "with the flag off nothing changes" do
    Application.delete_env(:cyfr, :headless)
    assert get(build_conn(), "/login").status == 200
  end
end
