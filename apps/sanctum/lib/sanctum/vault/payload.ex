# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.Payload do
  @moduledoc """
  The sealed vault-entry payload document, version 3:

      {"v":3,"fields":{"url":"https://…","anon_key":"…"},
       "oauth":{"access_token":"…","refresh_token":"…",
                "expires_at":"2026-08-07T12:00:00Z"}}

  The `oauth` bundle holds the entry's token beside its refresh token and
  the token's expiry. The scopes the token was granted for are the
  entry's `oauth_scopes` binding column, never the bundle's.

  Decoding is strict: another version, unknown keys, non-string field
  values and malformed oauth blocks are refused, so a tampered or
  mis-written payload fails before any of it is dispensed. A refusal
  names the shape that failed and never a value: a plaintext that does
  not read as JSON is `{:invalid_payload, {:not_json, position}}`, the
  byte offset the parser stopped at and none of the bytes.
  """

  @type t :: map()

  @version 3
  @oauth_keys ~w(access_token refresh_token expires_at)

  @doc "Decode and validate a sealed payload's plaintext."
  @spec decode(binary()) ::
          {:ok, t()} | {:error, {:invalid_payload, atom() | tuple()}}
  def decode(plaintext) when is_binary(plaintext) do
    case Jason.decode(plaintext) do
      {:ok, decoded} -> validate(decoded)
      # The parser's error holds the whole decrypted input: only where it
      # stopped leaves here.
      {:error, %Jason.DecodeError{position: position}} -> {:error, not_json(position)}
    end
  end

  @doc """
  Encode a material payload. `fields` is the name → value map mirrored
  (names only) by the row's unsealed `field_names` column; `oauth` is the
  token bundle or nil.
  """
  @spec encode_material(%{String.t() => String.t()}, map() | nil) ::
          {:ok, binary()} | {:error, {:invalid_payload, term()}}
  def encode_material(fields, oauth \\ nil) do
    doc =
      %{"v" => @version, "fields" => fields}
      |> then(fn doc -> if oauth, do: Map.put(doc, "oauth", oauth), else: doc end)

    with {:ok, valid} <- validate(doc) do
      {:ok, Jason.encode!(valid)}
    end
  end

  defp not_json(position) when is_integer(position), do: {:invalid_payload, {:not_json, position}}

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate(%{"v" => @version, "fields" => fields} = doc) when is_map(fields) do
    with :ok <- only_keys(doc, ~w(v fields oauth)),
         :ok <- check_fields(fields),
         :ok <- check_oauth(Map.get(doc, "oauth")) do
      {:ok, doc}
    end
  end

  # The rejected term is decrypted material — shape names only, never the
  # value, in the reason.
  defp validate(_other), do: {:error, {:invalid_payload, :unrecognized_shape}}

  defp only_keys(map, allowed) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      extra -> {:error, {:invalid_payload, {:unknown_keys, Enum.sort(extra)}}}
    end
  end

  defp check_fields(fields) do
    valid? =
      Enum.all?(fields, fn
        {name, value} -> is_binary(name) and name != "" and is_binary(value)
      end)

    if valid?, do: :ok, else: bad("fields")
  end

  defp check_oauth(nil), do: :ok

  defp check_oauth(%{"access_token" => token} = oauth) when is_binary(token) do
    with :ok <- only_keys(oauth, @oauth_keys) do
      if optional_string?(oauth, "refresh_token") and optional_string?(oauth, "expires_at"),
        do: :ok,
        else: bad("oauth")
    end
  end

  defp check_oauth(_), do: bad("oauth")

  defp optional_string?(map, key) do
    case Map.get(map, key) do
      nil -> true
      v -> is_binary(v)
    end
  end

  defp bad(key), do: {:error, {:invalid_payload, {:malformed, key}}}
end
