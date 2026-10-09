# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CanvasLiveTest do
  @moduledoc """
  The canvas layer draws the person's layout for the posture their client
  reports, and the shell holds the frames that arrangement places over the
  visible canvas: its frame, a `column` app's tincture at its column, a
  floating entry's only when its tincture declares `float`, and nothing
  for a tincture nobody installed, which floats as a placeholder. A `full`
  app opens only when the canvas asks for it. A posture report that is
  neither `hand` nor `desk` is ignored. The switcher and the edge strip are
  drawn for more than one canvas. Opening a full frame over the canvas
  freezes the frames beneath it, and closing it lets them run again.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

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

  # The registry is one server-wide process; after the test's own checkout
  # is gone its reload runs on a checkout lent to it alone.
  defp reload_registry do
    registry = Process.whereis(Prism.TinctureRegistry)

    case Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo) do
      :ok ->
        try do
          Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), registry)
          :ok = Prism.TinctureRegistry.reload()
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Arca.Repo)
        end

      {:already, _} ->
        Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), registry)
        :ok = Prism.TinctureRegistry.reload()
    end
  end

  # A tincture version in the athanor's tree and its component row, with
  # `tincture` its manifest's block and `files` its files.
  defp lay!(ctx, name, tincture, files) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => tincture
    }

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(ctx),
        ["components", "tinctures", "local", name, "1.0.0"]
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    for {file, bytes} <- files, do: File.write!(Path.join(dir, file), bytes)

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
        "canvas" => %{"module" => "canvas.js", "toolkit" => 1},
        "streams" => []
      },
      [{"canvas.js", "export default (canvas) => canvas.render({type: \"spacer\"})"}]
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
    {:ok, layout} = Prima.Layout.validate(%{"version" => 2, "canvases" => canvases})
    {:ok, _revision} = Arca.Layouts.publish(Sanctum.Context.actor(ctx), user.user_id, layout, 0)
    :ok
  end

  defp app(tincture, mode, order), do: %{"tincture" => tincture, "mode" => mode, "order" => order}

  defp float(tincture, x, y), do: %{"tincture" => tincture, "position" => %{"x" => x, "y" => y}}

  # Desk: a column app, a full app, a column nobody installed, and three
  # floating entries — one declared, one not, one nobody installed. Hand:
  # one column of another tincture. A second canvas places nothing.
  defp canvases do
    [
      %{
        "id" => "home",
        "tincture" => "tincture:local.markets",
        "postures" => %{
          "desk" => %{
            "apps" => [
              app("tincture:local.slot-dash", "column", 0),
              app("tincture:local.icon-dash", "full", 1),
              app("tincture:acme.gone", "column", 2)
            ],
            "floating" => [
              float("tincture:local.float-dash", 2500, 5000),
              float("tincture:local.nofloat-dash", 0, 0),
              float("tincture:acme.ghost", 9000, 9000)
            ]
          },
          "hand" => %{
            "apps" => [app("tincture:local.icon-dash", "column", 0)],
            "floating" => []
          }
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
    tincture!(ctx, "float-dash", %{"placement" => "float"})
    tincture!(ctx, "nofloat-dash")
  end

  defp frames(view), do: :sys.get_state(view.pid).socket.assigns.frames

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
    do: view |> element("#canvas") |> render_hook("posture", %{"posture" => posture})

  test "the desk arrangement is drawn and its frames are held", %{
    conn: conn,
    ctx: ctx,
    user: user
  } do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/tinctures")
    html = render(view)

    # The canvas fills the layer under everything placed over it.
    canvas = by_key(view, {:canvas, "home"})
    assert %{state: :live, visible: true, placement: :canvas} = canvas
    assert html =~ ~r/data-canvas-place="canvas"[^>]*>\s*<iframe[^>]*id="#{canvas.id}"/

    # A column app is its tincture's own frame, at its column.
    column = by_key(view, {:app, "home", "tincture:local.slot-dash"})
    assert %{state: :live, visible: true, placement: {:column, 0}, arranged: true} = column
    assert row(column.id).state == "active"
    assert html =~ ~s(data-canvas-column="#{column.id}")

    # The declared floater floats at its layout position; a floating
    # tincture nobody installed is a placeholder.
    float = by_key(view, {:floating, "home", "tincture:local.float-dash"})
    assert %{state: :live, placement: {:floating, %{x: 2500, y: 5000}}} = float
    assert html =~ "left: min(25.00%"
    assert html =~ ~s(data-canvas-placeholder="tincture:acme.ghost")

    # The shown columns the hook lays out, in order.
    [_, columns] = Regex.run(~r/data-columns="([^"]*)"/, html)

    assert columns |> String.replace("&quot;", "\"") |> Jason.decode!() == [
             %{"frame" => column.id, "order" => 0}
           ]

    # A full app is not opened until the canvas asks for it, and the
    # canvas, the column and the floater are all that were.
    assert by_key(view, {:app, "home", "tincture:local.icon-dash"}) == nil
    assert length(rows()) == 3

    # In the order they were opened: what the layout places, then the canvas.
    assert Enum.map(Prism.Frames.list(frames(view)), & &1.tincture_id) == [
             "iframe_slot-dash",
             "iframe_float-dash",
             "iframe_markets"
           ]
  end

  test "a tincture that does not declare float is not placed", %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/tinctures")

    assert by_key(view, {:floating, "home", "tincture:local.nofloat-dash"}) == nil
    refute Enum.any?(Prism.Frames.list(frames(view)), &(&1.tincture_id == "iframe_nofloat-dash"))
    assert length(Regex.scan(~r/<iframe /, render(view))) == 3
  end

  test "a layout naming only uninstalled tinctures draws placeholders and opens nothing",
       %{conn: conn, ctx: ctx, user: user} do
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/tinctures")
    html = render(view)

    for ref <- ~w(tincture:local.float-dash tincture:acme.ghost) do
      assert html =~ ~s(data-canvas-placeholder="#{ref}")
    end

    refute html =~ "<iframe"
    assert Prism.Frames.list(frames(view)) == []
    assert rows() == []
  end

  test "the hand posture swaps the arrangement, and an unknown posture is ignored",
       %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/tinctures")
    desk_column = by_key(view, {:app, "home", "tincture:local.slot-dash"})
    desk_float = by_key(view, {:floating, "home", "tincture:local.float-dash"})
    canvas = by_key(view, {:canvas, "home"})

    posture!(view, "tablet")
    posture!(view, "HAND")
    html = render(view)
    assert html =~ ~s(data-posture="desk")
    assert by_key(view, {:app, "home", "tincture:local.slot-dash"}).id == desk_column.id

    posture!(view, "hand")
    html = render(view)
    assert html =~ ~s(data-posture="hand")

    pocket = by_key(view, {:app, "home", "tincture:local.icon-dash"})
    assert %{tincture_id: "iframe_icon-dash", state: :live, placement: {:column, 0}} = pocket
    assert by_key(view, {:app, "home", "tincture:local.slot-dash"}) == nil
    assert by_key(view, {:floating, "home", "tincture:local.float-dash"}) == nil
    assert row(desk_column.id).state == "revoked"
    assert row(desk_float.id).state == "revoked"
    refute html =~ ~s(data-canvas-placeholder="tincture:acme.ghost")

    # The canvas is kept across postures.
    assert by_key(view, {:canvas, "home"}).id == canvas.id
  end

  test "a full frame over the canvas freezes what it covers, and closing it lets it run",
       %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/tinctures")
    column = by_key(view, {:app, "home", "tincture:local.slot-dash"})
    canvas = by_key(view, {:canvas, "home"})
    bearer = bearer!(view, column.id)
    assert {:ok, _} = Sanctum.TinctureAuth.verify_frame_credential(bearer)

    render_hook(view, "canvas_verb", %{
      "frame" => canvas.id,
      "message" =>
        Prima.CanvasWire.encode(%{
          verb: :open,
          frame: canvas.id,
          args: %{"ref" => "tincture:local.icon-dash"}
        })
    })

    assert %{placement: :full, visible: true} =
             by_key(view, {:app, "home", "tincture:local.icon-dash"})

    assert %{state: :frozen, visible: false} = by_key(view, column.key)
    assert {:error, :suspended} = Sanctum.TinctureAuth.verify_frame_credential(bearer)
    assert %{state: :frozen} = by_key(view, {:floating, "home", "tincture:local.float-dash"})
    assert %{state: :frozen} = by_key(view, {:canvas, "home"})
    column_id = column.id
    assert_push_event(view, "frame_state", %{frame: ^column_id, state: "frozen"})

    render_click(view, "close_active_tincture", %{})
    assert %{state: :live, visible: true} = by_key(view, column.key)
    assert {:ok, _} = Sanctum.TinctureAuth.verify_frame_credential(bearer)
    assert_push_event(view, "frame_state", %{frame: ^column_id, state: "live"})
  end

  test "the switcher and the edge strip are drawn for more than one canvas, and not in safe mode",
       %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/tinctures")
    html = render(view)

    assert has_element?(
             view,
             ~s(#canvas-switcher button[data-canvas="home"][aria-pressed="true"])
           )

    assert has_element?(
             view,
             ~s(#canvas-switcher button[data-canvas="work"][aria-pressed="false"])
           )

    assert has_element?(
             view,
             ~s(#canvas-switcher button[phx-click="switch_canvas"][phx-value-canvas="work"])
           )

    assert html =~ ~r/id="canvas-edge-strip"[^>]*class="[^"]*h-4/

    render_click(view, "safe_mode", %{})
    refute has_element?(view, "#canvas-switcher")
    refute has_element?(view, "#canvas-edge-strip")
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
          "desk" => %{
            "apps" => [app("tincture:local.notes-canvas", "column", 0)],
            "floating" => []
          }
        }
      }
    ])

    {view, _html} = mount_athanor(conn, "/tinctures")

    assert %{state: :refused, refusal: :undeclared, credential_id: nil} =
             app = by_key(view, {:app, "home", "tincture:local.notes-canvas"})

    assert render(view) =~ ~s(id="tincture_state_#{app.id}")
    assert Enum.map(rows(), & &1.name) == ["markets"]
  end

  test "the shell ending revokes the layout's frames too", %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, canvases())

    {view, _html} = mount_athanor(conn, "/tinctures")
    ids = Enum.map(Prism.Frames.list(frames(view)), & &1.id)
    assert length(ids) == 3

    GenServer.stop(view.pid, :normal)
    for id <- ids, do: assert(row(id).state == "revoked")
  end

  test "the shell mounts the canvas and the system layer", %{conn: conn} do
    {_view, html} = mount_athanor(conn, "/tinctures")

    assert html =~ ~s(id="canvas")
    assert html =~ ~s(phx-hook="Canvas")
    assert html =~ ~s(id="system-layer")
    assert html =~ ~s(data-posture="desk")
  end
end
