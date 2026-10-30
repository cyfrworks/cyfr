# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LayoutTest do
  @moduledoc """
  The layout document against `tests/fixtures/layout.json`: the valid
  document reads, writes back to itself and hashes to the fixture's
  canonical bytes and digest; every refused document is refused; a
  document of another version is refused by `validate/1` and decodes as
  `:unsupported_version`; and the shape's own rules — each placement's
  keys, canonical app order, a posture a canvas does not name read as
  empty, an empty layout, the bounds, a tincture nobody installed kept.
  """

  use ExUnit.Case, async: true

  alias Prima.Layout

  @vectors Path.expand("../../../../tests/fixtures/layout.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp document(canvases), do: %{"version" => 3, "canvases" => canvases}

  defp canvas(id, tincture, postures \\ %{}),
    do: %{"id" => id, "tincture" => tincture, "postures" => postures}

  defp window(tincture, order \\ 0),
    do: %{
      "tincture" => tincture,
      "placement" => "window",
      "order" => order,
      "geometry" => %{"x" => 0, "y" => 0, "w" => 3000, "h" => 5000},
      "minimised" => false
    }

  defp full(tincture, order),
    do: %{"tincture" => tincture, "placement" => "full", "order" => order, "minimised" => false}

  defp desk(apps),
    do: document([canvas("home", "tincture:local.canvas", %{"desk" => %{"apps" => apps}})])

  describe "the fixture" do
    test "the valid document reads, writes back and hashes as the fixture says" do
      v = vectors()

      assert {:ok, %Layout{version: 3} = layout} = Layout.validate(v["valid"])
      assert Layout.to_json(layout) == v["valid"]
      assert Layout.encode(layout) == v["canonical"]
      assert Layout.digest(layout) == v["digest"]
      assert {:ok, ^layout} = Layout.decode(v["canonical"])
    end

    test "each placement reads as the struct with exactly its own fields set" do
      {:ok, layout} = Layout.validate(vectors()["valid"])

      assert {:ok, [%{id: "home", tincture: "tincture:local.canvas", apps: apps}, markets]} =
               Layout.arrangement(layout, "desk")

      assert apps == [
               %{
                 tincture: "tincture:local.weather-look",
                 placement: :tile,
                 order: 0,
                 geometry: nil,
                 side: :right,
                 share: 2500,
                 minimised: false
               },
               %{
                 tincture: "tincture:example.com.not-installed",
                 placement: :tile,
                 order: 1,
                 geometry: nil,
                 side: :left,
                 share: 2000,
                 minimised: true
               },
               %{
                 tincture: "tincture:local.flappy-bird",
                 placement: :window,
                 order: 2,
                 geometry: %{x: 4700, y: 4400, w: 2300, h: 5000},
                 side: nil,
                 share: nil,
                 minimised: false
               },
               %{
                 tincture: "tincture:local.vault",
                 placement: :full,
                 order: 3,
                 geometry: nil,
                 side: nil,
                 share: nil,
                 minimised: true
               }
             ]

      assert markets == %{id: "markets", tincture: "tincture:local.markets", apps: []}
    end

    test "a tincture nobody installed is kept" do
      {:ok, layout} = Layout.validate(vectors()["valid"])
      assert "tincture:example.com.not-installed" in Layout.tinctures(layout)
    end

    test "every refused document is refused, with a sentence" do
      invalid = vectors()["invalid"]
      assert length(invalid) >= 30

      for %{"why" => why, "document" => document} <- invalid do
        assert {:error, {:invalid_layout, sentence}} = Layout.validate(document), why
        assert is_binary(sentence) and sentence != ""
      end
    end

    test "a document never carries an operation or a stream" do
      [operation, stream | _] = vectors()["invalid"]

      assert {:error, {:invalid_layout, sentence}} = Layout.validate(operation["document"])
      assert sentence =~ "action"
      assert {:error, {:invalid_layout, sentence}} = Layout.validate(stream["document"])
      assert sentence =~ "stream"
    end

    test "a document of another version is refused, and its stored bytes decode as unsupported" do
      unsupported = vectors()["unsupported"]
      assert length(unsupported) >= 2

      for %{"why" => why, "document" => document} <- unsupported do
        assert {:error, {:invalid_layout, sentence}} = Layout.validate(document), why
        assert sentence =~ "version must be 3", why
        assert {:error, :unsupported_version} = Layout.decode(Jason.encode!(document)), why
      end
    end
  end

  describe "the shape" do
    test "apps are held in {order, tincture} order, so the digest ignores the list's order" do
      apps = [
        window("tincture:local.vault", 1),
        full("tincture:local.timer", 0),
        window("tincture:local.clock", 1)
      ]

      {:ok, forward} = Layout.validate(desk(apps))
      {:ok, reversed} = Layout.validate(desk(Enum.reverse(apps)))

      {:ok, [%{apps: held}]} = Layout.arrangement(forward, "desk")

      assert Enum.map(held, & &1.tincture) ==
               ~w(tincture:local.timer tincture:local.clock tincture:local.vault)

      assert Layout.digest(forward) == Layout.digest(reversed)
    end

    test "each posture arranges every canvas in order, and a posture a canvas does not name is empty" do
      {:ok, layout} =
        Layout.validate(
          document([
            canvas("home", "tincture:local.canvas", %{
              "desk" => %{"apps" => [full("tincture:local.vault", 0)]}
            }),
            canvas("markets", "tincture:local.markets")
          ])
        )

      assert {:ok,
              [
                %{
                  id: "home",
                  tincture: "tincture:local.canvas",
                  apps: [%{tincture: "tincture:local.vault", placement: :full, order: 0}]
                },
                %{id: "markets", tincture: "tincture:local.markets", apps: []}
              ]} = Layout.arrangement(layout, "desk")

      assert {:ok, [%{id: "home", apps: []}, %{id: "markets", apps: []}]} =
               Layout.arrangement(layout, "hand")

      assert :error = Layout.arrangement(layout, "wall")
    end

    test "an empty layout is valid and arranges nothing" do
      assert {:ok, %Layout{canvases: []} = empty} = Layout.validate(document([]))
      assert {:ok, []} = Layout.arrangement(empty, "desk")
      assert Layout.tinctures(empty) == []
    end

    test "the default is one canvas, home, on the shipped canvas, with nothing placed, and is itself valid" do
      default = Layout.default()

      assert default == %Layout{
               version: 3,
               canvases: [%{id: "home", tincture: "tincture:local.canvas", postures: %{}}]
             }

      assert Layout.tinctures(default) == ["tincture:local.canvas"]

      for name <- Layout.postures() do
        assert {:ok, [%{id: "home", tincture: "tincture:local.canvas", apps: []}]} =
                 Layout.arrangement(default, name)
      end

      assert {:ok, ^default} = Layout.validate(Layout.to_json(default))
    end

    test "eight canvases and 32 apps are held, and one more of either is not" do
      canvases = fn n -> for i <- 1..n//1, do: canvas("c#{i}", "tincture:local.canvas-#{i}") end
      apps = fn n -> desk(for i <- 1..n//1, do: window("tincture:local.app-#{i}", i)) end

      assert {:ok, _} = Layout.validate(document(canvases.(8)))
      assert {:error, {:invalid_layout, _}} = Layout.validate(document(canvases.(9)))
      assert {:ok, _} = Layout.validate(apps.(32))
      assert {:error, {:invalid_layout, sentence}} = Layout.validate(apps.(33))
      assert sentence =~ "at most 32 apps"
    end

    test "a window's geometry and a tile's share hold their bounds at both ends" do
      geometry = fn x, y, w, h ->
        desk([
          Map.put(window("tincture:local.vault"), "geometry", %{
            "x" => x,
            "y" => y,
            "w" => w,
            "h" => h
          })
        ])
      end

      tile = fn share ->
        desk([
          %{
            "tincture" => "tincture:local.vault",
            "placement" => "tile",
            "order" => 0,
            "side" => "left",
            "share" => share,
            "minimised" => false
          }
        ])
      end

      assert {:ok, _} = Layout.validate(geometry.(0, 0, 1, 1))
      assert {:ok, _} = Layout.validate(geometry.(10_000, 10_000, 10_000, 10_000))
      assert {:error, {:invalid_layout, _}} = Layout.validate(geometry.(0, 10_001, 1, 1))
      assert {:error, {:invalid_layout, _}} = Layout.validate(geometry.(0, 0, 1, 0))
      assert {:error, {:invalid_layout, _}} = Layout.validate(geometry.(0.5, 0, 1, 1))
      assert {:ok, _} = Layout.validate(tile.(1))
      assert {:ok, _} = Layout.validate(tile.(10_000))
      assert {:error, {:invalid_layout, sentence}} = Layout.validate(tile.(0))
      assert sentence =~ "share"
    end

    test "a refusal names the placement whose keys an app breaks" do
      assert {:error, {:invalid_layout, sentence}} =
               Layout.validate(desk([Map.put(window("tincture:local.vault"), "side", "left")]))

      assert sentence =~ "placed as a window"
      assert sentence =~ "side"
    end

    test "a version-2 document is refused for its version" do
      document = %{
        "version" => 2,
        "canvases" => [
          canvas("home", "tincture:local.canvas", %{"desk" => %{"apps" => [], "floating" => []}})
        ]
      }

      assert {:error, {:invalid_layout, sentence}} = Layout.validate(document)
      assert sentence =~ "version must be 3"
    end

    test "stored bytes of this version that do not read, or name no whole-number version, are refused" do
      broken = Jason.encode!(desk([Map.delete(window("tincture:local.vault"), "geometry")]))

      assert {:error, {:invalid_layout, _}} = Layout.decode(broken)
      assert {:error, {:invalid_layout, _}} = Layout.decode(~s({"version":"2","canvases":[]}))
      assert {:error, {:invalid_layout, _}} = Layout.decode(~s({"canvases":[]}))
      assert {:error, {:invalid_layout, _}} = Layout.decode("[2]")
    end

    test "a reference is spelt canonically" do
      assert {:error, {:invalid_layout, sentence}} =
               Layout.validate(document([canvas("home", "t:local.canvas")]))

      assert sentence =~ "tincture:local.canvas"
    end

    test "what is not an object, or not JSON, is refused" do
      assert {:error, {:invalid_layout, _}} = Layout.validate([])
      assert {:error, {:invalid_layout, _}} = Layout.validate(nil)
      assert {:error, {:invalid_layout, _}} = Layout.decode("{")
    end
  end
end
