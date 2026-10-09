# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.CanvasValidationTest do
  @moduledoc """
  A candidate canvas version trialled on the glass, through the shell
  (`Prism.CanvasValidation`, `PrismWeb.ShellLive`): one case per outcome.
  A tree activates the version; the deadline records `no_tree`; a failure
  or the frame's death records `died`; a member that lost its slot
  activates and records nothing. After every outcome, a refused
  activation included, the frame is no longer held and its validation
  credential's row is revoked. A version restored is not trialled again
  until a newer one is installed; a trial's `open` and `press` are
  dropped; two glasses trialling one version publish one activation; a
  grant that waits for the person is asked for.

  Takes a slot through `Arca.ControlPlane` in the ownership case, which
  writes the process-wide standing record; that case saves and restores it.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Arca.Schemas.CellLease
  alias Prism.CanvasValidation
  alias Prism.Frames

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "canvas_validation_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry()
    end)

    {:ok, conn: conn, user: user, athanor: athanor, ctx: ctx}
  end

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

  # A canvas version laid in the athanor's tree with its component row.
  defp canvas!(ctx, name, version) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => version,
      "publisher" => "local",
      "tincture" => %{
        "frame" => %{"placement" => "canvas"},
        "canvas" => %{"module" => "canvas.js", "toolkit" => 1},
        "streams" => [%{"name" => "runs.changes"}]
      }
    }

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(ctx),
        ["components", "tinctures", "local", name, version]
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "canvas.js"), "export default (c) => c.render({type: \"spacer\"})")

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

    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
  end

  defp versions!(ctx, fields) do
    actor = Sanctum.Context.actor(ctx)
    %{revision: revision} = stored(ctx)

    {:ok, _} =
      Arca.CanvasVersions.publish(
        actor,
        "markets",
        Map.merge(Arca.CanvasVersions.empty(), fields),
        revision
      )
  end

  # The versions document of markets and the revision it is at, 0 for none.
  defp stored(ctx) do
    case Arca.CanvasVersions.get(Sanctum.Context.actor(ctx), "markets") do
      {:ok, %{document: document, revision: revision}} ->
        %{document: document, revision: revision}

      {:error, :not_found} ->
        %{document: Arca.CanvasVersions.empty(), revision: 0}
    end
  end

  # The person's layout: one canvas, home on markets.
  defp layout!(user, athanor) do
    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: athanor.id,
        permissions: Sanctum.Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, _} =
      Compendium.Providers.Layout.handle("layout", ctx, %{
        "action" => "edit",
        "document" => %{
          "version" => 2,
          "canvases" => [
            %{"id" => "home", "tincture" => "tincture:local.markets", "postures" => %{}}
          ]
        },
        "revision" => 0
      })
  end

  defp shell!(conn) do
    {view, _html} = mount_athanor(conn, "/tinctures")

    wait_until(
      fn ->
        _ = render(view)
        assigns = assigns(view)
        assigns.showing != :pending or assigns.safe_mode != nil
      end,
      2_000,
      "the shell to settle"
    )

    view
  end

  defp assigns(%Phoenix.LiveViewTest.View{pid: pid}), do: :sys.get_state(pid).socket.assigns
  defp frames(view), do: assigns(view).frames
  defp trial(view), do: Frames.get(frames(view), {:validation, "home"})
  defp live_canvas(view), do: Frames.get(frames(view), {:canvas, "home"})

  defp row(frame_id) do
    Arca.Repo.one(from(f in Arca.Schemas.FrameCredential, where: f.frame_id == ^frame_id))
  end

  defp verb!(view, frame_id, verb, args \\ %{}),
    do:
      render_hook(view, "canvas_verb", %{
        "frame" => frame_id,
        "message" => Prima.CanvasWire.encode(%{verb: verb, frame: frame_id, args: args})
      })

  # The trial ended: its frame is not held, nor rendered, and its
  # credential's row is revoked.
  defp torn_down!(view, trial) do
    assert trial(view) == nil
    refute render(view) =~ ~s(id="#{trial.id}")
    assert row(trial.id).state == "revoked"
  end

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
    node = "node-validation-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  # A successor takes the slot over; this member still believes it holds it.
  defp take_over!(slot) do
    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
        set: [owner: slot.node <> "#boot_b", generation: slot.generation + 1]
      )

    assert Arca.ControlPlane.held?()
  end

  describe "whether to validate" do
    test "the newest version is trialled unless it is the working, kept or failed one" do
      empty = Arca.CanvasVersions.empty()
      assert CanvasValidation.needed?(empty, "1.0.0")
      refute CanvasValidation.needed?(%{empty | working: "1.0.0"}, "1.0.0")
      refute CanvasValidation.needed?(%{empty | working: "1.0.0", kept: "1.0.1"}, "1.0.1")

      refute CanvasValidation.needed?(
               %{
                 empty
                 | failed: %{version: "1.0.1", outcome: "died", at: "2026-10-09T12:00:00Z"}
               },
               "1.0.1"
             )

      assert CanvasValidation.needed?(%{empty | working: "1.0.0", kept: "0.9.0"}, "1.0.1")
      assert CanvasValidation.deadline_ms() == 10_000
    end

    test "each event reports its outcome" do
      assert CanvasValidation.outcome(:tree) == "tree"
      assert CanvasValidation.outcome(:deadline) == "no_tree"
      assert CanvasValidation.outcome(:failed) == "died"
      assert CanvasValidation.outcome(:gone) == "died"
    end
  end

  describe "an outcome" do
    setup %{ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.0.0")
      layout!(user, athanor)
      :ok
    end

    test "a tree activates the version, and the trial is torn down", %{conn: conn, ctx: ctx} do
      view = shell!(conn)
      assert %{state: :live, visible: false, reference: %{version: "1.0.0"}} = trial = trial(view)
      assert row(trial.id).purpose == "validation"
      assert live_canvas(view) == nil

      verb!(view, trial.id, :tree)

      torn_down!(view, trial)
      assert %{document: %{working: "1.0.0", kept: nil, failed: nil}, revision: 1} = stored(ctx)
      assert %{state: :live, visible: true, reference: %{version: "1.0.0"}} = live_canvas(view)
      assert assigns(view).safe_mode == nil
    end

    test "no tree by the deadline records no_tree, and the working version opens",
         %{conn: conn, ctx: ctx} do
      canvas!(ctx, "markets", "1.0.1")
      versions!(ctx, %{working: "1.0.0"})
      view = shell!(conn)
      assert %{reference: %{version: "1.0.1"}} = trial = trial(view)

      send(view.pid, {:validation_deadline, trial.id})
      _ = render(view)

      torn_down!(view, trial)

      assert %{
               working: "1.0.0",
               kept: nil,
               failed: %{version: "1.0.1", outcome: "no_tree"}
             } = stored(ctx).document

      assert %{state: :live, reference: %{version: "1.0.0"}} = live_canvas(view)

      # A deadline for the trial no longer held changes nothing.
      revision = stored(ctx).revision
      send(view.pid, {:validation_deadline, trial.id})
      _ = render(view)
      assert stored(ctx).revision == revision
    end

    test "a failure at any stage records died, and with no working version is safe mode not_validated",
         %{conn: conn, ctx: ctx} do
      view = shell!(conn)
      trial = trial(view)

      verb!(view, trial.id, :failed, %{"stage" => "tree"})

      torn_down!(view, trial)
      assert %{working: nil, failed: %{version: "1.0.0", outcome: "died"}} = stored(ctx).document
      assert %{reason: :not_validated} = assigns(view).safe_mode

      assert render(view) =~
               Phoenix.HTML.safe_to_string(
                 Phoenix.HTML.html_escape(
                   "Your canvas's new version did not start, and it has no earlier version to show."
                 )
               )
    end

    test "the frame's death records died", %{conn: conn, ctx: ctx} do
      view = shell!(conn)
      trial = trial(view)

      render_hook(view, "frame_gone", %{"frame" => trial.id})

      torn_down!(view, trial)
      assert %{failed: %{version: "1.0.0", outcome: "died"}} = stored(ctx).document
    end

    test "a member that lost its slot activates and records nothing, revokes the trial's credential, and is never safe mode",
         %{conn: conn, ctx: ctx} do
      slot = claimant!()
      view = shell!(conn)
      trial = trial(view)
      take_over!(slot)

      verb!(view, trial.id, :tree)

      torn_down!(view, trial)
      assert stored(ctx) == %{document: Arca.CanvasVersions.empty(), revision: 0}
      assert assigns(view).safe_mode == nil
      assert %{state: :refused, refusal: :unavailable} = live_canvas(view)
    end

    test "a grant that waits for the person is asked for; dismissed, the canvas shows its refusal",
         %{conn: conn, ctx: ctx} do
      view = shell!(conn)
      trial = trial(view)

      # The canvas's owner profile came to wait for the person after the
      # trial opened.
      :ok =
        Sanctum.Test.ConsentFixtures.seed_head!(
          ctx,
          %{
            id: "prof_markets_canvas",
            kind: :owner,
            source_ref: "tincture:local.markets",
            label: "owner",
            status: :needs_consent
          },
          %{
            id: "cons_markets_canvas",
            revision: 1,
            scope: :versionless,
            pinned_version: "",
            invoke_mode: :open_inert,
            shape_digest: "sha256:shape",
            commit_digest: "sha256:commit",
            blob_digest: Prima.JCS.hash_binary("{}"),
            resolved_policy: "{}",
            activation: %{}
          }
        )

      verb!(view, trial.id, :tree)

      torn_down!(view, trial)
      assert stored(ctx).revision == 0
      html = render(view)
      assert html =~ ~s(data-kind="grant")
      assert html =~ "Grant tincture:local.markets"

      assert [{_prompt, {{:activation, "home"}, "iframe_markets"}}] =
               Map.to_list(assigns(view).grant_prompts)

      view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()
      _ = render(view)

      assert %{state: :refused, refusal: :ungranted} = live_canvas(view)
      assert trial(view) == nil
      assert assigns(view).safe_mode == nil
    end
  end

  describe "a restore" do
    test "after a restore, showing the canvas validates nothing; a newer version is validated as before",
         %{conn: conn, ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.0.0")
      canvas!(ctx, "markets", "1.0.1")
      layout!(user, athanor)
      # 1.0.1 was activated, then the person restored 1.0.0.
      versions!(ctx, %{working: "1.0.0", kept: "1.0.1"})
      revision = stored(ctx).revision

      view = shell!(conn)
      assert trial(view) == nil
      assert %{state: :live, reference: %{version: "1.0.0"}} = live_canvas(view)
      assert %{working: "1.0.0", kept: "1.0.1"} = stored(ctx).document
      assert stored(ctx).revision == revision
      GenServer.stop(view.pid, :normal)

      canvas!(ctx, "markets", "1.0.2")
      view = shell!(conn)
      assert %{reference: %{version: "1.0.2"}} = trial(view)
      assert live_canvas(view) == nil
    end
  end

  describe "a trial's own verbs" do
    setup %{ctx: ctx, user: user, athanor: athanor} do
      canvas!(ctx, "markets", "1.0.0")
      layout!(user, athanor)
      :ok
    end

    test "its open, press and ready are dropped and never forwarded", %{conn: conn, ctx: ctx} do
      view = shell!(conn)
      trial = trial(view)

      verb!(view, trial.id, :open, %{"ref" => "tincture:local.markets"})

      verb!(view, trial.id, :press, %{
        "binding" => "feed_01a09fee-2e4f-7a5b-9c6d-7e8f9a0b1c2d",
        "action" => "refresh"
      })

      verb!(view, trial.id, :ready)

      assert Frames.dropped(frames(view)) == 3
      assert [%{key: {:validation, "home"}}] = Frames.list(frames(view))

      assert Arca.Repo.all(
               from(d in Arca.Schemas.DecisionLog,
                 where: d.athanor_id == ^ctx.athanor_id and d.tool == "feed"
               )
             ) == []

      assert stored(ctx).revision == 0
    end
  end

  describe "two glasses" do
    test "trialling one version publish one activation", %{
      conn: conn,
      ctx: ctx,
      user: user,
      athanor: athanor
    } do
      canvas!(ctx, "markets", "1.0.0")
      layout!(user, athanor)

      first = shell!(conn)
      second = shell!(conn)
      a = trial(first)
      b = trial(second)
      refute a.id == b.id

      verb!(first, a.id, :tree)
      verb!(second, b.id, :tree)

      torn_down!(first, a)
      torn_down!(second, b)
      assert %{document: %{working: "1.0.0", kept: nil}, revision: 1} = stored(ctx)
      assert %{state: :live, reference: %{version: "1.0.0"}} = live_canvas(first)
      assert %{state: :live, reference: %{version: "1.0.0"}} = live_canvas(second)
    end
  end
end
