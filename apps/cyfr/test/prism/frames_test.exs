# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.FramesTest do
  @moduledoc """
  The frames' pure transitions, without a store: which frames the layout
  places over a canvas and for which tinctures, which canvas and frames
  are visible, which credential transitions visibility asks for (a hidden
  canvas frozen whatever it declares, a validation frame never), to which
  frame a message is attributed, the one-time handshake and a canvas's
  handshake reply, and the signals the view sends. Only the frames' own open path
  makes a canvas or validation frame. The effects, through
  `Sanctum.TinctureAuth`, are `PrismWeb.ShellFrameTest`'s,
  `PrismWeb.ShellCanvasTest`'s and `Prism.CanvasValidationTest`'s.
  """

  use ExUnit.Case, async: true

  alias Prism.Frames

  # One app of a layout's arrangement (`Prima.Layout.app/0`).
  @g %{x: 0, y: 0, w: 3000, h: 5000}

  defp layout_app(tincture, placement, order, minimised \\ false) do
    %{
      tincture: tincture,
      placement: placement,
      order: order,
      geometry: if(placement == :window, do: %{x: 0, y: 0, w: 3000, h: 5000}),
      side: if(placement == :tile, do: :right),
      share: if(placement == :tile, do: 2500),
      minimised: minimised
    }
  end

  defp card(name, frame \\ %{}) do
    %{
      id: "iframe_#{name}",
      publisher: "local",
      name: name,
      version: "1.0.0",
      entry: "index.html",
      athanor_segment: "home",
      public: false,
      manifest: %{"tincture" => %{"entry" => "index.html", "frame" => frame}}
    }
  end

  defp frame(key, placement, fields) do
    id = Keyword.get(fields, :id, "frm_" <> Base.url_encode64(:crypto.strong_rand_bytes(9)))
    tincture_id = Keyword.get(fields, :tincture_id, "iframe_" <> String.slice(id, 4, 8))

    Map.merge(
      %{
        key: key,
        id: id,
        tincture_id: tincture_id,
        reference: %{publisher: "local", name: tincture_id, version: "1.0.0"},
        src: "/t/home/local/x",
        sandbox: "allow-scripts",
        allow: "",
        state: :live,
        refusal: nil,
        credential_id: "fcr_" <> id,
        bearer: "bearer-" <> id,
        deadline: DateTime.add(DateTime.utc_now(), 3_600, :second),
        placement: placement,
        visible: true,
        background: false,
        actions: [],
        stack: 0,
        minimised: false,
        canvas: nil
      },
      Map.new(fields)
    )
  end

  defp app(canvas, name, placement, fields \\ []),
    do:
      frame(
        {:app, canvas, "tincture:local.#{name}"},
        placement,
        [tincture_id: "iframe_#{name}"] ++ fields
      )

  defp launch(name, fields \\ []),
    do: frame({:full, "iframe_#{name}"}, :full, [tincture_id: "iframe_#{name}"] ++ fields)

  # A canvas or validation frame, as only the frames' open path makes one;
  # built here as the value it would hold.
  defp canvas_frame(kind, canvas_id, fields \\ []) do
    frame({kind, canvas_id}, kind, [tincture_id: "iframe_canvas"] ++ fields)
  end

  # Hold the frames, canvas-placement ones as the open path holds them.
  defp held(frames, canvas \\ "home") do
    Enum.reduce(frames, %Frames{canvas: canvas}, fn %{key: key} = frame, t ->
      %{t | frames: Map.put(t.frames, key, frame), order: t.order ++ [key]}
    end)
  end

  describe "placement" do
    test "every app of an installed tincture is placed as the layout stands it, in its order" do
      cards = Enum.map(~w(notes clock sheet radio), &card/1)

      canvas = %{
        id: "home",
        tincture: "tincture:local.canvas",
        apps: [
          layout_app("tincture:local.clock", :full, 1),
          layout_app("tincture:local.radio", :window, 2, true),
          layout_app("tincture:local.notes", :window, 3),
          layout_app("tincture:local.sheet", :tile, 5)
        ]
      }

      assert [
               {{:app, "home", "tincture:local.clock"}, :full, 1, false, %{id: "iframe_clock"}},
               {{:app, "home", "tincture:local.radio"}, {:window, @g}, 2, true,
                %{id: "iframe_radio"}},
               {{:app, "home", "tincture:local.notes"}, {:window, @g}, 3, false,
                %{id: "iframe_notes"}},
               {{:app, "home", "tincture:local.sheet"}, {:tile, :right, 2500}, 5, false,
                %{id: "iframe_sheet"}}
             ] = Frames.placements(canvas, cards, "desk")

      # In the hand every app is full, whatever the layout stores.
      assert Enum.map(Frames.placements(canvas, cards, "hand"), &elem(&1, 1)) ==
               [:full, :full, :full, :full]
    end

    test "an entry naming a tincture nobody installed places nothing" do
      canvas = %{
        id: "home",
        tincture: "tincture:local.canvas",
        apps: [layout_app("tincture:acme.gone", :window, 0)]
      }

      assert Frames.placements(canvas, [card("notes")], "desk") == []
    end

    test "canvas? reads the declaration, and a declaration off the rules is no canvas" do
      canvas = %{
        manifest: %{
          "tincture" => %{
            "frame" => %{"placement" => "canvas"},
            "entry" => "index.html"
          }
        }
      }

      assert Frames.canvas?(canvas)
      refute Frames.canvas?(card("d", %{"placement" => "sidebar"}))
      refute Frames.canvas?(%{manifest: nil})
    end

    test "a layout reference resolves to the listed card by publisher and name" do
      cards = [card("notes"), %{card("notes") | publisher: "acme", id: "iframe_acme"}]

      assert %{id: "iframe_notes"} = Frames.resolve("tincture:local.notes", cards)
      assert %{id: "iframe_acme"} = Frames.resolve("tincture:acme.notes", cards)
      assert Frames.resolve("tincture:local.missing", cards) == nil
      assert Frames.resolve("not a ref", cards) == nil
      assert Frames.resolve(nil, cards) == nil
      assert Frames.ref_of(card("notes")) == "tincture:local.notes"
    end

    test "place, resize, raise, minimise and restore keep the frame and change only what they name" do
      window = app("home", "notes", {:window, @g}, stack: 0)
      tile = app("home", "sheet", {:tile, :left, 2000}, stack: 1)
      full = app("home", "game", :full, stack: 2)
      t = held([window, tile, full])

      kept = fn t, frame ->
        Map.take(Frames.get(t, frame.key), [:id, :credential_id, :bearer, :src])
      end

      ids = fn frame -> Map.take(frame, [:id, :credential_id, :bearer, :src]) end

      moved = Frames.place(t, window.key, {:window, %{x: 10, y: 20, w: 300, h: 400}})
      assert Frames.get(moved, window.key).placement == {:window, %{x: 10, y: 20, w: 300, h: 400}}
      assert kept.(moved, window) == ids.(window)

      tiled = Frames.place(t, window.key, {:tile, :right, 3000})
      assert Frames.get(tiled, window.key).placement == {:tile, :right, 3000}
      assert kept.(tiled, window) == ids.(window)

      fulled = Frames.place(t, tile.key, :full)
      assert Frames.get(fulled, tile.key).placement == :full
      assert kept.(fulled, tile) == ids.(tile)

      resized = Frames.resize(t, tile.key, 4000)
      assert Frames.get(resized, tile.key).placement == {:tile, :left, 4000}
      resized = Frames.resize(t, window.key, %{x: 0, y: 0, w: 9000, h: 9000})

      assert Frames.get(resized, window.key).placement ==
               {:window, %{x: 0, y: 0, w: 9000, h: 9000}}

      assert Frames.resize(t, full.key, 4000) == t
      assert Frames.resize(t, window.key, 4000) == t

      raised = Frames.raise(t, window.key)
      assert Frames.get(raised, window.key).stack == 3
      assert kept.(raised, window) == ids.(window)
      assert Frames.raise(raised, window.key) == raised

      minimised = Frames.minimise(t, window.key)
      assert %{minimised: true, placement: {:window, @g}} = Frames.get(minimised, window.key)
      restored = Frames.restore(minimised, window.key)
      assert %{minimised: false, stack: 3} = Frames.get(restored, window.key)
      assert kept.(restored, window) == ids.(window)

      # A placement of no kind, or a frame that is not an app's, changes nothing.
      assert Frames.place(t, window.key, {:window, @g}) == t
      assert Frames.place(t, {:canvas, "home"}, :full) == t
    end

    test "each key names the canvas it belongs to, and a launch none" do
      assert Frames.canvas_of({:canvas, "home"}) == "home"
      assert Frames.canvas_of({:validation, "home"}) == "home"
      assert Frames.canvas_of({:app, "work", "tincture:local.x"}) == "work"
      assert Frames.canvas_of({:full, "iframe_x"}) == nil

      assert Frames.canvas_key?({:canvas, "home"})
      assert Frames.canvas_key?({:validation, "home"})
      refute Frames.canvas_key?({:app, "home", "tincture:local.x"})
      refute Frames.canvas_key?({:full, "iframe_x"})
    end
  end

  describe "visibility" do
    setup do
      frames = [
        canvas_frame(:canvas, "home", id: "frm_home_canvas"),
        canvas_frame(:validation, "work", id: "frm_work_trial"),
        canvas_frame(:canvas, "work", id: "frm_work_canvas"),
        app("home", "notes", {:window, @g}, stack: 0),
        app("home", "game", :full, stack: 1, minimised: true),
        app("work", "sheet", {:window, @g}),
        app("home", "clock", {:tile, :right, 2000}, stack: 2),
        app("home", "hidden", {:window, @g}, stack: 3, minimised: true),
        launch("radio")
      ]

      {:ok, t: held(frames)}
    end

    defp shown(t),
      do:
        t
        |> Frames.visibility()
        |> Frames.list()
        |> Enum.filter(& &1.visible)
        |> Enum.map(& &1.key)

    test "with no frame active, the visible canvas and its windows and tiles not minimised are shown",
         %{t: t} do
      assert shown(t) == [
               {:canvas, "home"},
               {:app, "home", "tincture:local.notes"},
               {:app, "home", "tincture:local.clock"}
             ]
    end

    test "another canvas shown hides the first and every frame of it", %{t: t} do
      assert shown(%{t | canvas: "work"}) == [
               {:canvas, "work"},
               {:app, "work", "tincture:local.sheet"}
             ]
    end

    test "the topmost full app of the visible canvas not minimised, or a launch above it, alone is shown",
         %{t: t} do
      game = {:app, "home", "tincture:local.game"}
      t = Frames.restore(t, game)
      assert shown(t) == [game]
      assert Frames.active_tincture(t) == "iframe_game"

      assert shown(Frames.activate(t, {:full, "iframe_radio"})) == [{:full, "iframe_radio"}]
      assert shown(Frames.minimise(t, game)) |> Enum.member?({:canvas, "home"})
    end

    test "a window raised above the full app ends its cover; the full app waits hidden until raised",
         %{t: t} do
      game = {:app, "home", "tincture:local.game"}
      notes = {:app, "home", "tincture:local.notes"}
      t = Frames.restore(t, game)
      assert shown(t) == [game]

      raised = Frames.raise(t, notes)
      assert Frames.active(raised) == nil

      assert shown(raised) == [
               {:canvas, "home"},
               notes,
               {:app, "home", "tincture:local.clock"}
             ]

      assert %{placement: :full, minimised: false} = Frames.get(raised, game)
      assert shown(Frames.raise(raised, game)) == [game]
    end

    test "a full app is active only over its own canvas", %{t: t} do
      t = t |> Frames.restore({:app, "home", "tincture:local.game"})

      assert Frames.active(%{t | canvas: "work"}) == nil

      assert shown(%{t | canvas: "work"}) == [
               {:canvas, "work"},
               {:app, "work", "tincture:local.sheet"}
             ]

      # Shown again over its canvas.
      assert %{key: {:app, "home", _}} = Frames.active(t)
    end

    test "a validation frame is never shown", %{t: t} do
      for canvas <- ["home", "work"] do
        refute {:validation, "work"} in shown(%{t | canvas: canvas})
      end
    end

    test "activating anything but a launch changes nothing", %{t: t} do
      assert Frames.activate(t, {:app, "home", "tincture:local.notes"}) == t
      assert Frames.activate(t, {:canvas, "home"}) == t
      assert Frames.activate(t, {:full, "iframe_nobody"}) == t
    end

    test "forgetting the active launch leaves the topmost full app of this canvas active",
         %{t: t} do
      t =
        t
        |> Frames.restore({:app, "home", "tincture:local.game"})
        |> Frames.activate({:full, "iframe_radio"})
        |> Frames.forget({:full, "iframe_radio"})

      assert %{key: {:app, "home", "tincture:local.game"}} = Frames.active(t)

      t = Frames.forget(t, {:app, "home", "tincture:local.game"})
      assert Frames.active(t) == nil
    end
  end

  describe "the visibility plan" do
    test "a hidden canvas is suspended whatever its declaration" do
      # Both canvases declare a background grant, as no canvas can: the
      # hidden one is frozen all the same, and an app of it keeps its own.
      t =
        held(
          [
            canvas_frame(:canvas, "home", background: true),
            canvas_frame(:canvas, "work", background: true),
            app("work", "radio", {:window, @g}, background: true),
            app("work", "notes", {:window, @g})
          ],
          "home"
        )
        |> Frames.visibility()

      assert Frames.plan(t) == [
               {:freeze, {:canvas, "work"}},
               {:freeze, {:app, "work", "tincture:local.notes"}}
             ]

      # Shown again, the frozen canvas is to thaw.
      thawing = %{Frames.freeze(t, {:canvas, "work"}) | canvas: "work"} |> Frames.visibility()
      assert {:thaw, {:canvas, "work"}} in Frames.plan(thawing)
      assert {:freeze, {:canvas, "home"}} in Frames.plan(thawing)
    end

    test "a validation frame is never frozen or thawed" do
      t =
        held([
          canvas_frame(:validation, "home"),
          canvas_frame(:validation, "work", state: :frozen)
        ])
        |> Frames.visibility()

      assert Frames.plan(t) == []
    end

    test "a hidden live frame without a background grant is to freeze; a refused one is left alone" do
      t =
        held([
          app("home", "notes", {:window, @g}),
          launch("a"),
          launch("b", background: true),
          launch("c", state: :refused, refusal: :refused, bearer: nil)
        ])
        |> Frames.activate({:full, "iframe_a"})
        |> Frames.visibility()

      assert Frames.plan(t) == [{:freeze, {:app, "home", "tincture:local.notes"}}]
    end
  end

  describe "holding a frame" do
    test "only the frames' own open path holds a canvas or validation frame" do
      for kind <- [:canvas, :validation] do
        assert_raise ArgumentError, fn -> Frames.put(Frames.new(), canvas_frame(kind, "home")) end
      end

      launched = launch("a")
      assert Frames.get(Frames.put(Frames.new(), launched), launched.key) == launched
    end
  end

  describe "attribution" do
    test "a message is attributed only to a live frame this value holds" do
      live = launch("a", id: "frm_live_frame_1")
      frozen = launch("b", id: "frm_frozen_frame", state: :frozen)
      refused = launch("c", id: "frm_refused_frm", state: :refused)
      t = held([live, frozen, refused])

      assert {:ok, %{key: {:full, "iframe_a"}}} = Frames.attribute(t, "frm_live_frame_1")
      assert Frames.attribute(t, "frm_frozen_frame") == :error
      assert Frames.attribute(t, "frm_refused_frm") == :error
      assert Frames.attribute(t, "frm_not_this_views") == :error
      assert Frames.attribute(t, nil) == :error
    end

    test "the bearer is handed over once" do
      t = held([launch("a", id: "frm_handshake_1", bearer: "secret")])

      assert {:ok, "secret", t} = Frames.hand_over(t, "frm_handshake_1")
      assert Frames.hand_over(t, "frm_handshake_1") == :error
      assert Frames.hand_over(t, "frm_other_frame") == :error
      assert Frames.hand_over(t, 42) == :error
    end

    test "a canvas or validation frame is handed the canvas handshake, once; any other frame its bearer" do
      streams = [%{"name" => "runs.changes", "subject" => nil}]

      block = fn id, mode ->
        %{"mode" => mode, "data_path" => Prima.TinctureWire.data_path(id), "streams" => streams}
      end

      t =
        held([
          canvas_frame(:canvas, "home",
            id: "frm_canvas_hand",
            bearer: "canvas-bearer",
            canvas: block.("frm_canvas_hand", "live")
          ),
          canvas_frame(:validation, "home",
            id: "frm_trial_hand",
            bearer: "trial-bearer",
            canvas: block.("frm_trial_hand", "validation")
          ),
          launch("a",
            id: "frm_launch_hand",
            bearer: "launch-bearer",
            canvas: block.("frm_launch_hand", "live")
          )
        ])

      assert {:ok, handed, %{key: {:canvas, "home"}}, t} =
               Frames.handshake(t, "frm_canvas_hand")

      # Exactly the wire's canvas handshake: the credential and the block.
      assert handed == %{
               "credential" => "canvas-bearer",
               "canvas" => block.("frm_canvas_hand", "live")
             }

      assert handed ==
               Prima.TinctureWire.canvas_handshake(
                 "frm_canvas_hand",
                 "canvas-bearer",
                 "live",
                 streams
               )

      assert Frames.get(t, {:canvas, "home"}).bearer == nil
      assert Frames.get(t, {:canvas, "home"}).canvas == block.("frm_canvas_hand", "live")

      assert {:ok, %{"credential" => "trial-bearer", "canvas" => %{"mode" => "validation"}}, _, t} =
               Frames.handshake(t, "frm_trial_hand")

      # A canvas block is a canvas's alone: a frame under any other key is
      # handed its bearer and nothing else.
      assert {:ok, %{credential: "launch-bearer"} = reply, _, t} =
               Frames.handshake(t, "frm_launch_hand")

      assert Map.keys(reply) == [:credential]

      for id <- ~w(frm_canvas_hand frm_trial_hand frm_launch_hand frm_unknown_one),
          do: assert(Frames.handshake(t, id) == :error)
    end

    test "a dropped message is counted" do
      assert Frames.new() |> Frames.drop_message() |> Frames.drop_message() |> Frames.dropped() ==
               2
    end
  end

  describe "renewal" do
    test "a live frame holding a deadline is renewed, a shown canvas's included; a hidden canvas and a validation's never are" do
      assert Frames.renewable?(launch("a"))
      assert Frames.renewable?(app("home", "b", {:window, @g}))
      assert Frames.renewable?(canvas_frame(:canvas, "home"))
      refute Frames.renewable?(launch("c", state: :frozen))
      refute Frames.renewable?(launch("d", state: :refused))
      refute Frames.renewable?(launch("e", deadline: nil))
      refute Frames.renewable?(canvas_frame(:canvas, "home", state: :frozen, visible: false))
      refute Frames.renewable?(canvas_frame(:validation, "home"))
    end

    test "queued replacements are taken once, in order" do
      t = %{
        held([launch("a")])
        | replacements: [
            %{frame: "frm_first_one", credential: "one"},
            %{frame: "frm_second_one", credential: "two"}
          ]
      }

      assert {[%{credential: "one"}, %{credential: "two"}], t} = Frames.take_replacements(t)
      assert {[], _t} = Frames.take_replacements(t)
    end

    test "a bearer and a replacement are redacted wherever they are logged" do
      replacement = %{frame: "frm_redacted_1", credential: "the-bearer"}
      frame = launch("a", bearer: "the-bearer")

      refute inspect(Prima.Sanitizer.sanitize(replacement)) =~ "the-bearer"
      refute inspect(Prima.Sanitizer.sanitize(frame)) =~ "the-bearer"
    end
  end

  describe "signals" do
    test "a frame whose state moved between live and frozen is signalled, and nothing else" do
      a = launch("a", id: "frm_signal_aaaa")
      b = launch("b", id: "frm_signal_bbbb")
      c = launch("c", id: "frm_signal_cccc")
      before = held([a, b, c])

      later =
        before
        |> Frames.freeze(a.key)
        |> Frames.refuse(c.key, :unavailable)
        |> Frames.put(launch("d", state: :frozen))

      assert Frames.signals(before, later) == [%{frame: "frm_signal_aaaa", state: "frozen"}]

      assert Frames.signals(later, Frames.thaw(later, a.key)) == [
               %{frame: "frm_signal_aaaa", state: "live"}
             ]
    end

    test "a frame reopened under the same key is not signalled as the old one" do
      old = launch("a", id: "frm_old_frame_1", state: :frozen)
      new = launch("a", id: "frm_new_frame_1")

      assert Frames.signals(held([old]), held([new])) == []
    end
  end

  describe "refusal classes" do
    test "each refusal reads as the class the frame shows" do
      assert Frames.refusal(:unavailable) == :unavailable
      assert Frames.refusal({:unavailable, "Canvas versions"}) == :unavailable
      assert Frames.refusal(:not_owner) == :unavailable
      assert Frames.refusal({:undeclared_capability, ["camera"]}) == :undeclared
      assert Frames.refusal({:invalid_tincture, "no"}) == :undeclared
      assert Frames.refusal({:placement, "canvas"}) == :undeclared
      assert Frames.refusal(:unregistered) == :unregistered
      assert Frames.refusal(:ungranted) == :ungranted
      assert Frames.refusal(:revoked) == :refused
      assert Frames.refusal(:expired) == :refused
    end
  end

  describe "declared actions" do
    test "a frame declares only the actions its version listed" do
      keeper = launch("keeper", actions: ["vault.create", "vault.status"])
      assert Frames.declares?(keeper, "vault.create")
      refute Frames.declares?(launch("x", actions: []), "vault.create")
      refute Frames.declares?(%{}, "vault.create")
    end
  end
end
