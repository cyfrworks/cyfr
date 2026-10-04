# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.ResultsTest do
  @moduledoc """
  A manifest's `results` block against the `results` rows of
  `tests/fixtures/canvas_shape.json`: every valid block answers its shapes
  normalized, and every refused block is refused in the form
  `Prima.Manifest`'s other block checks answer. Beside them, the bound on
  how many operations a block names.
  """

  use ExUnit.Case, async: true

  alias Prima.Manifest.Results

  @vectors Path.expand("../../../../../tests/fixtures/canvas_shape.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!() |> Map.fetch!("results")

  test "every valid block answers each operation's shape normalized" do
    for %{"why" => why, "block" => block, "normalized" => normalized} <- vectors()["valid"] do
      assert Results.validate(block) == {:ok, normalized}, why
    end
  end

  test "every refused block is refused with a sentence, as the manifest's block checks are" do
    for %{"why" => why, "block" => block} <- vectors()["invalid"] do
      assert {:error, {:invalid_results, sentence}} = Results.validate(block), why
      assert is_binary(sentence) and sentence != "", why
    end
  end

  test "an operation name is 1 to 64 code points with no control character" do
    shape = %{"type" => "json"}

    assert {:ok, _} = Results.validate(%{String.duplicate("é", 64) => shape})

    assert {:error, {:invalid_results, _}} =
             Results.validate(%{String.duplicate("é", 65) => shape})

    assert {:error, {:invalid_results, _}} = Results.validate(%{"tab\there" => shape})
    assert Results.operation?("quote")
    refute Results.operation?("")
  end

  test "a block names at most 64 operations" do
    block = Map.new(1..65, &{"op#{&1}", %{"type" => "boolean"}})
    sixty_four = block |> Enum.sort() |> Enum.take(64) |> Map.new()

    assert {:ok, normalized} = Results.validate(sixty_four)
    assert map_size(normalized) == Results.max_operations()
    assert {:error, {:invalid_results, _}} = Results.validate(block)
  end

  test "a refused shape names its operation, path and reason" do
    block = %{"quote" => %{"type" => "list", "of" => %{"type" => "string"}, "max" => 1001}}

    assert {:error, {:invalid_results, sentence}} = Results.validate(block)
    assert sentence =~ "quote"
    assert sentence =~ "/max"
    assert sentence =~ "range"
  end

  test "a term JSON cannot spell is refused without the value it carries" do
    canary = "c4n4ry-results-58e2"
    struct = %URI{path: canary}

    blocks = [
      %{{:quote, canary} => %{"type" => "json"}},
      %{[canary] => %{"type" => "json"}},
      %{String.to_atom(canary) => %{"type" => "json"}},
      %{"quote" => %{"type" => "json", {:key, canary} => 1}},
      %{"quote" => %{"type" => "object", "fields" => %{{:key, canary} => %{"type" => "json"}}}},
      %{"quote" => %{"type" => "enum", "values" => [canary | :bad_tail]}},
      %{"quote" => %{"type" => "enum", "values" => ["a" | canary]}},
      %{"quote" => %{"type" => "object", "fields" => %{}, "required" => [canary | :bad_tail]}},
      %{"quote" => struct},
      struct,
      [{"quote", canary}]
    ]

    for block <- blocks do
      assert {:error, {:invalid_results, sentence}} = Results.validate(block), inspect(block)
      assert String.valid?(sentence)
      refute String.contains?(sentence, canary)
    end
  end

  test "a binary key that is not UTF-8 text is never named, and the sentence is text" do
    canary = "c4n4ry-results-58e2"

    for key <- [<<0xFF>> <> canary, canary <> <<0xC3>>] do
      cases = [
        {%{key => %{"type" => "json"}},
         "results keys are operation names of 1 to 64 characters with no control character"},
        {%{"q" => %{"type" => "json", key => 1}},
         ~s{results.q: the shape is refused at "" (unknown_key)}},
        {%{"q" => %{"type" => "list", "of" => %{"type" => "json", key => 1}}},
         ~s{results.q: the shape is refused at "/of" (unknown_key)}},
        {%{"q" => %{"type" => "object", "fields" => %{key => %{"type" => "json"}}}},
         ~s{results.q: the shape is refused at "/fields" (name)}}
      ]

      for {block, expected} <- cases do
        refusal = Results.validate(block)
        assert refusal == {:error, {:invalid_results, expected}}, inspect(key)
        {:error, {:invalid_results, sentence}} = refusal
        assert String.valid?(sentence)
        refute String.contains?(sentence, canary)
      end
    end
  end
end
