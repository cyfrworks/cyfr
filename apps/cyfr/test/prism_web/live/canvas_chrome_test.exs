# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CanvasChromeTest do
  @moduledoc """
  The chrome the shell draws around each window and tile, and the shelf.
  Each control of a title bar reaches the shell (`PrismWeb.ShellLive`) as
  its arrangement event and changes what the app stands as; the shelf
  lists the visible canvas's apps, the active one marked and a minimised
  one dimmed, and a click raises or restores one. However an app is
  raised, tiled or made full, its frame is the same frame: the same id and
  source, its wrapper where it was in the stream.
  """

  use PrismWeb.ConnCase, async: false

  alias Prism.Frames

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "canvas_chrome_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry()
    end)

    {:ok, conn: conn, user: user, ctx: ctx}
  end

  # A tincture version committed in the athanor's tree and its component
  # row, with `tincture` its manifest's block.
  defp lay!(ctx, name, tincture) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => tincture
    }

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, "1.0.0",
      manifest: manifest,
      files: [{"index.html", "<html><head></head><body>#{name}</body></html>"}]
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

  defp installed!(ctx) do
    lay!(ctx, "markets", %{
      "frame" => %{"placement" => "canvas"},
      "entry" => "index.html",
      "streams" => []
    })

    {:ok, _} =
      Arca.CanvasVersions.publish(
        Sanctum.Context.actor(ctx),
        "markets",
        %{Arca.CanvasVersions.empty() | working: "1.0.0"},
        0
      )

    for name <- ~w(slot-dash tile-dash hidden-dash),
        do: lay!(ctx, name, %{"entry" => "index.html", "frame" => %{}})
  end

  defp app(tincture, placement, order, minimised \\ false) do
    %{
      "tincture" => "tincture:local.#{tincture}",
      "placement" => placement,
      "order" => order,
      "minimised" => minimised
    }
    |> Map.merge(
      case placement do
        "window" -> %{"geometry" => %{"x" => 2500, "y" => 2000, "w" => 3000, "h" => 4000}}
        "tile" -> %{"side" => "right", "share" => 2500}
      end
    )
  end

  # The desk: a window under a tile, and a window kept minimised.
  defp layout!(ctx, user) do
    canvases = [
      %{
        "id" => "home",
        "tincture" => "tincture:local.markets",
        "postures" => %{
          "desk" => %{
            "apps" => [
              app("slot-dash", "window", 0),
              app("tile-dash", "tile", 1),
              app("hidden-dash", "window", 2, true)
            ]
          }
        }
      }
    ]

    {:ok, layout} = Prima.Layout.validate(%{"version" => 3, "canvases" => canvases})
    {:ok, _revision} = Arca.Layouts.publish(Sanctum.Context.actor(ctx), user.user_id, layout, 0)
    :ok
  end

  defp shell!(conn, ctx, user) do
    installed!(ctx)
    layout!(ctx, user)
    {view, _html} = mount_athanor(conn, "/tinctures")
    view
  end

  defp frames(view), do: :sys.get_state(view.pid).socket.assigns.frames

  defp app_frame(view, name),
    do: Frames.get(frames(view), {:app, "home", "tincture:local.#{name}"})

  defp control(view, frame, action),
    do: element(view, ~s(#canvas-frame-#{frame.id} [data-canvas-action="#{action}"]))

  # Every wrapper in the stream in document order, with its iframe's id and
  # source.
  defp wrappers(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#canvas-frames > *")
    |> Enum.map(fn child ->
      iframe = LazyHTML.query(child, "iframe")

      {LazyHTML.attribute(child, "id"), LazyHTML.attribute(iframe, "id"),
       LazyHTML.attribute(iframe, "src")}
    end)
  end

  test "a window and a tile wear the shell's chrome; the full frame its capsule", %{
    conn: conn,
    ctx: ctx,
    user: user
  } do
    view = shell!(conn, ctx, user)
    window = app_frame(view, "slot-dash")
    tile = app_frame(view, "tile-dash")

    # A title bar after the frame, with the app's name and its four controls.
    for frame <- [window, tile],
        action <- ~w(minimise full close),
        do: assert(has_element?(control(view, frame, action)))

    assert has_element?(
             view,
             ~s(#canvas-frame-#{window.id} [data-canvas-grip="#{window.id}"]),
             "slot-dash"
           )

    assert has_element?(control(view, window, "tile"))
    assert has_element?(control(view, tile, "window"))

    html = render(view)
    assert html =~ ~r/id="#{window.id}"[^>]*>(<\/iframe>)?\s*<div class="canvas-titlebar"/

    # A window is resized from eight edges and corners; a tile from its
    # inner divider alone.
    for edge <- ~w(n s e w ne nw se sw),
        do:
          assert(
            has_element?(
              view,
              ~s(#canvas-frame-#{window.id} .canvas-edge[data-canvas-edge="#{edge}"])
            )
          )

    assert has_element?(view, ~s(#canvas-frame-#{tile.id} .canvas-divider[data-canvas-edge="w"]))
    refute has_element?(view, ~s(#canvas-frame-#{tile.id} .canvas-edge))

    # The tile is the topmost app: the active one, ringed; what each takes
    # when it changes placement is rendered for the keys.
    assert has_element?(
             view,
             ~s(#canvas-frame-#{tile.id}.canvas-active[data-canvas-active="true"])
           )

    assert has_element?(view, ~s(#canvas-frame-#{window.id}[data-canvas-active="false"]))
    assert has_element?(view, ~s(#canvas-frame-#{window.id}[data-canvas-tile-share="3000"]))

    assert has_element?(
             view,
             ~s(#canvas-frame-#{tile.id}[data-canvas-window="6800 800 3000 7000"])
           )

    refute has_element?(view, ~s(#canvas-frame-#{window.id} [aria-label="Tincture controls"]))
  end

  test "each control of a title bar reaches the shell and changes what its app stands as", %{
    conn: conn,
    ctx: ctx,
    user: user
  } do
    view = shell!(conn, ctx, user)
    window = app_frame(view, "slot-dash")
    tile = app_frame(view, "tile-dash")

    # Tile or window toggles: the window, its middle on the left, tiles at
    # the left at its own width; the tile becomes a window where it stood.
    control(view, window, "tile") |> render_click()
    assert %{placement: {:tile, :left, 3000}} = app_frame(view, "slot-dash")

    control(view, tile, "window") |> render_click()

    assert %{placement: {:window, %{x: 6800, y: 800, w: 3000, h: 7000}}} =
             app_frame(view, "tile-dash")

    control(view, tile, "full") |> render_click()
    assert %{placement: :full} = app_frame(view, "tile-dash")

    control(view, window, "minimise") |> render_click()
    assert %{minimised: true, visible: false} = app_frame(view, "slot-dash")

    render_hook(view, "app_restore", %{"ref" => "tincture:local.slot-dash"})
    control(view, app_frame(view, "slot-dash"), "close") |> render_click()
    assert app_frame(view, "slot-dash") == nil
  end

  test "a title bar shows the app's name first and the title it set after it; the shelf shows the name alone",
       %{conn: conn, ctx: ctx, user: user} do
    view = shell!(conn, ctx, user)
    window = app_frame(view, "slot-dash")
    title = "Your vault: the names of your stored credentials and where each may go"

    render_hook(view, "frame_verb", %{
      "frame" => window.id,
      "message" => Prima.TinctureWire.shell_message(:title, window.id, %{"title" => title})
    })

    bar = ~s(#canvas-frame-#{window.id} [data-canvas-grip="#{window.id}"])
    assert has_element?(view, "#{bar} .canvas-app-name", "slot-dash")
    refute has_element?(view, "#{bar} .canvas-app-name", "Your vault")
    assert has_element?(view, ~s(#{bar} .canvas-app-title[title="#{title}"]), title)

    shelf = ~s(#canvas-shelf-apps [data-canvas-shelf-app="tincture:local.slot-dash"])
    assert has_element?(view, shelf, "slot-dash")
    refute has_element?(view, shelf, "Your vault")

    # A title that only repeats the name is not shown twice.
    render_hook(view, "frame_verb", %{
      "frame" => window.id,
      "message" => Prima.TinctureWire.shell_message(:title, window.id, %{"title" => "slot-dash"})
    })

    refute has_element?(view, "#{bar} .canvas-app-title")
  end

  test "the shelf lists the canvas's apps, the active one marked and a minimised one dimmed, and a click raises or restores",
       %{conn: conn, ctx: ctx, user: user} do
    view = shell!(conn, ctx, user)
    window = app_frame(view, "slot-dash")
    shelf = "#canvas-shelf #canvas-shelf-apps"

    assert has_element?(
             view,
             ~s(#{shelf} [data-canvas-shelf-app="tincture:local.tile-dash"][data-canvas-active="true"][aria-pressed="true"]),
             "tile-dash"
           )

    assert has_element?(
             view,
             ~s(#{shelf} [data-canvas-shelf-app="tincture:local.slot-dash"][data-canvas-active="false"][data-canvas-minimised="false"])
           )

    # Minimised in the layout and never opened: on the shelf, dimmed.
    assert has_element?(
             view,
             ~s(#{shelf} [data-canvas-shelf-app="tincture:local.hidden-dash"][data-canvas-minimised="true"])
           )

    assert app_frame(view, "hidden-dash") == nil

    # A click on the window raises it: it is the active one now.
    view
    |> element(~s(#{shelf} [data-canvas-shelf-app="tincture:local.slot-dash"]))
    |> render_click()

    assert has_element?(view, ~s(#canvas-frame-#{window.id}[data-canvas-active="true"]))

    assert has_element?(
             view,
             ~s(#{shelf} [data-canvas-shelf-app="tincture:local.slot-dash"][data-canvas-active="true"])
           )

    # A click on the minimised one restores it, opened and raised.
    view
    |> element(~s(#{shelf} [data-canvas-shelf-app="tincture:local.hidden-dash"]))
    |> render_click()

    assert %{minimised: false, visible: true} = hidden = app_frame(view, "hidden-dash")
    assert has_element?(view, ~s(#canvas-frame-#{hidden.id}[data-canvas-active="true"]))

    # Minimised through its chrome, it stays on the shelf, dimmed.
    control(view, hidden, "minimise") |> render_click()

    assert has_element?(
             view,
             ~s(#{shelf} [data-canvas-shelf-app="tincture:local.hidden-dash"][data-canvas-minimised="true"])
           )
  end

  test "an app's frame is the same frame across a raise, a tile and a full, its wrapper where it was in the stream",
       %{conn: conn, ctx: ctx, user: user} do
    view = shell!(conn, ctx, user)
    window = app_frame(view, "slot-dash")
    before = wrappers(view)
    assert {["canvas-frame-#{window.id}"], [window.id], [window.src]} in before

    for {event, params} <- [
          {"frame_raise", %{}},
          {"frame_tile", %{"side" => "left", "share" => 3000}},
          {"frame_raise", %{}},
          {"frame_full", %{}},
          {"frame_move", %{"geometry" => %{"x" => 100, "y" => 100, "w" => 4000, "h" => 4000}}}
        ] do
      render_hook(view, event, Map.put(params, "frame", window.id))
      assert_reply(view, %{ok: true})

      assert %{id: id, src: src} = app_frame(view, "slot-dash")
      assert {id, src} == {window.id, window.src}, event
      assert wrappers(view) == before, event
    end
  end
end
