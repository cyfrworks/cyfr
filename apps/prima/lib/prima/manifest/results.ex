# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.Results do
  @moduledoc """
  A component manifest's `results` block: the shape (`Prima.Canvas.Shape`)
  of what each of its operations answers, by operation name.

      "results": {"quote": {"type": "object", "fields": {"price": {"type": "number"}}}}

  The block is presentational to the release digest: it decides nothing a
  consent covers, and a feed binding copies the shape of its operation
  when it is bound.
  """

  alias Prima.Canvas.Shape

  @max_operations 64

  @typedoc "Operation name to normalized shape."
  @type t :: %{String.t() => Shape.t()}

  @doc "The most operations a block may name."
  @spec max_operations() :: pos_integer()
  def max_operations, do: @max_operations

  @doc """
  Whether `name` is an operation name a block may key: 1 to 64 code points
  with no control character, the rule `Prima.Canvas.Shape.name?/1` holds.
  """
  @spec operation?(term()) :: boolean()
  def operation?(name), do: Shape.name?(name)

  @doc """
  A decoded `results` block: an object of 0 to #{@max_operations}
  operation names, each mapped to a shape. Answers each shape normalized,
  or the first refusal in the form `Prima.Manifest`'s other block checks
  answer, `{:invalid_results, sentence}`; operations are read in sorted
  order.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, {:invalid_results, String.t()}}
  def validate(block) when is_map(block) and not is_struct(block) do
    if map_size(block) > @max_operations do
      refuse("results names at most #{@max_operations} operations")
    else
      block
      |> Enum.sort()
      |> Enum.reduce_while({:ok, %{}}, fn {name, shape}, {:ok, acc} ->
        case operation(name, shape) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, name, normalized)}}
          refusal -> {:halt, refusal}
        end
      end)
    end
  end

  def validate(_block), do: refuse("results must be an object of operation names to shapes")

  defp operation(name, shape) do
    if operation?(name) do
      case Shape.validate(shape) do
        {:ok, normalized} ->
          {:ok, normalized}

        {:error, %{path: path, reason: reason}} ->
          refuse("results.#{name}: the shape is refused at \"#{path}\" (#{reason})")
      end
    else
      refuse("results keys are operation names of 1 to 64 characters with no control character")
    end
  end

  defp refuse(sentence), do: {:error, {:invalid_results, sentence}}
end
