# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.ArrangementTest do
  @moduledoc """
  The person's gestures on their layout: each makes exactly its own
  change to one canvas's apps in one posture, keeps every bound the
  layout holds, renumbers the stacking order without growing it, and
  gives the same document made twice as made once; a gesture on an app
  the canvas does not place, a placement in the hand or a document the
  layout refuses changes nothing.
  """

  use ExUnit.Case, async: true

  alias Prism.Arrangement
  alias Prima.Layout

  @window %{x: 1000, y: 1000, w: 3000, h: 5000}

  defp window(ref, order, minimised \\ false),
    do: %{
      "tincture" => ref,
      "placement" => "window",
      "order" => order,
      "geometry" => %{"x" => 1000, "y" => 1000, "w" => 3000, "h" => 5000},
      "minimised" => minimised
    }

  defp tile(ref, order),
    do: %{
      "tincture" => ref,
      "placement" => "tile",
      "order" => order,
      "side" => "right",
      "share" => 2500,
      "minimised" => false
    }

  defp layout(desk, hand \\ []) do
    {:ok, layout} =
      Layout.validate(%{
        "version" => 3,
        "canvases" => [
          %{
            "id" => "home",
            "tincture" => "tincture:local.canvas",
            "postures" => %{"desk" => %{"apps" => desk}, "hand" => %{"apps" => hand}}
          },
          %{"id" => "work", "tincture" => "tincture:local.work", "postures" => %{}}
        ]
      })

    layout
  end

  defp apps(layout, posture \\ "desk") do
    {:ok, [home | _]} = Layout.arrangement(layout, posture)
    home.apps
  end

  defp app(layout, ref, posture \\ "desk"),
    do: Enum.find(apps(layout, posture), &(&1.tincture == ref))

  @a "tincture:local.a"
  @b "tincture:local.b"
  @c "tincture:local.c"

  describe "each gesture" do
    setup do
      {:ok, layout: layout([window(@a, 0), tile(@b, 1), window(@c, 2)])}
    end

    test "a move stands the app as a window at the geometry, raised above every other",
         %{layout: layout} do
      geometry = %{x: 0, y: 2000, w: 5000, h: 8000}
      assert {:ok, moved} = Arrangement.apply(layout, "home", "desk", {:move, @b, geometry})

      assert app(moved, @b) == %{
               tincture: @b,
               placement: :window,
               order: 2,
               geometry: geometry,
               side: nil,
               share: nil,
               minimised: false
             }

      assert Enum.map(apps(moved), &{&1.tincture, &1.order}) == [{@a, 0}, {@c, 1}, {@b, 2}]
    end

    test "a resize and a tile raise the app too; a minimise and a close raise nothing",
         %{layout: layout} do
      order = fn layout -> Enum.map(apps(layout), &{&1.tincture, &1.order}) end
      geometry = %{x: 100, y: 100, w: 9000, h: 9000}

      assert {:ok, resized} = Arrangement.apply(layout, "home", "desk", {:resize, @a, geometry})
      assert order.(resized) == [{@b, 0}, {@c, 1}, {@a, 2}]

      assert {:ok, resized} = Arrangement.apply(layout, "home", "desk", {:resize, @b, 4000})
      assert order.(resized) == [{@a, 0}, {@c, 1}, {@b, 2}]

      assert {:ok, tiled} = Arrangement.apply(layout, "home", "desk", {:tile, @a, :left, 2000})
      assert order.(tiled) == [{@b, 0}, {@c, 1}, {@a, 2}]

      assert {:ok, minimised} = Arrangement.apply(layout, "home", "desk", {:minimise, @a})
      assert order.(minimised) == order.(layout)

      assert {:ok, closed} = Arrangement.apply(layout, "home", "desk", {:close, @a})
      assert order.(closed) == [{@b, 0}, {@c, 1}]
    end

    test "a resize takes a window's geometry or a tile's share, and nothing of another kind",
         %{layout: layout} do
      geometry = %{x: 100, y: 100, w: 9000, h: 9000}
      assert {:ok, resized} = Arrangement.apply(layout, "home", "desk", {:resize, @a, geometry})
      assert app(resized, @a).geometry == geometry

      assert {:ok, resized} = Arrangement.apply(layout, "home", "desk", {:resize, @b, 4000})
      assert %{placement: :tile, side: :right, share: 4000} = app(resized, @b)

      assert {:ok, ^layout} = Arrangement.apply(layout, "home", "desk", {:resize, @a, 4000})
    end

    test "a tile, a full, a minimise and a restore stand the app so", %{layout: layout} do
      assert {:ok, tiled} = Arrangement.apply(layout, "home", "desk", {:tile, @a, :left, 2000})
      assert %{placement: :tile, side: :left, share: 2000, geometry: nil} = app(tiled, @a)

      assert {:ok, full} = Arrangement.apply(layout, "home", "desk", {:full, @b})
      assert %{placement: :full, side: nil, share: nil} = app(full, @b)

      assert {:ok, minimised} = Arrangement.apply(layout, "home", "desk", {:minimise, @c})
      assert %{placement: :window, geometry: @window, minimised: true} = app(minimised, @c)

      assert {:ok, restored} = Arrangement.apply(minimised, "home", "desk", {:restore, @c})
      assert %{minimised: false, order: 2} = app(restored, @c)
    end

    test "a raise puts the app last in a stacking order renumbered from 0", %{layout: layout} do
      assert {:ok, raised} = Arrangement.apply(layout, "home", "desk", {:raise, @a})
      assert Enum.map(apps(raised), &{&1.tincture, &1.order}) == [{@b, 0}, {@c, 1}, {@a, 2}]

      # Raised again it stays where it is.
      assert {:ok, ^raised} = Arrangement.apply(raised, "home", "desk", {:raise, @a})
    end

    test "a close takes the app off the canvas, and the rest close up", %{layout: layout} do
      assert {:ok, closed} = Arrangement.apply(layout, "home", "desk", {:close, @b})
      assert Enum.map(apps(closed), &{&1.tincture, &1.order}) == [{@a, 0}, {@c, 1}]
    end

    test "an open places an app not placed above the rest, restores a minimised one and raises a shown one",
         %{layout: layout} do
      d = "tincture:local.d"
      new = Arrangement.open(d, nil, "desk", 3)
      assert {:ok, opened} = Arrangement.apply(layout, "home", "desk", {:open, d, new})
      assert %{placement: :window, order: 3, minimised: false} = app(opened, d)

      {:ok, minimised} = Arrangement.apply(layout, "home", "desk", {:minimise, @a})
      assert {:ok, reopened} = Arrangement.apply(minimised, "home", "desk", {:open, @a, new})

      assert %{placement: :window, geometry: @window, minimised: false, order: 2} =
               app(reopened, @a)
    end

    test "made twice, each gesture gives the document made once", %{layout: layout} do
      for gesture <- [
            {:move, @a, %{x: 0, y: 0, w: 100, h: 100}},
            {:resize, @b, 3000},
            {:tile, @c, :left, 1500},
            {:full, @a},
            {:minimise, @b},
            {:restore, @b},
            {:raise, @a},
            {:open, "tincture:local.d", Arrangement.open("tincture:local.d", nil, "desk", 3)}
          ] do
        {:ok, once} = Arrangement.apply(layout, "home", "desk", gesture)
        assert {:ok, ^once} = Arrangement.apply(once, "home", "desk", gesture), inspect(gesture)
      end

      # Closed once, the app is gone: closing it again is refused, and the
      # document stays the one closing it once made.
      {:ok, closed} = Arrangement.apply(layout, "home", "desk", {:close, @c})
      assert {:error, :not_placed} = Arrangement.apply(closed, "home", "desk", {:close, @c})
    end

    test "the other canvas and the other posture are left as they are", %{layout: layout} do
      {:ok, moved} = Arrangement.apply(layout, "home", "desk", {:raise, @a})
      assert apps(moved, "hand") == apps(layout, "hand")
      assert Enum.at(moved.canvases, 1) == Enum.at(layout.canvases, 1)
    end
  end

  describe "a refusal changes nothing" do
    setup do
      {:ok, layout: layout([window(@a, 0), tile(@b, 1)], [window(@a, 0)])}
    end

    test "for an app the canvas does not place, or a canvas the layout does not have",
         %{layout: layout} do
      assert {:error, :not_placed} = Arrangement.apply(layout, "home", "desk", {:raise, @c})
      assert {:error, :not_placed} = Arrangement.apply(layout, "work", "desk", {:close, @a})
      assert {:error, :no_canvas} = Arrangement.apply(layout, "gone", "desk", {:raise, @a})
    end

    test "for a placement in the hand, where every app is full; the stacking gestures stand",
         %{layout: layout} do
      for gesture <- [
            {:move, @a, @window},
            {:resize, @a, @window},
            {:tile, @a, :left, 2000},
            {:full, @a}
          ] do
        assert {:error, :hand} = Arrangement.apply(layout, "home", "hand", gesture)
      end

      assert {:ok, _} = Arrangement.apply(layout, "home", "hand", {:minimise, @a})
      assert {:ok, _} = Arrangement.apply(layout, "home", "hand", {:close, @a})
    end

    test "for a geometry or a share outside the layout's bounds, with the layout's sentence",
         %{layout: layout} do
      for geometry <- [
            %{x: 10_001, y: 0, w: 100, h: 100},
            %{x: -1, y: 0, w: 100, h: 100},
            %{x: 0, y: 0, w: 0, h: 100},
            %{x: 0, y: 0, w: 100, h: 10_001}
          ] do
        assert {:error, {:invalid, sentence}} =
                 Arrangement.apply(layout, "home", "desk", {:move, @a, geometry})

        assert sentence =~ "w and h"
      end

      for share <- [0, 10_001] do
        assert {:error, {:invalid, _}} =
                 Arrangement.apply(layout, "home", "desk", {:tile, @a, :left, share})

        assert {:error, {:invalid, _}} =
                 Arrangement.apply(layout, "home", "desk", {:resize, @b, share})
      end
    end
  end

  describe "an app opened that the layout does not place" do
    test "is full in the hand, a tile where its hint asks, and otherwise a window cascaded" do
      assert %{placement: :full} = Arrangement.open(@a, nil, "hand", 0)

      assert %{placement: :tile, side: :left, share: 3000} =
               Arrangement.open(@a, %Prima.Manifest.Tincture.Size{tile: "left"}, "desk", 0)

      assert %{placement: :window, geometry: first} = Arrangement.open(@a, nil, "desk", 0)
      assert %{placement: :window, geometry: second} = Arrangement.open(@a, nil, "desk", 1)
      assert second.x > first.x and second.y > first.y

      for placed <- 0..40 do
        layout = layout([])
        app = Arrangement.open(@a, nil, "desk", placed)
        assert {:ok, _} = Arrangement.apply(layout, "home", "desk", {:open, @a, app})
      end
    end
  end
end
