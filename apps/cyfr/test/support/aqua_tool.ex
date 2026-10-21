# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.AquaTool do
  @moduledoc """
  The `aqua` tool as a test calls it: through the gate on `ctx`'s
  external plane, its answer deep-stringified, as the AQUA page reads it
  (`PrismWeb.AquaLive.Section.call_aqua/2`).
  """

  @doc "Call the `aqua` tool and answer its result with string keys."
  @spec call(Sanctum.Context.t(), map()) :: {:ok, term()} | {:error, term()}
  def call(ctx, args) do
    case Sanctum.Gate.call_external("aqua", ctx, args) do
      {:ok, result} -> {:ok, stringify(result)}
      other -> other
    end
  end

  defp stringify(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
