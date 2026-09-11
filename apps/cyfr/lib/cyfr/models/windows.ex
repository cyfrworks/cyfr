# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Models.Windows do
  @moduledoc """
  The context window assumed for a model when its catalyst reports none:
  a table by the catalyst's exact name (the bundled providers' current
  defaults), then the configured default. `describe` reports no window
  and `models` reports one only where the provider does, so a planner
  always has a number — from the catalyst when it says, from here when
  it does not.
  """

  @by_catalyst %{
    "claude" => 200_000,
    "openai" => 128_000,
    "gemini" => 1_000_000,
    "grok" => 131_072,
    "openrouter" => 128_000
  }

  @doc "The window the table assumes for a catalyst reference, by exact name, or nil."
  @spec by_catalyst(String.t()) :: pos_integer() | nil
  def by_catalyst(reference) when is_binary(reference) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, %{name: name}} -> Map.get(@by_catalyst, name)
      _ -> nil
    end
  end

  @doc "The window assumed when neither the catalyst nor the table knows."
  @spec default() :: pos_integer()
  def default, do: Application.get_env(:cyfr, :model_context_window_default, 128_000)

  @doc "The table, for the console and the tests."
  @spec table() :: %{String.t() => pos_integer()}
  def table, do: @by_catalyst
end
