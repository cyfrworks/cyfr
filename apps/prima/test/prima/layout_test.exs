# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LayoutTest do
  @moduledoc """
  The layout document against `tests/fixtures/layout.json`: the valid
  document reads, writes back to itself and hashes to the fixture's
  canonical bytes and digest; every refused document is refused; and the
  shape's own rules — canonical slot order, a posture read from the
  default, a tincture nobody installed kept.
  """

  use ExUnit.Case, async: true

  alias Prima.Layout

  @vectors Path.expand("../../../../tests/fixtures/layout.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  describe "the fixture" do
    test "the valid document reads, writes back and hashes as the fixture says" do
      v = vectors()

      assert {:ok, %Layout{version: 1} = layout} = Layout.validate(v["valid"])
      assert Layout.to_json(layout) == v["valid"]
      assert Layout.encode(layout) == v["canonical"]
      assert Layout.digest(layout) == v["digest"]
      assert {:ok, ^layout} = Layout.decode(v["canonical"])
    end

    test "a tincture nobody installed is kept, to be drawn as a placeholder" do
      {:ok, layout} = Layout.validate(vectors()["valid"])
      assert "tincture:example.com.not-installed" in Layout.tinctures(layout)

      {:ok, desk} = Layout.posture(layout, "desk")
      assert Enum.any?(desk.slots, &(&1.tincture == "tincture:example.com.not-installed"))
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
    test "slots are held in {order, id} order, so the digest ignores the list's order" do
      slots = [
        %{"id" => "b", "tincture" => "tincture:local.vault", "size" => "icon", "order" => 1},
        %{"id" => "c", "tincture" => "tincture:local.timer", "size" => "icon", "order" => 0},
        %{"id" => "a", "tincture" => "tincture:local.timer", "size" => "icon", "order" => 1}
      ]

      document = fn slots ->
        %{
          "version" => 1,
          "postures" => %{
            "hand" => %{"desktop" => "tincture:local.desktop", "slots" => slots, "floating" => []}
          }
        }
      end

      {:ok, forward} = Layout.validate(document.(slots))
      {:ok, reversed} = Layout.validate(document.(Enum.reverse(slots)))

      assert Enum.map(forward.postures["hand"].slots, & &1.id) == ~w(c a b)
      assert Layout.digest(forward) == Layout.digest(reversed)
    end

    test "a posture the document does not name reads as the default's" do
      {:ok, layout} =
        Layout.validate(%{
          "version" => 1,
          "postures" => %{"desk" => %{"desktop" => "tincture:local.other"}}
        })

      assert {:ok, %{desktop: "tincture:local.other", slots: [], floating: []}} =
               Layout.posture(layout, "desk")

      assert {:ok, %{desktop: "tincture:local.desktop"}} = Layout.posture(layout, "hand")
      assert :error = Layout.posture(layout, "wall")
    end

    test "the default runs the shipped desktop in every posture and is itself valid" do
      default = Layout.default()
      assert Enum.sort(Map.keys(default.postures)) == Layout.postures()
      assert Layout.tinctures(default) == ["tincture:local.desktop"]
      assert {:ok, ^default} = Layout.validate(Layout.to_json(default))
    end

    test "a reference is spelt canonically" do
      document = %{
        "version" => 1,
        "postures" => %{"hand" => %{"desktop" => "t:local.desktop"}}
      }

      assert {:error, {:invalid_layout, sentence}} = Layout.validate(document)
      assert sentence =~ "tincture:local.desktop"
    end

    test "what is not an object, or not JSON, is refused" do
      assert {:error, {:invalid_layout, _}} = Layout.validate([])
      assert {:error, {:invalid_layout, _}} = Layout.validate(nil)
      assert {:error, {:invalid_layout, _}} = Layout.decode("{")
    end
  end
end
