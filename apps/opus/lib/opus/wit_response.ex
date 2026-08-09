# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WitResponse do
  @moduledoc """
  Shared WIT-boundary response encoding for catalyst host functions.

  The `cyfr:http`, `cyfr:storage` and `cyfr:formula` host functions return a
  JSON string. Two rules are shared across all of them and were previously
  copied into each handler:

    * an encode failure must still yield valid JSON (never a raised error across
      the WIT boundary), and
    * errors use one envelope — `{"error": {"type", "message"}}`.

  Callers pass an already-stringified `message`, so each keeps its own reason
  coercion (a bare string, `to_string/1`, or a richer `stringify_reason/1`).
  """

  @encode_failure ~s({"error":{"type":"encoding_error","message":"Failed to encode response"}})

  @doc "Encode to JSON, falling back to a valid error envelope on failure."
  @spec safe_encode(term()) :: String.t()
  def safe_encode(data) do
    case Jason.encode(data) do
      {:ok, json} -> json
      {:error, _} -> @encode_failure
    end
  end

  @doc """
  Encode the shared `{"error": {type, message}}` envelope. `message` is
  normalized to a string (never raises), so callers may pass a pre-coerced
  string or a raw term.
  """
  @spec encode_error(atom() | String.t(), term()) :: String.t()
  def encode_error(type, message) do
    safe_encode(%{"error" => %{"type" => to_string(type), "message" => normalize(message)}})
  end

  defp normalize(message) when is_binary(message), do: message
  defp normalize(message) when is_atom(message), do: to_string(message)
  defp normalize(message), do: inspect(message)
end
