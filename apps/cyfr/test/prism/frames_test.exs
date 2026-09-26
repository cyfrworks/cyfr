# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.FramesTest do
  @moduledoc """
  The frames' pure transitions, without a store: which frames an
  arrangement places and for which tinctures, what is visible, which
  credential transitions visibility asks for, to which frame a message is
  attributed, the one-time handshake, and the signals the view sends. The
  effects, through `Sanctum.TinctureAuth`, are `PrismWeb.ShellFrameTest`'s
  and `PrismWeb.CanvasLiveTest`'s.
  """

  use ExUnit.Case, async: true

  alias Prism.Frames

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

  defp frame(placement, tincture_id, fields \\ []) do
    id = Keyword.get(fields, :id, "frm_" <> Base.url_encode64(:crypto.strong_rand_bytes(9)))

    Map.merge(
      %{
        key: Frames.key(placement, tincture_id),
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
        placement: placement,
        visible: true,
        background: false
      },
      Map.new(fields)
    )
  end

  defp held(frames), do: Enum.reduce(frames, Frames.new(), &Frames.put(&2, &1))

  describe "placement" do
    test "a full slot of an installed tincture is framed at its slot; icon and card slots are not" do
      cards = [card("notes"), card("clock")]

      arrangement = %{
        desktop: "tincture:local.desktop",
        slots: [
          %{id: "main", tincture: "tincture:local.notes", size: :full, order: 0, card: nil},
          %{id: "ico", tincture: "tincture:local.clock", size: :icon, order: 1, card: nil},
          %{id: "crd", tincture: "tincture:local.clock", size: :card, order: 2, card: nil}
        ],
        floating: []
      }

      assert [{{:slot, "main"}, %{id: "iframe_notes"}}] = Frames.placements(arrangement, cards)
    end

    test "an entry naming a tincture nobody installed places nothing" do
      arrangement = %{
        desktop: "tincture:local.desktop",
        slots: [%{id: "gone", tincture: "tincture:acme.gone", size: :full, order: 0, card: nil}],
        floating: [%{tincture: "tincture:acme.ghost", position: %{x: 0, y: 0}}]
      }

      assert Frames.placements(arrangement, [card("notes")]) == []
    end

    test "only a tincture that declares float floats, once, where the layout first puts it" do
      cards = [
        card("clock", %{"placement" => "float"}),
        card("notes"),
        card("desk", %{"placement" => "desktop"})
      ]

      arrangement = %{
        desktop: "tincture:local.desktop",
        slots: [],
        floating: [
          %{tincture: "tincture:local.notes", position: %{x: 0, y: 0}},
          %{tincture: "tincture:local.desk", position: %{x: 1, y: 1}},
          %{tincture: "tincture:local.clock", position: %{x: 2500, y: 5000}},
          %{tincture: "tincture:local.clock", position: %{x: 9000, y: 9000}}
        ]
      }

      assert [{{:floating, %{x: 2500, y: 5000}}, %{id: "iframe_clock"}}] =
               Frames.placements(arrangement, cards)
    end

    test "floats? reads the declaration, and a declaration off the rules floats nothing" do
      assert Frames.floats?(card("a", %{"placement" => "float"}))
      refute Frames.floats?(card("b"))
      refute Frames.floats?(card("c", %{"placement" => "float", "capabilities" => ["camera"]}))
      refute Frames.floats?(%{manifest: nil})
    end

    test "a layout reference resolves to the listed card by publisher and name" do
      cards = [card("notes"), %{card("notes") | publisher: "acme", id: "iframe_acme"}]

      assert %{id: "iframe_notes"} = Frames.resolve("tincture:local.notes", cards)
      assert %{id: "iframe_acme"} = Frames.resolve("tincture:acme.notes", cards)
      assert Frames.resolve("tincture:local.missing", cards) == nil
      assert Frames.resolve("not a ref", cards) == nil
      assert Frames.resolve(nil, cards) == nil
    end

    test "only a floating frame moves, and only to the placement it is given" do
      floating = frame({:floating, %{x: 0, y: 0}}, "iframe_clock")
      slot = frame({:slot, "main"}, "iframe_notes")
      t = held([floating, slot])

      moved = Frames.place(t, floating.key, {:floating, %{x: 10, y: 20}})
      assert Frames.get(moved, floating.key).placement == {:floating, %{x: 10, y: 20}}

      assert Frames.place(t, slot.key, {:floating, %{x: 1, y: 1}}) == t
      assert Frames.place(t, floating.key, :full) == t
    end
  end

  describe "visibility" do
    setup do
      full_a = frame(:full, "iframe_a")
      full_b = frame(:full, "iframe_b")
      slot = frame({:slot, "main"}, "iframe_notes")
      floating = frame({:floating, %{x: 0, y: 0}}, "iframe_clock", background: true)
      {:ok, t: held([slot, floating, full_a, full_b]), full_a: full_a, full_b: full_b}
    end

    test "with no full frame active, the slot and floating frames are shown and full ones hidden",
         %{t: t} do
      shown = t |> Frames.visibility() |> Frames.list() |> Enum.map(&{&1.tincture_id, &1.visible})

      assert shown == [
               {"iframe_notes", true},
               {"iframe_clock", true},
               {"iframe_a", false},
               {"iframe_b", false}
             ]
    end

    test "the active full frame alone is shown", %{t: t, full_b: full_b} do
      t = t |> Frames.activate(full_b.key) |> Frames.visibility()

      assert [%{tincture_id: "iframe_b"}] = t |> Frames.list() |> Enum.filter(& &1.visible)
      assert Frames.active_tincture(t) == "iframe_b"
    end

    test "a hidden live frame without a background grant is to freeze; a background one is not",
         %{t: t, full_a: full_a} do
      t = t |> Frames.activate(full_a.key) |> Frames.visibility()

      assert Frames.plan(t) == [
               {:freeze, {:slot, "main"}},
               {:freeze, {:full, "iframe_b"}}
             ]
    end

    test "a shown frozen frame is to thaw, and a refused one is left alone", %{t: t} do
      t =
        t
        |> Frames.freeze({:slot, "main"})
        |> Frames.refuse({:floating, "iframe_clock"}, :refused)
        |> Frames.visibility()

      assert {:thaw, {:slot, "main"}} in Frames.plan(t)
      refute Enum.any?(Frames.plan(t), &match?({_, {:floating, _}}, &1))
      assert %{state: :refused, bearer: nil} = Frames.get(t, {:floating, "iframe_clock"})
    end

    test "activating a key that is not a held full frame changes nothing", %{t: t} do
      assert Frames.activate(t, {:slot, "main"}) == t
      assert Frames.activate(t, {:full, "iframe_nobody"}) == t
    end

    test "forgetting the active frame makes the first full frame still held active",
         %{t: t, full_a: full_a, full_b: full_b} do
      t = t |> Frames.activate(full_b.key) |> Frames.forget(full_b.key)
      assert Frames.active(t).key == full_a.key

      t = Frames.forget(t, full_a.key)
      assert Frames.active(t) == nil
      assert Enum.map(Frames.list(t), & &1.tincture_id) == ["iframe_notes", "iframe_clock"]
    end
  end

  describe "attribution" do
    test "a message is attributed only to a live frame this value holds" do
      live = frame(:full, "iframe_a", id: "frm_live_frame_1")
      frozen = frame(:full, "iframe_b", id: "frm_frozen_frame", state: :frozen)
      refused = frame(:full, "iframe_c", id: "frm_refused_frm", state: :refused)
      t = held([live, frozen, refused])

      assert {:ok, %{key: {:full, "iframe_a"}}} = Frames.attribute(t, "frm_live_frame_1")
      assert Frames.attribute(t, "frm_frozen_frame") == :error
      assert Frames.attribute(t, "frm_refused_frm") == :error
      assert Frames.attribute(t, "frm_not_this_views") == :error
      assert Frames.attribute(t, nil) == :error
    end

    test "the bearer is handed over once" do
      t = held([frame(:full, "iframe_a", id: "frm_handshake_1", bearer: "secret")])

      assert {:ok, "secret", t} = Frames.hand_over(t, "frm_handshake_1")
      assert Frames.hand_over(t, "frm_handshake_1") == :error
      assert Frames.hand_over(t, "frm_other_frame") == :error
      assert Frames.hand_over(t, 42) == :error
    end

    test "a dropped message is counted" do
      assert Frames.new() |> Frames.drop_message() |> Frames.drop_message() |> Frames.dropped() ==
               2
    end
  end

  describe "signals" do
    test "a frame whose state moved between live and frozen is signalled, and nothing else" do
      a = frame(:full, "iframe_a", id: "frm_signal_aaaa")
      b = frame(:full, "iframe_b", id: "frm_signal_bbbb")
      c = frame(:full, "iframe_c", id: "frm_signal_cccc")
      before = held([a, b, c])

      later =
        before
        |> Frames.freeze(a.key)
        |> Frames.refuse(c.key, :unavailable)
        |> Frames.put(frame(:full, "iframe_d", state: :frozen))

      assert Frames.signals(before, later) == [%{frame: "frm_signal_aaaa", state: "frozen"}]

      assert Frames.signals(later, Frames.thaw(later, a.key)) == [
               %{frame: "frm_signal_aaaa", state: "live"}
             ]
    end

    test "a frame reopened under the same key is not signalled as the old one" do
      old = frame(:full, "iframe_a", id: "frm_old_frame_1", state: :frozen)
      new = frame(:full, "iframe_a", id: "frm_new_frame_1")

      assert Frames.signals(held([old]), held([new])) == []
    end
  end

  describe "refusal classes" do
    test "each refusal reads as the class the frame shows" do
      assert Frames.refusal(:unavailable) == :unavailable
      assert Frames.refusal(:not_owner) == :unavailable
      assert Frames.refusal({:undeclared_capability, ["camera"]}) == :undeclared
      assert Frames.refusal({:invalid_tincture, "no"}) == :undeclared
      assert Frames.refusal(:unregistered) == :unregistered
      assert Frames.refusal(:revoked) == :refused
      assert Frames.refusal(:expired) == :refused
    end
  end
end
