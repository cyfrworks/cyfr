# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LayoutTest do
  @moduledoc """
  The layout document against `tests/fixtures/layout.json`: the valid
  document reads, writes back to itself and hashes to the fixture's
  canonical bytes and digest; every refused document is refused, a
  version-1 document among them; and the shape's own rules — canonical
  app order, a posture a canvas does not name read as empty, an empty
  layout, the bounds, a tincture nobody installed kept.
  """

  use ExUnit.Case, async: true

  alias Prima.Layout

  @vectors Path.expand("../../../../tests/fixtures/layout.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp document(canvases), do: %{"version" => 2, "canvases" => canvases}

  defp canvas(id, tincture, postures \\ %{}),
    do: %{"id" => id, "tincture" => tincture, "postures" => postures}

  defp app(tincture, mode \\ "column", order \\ 0),
    do: %{"tincture" => tincture, "mode" => mode, "order" => order}

  describe "the fixture" do
    test "the valid document reads, writes back and hashes as the fixture says" do
      v = vectors()

      assert {:ok, %Layout{version: 2} = layout} = Layout.validate(v["valid"])
      assert Layout.to_json(layout) == v["valid"]
      assert Layout.encode(layout) == v["canonical"]
      assert Layout.digest(layout) == v["digest"]
      assert {:ok, ^layout} = Layout.decode(v["canonical"])
    end

    test "a tincture nobody installed is kept" do
      {:ok, layout} = Layout.validate(vectors()["valid"])
      assert "tincture:example.com.not-installed" in Layout.tinctures(layout)

      {:ok, [home, _markets]} = Layout.arrangement(layout, "desk")
      assert Enum.any?(home.apps, &(&1.tincture == "tincture:example.com.not-installed"))
    end

    test "every refused document is refused, with a sentence" do
      invalid = vectors()["invalid"]
      assert length(invalid) >= 8

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
  end

  describe "the shape" do
    test "apps are held in {order, tincture} order, so the digest ignores the list's order" do
      apps = [
        app("tincture:local.vault", "column", 1),
        app("tincture:local.timer", "full", 0),
        app("tincture:local.clock", "column", 1)
      ]

      layout_of = fn apps ->
        document([
          canvas("home", "tincture:local.canvas", %{"hand" => %{"apps" => apps, "floating" => []}})
        ])
      end

      {:ok, forward} = Layout.validate(layout_of.(apps))
      {:ok, reversed} = Layout.validate(layout_of.(Enum.reverse(apps)))

      {:ok, [%{apps: held}]} = Layout.arrangement(forward, "hand")

      assert Enum.map(held, & &1.tincture) ==
               ~w(tincture:local.timer tincture:local.clock tincture:local.vault)

      assert Layout.digest(forward) == Layout.digest(reversed)
    end

    test "each posture arranges every canvas in order, and a posture a canvas does not name is empty" do
      {:ok, layout} =
        Layout.validate(
          document([
            canvas("home", "tincture:local.canvas", %{
              "desk" => %{
                "apps" => [app("tincture:local.vault")],
                "floating" => [
                  %{"tincture" => "tincture:local.timer", "position" => %{"x" => 1, "y" => 2}}
                ]
              }
            }),
            canvas("markets", "tincture:local.markets")
          ])
        )

      assert {:ok,
              [
                %{
                  id: "home",
                  tincture: "tincture:local.canvas",
                  apps: [%{tincture: "tincture:local.vault", mode: :column, order: 0}],
                  floating: [%{tincture: "tincture:local.timer", position: %{x: 1, y: 2}}]
                },
                %{id: "markets", tincture: "tincture:local.markets", apps: [], floating: []}
              ]} = Layout.arrangement(layout, "desk")

      assert {:ok, [%{id: "home", apps: [], floating: []}, %{id: "markets"}]} =
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

      assert %Layout{
               version: 2,
               canvases: [%{id: "home", tincture: "tincture:local.canvas", postures: %{}}]
             } = default

      assert Layout.tinctures(default) == ["tincture:local.canvas"]

      for name <- Layout.postures() do
        assert {:ok, [%{id: "home", apps: [], floating: []}]} = Layout.arrangement(default, name)
      end

      assert {:ok, ^default} = Layout.validate(Layout.to_json(default))
    end

    test "eight canvases, 32 apps and 16 floating tinctures are held, and one more of each is not" do
      canvases = fn n ->
        for i <- 1..n//1, do: canvas("c#{i}", "tincture:local.canvas-#{i}")
      end

      posture = fn apps, floating ->
        document([
          canvas("home", "tincture:local.canvas", %{
            "desk" => %{
              "apps" => for(i <- 1..apps//1, do: app("tincture:local.app-#{i}", "column", i)),
              "floating" =>
                for(
                  i <- 1..floating//1,
                  do: %{
                    "tincture" => "tincture:local.float-#{i}",
                    "position" => %{"x" => 0, "y" => 0}
                  }
                )
            }
          })
        ])
      end

      assert {:ok, _} = Layout.validate(document(canvases.(8)))
      assert {:error, {:invalid_layout, _}} = Layout.validate(document(canvases.(9)))
      assert {:ok, _} = Layout.validate(posture.(32, 16))
      assert {:error, {:invalid_layout, _}} = Layout.validate(posture.(33, 0))
      assert {:error, {:invalid_layout, _}} = Layout.validate(posture.(0, 17))
    end

    test "a version-1 document is refused for its version" do
      document = %{
        "version" => 1,
        "postures" => %{"desk" => %{"desktop" => "tincture:local.canvas", "slots" => []}}
      }

      assert {:error, {:invalid_layout, sentence}} = Layout.validate(document)
      assert sentence =~ "version must be 2"
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
