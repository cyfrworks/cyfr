# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Canvas.ShapeTest do
  @moduledoc """
  The shape grammar against `tests/fixtures/canvas_shape.json`: every valid
  shape normalizes as the fixture says and passes its own fixture, as do
  the `results` blocks' shapes and the result shapes of
  `tests/fixtures/feed.json`'s bindings; spellings that differ only in
  `required`'s order share one digest; every refused shape and value is
  refused at the fixture's path for its reason; and the reasons, types and
  depth limit are the module's. Beside them,
  the bounds the fixture would spell at length: a full enum and object, a
  list at its max and the depth limit built programmatically, and the
  terms JSON cannot spell (an improper list, a key that is not a string, a
  struct), which are refused, or raise, without the value they carry.
  """

  use ExUnit.Case, async: true

  alias Prima.Canvas.Shape

  @vectors Path.expand("../../../../../tests/fixtures/canvas_shape.json", __DIR__)

  @feed_vectors Path.expand("../../../../../tests/fixtures/feed.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp feed_vectors, do: @feed_vectors |> File.read!() |> Jason.decode!()

  # A value no refusal may carry.
  @canary "c4n4ry-shape-3b9a"

  defp normalized!(shape) do
    {:ok, normalized} = Shape.validate(shape)
    normalized
  end

  # The report of the ArgumentError `fun` raises, its stacktrace included;
  # any other exception, or none, fails the test.
  defp raised(fun) do
    fun.()
    flunk("expected an ArgumentError")
  rescue
    e in ArgumentError -> Exception.format(:error, e, __STACKTRACE__)
  end

  # Whether `text` carries the canary, as its bytes or as the byte list
  # `inspect/1` prints for a binary that is not UTF-8 text.
  defp carries_canary?(text) do
    String.contains?(text, [@canary, @canary |> :binary.bin_to_list() |> Enum.join(", ")])
  end

  # A refusal is text, its path and its reason, and carries no canary. The
  # path is read itself, not through `inspect/1`, which would print a
  # binary that is not UTF-8 text as a byte list.
  defp value_free!({:error, %{path: path, reason: reason}} = refusal) do
    assert String.valid?(path) and String.valid?(reason), inspect(refusal)
    refute carries_canary?(path), inspect(refusal)
  end

  describe "the fixture" do
    test "the types, depth limit and reasons are the module's" do
      v = vectors()
      assert v["types"] == Shape.types()
      assert v["max_depth"] == Shape.max_depth()
      assert v["reasons"] == Shape.reasons()
    end

    test "every valid shape normalizes as the fixture says, and normalizing is idempotent" do
      valid = vectors()["shapes"]["valid"]
      types = valid |> Enum.map(& &1["normalized"]["type"]) |> Enum.uniq() |> Enum.sort()
      assert types == Enum.sort(Shape.types())

      for %{"why" => why, "shape" => shape, "normalized" => normalized} <- valid do
        assert Shape.validate(shape) == {:ok, normalized}, why
        assert Shape.validate(normalized) == {:ok, normalized}, why
        assert Shape.encode(normalized) == Shape.encode(normalized!(shape)), why
      end
    end

    test "every valid shape's fixture is the fixture's, never null, and passes the shape" do
      for %{"why" => why, "normalized" => shape, "fixture" => fixture} <-
            vectors()["shapes"]["valid"] do
        assert Shape.fixture(shape) == fixture, why
        refute is_nil(Shape.fixture(shape)), why
        assert Shape.check(shape, Shape.fixture(shape)) == :ok, why
      end

      for %{"shape" => shape} <- vectors()["values"] do
        normalized = normalized!(shape)
        assert Shape.check(normalized, Shape.fixture(normalized)) == :ok
      end

      results =
        for %{"normalized" => block} <- vectors()["results"]["valid"],
            {operation, shape} <- block,
            do: {"results #{operation}", shape}

      bindings =
        for %{"json" => binding} <- feed_vectors()["bindings"]["valid"],
            do: {"binding #{binding["name"]}", binding["result_shape"]}

      assert results != [] and bindings != []

      for {where, shape} <- results ++ bindings do
        assert Shape.validate(shape) == {:ok, shape}, where
        refute is_nil(Shape.fixture(shape)), where
        assert Shape.check(shape, Shape.fixture(shape)) == :ok, where
      end
    end

    test "spellings that differ only in required's order normalize, encode and digest alike" do
      spellings = vectors()["spellings"]
      assert spellings != []

      for %{"why" => why, "shapes" => shapes, "normalized" => normalized, "digest" => digest} <-
            spellings do
        assert length(shapes) >= 2, why
        assert normalized["required"] == Enum.sort(normalized["required"]), why

        for shape <- shapes do
          assert Shape.validate(shape) == {:ok, normalized}, why
          assert Shape.encode(normalized!(shape)) == Shape.encode(normalized), why
          assert Shape.digest(normalized!(shape)) == digest, why
        end
      end
    end

    test "every refused shape is refused at its path for its reason" do
      invalid = vectors()["shapes"]["invalid"]
      reasons = Map.keys(Shape.reasons())

      for %{"why" => why, "shape" => shape, "path" => path, "reason" => reason} <- invalid do
        assert reason in reasons, why
        assert Shape.validate(shape) == {:error, %{path: path, reason: reason}}, why
      end
    end

    test "the canonical bytes and digest are the normalized shape's JCS" do
      %{"shape" => shape, "bytes" => bytes, "digest" => digest} = vectors()["canonical"]

      assert Shape.encode(shape) == bytes
      assert Shape.digest(shape) == digest
      assert digest == Prima.JCS.hash_binary(bytes)
    end

    test "two spellings of one shape hash alike" do
      terse = %{"type" => "list", "of" => %{"type" => "string"}}

      spelt =
        %{
          "max" => 100,
          "nullable" => false,
          "of" => %{"type" => "string", "max" => 256, "nullable" => false},
          "type" => "list"
        }

      assert Shape.digest(normalized!(terse)) == Shape.digest(normalized!(spelt))
      refute Shape.digest(normalized!(terse)) == Shape.digest(normalized!(%{spelt | "max" => 99}))
    end

    test "every value is passed or refused at its path for its reason, the first failing path" do
      reasons = Map.keys(Shape.reasons())

      for %{"shape" => shape, "valid" => valid, "invalid" => invalid} <- vectors()["values"] do
        normalized = normalized!(shape)

        for value <- valid, do: assert(Shape.check(normalized, value) == :ok, inspect(value))

        for %{"why" => why, "value" => value, "path" => path, "reason" => reason} <- invalid do
          assert reason in reasons, why
          assert Shape.check(normalized, value) == {:error, %{path: path, reason: reason}}, why
        end
      end
    end
  end

  describe "the bounds" do
    test "an enum takes 64 values and no more" do
      values = Enum.map(1..65, &"v#{&1}")

      assert {:ok, _} = Shape.validate(%{"type" => "enum", "values" => Enum.take(values, 64)})

      assert Shape.validate(%{"type" => "enum", "values" => values}) ==
               {:error, %{path: "/values", reason: "range"}}

      long = String.duplicate("é", 256)
      assert {:ok, _} = Shape.validate(%{"type" => "enum", "values" => [long]})

      assert Shape.validate(%{"type" => "enum", "values" => [long <> "é"]}) ==
               {:error, %{path: "/values/0", reason: "range"}}
    end

    test "an object takes 64 fields and no more" do
      fields = Map.new(1..65, &{"f#{&1}", %{"type" => "boolean"}})
      sixty_four = Map.new(Enum.take(Enum.sort(fields), 64))

      assert {:ok, _} = Shape.validate(%{"type" => "object", "fields" => sixty_four})

      assert Shape.validate(%{"type" => "object", "fields" => fields}) ==
               {:error, %{path: "/fields", reason: "range"}}
    end

    test "a field's name is 1 to 64 code points with no control character" do
      for name <- [String.duplicate("é", 64), "a b", "prix €", "a/b"] do
        assert Shape.name?(name), name
      end

      for name <- ["", String.duplicate("é", 65), "a\u0000", "a\u007F", "a\u0085", 7, nil] do
        refute Shape.name?(name), inspect(name)
      end
    end

    test "a list holds at most its max, and a string at most its max in code points" do
      list = normalized!(%{"type" => "list", "of" => %{"type" => "integer"}, "max" => 1000})
      assert Shape.check(list, List.duplicate(1, 1000)) == :ok
      assert Shape.check(list, List.duplicate(1, 1001)) == {:error, %{path: "", reason: "max"}}

      default = normalized!(%{"type" => "list", "of" => %{"type" => "integer"}})
      assert Shape.check(default, List.duplicate(1, 100)) == :ok
      assert Shape.check(default, List.duplicate(1, 101)) == {:error, %{path: "", reason: "max"}}

      string = normalized!(%{"type" => "string"})
      assert Shape.check(string, String.duplicate("€", 256)) == :ok

      assert Shape.check(string, String.duplicate("€", 257)) ==
               {:error, %{path: "", reason: "max"}}
    end

    test "a shape is at most 8 deep, counting each of and each field" do
      nest = fn depth, wrap ->
        Enum.reduce(2..depth//1, %{"type" => "json"}, fn _, inner -> wrap.(inner) end)
      end

      list = fn inner -> %{"type" => "list", "of" => inner} end
      object = fn inner -> %{"type" => "object", "fields" => %{"x" => inner}} end

      assert {:ok, _} = Shape.validate(nest.(8, list))
      assert {:ok, _} = Shape.validate(nest.(8, object))

      assert Shape.validate(nest.(9, list)) ==
               {:error, %{path: String.duplicate("/of", 8), reason: "depth"}}

      assert Shape.validate(nest.(9, object)) ==
               {:error, %{path: String.duplicate("/fields/x", 8), reason: "depth"}}
    end

    test "a value's path escapes ~ and / in a field's name" do
      shape = normalized!(%{"type" => "object", "fields" => %{"~/" => %{"type" => "integer"}}})
      assert Shape.check(shape, %{"~/" => "x"}) == {:error, %{path: "/~0~1", reason: "type"}}
      assert Shape.escape("a~1/b") == "a~01~1b"
      assert Shape.escape(3) == "3"
    end

    test "a time carries its offset" do
      time = normalized!(%{"type" => "time"})

      for at <- [
            "2026-10-04T12:00:00Z",
            "2026-10-04T12:00:00.5-03:30",
            "2026-10-04 12:00:00+00:00"
          ] do
        assert Shape.check(time, at) == :ok, at
      end

      for at <- ["2026-10-04T12:00:00", "2026-10-04", "noon"] do
        assert Shape.check(time, at) == {:error, %{path: "", reason: "time"}}, at
      end
    end

    test "json admits any JSON value, and only JSON" do
      json = normalized!(%{"type" => "json"})

      for value <- [1, 2.5, "x", true, [nil], %{"a" => %{"b" => [1, nil]}}],
          do: assert(Shape.check(json, value) == :ok)

      for value <- [:atom, %{a: 1}, {1, 2}, <<0xFF>>],
          do: assert(Shape.check(json, value) == {:error, %{path: "", reason: "type"}})
    end
  end

  describe "refusals name no value they were handed" do
    test "an improper list in a shape is refused at the list, whichever end carries the value" do
      for values <- [[@canary | :bad_tail], ["a" | @canary], ["a", "b" | {@canary}]] do
        refusal = Shape.validate(%{"type" => "enum", "values" => values})
        assert refusal == {:error, %{path: "/values", reason: "type"}}
        value_free!(refusal)

        object = %{"type" => "object", "fields" => %{"a" => %{"type" => "json"}}}
        refusal = Shape.validate(Map.put(object, "required", values))
        assert refusal == {:error, %{path: "/required", reason: "type"}}
        value_free!(refusal)
      end
    end

    test "an improper list in a checked value is refused as another type" do
      list = normalized!(%{"type" => "list", "of" => %{"type" => "string"}})
      json = normalized!(%{"type" => "json"})

      object =
        normalized!(%{"type" => "object", "fields" => %{"xs" => %{"type" => "json"}}})

      for value <- [[@canary | :bad_tail], ["a" | @canary], ["a", "b" | {@canary}]] do
        for {shape, checked, path} <- [
              {list, value, ""},
              {json, value, ""},
              {json, %{"a" => value}, ""},
              {object, %{"xs" => value}, "/xs"}
            ] do
          refusal = Shape.check(shape, checked)
          assert refusal == {:error, %{path: path, reason: "type"}}
          value_free!(refusal)
        end

        refute Shape.json?(value)
      end
    end

    test "a key that is not a string is refused at its object, never named" do
      # A binary that is not UTF-8 text is no string either: no pointer
      # spells it.
      keys = [
        {:key, @canary},
        [@canary],
        %{@canary => 1},
        String.to_atom(@canary),
        7,
        <<0xFF>> <> @canary,
        @canary <> <<0xC3>>
      ]

      object = normalized!(%{"type" => "object", "fields" => %{"a" => %{"type" => "json"}}})
      json = normalized!(%{"type" => "json"})

      for key <- keys do
        cases = [
          {Shape.validate(%{"type" => "json", key => 1}), %{path: "", reason: "unknown_key"}},
          {Shape.validate(%{"type" => "list", "of" => %{"type" => "json", key => @canary}}),
           %{path: "/of", reason: "unknown_key"}},
          {Shape.validate(%{"type" => "object", "fields" => %{key => %{"type" => "json"}}}),
           %{path: "/fields", reason: "name"}},
          {Shape.check(object, %{key => @canary}), %{path: "", reason: "unknown_field"}},
          {Shape.check(object, %{"a" => 1, key => @canary}),
           %{path: "", reason: "unknown_field"}},
          {Shape.check(json, %{"a" => %{key => @canary}}), %{path: "", reason: "type"}}
        ]

        for {refusal, expected} <- cases do
          assert refusal == {:error, expected}, inspect(key)
          value_free!(refusal)
        end
      end
    end

    test "a struct is refused as another type" do
      struct = %URI{path: @canary}
      object = normalized!(%{"type" => "object", "fields" => %{}})

      for refusal <- [
            Shape.validate(struct),
            Shape.validate(%{"type" => "list", "of" => struct}),
            Shape.validate(%{"type" => "object", "fields" => struct}),
            Shape.check(object, struct),
            Shape.check(normalized!(%{"type" => "json"}), [struct])
          ] do
        assert {:error, %{reason: "type"}} = refusal
        value_free!(refusal)
      end
    end

    test "a shape that is not a validated one raises without the value it carries" do
      # Each shape with a value that reaches the part of it that is not a
      # shape's.
      shapes = [
        {@canary, [@canary]},
        {{@canary}, [@canary]},
        {%{"type" => @canary}, [@canary]},
        {%{"type" => "list", "of" => @canary, "max" => 1}, [@canary]},
        {%{"type" => "object", "fields" => @canary, "required" => []}, %{"a" => [@canary]}},
        {%{"type" => "object", "fields" => %{"a" => @canary}, "required" => []},
         %{"a" => [@canary]}},
        {%{"type" => "enum", "values" => @canary}, @canary}
      ]

      for {shape, value} <- shapes do
        refute carries_canary?(raised(fn -> Shape.check(shape, value) end))
        refute carries_canary?(raised(fn -> Shape.fixture(shape) end))
      end

      for shape <- [{@canary}, [@canary], %{"k" => [1 | @canary]}, %{{:k, @canary} => 1}] do
        refute carries_canary?(raised(fn -> Shape.encode(shape) end))
        refute carries_canary?(raised(fn -> Shape.digest(shape) end))
      end

      refute carries_canary?(raised(fn -> Shape.escape({@canary}) end))
    end
  end
end
