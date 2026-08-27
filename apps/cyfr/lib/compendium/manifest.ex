# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Manifest do
  @moduledoc """
  Shared manifest decoding utilities.

  Normalizes manifest values from various storage representations
  (nil, JSON string, map) into a consistent map format.
  """

  require Logger

  @doc """
  Decode a manifest value into a map.

  Handles nil (returns empty map), maps (passthrough), and JSON strings.
  Returns an empty map on decode failure — a malformed manifest degrades to
  "no declarations", so the failure is logged to avoid a silent capability gap.
  """
  @spec decode(nil | map() | binary()) :: map()
  def decode(nil), do: %{}
  def decode(manifest) when is_map(manifest), do: manifest

  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        map

      other ->
        Logger.warning(
          "[Compendium.Manifest] manifest decode failed (#{inspect(elem_or_self(other))}); " <>
            "treating as empty — declared capabilities will be missing"
        )

        %{}
    end
  end

  def decode(_), do: %{}

  @doc """
  Strict counterpart of `decode/1` for write boundaries.

  Registration must never accept a manifest it cannot parse — a malformed
  manifest would otherwise register a component with zero declared
  capabilities and skip all manifest validation. Reads of historical rows
  keep using the lenient `decode/1`.
  """
  @spec decode_strict(nil | map() | binary()) :: {:ok, map()} | {:error, :malformed_manifest}
  def decode_strict(nil), do: {:ok, %{}}
  def decode_strict(manifest) when is_map(manifest), do: {:ok, manifest}

  def decode_strict(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :malformed_manifest}
    end
  end

  def decode_strict(_), do: {:error, :malformed_manifest}

  @doc """
  The suggested vocabulary for the manifest's `category` field — the one
  roster the MCP categories action serves. The field itself is free
  text (search filters on whatever a manifest declared); this names the
  recommended values without enforcing them.
  """
  @spec known_categories() :: [%{name: String.t(), description: String.t()}]
  def known_categories do
    [
      %{name: "api-integrations", description: "External API connectors"},
      %{name: "data-processing", description: "Data transformation and analysis"},
      %{name: "ai-ml", description: "Machine learning and AI tools"},
      %{name: "security", description: "Security and cryptography"},
      %{name: "utilities", description: "General-purpose utilities"}
    ]
  end

  defp elem_or_self({:error, reason}), do: reason
  defp elem_or_self(other), do: other
end
