# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.FrameSocketTest do
  @moduledoc """
  A frame's stream connection (`Emissary.Web.FrameSocket`): one
  connection carries every stream a frame subscribes to, each answered
  `subscribed` and its events tagged with its stream and subject; an
  unsubscribed stream frees its place at once, so a frame at the cap opens
  the next immediately; the connection carries at most the wire's
  subscriptions and is one frame's, a canvas's on its own path alone;
  a message that does not read closes it, one whose number reads refuses
  that subscription alone; a frame's suspension ends each subscription at
  its announcement; a newer connection of the frame replaces the older, an
  idle one closes; each subscribe's bearer is read as a request's, while
  an admitted subscription is held to the row up to its own bound; a
  validation trial is answered from fixtures and holds nothing; and over
  a real listener eight streams share one connection, and a message over
  the wire's bound closes it.
  """

  # Mints and suspends frame credentials, writes platform settings and
  # meters rates, all of them process-wide.
  use CyfrWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Cyfr.Test.FrameSocket, as: Socket
  alias Emissary.Web.FrameSocket
  alias Prima.TinctureWire
  alias Sanctum.TinctureAuth

  @version "1.0.0"

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

  defp canvas!(ctx, name, data) do
    put_version!(ctx, name, %{
      "name" => name,
      "type" => "tincture",
      "version" => @version,
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "desktop" => %{"data" => data}}
    })
  end

  defp app!(ctx, name, streams) do
    put_version!(ctx, name, %{
      "name" => name,
      "type" => "tincture",
      "version" => @version,
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "streams" => streams}
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

  defp canvas_frame!(source, data \\ ["mcp_servers.changes"]) do
    name = "sock-canvas-#{System.unique_integer([:positive])}"
    frame!(source, name, canvas!(source, name, data))
  end

  defp topic(source), do: Cyfr.Bus.mcp_servers(Sanctum.Context.actor(source))

  defp listeners(source), do: length(Registry.lookup(Cyfr.PubSub, topic(source)))

  defp changed(source) do
    actor = Sanctum.Context.actor(source)
    :ok = Cyfr.Bus.broadcast(actor, topic(source), Cyfr.Bus.McpServers.new(actor, :changed))
  end

  defp answer(socket, sub) do
    assert_receive {:socket, ^socket, %{"sub" => ^sub} = message}, @answer_ms
    message
  end

  # ---------------------------------------------------------------------------
  # One connection, many streams
  # ---------------------------------------------------------------------------

  test "a subscription is answered subscribed, and its events arrive tagged with its stream and subject",
       %{source: source} do
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})

    Socket.subscribe(socket, 1, frame.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 1)
    wait_until(fn -> listeners(source) == 1 end, @answer_ms)

    changed(source)

    assert %{
             "type" => "event",
             "stream" => "mcp_servers.changes",
             "subject" => nil,
             "id" => nil,
             "data" => %{"kind" => "changed"} = data
           } = answer(socket, 1)

    refute Map.has_key?(data, "athanor_id")

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

    assert %{"type" => "ended", "error" => %{"class" => "rate_limited"}} =
             answer(socket, max + 1)

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

  test "a frame's suspension ends every subscription at its announcement", %{source: source} do
    bound = Application.get_env(:sanctum, :caller_memo_ttl_ms)

    on_exit(fn ->
      if bound,
        do: Application.put_env(:sanctum, :caller_memo_ttl_ms, bound),
        else: Application.delete_env(:sanctum, :caller_memo_ttl_ms)
    end)

    # A freshness bound no case outlasts: only the announcement can end
    # the subscriptions within this case.
    Application.put_env(:sanctum, :caller_memo_ttl_ms, 600_000)

    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})

    for sub <- [1, 2] do
      Socket.subscribe(socket, sub, frame.bearer, "mcp_servers.changes")
      assert %{"type" => "subscribed"} = answer(socket, sub)
    end

    {:ok, _} = TinctureAuth.suspend_frame(source, frame.id)

    for sub <- [1, 2] do
      assert %{"type" => "ended", "error" => %{"class" => "forbidden"}} = answer(socket, sub)
    end

    wait_until(fn -> listeners(source) == 0 end, @answer_ms)
    assert Socket.state(socket).subs == %{}
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

    assert %{"type" => "ended", "error" => %{"class" => "forbidden", "message" => message}} =
             answer(socket, 2)

    assert message =~ "frame_connection_mismatch"

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
    assert %{"type" => "ended", "error" => %{"message" => message}} = answer(socket, 1)
    assert message =~ "frame_path_mismatch"

    socket = Socket.connect({:canvas, an_app.frame_id})
    Socket.subscribe(socket, 1, an_app.bearer, "mcp_servers.changes")
    assert %{"type" => "ended", "error" => %{"message" => message}} = answer(socket, 1)
    assert message =~ "not_a_canvas"

    socket = Socket.connect({:canvas, mine.frame_id})
    Socket.subscribe(socket, 1, mine.bearer, "mcp_servers.changes")
    assert %{"type" => "subscribed"} = answer(socket, 1)
  end

  test "a stream the frame does not declare is refused, recorded, and holds nothing",
       %{source: source} do
    frame = canvas_frame!(source)
    socket = Socket.connect({:canvas, frame.frame_id})

    Socket.subscribe(socket, 1, frame.bearer, "confirmation.changes")

    assert %{"type" => "ended", "error" => %{"class" => "forbidden", "message" => message}} =
             answer(socket, 1)

    assert message =~ "does not declare that stream"
    assert Socket.state(socket).subs == %{}

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
  # A validation trial
  # ---------------------------------------------------------------------------

  test "a validation trial is answered from fixtures, through no gate, and holds no place",
       %{source: source} do
    [%Prima.Provider.Stream{name: shaped, shape: shape} | _] = shaped_streams()
    name = "sock-trial-#{System.unique_integer([:positive])}"
    digest = canvas!(source, name, [shaped, "mcp_servers.changes"])
    frame = frame!(source, name, digest, validation: true)
    socket = Socket.connect({:canvas, frame.frame_id})

    # A shaped stream answers its shape's fixture; a shapeless one nothing.
    Socket.subscribe(socket, 1, frame.bearer, shaped)
    assert %{"type" => "subscribed"} = answer(socket, 1)
    fixture = Prima.Canvas.Shape.fixture(shape)
    assert %{"type" => "event", "stream" => ^shaped, "data" => ^fixture} = answer(socket, 1)
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
      frame = canvas_frame!(source, names)

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
