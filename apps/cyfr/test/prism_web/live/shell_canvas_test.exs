# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellCanvasTest do
  @moduledoc """
  The canvases in the shell, and safe mode.

  The shell shows the layout's first canvas, its working version opened as
  a canvas frame on the canvas's own page, and draws the picker only
  when no canvas runs: a layout with no canvas, or a canvas nobody
  installed. A new person sees the shipped canvas, validated once and then
  opened live. A canvas is decided against the listing read as it is
  decided, so what was installed or removed while the shell is open is
  decided as it now stands. Nothing whose presence varies comes before the
  canvas layer, and no element around its frames pushes an event. It reads
  the layout again when one of the person's own sessions
  publishes it. A full frame over a canvas freezes it; switching
  freezes the canvas left and its apps, and shows the next, with no wrap.
  A canvas's `open` places a listed tincture where its arrangement puts
  it, and its `press` reaches `feed.press` only from the visible live
  canvas whose version reads that feed. A canvas shown and not ready
  within the whole period from its showing, one refused at open, and the
  person's own ask enter safe mode, which
  discards every frame with its credential; its kept version restores and
  opens only that canvas.

  Takes a slot through `Arca.ControlPlane` in the ownership case, which
  writes the process-wide standing record; that case saves and restores it.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Prism.Frames

  # The shipped canvas, as the seed holds it: the one version it ships.
  @seed_canvas Path.expand("../../../../../seed/components/tinctures/local/canvas", __DIR__)

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "shell_canvas_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry()
    end)

    {:ok, conn: conn, user: user, athanor: athanor, ctx: ctx}
  end

  # ---- what the athanor holds -----------------------------------------------

  # A tincture version laid in the athanor's tree with its component row:
  # `tincture` its manifest's block, `files` its files. Answers the row's
  # release digest.
  defp lay!(ctx, name, version, tincture, files, opts \\ []) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => version,
      "publisher" => "local",
      "tincture" => tincture
    }

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, version,
      manifest: manifest,
      files: files
    )

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name <> version), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: version,
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

    acknowledged!(ctx)

    if Keyword.get(opts, :granted, true),
      do: Sanctum.Test.ConsentFixtures.grant_tincture!(ctx, "tincture:local.#{name}")

    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
    release_digest
  end

  # The rows these fixtures write are the registry's, as a commit would
  # have written them: the root's projection is told it holds them after a
  # row is written and after a unit is laid, so a read derives nothing
  # over them from the units the fixtures commit.
  defp acknowledged!(ctx) do
    actor = Sanctum.Context.actor(ctx)
    {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, "components")

    {:ok, :acknowledged} =
      Arca.StorageProjectionChanges.replace(actor, "components", token, fn -> :acknowledged end)

    :ok
  end

  defp tincture!(ctx, name, tincture \\ %{}) do
    lay!(ctx, name, "1.0.0", Map.merge(%{"entry" => "index.html"}, tincture), [
      {"index.html", "<html><head></head><body>#{name}</body></html>"}
    ])
  end

  # Every version of tincture `name` gone from the athanor's tree — each
  # version's unit cleared beneath its name, as a reset of the tree takes
  # them — and the registry scanned again.
  defp unlay!(ctx, name) do
    cleared =
      Arca.Overlay.with_internal_writes(fn ->
        Arca.delete_tree(Sanctum.Context.actor(ctx), ["components", "tinctures", "local", name])
      end)

    true = cleared in [:ok, {:error, :not_found}]
    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
  end

  # A canvas version, granted as the person would grant it unless
  # `granted: false` leaves the grant as it was.
  defp canvas!(
         ctx,
         name,
         version \\ "1.0.0",
         streams \\ [%{"name" => "runs.changes"}],
         opts \\ []
       ) do
    lay!(
      ctx,
      name,
      version,
      %{
        "frame" => %{"placement" => "canvas"},
        "entry" => "index.html",
        "streams" => streams
      },
      [{"index.html", "<html><head></head><body>#{name}</body></html>"}],
      opts
    )
  end

  defp seed do
    [dir] = Path.wildcard(Path.join(@seed_canvas, "*"))
    dir
  end

  defp seed_manifest,
    do: seed() |> Path.join("cyfr-manifest.json") |> File.read!() |> Jason.decode!()

  # The shipped canvas, as the seed holds it, installed in the athanor.
  defp shipped!(ctx) do
    manifest = seed_manifest()

    files =
      for path <- Path.wildcard(Path.join(seed(), "**/*")),
          File.regular?(path),
          relative = Path.relative_to(path, seed()),
          relative != "cyfr-manifest.json",
          do: {relative, File.read!(path)}

    lay!(ctx, "canvas", manifest["version"], manifest["tincture"], files)
  end

  # Version `version` of tincture `name` gone from the athanor's tree and
  # its rows, and the registry scanned again.
  defp unlay_version!(ctx, name, version) do
    actor = Sanctum.Context.actor(ctx)

    {:ok, :deleted} =
      Arca.Overlay.drop_unit(actor, ["components", "tinctures", "local", name, version])

    :ok = Arca.ComponentStorage.delete_component(actor, name, version, "local", "tincture")
    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
  end

  # The canvas `name`'s versions document, as a glass's validation leaves it.
  defp versions!(ctx, name, fields) do
    actor = Sanctum.Context.actor(ctx)

    revision =
      case Arca.CanvasVersions.get(actor, name) do
        {:ok, %{revision: revision}} -> revision
        {:error, :not_found} -> 0
      end

    {:ok, _} =
      Arca.CanvasVersions.publish(
        actor,
        name,
        Map.merge(Arca.CanvasVersions.empty(), fields),
        revision
      )
  end

  defp versions(ctx, name) do
    case Arca.CanvasVersions.get(Sanctum.Context.actor(ctx), name) do
      {:ok, %{document: document}} -> document
      {:error, :not_found} -> Arca.CanvasVersions.empty()
    end
  end

  defp entry(id, tincture, postures \\ %{}),
    do: %{"id" => id, "tincture" => tincture, "postures" => postures}

  defp posture(apps), do: %{"apps" => apps}

  defp app(tincture, placement, order \\ 0, minimised \\ false) do
    %{
      "tincture" => tincture,
      "placement" => placement,
      "order" => order,
      "minimised" => minimised
    }
    |> Map.merge(
      case placement do
        "window" -> %{"geometry" => %{"x" => 1000, "y" => 1000, "w" => 3000, "h" => 5000}}
        "tile" -> %{"side" => "right", "share" => 2500}
        "full" -> %{}
      end
    )
  end

  # Publish the person's layout as the layout tool does, from another
  # session of theirs.
  defp layout!(user, athanor, canvases) do
    ctx = person(user, athanor)

    {:ok, %{revision: revision}} = Compendium.Providers.Layout.read(ctx)

    {:ok, _} =
      Compendium.Providers.Layout.handle("layout", ctx, %{
        "action" => "edit",
        "document" => %{"version" => 3, "canvases" => canvases},
        "revision" => revision
      })
  end

  # The person's own context, as another of their sessions holds it.
  defp person(user, athanor) do
    Sanctum.Context.build(
      user_id: user.user_id,
      athanor_id: athanor.id,
      permissions: Sanctum.Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  # ---- the shell ------------------------------------------------------------

  defp shell!(conn) do
    {view, _html} = mount_athanor(conn, "/canvas")
    Process.put(:view, view)
    # The canvas's read and the shell's placing are messages to the view;
    # they end in a canvas decided on, or in safe mode.
    settle!(view, fn ->
      assigns = assigns(view)
      assigns.showing != :pending or assigns.safe_mode != nil
    end)

    view
  end

  # The canvas reads the layout again through messages the view handles
  # in turn: render until `check` holds, a bounded number of times.
  defp settle!(view, check) do
    wait_until(fn -> render(view) && check.() end, 2_000, "the shell to settle")
  end

  defp assigns(%Phoenix.LiveViewTest.View{pid: pid}), do: :sys.get_state(pid).socket.assigns
  defp frames(view), do: assigns(view).frames
  defp canvas(view, id \\ "home"), do: Frames.get(frames(view), {:canvas, id})
  defp validation(view, id \\ "home"), do: Frames.get(frames(view), {:validation, id})
  defp opened(view), do: Frames.list(frames(view))
  defp dropped(view), do: Frames.dropped(frames(view))

  defp row(frame_id) do
    Arca.Repo.one(from(f in Arca.Schemas.FrameCredential, where: f.frame_id == ^frame_id))
  end

  defp rows, do: Arca.Repo.all(Arca.Schemas.FrameCredential)

  # Frame `frame_id`'s credential revoked behind the shell's back, so the
  # activation its trial reports spends nothing and records nothing.
  defp revoke!(frame_id) do
    {1, _} =
      Arca.Repo.update_all(
        from(f in Arca.Schemas.FrameCredential, where: f.frame_id == ^frame_id),
        set: [state: "revoked"]
      )
  end

  defp verify(bearer), do: Sanctum.TinctureAuth.verify_frame_credential(bearer)

  # The frame credential's lifetime, installed beside whatever the run
  # installed and restored after.
  defp deadline_setting!(seconds) do
    previous = Arca.PlatformSettings.installed()

    on_exit(fn ->
      if previous,
        do: Arca.PlatformSettings.install_defaults!(previous),
        else: Arca.PlatformSettings.uninstall()
    end)

    Arca.PlatformSettings.install_defaults!(
      Map.put(previous || %{}, "frame_credential_deadline_s", %{default: seconds, stale: :serve})
    )
  end

  # A canvas frame's handshake: the wire's canvas handshake reply.
  defp handshake!(view, frame_id) do
    render_hook(view, "frame_handshake", %{"frame" => frame_id})
    assert_reply(view, %{"credential" => _, "canvas" => _} = reply)
    reply
  end

  # A canvas's stream opened on its own data route under `bearer`, as its
  # page's SDK opens one.
  defp canvas_stream(frame_id, bearer, stream, subject \\ nil) do
    body = Prima.TinctureWire.request(:stream_open, %{stream: stream, subject: subject})

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("origin", "null")
    |> put_req_header("authorization", Prima.TinctureWire.bearer(bearer))
    |> post(Prima.TinctureWire.stream_path(frame_id), Jason.encode!(body))
  end

  defp canvas_verb!(view, frame_id, verb, args \\ %{}),
    do:
      render_hook(view, "frame_verb", %{
        "frame" => frame_id,
        "message" => Prima.TinctureWire.shell_message(verb, frame_id, args)
      })

  # `#shell`'s children in document order, each by its id, or by its tag
  # when it has none.
  defp shell_children(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#shell > *")
    |> Enum.map(fn child ->
      List.first(LazyHTML.attribute(child, "id")) || hd(LazyHTML.tag(child))
    end)
  end

  # Every ancestor of the element `selector` names in the shell's render,
  # nearest first.
  defp ancestors(view, selector) do
    [node] =
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.to_list()

    parents(LazyHTML.parent_node(node))
  end

  defp parents(node) do
    if Enum.empty?(node), do: [], else: [node | parents(LazyHTML.parent_node(node))]
  end

  defp label(node), do: List.first(LazyHTML.attribute(node, "id")) || hd(LazyHTML.tag(node))

  # The element's hook and event bindings, each as its element and attribute:
  # an event pushed from an element locks it until the reply.
  @bindings ~w(phx-hook phx-click phx-click-away phx-capture-click phx-blur phx-focus phx-change phx-submit
               phx-mounted phx-connected phx-disconnected phx-remove)

  defp bindings(node) do
    [attributes] = LazyHTML.attributes(node)

    for {name, _value} <- attributes,
        name in @bindings or
          String.starts_with?(name, ["phx-window-", "phx-key", "phx-viewport-"]),
        do: {label(node), name}
  end

  defp iframe(html, frame_id) do
    [tag] = Regex.run(~r/<iframe[^>]*id="#{frame_id}"[^>]*>/, html)
    tag
  end

  defp attribute(tag, name) do
    case Regex.run(~r/\s#{name}="([^"]*)"/, tag) do
      [_, value] -> value
      nil -> nil
    end
  end

  # The install media ships the canvas: a seed tree of the test's own,
  # restored when it ends.
  defp shipped_seed! do
    seed =
      Path.join(System.tmp_dir!(), "shell_canvas_seed_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(seed, "components/tinctures/local/canvas"))

    File.cp_r!(
      seed(),
      Path.join(seed, "components/tinctures/local/canvas/#{Path.basename(seed())}")
    )

    previous = Application.get_env(:arca, :seed_path)
    Application.put_env(:arca, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:arca, :seed_path, previous)
      File.rm_rf(seed)
    end)
  end

  # The person's stored layout no longer holds its digest: every read of
  # it, `Compendium.layout/2`'s included, answers an error.
  defp break_layout!(ctx, user, athanor) do
    key = Arca.Layouts.key(user.user_id)

    {1, _} =
      Arca.Repo.update_all(
        from(d in Arca.Schemas.FencedDocument,
          where: d.athanor_id == ^ctx.athanor_id and d.key == ^key
        ),
        set: [digest: "sha256:" <> String.duplicate("0", 64)]
      )

    assert {:error, _} = Compendium.layout(person(user, athanor), "desk")
  end

  # The digest the person's stored layout holds, and that digest put back
  # after `break_layout!/3`: reads answer again.
  defp layout_digest(ctx, user) do
    key = Arca.Layouts.key(user.user_id)

    Arca.Repo.one(
      from(d in Arca.Schemas.FencedDocument,
        where: d.athanor_id == ^ctx.athanor_id and d.key == ^key,
        select: d.digest
      )
    )
  end

  defp mend_layout!(ctx, user, athanor, digest) do
    key = Arca.Layouts.key(user.user_id)

    {1, _} =
      Arca.Repo.update_all(
        from(d in Arca.Schemas.FencedDocument,
          where: d.athanor_id == ^ctx.athanor_id and d.key == ^key
        ),
        set: [digest: digest]
      )

    assert {:ok, _} = Compendium.layout(person(user, athanor), "desk")
  end

  # The layout published, as the bus tells this shell.
  defp published!(view, ctx, user),
    do: send(view.pid, Cyfr.Bus.LayoutPublished.new(Sanctum.Context.actor(ctx), user.user_id, 9))

  defp layout_notes(view),
    do: length(Regex.scan(~r/data-canvas-layout="unavailable"/, render(view)))

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  # A claimant runs, as a deployment's does, and this member holds its
  # slot: the umbrella's test configuration runs none.
  defp claimant! do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-shell-canvas-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  # A successor takes the slot over; this member still believes it holds it.
  defp take_over!(slot) do
    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^slot.node),
        set: [owner: slot.node <> "#boot_b", generation: slot.generation + 1]
      )

    assert Arca.ControlPlane.held?()
  end

  # Two canvases with working versions, `home` on markets and `work` on
  # notes-canvas, `home_postures` placed over home. Answers markets'
  # release digest.
  defp two_canvases!(ctx, user, athanor, home_postures \\ %{}) do
    digest = canvas!(ctx, "markets")
    canvas!(ctx, "notes-canvas")
    versions!(ctx, "markets", %{working: "1.0.0"})
    versions!(ctx, "notes-canvas", %{working: "1.0.0"})

    layout!(user, athanor, [
      entry("home", "tincture:local.markets", home_postures),
      entry("work", "tincture:local.notes-canvas")
    ])

    digest
  end

  # A shell whose `home` canvas runs 1.0.1, 1.0.0 kept, and is hidden by
  # `hidden_by`: a switch to `work`, or a full frame its own open put over
  # it, which freezes it while it stays the visible canvas.
  defp hidden_canvas!(conn, ctx, user, athanor, hidden_by) do
    tincture!(ctx, "app-dash")
    full = %{"desk" => posture([app("tincture:local.app-dash", "full", 0, true)])}
    two_canvases!(ctx, user, athanor, if(hidden_by == :full_frame, do: full, else: %{}))
    canvas!(ctx, "markets", "1.0.1")
    versions!(ctx, "markets", %{working: "1.0.1", kept: "1.0.0"})

    view = shell!(conn)
    assert %{reference: %{version: "1.0.1"}, state: :live} = home = canvas(view)

    case hidden_by do
      :switch -> render_hook(view, "switch_canvas", %{"canvas" => "work"})
      :full_frame -> canvas_verb!(view, home.id, :open, %{"ref" => "tincture:local.app-dash"})
    end

    assert %{state: :frozen, visible: false} = canvas(view)
    view
  end

  # The hidden `home` canvas shown again as `hidden_canvas!/5` hid it.
  defp show_again!(view, :switch), do: render_hook(view, "switch_canvas", %{"canvas" => "home"})
  defp show_again!(view, :full_frame), do: render_click(view, "close_active_tincture", %{})

  # A shell whose `home` canvas opened hidden: a full frame its own open
  # put over it is shown when the layout gives `home` another tincture,
  # whose frame opens frozen under that full frame. Closing the full frame
  # shows it.
  defp opened_hidden!(conn, ctx, user, athanor) do
    tincture!(ctx, "app-dash")
    full = %{"desk" => posture([app("tincture:local.app-dash", "full", 0, true)])}
    two_canvases!(ctx, user, athanor, full)
    view = shell!(conn)
    first = canvas(view)
    canvas_verb!(view, first.id, :open, %{"ref" => "tincture:local.app-dash"})
    assert %{state: :frozen} = canvas(view)

    layout!(user, athanor, [
      entry("home", "tincture:local.notes-canvas", full),
      entry("work", "tincture:local.markets")
    ])

    settle!(view, fn -> match?(%{reference: %{name: "notes-canvas"}}, canvas(view)) end)
    assert %{state: :frozen, visible: false} = opened = canvas(view)
    refute opened.id == first.id
    assert row(opened.id).state == "suspended"
    view
  end

  # The period a shown canvas has to send ready: ten seconds, as
  # `PrismWeb.ShellLive` documents it.
  @ready_ms 10_000

  # When the timer of a ready deadline the shell holds fires, in
  # monotonic milliseconds.
  defp fires_at(timer) do
    left = Process.read_timer(timer)
    assert is_integer(left)
    System.monotonic_time(:millisecond) + left
  end

  # Time passes beyond every ready deadline the shell holds: each is
  # delivered as its timer delivers it, its timer cancelled first so it
  # arrives once.
  defp deadlines_pass!(view) do
    for {frame_id, {timer, token}} <- assigns(view).canvas_deadlines do
      Process.cancel_timer(timer)
      send(view.pid, {:canvas_deadline, frame_id, token})
    end

    _ = render(view)
  end

  # ===========================================================================

  describe "the canvas" do
    test "the visible canvas is the layout's first, opened as a canvas frame, and the picker is not drawn",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      tincture!(ctx, "app-dash")
      digest = two_canvases!(ctx, user, athanor)
      view = shell!(conn)

      assert %{
               state: :live,
               visible: true,
               placement: :canvas,
               reference: %{name: "markets", version: "1.0.0"}
             } = home = canvas(view)

      assert canvas(view, "work") == nil
      assert Frames.visible_canvas(frames(view)) == "home"

      html = render(view)
      refute html =~ ~s(id="shell-picker")
      assert html =~ ~s(data-canvas-place="canvas")

      # The canvas's own page under an asset credential, its sandbox the
      # rules', and no allow attribute.
      tag = iframe(html, home.id)
      assert attribute(tag, "data-frame-kind") == "canvas"
      assert attribute(tag, "src") =~ ~r{^/_c/v1/[^/]+/#{home.id}$}
      assert "/_c/v1/" <> _ = attribute(tag, "src")
      assert attribute(tag, "src") == home.src

      assert attribute(tag, "sandbox") ==
               Enum.join(Compendium.tincture_canvas_sandbox_tokens(), " ")

      assert attribute(tag, "allow") == nil

      row = row(home.id)
      assert row.state == "active"
      assert row.purpose == "live"
      assert {row.name, row.version, row.version_digest} == {"markets", "1.0.0", digest}

      # Its handshake is the wire's canvas handshake, its bearer beside
      # its block, once.
      reply = handshake!(view, home.id)

      assert reply ==
               Prima.TinctureWire.canvas_handshake(
                 home.id,
                 reply["credential"],
                 "live",
                 [%{"name" => "runs.changes", "subject" => nil}]
               )

      assert reply["canvas"]["data_path"] == Prima.TinctureWire.data_path(home.id)

      assert {:ok, %{frame_id: frame_id, mode: :live}} =
               Sanctum.TinctureAuth.verify_frame_credential(reply["credential"])

      assert frame_id == home.id
      refute render(view) =~ reply["credential"]

      # It is told what it may open: the listed tinctures that are not canvases.
      home_id = home.id
      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: installed})

      assert installed == [
               %{ref: "tincture:local.app-dash", name: "app-dash", icon: nil, open: false}
             ]

      render_hook(view, "frame_handshake", %{"frame" => home.id})
      assert_reply(view, %{error: "no_credential"})
    end

    test "installed carries each tincture's emoji, or none, and whether it is open over the visible canvas",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      tincture!(ctx, "app-dash", %{"icon" => "🧭"})
      tincture!(ctx, "plain-dash", %{"icon" => String.duplicate("🧭", 17)})
      tincture!(ctx, "word-dash", %{"icon" => "palette"})

      layout!(user, athanor, [
        entry("home", "tincture:local.markets", %{
          "desk" => posture([app("tincture:local.app-dash", "window")])
        })
      ])

      view = shell!(conn)
      assert %{state: :live, id: home_id} = canvas(view)

      assert %{visible: true} =
               Frames.get(frames(view), {:app, "home", "tincture:local.app-dash"})

      _reply = handshake!(view, home_id)

      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: installed})

      assert installed == [
               %{ref: "tincture:local.app-dash", name: "app-dash", icon: "🧭", open: true},
               %{ref: "tincture:local.plain-dash", name: "plain-dash", icon: nil, open: false},
               %{ref: "tincture:local.word-dash", name: "word-dash", icon: nil, open: false}
             ]
    end

    test "a layout with no canvas draws the picker", %{
      conn: conn,
      ctx: ctx,
      user: user,
      athanor: athanor
    } do
      canvas!(ctx, "markets")
      tincture!(ctx, "app-dash")
      layout!(user, athanor, [])
      view = shell!(conn)

      assert opened(view) == []
      assert Frames.visible_canvas(frames(view)) == nil
      assert render(view) =~ ~s(id="shell-picker")
      refute render(view) =~ ~s(id="canvas-switcher")
      assert rows() == []
    end

    test "a canvas nobody installed is not shown: the picker is drawn and its apps still open",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      tincture!(ctx, "app-dash")
      tincture!(ctx, "clock")

      layout!(user, athanor, [
        entry("home", "tincture:local.no-canvas", %{
          "desk" =>
            posture([
              app("tincture:local.app-dash", "window"),
              app("tincture:local.clock", "tile", 1)
            ])
        })
      ])

      view = shell!(conn)

      assert canvas(view) == nil
      assert validation(view) == nil
      assert render(view) =~ ~s(id="shell-picker")

      assert %{state: :live, visible: true, placement: {:window, %{x: 1000, w: 3000}}} =
               Frames.get(frames(view), {:app, "home", "tincture:local.app-dash"})

      assert %{state: :live, visible: true, placement: {:tile, :right, 2500}} =
               Frames.get(frames(view), {:app, "home", "tincture:local.clock"})
    end

    test "a new person sees the shipped canvas", %{conn: conn, ctx: ctx} do
      digest = shipped!(ctx)
      view = shell!(conn)

      # Its newest version is neither working, kept nor failed: it is
      # trialled first, hidden and inert, before anything opens live.
      assert canvas(view) == nil

      assert %{state: :live, visible: false, reference: %{name: "canvas"}} =
               trial = validation(view)

      assert row(trial.id).purpose == "validation"
      assert render(view) =~ ~r/data-canvas-place="validation"[^>]*inert/
      refute render(view) =~ ~s(id="shell-picker")

      %{"version" => version, "tincture" => %{"streams" => streams}} = seed_manifest()
      reply = handshake!(view, trial.id)
      assert reply["canvas"]["mode"] == "validation"

      assert reply["canvas"]["streams"] ==
               Enum.map(streams, &%{"name" => &1["name"], "subject" => &1["subject"]})

      canvas_verb!(view, trial.id, :ready)

      # The trial's credential was spent, the version activated, and the
      # working version opened live.
      assert validation(view) == nil
      assert row(trial.id).state == "revoked"
      assert %{working: ^version, kept: nil, failed: nil} = versions(ctx, "canvas")

      assert %{state: :live, visible: true, reference: %{name: "canvas", version: ^version}} =
               shipped = canvas(view)

      assert row(shipped.id).version_digest == digest

      # Validated once per new version, not per mount.
      GenServer.stop(view.pid, :normal)
      again = shell!(conn)
      assert validation(again) == nil
      assert %{state: :live, reference: %{version: ^version}} = canvas(again)
    end

    test "the canvas is frozen while a full frame covers it and live again once it closes",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      tincture!(ctx, "app-dash")

      two_canvases!(ctx, user, athanor, %{
        "desk" => posture([app("tincture:local.app-dash", "full", 0, true)])
      })

      view = shell!(conn)
      home = canvas(view)
      id = home.id

      canvas_verb!(view, id, :open, %{"ref" => "tincture:local.app-dash"})
      assert %{state: :frozen, visible: false} = canvas(view)
      assert row(id).state == "suspended"
      assert_push_event(view, "frame_state", %{frame: ^id, state: "frozen"})

      assert %{state: :live, visible: true, placement: :full} =
               Frames.get(frames(view), {:app, "home", "tincture:local.app-dash"})

      render_click(view, "close_active_tincture", %{})
      assert %{id: ^id, state: :live, visible: true} = canvas(view)
      assert row(id).state == "active"
    end

    test "a shown full frame takes everything it covers out of reach, and only that",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      tincture!(ctx, "app-dash")

      two_canvases!(ctx, user, athanor, %{
        "desk" => posture([app("tincture:local.app-dash", "full", 0, true)])
      })

      view = shell!(conn)

      # The Canvas mode draws no sidebar and no drawer.
      refute has_element?(view, "#chrome-side")

      for covered <- ~w(#chrome-top [data-canvas-place="canvas"]) do
        refute has_element?(view, "#{covered}[inert]"), covered
      end

      canvas_verb!(view, canvas(view).id, :open, %{"ref" => "tincture:local.app-dash"})

      # The chrome and every canvas layer under the full frame.
      for covered <- ~w(#chrome-top [data-canvas-place="canvas"]) do
        assert has_element?(view, "#{covered}[inert]"), covered
      end

      assert has_element?(view, "#chrome-top[inert] #topbar")

      # The full frame and its capsule, the shell's own Safe mode control,
      # the switcher, the system layer and the assistant's panel stay
      # reachable.
      refute has_element?(view, ~s([data-canvas-place="full"][inert]))
      refute has_element?(view, ~s([inert] button[phx-click="close_active_tincture"]))

      for reachable <- ~w(#shell-safe-mode #canvas-switcher #system-layer #aqua-panel) do
        assert has_element?(view, reachable), reachable
        refute has_element?(view, "[inert] #{reachable}"), reachable
        refute has_element?(view, "#{reachable}[inert]"), reachable
      end

      render_click(view, "close_active_tincture", %{})

      for covered <- ~w(#chrome-top [data-canvas-place="canvas"]) do
        refute has_element?(view, "#{covered}[inert]"), covered
      end
    end

    test "a layout published by another session of the same person is read again here; another person's is not",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "markets", %{working: "1.0.0"})
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{reference: %{name: "markets"}} = canvas(view)

      # Another member of the same athanor arranges their own layout.
      other = test_user()

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(other.user_id, scope: "athanor", athanor_id: athanor.id)

      layout!(other, athanor, [entry("home", "tincture:local.notes-canvas")])
      _ = render(view)
      assert %{reference: %{name: "markets"}} = canvas(view)

      # A payload naming someone else never moves this shell, however it arrives.
      send(view.pid, Cyfr.Bus.LayoutPublished.new(Sanctum.Context.actor(ctx), other.user_id, 9))
      _ = render(view)
      assert %{reference: %{name: "markets"}} = canvas(view)

      # The same person, from another session.
      old = canvas(view).id
      layout!(user, athanor, [entry("home", "tincture:local.notes-canvas")])
      settle!(view, fn -> match?(%{reference: %{name: "notes-canvas"}}, canvas(view)) end)

      assert %{reference: %{name: "notes-canvas"}, state: :live} = canvas(view)
      assert row(old).state == "revoked"
    end

    test "a version written while the shell is open is validated before its canvas opens",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{state: :live, reference: %{version: "1.0.0"}} = home = canvas(view)

      # A newer version installed after the shell listed its tinctures, and
      # a fresh canvas id on the same tincture in home's place.
      canvas!(ctx, "markets", "1.0.1")
      layout!(user, athanor, [entry("fresh", "tincture:local.markets")])

      settle!(view, fn ->
        Frames.visible_canvas(frames(view)) == "fresh" and
          (validation(view, "fresh") != nil or canvas(view, "fresh") != nil)
      end)

      assert %{state: :live, visible: false, reference: %{name: "markets", version: "1.0.1"}} =
               trial = validation(view, "fresh")

      assert canvas(view, "fresh") == nil
      assert %{purpose: "validation", version: "1.0.1"} = row(trial.id)
      assert row(home.id).state == "revoked"
      assert %{working: "1.0.0"} = versions(ctx, "markets")
    end

    test "a version written during a validation is validated once that validation ends, before the working version opens",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.1.0")
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{state: :live, reference: %{version: "1.1.0"}} = first = validation(view)

      # 1.2.0 is written while 1.1.0 is trialled; 1.1.0's ready activates it.
      canvas!(ctx, "markets", "1.2.0")
      canvas_verb!(view, first.id, :ready)

      assert row(first.id).state == "revoked"
      assert %{working: "1.1.0"} = versions(ctx, "markets")
      assert canvas(view) == nil

      assert %{state: :live, visible: false, reference: %{version: "1.2.0"}} =
               newer = validation(view)

      assert %{purpose: "validation", version: "1.2.0"} = row(newer.id)

      # 1.2.0's ready activates it, and with nothing newer the working
      # version opens: no third trial.
      canvas_verb!(view, newer.id, :ready)

      assert validation(view) == nil
      assert %{working: "1.2.0", kept: "1.1.0"} = versions(ctx, "markets")
      assert %{state: :live, visible: true, reference: %{version: "1.2.0"}} = canvas(view)
      assert assigns(view).safe_mode == nil
    end

    test "a validation that ends with no newer version written opens the working version and starts no trial",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.1.0")
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{state: :live, reference: %{version: "1.1.0"}} = first = validation(view)

      canvas_verb!(view, first.id, :ready)

      assert validation(view) == nil
      assert [%{purpose: "validation"}] = rows() |> Enum.filter(&(&1.purpose == "validation"))
      assert %{working: "1.1.0"} = versions(ctx, "markets")
      assert %{state: :live, visible: true, reference: %{version: "1.1.0"}} = canvas(view)
    end

    test "a validation that records nothing, with no newer version written, opens the working version and trials nothing again",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.0.0")
      versions!(ctx, "markets", %{working: "1.0.0"})
      canvas!(ctx, "markets", "1.1.0")
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{reference: %{version: "1.1.0"}} = first = validation(view)

      # 1.1.0's credential is gone before its ready: the activation records
      # nothing, and 1.1.0, the version just tried, is still the newest.
      revoke!(first.id)
      canvas_verb!(view, first.id, :ready)

      assert validation(view) == nil
      assert Enum.count(rows(), &(&1.purpose == "validation")) == 1
      assert %{working: "1.0.0", failed: nil} = versions(ctx, "markets")
      assert %{state: :live, reference: %{version: "1.0.0"}} = canvas(view)
    end

    test "a newer version whose trial records nothing is not trialled again when it stays the newest",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.0.0")
      versions!(ctx, "markets", %{working: "1.0.0"})
      canvas!(ctx, "markets", "1.1.0")
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{reference: %{version: "1.1.0"}} = first = validation(view)

      canvas!(ctx, "markets", "1.2.0")
      canvas_verb!(view, first.id, :ready)
      assert %{reference: %{version: "1.2.0"}} = newer = validation(view)

      # 1.2.0's credential is gone before its ready: the activation is
      # refused and records nothing, and 1.2.0 is still the newest.
      revoke!(newer.id)
      canvas_verb!(view, newer.id, :ready)

      assert validation(view) == nil
      assert %{working: "1.1.0", kept: "1.0.0", failed: nil} = versions(ctx, "markets")
      assert %{state: :live, reference: %{version: "1.1.0"}} = canvas(view)
    end

    for meanwhile <- ["activated", "recorded as failed"] do
      @tag meanwhile: meanwhile
      test "a newer version another glass #{meanwhile} during a validation is not trialled at its end",
           %{conn: conn, ctx: ctx, user: user, athanor: athanor, meanwhile: meanwhile} do
        canvas!(ctx, "markets", "1.0.0")
        versions!(ctx, "markets", %{working: "1.0.0"})
        canvas!(ctx, "markets", "1.1.0")
        layout!(user, athanor, [entry("home", "tincture:local.markets")])
        view = shell!(conn)
        assert %{reference: %{version: "1.1.0"}} = first = validation(view)

        # 1.2.0 is written, and another glass decides it before 1.1.0's
        # ready: activated, so 1.1.0's ready is a late report (conflict); or
        # recorded as failed, with 1.1.0's credential gone so its ready
        # records nothing over that failure.
        canvas!(ctx, "markets", "1.2.0")

        {working, document} =
          case meanwhile do
            "activated" ->
              {"1.2.0", %{working: "1.2.0", kept: "1.0.0"}}

            "recorded as failed" ->
              # A ready would clear `failed`, so 1.1.0's must record nothing.
              revoke!(first.id)
              failure = %{version: "1.2.0", outcome: "died", at: "2026-10-12T00:00:00Z"}
              {"1.0.0", %{working: "1.0.0", failed: failure}}
          end

        versions!(ctx, "markets", document)
        canvas_verb!(view, first.id, :ready)

        assert row(first.id).state == "revoked"
        assert validation(view) == nil
        assert Enum.count(rows(), &(&1.purpose == "validation")) == 1
        assert %{state: :live, reference: %{version: ^working}} = canvas(view)
        assert versions(ctx, "markets") == Map.merge(Arca.CanvasVersions.empty(), document)
      end
    end

    test "a version trialled at a validation's end is trialled from there once, however the newest version moves",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.0.0")
      versions!(ctx, "markets", %{working: "1.0.0"})
      canvas!(ctx, "markets", "1.1.0")
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{reference: %{version: "1.1.0"}} = first = validation(view)

      # Every trial here records nothing: its credential is gone before
      # its ready, or its version is.
      canvas!(ctx, "markets", "1.2.0")
      revoke!(first.id)
      canvas_verb!(view, first.id, :ready)
      assert %{reference: %{version: "1.2.0"}} = second = validation(view)

      unlay_version!(ctx, "markets", "1.2.0")
      canvas_verb!(view, second.id, :ready)
      assert %{reference: %{version: "1.1.0"}} = third = validation(view)

      # 1.2.0 is the newest again, and was trialled from here already.
      canvas!(ctx, "markets", "1.2.0")
      revoke!(third.id)
      canvas_verb!(view, third.id, :ready)

      assert validation(view) == nil
      assert %{working: "1.0.0", failed: nil} = versions(ctx, "markets")
      assert %{state: :live, reference: %{version: "1.0.0"}} = canvas(view)
    end

    test "a canvas installed while the shell is open is decided, never taken for uninstalled",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{state: :live} = canvas(view)

      # Installed after the shell listed its tinctures, then added to the
      # layout and shown.
      canvas!(ctx, "notes-canvas")

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      settle!(view, fn -> Enum.any?(assigns(view).arrangement || [], &(&1.id == "work")) end)
      render_hook(view, "switch_canvas", %{"canvas" => "work"})

      assert %{
               state: :live,
               visible: false,
               reference: %{name: "notes-canvas", version: "1.0.0"}
             } = validation(view, "work")

      assert assigns(view).showing == :canvas
      refute render(view) =~ ~s(id="shell-picker")
    end

    test "nothing whose presence varies comes before the canvas layer",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("ghost", "tincture:local.no-canvas")
      ])

      view = shell!(conn)
      refute has_element?(view, "#shell-picker")
      without = shell_children(view)
      assert ["canvas" | _] = without

      # The picker drawn over the held frames, for a canvas whose tincture
      # nobody installed: the last child, every other child as it was.
      render_hook(view, "switch_canvas", %{"canvas" => "ghost"})
      assert %{state: :frozen} = canvas(view)
      assert has_element?(view, "#shell-picker")
      drawn = shell_children(view)
      assert ["canvas" | _] = drawn
      assert List.last(drawn) == "shell-picker"
      assert List.delete(drawn, "shell-picker") == without

      render_hook(view, "switch_canvas", %{"canvas" => "home"})
      refute has_element?(view, "#shell-picker")
      assert shell_children(view) == without
    end

    test "a tincture installed while the shell is open as anything but a canvas, then named as a canvas, is safe mode not_ready",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{state: :live} = canvas(view)

      # Installed after the shell listed its tinctures, not as a canvas, then
      # named as a canvas by the layout and shown.
      tincture!(ctx, "plain-dash")

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.plain-dash")
      ])

      settle!(view, fn -> Enum.any?(assigns(view).arrangement || [], &(&1.id == "work")) end)
      render_hook(view, "switch_canvas", %{"canvas" => "work"})

      assert %{reason: :not_ready} = assigns(view).safe_mode
      refute render(view) =~ ~s(id="shell-picker")
    end

    test "the same tincture installed before the shell mounted is safe mode not_ready on the same switch",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      tincture!(ctx, "plain-dash")
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{state: :live} = canvas(view)

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.plain-dash")
      ])

      settle!(view, fn -> Enum.any?(assigns(view).arrangement || [], &(&1.id == "work")) end)
      render_hook(view, "switch_canvas", %{"canvas" => "work"})

      assert %{reason: :not_ready} = assigns(view).safe_mode
      refute render(view) =~ ~s(id="shell-picker")
    end

    test "a tincture listed at mount and removed since, then named as a canvas, draws the picker and is not safe mode",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      tincture!(ctx, "plain-dash")
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{state: :live} = canvas(view)
      assert Enum.any?(assigns(view).tinctures, &(&1.name == "plain-dash"))

      # Removed after the shell listed its tinctures, then named as a canvas
      # by the layout and shown.
      unlay!(ctx, "plain-dash")

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.plain-dash")
      ])

      settle!(view, fn -> Enum.any?(assigns(view).arrangement || [], &(&1.id == "work")) end)
      render_hook(view, "switch_canvas", %{"canvas" => "work"})

      assert assigns(view).safe_mode == nil
      assert assigns(view).showing == :none
      assert render(view) =~ ~s(id="shell-picker")
    end

    test "a listing a decision reads is pushed to every held canvas frame",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})
      tincture!(ctx, "app-dash")

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      view = shell!(conn)
      assert %{state: :live, id: home_id} = canvas(view)
      _reply = handshake!(view, home_id)

      assert_push_event(view, "canvas_installed", %{
        frame: ^home_id,
        tinctures: [%{name: "app-dash"}]
      })

      # Installed after the shell listed its tinctures: the switch's decision
      # reads the listing again, and every held canvas frame is told.
      tincture!(ctx, "plain-dash")
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert %{state: :live} = canvas(view, "work")
      assert %{state: :frozen} = canvas(view, "home")
      assert Enum.sort(Enum.map(assigns(view).tinctures, & &1.name)) == ["app-dash", "plain-dash"]

      assert_push_event(view, "canvas_installed", %{
        frame: ^home_id,
        tinctures: [%{name: "app-dash"}, %{name: "plain-dash"}]
      })
    end

    test "a refreshed listing is pushed to every held canvas frame",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})
      tincture!(ctx, "app-dash")

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      view = shell!(conn)
      assert %{state: :live, id: home_id} = canvas(view)
      _reply = handshake!(view, home_id)

      assert_push_event(view, "canvas_installed", %{
        frame: ^home_id,
        tinctures: [%{name: "app-dash"}]
      })

      tincture!(ctx, "plain-dash")
      send(view.pid, :tinctures_refreshed)
      _ = render(view)
      assert Enum.sort(Enum.map(assigns(view).tinctures, & &1.name)) == ["app-dash", "plain-dash"]

      assert_push_event(view, "canvas_installed", %{
        frame: ^home_id,
        tinctures: [%{name: "app-dash"}, %{name: "plain-dash"}]
      })
    end

    test "a decision whose read changes nothing pushes no installed",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})
      tincture!(ctx, "app-dash")

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      view = shell!(conn)
      assert %{state: :live, id: home_id} = canvas(view)
      _reply = handshake!(view, home_id)

      assert_push_event(view, "canvas_installed", %{
        frame: ^home_id,
        tinctures: [%{name: "app-dash"}]
      })

      # Nothing installed or removed since: the switch's decision reads the
      # same listing, and no frame is pushed `installed`.
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert %{state: :live} = canvas(view, "work")
      assert %{state: :frozen} = canvas(view, "home")
      refute_push_event(view, "canvas_installed", %{frame: _})
    end

    test "a tincture removed since the last read is pushed out at a decision",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})
      tincture!(ctx, "app-dash")
      tincture!(ctx, "plain-dash")

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      view = shell!(conn)
      assert %{state: :live, id: home_id} = canvas(view)
      _reply = handshake!(view, home_id)

      assert_push_event(view, "canvas_installed", %{
        frame: ^home_id,
        tinctures: [%{name: "app-dash"}, %{name: "plain-dash"}]
      })

      unlay!(ctx, "plain-dash")
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert %{state: :live} = canvas(view, "work")
      assert %{state: :frozen} = canvas(view, "home")
      assert Enum.map(assigns(view).tinctures, & &1.name) == ["app-dash"]

      assert_push_event(view, "canvas_installed", %{
        frame: ^home_id,
        tinctures: [%{name: "app-dash"}]
      })
    end

    test "no ancestor of the frames container carries a hook or an event binding",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{state: :live} = canvas(view)

      ancestors = ancestors(view, "#canvas-frames")
      labels = Enum.map(ancestors, &label/1)

      # The walk reaches the canvas layer, the shell and the layout's main.
      assert Enum.take(labels, 2) == ["canvas", "shell"]
      assert "page-content" in labels and "main" in labels

      assert Enum.flat_map(ancestors, &bindings/1) == []
    end
  end

  describe "switching" do
    test "freezes the canvas it leaves whatever it declares, and its apps, and shows the next; nothing wraps",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      tincture!(ctx, "app-dash")

      two_canvases!(ctx, user, athanor, %{
        "desk" => posture([app("tincture:local.app-dash", "window")])
      })

      view = shell!(conn)
      home = canvas(view)
      column = Frames.get(frames(view), {:app, "home", "tincture:local.app-dash"})
      assert %{state: :live, visible: true} = column

      html = render(view)
      assert html =~ ~s(id="canvas-switcher")
      assert html =~ ~s(data-canvas="home")
      assert html =~ ~s(data-canvas="work")
      assert html =~ ~s(id="canvas-shelf")

      # The chord at the first canvas: no wrap.
      render_hook(view, "switch_canvas", %{"direction" => "previous"})
      assert Frames.visible_canvas(frames(view)) == "home"

      view |> element(~s(#canvas-switcher button[data-canvas="work"])) |> render_click()

      assert Frames.visible_canvas(frames(view)) == "work"
      assert %{state: :live, visible: true} = work = canvas(view, "work")
      assert row(work.id).state == "active"
      assert %{state: :frozen, visible: false} = canvas(view)
      assert row(home.id).state == "suspended"
      home_id = home.id
      assert_push_event(view, "frame_state", %{frame: ^home_id, state: "frozen"})

      assert %{state: :frozen, visible: false} =
               Frames.get(frames(view), {:app, "home", "tincture:local.app-dash"})

      # At the last canvas, next goes nowhere.
      render_hook(view, "switch_canvas", %{"direction" => "next"})
      assert Frames.visible_canvas(frames(view)) == "work"

      # Back by the chord: the canvas left is held, frozen, and thaws.
      render_hook(view, "switch_canvas", %{"direction" => "previous"})
      assert %{id: ^home_id, state: :live, visible: true} = canvas(view)
      assert row(home.id).state == "active"
      assert %{state: :frozen} = canvas(view, "work")

      # A canvas the layout does not have, or no canvas at all, is no switch.
      render_hook(view, "switch_canvas", %{"canvas" => "elsewhere"})
      render_hook(view, "switch_canvas", %{"direction" => "sideways"})
      assert Frames.visible_canvas(frames(view)) == "home"
    end

    test "a hidden canvas reads and acts on nothing; shown again, it reads its streams once more, once",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      tincture!(ctx, "app-dash")
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      home = canvas(view)
      bearer = handshake!(view, home.id)["credential"]
      topic = Cyfr.Bus.executions(Sanctum.Context.actor(ctx))

      # The subscriptions a stream's process holds on the runs' topic; other
      # parts of the shell hold their own there.
      held_by = fn pid ->
        for {^pid, _value} <- Registry.lookup(Cyfr.PubSub, topic), do: pid
      end

      open_stream = fn ->
        Task.async(fn -> canvas_stream(home.id, bearer, "runs.changes") end)
      end

      stream = open_stream.()
      wait_until(fn -> held_by.(stream.pid) != [] end, 5_000)

      # Hidden: the switch returns once the canvas is frozen and its
      # credential suspended, which ends its open stream with a refusal.
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert %{state: :frozen, visible: false} = canvas(view)
      assert row(home.id).state == "suspended"
      assert {:error, :suspended} = verify(bearer)

      assert {:ok, ended} = Task.yield(stream, 10_000) || Task.shutdown(stream)

      assert [%{event: "refusal", data: %{"class" => "forbidden"}}] =
               ended.resp_body |> Prima.Test.EventStream.decode() |> Enum.take(-1)

      assert held_by.(stream.pid) == []

      # A later read is refused, and its open and press are dropped.
      later = canvas_stream(home.id, bearer, "runs.changes")
      assert later.status == 403

      assert {:refused, %{class: "forbidden"}} =
               Prima.TinctureWire.decode_answer(:stream_open, Jason.decode!(later.resp_body))

      before = dropped(view)
      canvas_verb!(view, home.id, :open, %{"ref" => "tincture:local.app-dash"})

      canvas_verb!(view, home.id, :press, %{
        "binding" => "feed_01a09fee-2e4f-7a5b-9c6d-7e8f9a0b1c2d",
        "action" => "refresh"
      })

      assert dropped(view) == before + 2
      refute Enum.any?(opened(view), &match?(%{key: {:app, _, "tincture:local.app-dash"}}, &1))

      # Shown again, its credential resumes and a new open reads again,
      # holding one subscription.
      render_hook(view, "switch_canvas", %{"canvas" => "home"})
      assert row(home.id).state == "active"
      assert {:ok, _} = verify(bearer)

      again = open_stream.()
      wait_until(fn -> held_by.(again.pid) != [] end, 5_000)
      assert [_one] = held_by.(again.pid)

      # The stream reads the store after its subscription is in place and at
      # each revalidation, on the test's one shared connection, and a stream
      # killed inside a read takes that connection with it. So the view
      # stops first, while the test still owns the sandbox, and its end
      # revokes the canvas's credential, which closes the stream with a
      # refusal; the stream is awaited to that end, never killed.
      GenServer.stop(view.pid, :normal)
      assert {:ok, closed} = Task.yield(again, 10_000) || Task.shutdown(again)

      assert [%{event: "refusal"}] =
               closed.resp_body |> Prima.Test.EventStream.decode() |> Enum.take(-1)
    end

    test "a canvas shown again keeps its row's deadline and its handshake's bearer",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      home = canvas(view)
      bearer = handshake!(view, home.id)["credential"]
      %{deadline: deadline} = row(home.id)

      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert row(home.id).state == "suspended"
      render_hook(view, "switch_canvas", %{"canvas" => "home"})

      home_id = home.id
      assert %{id: ^home_id, state: :live, deadline: ^deadline} = canvas(view)
      assert %{state: "active", deadline: ^deadline} = row(home.id)
      assert {:ok, %{frame_id: ^home_id, deadline: ^deadline}} = verify(bearer)
      refute_push_event(view, "frame_bearer", %{frame: ^home_id})
    end

    test "a shown canvas's credential is renewed before its deadline and its new bearer pushed for its wire; hidden, it is renewed no more",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      home = canvas(view)
      home_id = home.id
      old = handshake!(view, home_id)["credential"]
      %{deadline: deadline} = row(home_id)

      assert %{^home_id => {timer, token}} = assigns(view).renewals
      Process.cancel_timer(timer)
      send(view.pid, {:frame_renewal, home_id, deadline, token})
      _ = render(view)

      assert_push_event(view, "frame_bearer", %{frame: ^home_id, credential: new})
      refute new == old
      assert {:ok, %{frame_id: ^home_id, deadline: renewed}} = verify(new)
      assert DateTime.compare(renewed, deadline) == :gt
      assert %{state: "active", deadline: ^renewed} = row(home_id)
      assert %{state: :live, deadline: ^renewed, bearer: nil} = canvas(view)

      # The bearer it replaced keeps its own deadline.
      assert {:ok, %{frame_id: ^home_id, deadline: ^deadline}} = verify(old)

      # Armed again for the new deadline while shown; hidden, it is not.
      assert %{^home_id => {_next, next_token}} = assigns(view).renewals
      refute next_token == token
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert row(home_id).state == "suspended"
      refute Map.has_key?(assigns(view).renewals, home_id)
    end

    test "a canvas shown again after its deadline passed is refused, as before",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      deadline_setting!(2)
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      home = canvas(view)
      handshake!(view, home.id)

      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert row(home.id).state == "suspended"

      wait_until(
        fn -> DateTime.compare(row(home.id).deadline, DateTime.utc_now()) == :lt end,
        5_000,
        "the hidden canvas's deadline to pass"
      )

      %{deadline: deadline} = row(home.id)
      render_hook(view, "switch_canvas", %{"canvas" => "home"})

      assert %{state: "revoked", deadline: ^deadline} = row(home.id)
      refute match?(%{state: :live}, canvas(view))
      home_id = home.id
      refute_push_event(view, "frame_bearer", %{frame: ^home_id})
    end

    test "a switch during validation tears the trial down and activates nothing",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      view = shell!(conn)
      trial = validation(view)
      assert %{state: :live} = trial

      render_hook(view, "switch_canvas", %{"canvas" => "work"})

      assert validation(view) == nil
      assert row(trial.id).state == "revoked"
      assert %{working: nil, failed: nil} = versions(ctx, "markets")

      # Its ready, or its deadline, arriving now changes nothing.
      canvas_verb!(view, trial.id, :ready)

      send(view.pid, {:validation_deadline, trial.id})
      _ = render(view)
      assert %{working: nil, failed: nil} = versions(ctx, "markets")

      # Shown again, it is validated again.
      render_hook(view, "switch_canvas", %{"canvas" => "home"})
      assert %{state: :live} = again = validation(view)
      refute again.id == trial.id
    end

    test "a layout change during validation, the canvas given another tincture or dropped, tears the trial down and activates nothing",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      view = shell!(conn)
      trial = validation(view)
      assert %{state: :live, reference: %{name: "markets"}} = trial

      # Given another tincture, the canvas opens as that tincture's versions say.
      layout!(user, athanor, [entry("home", "tincture:local.notes-canvas")])
      settle!(view, fn -> match?(%{reference: %{name: "notes-canvas"}}, canvas(view)) end)

      assert validation(view) == nil
      assert row(trial.id).state == "revoked"
      assert %{working: nil, kept: nil, failed: nil} = versions(ctx, "markets")

      # Given back, it is trialled anew; dropped, its trial goes the same way.
      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      settle!(view, fn -> match?(%{state: :live}, validation(view)) end)
      again = validation(view)
      refute again.id == trial.id

      layout!(user, athanor, [entry("work", "tincture:local.notes-canvas")])
      settle!(view, fn -> match?(%{state: :live}, canvas(view, "work")) end)

      assert validation(view) == nil
      assert row(again.id).state == "revoked"
      assert %{working: nil, kept: nil, failed: nil} = versions(ctx, "markets")
    end
  end

  describe "a validation's grant prompt" do
    # A canvas tincture's owner profile, markets' unless named: `status`
    # :needs_consent while its grant waits for the person, :active once the
    # person granted it its newest version's shape.
    defp owner_head!(ctx, name \\ "markets", status) do
      :ok =
        Sanctum.Test.ConsentFixtures.seed_head!(
          ctx,
          %{
            id: "prof_#{String.replace(name, "-", "_")}",
            kind: :owner,
            source_ref: "tincture:local.#{name}",
            label: "owner",
            status: status
          },
          %{
            id: "cons_#{String.replace(name, "-", "_")}",
            revision: 1,
            scope: :versionless,
            pinned_version: "",
            invoke_mode: :open_inert,
            shape_digest: :live,
            commit_digest: "sha256:commit",
            resolved_policy: Sanctum.Test.ConsentFixtures.empty_policy("tincture:local.#{name}"),
            activation: %{"tincture:local.#{name}" => "sha256:act"}
          }
        )
    end

    test "a version that reads a stream its grant does not name is refused at its trial's open and asks again; confirmed, it is validated under the grant that names it",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})

      canvas!(
        ctx,
        "markets",
        "1.0.1",
        [%{"name" => "runs.changes"}, %{"name" => "mcp_servers.changes"}],
        granted: false
      )

      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)

      # The grant names 1.0.0's streams: 1.0.1's trial opens nothing and
      # the grant is asked for again.
      settle!(view, fn -> assigns(view).grant_prompts != %{} end)
      assert validation(view) == nil
      refute Enum.any?(rows(), &(&1.version == "1.0.1"))
      assert render(view) =~ "Grant tincture:local.markets"

      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
      wait_until(fn -> assigns(view).grant_prompts == %{} end, 5_000, "the grant")

      settle!(view, fn -> match?(%{state: :live}, validation(view)) end)
      assert %{reference: %{name: "markets", version: "1.0.1"}} = trial = validation(view)
      assert row(trial.id).state == "active"
    end

    test "after a wider version's trial fails, the working version asks for its own grant and, granted, opens with no prompt again",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})

      canvas!(
        ctx,
        "markets",
        "1.0.1",
        [%{"name" => "runs.changes"}, %{"name" => "mcp_servers.changes"}],
        granted: false
      )

      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)

      # 1.0.1's trial asks for 1.0.1's grant; granted, it is trialled, and
      # it fails.
      settle!(view, fn -> assigns(view).grant_prompts != %{} end)
      assert render(view) =~ "Grant tincture:local.markets:1.0.1"
      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
      wait_until(fn -> assigns(view).grant_prompts == %{} end, 5_000, "the grant")
      settle!(view, fn -> match?(%{state: :live}, validation(view)) end)
      trial = validation(view)
      canvas_verb!(view, trial.id, :failed, %{"stage" => "load"})

      # The grant now names 1.0.1, so the working 1.0.0 asks for its own.
      settle!(view, fn -> assigns(view).grant_prompts != %{} end)
      assert validation(view) == nil
      assert %{working: "1.0.0", failed: %{version: "1.0.1"}} = versions(ctx, "markets")
      assert render(view) =~ "Grant tincture:local.markets:1.0.0"
      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

      wait_until(
        fn -> assigns(view).grant_prompts == %{} end,
        5_000,
        "the working version's grant"
      )

      # Granted, 1.0.0 opens, and showing it again asks nothing more.
      settle!(view, fn -> match?(%{state: :live}, canvas(view)) end)
      assert %{reference: %{version: "1.0.0"}} = canvas(view)

      layout!(user, athanor, [])
      settle!(view, fn -> canvas(view) == nil end)
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      settle!(view, fn -> match?(%{state: :live}, canvas(view)) end)
      assert %{reference: %{version: "1.0.0"}} = canvas(view)
      assert assigns(view).grant_prompts == %{}
      refute render(view) =~ ~s(data-kind="grant")
    end

    test "a trial refused at its open for want of the grant is torn down at once and asks for it; dismissed, the canvas shows its refusal; confirmed, it is validated again",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      owner_head!(ctx, :needs_consent)
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      view = shell!(conn)

      # Refused at its open, the trial minted nothing and is not held; the
      # prompt is asked as activation's consent_required asks it.
      assert validation(view) == nil
      assert rows() == []
      assert render(view) =~ ~s(data-kind="grant")

      assert [{_prompt, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      # Dismissed, with no working version: the canvas shows its refusal.
      view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()
      _ = render(view)

      assert assigns(view).grant_prompts == %{}
      assert %{state: :refused, refusal: :ungranted} = canvas(view)
      assert validation(view) == nil
      assert assigns(view).safe_mode == nil
      assert rows() == []

      # Shown anew, it is refused at its open and asks again; confirmed,
      # the canvas is validated again under the grant now held.
      layout!(user, athanor, [])
      settle!(view, fn -> canvas(view) == nil end)
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      settle!(view, fn -> assigns(view).grant_prompts != %{} end)
      assert validation(view) == nil

      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
      wait_until(fn -> assigns(view).grant_prompts == %{} end, 5_000, "the grant")

      assert %{state: :live, reference: %{name: "markets"}} = trial = validation(view)
      assert row(trial.id).state == "active"
      assert assigns(view).safe_mode == nil
    end

    for asked_at <- ["activation", "open"] do
      @tag asked_at: asked_at
      test "asked at its #{asked_at}, answered once a newer trial of its canvas is held, it tears down nothing and shows nothing",
           %{conn: conn, ctx: ctx, user: user, athanor: athanor, asked_at: asked_at} do
        canvas!(ctx, "markets")
        canvas!(ctx, "notes-canvas")
        versions!(ctx, "notes-canvas", %{working: "1.0.0"})

        layout!(user, athanor, [
          entry("home", "tincture:local.markets"),
          entry("work", "tincture:local.notes-canvas")
        ])

        # The grant waits for the person: before the trial opens, so its
        # open is refused, or once it is underway, so its ready answers
        # consent_required. Either way the prompt is asked with no trial held.
        if asked_at == "open", do: owner_head!(ctx, :needs_consent)
        view = shell!(conn)
        first = validation(view)

        if asked_at == "activation" do
          assert %{state: :live} = first
          owner_head!(ctx, :needs_consent)
          canvas_verb!(view, first.id, :ready)
          assert row(first.id).state == "revoked"
        end

        assert validation(view) == nil
        assert render(view) =~ ~s(data-kind="grant")

        assert [{_prompt, {{:activation, "home"}, "iframe_markets"}}] =
                 Map.to_list(assigns(view).grant_prompts)

        # The person granted it another way, and the layout published
        # again decides the canvas, still shown, anew: a newer trial starts
        # while the first prompt is still open.
        owner_head!(ctx, :active)

        layout!(user, athanor, [
          entry("home", "tincture:local.markets"),
          entry("work", "tincture:local.notes-canvas")
        ])

        settle!(view, fn -> match?(%{state: :live}, validation(view)) end)
        assert %{state: :live} = newer = validation(view)
        if first, do: refute(first.id == newer.id)

        view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()
        _ = render(view)

        assert assigns(view).grant_prompts == %{}
        newer_id = newer.id
        assert %{id: ^newer_id, state: :live} = validation(view)
        assert row(newer_id).state == "active"
        assert canvas(view) == nil
        assert assigns(view).safe_mode == nil
        assert %{working: nil, kept: nil, failed: nil} = versions(ctx, "markets")
      end
    end
  end

  describe "a grant prompt answered once its canvas was decided again" do
    # The first trial's activation finds the grant waiting, and asks; the
    # grant is then met another way, and a newer trial, started by the
    # layout published again, is refused activation for the slot this
    # member lost.
    # Answers the view, the first prompt and the refusal the canvas shows.
    defp decided_since!(conn, ctx, user, athanor) do
      canvas!(ctx, "markets", "1.0.0")
      canvas!(ctx, "markets", "1.0.1")
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "markets", %{working: "1.0.0"})
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      slot = claimant!()
      view = shell!(conn)

      assert %{state: :live, reference: %{version: "1.0.1"}} = first = validation(view)
      owner_head!(ctx, :needs_consent)
      canvas_verb!(view, first.id, :ready)
      assert validation(view) == nil

      assert [{prompt, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      owner_head!(ctx, :active)

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      settle!(view, fn -> match?(%{state: :live}, validation(view)) end)
      assert %{state: :live} = newer = validation(view)
      take_over!(slot)
      canvas_verb!(view, newer.id, :ready)

      assert validation(view) == nil
      assert %{state: :refused, refusal: :unavailable} = refused = canvas(view)
      assert assigns(view).safe_mode == nil
      {view, prompt, refused}
    end

    test "dismissed after a newer trial ended in not_owner, it leaves the canvas's refusal: no safe mode, nothing opened",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      {view, _prompt, refused} = decided_since!(conn, ctx, user, athanor)
      held = opened(view)
      minted = rows()

      dismiss!(view)

      assert assigns(view).grant_prompts == %{}
      assert assigns(view).safe_mode == nil
      assert canvas(view) == refused
      assert validation(view) == nil
      assert opened(view) == held
      assert rows() == minted
    end

    test "confirmed after a newer trial ended in not_owner, it starts nothing, and the canvas keeps its refusal",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      {view, prompt, refused} = decided_since!(conn, ctx, user, athanor)
      held = opened(view)
      minted = rows()

      # The system layer's report of the confirmed grant, as it sends it
      # once its commit lands.
      send(view.pid, {:system_layer, prompt, :confirmed})
      _ = render(view)

      assert assigns(view).grant_prompts == %{}
      assert assigns(view).safe_mode == nil
      assert canvas(view) == refused
      assert validation(view) == nil
      assert opened(view) == held
      assert rows() == minted
    end
  end

  describe "the live canvas's grant" do
    test "a working version whose grant waits shows its refusal and one grant prompt, never safe mode; decided again while it is open, nothing more is asked; dismissed, the refusal stays, and a layout change decides it again",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      owner_head!(ctx, :needs_consent)
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      view = shell!(conn)

      assert assigns(view).safe_mode == nil

      assert %{state: :refused, refusal: :ungranted, reference: %{version: "1.0.0"}} =
               first = canvas(view)

      assert validation(view) == nil
      assert rows() == []
      assert render(view) =~ ~s(data-kind="grant")

      assert [{prompt, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      # A layout change while the prompt is open decides the canvas again,
      # refused again, and asks nothing more: the open prompt stands.
      first_id = first.id
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      settle!(view, fn ->
        case canvas(view) do
          %{state: :refused, id: id} -> id != first_id
          _deciding -> false
        end
      end)

      assert %{state: :refused, refusal: :ungranted} = refused = canvas(view)

      assert [{^prompt, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      # Dismissed, the refusal stays, and nothing is asked again.
      dismiss!(view)

      assert assigns(view).grant_prompts == %{}
      assert canvas(view) == refused
      refute render(view) =~ ~s(data-kind="grant")
      assert assigns(view).safe_mode == nil

      # A layout change decides the canvas again: refused, it asks once more.
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      settle!(view, fn -> assigns(view).grant_prompts != %{} end)

      assert %{state: :refused, refusal: :ungranted} = again = canvas(view)
      refute again.id == refused.id

      assert [{another, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      refute another == prompt
    end

    test "dismissing a validation's grant prompt when the working version's grant also waits shows the refusal, with no second prompt; a switch back decides it again",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.0.0")
      canvas!(ctx, "markets", "1.0.1")
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "markets", %{working: "1.0.0"})
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})
      owner_head!(ctx, :needs_consent)

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      view = shell!(conn)

      # The newer version's trial is refused at its open, and asks.
      assert validation(view) == nil
      assert canvas(view) == nil

      assert [{_prompt, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      # Dismissed, the working version opens and is refused for want of the
      # same grant: its refusal shows, and nothing is asked again.
      dismiss!(view)

      assert %{state: :refused, refusal: :ungranted, reference: %{version: "1.0.0"}} =
               canvas(view)

      assert assigns(view).grant_prompts == %{}
      refute render(view) =~ ~s(data-kind="grant")
      assert assigns(view).safe_mode == nil
      assert rows() == []

      # A switch back decides the canvas again: its trial is refused and asks once more.
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      render_hook(view, "switch_canvas", %{"canvas" => "home"})

      assert canvas(view) == nil
      assert validation(view) == nil

      assert [{_prompt, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)
    end

    test "decided again while its prompt is open, the prompt stands for the newer decision, and confirming it opens the working version live",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      owner_head!(ctx, :needs_consent)
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      view = shell!(conn)
      assert %{state: :refused, refusal: :ungranted} = first = canvas(view)

      assert [{prompt, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      first_id = first.id
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      settle!(view, fn ->
        case canvas(view) do
          %{state: :refused, id: id} -> id != first_id
          _deciding -> false
        end
      end)

      assert [{^prompt, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
      wait_until(fn -> assigns(view).grant_prompts == %{} end, 5_000, "the grant")

      assert %{state: :live, reference: %{version: "1.0.0"}} = live = canvas(view)
      assert row(live.id).state == "active"
      assert assigns(view).safe_mode == nil
    end

    test "confirming a working version's grant prompt opens the working version live",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      owner_head!(ctx, :needs_consent)
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      view = shell!(conn)
      assert %{state: :refused, refusal: :ungranted} = refused = canvas(view)

      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
      wait_until(fn -> assigns(view).grant_prompts == %{} end, 5_000, "the grant")

      assert %{state: :live, reference: %{version: "1.0.0"}} = live = canvas(view)
      refute live.id == refused.id
      assert row(live.id).state == "active"
      assert validation(view) == nil
      assert assigns(view).safe_mode == nil
    end

    test "a prompt open for one tincture is withdrawn when the layout gives the canvas another tincture whose grant waits: that tincture is asked for its own grant, and its prompt is the one drawn",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "markets", %{working: "1.0.0"})
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})
      owner_head!(ctx, "markets", :needs_consent)
      owner_head!(ctx, "notes-canvas", :needs_consent)
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      view = shell!(conn)
      assert %{state: :refused, refusal: :ungranted, reference: %{name: "markets"}} = canvas(view)

      assert [{markets, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      assert render(view) =~ "Grant tincture:local.markets"

      layout!(user, athanor, [entry("home", "tincture:local.notes-canvas")])
      settle!(view, fn -> match?(%{reference: %{name: "notes-canvas"}}, canvas(view)) end)

      assert %{state: :refused, refusal: :ungranted} = refused = canvas(view)

      # notes-canvas is asked for once, under a prompt of its own; markets'
      # prompt is gone from the shell and from the system layer, and
      # notes-canvas's is the one drawn.
      assert [{notes, {{:activation, "home"}, "iframe_notes-canvas"}}] =
               Map.to_list(assigns(view).grant_prompts)

      refute notes == markets
      refute Map.has_key?(assigns(view).grant_decisions, markets)
      html = render(view)
      assert html =~ ~s(data-prompt-id="#{notes}")
      refute html =~ ~s(data-prompt-id="#{markets}")
      assert html =~ "Grant tincture:local.notes-canvas"
      refute html =~ "Grant tincture:local.markets"

      # Dismissing the prompt drawn answers notes-canvas's own: the canvas
      # keeps its refusal, and nothing more is asked.
      dismiss!(view)

      assert canvas(view) == refused
      assert assigns(view).grant_prompts == %{}
      refute render(view) =~ ~s(data-kind="grant")
      assert assigns(view).safe_mode == nil
    end

    test "a prompt open for one tincture is withdrawn when the layout gives the canvas another tincture that opens live",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "markets", %{working: "1.0.0"})
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})
      owner_head!(ctx, "markets", :needs_consent)
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      view = shell!(conn)
      assert %{state: :refused, reference: %{name: "markets"}} = canvas(view)

      assert [{markets, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      layout!(user, athanor, [entry("home", "tincture:local.notes-canvas")])
      settle!(view, fn -> match?(%{reference: %{name: "notes-canvas"}}, canvas(view)) end)

      assert %{state: :live} = canvas(view)
      assert assigns(view).grant_prompts == %{}
      refute Map.has_key?(assigns(view).grant_decisions, markets)
      html = render(view)
      refute html =~ ~s(data-prompt-id="#{markets}")
      refute html =~ ~s(data-kind="grant")
      assert assigns(view).safe_mode == nil
    end
  end

  describe "a grant prompt whose canvas left the screen" do
    for leaves_by <- ["a switch", "the layout dropping it"] do
      @tag leaves_by: leaves_by
      test "is withdrawn when its canvas leaves by #{leaves_by}, and showing the canvas again asks anew",
           %{conn: conn, ctx: ctx, user: user, athanor: athanor, leaves_by: leaves_by} do
        two_canvases!(ctx, user, athanor)
        owner_head!(ctx, "markets", :needs_consent)

        view = shell!(conn)
        assert %{state: :refused, refusal: :ungranted} = canvas(view)

        assert [{markets, {{:activation, "home"}, "iframe_markets"}}] =
                 Map.to_list(assigns(view).grant_prompts)

        assert render(view) =~ ~s(data-prompt-id="#{markets}")

        case leaves_by do
          "a switch" ->
            render_hook(view, "switch_canvas", %{"canvas" => "work"})

          "the layout dropping it" ->
            layout!(user, athanor, [entry("work", "tincture:local.notes-canvas")])
            settle!(view, fn -> Frames.visible_canvas(frames(view)) == "work" end)
        end

        assert %{state: :live} = canvas(view, "work")
        assert assigns(view).grant_prompts == %{}
        refute Map.has_key?(assigns(view).grant_decisions, markets)
        html = render(view)
        refute html =~ ~s(data-prompt-id="#{markets}")
        refute html =~ ~s(data-kind="grant")

        # Shown again, markets is decided again and asks under a new prompt.
        case leaves_by do
          "a switch" ->
            render_hook(view, "switch_canvas", %{"canvas" => "home"})

          "the layout dropping it" ->
            layout!(user, athanor, [
              entry("home", "tincture:local.markets"),
              entry("work", "tincture:local.notes-canvas")
            ])

            settle!(view, fn -> Enum.any?(assigns(view).arrangement, &(&1.id == "home")) end)
            render_hook(view, "switch_canvas", %{"canvas" => "home"})
        end

        assert [{again, {{:activation, "home"}, "iframe_markets"}}] =
                 Map.to_list(assigns(view).grant_prompts)

        refute again == markets
        assert render(view) =~ ~s(data-prompt-id="#{again}")
      end
    end

    test "safe mode withdraws every grant prompt the shell raised, so safe mode's prompt is the one drawn",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      two_canvases!(ctx, user, athanor)
      owner_head!(ctx, "markets", :needs_consent)

      view = shell!(conn)

      assert [{markets, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      assert render(view) =~ ~s(data-prompt-id="#{markets}")

      render_click(view, "safe_mode", %{})
      %{id: safe_mode} = assigns(view).safe_mode

      assert assigns(view).grant_prompts == %{}
      html = render(view)
      assert html =~ ~s(data-prompt-id="#{safe_mode}")
      assert html =~ ~s(data-kind="safe_mode")
      refute html =~ ~s(data-prompt-id="#{markets}")
      refute html =~ "Grant tincture:local.markets"
    end
  end

  describe "a canvas's open" do
    setup %{ctx: ctx, user: user, athanor: athanor} do
      tincture!(ctx, "full-dash")
      tincture!(ctx, "column-dash")
      tincture!(ctx, "loose-dash")
      tincture!(ctx, "clock")

      two_canvases!(ctx, user, athanor, %{
        "desk" =>
          posture([
            app("tincture:local.full-dash", "full", 0, true),
            app("tincture:local.clock", "window", 1, true)
          ]),
        "hand" => posture([])
      })

      :ok
    end

    test "opens a listed tincture where the arrangement puts it, or as a window on the desk, and writes it",
         %{conn: conn} do
      view = shell!(conn)
      id = canvas(view).id

      # A minimised app is placed but not opened with the canvas.
      assert Frames.get(frames(view), {:app, "home", "tincture:local.clock"}) == nil
      assert Frames.get(frames(view), {:app, "home", "tincture:local.full-dash"}) == nil

      canvas_verb!(view, id, :open, %{"ref" => "tincture:local.full-dash"})

      assert %{placement: :full, visible: true, state: :live} =
               Frames.get(frames(view), {:app, "home", "tincture:local.full-dash"})

      # Closing it closes the app on the layout too.
      render_click(view, "close_active_tincture", %{})
      assert Frames.get(frames(view), {:app, "home", "tincture:local.full-dash"}) == nil

      canvas_verb!(view, id, :open, %{"ref" => "tincture:local.loose-dash"})
      canvas_verb!(view, id, :open, %{"ref" => "tincture:local.column-dash"})

      assert %{placement: {:window, loose}, visible: true} =
               Frames.get(frames(view), {:app, "home", "tincture:local.loose-dash"})

      assert %{placement: {:window, column}, visible: true} =
               Frames.get(frames(view), {:app, "home", "tincture:local.column-dash"})

      assert column.x > loose.x

      # The minimised window, asked for, comes back where it stood.
      canvas_verb!(view, id, :open, %{"ref" => "tincture:local.clock"})

      assert %{placement: {:window, %{x: 1000, y: 1000}}, visible: true} =
               Frames.get(frames(view), {:app, "home", "tincture:local.clock"})

      # Every open is the person's, written once the gestures settle.
      send(view.pid, :write_layout)
      _ = render(view)

      assert {:ok, %{revision: 2, arrangement: [home | _]}} =
               Compendium.layout(person_of(view), "desk")

      assert Enum.map(home.apps, &{&1.tincture, &1.minimised}) == [
               {"tincture:local.loose-dash", false},
               {"tincture:local.column-dash", false},
               {"tincture:local.clock", false}
             ]

      assert dropped(view) == 0
    end

    test "opens full in the hand", %{conn: conn} do
      view = shell!(conn)
      view |> element("#canvas-hook") |> render_hook("posture", %{"posture" => "hand"})
      settle!(view, fn -> assigns(view).posture == "hand" end)

      canvas_verb!(view, canvas(view).id, :open, %{"ref" => "tincture:local.loose-dash"})

      assert %{placement: :full, visible: true} =
               Frames.get(frames(view), {:app, "home", "tincture:local.loose-dash"})
    end

    test "an open with an extra key, of an unlisted tincture or a canvas, or from a hidden canvas, is dropped",
         %{conn: conn} do
      view = shell!(conn)
      home = canvas(view).id

      render_hook(view, "frame_verb", %{
        "frame" => home,
        "message" => %{
          "v" => 1,
          "verb" => "open",
          "frame" => home,
          "args" => %{"ref" => "tincture:local.loose-dash", "place" => "full"}
        }
      })

      canvas_verb!(view, home, :open, %{"ref" => "tincture:local.nobody"})
      canvas_verb!(view, home, :open, %{"ref" => "tincture:local.notes-canvas"})

      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      canvas_verb!(view, home, :open, %{"ref" => "tincture:local.loose-dash"})

      assert dropped(view) == 4
      refute Enum.any?(opened(view), &match?(%{key: {:app, _, "tincture:local.loose-dash"}}, &1))
    end

    test "a canvas's title, close and credential are dropped: it acts only on ready, failed, open and press",
         %{conn: conn} do
      view = shell!(conn)
      home = canvas(view).id

      canvas_verb!(view, home, :title, %{"title" => "Mine"})
      canvas_verb!(view, home, :close)
      canvas_verb!(view, home, :credential, %{"name" => "api"})

      assert dropped(view) == 3
      assert %{state: :live} = canvas(view)
      assert assigns(view).credential_prompts == %{}
    end

    test "a message naming another frame than the port it came from, or malformed, is dropped",
         %{conn: conn} do
      view = shell!(conn)
      home = canvas(view).id

      # The port's frame and the message's differ.
      render_hook(view, "frame_verb", %{
        "frame" => home,
        "message" =>
          Prima.TinctureWire.shell_message(:open, "frm_another_frame", %{
            "ref" => "tincture:local.loose-dash"
          })
      })

      # A press with arguments its verb does not take, and a failure at no stage.
      canvas_verb!(view, home, :press, %{"binding" => "btc", "action" => "refresh"})
      canvas_verb!(view, home, :failed, %{"stage" => "boot"})

      assert dropped(view) == 3
      assert %{state: :live} = canvas(view)
      assert assigns(view).safe_mode == nil
      refute Enum.any?(opened(view), &match?(%{key: {:app, _, "tincture:local.loose-dash"}}, &1))
    end
  end

  describe "a canvas's press" do
    # A live feed of the athanor, `name`, with one refresh action.
    defp feed!(ctx, name) do
      {:ok, binding} =
        Prima.Feed.Binding.validate(%{
          "name" => name,
          "label" => "A feed",
          "reference" => "catalyst:local.markets",
          "operation" => "quote",
          "args" => %{},
          "interval_minutes" => 5,
          "result_shape" => %{"type" => "json"},
          "actions" => [%{"name" => "refresh", "label" => "Refresh", "kind" => "refresh"}]
        })

      {:ok, row} =
        Arca.CronSchedule.create_feed(Sanctum.Context.actor(ctx), %{
          binding: binding,
          resolved_reference: "catalyst:local.markets:1.0.0",
          profile_id: "prof_feed_#{name}",
          cap: 10
        })

      row.id
    end

    defp pressed(ctx) do
      Arca.Repo.all(
        from(d in Arca.Schemas.DecisionLog,
          where: d.athanor_id == ^ctx.athanor_id and d.tool == "feed" and d.action == "press"
        )
      )
    end

    setup %{ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.0.0", [
        %{"name" => "feed.results", "subject" => "btc"},
        %{"name" => "runs.changes"}
      ])

      canvas!(ctx, "notes-canvas")
      versions!(ctx, "markets", %{working: "1.0.0"})
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      {:ok, btc: feed!(ctx, "btc"), eth: feed!(ctx, "eth")}
    end

    test "from the visible live canvas whose version reads the feed, it reaches feed.press",
         %{conn: conn, ctx: ctx, btc: btc} do
      view = shell!(conn)

      # An action the binding does not declare: feed.press refuses it, the
      # refusal is logged by class, and the canvas is told nothing.
      canvas_verb!(view, canvas(view).id, :press, %{"binding" => btc, "action" => "zap"})

      assert [%{admission: "admitted"}] = pressed(ctx)
      assert dropped(view) == 0
    end

    test "for an undeclared feed, a binding that is not live, or from a hidden or another frame, it is dropped",
         %{conn: conn, ctx: ctx, eth: eth, btc: btc} do
      view = shell!(conn)
      home = canvas(view).id

      # A feed the served version does not read.
      canvas_verb!(view, home, :press, %{"binding" => eth, "action" => "refresh"})

      # A binding id that is no live feed of the athanor.
      gone = "feed_01a09fee-2e4f-7a5b-9c6d-7e8f9a0b1c2d"
      canvas_verb!(view, home, :press, %{"binding" => gone, "action" => "refresh"})

      # From a frozen, hidden canvas.
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      canvas_verb!(view, home, :press, %{"binding" => btc, "action" => "refresh"})

      # From a canvas whose version reads no feed.
      canvas_verb!(view, canvas(view, "work").id, :press, %{
        "binding" => btc,
        "action" => "refresh"
      })

      assert dropped(view) == 4
      assert pressed(ctx) == []
    end

    test "a press or a failure from a frame that is no canvas's is dropped",
         %{conn: conn, ctx: ctx, btc: btc} do
      tincture!(ctx, "app-dash")
      view = shell!(conn)
      canvas_verb!(view, canvas(view).id, :open, %{"ref" => "tincture:local.app-dash"})

      assert %{id: app, state: :live, visible: true} =
               Frames.get(frames(view), {:app, "home", "tincture:local.app-dash"})

      before = dropped(view)
      canvas_verb!(view, app, :press, %{"binding" => btc, "action" => "refresh"})
      canvas_verb!(view, app, :failed, %{"stage" => "runtime"})

      assert dropped(view) == before + 2
      assert pressed(ctx) == []
      assert assigns(view).safe_mode == nil
      assert %{state: :live} = canvas(view)
    end
  end

  describe "safe mode" do
    test "asked for, safe mode revokes every credential the shell minted and draws the prompt",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      tincture!(ctx, "app-dash")

      two_canvases!(ctx, user, athanor, %{
        "desk" => posture([app("tincture:local.app-dash", "full", 0, true)])
      })

      view = shell!(conn)
      canvas_verb!(view, canvas(view).id, :open, %{"ref" => "tincture:local.app-dash"})
      minted = Enum.map(opened(view), & &1.id)
      assert length(minted) == 2

      render_click(view, "safe_mode", %{})

      assert opened(view) == []
      for id <- minted, do: assert(row(id).state == "revoked")

      html = render(view)
      refute html =~ ~s(id="shell-picker")
      refute html =~ ~s(id="canvas-switcher")
      assert html =~ ~s(data-kind="safe_mode")
      assert html =~ "You turned safe mode on."

      # Nothing launches while it is on, and a second ask is the same safe mode.
      render_click(view, "select_tincture", %{"tincture" => "iframe_app-dash"})
      render_click(view, "safe_mode", %{})
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert opened(view) == []
      assert Frames.visible_canvas(frames(view)) == "home"
    end

    test "choosing the kept version restores it and opens only that canvas",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.0.0")
      canvas!(ctx, "markets", "1.0.1")
      canvas!(ctx, "notes-canvas")
      versions!(ctx, "markets", %{working: "1.0.1", kept: "1.0.0"})
      versions!(ctx, "notes-canvas", %{working: "1.0.0"})

      layout!(user, athanor, [
        entry("home", "tincture:local.markets"),
        entry("work", "tincture:local.notes-canvas")
      ])

      view = shell!(conn)
      assert %{reference: %{version: "1.0.1"}} = canvas(view)

      render_click(view, "safe_mode", %{})
      html = render(view)
      assert html =~ "Go back to the version before"
      assert html =~ "Use the shipped canvas"

      view |> element(~s(#system-layer-dialog button[phx-value-offer="kept"])) |> render_click()
      settle!(view, fn -> canvas(view) != nil end)

      assert %{working: "1.0.0", kept: "1.0.1"} = versions(ctx, "markets")

      # Restored, the newest version is the kept one: nothing is validated,
      # and only the visible canvas opens, at its working version.
      assert [%{key: {:canvas, "home"}, state: :live, reference: %{version: "1.0.0"}}] =
               opened(view)

      assert assigns(view).safe_mode == nil
      refute render(view) =~ ~s(id="shell-picker")
    end

    test "the shipped canvas is shown on this glass alone, nothing is written, and it stays until the layout names another canvas",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      # The install media ships the canvas: a seed tree of this test's own,
      # restored when it ends.
      seed =
        Path.join(System.tmp_dir!(), "shell_canvas_seed_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(seed, "components/tinctures/local/canvas"))
      shipped = Path.basename(seed())
      File.cp_r!(seed(), Path.join(seed, "components/tinctures/local/canvas/#{shipped}"))
      previous = Application.get_env(:arca, :seed_path)
      Application.put_env(:arca, :seed_path, seed)

      on_exit(fn ->
        Application.put_env(:arca, :seed_path, previous)
        File.rm_rf(seed)
      end)

      shipped!(ctx)
      tincture!(ctx, "fallback-app")
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      {:ok, %{revision: layout_revision}} = Compendium.layout(person(user, athanor), "desk")

      view = shell!(conn)
      render_click(view, "safe_mode", %{})

      view
      |> element(~s(#system-layer-dialog button[phx-value-offer="shipped"]))
      |> render_click()

      settle!(view, fn -> canvas(view) != nil end)

      assert %{reference: %{name: "canvas", version: ^shipped}, state: :live} = canvas(view)
      assert validation(view) == nil

      assert {:ok, %{revision: ^layout_revision}} =
               Compendium.layout(person(user, athanor), "desk")

      assert {:error, :not_found} = Arca.CanvasVersions.get(Sanctum.Context.actor(ctx), "canvas")
      assert %{working: "1.0.0"} = versions(ctx, "markets")

      # A publication that only arranges, the canvas's tincture kept, keeps
      # the shipped canvas: saving a gesture never opens the failed one.
      shipped_id = canvas(view).id
      layout!(user, athanor, [entry("home", "tincture:local.markets", %{"desk" => posture([])})])
      settle!(view, fn -> assigns(view).layout_base.revision == layout_revision + 1 end)
      assert %{id: ^shipped_id, reference: %{name: "canvas"}} = canvas(view)

      # A layout naming another tincture for the canvas lets it go, and
      # that canvas opens; read when a gesture's write meets it as a newer
      # revision, it lets it go all the same.
      canvas!(ctx, "markets-two")
      versions!(ctx, "markets-two", %{working: "1.0.0"})
      render_hook(view, "app_open", %{"ref" => "tincture:local.fallback-app"})
      assert_reply(view, %{ok: true})
      layout!(user, athanor, [entry("home", "tincture:local.markets-two")])
      send(view.pid, :write_layout)
      _ = render(view)
      assert assigns(view).pending == []
      assert assigns(view).shipped == nil
      settle!(view, fn -> match?(%{reference: %{name: "markets-two"}}, canvas(view)) end)
      assert row(shipped_id).state == "revoked"
    end

    test "a canvas that sends ready before its deadline is not safe mode; one that never does is",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      id = canvas(view).id
      handshake!(view, id)

      # Ready at nine seconds: before the deadline message.
      canvas_verb!(view, id, :ready)
      deadlines_pass!(view)
      assert assigns(view).safe_mode == nil
      assert %{id: ^id, state: :live} = canvas(view)

      # A canvas opened again that never says it is ready.
      render_click(view, "safe_mode", %{})
      assert assigns(view).canvas_deadlines == %{}
      view |> element(~s(#system-layer-dialog button[phx-value-offer="retry"])) |> render_click()
      settle!(view, fn -> canvas(view) != nil end)
      again = canvas(view).id
      refute again == id
      handshake!(view, again)

      deadlines_pass!(view)
      assert %{reason: :not_ready} = assigns(view).safe_mode
      assert opened(view) == []
      assert row(again).state == "revoked"
      assert render(view) =~ "Your canvas did not start."
    end

    test "a canvas whose frame opens and never handshakes is safe mode not_ready at its deadline",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      render_click(view, "safe_mode", %{})

      view |> element(~s(#system-layer-dialog button[phx-value-offer="retry"])) |> render_click()
      settle!(view, fn -> canvas(view) != nil end)

      # Its deadline is armed at its open, with no handshake: the page never
      # took its credential.
      assert %{id: id, state: :live} = canvas(view)
      assert row(id).state == "active"
      assert %{^id => {timer, _token}} = assigns(view).canvas_deadlines
      assert is_integer(Process.read_timer(timer))
      refute MapSet.member?(assigns(view).canvas_ready, id)

      # The deadline fires: its timer's own message reaches the shell.
      wait_until(fn -> assigns(view).safe_mode != nil end, 30_000, "the ready deadline")
      assert Process.read_timer(timer) == false
      assert %{reason: :not_ready} = assigns(view).safe_mode
      assert opened(view) == []
      assert row(id).state == "revoked"
      refute Map.has_key?(assigns(view).canvas_deadlines, id)
    end

    test "a handshake arms no second deadline", %{
      conn: conn,
      ctx: ctx,
      user: user,
      athanor: athanor
    } do
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      id = canvas(view).id
      assert %{^id => {timer, _token}} = deadlines = assigns(view).canvas_deadlines
      assert map_size(deadlines) == 1

      handshake!(view, id)

      # The timer armed at the open runs on, the only one.
      assert assigns(view).canvas_deadlines == deadlines
      assert is_integer(Process.read_timer(timer))
    end

    test "a canvas opened hidden runs no deadline; shown, it has the whole period from its showing, and is safe mode not_ready once that passes",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      view = opened_hidden!(conn, ctx, user, athanor)
      %{id: id} = canvas(view)

      # Opened hidden: the shell runs no ready deadline for it.
      refute Map.has_key?(assigns(view).canvas_deadlines, id)

      # Shown, however near the end of a period counted from its open that
      # is: the whole period runs from its showing.
      shown_at = System.monotonic_time(:millisecond)
      render_click(view, "close_active_tincture", %{})
      assert %{id: ^id, state: :live, visible: true} = canvas(view)
      assert %{^id => {timer, token}} = assigns(view).canvas_deadlines
      assert map_size(assigns(view).canvas_deadlines) == 1

      # Its deadline, the only one held, falls due no sooner than the whole
      # period from its showing, within the clocks' millisecond rounding.
      assert fires_at(timer) >= shown_at + @ready_ms - 2

      # Before then nothing sends it to safe mode: a deadline that is not
      # the one held changes nothing.
      send(view.pid, {:canvas_deadline, id, make_ref()})
      _ = render(view)
      assert assigns(view).safe_mode == nil
      assert %{^id => {^timer, ^token}} = assigns(view).canvas_deadlines

      # The whole period passes, and it is still not ready.
      deadlines_pass!(view)
      assert %{reason: :not_ready} = assigns(view).safe_mode
      assert opened(view) == []
      assert row(id).state == "revoked"
    end

    test "a canvas never shown never goes to safe mode not_ready",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      view = opened_hidden!(conn, ctx, user, athanor)
      %{id: id} = canvas(view)
      refute Map.has_key?(assigns(view).canvas_deadlines, id)

      # Time passes: every deadline the shell holds falls due.
      deadlines_pass!(view)
      assert assigns(view).safe_mode == nil

      # Away to `work` and back, which shows the full frame over `home`
      # again: the canvas is never shown, and no deadline is ever its.
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert %{state: :live, visible: true} = canvas(view, "work")
      assert %{state: :frozen, visible: false} = canvas(view)
      refute Map.has_key?(assigns(view).canvas_deadlines, id)

      render_hook(view, "switch_canvas", %{"canvas" => "home"})
      assert %{id: ^id, state: :frozen, visible: false} = canvas(view)
      assert assigns(view).canvas_deadlines == %{}

      deadlines_pass!(view)
      assert assigns(view).safe_mode == nil
      assert %{id: ^id, state: :frozen} = canvas(view)
    end

    test "a stale deadline, for a canvas no longer held or a timer cancelled since, changes nothing",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      id = canvas(view).id
      assert %{^id => held} = assigns(view).canvas_deadlines

      send(view.pid, {:canvas_deadline, "frm_not_this_canvas", make_ref()})
      # The shown canvas's frame, under a token other than the one held: a
      # timer cancelled after it fired.
      send(view.pid, {:canvas_deadline, id, make_ref()})
      _ = render(view)

      assert assigns(view).safe_mode == nil
      assert %{^id => ^held} = assigns(view).canvas_deadlines
    end

    for stage <- ["load", "runtime"] do
      @tag stage: stage
      test "a canvas that reports a failure at #{stage} is safe mode crashed, its kept version offered",
           %{conn: conn, ctx: ctx, user: user, athanor: athanor, stage: stage} do
        two_canvases!(ctx, user, athanor)
        canvas!(ctx, "markets", "1.0.1")
        versions!(ctx, "markets", %{working: "1.0.1", kept: "1.0.0"})
        view = shell!(conn)
        assert %{reference: %{version: "1.0.1"}} = canvas(view)

        canvas_verb!(view, canvas(view).id, :failed, %{"stage" => stage})

        assert %{reason: :crashed} = assigns(view).safe_mode
        assert opened(view) == []
        html = render(view)
        assert html =~ "Your canvas stopped working."
        assert html =~ ~s(phx-value-offer="kept")
      end
    end

    test "the visible canvas's frame dying is safe mode crashed", %{
      conn: conn,
      ctx: ctx,
      user: user,
      athanor: athanor
    } do
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      home = canvas(view)

      render_hook(view, "frame_gone", %{"frame" => home.id})

      assert %{reason: :crashed} = assigns(view).safe_mode
      assert opened(view) == []
      assert row(home.id).state == "revoked"
      assert render(view) =~ "Your canvas stopped working."
    end

    test "a hidden canvas's frame dying is torn down with no call, and showing it again opens it anew",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      home = canvas(view)
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert %{state: :frozen} = canvas(view)

      render_hook(view, "frame_gone", %{"frame" => home.id})

      assert canvas(view) == nil
      assert row(home.id).state == "revoked"
      assert assigns(view).safe_mode == nil
      assert %{state: :live, visible: true} = canvas(view, "work")
      assert %{working: "1.0.0", failed: nil} = versions(ctx, "markets")

      render_hook(view, "switch_canvas", %{"canvas" => "home"})
      assert %{state: :live, visible: true} = again = canvas(view)
      refute again.id == home.id
      assert row(again.id).state == "active"
    end

    # A canvas hidden by a switch, or frozen under a full frame over it,
    # and shown again by the switch back or the full frame's close.
    for hidden_by <- [:switch, :full_frame] do
      @tag hidden_by: hidden_by
      test "a canvas hidden by #{hidden_by} that reports ready is ready: no deadline, hidden or shown again, is safe mode",
           %{conn: conn, ctx: ctx, user: user, athanor: athanor, hidden_by: hidden_by} do
        view = hidden_canvas!(conn, ctx, user, athanor, hidden_by)
        home = canvas(view)
        assert %{state: :frozen, visible: false} = home
        before = dropped(view)

        canvas_verb!(view, home.id, :ready)

        assert dropped(view) == before
        assert MapSet.member?(assigns(view).canvas_ready, home.id)

        # Hidden, it runs no deadline; shown again, ready, it is given none.
        refute Map.has_key?(assigns(view).canvas_deadlines, home.id)
        show_again!(view, hidden_by)
        assert %{id: id, state: :live, visible: true} = canvas(view)
        assert id == home.id
        refute Map.has_key?(assigns(view).canvas_deadlines, home.id)

        deadlines_pass!(view)
        assert assigns(view).safe_mode == nil
      end

      @tag hidden_by: hidden_by
      test "a canvas hidden by #{hidden_by} before it is ready runs no deadline while hidden, and shown again has the whole period from its showing",
           %{conn: conn, ctx: ctx, user: user, athanor: athanor, hidden_by: hidden_by} do
        view = hidden_canvas!(conn, ctx, user, athanor, hidden_by)
        home = canvas(view)
        refute Map.has_key?(assigns(view).canvas_deadlines, home.id)

        # Time passes while it is hidden: whatever the shell holds falls due,
        # and none of it is this canvas's. The canvas shown meanwhile, if
        # any, is ready.
        for %{key: {:canvas, _}, state: :live, id: shown} <- opened(view),
            do: canvas_verb!(view, shown, :ready)

        deadlines_pass!(view)
        assert assigns(view).safe_mode == nil
        assert %{state: :frozen} = canvas(view)

        shown_at = System.monotonic_time(:millisecond)
        show_again!(view, hidden_by)
        assert %{id: id, state: :live, visible: true} = canvas(view)
        assert id == home.id
        assert %{^id => {timer, _token}} = assigns(view).canvas_deadlines

        # Its deadline falls due no sooner than the whole period from its
        # showing, within the clocks' millisecond rounding.
        assert fires_at(timer) >= shown_at + @ready_ms - 2

        deadlines_pass!(view)
        assert %{reason: :not_ready} = assigns(view).safe_mode
      end

      @tag hidden_by: hidden_by
      test "a canvas hidden by #{hidden_by} that reports a failure is died: nothing while hidden, safe mode crashed once shown",
           %{conn: conn, ctx: ctx, user: user, athanor: athanor, hidden_by: hidden_by} do
        view = hidden_canvas!(conn, ctx, user, athanor, hidden_by)
        home = canvas(view)
        before = dropped(view)

        canvas_verb!(view, home.id, :failed, %{"stage" => "runtime"})

        # Hidden, it acts on nothing and is held as it was.
        assert dropped(view) == before
        assert assigns(view).safe_mode == nil
        assert MapSet.member?(assigns(view).canvas_died, home.id)
        assert %{id: id, state: :frozen} = canvas(view)
        assert id == home.id

        # Shown again, it is safe mode crashed, as a failure while shown is,
        # its kept version offered.
        show_again!(view, hidden_by)
        assert %{reason: :crashed} = assigns(view).safe_mode
        assert opened(view) == []
        assert row(home.id).state == "revoked"
        html = render(view)
        assert html =~ "Your canvas stopped working."
        assert html =~ ~s(phx-value-offer="kept")
      end
    end

    test "a canvas refused at open is safe mode", %{
      conn: conn,
      ctx: ctx,
      user: user,
      athanor: athanor
    } do
      # Named as the layout's canvas, but not declared as one.
      tincture!(ctx, "plain-dash")
      layout!(user, athanor, [entry("home", "tincture:local.plain-dash")])
      view = shell!(conn)

      assert %{reason: :not_ready} = assigns(view).safe_mode
      assert opened(view) == []
      assert rows() == []
      refute render(view) =~ ~s(id="shell-picker")
      assert render(view) =~ "Your canvas did not start."
    end

    test "a working version refused at its open for anything but its grant is safe mode", %{
      conn: conn,
      ctx: ctx,
      user: user,
      athanor: athanor
    } do
      # The listed version is a canvas; the working one is not declared as one.
      lay!(ctx, "markets", "1.0.0", %{"entry" => "index.html"}, [
        {"index.html", "<html><head></head><body>markets</body></html>"}
      ])

      canvas!(ctx, "markets", "1.0.1")
      versions!(ctx, "markets", %{working: "1.0.0", kept: "1.0.1"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)

      assert %{reason: :not_ready} = assigns(view).safe_mode
      assert opened(view) == []
      assert rows() == []
      assert assigns(view).grant_prompts == %{}
      assert render(view) =~ "Your canvas did not start."
    end
  end

  describe "the shipped canvas's grant" do
    # Safe mode's shipped canvas, chosen while its own grant waits for the
    # person. Answers the view, the layout's revision and the refusal shown.
    defp shipped_ungranted!(conn, ctx, user, athanor) do
      shipped_seed!()
      shipped!(ctx)
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      {:ok, %{revision: revision}} = Compendium.layout(person(user, athanor), "desk")

      view = shell!(conn)
      assert %{state: :live, reference: %{name: "markets"}} = canvas(view)
      render_click(view, "safe_mode", %{})
      owner_head!(ctx, "canvas", :needs_consent)

      view
      |> element(~s(#system-layer-dialog button[phx-value-offer="shipped"]))
      |> render_click()

      settle!(view, fn -> canvas(view) != nil end)

      assert %{reference: %{name: "canvas"}, state: :refused, refusal: :ungranted} =
               refused = canvas(view)

      {view, revision, refused}
    end

    test "refused for want of its grant, it asks for tincture:local.canvas's grant; confirmed, the shipped canvas opens live and nothing is written",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      {view, revision, refused} = shipped_ungranted!(conn, ctx, user, athanor)

      html = render(view)
      assert html =~ "Grant tincture:local.canvas"
      refute html =~ "Grant tincture:local.markets"

      assert [{_prompt, {{:activation, "home"}, "iframe_canvas"}}] =
               Map.to_list(assigns(view).grant_prompts)

      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
      wait_until(fn -> assigns(view).grant_prompts == %{} end, 5_000, "the grant")

      assert %{reference: %{name: "canvas"}, state: :live} = live = canvas(view)
      refute live.id == refused.id
      assert row(live.id).state == "active"
      assert assigns(view).shipped == "home"
      assert assigns(view).safe_mode == nil
      assert {:ok, %{revision: ^revision}} = Compendium.layout(person(user, athanor), "desk")
      assert {:error, :not_found} = Arca.CanvasVersions.get(Sanctum.Context.actor(ctx), "canvas")
      assert %{working: "1.0.0"} = versions(ctx, "markets")
    end

    test "dismissed, the shipped canvas's refusal stays", %{
      conn: conn,
      ctx: ctx,
      user: user,
      athanor: athanor
    } do
      {view, _revision, refused} = shipped_ungranted!(conn, ctx, user, athanor)

      dismiss!(view)

      assert assigns(view).grant_prompts == %{}
      assert canvas(view) == refused
      assert assigns(view).shipped == "home"
      assert assigns(view).safe_mode == nil
      refute render(view) =~ ~s(data-kind="grant")
    end
  end

  describe "a layout change whose read fails" do
    test "keeps the canvas's refusal, and draws the layout note once",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      owner_head!(ctx, :needs_consent)
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      view = shell!(conn)
      assert %{state: :refused, refusal: :ungranted} = refused = canvas(view)
      dismiss!(view)
      assert canvas(view) == refused

      break_layout!(ctx, user, athanor)
      published!(view, ctx, user)
      settle!(view, fn -> layout_notes(view) == 1 end)

      assert canvas(view) == refused
      assert render(view) =~ ~s(data-tincture-state=)
      assert assigns(view).safe_mode == nil
      assert assigns(view).grant_prompts == %{}
      refute render(view) =~ ~s(id="shell-picker")
    end

    test "keeps the shipped canvas safe mode chose, and draws the layout note once",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      shipped_seed!()
      shipped!(ctx)
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      view = shell!(conn)
      render_click(view, "safe_mode", %{})

      view
      |> element(~s(#system-layer-dialog button[phx-value-offer="shipped"]))
      |> render_click()

      settle!(view, fn -> canvas(view) != nil end)
      assert %{reference: %{name: "canvas"}, state: :live} = shipped = canvas(view)

      break_layout!(ctx, user, athanor)
      published!(view, ctx, user)
      settle!(view, fn -> layout_notes(view) == 1 end)

      assert canvas(view) == shipped
      assert row(shipped.id).state == "active"
      assert assigns(view).shipped == "home"
      assert assigns(view).safe_mode == nil
      refute render(view) =~ ~s(id="shell-picker")
    end

    test "keeps the live canvas, and draws the layout note once",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      view = shell!(conn)
      assert %{state: :live} = live = canvas(view)

      break_layout!(ctx, user, athanor)
      published!(view, ctx, user)
      settle!(view, fn -> layout_notes(view) == 1 end)

      assert canvas(view) == live
      assert row(live.id).state == "active"
    end

    test "at mount, with nothing shown, draws the picker and the layout note once",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])
      break_layout!(ctx, user, athanor)

      view = shell!(conn)

      assert assigns(view).showing == :none
      assert opened(view) == []
      assert render(view) =~ ~s(id="shell-picker")
      assert layout_notes(view) == 1
    end

    test "a change whose read failed before safe mode does not drop the shipped canvas chosen after it",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      shipped_seed!()
      shipped!(ctx)
      canvas!(ctx, "markets")
      versions!(ctx, "markets", %{working: "1.0.0"})
      layout!(user, athanor, [entry("home", "tincture:local.markets")])

      view = shell!(conn)
      assert %{state: :live, reference: %{name: "markets"}} = canvas(view)

      # A layout published whose read fails; then the store answers again.
      digest = layout_digest(ctx, user)
      break_layout!(ctx, user, athanor)
      published!(view, ctx, user)
      settle!(view, fn -> layout_notes(view) == 1 end)
      assert %{state: :live, reference: %{name: "markets"}} = canvas(view)
      mend_layout!(ctx, user, athanor, digest)

      # Only then the person enters safe mode and chooses the shipped canvas.
      render_click(view, "safe_mode", %{})

      view
      |> element(~s(#system-layer-dialog button[phx-value-offer="shipped"]))
      |> render_click()

      settle!(view, fn -> canvas(view) != nil end)

      assert %{reference: %{name: "canvas"}, state: :live} = canvas(view)
      assert assigns(view).shipped == "home"
      assert layout_notes(view) == 0
    end
  end

  describe "arranging" do
    @moved %{"x" => 500, "y" => 600, "w" => 4000, "h" => 5000}

    setup %{ctx: ctx, user: user, athanor: athanor} do
      tincture!(ctx, "app-dash")
      tincture!(ctx, "side-dash")
      tincture!(ctx, "loose-dash")

      placed =
        posture([
          app("tincture:local.app-dash", "window", 0),
          app("tincture:local.side-dash", "tile", 1)
        ])

      two_canvases!(ctx, user, athanor, %{"desk" => placed, "hand" => placed})

      actor = Sanctum.Context.actor(person(user, athanor))
      :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.layouts(actor, user.user_id))
      :ok
    end

    defp app_frame(view, name),
      do: Frames.get(frames(view), {:app, "home", "tincture:local.#{name}"})

    defp gesture!(view, event, params) do
      render_hook(view, event, params)
      assert_reply(view, reply)
      reply
    end

    defp written!(view) do
      send(view.pid, :write_layout)
      _ = render(view)
    end

    defp stored(user, athanor) do
      {:ok, layout} = Compendium.layout(person(user, athanor), "desk")
      layout
    end

    defp stored_app(user, athanor, name) do
      %{arrangement: [home | _]} = stored(user, athanor)
      Enum.find(home.apps, &(&1.tincture == "tincture:local.#{name}"))
    end

    defp identity(frame), do: Map.take(frame, [:id, :credential_id, :src])

    test "a settled move writes exactly one edit, at the revision read, and the next reload keeps the view",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      assert %{revision: 1} = stored(user, athanor)
      dash = app_frame(view, "app-dash")
      assert %{placement: {:window, _}, state: :live} = dash

      assert gesture!(view, "frame_move", %{"frame" => dash.id, "geometry" => @moved}) == %{
               ok: true
             }

      assert gesture!(view, "frame_resize", %{
               "frame" => app_frame(view, "side-dash").id,
               "share" => 3500
             }) ==
               %{ok: true}

      # Made at once on the frames, before any write.
      moved = %{x: 500, y: 600, w: 4000, h: 5000}
      assert %{placement: {:window, ^moved}} = app_frame(view, "app-dash")
      assert identity(app_frame(view, "app-dash")) == identity(dash)
      assert %{revision: 1} = stored(user, athanor)
      refute_received %Cyfr.Bus.LayoutPublished{}

      written!(view)
      # A second wake finds nothing left to write.
      written!(view)

      assert %{revision: 2} = stored(user, athanor)
      assert %{placement: :window, geometry: ^moved} = stored_app(user, athanor, "app-dash")
      assert %{placement: :tile, share: 3500} = stored_app(user, athanor, "side-dash")
      assert_receive %Cyfr.Bus.LayoutPublished{revision: 2}
      refute_receive %Cyfr.Bus.LayoutPublished{}, 100
      assert assigns(view).pending == []
      assert assigns(view).layout_base.revision == 2

      # Its own announcement read back changes nothing it holds.
      settle!(view, fn -> assigns(view).layout_changed == false end)
      assert identity(app_frame(view, "app-dash")) == identity(dash)
      assert row(dash.id).state == "active"

      # Another shell of the person opens the frames where they were left.
      again = shell!(conn)
      assert %{placement: {:window, ^moved}} = app_frame(again, "app-dash")
      assert %{placement: {:tile, :right, 3500}} = app_frame(again, "side-dash")
    end

    test "a frame keeps its id and credential through a move, a resize, a raise, a tile and a full",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      dash = app_frame(view, "app-dash")
      render_hook(view, "frame_handshake", %{"frame" => dash.id})
      assert_reply(view, %{credential: bearer})

      for {event, params} <- [
            {"frame_move", %{"geometry" => @moved}},
            {"frame_resize", %{"geometry" => %{@moved | "w" => 9000}}},
            {"frame_raise", %{}},
            {"frame_tile", %{"side" => "left", "share" => 2000}},
            {"frame_full", %{}}
          ] do
        assert gesture!(view, event, Map.put(params, "frame", dash.id)) == %{ok: true}, event
        assert identity(app_frame(view, "app-dash")) == identity(dash), event
      end

      assert %{placement: :full, visible: true} = app_frame(view, "app-dash")
      assert %{key: {:app, "home", "tincture:local.app-dash"}} = Frames.active(frames(view))
      assert {:ok, _} = verify(bearer)

      written!(view)
      assert %{placement: :full, order: 1} = stored_app(user, athanor, "app-dash")
    end

    test "minimise, restore, close and open follow the layout, and each tells the canvas what is open",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      home = canvas(view)
      _ = handshake!(view, home.id)
      home_id = home.id
      assert_push_event(view, "canvas_installed", %{frame: ^home_id})
      dash = app_frame(view, "app-dash")

      assert gesture!(view, "frame_minimise", %{"frame" => dash.id}) == %{ok: true}
      assert %{minimised: true, visible: false} = app_frame(view, "app-dash")
      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: installed})
      assert %{open: true} = Enum.find(installed, &(&1.name == "app-dash"))

      assert gesture!(view, "app_restore", %{"ref" => "tincture:local.app-dash"}) == %{ok: true}
      assert %{minimised: false, visible: true} = app_frame(view, "app-dash")
      assert identity(app_frame(view, "app-dash")) == identity(dash)
      assert_push_event(view, "canvas_installed", %{frame: ^home_id})

      assert gesture!(view, "frame_close", %{"frame" => dash.id}) == %{ok: true}
      assert app_frame(view, "app-dash") == nil
      assert row(dash.id).state == "revoked"
      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: installed})
      assert %{open: false} = Enum.find(installed, &(&1.name == "app-dash"))

      assert gesture!(view, "app_open", %{"ref" => "tincture:local.loose-dash"}) == %{ok: true}
      assert %{placement: {:window, _}, visible: true} = app_frame(view, "loose-dash")
      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: installed})
      assert %{open: true} = Enum.find(installed, &(&1.name == "loose-dash"))

      written!(view)
      assert stored_app(user, athanor, "app-dash") == nil
      assert %{placement: :window, order: 1} = stored_app(user, athanor, "loose-dash")
    end

    test "a gesture outside its bounds, on a frame not held or on a hidden canvas is refused and changes nothing",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      dash = app_frame(view, "app-dash")
      side = app_frame(view, "side-dash")
      before = frames(view)

      for {event, params, error} <- [
            {"frame_move", %{"frame" => "frm_nobody_held", "geometry" => @moved}, "not_held"},
            {"frame_move", %{"frame" => dash.id, "geometry" => %{@moved | "x" => 10_001}},
             "invalid"},
            {"frame_move", %{"frame" => dash.id, "geometry" => %{@moved | "w" => 0}}, "invalid"},
            {"frame_move", %{"frame" => dash.id, "geometry" => %{@moved | "h" => 2.5}},
             "malformed"},
            {"frame_resize", %{"frame" => side.id, "share" => 0}, "invalid"},
            {"frame_resize", %{"frame" => side.id, "share" => 10_001}, "invalid"},
            {"frame_tile", %{"frame" => dash.id, "share" => 2000}, "malformed"},
            {"frame_tile", %{"frame" => dash.id, "side" => "top", "share" => 2000}, "malformed"},
            {"frame_raise", %{"frame" => canvas(view).id}, "not_held"},
            {"app_open", %{"ref" => "tincture:local.nobody"}, "not_listed"},
            {"app_restore", %{"ref" => "tincture:local.loose-dash"}, "not_placed"}
          ] do
        assert gesture!(view, event, params) == %{error: error}, inspect({event, params})
      end

      assert frames(view) == before
      assert assigns(view).pending == []

      # An app of a canvas the glass no longer shows is not arranged.
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert gesture!(view, "frame_raise", %{"frame" => dash.id}) == %{error: "hidden"}

      written!(view)
      assert %{revision: 1} = stored(user, athanor)
    end

    test "a write refused for a newer revision reloads and makes again the gestures that still apply",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      dash = app_frame(view, "app-dash")
      side = app_frame(view, "side-dash")

      assert gesture!(view, "frame_move", %{"frame" => dash.id, "geometry" => @moved}) == %{
               ok: true
             }

      assert gesture!(view, "frame_minimise", %{"frame" => side.id}) == %{ok: true}

      # Another screen of the person arranges meanwhile: it closes the tile
      # and opens another app.
      layout!(user, athanor, [
        entry("home", "tincture:local.markets", %{
          "desk" =>
            posture([
              app("tincture:local.app-dash", "window", 0),
              app("tincture:local.loose-dash", "tile", 1)
            ])
        }),
        entry("work", "tincture:local.notes-canvas")
      ])

      assert_receive %Cyfr.Bus.LayoutPublished{revision: 2}
      # The view keeps its gestures while they wait: its read leaves them.
      _ = render(view)
      assert %{placement: {:window, %{x: 500}}} = app_frame(view, "app-dash")

      written!(view)

      assert %{revision: 3} = stored(user, athanor)

      assert %{placement: :window, geometry: %{x: 500, y: 600}} =
               stored_app(user, athanor, "app-dash")

      assert %{placement: :tile} = stored_app(user, athanor, "loose-dash")
      # The tile the other screen closed is not brought back by its minimise.
      assert stored_app(user, athanor, "side-dash") == nil
      assert app_frame(view, "side-dash") == nil
      assert identity(app_frame(view, "app-dash")) == identity(dash)
      assert assigns(view).pending == []
    end

    test "an app raised or reopened while another is full is brought forward, and the full one waits hidden",
         %{conn: conn} do
      view = shell!(conn)
      dash = app_frame(view, "app-dash")
      assert gesture!(view, "frame_full", %{"frame" => dash.id}) == %{ok: true}
      assert %{key: {:app, "home", "tincture:local.app-dash"}} = Frames.active(frames(view))
      assert %{visible: false} = app_frame(view, "side-dash")

      assert gesture!(view, "app_open", %{"ref" => "tincture:local.side-dash"}) == %{ok: true}
      assert Frames.active(frames(view)) == nil
      assert %{visible: true, state: :live} = app_frame(view, "side-dash")
      assert %{visible: false, placement: :full} = app_frame(view, "app-dash")
      assert %{state: :live, visible: true} = canvas(view)

      assert gesture!(view, "frame_raise", %{"frame" => dash.id}) == %{ok: true}
      assert %{key: {:app, "home", "tincture:local.app-dash"}} = Frames.active(frames(view))
    end

    test "windows stack by their rank, distinct whatever orders the layout holds",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)

      z = fn name ->
        html = render(view)
        frame = app_frame(view, name)
        [tag] = Regex.run(~r/<div[^>]*data-canvas-frame="#{frame.id}"[^>]*>/, html)
        [_, z] = Regex.run(~r/z-index: ([0-9]+)/, tag)
        String.to_integer(z)
      end

      for {a, b} <- [{100, 200}, {300, 200}] do
        layout!(user, athanor, [
          entry("home", "tincture:local.markets", %{
            "desk" =>
              posture([
                app("tincture:local.app-dash", "window", a),
                app("tincture:local.side-dash", "window", b)
              ])
          }),
          entry("work", "tincture:local.notes-canvas")
        ])

        settle!(view, fn -> app_frame(view, "app-dash").stack == a end)
      end

      assert {z.("side-dash"), z.("app-dash")} == {30, 31}
    end

    test "an app that closes itself is closed on the layout and stays closed after another gesture",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      dash = app_frame(view, "app-dash")
      side = app_frame(view, "side-dash")

      render_hook(view, "frame_verb", %{
        "frame" => dash.id,
        "message" => Prima.TinctureWire.shell_message(:close, dash.id)
      })

      assert app_frame(view, "app-dash") == nil
      assert row(dash.id).state == "revoked"

      assert gesture!(view, "frame_move", %{"frame" => side.id, "geometry" => @moved}) == %{
               ok: true
             }

      assert app_frame(view, "app-dash") == nil

      written!(view)
      assert stored_app(user, athanor, "app-dash") == nil
      assert %{placement: :window} = stored_app(user, athanor, "side-dash")
    end

    test "each canvas is told the apps open over it, a hidden one included",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      home = canvas(view)
      home_id = home.id
      _ = handshake!(view, home_id)
      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: first})
      assert %{open: true} = Enum.find(first, &(&1.name == "app-dash"))

      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      work = canvas(view, "work")
      work_id = work.id
      _ = handshake!(view, work_id)
      assert_push_event(view, "canvas_installed", %{frame: ^work_id, tinctures: told})
      assert %{open: false} = Enum.find(told, &(&1.name == "app-dash"))

      assert gesture!(view, "app_open", %{"ref" => "tincture:local.loose-dash"}) == %{ok: true}
      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: hidden})
      assert %{open: true} = Enum.find(hidden, &(&1.name == "app-dash"))
      assert %{open: false} = Enum.find(hidden, &(&1.name == "loose-dash"))
      assert_push_event(view, "canvas_installed", %{frame: ^work_id, tinctures: shown})
      assert %{open: false} = Enum.find(shown, &(&1.name == "app-dash"))
      assert %{open: true} = Enum.find(shown, &(&1.name == "loose-dash"))

      written!(view)
      assert %{revision: 2} = stored(user, athanor)
    end

    test "a publication from elsewhere tells each held canvas its open apps again",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      home_id = canvas(view).id
      _ = handshake!(view, home_id)
      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: initial})
      assert %{open: false} = Enum.find(initial, &(&1.name == "loose-dash"))

      layout!(user, athanor, [
        entry("home", "tincture:local.markets", %{
          "desk" =>
            posture([
              app("tincture:local.app-dash", "window", 0),
              app("tincture:local.side-dash", "tile", 1),
              app("tincture:local.loose-dash", "window", 2)
            ])
        }),
        entry("work", "tincture:local.notes-canvas")
      ])

      settle!(view, fn ->
        assigns(view).layout_base.revision == 2 and app_frame(view, "loose-dash") != nil
      end)

      assert app_frame(view, "loose-dash").visible
      assert canvas(view).id == home_id
      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: later})
      assert %{open: true} = Enum.find(later, &(&1.name == "loose-dash"))
    end

    test "a change of posture tells the canvas its open apps again",
         %{conn: conn, user: user, athanor: athanor} do
      layout!(user, athanor, [
        entry("home", "tincture:local.markets", %{
          "desk" => posture([app("tincture:local.app-dash", "window", 0)]),
          "hand" => posture([])
        }),
        entry("work", "tincture:local.notes-canvas")
      ])

      view = shell!(conn)
      home_id = canvas(view).id
      _ = handshake!(view, home_id)
      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: initial})
      assert %{open: true} = Enum.find(initial, &(&1.name == "app-dash"))

      view |> element("#canvas-hook") |> render_hook("posture", %{"posture" => "hand"})

      settle!(view, fn ->
        assigns(view).posture == "hand" and app_frame(view, "app-dash") == nil
      end)

      assert canvas(view).id == home_id
      assert_push_event(view, "canvas_installed", %{frame: ^home_id, tinctures: later})
      assert %{open: false} = Enum.find(later, &(&1.name == "app-dash"))
    end

    test "the topmost of many windows stays under the canvas's switcher",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      apps =
        for n <- 1..27 do
          name = "many-#{n}"
          tincture!(ctx, name)

          app("tincture:local.#{name}", "window", n)
          |> Map.put("geometry", %{"x" => 0, "y" => 0, "w" => 10_000, "h" => 10_000})
        end

      layout!(user, athanor, [
        entry("home", "tincture:local.markets", %{"desk" => posture(apps)}),
        entry("work", "tincture:local.notes-canvas")
      ])

      view = shell!(conn)
      canvas_verb!(view, canvas(view).id, :ready)
      top = app_frame(view, "many-27")
      assert top.visible
      assert Enum.count(opened(view), &match?(%{key: {:app, "home", _}}, &1)) == 27

      html = render(view)
      [tag] = Regex.run(~r/<div[^>]*data-canvas-frame="#{top.id}"[^>]*>/, html)
      assert tag =~ "left: 0.00%; top: 0.00%; width: 100.00%; height: 100.00%;"
      [_, app_z] = Regex.run(~r/z-index: ([0-9]+)/, tag)
      # The switcher is the shelf's, which its stylesheet stacks.
      assert html =~ ~r/<nav[^>]*id="canvas-shelf".*id="canvas-switcher"/s
      css = File.read!(Path.expand("../../../assets/css/canvas_chrome.css", __DIR__))
      [_, shelf_z] = Regex.run(~r/\.canvas-shelf \{[^}]*z-index: ([0-9]+);/, css)
      assert String.to_integer(app_z) < String.to_integer(shelf_z)
    end

    test "a write the store cannot answer is tried five more times, then let go: the saved arrangement is back and later publications are followed",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      dash = app_frame(view, "app-dash")
      saved = dash.placement

      assert gesture!(view, "frame_move", %{"frame" => dash.id, "geometry" => @moved}) == %{
               ok: true
             }

      Process.cancel_timer(assigns(view).write_timer)

      # The store refuses every write while its root is a file.
      original = Application.fetch_env!(:arca, :base_path)
      blocked = Path.join(original, "arrange-blocked-#{System.unique_integer([:positive])}")
      File.write!(blocked, "not a directory")

      Prima.Test.Env.with_app_env(:arca, :base_path, blocked, fn ->
        for attempt <- 1..5 do
          written!(view)
          assert assigns(view).pending != [], "attempt #{attempt}"
          assert is_reference(assigns(view).write_timer), "attempt #{attempt}"
          Process.cancel_timer(assigns(view).write_timer)
        end

        written!(view)
      end)

      File.rm(blocked)
      assert assigns(view).pending == []
      assert assigns(view).write_timer == nil
      assert %{placement: ^saved} = app_frame(view, "app-dash")
      assert identity(app_frame(view, "app-dash")) == identity(dash)
      assert render(view) =~ "Your arrangement could not be saved"

      layout!(user, athanor, [
        entry("home", "tincture:local.markets", %{
          "desk" => posture([app("tincture:local.app-dash", "tile", 0)])
        }),
        entry("work", "tincture:local.notes-canvas")
      ])

      settle!(view, fn -> assigns(view).layout_base.revision == 2 end)
      assert %{placement: {:tile, :right, 2500}} = app_frame(view, "app-dash")
      assert app_frame(view, "side-dash") == nil
    end

    test "a window survives a switch to the Dashboard and back, even inside the write window",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      assert gesture!(view, "app_open", %{"ref" => "tincture:local.loose-dash"}) == %{ok: true}
      assert %{placement: {:window, geometry}, id: first_id} = app_frame(view, "loose-dash")
      assert assigns(view).pending != []

      # The switch is the top bar's link; following it ends the shell's page.
      assert {:error, {:live_redirect, %{to: dashboard}}} =
               view |> find_live_child("topbar") |> element("#mode-dashboard") |> render_click()

      GenServer.stop(view.pid, {:shutdown, :closed})
      assert row(first_id).state == "revoked"
      assert %{placement: :window, geometry: ^geometry} = stored_app(user, athanor, "loose-dash")

      {:ok, dash, _html} = live(conn, dashboard)

      assert {:error, {:live_redirect, %{to: back}}} =
               dash |> find_live_child("topbar") |> element("#mode-canvas") |> render_click()

      assert back =~ "/canvas"
      again = shell!(conn)

      assert %{placement: {:window, ^geometry}, state: :live, id: id} =
               app_frame(again, "loose-dash")

      assert id != first_id
    end

    test "in the hand every app shows full in stacking order, and a placement gesture is refused",
         %{conn: conn} do
      view = shell!(conn)
      view |> element("#canvas-hook") |> render_hook("posture", %{"posture" => "hand"})
      settle!(view, fn -> assigns(view).posture == "hand" end)

      dash = app_frame(view, "app-dash")

      assert gesture!(view, "frame_tile", %{"frame" => dash.id, "side" => "left", "share" => 2000}) ==
               %{error: "hand"}

      assert gesture!(view, "frame_raise", %{"frame" => dash.id}) == %{ok: true}
      assert %{placement: :full, visible: true} = app_frame(view, "app-dash")
      assert %{placement: :full, visible: false} = app_frame(view, "side-dash")
    end
  end

  describe "a canvas's failure after it reported ready" do
    test "changes nothing while it is shown", %{
      conn: conn,
      ctx: ctx,
      user: user,
      athanor: athanor
    } do
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      home = canvas(view)
      canvas_verb!(view, home.id, :ready)

      canvas_verb!(view, home.id, :failed, %{"stage" => "runtime"})

      assert assigns(view).safe_mode == nil
      assert %{id: id, state: :live} = canvas(view)
      assert id == home.id
    end

    test "changes nothing while it is hidden, nor once it is shown again",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      two_canvases!(ctx, user, athanor)
      view = shell!(conn)
      home = canvas(view)
      canvas_verb!(view, home.id, :ready)
      render_hook(view, "switch_canvas", %{"canvas" => "work"})
      assert %{state: :frozen} = canvas(view)

      canvas_verb!(view, home.id, :failed, %{"stage" => "runtime"})
      refute MapSet.member?(assigns(view).canvas_died, home.id)

      render_hook(view, "switch_canvas", %{"canvas" => "home"})
      assert assigns(view).safe_mode == nil
      assert %{id: id, state: :live} = canvas(view)
      assert id == home.id
    end
  end

  defp person_of(view), do: assigns(view).context

  # The system layer's dismissal of the prompt in front.
  defp dismiss!(view) do
    view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()
    _ = render(view)
  end
end
