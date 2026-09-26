# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SSETest do
  @moduledoc """
  The endpoint's delivery owner (`CyfrWeb.SSE.deliver/4`): it subscribes
  to the one topic a grant admits and delivers each payload projected to
  the grant's fields as one event of the wire's stream, and closes at the
  grant's deadline, on a standing announcement about its caller whose
  revalidation refuses, on a revalidation its timer finds refused, and on
  overflow with a typed refusal event — never silently. The frame's
  stream slots are counted per frame credential and released on close.
  """

  # Reads and writes platform settings and the stream slot registry.
  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias CyfrWeb.SSE
  alias Prima.{StreamGrant, TinctureWire}
  alias Sanctum.Context

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    athanor = "ath_sse_#{System.unique_integer([:positive])}"

    ctx =
      Context.build(
        user_id: "usr_sse",
        athanor_id: athanor,
        scope: :athanor,
        auth_method: :tincture,
        authenticated: true,
        validated_at: DateTime.utc_now(),
        frame: frame("frc_#{System.unique_integer([:positive])}")
      )

    {:ok, ctx: ctx, actor: Context.actor(ctx)}
  end

  defp frame(id) do
    %{
      id: id,
      frame_id: "frm_sse_#{id}",
      reference: %{publisher: "local", name: "dash", version: "1.0.0"},
      version_digest: "sha256:" <> String.duplicate("a", 64),
      grant_revision: 0
    }
  end

  defp grant(deadline_ms) do
    %StreamGrant{
      topic: :mcp_servers,
      projection: ["kind"],
      subject: nil,
      deadline: DateTime.add(DateTime.utc_now(), deadline_ms, :millisecond),
      grant_id: "sgr_sse"
    }
  end

  defp standing(ctx), do: fn -> {:ok, %{ctx | validated_at: DateTime.utc_now()}} end

  # Deliver in a process of its own, as a connection does; answers the
  # task and the topic it subscribes to.
  defp delivering(ctx, grant, opts) do
    parent = self()

    task =
      Task.async(fn ->
        conn = Plug.Test.conn(:post, "/_f/v1/stream")
        send(parent, {:delivering, self()})
        SSE.deliver(conn, ctx, grant, Keyword.merge([name: "mcp_servers.changes"], opts))
      end)

    assert_receive {:delivering, pid}
    topic = Cyfr.Bus.granted_topic(Context.actor(ctx), grant)
    wait_until(fn -> pid in subscribers(topic) end)
    {task, pid}
  end

  defp subscribers(topic), do: Registry.lookup(Cyfr.PubSub, topic) |> Enum.map(&elem(&1, 0))

  defp changed(actor), do: Cyfr.Bus.McpServers.new(actor, :changed)

  defp events(conn), do: TinctureWire.decode_stream(conn.resp_body)

  test "delivers each payload projected to the grant, under the stream's name, until the deadline",
       %{ctx: ctx, actor: actor} do
    {task, pid} = delivering(ctx, grant(400), revalidate: standing(ctx))

    :ok = Cyfr.Bus.broadcast(actor, Cyfr.Bus.mcp_servers(actor), changed(actor))
    # Another topic's payload in the connection's mailbox is not the stream's.
    send(pid, %Cyfr.Bus.Tinctures{athanor_id: actor.athanor_id, kind: :changed})

    conn = Task.await(task)
    assert conn.state == :chunked
    assert Plug.Conn.get_resp_header(conn, "content-type") == [TinctureWire.stream_content_type()]

    assert events(conn) == [
             %{id: nil, event: "mcp_servers.changes", data: %{"kind" => "changed"}}
           ]

    # Closed: nothing subscribed remains.
    assert subscribers(Cyfr.Bus.granted_topic(actor, grant(0))) == []
  end

  test "another athanor's payload never reaches the stream", %{ctx: ctx, actor: actor} do
    {task, _pid} = delivering(ctx, grant(300), revalidate: standing(ctx))
    other = Prima.Actor.in_athanor("ath_sse_other_#{System.unique_integer([:positive])}")
    :ok = Cyfr.Bus.broadcast(other, Cyfr.Bus.mcp_servers(other), changed(other))
    assert events(Task.await(task)) == []
    _ = actor
  end

  test "a context its timer finds refused closes the stream with that refusal", %{ctx: ctx} do
    stale = %{ctx | validated_at: DateTime.add(DateTime.utc_now(), -60, :second)}

    refusal = %Prima.Refusal{
      class: :forbidden,
      reason: :frame_suspended,
      message: "This frame is suspended"
    }

    {task, _pid} =
      delivering(stale, grant(60_000),
        revalidate: fn -> {:error, refusal} end,
        revalidate_every: 20
      )

    conn = Task.await(task, 5_000)

    assert [%{event: "refusal", data: %{"class" => "forbidden", "stage" => "execution"}}] =
             events(conn)
  end

  test "a standing announcement about the caller revalidates at once", %{ctx: ctx} do
    parent = self()

    revalidate = fn ->
      send(parent, :revalidated)
      {:error, Prima.Refusal.classify(:revoked)}
    end

    {task, _pid} = delivering(ctx, grant(60_000), revalidate: revalidate)

    # About someone else: ignored.
    Phoenix.PubSub.broadcast(
      Cyfr.PubSub,
      Cyfr.Bus.sessions(),
      %Cyfr.Bus.Session{kind: :revoked, user_id: "usr_someone_else"}
    )

    refute_receive :revalidated, 100

    Phoenix.PubSub.broadcast(
      Cyfr.PubSub,
      Cyfr.Bus.sessions(),
      %Cyfr.Bus.Session{kind: :revoked, user_id: ctx.user_id}
    )

    assert_receive :revalidated
    assert [%{event: "refusal", data: %{"class" => "unauthenticated"}}] = events(Task.await(task))
  end

  test "a stream that falls behind ends with the typed overflow refusal, never by dropping",
       %{ctx: ctx, actor: actor} do
    # The payloads are already queued when the stream starts reading: the
    # first one finds the backlog past the bound.
    for _ <- 1..5, do: send(self(), changed(actor))

    conn =
      SSE.deliver(Plug.Test.conn(:post, "/_f/v1/stream"), ctx, grant(60_000),
        name: "mcp_servers.changes",
        revalidate: standing(ctx),
        max_backlog: 2
      )

    overflow = SSE.overflow()

    assert [%{event: "refusal", data: data}] = events(conn)

    assert data == %{
             "class" => "rate_limited",
             "message" => overflow.message,
             "stage" => "execution"
           }
  end

  test "a grant already ended delivers nothing", %{ctx: ctx} do
    conn =
      SSE.deliver(Plug.Test.conn(:post, "/_f/v1/stream"), ctx, grant(-1_000),
        name: "mcp_servers.changes",
        revalidate: standing(ctx)
      )

    assert events(conn) == []
  end

  describe "a frame's stream slots" do
    setup do
      Cyfr.Test.Settings.put("frame_stream_max_concurrent", 1)
      :ok
    end

    test "are counted per frame credential, and a released slot is free at once", %{ctx: ctx} do
      assert :ok = SSE.claim_slot(:frame_stream, ctx, :frame_stream_max_concurrent)

      assert {:error, :stream_limit} =
               SSE.claim_slot(:frame_stream, ctx, :frame_stream_max_concurrent)

      other = %{ctx | frame: frame("frc_other_#{System.unique_integer([:positive])}")}
      assert :ok = SSE.claim_slot(:frame_stream, other, :frame_stream_max_concurrent)

      assert :ok = SSE.release_slot(:frame_stream, ctx)
      assert :ok = SSE.claim_slot(:frame_stream, ctx, :frame_stream_max_concurrent)
    end
  end
end
