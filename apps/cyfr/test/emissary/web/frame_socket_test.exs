# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.FrameSocketTest do
  @moduledoc """
  A frame's stream connection (`Emissary.Web.FrameSocket`): one
  connection carries every stream a frame subscribes to, each answered
  `subscribed` and its events tagged with its stream and subject, never
  naming the bus topic its grant admits; an unsubscribed stream frees its
  place at once, so a frame at the cap opens the next immediately; the
  connection carries at most the wire's subscriptions and is one frame's,
  a canvas's on its own path alone, where another frame's bearer is
  refused before its version is read or any charge is made; a stream
  bound to its holder is each person's own; a message that does not read
  closes it, one whose number reads refuses that subscription alone; a
  frame suspended or revoked ends each subscription at its announcement,
  a standing announcement about its person when revalidation refuses, and
  the next revalidation once its credential stops standing unannounced;
  a connection that falls too far behind ends every subscription with the
  overflow refusal, and hands a canvas-readable stream a fresh picture
  instead; such a stream keeps the delivery contract: its picture ends
  with a snapshot no item of it outranks, a change of a reread kind is
  answered with one fresh picture, at its bound the picture is read again
  and a read that fails is told stale once, and a resync is read only
  under the frame's context established again; a newer connection of the frame replaces the older,
  an idle one closes; each subscribe's bearer is read as a request's,
  while an admitted subscription is held to the row up to its own bound;
  a stream's refresh comes first, marked, and one that cannot be read
  ends it; a filtering stream delivers only its subject's payloads; an
  app that connects to an origin opens a stream only while its grant lets
  what the stream carries flow there; a validation trial is answered from
  fixtures, a feed's from the binding the athanor holds, and holds
  nothing; and over a real listener eight streams share one connection,
  and a message over the wire's bound closes it.
  """

  # Mints and suspends frame credentials, writes platform settings and
  # meters rates, all of them process-wide.
  use CyfrWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Cyfr.Test.FrameSocket, as: Socket
  alias Emissary.Web.FrameSocket
  alias Prima.Canvas.Shape
  alias Prima.TinctureWire
  alias Sanctum.TinctureAuth

  # A provider of two streams on the feeds topic, filtered by the feed's
  # name as their subject: one whose refresh publishes a live event of the
  # same revision before it answers, the event a refresh races, and one
  # whose refresh cannot be read.
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
      for {name, refresh} <- [{"racing.results", :refresh}, {"racing.broken", :broken}] do
        %Prima.Provider.Stream{
          name: name,
          topic: :feeds,
          projection: ~w(binding feed revision at result label actions),
          subject: ~S"\A[a-z0-9][a-z0-9-]{0,47}\z",
          deadline_bound: 60,
          refresh: {__MODULE__, refresh},
          filter: "feed"
        }
      end
    end

    def refresh(ctx, subject) do
      actor = Sanctum.Context.actor(ctx)
      current = Emissary.Web.FrameSocketTest.envelope(subject, 1, 10)

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

  # A provider of three canvas-readable streams on the schedules topic,
  # each item a schedule by its id, whose picture the case sets
  # (`picture/1`, a list of items or an error the read answers, kept in
  # the application's environment through `Prima.Test.Env`):
  # `pictured.changes` delivers each change, `pictured.rereads` answers a
  # `changed` with a fresh picture, and `pictured.brief`'s picture stands a
  # second.
  defmodule Pictured do
    @moduledoc false
    @behaviour Prima.Provider

    @impl true
    def service, do: "pictured"

    @impl true
    def tools, do: []

    @impl true
    def handle(_tool, _ctx, _args), do: {:error, :unreachable}

    @impl true
    def streams do
      {:ok, shape} =
        Prima.Canvas.Shape.validate(%{
          "type" => "object",
          "fields" => %{
            "kind" => %{"type" => "enum", "values" => ["changed", "removed"]},
            "schedule_id" => %{"type" => "string"},
            "status" => %{"type" => "string", "nullable" => true}
          },
          "required" => ["kind", "schedule_id"]
        })

      for {name, reread, stale_after} <- [
            {"pictured.changes", [], 60},
            {"pictured.rereads", ["changed"], 60},
            {"pictured.brief", [], 1}
          ] do
        %Prima.Provider.Stream{
          name: name,
          topic: :schedules,
          projection: ["kind", "schedule_id", "status", "revision", "at"],
          deadline_bound: 600,
          shape: Prima.Provider.Stream.delivered(shape),
          refresh: {__MODULE__, :refresh},
          key: "schedule_id",
          removal: "removed",
          reread: reread,
          stale_after: stale_after
        }
      end
    end

    def picture(picture), do: Prima.Test.Env.put_app_env(:cyfr, __MODULE__, picture)

    def refresh(_ctx, nil) do
      case Application.get_env(:cyfr, __MODULE__, []) do
        items when is_list(items) -> {:ok, items}
        {:error, _} = unread -> unread
      end
    end
  end

  @version "1.0.0"
  @wire Path.expand("../../../../../tests/fixtures/tincture_wire.json", __DIR__)
  @origin "api.flows.example"

  # How long an admission or a delivery may take on a loaded host. Each
  # wait ends on the answer itself; this bounds one that never comes.
  @answer_ms 10_000

  setup do
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)

    {person, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local())
    own = Sanctum.Test.People.athanor!(user)
    issuer = Sanctum.TestContext.issuer!(%{person | athanor_id: own.id})
    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, source} = Sanctum.Caller.establish(session.token)
    {:ok, source: source}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp canvas!(ctx, name, desktop) do
    put_version!(ctx, name, %{
      "name" => name,
      "type" => "tincture",
      "version" => @version,
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "desktop" => desktop}
    })
  end

  # An app declaring `streams`, and connecting to the origins `connect`
  # names.
  defp app!(ctx, name, streams, connect \\ []) do
    tincture = %{"entry" => "index.html", "streams" => streams}
    tincture = if connect == [], do: tincture, else: Map.put(tincture, "connect", connect)

    put_version!(ctx, name, %{
      "name" => name,
      "type" => "tincture",
      "version" => @version,
      "publisher" => "local",
      "tincture" => tincture
    })
  end

  defp put_version!(ctx, name, manifest) do
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: @version,
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    release_digest
  end

  # The frame the shell would open for `name`, granted first as the person
  # would grant it.
  defp frame!(source, name, digest, opts \\ []) do
    reference = %{publisher: "local", name: name, version: @version}
    frame_id = "frm_sock_#{System.unique_integer([:positive])}"

    revision =
      case Sanctum.Consent.tincture_grant(source, "tincture:local.#{name}:#{@version}") do
        {:ok, %{revision: revision}} ->
          revision

        {:error, :ungranted} ->
          Sanctum.Test.ConsentFixtures.grant_tincture!(source, "tincture:local.#{name}")
          1
      end

    mint =
      if Keyword.get(opts, :validation, false),
        do: &TinctureAuth.mint_validation_credential/5,
        else: &TinctureAuth.mint_frame_credential/5

    {:ok, %{credential: bearer, id: id}} = mint.(source, reference, digest, revision, frame_id)
    %{bearer: bearer, id: id, frame_id: frame_id}
  end

  defp canvas_frame!(source, desktop \\ %{"data" => ["mcp_servers.changes"]}) do
    name = "sock-canvas-#{System.unique_integer([:positive])}"
    frame!(source, name, canvas!(source, name, desktop))
  end

  defp topic(source), do: Cyfr.Bus.mcp_servers(Sanctum.Context.actor(source))

  defp listeners(source), do: length(Registry.lookup(Cyfr.PubSub, topic(source)))

  defp changed(source) do
    actor = Sanctum.Context.actor(source)
    :ok = Cyfr.Bus.broadcast(actor, topic(source), Cyfr.Bus.McpServers.new(actor, :changed))
  end

  # The wire's vector of the rejection `why` names (`stream_rejections`):
  # the refusal the SDK reads, which the socket answers word for word.
  defp vector_error(why) do
    @wire
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("stream_rejections")
    |> Map.fetch!("cases")
    |> Enum.find(&(&1["why"] == why))
    |> get_in(["answer", "error"])
  end

  defp answer(socket, sub) do
    assert_receive {:socket, ^socket, %{"sub" => ^sub} = message}, @answer_ms
    message
  end

  # The gate's stream decisions: an open admitted or refused.
  defp stream_decisions,
    do: Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: like(d.tool, "stream:%")))

  # A freshness bound no case outlasts: only an announcement or a deadline
  # ends a subscription within the case.
  defp fresh_for_the_case!,
    do: Prima.Test.Env.put_app_env(:sanctum, :caller_memo_ttl_ms, 600_000)

  # ---------------------------------------------------------------------------
  # One connection, many streams
  # ---------------------------------------------------------------------------

  test "a subscription is answered subscribed, and its events arrive tagged with its stream and subject",
       %{source: source} do
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})

    Socket.subscribe(socket, 1, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = subscribed = answer(socket, 1)
    wait_until(fn -> listeners(source) == 1 end, @answer_ms)

    changed(source)

    assert %{
             "type" => "event",
             "stream" => "mcp_servers.changes",
             "subject" => nil,
             "id" => nil,
             "data" => %{"kind" => "changed"} = data
           } = event = answer(socket, 1)

    refute Map.has_key?(data, "athanor_id")

    # The topic the grant admits is the endpoint's, never the frame's.
    for message <- [subscribed, event], do: refute(Jason.encode!(message) =~ "tenant:")

    assert Arca.Repo.exists?(
             from(d in Arca.Schemas.DecisionLog,
               where: d.tool == "stream:mcp_servers.changes" and d.admission == "admitted"
             )
           )
  end

  test "at the cap the next subscription is refused, and an unsubscribed one frees its place at once",
       %{source: source} do
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})
    max = TinctureWire.max_subscriptions()

    for sub <- 1..max do
      Socket.subscribe(socket, sub, frame.bearer, "mcp_servers.changes")
      assert %{"type" => "subscribed"} = answer(socket, sub)
    end

    wait_until(fn -> listeners(source) == max end, @answer_ms)

    Socket.subscribe(socket, max + 1, frame.bearer, "mcp_servers.changes")

    assert %{"type" => "ended", "error" => over} = answer(socket, max + 1)
    assert over == vector_error("the connection carries max_subscriptions subscriptions already")

    # A closed stream's place is free for the very next subscribe: no
    # timeout, and its forwarder gone with it.
    Socket.unsubscribe(socket, 1)
    Socket.subscribe(socket, max + 2, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, max + 2)
    assert map_size(Socket.state(socket).subs) == max
    wait_until(fn -> listeners(source) == max end, @answer_ms)

    # Nothing more of the unsubscribed stream reaches the frame.
    changed(source)
    assert %{"type" => "event"} = answer(socket, 2)
    refute_received {:socket, ^socket, %{"sub" => 1}}
  end

  # A suspended frame is the shell's to show again; a revoked bearer opens
  # nothing.
  for {act, class} <- [suspend_frame: "forbidden", revoke_frame: "unauthenticated"] do
    @tag act: act, class: class
    test "a frame's #{act} ends every subscription at its announcement",
         %{source: source, act: act, class: class} do
      fresh_for_the_case!()
      frame = canvas_frame!(source)
      socket = Socket.connect({:canvas, frame.frame_id})

      for sub <- [1, 2] do
        Socket.subscribe(socket, sub, frame.bearer, "mcp_servers.changes")
        assert %{"type" => "subscribed"} = answer(socket, sub)
      end

      {:ok, _} = apply(TinctureAuth, act, [source, frame.id])

      for sub <- [1, 2] do
        assert %{"type" => "ended", "error" => %{"class" => ^class}} = answer(socket, sub)
      end

      wait_until(fn -> listeners(source) == 0 end, @answer_ms)
      assert Socket.state(socket).subs == %{}
    end
  end

  # The person's standing moved with no announcement, and the
  # announcements about another and about them: `{topic, payload}` each.
  defp standing_moved!(:session, source) do
    {1, _} =
      Arca.Repo.delete_all(
        from(s in Arca.Schemas.Session, where: s.token_hash == ^source.session_token_hash)
      )

    {{Cyfr.Bus.sessions(), Cyfr.Bus.Session.new(:revoked, "local|local|sock-someone-else")},
     {Cyfr.Bus.sessions(), Cyfr.Bus.Session.new(:revoked, source.user_id)}}
  end

  defp standing_moved!(:athanor_archived, source) do
    Arca.Test.Actor.archive!(source.athanor_id)

    {{Cyfr.Bus.athanor_archived_global(), Cyfr.Bus.AthanorArchived.new("ath_sock_elsewhere")},
     {Cyfr.Bus.athanor_archived_global(), Cyfr.Bus.AthanorArchived.new(source.athanor_id)}}
  end

  for announcement <- [:session, :athanor_archived] do
    @tag announcement: announcement
    test "a standing announcement about the frame's person (#{announcement}) ends every subscription its revalidation refuses, one about another ends none",
         %{source: source, announcement: announcement} do
      fresh_for_the_case!()
      frame = canvas_frame!(source)
      socket = Socket.connect({:canvas, frame.frame_id})

      for sub <- [1, 2] do
        Socket.subscribe(socket, sub, frame.bearer, "mcp_servers.changes")
        assert %{"type" => "subscribed"} = answer(socket, sub)
      end

      {{topic, about_another}, {topic, about_them}} = standing_moved!(announcement, source)

      :ok = Phoenix.PubSub.broadcast(Cyfr.PubSub, topic, about_another)
      refute_receive {:socket, ^socket, %{"type" => "ended"}}, 300
      assert map_size(Socket.state(socket).subs) == 2

      :ok = Phoenix.PubSub.broadcast(Cyfr.PubSub, topic, about_them)

      for sub <- [1, 2] do
        assert %{"type" => "ended", "error" => %{"class" => "unauthenticated"}} =
                 answer(socket, sub)
      end

      wait_until(fn -> listeners(source) == 0 end, @answer_ms)
    end
  end

  test "a frame whose credential stops standing with no announcement ends at its next revalidation",
       %{source: source} do
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})
    Socket.subscribe(socket, 1, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 1)

    # The row revoked behind the shell's back: no announcement is made, and
    # the connection's own revalidation finds it.
    {1, _} =
      Arca.Repo.update_all(
        from(f in Arca.Schemas.FrameCredential, where: f.id == ^frame.id),
        set: [state: "revoked"]
      )

    assert %{"type" => "ended", "error" => %{"class" => "unauthenticated"}} = answer(socket, 1)
    wait_until(fn -> listeners(source) == 0 end, @answer_ms)
  end

  test "a connection that falls too far behind ends every subscription with the overflow refusal, never by dropping",
       %{source: source} do
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})

    for sub <- [1, 2] do
      Socket.subscribe(socket, sub, frame.bearer, "mcp_servers.changes")
      assert %{"type" => "subscribed"} = answer(socket, sub)
    end

    wait_until(fn -> listeners(source) == 2 end, @answer_ms)

    # The connection holds still while its forwarders queue more than it
    # may fall behind by; the first fact it then reads finds the backlog.
    :erlang.suspend_process(socket)

    try do
      for _ <- 1..600, do: changed(source)

      wait_until(
        fn -> elem(Process.info(socket, :message_queue_len), 1) > 1_000 end,
        @answer_ms
      )
    after
      :erlang.resume_process(socket)
    end

    for sub <- [1, 2] do
      ended = Jason.decode!(Jason.encode!(TinctureWire.ended(sub, FrameSocket.overflow())))
      assert answer(socket, sub) == ended
    end

    assert Socket.state(socket).subs == %{}
  end

  # ---------------------------------------------------------------------------
  # The delivery contract
  # ---------------------------------------------------------------------------

  describe "a canvas-readable stream keeps the delivery contract" do
    setup %{source: source} do
      Pictured.picture([item("sch_one", "active")])
      %{actor: Sanctum.Context.actor(source)}
    end

    defp item(id, status, at \\ DateTime.utc_now()),
      do: %{kind: :changed, schedule_id: id, status: status, revision: micro(at), at: at}

    defp micro(at), do: DateTime.to_unix(at, :microsecond)

    defp told!(actor, kind, id, status) do
      :ok =
        Cyfr.Bus.broadcast(
          actor,
          Cyfr.Bus.schedules(actor),
          Cyfr.Bus.Schedules.new(actor, kind, schedule_id: id, status: status)
        )
    end

    defp pictured(source, stream, fun) do
      Sanctum.Catalog.with_providers([Pictured], fn ->
        frame = canvas_frame!(source, %{"data" => [stream, "mcp_servers.changes"]})
        socket = Socket.connect({:canvas, frame.frame_id})
        fun.(socket, frame)
      end)
    end

    # The picture a subscription is handed: its items, then the snapshot
    # and the time it names.
    defp picture!(socket, sub, count) do
      items = for _ <- 1..count//1, do: answer(socket, sub)
      assert %{"type" => "snapshot", "at" => at} = answer(socket, sub)
      {:ok, at, 0} = DateTime.from_iso8601(at)
      {Enum.map(items, & &1["data"]), at}
    end

    test "its picture ends with a snapshot, no item stamped later than the read began, and each change follows with a higher revision",
         %{source: source, actor: actor} do
      # An owner that stamped its item after the read began.
      Pictured.picture([item("sch_one", "active", DateTime.add(DateTime.utc_now(), 3600))])

      pictured(source, "pictured.changes", fn socket, frame ->
        Socket.subscribe(socket, 1, frame.bearer, "pictured.changes")
        assert %{"type" => "subscribed"} = answer(socket, 1)
        {[read], at} = picture!(socket, 1, 1)

        assert %{"refresh" => true, "schedule_id" => "sch_one", "revision" => revision} = read
        assert revision == micro(at)
        assert read["at"] == DateTime.to_iso8601(at)

        told!(actor, :changed, "sch_one", "paused")

        assert %{"type" => "event", "data" => %{"status" => "paused", "revision" => later}} =
                 changed = answer(socket, 1)

        refute Map.has_key?(changed["data"], "refresh")
        assert later > revision

        told!(actor, :removed, "sch_one", nil)
        assert %{"data" => %{"kind" => "removed", "schedule_id" => "sch_one"}} = answer(socket, 1)
      end)
    end

    test "a change of a reread kind is answered with one fresh picture in its place, a burst of them with one",
         %{source: source, actor: actor} do
      pictured(source, "pictured.rereads", fn socket, frame ->
        Socket.subscribe(socket, 1, frame.bearer, "pictured.rereads")
        assert %{"type" => "subscribed"} = answer(socket, 1)
        {[_first], _at} = picture!(socket, 1, 1)

        Pictured.picture([item("sch_one", "paused"), item("sch_two", "active")])
        for status <- ~w(paused active paused), do: told!(actor, :changed, "sch_one", status)

        assert %{"type" => "resync"} = answer(socket, 1)
        {items, _at} = picture!(socket, 1, 2)

        assert Enum.map(items, &{&1["schedule_id"], &1["status"]}) == [
                 {"sch_one", "paused"},
                 {"sch_two", "active"}
               ]

        refute_receive {:socket, ^socket, %{"sub" => 1}}, 600

        # A removal is not a reread kind: it is delivered.
        told!(actor, :removed, "sch_two", nil)
        assert %{"type" => "event", "data" => %{"kind" => "removed"}} = answer(socket, 1)
      end)
    end

    test "at its bound a picture is read again as a resync; a read that fails tells stale once and keeps the stream",
         %{source: source} do
      fresh_for_the_case!()

      pictured(source, "pictured.brief", fn socket, frame ->
        Socket.subscribe(socket, 1, frame.bearer, "pictured.brief")
        assert %{"type" => "subscribed"} = answer(socket, 1)
        {[_], first} = picture!(socket, 1, 1)

        assert %{"type" => "resync"} = answer(socket, 1)
        {[_], second} = picture!(socket, 1, 1)
        assert DateTime.diff(second, first, :millisecond) >= 1_000

        Pictured.picture({:error, :database_error})
        assert %{"type" => "stale", "at" => at} = answer(socket, 1)
        assert at == DateTime.to_iso8601(second)
        refute_receive {:socket, ^socket, %{"sub" => 1}}, 1_500
        assert Map.keys(Socket.state(socket).subs) == [1]

        Pictured.picture([item("sch_one", "active")])
        assert %{"type" => "resync"} = answer(socket, 1)
        {[_], _third} = picture!(socket, 1, 1)
      end)
    end

    test "a connection that falls too far behind hands a canvas-readable stream a fresh picture and ends the other",
         %{source: source} do
      pictured(source, "pictured.changes", fn socket, frame ->
        Socket.subscribe(socket, 1, frame.bearer, "pictured.changes")
        assert %{"type" => "subscribed"} = answer(socket, 1)
        {[_], _at} = picture!(socket, 1, 1)
        Socket.subscribe(socket, 2, frame.bearer, "mcp_servers.changes")
        assert %{"type" => "subscribed"} = answer(socket, 2)

        :erlang.suspend_process(socket)

        try do
          for _ <- 1..1_100, do: changed(source)

          wait_until(
            fn -> elem(Process.info(socket, :message_queue_len), 1) > 1_000 end,
            @answer_ms
          )
        after
          :erlang.resume_process(socket)
        end

        ended = Jason.decode!(Jason.encode!(TinctureWire.ended(2, FrameSocket.overflow())))
        assert answer(socket, 2) == ended
        assert %{"type" => "resync"} = answer(socket, 1)
        {[_], _at} = picture!(socket, 1, 1)
        assert Map.keys(Socket.state(socket).subs) == [1]
      end)
    end

    test "a resync is read only under the frame's context established again: a credential that no longer stands ends the stream, handing nothing",
         %{source: source, actor: actor} do
      fresh_for_the_case!()

      pictured(source, "pictured.rereads", fn socket, frame ->
        Socket.subscribe(socket, 1, frame.bearer, "pictured.rereads")
        assert %{"type" => "subscribed"} = answer(socket, 1)
        {[_], _at} = picture!(socket, 1, 1)

        # Revoked behind the shell's back, within the context's freshness.
        {1, _} =
          Arca.Repo.update_all(
            from(f in Arca.Schemas.FrameCredential, where: f.id == ^frame.id),
            set: [state: "revoked"]
          )

        told!(actor, :changed, "sch_one", "paused")

        assert %{"type" => "ended", "error" => %{"class" => "unauthenticated"}} =
                 answer(socket, 1)

        refute_receive {:socket, ^socket, %{"sub" => 1}}, 300
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # One frame's
  # ---------------------------------------------------------------------------

  test "a connection carries one frame's streams: another frame's or another person's credential is refused",
       %{source: source} do
    mine = canvas_frame!(source)
    other = canvas_frame!(source)
    socket = Socket.connect(:shared)
    app = "sock-app-#{System.unique_integer([:positive])}"
    first = frame!(source, app, app!(source, app, [%{"name" => "mcp_servers.changes"}]))

    Socket.subscribe(socket, 1, first.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 1)

    second = frame!(source, app, app!(source, app, [%{"name" => "mcp_servers.changes"}]))
    Socket.subscribe(socket, 2, second.bearer, "mcp_servers.changes")

    assert %{"type" => "ended", "error" => mismatch} = answer(socket, 2)

    assert mismatch ==
             vector_error("another frame's credential on a connection bound to one frame")

    # A canvas's credential on the shared connection, and another person's
    # frame, open nothing either.
    Socket.subscribe(socket, 3, mine.bearer, "mcp_servers.changes")
    assert %{"type" => "ended", "error" => %{"message" => shared}} = answer(socket, 3)
    assert shared =~ "canvas_path_required"

    person = person!("sock-bystander")
    theirs = canvas_frame!(person)
    Socket.subscribe(socket, 4, theirs.bearer, "mcp_servers.changes")
    assert %{"type" => "ended", "error" => %{"class" => "forbidden"}} = answer(socket, 4)

    assert Map.keys(Socket.state(socket).subs) == [1]
    refute other.frame_id == mine.frame_id
  end

  test "a canvas path takes only its own frame's credential, and only a canvas's",
       %{source: source} do
    mine = canvas_frame!(source)
    other = canvas_frame!(source)
    app = "sock-app-#{System.unique_integer([:positive])}"
    an_app = frame!(source, app, app!(source, app, [%{"name" => "mcp_servers.changes"}]))

    socket = Socket.connect({:canvas, mine.frame_id})
    Socket.subscribe(socket, 1, other.bearer, "mcp_servers.changes")
    assert %{"type" => "ended", "error" => mismatch} = answer(socket, 1)

    assert mismatch ==
             vector_error("a canvas's connection presented another frame's credential")

    socket = Socket.connect({:canvas, an_app.frame_id})
    Socket.subscribe(socket, 1, an_app.bearer, "mcp_servers.changes")
    assert %{"type" => "ended", "error" => %{"message" => message}} = answer(socket, 1)
    assert message =~ "not_a_canvas"

    socket = Socket.connect({:canvas, mine.frame_id})
    Socket.subscribe(socket, 1, mine.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 1)
  end

  test "a canvas path refuses another frame's bearer before its version is read or any charge is made",
       %{source: source} do
    Cyfr.Test.Settings.put("frame_invocation_max", 1)
    Cyfr.Test.Settings.put("frame_invocation_window_ms", 60_000)
    name = "sock-path-#{System.unique_integer([:positive])}"
    digest = canvas!(source, name, %{"data" => ["mcp_servers.changes"]})
    mine = frame!(source, name, digest)
    other = frame!(source, name, digest)
    socket = Socket.connect({:canvas, mine.frame_id})

    for sub <- [1, 2] do
      Socket.subscribe(socket, sub, other.bearer, "mcp_servers.changes")

      assert %{"type" => "ended", "error" => %{"class" => "forbidden", "message" => message}} =
               answer(socket, sub)

      assert message =~ "(frame_path_mismatch)"
      refute message =~ mine.frame_id
      refute message =~ other.frame_id
    end

    # No authority was derived: each refusal is recorded under no person,
    # and nothing reached the gate.
    assert [_, _] =
             refusals =
             Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.tool == "tincture"))

    assert Enum.all?(refusals, &(&1.admission == "refused" and is_nil(&1.user_id)))
    assert stream_decisions() == []

    # Nothing was charged: the other open's one request in the window binds
    # its own connection, and the charge then holds.
    theirs = Socket.connect({:canvas, other.frame_id})
    Socket.subscribe(theirs, 1, other.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(theirs, 1)

    over = Socket.connect({:canvas, other.frame_id})
    Socket.subscribe(over, 1, other.bearer, "mcp_servers.changes")
    assert %{"type" => "ended", "error" => rated} = answer(over, 1)

    # The vector's sentence, its retry seconds this window's.
    vector = vector_error("the frame's request rate, charged once as the connection binds")
    assert Map.delete(rated, "message") == Map.delete(vector, "message")
    assert rated["message"] =~ ~r/\AToo many requests; retry in \d+ s\.\z/

    # With the canvas's version moved, this open's bearer is refused on
    # another open's path for the path, its version unread, and on its own
    # path for the version.
    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.Component, where: c.name == ^name),
        set: [release_digest: "sha256:" <> String.duplicate("f", 64)]
      )

    elsewhere = Socket.connect({:canvas, other.frame_id})
    Socket.subscribe(elsewhere, 1, mine.bearer, "mcp_servers.changes")
    assert %{"type" => "ended", "error" => %{"message" => message}} = answer(elsewhere, 1)
    assert message =~ "(frame_path_mismatch)"

    Socket.subscribe(socket, 3, mine.bearer, "mcp_servers.changes")
    assert %{"type" => "ended", "error" => %{"message" => message}} = answer(socket, 3)
    assert message =~ "changed since its frame opened"
  end

  test "a stream the frame does not declare, or with a subject it does not take, is refused, recorded, and holds nothing",
       %{source: source} do
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})

    for {sub, stream, subject} <- [
          {1, "confirmation.changes", nil},
          {2, "mcp_servers.changes", "x"}
        ] do
      Socket.subscribe(socket, sub, frame.bearer, stream, subject)

      assert %{"type" => "ended", "error" => undeclared} = answer(socket, sub)
      assert undeclared == vector_error("a stream the tincture does not declare")
    end

    assert Socket.state(socket).subs == %{}
    assert stream_decisions() == []

    assert Arca.Repo.exists?(
             from(d in Arca.Schemas.DecisionLog,
               where:
                 d.tool == "tincture" and d.admission == "refused" and
                   d.user_id == ^source.user_id
             )
           )
  end

  # ---------------------------------------------------------------------------
  # The wire's bounds
  # ---------------------------------------------------------------------------

  test "a message that does not read closes the connection; one whose number reads refuses that subscription",
       %{source: source} do
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})

    Socket.send_text(socket, TinctureWire.subscribe(1, frame.bearer, "x", nil))
    assert %{"type" => "ended", "error" => %{"class" => "invalid_argument"}} = answer(socket, 1)
    assert Process.alive?(socket)

    Socket.send_text(socket, "not json")
    unreadable = TinctureWire.close_code(:unreadable)
    assert_receive {:socket_closed, ^socket, ^unreadable, _reason}, @answer_ms

    socket = Socket.connect({:canvas, frame.frame_id})
    Socket.send_binary(socket, <<0, 1, 2>>)
    assert_receive {:socket_closed, ^socket, ^unreadable, _reason}, @answer_ms
  end

  test "a newer connection of the frame closes the older", %{source: source} do
    frame = canvas_frame!(source)
    older = Socket.connect({:canvas, frame.frame_id})
    Socket.subscribe(older, 1, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(older, 1)

    newer = Socket.connect({:canvas, frame.frame_id})
    Socket.subscribe(newer, 1, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(newer, 1)

    replaced = TinctureWire.close_code(:replaced)
    assert_receive {:socket_closed, ^older, ^replaced, _reason}, @answer_ms
    wait_until(fn -> listeners(source) == 1 end, @answer_ms)
  end

  test "a connection that holds no subscription closes as idle", %{source: source} do
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})
    Socket.subscribe(socket, 1, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 1)
    assert Socket.state(socket).idle == nil

    Socket.unsubscribe(socket, 1)
    assert {token, _timer} = Socket.state(socket).idle
    send(socket, {FrameSocket, :idle, token})

    idle = TinctureWire.close_code(:idle)
    assert_receive {:socket_closed, ^socket, ^idle, _reason}, @answer_ms
  end

  # ---------------------------------------------------------------------------
  # The bearer, read as a request's; the grant, held to the row
  # ---------------------------------------------------------------------------

  test "a subscribe's bearer is read as a request's: one past its own deadline subscribes nothing after a renewal",
       %{source: source} do
    Cyfr.Test.Settings.put("frame_credential_deadline_s", 2)
    frame = canvas_frame!(source)
    Cyfr.Test.Settings.put("frame_credential_deadline_s", 3_600)
    assert {:ok, %{credential: renewed}} = TinctureAuth.renew_frame(source, frame.id)

    wait_until(
      fn ->
        TinctureAuth.verify_frame_credential(frame.bearer) == {:error, :expired_credential}
      end,
      5_000
    )

    socket = Socket.connect({:canvas, frame.frame_id})
    Socket.subscribe(socket, 1, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "ended", "error" => %{"class" => "unauthenticated"}} = answer(socket, 1)

    Socket.subscribe(socket, 2, renewed, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 2)
  end

  test "at its grant's deadline a subscription reads the row again, so a renewal keeps it",
       %{source: source} do
    Cyfr.Test.Settings.put("frame_credential_deadline_s", 2)
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})
    Socket.subscribe(socket, 1, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 1)
    %{grant: %{deadline: first}} = Socket.state(socket).subs[1]

    Cyfr.Test.Settings.put("frame_credential_deadline_s", 3_600)
    assert {:ok, _renewed} = TinctureAuth.renew_frame(source, frame.id)
    wait_until(fn -> DateTime.compare(DateTime.utc_now(), first) == :gt end, 5_000)

    wait_until(
      fn ->
        case Socket.state(socket).subs[1] do
          %{grant: %{deadline: deadline}} -> DateTime.compare(deadline, first) == :gt
          nil -> flunk("the subscription ended at the bearer's deadline after a renewal")
        end
      end,
      @answer_ms
    )

    refute_received {:socket, ^socket, %{"type" => "ended"}}
  end

  test "no renewal keeps a subscription past its own bound from the open", %{source: source} do
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})
    Socket.subscribe(socket, 1, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 1)

    # The subscription's bound is near, and its deadline nearer: the row
    # stands for an hour, so only the bound can end it.
    now = DateTime.utc_now()

    Socket.update(socket, fn state ->
      entry = state.subs[1]
      grant = %{entry.grant | deadline: DateTime.add(now, 100, :millisecond)}
      grant = %{grant | bound: DateTime.add(now, 600, :millisecond)}
      token = make_ref()
      Process.cancel_timer(elem(entry.timer, 1))
      timer = Process.send_after(self(), {FrameSocket, :deadline, 1, token}, 100)
      put_in(state.subs[1], %{entry | grant: grant, timer: {token, timer}})
    end)

    assert %{"type" => "ended"} = ended = answer(socket, 1)
    refute Map.has_key?(ended, "error")
    assert DateTime.compare(DateTime.utc_now(), DateTime.add(now, 600, :millisecond)) != :lt
  end

  # ---------------------------------------------------------------------------
  # What a stream delivers
  # ---------------------------------------------------------------------------

  test "a stream bound to its holder is each person's own, and a named subject is refused",
       %{source: source} do
    streams = [%{"name" => "confirmation.changes"}]
    name = "sock-confirm-#{System.unique_integer([:positive])}"

    # Mine also names any subject for it, which publish refuses and a
    # stored row can still say: the frame's subject is refused all the same.
    any = %{"name" => "confirmation.changes", "subject" => "*"}
    mine = frame!(source, name, app!(source, name, [any | streams]))

    # The bystander holds the same declaration in their own athanor, under
    # a name of its own, as a grant's profile id is its name's.
    other = person!("sock-holder")
    their_name = "sock-their-confirm-#{System.unique_integer([:positive])}"
    theirs = frame!(other, their_name, app!(other, their_name, streams))

    my_socket = Socket.connect(:shared)
    their_socket = Socket.connect(:shared)

    # A subject from the frame is never taken, the holder's own included.
    for {sub, subject} <- [{1, other.user_id}, {2, source.user_id}] do
      Socket.subscribe(my_socket, sub, mine.bearer, "confirmation.changes", subject)
      assert %{"type" => "ended", "error" => %{"message" => message}} = answer(my_socket, sub)
      assert message =~ "does not declare that stream"
    end

    Socket.subscribe(my_socket, 3, mine.bearer, "confirmation.changes")
    assert %{"type" => "subscribed"} = answer(my_socket, 3)
    Socket.subscribe(their_socket, 1, theirs.bearer, "confirmation.changes")
    assert %{"type" => "subscribed"} = answer(their_socket, 1)

    # Each person's confirmation on their own topic, mine first: had mine
    # reached the bystander, it would come before theirs.
    my_ref = confirmed(source, "A")
    their_ref = confirmed(other, "B")

    assert %{
             "type" => "event",
             "stream" => "confirmation.changes",
             "subject" => nil,
             "data" =>
               %{"ref" => ^my_ref, "kind" => "opened", "operation" => "vault.create"} = data
           } = answer(my_socket, 3)

    # The projection carries no person and no athanor.
    refute Map.has_key?(data, "user_id")
    refute Map.has_key?(data, "athanor_id")

    assert %{"type" => "event", "data" => %{"ref" => ^their_ref}} = answer(their_socket, 1)
  end

  # A confirmation opened on `ctx`'s person's own topic, its id `letter`
  # repeated: its ref.
  defp confirmed(ctx, letter) do
    actor = Sanctum.Context.actor(ctx)
    ref = Prima.Confirmation.ref("cnf_" <> String.duplicate(letter, 43))

    opened =
      Cyfr.Bus.Confirmation.new(actor, :opened,
        ref: ref,
        operation: "vault.create",
        expires_at: ~U[2026-10-09 12:05:00Z]
      )

    :ok = Cyfr.Bus.broadcast(actor, Cyfr.Bus.confirmations(actor, ctx.user_id), opened)
    ref
  end

  test "a refresh's items arrive first, marked, before an event that raced the read; a refresh that cannot be read ends the subscription",
       %{source: source} do
    Sanctum.Catalog.with_providers([Racing], fn ->
      name = "sock-racing-#{System.unique_integer([:positive])}"

      streams = [
        %{"name" => "racing.results", "subject" => "btc"},
        %{"name" => "racing.broken", "subject" => "btc"}
      ]

      frame = frame!(source, name, app!(source, name, streams))
      socket = Socket.connect(:shared)

      Socket.subscribe(socket, 1, frame.bearer, "racing.results", "btc")
      assert %{"type" => "subscribed"} = answer(socket, 1)

      # The current state first, marked; then the event published while it
      # was read, the same revision and the same fields, unmarked.
      assert %{
               "type" => "event",
               "stream" => "racing.results",
               "subject" => "btc",
               "data" => %{"refresh" => true, "revision" => 1} = refreshed
             } = answer(socket, 1)

      assert %{"type" => "event", "data" => %{"revision" => 1, "feed" => "btc"} = raced} =
               answer(socket, 1)

      refute Map.has_key?(raced, "refresh")
      assert Map.delete(refreshed, "refresh") == raced

      Socket.subscribe(socket, 2, frame.bearer, "racing.broken", "btc")
      assert %{"type" => "subscribed"} = answer(socket, 2)
      assert %{"type" => "ended", "error" => %{"class" => "unavailable"}} = answer(socket, 2)
      assert Map.keys(Socket.state(socket).subs) == [1]
    end)
  end

  test "a filtering stream delivers only its subject's payloads, refresh and live",
       %{source: source} do
    btc = accepted!(source, "btc", 11)
    _eth = accepted!(source, "eth", 22)
    actor = Sanctum.Context.actor(source)
    frame = canvas_frame!(source, %{"feeds" => ["btc"]})
    socket = Socket.connect({:canvas, frame.frame_id})

    Socket.subscribe(socket, 1, frame.bearer, "feed.results", "btc")
    assert %{"type" => "subscribed"} = answer(socket, 1)

    assert %{"type" => "event", "subject" => "btc", "data" => refreshed} = answer(socket, 1)
    assert refreshed == btc |> Jason.encode!() |> Jason.decode!() |> Map.put("refresh", true)
    assert %{"type" => "snapshot"} = answer(socket, 1)

    # The subscription hears the athanor's one feeds topic and no topic
    # built from its subject.
    held = Registry.keys(Cyfr.PubSub, Socket.state(socket).subs[1].forwarder)
    assert Cyfr.Bus.feeds(actor) in held
    refute Enum.any?(held, &String.contains?(&1, "btc"))

    # The other feed's result goes first: had it passed, it would arrive
    # first.
    published(actor, "eth", 5, 33)
    published(actor, "btc", 6, 44)

    assert %{"type" => "event", "data" => %{"feed" => "btc", "revision" => 6} = live} =
             answer(socket, 1)

    assert live["result"] == %{"price" => 44}
    refute Map.has_key?(live, "refresh")
  end

  defp published(actor, feed, revision, price) do
    :ok =
      Cyfr.Bus.broadcast(
        actor,
        Cyfr.Bus.feeds(actor),
        Cyfr.Bus.FeedPublished.new(actor, envelope(feed, revision, price))
      )
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

    actor = Sanctum.Context.actor(ctx)

    {:ok, row} =
      Arca.CronSchedule.create_feed(actor, %{
        binding: binding,
        resolved_reference: "catalyst:local.markets:1.0.0",
        profile_id: "prof_sock_feed",
        cap: 1_000
      })

    {:ok, slot} = Arca.ControlPlane.member_slot()
    {:ok, seq} = Arca.CronSchedule.claim_feed_seq(actor, row.id)

    {:ok, envelope} =
      Opus.Feeds.accept(ctx, row.id, seq, %{"status" => 200, "data" => %{"price" => price}}, slot)

    envelope
  end

  # ---------------------------------------------------------------------------
  # The frame's flows
  # ---------------------------------------------------------------------------

  test "an app that connects to an origin opens a stream only while its grant lets what the stream carries flow there",
       %{source: source} do
    name = "sock-flow-#{System.unique_integer([:positive])}"
    digest = app!(source, name, [%{"name" => "mcp_servers.changes"}], [@origin])

    # The grant the frame opens under declares no flow.
    refused = frame!(source, name, digest)
    socket = Socket.connect(:shared)
    Socket.subscribe(socket, 1, refused.bearer, "mcp_servers.changes")

    assert %{"type" => "ended", "error" => %{"class" => "forbidden", "message" => message}} =
             answer(socket, 1)

    assert message == Prima.Flow.sentence([:outside], @origin)
    assert stream_decisions() == []

    # Granted again with what the stream carries let flow to the origin, a
    # frame opened under it subscribes through the gate.
    grant_flows!(source, name, [{:outside, @origin}])
    frame = frame!(source, name, digest)
    socket = Socket.connect(:shared)
    Socket.subscribe(socket, 1, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 1)
    assert [%{tool: "stream:mcp_servers.changes", admission: "admitted"}] = stream_decisions()

    # The grant rewritten in place, at the revision the frame names, to
    # declare no flow: the connection's next revalidation ends the
    # subscription with the flow's refusal.
    policy = policy(name, [])

    :ok =
      Sanctum.Test.ConsentFixtures.hand_edit_head!(
        source,
        profile_id(name),
        resolved_policy: policy,
        blob_digest: Prima.Digest.sha256(policy)
      )

    assert %{"type" => "ended", "error" => %{"class" => "forbidden", "message" => ^message}} =
             answer(socket, 1)

    wait_until(fn -> listeners(source) == 0 end, @answer_ms)
  end

  # The owner grant `frame!/4` opens `name` under, granted again at its
  # revision with its own node's ingress edge declaring `flows`
  # (`{class, origin}` pairs).
  defp grant_flows!(source, name, flows) do
    node = "tincture:local.#{name}"
    {:ok, %{revision: revision}} = Sanctum.Consent.tincture_grant(source, "#{node}:#{@version}")

    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        source,
        %{id: profile_id(name), kind: :owner, source_ref: node, label: "owner", status: :active},
        %{
          id: "cons_#{profile_id(name)}_flows",
          revision: revision,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: :live,
          commit_digest: "sha256:commit",
          resolved_policy: policy(name, flows),
          activation: %{node => "sha256:act"}
        }
      )
  end

  # `Sanctum.Test.ConsentFixtures.grant_tincture!/3`'s profile of `name`.
  defp profile_id(name), do: "prof_" <> String.replace(name, "-", "_")

  # A grant of the tincture `name` whose own node's ingress edge declares
  # `flows` and nothing else.
  defp policy(name, flows) do
    ingress =
      if flows == [],
        do: %{},
        else: %{
          "flows" =>
            Enum.map(flows, fn {class, to} -> %{"from" => Atom.to_string(class), "to" => to} end)
        }

    Jason.encode!(%{
      "canonical" => "jcs-1",
      "nodes" => %{
        "tincture:local.#{name}" => %{
          "limits" => Prima.Test.AuthorityFixtures.limits_map(),
          "edges" => %{"@ingress" => ingress}
        }
      }
    })
  end

  # ---------------------------------------------------------------------------
  # A validation trial
  # ---------------------------------------------------------------------------

  test "a validation trial is answered from fixtures, through no gate, and holds no place",
       %{source: source} do
    [%Prima.Provider.Stream{name: shaped, shape: shape} | _] = shaped_streams()
    name = "sock-trial-#{System.unique_integer([:positive])}"
    digest = canvas!(source, name, %{"data" => [shaped, "mcp_servers.changes"]})
    frame = frame!(source, name, digest, validation: true)
    socket = Socket.connect({:canvas, frame.frame_id})

    # A shaped stream answers its shape's fixture; a shapeless one nothing.
    Socket.subscribe(socket, 1, frame.bearer, shaped)
    assert %{"type" => "subscribed"} = answer(socket, 1)
    fixture = Shape.fixture(shape)
    assert %{"type" => "event", "stream" => ^shaped, "data" => ^fixture} = answer(socket, 1)
    assert %{"revision" => 0, "at" => "1970-01-01T00:00:00Z"} = fixture
    assert answer(socket, 1) == TinctureWire.snapshot(1, ~U[1970-01-01 00:00:00Z])
    assert %{"type" => "ended"} = answer(socket, 1)

    Socket.subscribe(socket, 2, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 2)
    assert %{"type" => "ended"} = answer(socket, 2)

    assert Socket.state(socket).subs == %{}
    assert listeners(source) == 0

    refute Arca.Repo.exists?(
             from(d in Arca.Schemas.DecisionLog,
               where: d.tool == ^"stream:#{shaped}" and d.user_id == ^source.user_id
             )
           )
  end

  test "a validation trial's feed results are the bound feed's envelope, its result the fixture of the binding's result shape",
       %{source: source} do
    name = "sock-feed-trial-#{System.unique_integer([:positive])}"
    digest = canvas!(source, name, %{"feeds" => ["btc", "eth"]})
    frame = frame!(source, name, digest, validation: true)
    binding = feed_binding("btc")

    {:ok, feed} =
      Arca.CronSchedule.create_feed(Sanctum.Context.actor(source), %{
        binding: binding,
        resolved_reference: "catalyst:local.markets:1.0.0",
        profile_id: "prof_canvas_feed",
        cap: 1_000
      })

    socket = Socket.connect({:canvas, frame.frame_id})
    Socket.subscribe(socket, 1, frame.bearer, "feed.results", "btc")
    assert %{"type" => "subscribed"} = answer(socket, 1)

    assert %{"type" => "event", "stream" => "feed.results", "subject" => "btc", "id" => nil} =
             event = answer(socket, 1)

    # The binding's envelope at its first revision and the epoch, its
    # result the fixture of the binding's result shape.
    result = Shape.fixture(binding.result_shape)
    envelope = Prima.Feed.envelope(feed.id, binding, 0, ~U[1970-01-01 00:00:00Z], result)
    assert event["data"] == envelope |> Jason.encode!() |> Jason.decode!()
    assert Shape.check(binding.result_shape, event["data"]["result"]) == :ok
    refute Enum.any?(~w(operation args reference), &Map.has_key?(event["data"], &1))
    assert TinctureWire.snapshot(1, ~U[1970-01-01 00:00:00Z]) == answer(socket, 1)
    assert TinctureWire.ended(1, nil) == answer(socket, 1)

    # A name the canvas declares and the athanor does not bind: no event.
    Socket.subscribe(socket, 2, frame.bearer, "feed.results", "eth")
    assert %{"type" => "subscribed"} = answer(socket, 2)
    assert TinctureWire.snapshot(2, ~U[1970-01-01 00:00:00Z]) == answer(socket, 2)
    assert TinctureWire.ended(2, nil) == answer(socket, 2)

    # A name the canvas does not declare is refused by its declaration.
    Socket.subscribe(socket, 3, frame.bearer, "feed.results", "doge")
    assert %{"type" => "ended", "error" => %{"class" => "forbidden"}} = answer(socket, 3)

    assert Socket.state(socket).subs == %{}
    assert stream_decisions() == []
  end

  test "a validation trial's feed results are refused unavailable when the feeds cannot be read",
       %{source: source} do
    name = "sock-feed-outage-#{System.unique_integer([:positive])}"
    frame = frame!(source, name, canvas!(source, name, %{"feeds" => ["btc"]}), validation: true)

    # The feeds' table fails, and the test's transaction gives it back.
    Arca.Repo.query!("ALTER TABLE cron_schedules RENAME TO cron_schedules_unavailable")
    socket = Socket.connect({:canvas, frame.frame_id})
    Socket.subscribe(socket, 1, frame.bearer, "feed.results", "btc")

    # Refused before anything opened, not answered with nothing.
    assert %{"type" => "ended", "error" => %{"class" => "unavailable"}} = answer(socket, 1)
  end

  defp feed_binding(name) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => name,
        "label" => "Feed #{name}",
        "reference" => "catalyst:local.markets",
        "operation" => "quote",
        "args" => %{"symbol" => String.upcase(name)},
        "interval_minutes" => 5,
        "result_shape" => %{
          "type" => "object",
          "fields" => %{
            "price" => %{"type" => "number"},
            "at" => %{"type" => "time"},
            "tags" => %{"type" => "list", "of" => %{"type" => "string", "max" => 16}}
          },
          "required" => ["price"]
        },
        "actions" => [%{"name" => "refresh", "label" => "Refresh", "kind" => "refresh"}]
      })

    binding
  end

  # The catalog's canvas-readable streams that every frame opens with no
  # subject of its own.
  defp shaped_streams do
    for %Prima.Provider.Stream{shape: %{}, filter: nil} = stream <- Sanctum.Catalog.streams(),
        do: stream
  end

  # ---------------------------------------------------------------------------
  # Over a real listener
  # ---------------------------------------------------------------------------

  describe "over a real listener" do
    setup do
      {:ok, server} =
        start_supervised(
          {Bandit,
           plug: CyfrWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      {:ok, port: port}
    end

    test "eight streams share one connection, each opened", %{source: source, port: port} do
      names = shaped_streams() |> Enum.map(& &1.name) |> Enum.sort() |> Enum.take(8)
      assert length(names) == 8
      frame = canvas_frame!(source, %{"data" => names})

      socket = Socket.ws_open(port, TinctureWire.socket_path(frame.frame_id))
      on_exit(fn -> :gen_tcp.close(socket) end)

      for {name, sub} <- Enum.with_index(names, 1) do
        :ok =
          Socket.ws_send(
            socket,
            Jason.encode!(TinctureWire.subscribe(sub, frame.bearer, name, nil))
          )
      end

      opened =
        Stream.repeatedly(fn -> Socket.ws_recv(socket) end)
        |> Stream.map(fn {1, json} -> Jason.decode!(json) end)
        |> Stream.filter(&(&1["type"] in ["subscribed", "ended"]))
        |> Enum.take(8)

      assert Enum.all?(opened, &(&1["type"] == "subscribed")), inspect(opened)
      assert opened |> Enum.map(& &1["sub"]) |> Enum.sort() == Enum.to_list(1..8)
    end

    # A valid subscription of exactly `bytes` bytes: its JSON, padded with
    # the whitespace JSON allows after a value.
    defp padded_subscribe(frame, bytes) do
      body = Jason.encode!(TinctureWire.subscribe(1, frame.bearer, "mcp_servers.changes", nil))
      body <> String.duplicate(" ", bytes - byte_size(body))
    end

    @tag :capture_log
    test "the message-byte bound holds across WebSocket fragments", %{source: source, port: port} do
      frame = canvas_frame!(source)
      socket = Socket.ws_open(port, TinctureWire.socket_path(frame.frame_id))
      on_exit(fn -> :gen_tcp.close(socket) end)

      over = padded_subscribe(frame, TinctureWire.max_message_bytes() + 1)
      :ok = Socket.ws_send_fragments(socket, over, 2_048)
      assert {8, <<1009::16, _reason::binary>>} = Socket.ws_recv(socket)
    end

    test "a message exactly at the byte bound is accepted, whole or in fragments",
         %{source: source, port: port} do
      frame = canvas_frame!(source)
      bytes = TinctureWire.max_message_bytes()

      for send <- [&Socket.ws_send/2, &Socket.ws_send_fragments(&1, &2, 1_000)] do
        socket = Socket.ws_open(port, TinctureWire.socket_path(frame.frame_id))
        :ok = send.(socket, padded_subscribe(frame, bytes))
        assert {1, json} = Socket.ws_recv(socket)
        assert %{"type" => "subscribed", "sub" => 1} = Jason.decode!(json)
        :gen_tcp.close(socket)
      end
    end

    @tag :capture_log
    test "a single frame one byte over the bound closes the connection",
         %{source: source, port: port} do
      frame = canvas_frame!(source)
      socket = Socket.ws_open(port, TinctureWire.socket_path(frame.frame_id))
      on_exit(fn -> :gen_tcp.close(socket) end)

      :ok = Socket.ws_send(socket, padded_subscribe(frame, TinctureWire.max_message_bytes() + 1))
      assert {8, <<1009::16, _reason::binary>>} = Socket.ws_recv(socket)
    end

    # The listener logs the frame it refused.
    @tag :capture_log
    test "a message over the wire's bound closes the connection", %{source: source, port: port} do
      frame = canvas_frame!(source)
      socket = Socket.ws_open(port, TinctureWire.socket_path(frame.frame_id))
      on_exit(fn -> :gen_tcp.close(socket) end)

      :ok = Socket.ws_send(socket, String.duplicate("x", TinctureWire.max_message_bytes() + 1))
      assert {8, <<1009::16, _reason::binary>>} = Socket.ws_recv(socket)
    end
  end

  defp person!(namespace) do
    {person, user} =
      Sanctum.TestContext.person!(%{
        Sanctum.TestContext.local()
        | user_id: "local|local|#{namespace}",
          namespace: namespace
      })

    own = Sanctum.Test.People.athanor!(user)
    issuer = Sanctum.TestContext.issuer!(%{person | athanor_id: own.id})
    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, ctx} = Sanctum.Caller.establish(session.token)
    ctx
  end
end
