# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MCPTransportTest do
  @moduledoc """
  The transport shape of 2026-07-28: POST only, and a response that is either one
  JSON object or a stream the client asked for.
  """
  use EmissaryWeb.ConnCase, async: false

  alias Emissary.MCP.Progress
  alias Emissary.MCP.Subscriptions

  describe "verbs the previous transport defined" do
    # A 404 would read as "wrong URL" and send an older client looking for the
    # endpoint somewhere else. 405 says the endpoint is right and the verb is not.
    test "GET /mcp answers 405 with an Allow header", %{conn: conn} do
      conn = get(conn, "/mcp")

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST, OPTIONS"]
      assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "POST only"
    end

    test "DELETE /mcp answers 405", %{conn: conn} do
      assert delete(conn, "/mcp").status == 405
    end

    test "the answer still declares the protocol version", %{conn: conn} do
      assert get_resp_header(get(conn, "/mcp"), "mcp-protocol-version") ==
               [Emissary.MCP.Protocol.version()]
    end
  end

  describe "response mode" do
    test "without a progressToken the answer is one JSON object", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover"})

      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
      assert json_response(conn, 200)["result"]["resultType"] == "complete"
    end

    test "a progressToken opts into a stream", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post_with_meta(
          %{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover"},
          %{"progressToken" => "tok-1"}
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/event-stream"

      # Reverse proxies buffer by default, which would collapse a progress stream
      # into a single delivery at the end — the one thing the client asked to avoid.
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    end

    test "the stream carries the response as an SSE event", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post_with_meta(
          %{"jsonrpc" => "2.0", "id" => 7, "method" => "server/discover"},
          %{"progressToken" => "tok-2"}
        )

      assert ["data: " <> payload] = String.split(conn.resp_body, "\n\n", trim: true)
      decoded = Jason.decode!(payload)

      assert decoded["id"] == 7
      assert decoded["result"]["resultType"] == "complete"
    end

    # Progress reported while the work ran must arrive before the result, not
    # after it — a client reading in order would otherwise see the stream close
    # and drop whatever was still queued behind the response.
    #
    # `Phoenix.ConnTest` dispatches inline, so the test process *is* the
    # connection process. Seeding its mailbox before dispatch is exactly the
    # state the controller finds itself in when a handler reported progress from
    # its task while the request was still running.
    test "progress queued during the call is flushed ahead of the response", %{conn: conn} do
      send(self(), {:mcp_progress, %{"method" => "notifications/progress", "seq" => 1}})
      send(self(), {:mcp_progress, %{"method" => "notifications/progress", "seq" => 2}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post_with_meta(
          %{"jsonrpc" => "2.0", "id" => 9, "method" => "server/discover"},
          %{"progressToken" => "tok-3"}
        )

      events =
        conn.resp_body
        |> String.split("\n\n", trim: true)
        |> Enum.map(&(&1 |> String.replace_prefix("data: ", "") |> Jason.decode!()))

      assert [first, second, response] = events
      assert first["seq"] == 1
      assert second["seq"] == 2

      # Order is preserved and the response is last.
      assert response["id"] == 9
      assert response["result"]["resultType"] == "complete"
    end
  end

  describe "subscriptions/listen" do
    # The acknowledgment must come first and must carry the subscription id: on
    # stdio one channel multiplexes every subscription, so without it a client
    # cannot tell which stream a later notification belongs to.
    test "acknowledges first, with the subscription id", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 42,
          "method" => "subscriptions/listen",
          "params" => %{"notifications" => %{"toolsListChanged" => true}}
        })

      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/event-stream"

      first =
        conn.resp_body
        |> String.split("\n\n", trim: true)
        |> List.first()
        |> String.replace_prefix("data: ", "")
        |> Jason.decode!()

      assert first["method"] == "notifications/subscriptions/acknowledged"
      assert first["params"]["_meta"][Subscriptions.subscription_id_key()] == 42
      assert first["params"]["notifications"] == %{"toolsListChanged" => true}
    end

    test "the acknowledgment reports only what will actually be sent", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "subscriptions/listen",
          "params" => %{"notifications" => %{"resourcesListChanged" => true}}
        })

      first =
        conn.resp_body
        |> String.split("\n\n", trim: true)
        |> List.first()
        |> String.replace_prefix("data: ", "")
        |> Jason.decode!()

      # Requested, not honourable, so not acknowledged — the client learns
      # immediately rather than waiting on an event that cannot arrive.
      assert first["params"]["notifications"] == %{}
    end

    # A stream that simply stops is indistinguishable from a dropped connection.
    # Answering the original request says "this ended cleanly", which is what
    # tells a client to reconnect rather than to report a fault.
    test "ends by answering the original request, not by going silent",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post(%{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "subscriptions/listen",
          "params" => %{"notifications" => %{"toolsListChanged" => true}}
        })

      last =
        conn.resp_body
        |> String.split("\n\n", trim: true)
        |> Enum.reject(&(&1 == ":"))
        |> List.last()
        |> String.replace_prefix("data: ", "")
        |> Jason.decode!()

      assert last["id"] == 7
      assert last["result"]["resultType"] == "complete"
      assert last["result"]["_meta"][Subscriptions.subscription_id_key()] == 7
    end
  end

  describe "the progress channel is request-scoped" do
    test "a listener is addressed by request id, not by session", %{conn: _conn} do
      :ok = Progress.listen("req_scoped", "tok")

      %Sanctum.Context{} = base = Sanctum.TestContext.local()
      Progress.emit(%Sanctum.Context{base | request_id: "req_scoped"}, %{"phase" => "x"})

      assert_receive {:mcp_progress, %{"method" => "notifications/progress"}}
    end
  end

  # `mcp_post/2` builds a conforming `_meta`; this adds the client's optional
  # fields on top of it without duplicating the conformance rules.
  defp mcp_post_with_meta(conn, body, extra_meta) do
    params = Map.get(body, "params") || %{}

    meta =
      %{
        Emissary.MCP.Protocol.meta_protocol_version_key() => Emissary.MCP.Protocol.version(),
        Emissary.MCP.Protocol.meta_client_capabilities_key() => %{}
      }
      |> Map.merge(extra_meta)

    conn
    |> Plug.Conn.put_req_header("mcp-protocol-version", Emissary.MCP.Protocol.version())
    |> Plug.Conn.put_req_header("mcp-method", body["method"])
    |> Phoenix.ConnTest.dispatch(
      EmissaryWeb.Endpoint,
      :post,
      "/mcp",
      Map.put(body, "params", Map.put(params, "_meta", meta))
    )
  end
end
