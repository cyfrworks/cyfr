# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.MCPTransportTest do
  @moduledoc """
  The transport shape of 2026-07-28: POST only, and a response that is either one
  JSON object or a stream the client asked for.
  """
  use EmissaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

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

    # Progress must reach the client while work runs. Phoenix.ConnTest uses
    # this process as the connection. The task supervisor is held while a
    # stand-in for the work publishes two steps on the request's topic the
    # connection subscribed to, so both are waiting when the pump starts —
    # progress that arrives before the task's result.
    test "progress reported during the call is written before the response", %{conn: conn} do
      conn_pid = self()
      :ok = :sys.suspend(Emissary.TaskSupervisor)
      on_exit(fn -> :sys.resume(Emissary.TaskSupervisor) end)
      spawn_link(fn -> publish_when_listening(conn_pid, [:one, :two]) end)

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
      assert first["method"] == "notifications/progress"
      assert first["params"]["phase"] == "one"
      assert first["params"]["progressToken"] == "tok-3"
      assert second["params"]["phase"] == "two"

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

  describe "subscriptions/listen holds its credential to its standing" do
    # The stream's own window, short: a case that leaves one open ends.
    setup do
      prev = Application.get_env(:cyfr, :mcp_subscription_max_ms)
      Application.put_env(:cyfr, :mcp_subscription_max_ms, 5_000)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:cyfr, :mcp_subscription_max_ms, prev),
          else: Application.delete_env(:cyfr, :mcp_subscription_max_ms)
      end)

      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.Session.create(ctx)
      {:ok, ctx: ctx, session: session}
    end

    defp open_listen(conn, token, id) do
      Task.async(fn ->
        started = System.monotonic_time(:millisecond)

        conn =
          conn
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> token)
          |> mcp_post(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "method" => "subscriptions/listen",
            "params" => %{"notifications" => %{"toolsListChanged" => true}}
          })

        {conn, System.monotonic_time(:millisecond) - started}
      end)
    end

    defp last_frame(conn) do
      conn.resp_body
      |> String.split("\n\n", trim: true)
      |> Enum.reject(&(&1 == ":"))
      |> List.last()
      |> String.replace_prefix("data: ", "")
      |> Jason.decode!()
    end

    test "a revocation announced for the caller ends the stream with its refusal", %{
      conn: conn,
      ctx: ctx,
      session: session
    } do
      task = open_listen(conn, session.token, 11)
      Process.sleep(300)

      {:ok, _} = Sanctum.Session.revoke_all_for_user(ctx.user_id)

      {conn, elapsed} = Task.await(task, 10_000)
      assert elapsed < 4_000
      assert %{"id" => 11, "error" => %{"code" => -33001}} = last_frame(conn)
    end

    test "a revocation nobody announced ends the stream at its periodic recheck", %{
      conn: conn,
      session: session
    } do
      task = open_listen(conn, session.token, 12)
      Process.sleep(300)

      hash = Sanctum.Session.token_hash(session.token)

      Arca.Repo.delete_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))

      # The recheck the stream arms for itself every thirty seconds, now.
      send(task.pid, CyfrWeb.ContextGuard.recheck_message())

      {conn, elapsed} = Task.await(task, 10_000)
      assert elapsed < 4_000
      assert %{"id" => 12, "error" => %{"code" => -33001}} = last_frame(conn)
    end

    test "a key-backed stream ends at its recheck once the key is revoked", %{
      conn: conn,
      ctx: ctx
    } do
      name = "listen-#{System.unique_integer([:positive])}"
      {:ok, %{api_key: raw}} = Sanctum.ApiKey.create(ctx, %{name: name, type: :service})

      task = open_listen(conn, raw, 14)
      Process.sleep(300)

      :ok = Sanctum.ApiKey.revoke(ctx, name)
      send(task.pid, CyfrWeb.ContextGuard.recheck_message())

      {conn, elapsed} = Task.await(task, 10_000)
      assert elapsed < 4_000
      assert %{"id" => 14, "error" => %{"code" => -33001}} = last_frame(conn)
    end

    test "a standing caller's recheck keeps the stream open to its end", %{
      conn: conn,
      session: session
    } do
      task = open_listen(conn, session.token, 13)
      Process.sleep(300)
      send(task.pid, CyfrWeb.ContextGuard.recheck_message())

      {conn, elapsed} = Task.await(task, 10_000)
      assert elapsed >= 4_000
      assert %{"id" => 13, "result" => %{"resultType" => "complete"}} = last_frame(conn)
    end
  end

  describe "the progress channel is request-scoped" do
    test "a listener is addressed by request id, not by session", %{conn: _conn} do
      :ok = Progress.listen("req_scoped", "tok")
      on_exit(fn -> Progress.forget("req_scoped") end)
      actor = Prima.Actor.in_athanor("ath_scoped")

      mine = Cyfr.Bus.Progress.new(actor, {:pull, "p"}, request_id: "req_scoped", phase: :x)
      theirs = Cyfr.Bus.Progress.new(actor, {:pull, "p"}, request_id: "req_other", phase: :x)

      assert {:ok, %{"method" => "notifications/progress"}} = Progress.notification(mine)
      assert Progress.notification(theirs) == :ignore
    end

    test "a streamed request leaves no subscription and no token behind", %{conn: conn} do
      conn_pid = self()
      :ok = :sys.suspend(Emissary.TaskSupervisor)
      on_exit(fn -> :sys.resume(Emissary.TaskSupervisor) end)
      spawn_link(fn -> publish_when_listening(conn_pid, [:only]) end)

      conn
      |> put_req_header("content-type", "application/json")
      |> mcp_post_with_meta(
        %{"jsonrpc" => "2.0", "id" => 10, "method" => "server/discover"},
        %{"progressToken" => "tok-done"}
      )

      refute Enum.any?(Registry.keys(Cyfr.PubSub, self()), &(&1 =~ ":progress:request:"))
      refute Enum.any?(Process.get_keys(), &match?({Emissary.MCP.Progress, _}, &1))

      # A step for the finished request, published now, reaches nobody here.
      refute_receive %Cyfr.Bus.Progress{}, 100
    end
  end

  # The work behind a streamed request, standing in for a tool: once the
  # connection `conn_pid` subscribed to its request's progress topic, the
  # steps named are published there, then the held task supervisor lets
  # the request's task start.
  defp publish_when_listening(conn_pid, phases, deadline \\ 200) do
    topic =
      conn_pid
      |> then(&Registry.keys(Cyfr.PubSub, &1))
      |> Enum.find(&(&1 =~ ":progress:request:"))

    cond do
      is_binary(topic) ->
        ["tenant", athanor_id, "progress", "request", request_id] = String.split(topic, ":")
        actor = Prima.Actor.in_athanor(athanor_id)

        for phase <- phases do
          step =
            Cyfr.Bus.Progress.new(actor, {:pull, "p"},
              request_id: request_id,
              phase: phase,
              message: "step"
            )

          :ok = Cyfr.Bus.broadcast_progress(actor, step)
        end

        :sys.resume(Emissary.TaskSupervisor)

      deadline > 0 ->
        Process.sleep(10)
        publish_when_listening(conn_pid, phases, deadline - 1)

      true ->
        :sys.resume(Emissary.TaskSupervisor)
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
