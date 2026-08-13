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

    # A `progressToken` is an opt-in to *receiving* progress, not a demand for a
    # stream. Opening one commits `200`, and the choice of body shape is the
    # server's — so a call that reports nothing is answered the cheap way.
    test "a progressToken alone does not open a stream", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post_with_meta(
          %{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover"},
          %{"progressToken" => "tok-1"}
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
      assert json_response(conn, 200)["result"]["resultType"] == "complete"
    end

    # This is the reason the stream is opened on first progress rather than up
    # front. Committing `200` before dispatch would make every status-bearing
    # rejection unreachable, and this revision leans on those: an unimplemented
    # method MUST answer 404, and a dual-era client reads the status to tell a
    # modern server from a legacy one.
    test "an unimplemented method still answers 404 when progress was requested",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post_with_meta(
          %{"jsonrpc" => "2.0", "id" => 3, "method" => "no/such/method"},
          %{"progressToken" => "tok-404"}
        )

      assert conn.status == 404
      assert json_response(conn, 404)["error"]["code"] == -32_601
    end

    # Progress must reach the client *while* the work runs. It used to be
    # delivered by draining the mailbox after the handler had already returned,
    # which turned a progress stream into one burst at the end — and left
    # nothing open for a client to close, so cancellation had no signal.
    #
    # `Phoenix.ConnTest` dispatches inline, so the test process is the
    # connection process; the handler runs in a task and reports back to it.
    # Seeding the mailbox before dispatch is exactly the state the pump finds
    # when a handler reports progress before the result is ready.
    test "progress reported during the call is written before the response", %{conn: conn} do
      send(self(), {:mcp_progress, %{"method" => "notifications/progress", "seq" => 1}})
      send(self(), {:mcp_progress, %{"method" => "notifications/progress", "seq" => 2}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> mcp_post_with_meta(
          %{"jsonrpc" => "2.0", "id" => 9, "method" => "server/discover"},
          %{"progressToken" => "tok-3"}
        )

      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/event-stream"

      # Reverse proxies buffer by default, which would collapse a progress stream
      # into a single delivery at the end — the one thing the client asked to avoid.
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]

      events =
        conn.resp_body
        |> String.split("\n\n", trim: true)
        |> Enum.map(&(&1 |> String.replace_prefix("data: ", "") |> Jason.decode!()))

      assert [first, second, response] = events
      assert first["seq"] == 1
      assert second["seq"] == 2

      # Order is preserved and the response is the stream's last frame.
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
