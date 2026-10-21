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
  alias Prima.Test.EventStream
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
      grant_revision: 0,
      mode: :live
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

  defp events(conn), do: EventStream.decode(conn.resp_body)

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

  describe "a stream that refreshes and filters" do
    # A stream on the feeds topic whose refresh publishes a live event of
    # the same revision before it answers: the event a refresh races.
    defmodule Racing do
      @moduledoc false
      @behaviour Prima.Provider

      @impl true
      def service, do: "racing"

      @impl true
      def tools, do: []

      @impl true
      def handle(_tool, _ctx, _args), do: {:error, :unreachable}

      @impl true
      def streams do
        [
          %Prima.Provider.Stream{
            name: "racing.results",
            topic: :feeds,
            projection: ~w(binding feed revision at result label actions),
            subject: ~S"\A[a-z0-9][a-z0-9-]{0,47}\z",
            deadline_bound: 60,
            refresh: {__MODULE__, :refresh},
            filter: "feed"
          },
          %Prima.Provider.Stream{
            name: "racing.broken",
            topic: :feeds,
            projection: ~w(feed revision),
            subject: ~S"\A[a-z0-9][a-z0-9-]{0,47}\z",
            deadline_bound: 60,
            refresh: {__MODULE__, :broken},
            filter: "feed"
          }
        ]
      end

      def refresh(ctx, subject) do
        actor = Sanctum.Context.actor(ctx)
        current = CyfrWeb.SSETest.envelope(subject, 1, 10)

        :ok =
          Cyfr.Bus.broadcast(
            actor,
            Cyfr.Bus.feeds(actor),
            Cyfr.Bus.FeedPublished.new(actor, current)
          )

        {:ok, [current]}
      end

      def broken(_ctx, _subject), do: {:error, :database_error}
    end

    defp feed_grant(subject, deadline_ms) do
      %StreamGrant{
        topic: :feeds,
        projection: ~w(binding feed revision at result label actions),
        subject: subject,
        deadline: DateTime.add(DateTime.utc_now(), deadline_ms, :millisecond),
        grant_id: "sgr_sse_feed"
      }
    end

    # Deliver in a process of its own; answers the task and its pid once
    # it is subscribed to the athanor's one feeds topic.
    defp delivering_feed(ctx, name, grant) do
      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:delivering, self()})

          SSE.deliver(Plug.Test.conn(:post, "/_f/v1/stream"), ctx, grant,
            name: name,
            revalidate: standing(ctx)
          )
        end)

      assert_receive {:delivering, pid}
      wait_until(fn -> pid in subscribers(Cyfr.Bus.feeds(Context.actor(ctx))) end)
      {task, pid}
    end

    defp published(actor, feed, revision, price) do
      :ok =
        Cyfr.Bus.broadcast(
          actor,
          Cyfr.Bus.feeds(actor),
          Cyfr.Bus.FeedPublished.new(actor, envelope(feed, revision, price))
        )
    end

    test "a refresh is delivered first and an event racing it is delivered, deduplicable",
         %{ctx: ctx} do
      Sanctum.Catalog.with_providers([Racing], fn ->
        {task, _pid} = delivering_feed(ctx, "racing.results", feed_grant("btc", 500))

        assert [refreshed, raced] = events(Task.await(task))

        # The current state first, marked; then the event published while
        # it was read, the same revision and the same fields, unmarked.
        assert %{event: "racing.results", data: %{"refresh" => true, "revision" => 1}} =
                 refreshed

        assert %{event: "racing.results", data: %{"revision" => 1, "feed" => "btc"} = raced_data} =
                 raced

        refute Map.has_key?(raced_data, "refresh")
        assert Map.delete(refreshed.data, "refresh") == raced_data
      end)
    end

    test "a filtering stream delivers only its subject's payloads, refresh and live",
         %{ctx: ctx, actor: actor} do
      Arca.Test.Actor.ensure_athanor_row(ctx.athanor_id)
      btc = accepted!(ctx, "btc", 11)
      _eth = accepted!(ctx, "eth", 22)

      {task, pid} = delivering_feed(ctx, "feed.results", feed_grant("btc", 500))

      # The delivery holds the athanor's one feeds topic and no topic built
      # from its subject.
      held = Registry.keys(Cyfr.PubSub, pid)
      assert Cyfr.Bus.feeds(actor) in held
      refute Enum.any?(held, &String.contains?(&1, "btc"))

      published(actor, "eth", 5, 33)
      published(actor, "btc", 6, 44)

      delivered = events(Task.await(task))
      assert Enum.all?(delivered, &(&1.data["feed"] == "btc")), inspect(delivered)

      assert [%{data: refreshed}, %{data: live}] = delivered
      assert refreshed == Map.put(btc, "refresh", true)
      assert %{"revision" => 6, "result" => %{"price" => 44}} = live
      refute Map.has_key?(live, "refresh")
    end

    test "a refresh that cannot be read ends the stream, unavailable, through the same cleanup",
         %{ctx: ctx} do
      Sanctum.Catalog.with_providers([Racing], fn ->
        conn =
          SSE.deliver(Plug.Test.conn(:post, "/_f/v1/stream"), ctx, feed_grant("btc", 60_000),
            name: "racing.broken",
            revalidate: standing(ctx)
          )

        assert [%{event: "refusal", data: %{"class" => "unavailable"}}] = events(conn)
        assert Registry.keys(Cyfr.PubSub, self()) == []
      end)
    end
  end

  @doc false
  # An accepted result's envelope, as `Prima.Feed.envelope/5` builds it.
  def envelope(feed, revision, price) do
    %{
      "binding" => "feed_01926f4e-8c1a-7b3d-9e2f-1a2b3c4d5e6f",
      "feed" => feed,
      "revision" => revision,
      "at" => "2026-10-09T00:00:00Z",
      "result" => %{"price" => price},
      "label" => "Feed #{feed}",
      "actions" => []
    }
  end

  # A live feed of the context's athanor with one accepted result: its
  # envelope as the stream's refresh answers it.
  defp accepted!(ctx, name, price) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => name,
        "label" => "Feed #{name}",
        "reference" => "catalyst:local.markets",
        "operation" => "quote",
        "args" => %{},
        "interval_minutes" => 5,
        "result_shape" => %{"type" => "json"},
        "actions" => []
      })

    actor = Context.actor(ctx)

    {:ok, row} =
      Arca.CronSchedule.create_feed(actor, %{
        binding: binding,
        resolved_reference: "catalyst:local.markets:1.0.0",
        profile_id: "prof_sse",
        cap: 1_000
      })

    {:ok, slot} = Arca.ControlPlane.member_slot()
    {:ok, seq} = Arca.CronSchedule.claim_feed_seq(actor, row.id)

    {:ok, envelope} =
      Opus.Feeds.accept(
        ctx,
        row.id,
        seq,
        %{"status" => 200, "data" => %{"price" => price}},
        slot
      )

    envelope
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
