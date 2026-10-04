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
end
