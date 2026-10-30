# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CanvasLiveTest do
  @moduledoc """
  The canvas layer draws the person's layout for the posture their client
  reports, and the shell holds the frames that arrangement places over the
  visible canvas: its frame narrowed by its tiles, each window at its
  geometry and each tile at its edge and share, stacked by their order;
  nothing for a minimised app or a tincture nobody installed. In the hand
  every app is full. A posture report that is neither `hand` nor `desk`
  is ignored. The shelf carries a dot per canvas
  for more than one canvas. Opening a full frame over the canvas
  freezes the frames beneath it, and closing it lets them run again. The
  frames' wrappers are a stream, after only the layer's always-present
  elements, and a frame discarded leaves the others where they were: every
  update streams each held frame, deletes only the wrappers of frames no
  longer held, and never resets.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "canvas_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry()
    end)

    {:ok, conn: conn, user: user, ctx: ctx}
  end

  # A tincture version committed in the athanor's tree and its component row, with
  # `tincture` its manifest's block and `files` its files.
  defp lay!(ctx, name, tincture, files) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => tincture
    }

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, "1.0.0",
      manifest: manifest,
      files: files
    )

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|#{ctx.namespace}",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    Sanctum.Test.ConsentFixtures.grant_tincture!(ctx, "tincture:local.#{name}")
    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
    :ok
  end

  defp tincture!(ctx, name, frame \\ %{}) do
    lay!(ctx, name, %{"entry" => "index.html", "frame" => frame}, [
      {"index.html", "<html><head></head><body>#{name}</body></html>"}
    ])
  end

  defp canvas!(ctx, name) do
    lay!(
      ctx,
      name,
      %{
        "frame" => %{"placement" => "canvas"},
        "entry" => "index.html",
        "streams" => []
      },
      [{"index.html", "<html><head></head><body>canvas</body></html>"}]
    )

    {:ok, _} =
      Arca.CanvasVersions.publish(
        Sanctum.Context.actor(ctx),
        name,
        %{Arca.CanvasVersions.empty() | working: "1.0.0"},
        0
      )
  end

  defp layout!(ctx, user, canvases) do
    {:ok, layout} = Prima.Layout.validate(%{"version" => 3, "canvases" => canvases})
    {:ok, _revision} = Arca.Layouts.publish(Sanctum.Context.actor(ctx), user.user_id, layout, 0)
    :ok
  end

  defp app(tincture, placement, order, minimised \\ false) do
    %{
      "tincture" => tincture,
      "placement" => placement,
      "order" => order,
      "minimised" => minimised
    }
    |> Map.merge(
      case placement do
        "window" -> %{"geometry" => %{"x" => 2500, "y" => 5000, "w" => 3000, "h" => 4000}}
        "tile" -> %{"side" => "right", "share" => 2500}
        "full" -> %{}
      end
    )
  end

  # Desk: a window, a minimised full app, a window nobody installed, a
  # tile and a minimised window. Hand: one window of another tincture. A second
  # canvas places nothing.
  defp canvases do
    [
      %{
        "id" => "home",
        "tincture" => "tincture:local.markets",
        "postures" => %{
          "desk" => %{
            "apps" => [
              app("tincture:local.slot-dash", "window", 0),
              app("tincture:local.icon-dash", "full", 1, true),
              app("tincture:acme.gone", "window", 2),
              app("tincture:local.tile-dash", "tile", 3),
              app("tincture:local.hidden-dash", "window", 4, true)
            ]
          },
          "hand" => %{"apps" => [app("tincture:local.icon-dash", "window", 0)]}
        }
      },
      %{"id" => "work", "tincture" => "tincture:local.notes-canvas", "postures" => %{}}
    ]
  end

  defp installed!(ctx) do
    canvas!(ctx, "markets")
    canvas!(ctx, "notes-canvas")
    tincture!(ctx, "slot-dash")
    tincture!(ctx, "icon-dash")
    tincture!(ctx, "tile-dash")
    tincture!(ctx, "hidden-dash")
  end

  defp frames(view), do: :sys.get_state(view.pid).socket.assigns.frames

  # The opening tag of the wrapper around frame `frame_id`.
  defp wrapper_tag(html, frame_id) do
    [tag] = Regex.run(~r/<div[^>]*data-canvas-frame="#{frame_id}"[^>]*>/, html)
    tag
  end

  defp by_key(view, key), do: Prism.Frames.get(frames(view), key)

  defp row(frame_id) do
    Arca.Repo.one(from(f in Arca.Schemas.FrameCredential, where: f.frame_id == ^frame_id))
  end

  defp rows, do: Arca.Repo.all(Arca.Schemas.FrameCredential)

  defp bearer!(view, frame_id) do
    render_hook(view, "frame_handshake", %{"frame" => frame_id})
    assert_reply(view, %{credential: bearer})
    bearer
  end

  defp posture!(view, posture),
    do: view |> element("#canvas-hook") |> render_hook("posture", %{"posture" => posture})

  # The person's layout published again over `revision`, as the bus tells
  # the shell.
  defp relayout!(view, ctx, user, canvases, revision) do
    actor = Sanctum.Context.actor(ctx)
    {:ok, layout} = Prima.Layout.validate(%{"version" => 3, "canvases" => canvases})
    {:ok, next} = Arca.Layouts.publish(actor, user.user_id, layout, revision)
    send(view.pid, Cyfr.Bus.LayoutPublished.new(actor, user.user_id, next))
  end

  # The person's stored layout no longer holds its digest: every read of it
  # answers an error.
  defp break_layout!(ctx, user) do
    key = Arca.Layouts.key(user.user_id)

    {1, _} =
      Arca.Repo.update_all(
        from(d in Arca.Schemas.FencedDocument,
          where: d.athanor_id == ^ctx.athanor_id and d.key == ^key
        ),
        set: [digest: "sha256:" <> String.duplicate("0", 64)]
      )
  end

  # The canvas layer's children in document order: each by its id, the
  # layout note by its data attribute.
  defp layer(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#canvas > *")
    |> Enum.map(fn child ->
      case LazyHTML.attribute(child, "id") do
        [id] -> id
        [] -> if LazyHTML.attribute(child, "data-canvas-layout") != [], do: "layout-note"
      end
    end)
  end

  # The children of the canvas layer's stream container in document order:
  # each one's id and frame, and its iframe's id and src.
  defp wrappers(view) do
    html = view |> render() |> LazyHTML.from_fragment()
    assert LazyHTML.attribute(LazyHTML.query(html, "#canvas-frames"), "phx-update") == ["stream"]

    html
    |> LazyHTML.query("#canvas-frames > *")
    |> Enum.map(fn child ->
      iframe = LazyHTML.query(child, "iframe")

      {LazyHTML.attribute(child, "id"), LazyHTML.attribute(child, "data-canvas-frame"),
       LazyHTML.attribute(iframe, "id"), LazyHTML.attribute(iframe, "src")}
    end)
  end

  defp wrapper(frame), do: {["canvas-frame-#{frame.id}"], [frame.id], [frame.id], [frame.src]}

  # A frame as the layer's stream reads it: its id, its key and its state.
  defp held_frame(name, state \\ :live),
    do: %{id: "frm_#{name}", key: {:app, "home", "tincture:local.#{name}"}, state: state}

  defp holding(frames) do
    %Prism.Frames{
      Prism.Frames.new()
      | frames: Map.new(frames, &{&1.key, &1}),
        order: Enum.map(frames, & &1.key)
    }
  end

  # The canvas layer's socket, as LiveView mounts a component's.
  defp layer_socket do
    socket = %Phoenix.LiveView.Socket{
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }

    {:ok, socket} = PrismWeb.CanvasLive.mount(socket)
    socket
  end

  # One update of the layer with `frames` held, and what its stream sends
  # for it: whether it resets, the wrappers it deletes, and the wrappers it
  # inserts in order, each with its position and its frame's state. The
  # stream's pending changes are then dropped, as LiveView drops them once
  # it has rendered them.
  defp update!(socket, ctx, frames) do
    assigns = %{
      id: "canvas",
      context: ctx,
      frames: holding(frames),
      tinctures: []
    }

    {:ok, socket} = PrismWeb.CanvasLive.update(assigns, socket)
    stream = socket.assigns.streams.frames

    inserts =
      for {id, at, frame, _limit, _update_only} <- Enum.reverse(stream.inserts),
          do: {id, at, frame.state}

    sent = %{reset: stream.reset?, deletes: Enum.sort(stream.deletes), inserts: inserts}

    deleted = MapSet.new(sent.deletes)
    assert Enum.all?(sent.inserts, fn {id, _at, _state} -> not MapSet.member?(deleted, id) end)

    {sent, update_in(socket.assigns.streams.frames, &Phoenix.LiveView.LiveStream.prune/1)}
  end

  defp streamed(frame, state \\ :live), do: {"canvas-frame-#{frame.id}", -1, state}

  test "the desk arrangement is drawn and its frames are held", %{
    conn: conn,
    ctx: ctx,
    user: user
  } do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/canvas")
    html = render(view)

    # The canvas fills the layer under everything placed over it.
    canvas = by_key(view, {:canvas, "home"})
    assert %{state: :live, visible: true, placement: :canvas} = canvas
    assert html =~ ~r/data-canvas-place="canvas"[^>]*>\s*<iframe[^>]*id="#{canvas.id}"/

    # A window is its tincture's own frame, at its geometry and stack.
    column = by_key(view, {:app, "home", "tincture:local.slot-dash"})

    assert %{
             state: :live,
             visible: true,
             placement: {:window, %{x: 2500, y: 5000, w: 3000, h: 4000}},
             stack: 0
           } = column

    assert row(column.id).state == "active"
    window = wrapper_tag(html, column.id)
    assert window =~ ~s(data-canvas-place="window")
    assert window =~ ~s(data-canvas-geometry="2500 5000 3000 4000")
    assert window =~ ~s(data-canvas-stack="0")
    assert window =~ "left: 25.00%; top: 50.00%; width: 30.00%; height: 40.00%; z-index: 30;"

    # A tile stands at its edge and share, and narrows the canvas beside it.
    tile = by_key(view, {:app, "home", "tincture:local.tile-dash"})
    assert %{state: :live, visible: true, placement: {:tile, :right, 2500}, stack: 3} = tile
    tiled = wrapper_tag(html, tile.id)
    assert tiled =~ ~s(data-canvas-place="tile")
    assert tiled =~ ~s(data-canvas-side="right")
    assert tiled =~ ~s(data-canvas-share="2500")
    assert tiled =~ "left: 75.00%; width: 25.00%; z-index: 20;"
    assert wrapper_tag(html, canvas.id) =~ "left: 0.00%; right: 25.00%;"

    # A minimised app, full or not, is not opened with the canvas, and the
    # canvas, the window and the tile are all that were.
    assert by_key(view, {:app, "home", "tincture:local.icon-dash"}) == nil
    assert by_key(view, {:app, "home", "tincture:local.hidden-dash"}) == nil
    assert length(rows()) == 3

    # In the order they were opened: what the layout places, then the canvas.
    assert Enum.map(Prism.Frames.list(frames(view)), & &1.tincture_id) == [
             "iframe_slot-dash",
             "iframe_tile-dash",
             "iframe_markets"
           ]
  end

  test "the frames are a stream whose only earlier siblings are always present",
       %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/canvas")
    [first, middle, last] = held = Prism.Frames.list(frames(view))
    assert middle.key == {:app, "home", "tincture:local.tile-dash"}

    # Every frame's wrapper, and only those, in the order it was opened.
    assert wrappers(view) == Enum.map(held, &wrapper/1)

    # The middle frame of three discarded: the other two keep their ids,
    # their src and their order.
    [home, work] = canvases()

    home =
      update_in(home, ["postures", "desk", "apps"], fn apps ->
        Enum.reject(apps, &(&1["tincture"] == "tincture:local.tile-dash"))
      end)

    relayout!(view, ctx, user, [home, work], 1)

    wait_until(
      fn -> render(view) && by_key(view, middle.key) == nil end,
      2_000,
      "the tile's frame discarded"
    )

    assert row(middle.id).state == "revoked"
    assert Enum.map(Prism.Frames.list(frames(view)), & &1.id) == [first.id, last.id]
    assert wrappers(view) == [wrapper(first), wrapper(last)]

    # The layout note drawn: the container's only earlier siblings are the
    # geometry and status elements.
    break_layout!(ctx, user)
    posture!(view, "hand")

    {earlier, ["canvas-frames" | later]} =
      Enum.split_while(layer(view), &(&1 != "canvas-frames"))

    assert earlier == ["canvas-geometry", "canvas-status"]
    assert "layout-note" in later
    assert "canvas-shelf" in later
    assert wrappers(view) == [wrapper(first), wrapper(last)]
  end

  test "each update streams every held frame, deletes only the wrappers of frames no longer held, and never resets",
       %{ctx: ctx} do
    [a, b, c, d] = Enum.map(~w(a b c d), &held_frame/1)

    # The first update: every frame, in the order it was opened.
    {sent, socket} = update!(layer_socket(), ctx, [a, b, c])
    assert sent == %{reset: false, deletes: [], inserts: [streamed(a), streamed(b), streamed(c)]}

    # The same frames, one of them frozen: each updated where it stands.
    {sent, socket} = update!(socket, ctx, [a, %{b | state: :frozen}, c])

    assert sent == %{
             reset: false,
             deletes: [],
             inserts: [streamed(a), streamed(b, :frozen), streamed(c)]
           }

    # The middle frame discarded: its wrapper alone is deleted.
    {sent, socket} = update!(socket, ctx, [a, c])

    assert sent == %{
             reset: false,
             deletes: ["canvas-frame-frm_b"],
             inserts: [streamed(a), streamed(c)]
           }

    # A new frame opened: inserted after the others.
    {sent, _socket} = update!(socket, ctx, [a, c, d])
    assert sent == %{reset: false, deletes: [], inserts: [streamed(a), streamed(c), streamed(d)]}
  end

  test "a minimised app is not opened with the canvas", %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/canvas")

    assert by_key(view, {:app, "home", "tincture:local.hidden-dash"}) == nil
    refute Enum.any?(Prism.Frames.list(frames(view)), &(&1.tincture_id == "iframe_hidden-dash"))
    assert length(Regex.scan(~r/<iframe /, render(view))) == 3
  end

  test "a layout naming only uninstalled tinctures opens nothing",
       %{conn: conn, ctx: ctx, user: user} do
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/canvas")
    html = render(view)

    refute html =~ "<iframe"
    assert Prism.Frames.list(frames(view)) == []
    assert rows() == []
  end

  test "the hand posture swaps the arrangement, and an unknown posture is ignored",
       %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/canvas")
    desk_column = by_key(view, {:app, "home", "tincture:local.slot-dash"})
    desk_tile = by_key(view, {:app, "home", "tincture:local.tile-dash"})
    canvas = by_key(view, {:canvas, "home"})

    posture!(view, "tablet")
    posture!(view, "HAND")
    html = render(view)
    assert html =~ ~s(data-posture="desk")
    assert by_key(view, {:app, "home", "tincture:local.slot-dash"}).id == desk_column.id

    posture!(view, "hand")
    html = render(view)
    assert html =~ ~s(data-posture="hand")

    # In the hand every app is full, whatever the layout stores for it.
    pocket = by_key(view, {:app, "home", "tincture:local.icon-dash"})
    assert %{tincture_id: "iframe_icon-dash", state: :live, placement: :full} = pocket
    assert by_key(view, {:app, "home", "tincture:local.slot-dash"}) == nil
    assert by_key(view, {:app, "home", "tincture:local.tile-dash"}) == nil
    assert row(desk_column.id).state == "revoked"
    assert row(desk_tile.id).state == "revoked"

    # The canvas is kept across postures.
    assert by_key(view, {:canvas, "home"}).id == canvas.id
  end

  test "a full frame over the canvas freezes what it covers, and closing it lets it run",
       %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/canvas")
    column = by_key(view, {:app, "home", "tincture:local.slot-dash"})
    canvas = by_key(view, {:canvas, "home"})
    bearer = bearer!(view, column.id)
    assert {:ok, _} = Sanctum.TinctureAuth.verify_frame_credential(bearer)

    render_hook(view, "frame_verb", %{
      "frame" => canvas.id,
      "message" =>
        Prima.TinctureWire.shell_message(:open, canvas.id, %{"ref" => "tincture:local.icon-dash"})
    })

    assert %{placement: :full, visible: true} =
             by_key(view, {:app, "home", "tincture:local.icon-dash"})

    assert %{state: :frozen, visible: false} = by_key(view, column.key)
    assert {:error, :suspended} = Sanctum.TinctureAuth.verify_frame_credential(bearer)
    assert %{state: :frozen} = by_key(view, {:app, "home", "tincture:local.tile-dash"})
    assert %{state: :frozen} = by_key(view, {:canvas, "home"})
    column_id = column.id
    assert_push_event(view, "frame_state", %{frame: ^column_id, state: "frozen"})

    render_click(view, "close_active_tincture", %{})
    assert %{state: :live, visible: true} = by_key(view, column.key)
    assert {:ok, _} = Sanctum.TinctureAuth.verify_frame_credential(bearer)
    assert_push_event(view, "frame_state", %{frame: ^column_id, state: "live"})
  end

  test "the shelf carries a dot per canvas when there is more than one",
       %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/canvas")

    assert has_element?(
             view,
             ~s(#canvas-shelf #canvas-switcher button[data-canvas="home"][aria-pressed="true"])
           )

    assert has_element?(
             view,
             ~s(#canvas-shelf #canvas-switcher button[data-canvas="work"][aria-pressed="false"])
           )

    assert has_element?(
             view,
             ~s(#canvas-switcher button[phx-click="switch_canvas"][phx-value-canvas="work"])
           )

    # The edge strip is gone: the shelf takes its swipe. The apps stand
    # above the shelf.
    refute has_element?(view, "#canvas-edge-strip")
    assert has_element?(view, ~s(#canvas-frames[class*="bottom-[52px]"]))
  end

  test "a canvas placed as an app is refused, and mints nothing", %{
    conn: conn,
    ctx: ctx,
    user: user
  } do
    canvas!(ctx, "markets")
    canvas!(ctx, "notes-canvas")

    layout!(ctx, user, [
      %{
        "id" => "home",
        "tincture" => "tincture:local.markets",
        "postures" => %{
          "desk" => %{"apps" => [app("tincture:local.notes-canvas", "tile", 0)]}
        }
      }
    ])

    {view, _html} = mount_athanor(conn, "/canvas")

    assert %{state: :refused, refusal: :undeclared, credential_id: nil} =
             app = by_key(view, {:app, "home", "tincture:local.notes-canvas"})

    assert render(view) =~ ~s(id="tincture_state_#{app.id}")
    assert Enum.map(rows(), & &1.name) == ["markets"]
  end

  test "the shell ending revokes the layout's frames too", %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/canvas")
    ids = Enum.map(Prism.Frames.list(frames(view)), & &1.id)
    assert length(ids) == 3

    GenServer.stop(view.pid, :normal)
    for id <- ids, do: assert(row(id).state == "revoked")
  end

  test "the shell mounts the canvas and the system layer", %{conn: conn} do
    {_view, html} = mount_athanor(conn, "/canvas")

    assert html =~ ~s(id="canvas")
    assert html =~ ~s(phx-hook="Canvas")
    assert html =~ ~s(id="system-layer")
    assert html =~ ~s(data-posture="desk")
  end
end
