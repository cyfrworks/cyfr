# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.Payload do
  @moduledoc """
  The sealed vault-entry payload document, version 3:

      {"v":3,"fields":{"url":"https://…","anon_key":"…"},
       "oauth":{"access_token":"…","refresh_token":"…",
                "expires_at":"2026-08-07T12:00:00Z","token_type":"bearer",
                "scopes":["a","b"],
                "tokens":{"a":{"access_token":"…","expires_at":null}}}}

  The `oauth` bundle holds the entry's full-scope token beside its
  refresh token. Its optional `tokens` map holds only tokens for narrower
  scope sets, each obtained by a refresh the provider attenuated
  (`Sanctum.Vault.OAuth`): the key is the scope set, sorted, de-duplicated
  and joined by one space (`scope_key/1`), the value the token and its
  expiry. Absent means none.

  Decoding is strict: another version, unknown keys, non-string field
  values and malformed oauth blocks are refused, so a tampered or
  mis-written payload fails before any of it is dispensed.
  """

  @type t :: map()

  @version 3
  @oauth_keys ~w(access_token refresh_token expires_at token_type scopes tokens)
  @token_keys ~w(access_token expires_at)

  @doc "Decode and validate a sealed payload's plaintext."
  @spec decode(binary()) ::
          {:ok, t()} | {:error, {:invalid_payload, term()}}
  def decode(plaintext) when is_binary(plaintext) do
    case Jason.decode(plaintext) do
      {:ok, decoded} -> validate(decoded)
      {:error, reason} -> {:error, {:invalid_payload, reason}}
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

  @doc """
  The key a scope set's token is held under in `oauth.tokens`: its scopes
  sorted, de-duplicated and joined by one space, so one set has one key
  however it was spelled.
  """
  @spec scope_key([String.t()]) :: String.t()
  def scope_key(scopes) when is_list(scopes) do
    scopes |> Enum.uniq() |> Enum.sort() |> Enum.join(" ")
  end

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
      optional_ok? =
        optional_string?(oauth, "refresh_token") and
          optional_string?(oauth, "expires_at") and
          optional_string?(oauth, "token_type") and
          optional_string_list?(oauth, "scopes")

      if optional_ok?, do: check_tokens(Map.get(oauth, "tokens")), else: bad("oauth")
    end
  end

  defp check_oauth(_), do: bad("oauth")

  # Each held token sits under its own scope set's key, spelled the one
  # way `scope_key/1` spells it, so a set is never held twice under two
  # spellings.
  defp check_tokens(nil), do: :ok

  defp check_tokens(tokens) when is_map(tokens) do
    valid? =
      Enum.all?(tokens, fn {key, token} ->
        canonical_key?(key) and held_token?(token)
      end)

    if valid?, do: :ok, else: bad("oauth.tokens")
  end

  defp check_tokens(_), do: bad("oauth.tokens")

  defp canonical_key?(key) when is_binary(key) and key != "" do
    scopes = String.split(key, " ")
    "" not in scopes and key == scope_key(scopes)
  end

  defp canonical_key?(_), do: false

  defp held_token?(%{"access_token" => token} = held) when is_binary(token) do
    Map.keys(held) -- @token_keys == [] and optional_string?(held, "expires_at")
  end

  defp held_token?(_), do: false

  defp optional_string?(map, key) do
    case Map.get(map, key) do
      nil -> true
      v -> is_binary(v)
    end
  end

  defp optional_string_list?(map, key) do
    case Map.get(map, key) do
      nil -> true
      list when is_list(list) -> Enum.all?(list, &is_binary/1)
      _ -> false
    end
  end

  defp bad(key), do: {:error, {:invalid_payload, {:malformed, key}}}
end
