# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Manifest do
  @moduledoc """
  Shared manifest decoding utilities.

  Normalizes manifest values from various storage representations
  (nil, JSON string, map) into a consistent map format.
  """

  @doc """
  Decode a manifest value into a map.

  Handles nil (returns empty map), maps (passthrough), and JSON strings.
  Returns an empty map on decode failure.
  """
  @spec decode(nil | map() | binary()) :: map()
  def decode(nil), do: %{}
  def decode(manifest) when is_map(manifest), do: manifest

  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  def decode(_), do: %{}
end