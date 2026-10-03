# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CanvasLiveTest do
  @moduledoc """
  The canvas draws the person's layout for the posture their client
  reports, and the shell holds exactly the frames that arrangement places:
  a `full` slot's tincture framed at its slot, a floating entry's only when
  its tincture declares `float`, and nothing for a tincture nobody
  installed, which draws a placeholder. A posture report that is neither
  `hand` nor `desk` is ignored. Opening a full frame over the canvas
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
  # `frame` as its `tincture.frame` block.
  defp tincture!(ctx, name, frame \\ %{}) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "frame" => frame}
    }

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(ctx),
        ["components", "tinctures", "local", name, "1.0.0"]
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "index.html"), "<html><head></head><body>#{name}</body></html>")

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

  defp layout!(ctx, user, document) do
    {:ok, layout} = Prima.Layout.validate(document)
    {:ok, _revision} = Arca.Layouts.publish(Sanctum.Context.actor(ctx), user.user_id, layout, 0)
    :ok
  end

  # Desk: a full slot, an icon slot, a card slot nobody installed, and
  # three floating entries — one declared, one not, one nobody installed.
  # Hand: one full slot of another tincture.
  defp document do
    %{
      "version" => 1,
      "postures" => %{
        "desk" => %{
          "desktop" => "tincture:local.desktop",
          "slots" => [
            %{
              "id" => "main",
              "tincture" => "tincture:local.slot-dash",
              "size" => "full",
              "order" => 0
            },
            %{
              "id" => "ico",
              "tincture" => "tincture:local.icon-dash",
              "size" => "icon",
              "order" => 1
            },
            %{"id" => "gone", "tincture" => "tincture:acme.gone", "size" => "card", "order" => 2}
          ],
          "floating" => [
            %{
              "tincture" => "tincture:local.float-dash",
              "position" => %{"x" => 2500, "y" => 5000}
            },
            %{"tincture" => "tincture:local.nofloat-dash", "position" => %{"x" => 0, "y" => 0}},
            %{"tincture" => "tincture:acme.ghost", "position" => %{"x" => 9000, "y" => 9000}}
          ]
        },
        "hand" => %{
          "desktop" => "tincture:local.desktop",
          "slots" => [
            %{
              "id" => "pocket",
              "tincture" => "tincture:local.icon-dash",
              "size" => "full",
              "order" => 0
            }
          ],
          "floating" => []
        }
      }
    }
  end

  defp installed!(ctx) do
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
    layout!(ctx, user, document())

    {view, _html} = mount_athanor(conn, "/tinctures")
    html = render(view)

    # A full slot is its tincture's own frame, at its slot.
    slot = by_key(view, {:slot, "main"})
    assert %{state: :live, visible: true, tincture_id: "iframe_slot-dash"} = slot
    assert row(slot.id).state == "active"
    assert html =~ ~r/data-canvas-place="slot:main"[^>]*>\s*<iframe[^>]*id="#{slot.id}"/

    # The declared floater floats at its layout position.
    float = by_key(view, {:floating, "iframe_float-dash"})
    assert %{state: :live, placement: {:floating, %{x: 2500, y: 5000}}} = float
    assert html =~ "left: min(25.00%"

    # An icon slot is a tile; a tincture nobody installed is a placeholder.
    assert html =~ ~s(data-canvas-tincture="tincture:local.icon-dash")
    assert html =~ ~s(data-canvas-placeholder="tincture:acme.gone")
    assert html =~ ~s(data-canvas-placeholder="tincture:acme.ghost")

    # The slot list the hook lays out, in order.
    [_, slots] = Regex.run(~r/data-slots="([^"]*)"/, html)

    assert slots |> String.replace("&quot;", "\"") |> Jason.decode!() == [
             %{"id" => "main", "size" => "full", "order" => 0},
             %{"id" => "ico", "size" => "icon", "order" => 1},
             %{"id" => "gone", "size" => "card", "order" => 2}
           ]

    # Only the slot frame and the declared floater were opened.
    assert length(rows()) == 2

    assert Enum.map(Prism.Frames.list(frames(view)), & &1.tincture_id) == [
             "iframe_slot-dash",
             "iframe_float-dash"
           ]
  end

  test "a tincture that does not declare float is not placed", %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, document())

    {view, _html} = mount_athanor(conn, "/tinctures")

    assert by_key(view, {:floating, "iframe_nofloat-dash"}) == nil
    refute Enum.any?(Prism.Frames.list(frames(view)), &(&1.tincture_id == "iframe_nofloat-dash"))
    assert length(Regex.scan(~r/<iframe /, render(view))) == 2
  end

  test "a layout naming only uninstalled tinctures draws placeholders and opens nothing",
       %{conn: conn, ctx: ctx, user: user} do
    layout!(ctx, user, document())

    {view, _html} = mount_athanor(conn, "/tinctures")
    html = render(view)

    for ref <- ~w(tincture:local.slot-dash tincture:local.icon-dash tincture:acme.gone
                  tincture:local.float-dash tincture:acme.ghost) do
      assert html =~ ~s(data-canvas-placeholder="#{ref}")
    end

    refute html =~ "<iframe"
    assert Prism.Frames.list(frames(view)) == []
    assert rows() == []
  end

  test "the hand posture swaps the arrangement, and an unknown posture is ignored",
       %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, document())

    {view, _html} = mount_athanor(conn, "/tinctures")
    desk_slot = by_key(view, {:slot, "main"})
    desk_float = by_key(view, {:floating, "iframe_float-dash"})

    posture!(view, "tablet")
    posture!(view, "HAND")
    html = render(view)
    assert html =~ ~s(data-posture="desk")
    assert by_key(view, {:slot, "main"}).id == desk_slot.id

    posture!(view, "hand")
    html = render(view)
    assert html =~ ~s(data-posture="hand")

    pocket = by_key(view, {:slot, "pocket"})
    assert %{tincture_id: "iframe_icon-dash", state: :live} = pocket
    assert by_key(view, {:slot, "main"}) == nil
    assert by_key(view, {:floating, "iframe_float-dash"}) == nil
    assert row(desk_slot.id).state == "revoked"
    assert row(desk_float.id).state == "revoked"
    refute html =~ ~s(data-canvas-placeholder="tincture:acme.gone")
  end

  test "a full frame over the canvas freezes what it covers, and closing it lets it run",
       %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, document())

    {view, _html} = mount_athanor(conn, "/tinctures")
    slot = by_key(view, {:slot, "main"})
    bearer = bearer!(view, slot.id)
    assert {:ok, _} = Sanctum.TinctureAuth.verify_frame_credential(bearer)

    render_click(view, "select_tincture", %{"tincture" => "iframe_icon-dash"})
    assert %{state: :frozen, visible: false} = by_key(view, {:slot, "main"})
    assert {:error, :suspended} = Sanctum.TinctureAuth.verify_frame_credential(bearer)
    assert %{state: :frozen} = by_key(view, {:floating, "iframe_float-dash"})
    slot_id = slot.id
    assert_push_event(view, "frame_state", %{frame: ^slot_id, state: "frozen"})

    render_click(view, "close_active_tincture", %{})
    assert %{state: :live, visible: true} = by_key(view, {:slot, "main"})
    assert {:ok, _} = Sanctum.TinctureAuth.verify_frame_credential(bearer)
    assert_push_event(view, "frame_state", %{frame: ^slot_id, state: "live"})
  end

  test "the shell ending revokes the layout's frames too", %{conn: conn, ctx: ctx, user: user} do
    installed!(ctx)
    layout!(ctx, user, document())

    {view, _html} = mount_athanor(conn, "/tinctures")
    ids = Enum.map(Prism.Frames.list(frames(view)), & &1.id)
    assert length(ids) == 2

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
