# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CanvasPrefsTest do
  @moduledoc """
  The preferences document against a schema the manifest reads: what a
  desktop sends validates as it was sent, and each refusal names its path
  and never a long value; a document projects to what a schema declares
  now; a merge replaces each named widget entry whole, keeps the rest and
  replaces the desktop section only when named; the codec reads only what
  it writes, and the cap bounds documents the schema admits.
  """

  use ExUnit.Case, async: true

  alias Prima.CanvasPrefs
  alias Prima.Manifest.Tincture

  @max Prima.JCS.max_safe_integer()

  @prefs %{
    "widgets" => %{
      "weather" => %{
        "fields" => %{
          "units" => %{"type" => "enum", "values" => ["c", "f"]},
          "city" => %{"type" => "string", "max" => 8}
        }
      },
      "clock" => %{
        "fields" => %{
          "seconds" => %{"type" => "boolean"},
          "offset" => %{"type" => "integer"},
          "scale" => %{"type" => "integer"}
        }
      },
      "notes" => %{}
    },
    "desktop" => %{
      "fields" => %{"compact" => %{"type" => "boolean"}, "title" => %{"type" => "string"}}
    }
  }

  @rect %{"x" => 0, "y" => 250, "w" => 10_000, "h" => 1}

  defp schema(prefs \\ @prefs) do
    {:ok, declaration} =
      Tincture.from_manifest(%{"tincture" => %{"desktop" => %{"prefs" => prefs}}})

    declaration.desktop.prefs
  end

  defp refusal(incoming) do
    assert {:error, sentence} = CanvasPrefs.validate(incoming, schema())
    assert is_binary(sentence)
    sentence
  end

  defp widget(id, entry), do: %{"widgets" => %{id => entry}}

  describe "validate/2" do
    test "what a desktop sends validates as it was sent, every field optional" do
      full = %{
        "widgets" => %{
          "weather" => %{"on" => true, "rect" => @rect, "units" => "f", "city" => "Oslo"},
          "clock" => %{"on" => false, "seconds" => true, "offset" => -@max, "scale" => @max},
          "notes" => %{"rect" => @rect}
        },
        "desktop" => %{"compact" => true, "title" => ""}
      }

      for incoming <- [
            full,
            Map.delete(full, "desktop"),
            Map.delete(full, "widgets"),
            %{"widgets" => %{}},
            %{"desktop" => %{}},
            widget("weather", %{}),
            # Text is bounded by code points, never graphemes or bytes: eight
            # two-byte letters fit a max of 8.
            widget("weather", %{"city" => "éééééééé"})
          ] do
        assert {:ok, ^incoming} = CanvasPrefs.validate(incoming, schema()), inspect(incoming)
      end
    end

    test "the top level names widgets, desktop or both and nothing else" do
      assert refusal(%{}) =~ "name widgets, desktop or both"
      assert refusal(%{"widgets" => %{}, "layout" => 1}) =~ ~s[unknown key(s): "layout"]
      assert refusal([]) =~ "must be an object"
      assert refusal("prefs") =~ "must be an object"
      assert refusal(%{"widgets" => []}) == "widgets must be an object"
      assert refusal(%{"desktop" => "compact"}) == "desktop must be an object"
    end

    test "a widget or a field the schema does not declare is refused by its path" do
      assert refusal(widget("radar", %{})) ==
               ~s(widgets: "radar" is no widget this desktop declares)

      assert refusal(widget("weather", %{"colour" => "red"})) ==
               ~s(widgets.weather: "colour" is no field it declares)

      # A field one widget declares is not another's.
      assert refusal(widget("notes", %{"units" => "c"})) ==
               ~s(widgets.notes: "units" is no field it declares)

      assert refusal(widget("weather", "on")) == "widgets.weather must be an object"

      assert refusal(%{"desktop" => %{"dense" => true}}) ==
               ~s(desktop: "dense" is no field it declares)

      # on and rect are a widget's, not the desktop's.
      assert refusal(%{"desktop" => %{"on" => true}}) == ~s(desktop: "on" is no field it declares)
    end

    test "each value outside its type is refused naming its path" do
      cases = [
        {widget("clock", %{"on" => "yes"}), "widgets.clock.on must be true or false"},
        {widget("clock", %{"seconds" => 1}), "widgets.clock.seconds must be true or false"},
        {widget("clock", %{"offset" => 1.5}), "widgets.clock.offset must be a whole number"},
        {widget("clock", %{"offset" => @max + 1}), "widgets.clock.offset must be a whole number"},
        {widget("clock", %{"offset" => -@max - 1}),
         "widgets.clock.offset must be a whole number"},
        {widget("clock", %{"offset" => "3"}), "widgets.clock.offset must be a whole number"},
        {widget("weather", %{"city" => "Amsterdam"}),
         "widgets.weather.city must be text of at most 8 code points"},
        # Five graphemes, ten code points.
        {widget("weather", %{"city" => String.duplicate("é", 5)}),
         "widgets.weather.city must be text of at most 8 code points"},
        {widget("weather", %{"city" => "Os\nlo"}), "got text with a control character"},
        {widget("weather", %{"city" => "Os\u0085lo"}), "with no control character"},
        {widget("weather", %{"city" => <<0xFF>>}), "got bytes that are not UTF-8 text"},
        {widget("weather", %{"city" => 7}), "widgets.weather.city must be text"},
        {widget("weather", %{"units" => "k"}),
         ~s(widgets.weather.units must be one of its declared values, got "k")},
        {widget("weather", %{"units" => 1}), "widgets.weather.units must be one of"},
        {%{"desktop" => %{"compact" => nil}}, "desktop.compact must be true or false"},
        {%{"desktop" => %{"title" => String.duplicate("t", 257)}},
         "desktop.title must be text of at most 256 code points"}
      ]

      for {incoming, expected} <- cases do
        assert refusal(incoming) =~ expected, inspect(incoming)
      end
    end

    test "rect is exactly x, y, w and h within a layout window's bounds" do
      for rect <- [
            Map.delete(@rect, "h"),
            Map.put(@rect, "z", 0),
            %{@rect | "x" => -1},
            %{@rect | "w" => 0},
            %{@rect | "h" => 10_001},
            %{@rect | "y" => 2.5},
            %{@rect | "x" => "0"},
            [0, 0, 1, 1]
          ] do
        assert refusal(widget("notes", %{"rect" => rect})) =~
                 "widgets.notes.rect must be a window's geometry",
               inspect(rect)

        refute Prima.Layout.geometry?(rect)
      end

      assert Prima.Layout.geometry?(@rect)
    end

    test "the first refusal in sorted order is the answer, and a long value is never echoed" do
      both = %{"widgets" => %{"weather" => %{"units" => "k"}, "clock" => %{"on" => 1}}}
      assert refusal(both) =~ "widgets.clock.on"

      long = String.duplicate("a", 300)
      sentence = refusal(widget("weather", %{"city" => long}))
      refute sentence =~ long
      assert sentence =~ "a string of 300 characters"

      sentence = refusal(widget(String.duplicate("w", 200), %{}))
      assert sentence =~ "a string of 200 characters"
      refute sentence =~ String.duplicate("w", 65)
    end
  end

  describe "project/2" do
    test "a document keeps only what the schema declares now and still admits" do
      stored = %{
        "widgets" => %{
          "weather" => %{"on" => true, "rect" => @rect, "units" => "f", "city" => "Oslo"},
          "clock" => %{"offset" => 3, "gone" => true},
          "radar" => %{"on" => true}
        },
        "desktop" => %{"compact" => true, "dense" => true}
      }

      assert CanvasPrefs.project(stored, schema()) == %{
               "widgets" => %{
                 "weather" => %{"on" => true, "rect" => @rect, "units" => "f", "city" => "Oslo"},
                 "clock" => %{"offset" => 3}
               },
               "desktop" => %{"compact" => true}
             }

      # A later version narrows units and city and turns offset into text:
      # the values it no longer admits leave, the fixed fields stay.
      narrowed =
        @prefs
        |> put_in(["widgets", "weather", "fields", "units", "values"], ["c"])
        |> put_in(["widgets", "weather", "fields", "city", "max"], 2)
        |> put_in(["widgets", "clock", "fields", "offset"], %{"type" => "string"})
        |> put_in(["desktop"], %{})

      assert CanvasPrefs.project(stored, schema(narrowed)) == %{
               "widgets" => %{"weather" => %{"on" => true, "rect" => @rect}, "clock" => %{}},
               "desktop" => %{}
             }

      assert CanvasPrefs.project(stored, schema(%{})) == CanvasPrefs.empty()
    end

    test "a document the schema admits whole projects to itself" do
      document = %{
        "widgets" => %{"notes" => %{"on" => false}, "clock" => %{"scale" => -2}},
        "desktop" => %{"title" => "Desk"}
      }

      assert CanvasPrefs.project(document, schema()) == document
    end
  end

  describe "merge/2" do
    @stored %{
      "widgets" => %{
        "weather" => %{"on" => true, "units" => "c"},
        "clock" => %{"on" => true, "seconds" => true}
      },
      "desktop" => %{"compact" => true}
    }

    test "each widget entry incoming names replaces the stored one whole, and the rest stay" do
      assert CanvasPrefs.merge(@stored, widget("weather", %{"units" => "f"})) == %{
               "widgets" => %{
                 "weather" => %{"units" => "f"},
                 "clock" => %{"on" => true, "seconds" => true}
               },
               "desktop" => %{"compact" => true}
             }

      assert CanvasPrefs.merge(@stored, widget("notes", %{"on" => false}))["widgets"] ==
               Map.put(@stored["widgets"], "notes", %{"on" => false})
    end

    test "the desktop section is replaced whole when named and kept when not" do
      assert CanvasPrefs.merge(@stored, %{"desktop" => %{}}) == %{@stored | "desktop" => %{}}
      assert CanvasPrefs.merge(@stored, %{"widgets" => %{}}) == @stored

      assert CanvasPrefs.merge(CanvasPrefs.empty(), %{"desktop" => %{"title" => "Desk"}}) ==
               %{"widgets" => %{}, "desktop" => %{"title" => "Desk"}}
    end
  end

  describe "the codec" do
    test "a document encodes canonically, decodes to itself and hashes its bytes" do
      assert CanvasPrefs.encode(CanvasPrefs.empty()) == ~s({"desktop":{},"widgets":{}})

      document = %{
        "widgets" => %{
          "weather" => %{"on" => true, "rect" => @rect, "units" => "f", "city" => "Zürich"},
          "clock" => %{"offset" => -@max}
        },
        "desktop" => %{"compact" => false}
      }

      bytes = CanvasPrefs.encode(document)
      assert {:ok, ^document} = CanvasPrefs.decode(bytes)
      assert CanvasPrefs.digest(document) == Prima.Digest.sha256(bytes)
      assert {:ok, empty} = CanvasPrefs.decode(CanvasPrefs.encode(CanvasPrefs.empty()))
      assert empty == CanvasPrefs.empty()
    end

    test "decode reads only what encode writes" do
      for bytes <- [
            ~s({"desktop": {},"widgets":{}}),
            ~s({"widgets":{},"desktop":{}}),
            ~s({"widgets":{}}),
            ~s({"desktop":{},"layout":{},"widgets":{}}),
            ~s({"desktop":{},"widgets":[]}),
            ~s({"desktop":{},"widgets":{"w":{"on":1}}}),
            ~s({"desktop":{},"widgets":{"w":{"rect":{"h":1,"w":0,"x":0,"y":0}}}}),
            ~s({"desktop":{"n":1.5},"widgets":{}}),
            ~s({"desktop":{"n":9007199254740992},"widgets":{}}),
            ~s({"desktop":{"n":null},"widgets":{}}),
            ~s({"desktop":{"n":{"deep":true}},"widgets":{}}),
            ~s({"desktop":{"n":[1]},"widgets":{}}),
            ~s({"desktop":{"n":1,"n":2},"widgets":{}}),
            ~s([]),
            "not json",
            7
          ] do
        assert {:error, :invalid_document} = CanvasPrefs.decode(bytes), inspect(bytes)
      end
    end

    test "encode takes a document and nothing else" do
      for bad <- [
            %{"widgets" => %{}},
            %{"widgets" => %{"w" => %{"on" => "yes"}}, "desktop" => %{}}
          ] do
        assert_raise ArgumentError, fn -> CanvasPrefs.encode(bad) end
      end
    end

    test "the cap bounds documents the schema admits" do
      assert CanvasPrefs.max_bytes() == 16_384

      # Every widget the manifest allows, each with every field it allows
      # at its longest: the schema alone does not bound the document.
      fields = Map.new(1..16, &{"f#{&1}", %{"type" => "string", "max" => 256}})
      widgets = Map.new(1..32, &{"w#{&1}", %{"fields" => fields}})
      wide = schema(%{"widgets" => widgets})

      values = Map.new(1..16, &{"f#{&1}", String.duplicate("é", 256)})
      incoming = %{"widgets" => Map.new(1..32, &{"w#{&1}", values})}

      assert {:ok, incoming} = CanvasPrefs.validate(incoming, wide)
      merged = CanvasPrefs.merge(CanvasPrefs.empty(), incoming)
      assert byte_size(CanvasPrefs.encode(merged)) > CanvasPrefs.max_bytes()
    end
  end
end
