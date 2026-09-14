# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Json do
  @moduledoc """
  One spelling for "decode this stored JSON" and "encode or say so".

  Provides JSON encoding and decoding with explicit fallback behavior
  for callers handling stored values and log payloads.

  The failure posture is the caller's visible choice, not an accident of
  which private copy it reached:

    * `decode/1` — `{:ok, term} | {:error, :invalid_json}`. The caller
      decides what a corrupt column means; execution paths fail closed.
    * `decode_or/3` — the lenient form for display/rendering paths: the
      default comes back and the corruption is logged under its owner's
      label, never silently.
    * `safe_encode/1` — encode, or the one `#{inspect(~s({"_encoding_error":"value not encodable"}))}`
      envelope. An unencodable value must neither crash the caller nor
      masquerade as data.

  Guest-facing envelopes keep their own shapes where the wire demands it
  (`Cyfr.WitResponse.safe_encode/1` answers the guest protocol's error
  object); this module is for host-side storage and logs.
  """

  require Logger

  @encode_failure ~s({"_encoding_error":"value not encodable"})

  @doc "Strict decode: the caller owns what a corrupt value means."
  @spec decode(term()) :: {:ok, term()} | {:error, :invalid_json}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def decode(_), do: {:error, :invalid_json}

  @doc """
  Lenient decode for display/rendering paths: `nil`/`""` and corrupt JSON
  answer `default`, corruption logged under `label` — visible, never
  load-bearing.
  """
  @spec decode_or(term(), term(), String.t()) :: term()
  def decode_or(nil, default, _label), do: default
  def decode_or("", default, _label), do: default

  def decode_or(json, default, label) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} ->
        value

      {:error, _} ->
        Logger.warning(
          "[#{label}] stored JSON did not decode " <>
            "(#{String.slice(json, 0, 100)}) — using #{inspect(default)}"
        )

        default
    end
  end

  @doc "Encode, or the one failure envelope — never `inspect/1` output."
  @spec safe_encode(term()) :: String.t()
  def safe_encode(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> @encode_failure
    end
  end

  @doc """
  Encodes a value, returning `:invalid_json` for unencodable input.
  Callers handle this error using the same vocabulary as `decode/1`.
  """
  @spec encode(term()) :: {:ok, String.t()} | {:error, :unencodable}
  def encode(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :unencodable}
    end
  end
end
